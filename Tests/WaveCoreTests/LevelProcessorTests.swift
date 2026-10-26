import Foundation
import Testing
@testable import WaveCore

@Suite struct LevelProcessorTests {
    static let layers: [Range<Int>] = [0..<7, 7..<18, 18..<24]
    static let frame = 1.0 / 60.0

    static func makeProcessor() -> LevelProcessor {
        LevelProcessor(layerBands: layers)
    }

    /// Кадр из 24 полос: `floor` везде, кроме заданных полос.
    static func levels(_ overrides: [Int: Float], floor: Float = -120) -> [Float] {
        var result = [Float](repeating: floor, count: 24)
        for (band, value) in overrides { result[band] = value }
        return result
    }

    /// Гонит один и тот же кадр `seconds` секунд и возвращает последний выход.
    @discardableResult
    static func run(
        _ processor: inout LevelProcessor,
        _ input: [Float],
        seconds: Double,
        settings: LevelSettings = LevelSettings(followSystemVolume: false)
    ) -> [Float] {
        var output: [Float] = []
        for _ in 0..<Int((seconds / frame).rounded()) {
            output = processor.normalize(input, dt: frame, settings: settings)
        }
        return output
    }

    @Test func silenceIsFlat() {
        for mode in LevelMode.allCases {
            var processor = Self.makeProcessor()
            let settings = LevelSettings(mode: mode)
            let output = Self.run(&processor, Self.levels([:]), seconds: 1, settings: settings)
            #expect(output.count == 24)
            #expect(output.allSatisfy { $0 == 0 })
        }
    }

    @Test func quietHissStaysSmall() {
        var processor = Self.makeProcessor()
        let output = Self.run(&processor, Self.levels([:], floor: -65), seconds: 3)
        #expect(output.allSatisfy { $0 < 0.1 })
    }

    @Test func invalidInputDoesNotPoisonPeak() {
        var processor = Self.makeProcessor()
        var bad = [Float](repeating: -50, count: 24)
        bad[0] = .infinity
        bad[1] = .nan
        bad[2] = -.infinity
        let settings = LevelSettings(followSystemVolume: false)
        let first = processor.normalize(bad, dt: Self.frame, settings: settings)
        #expect(first.allSatisfy { $0.isFinite && (0...1).contains($0) })

        let output = Self.run(&processor, Self.levels([3: -30], floor: -45), seconds: 2)
        #expect(output.allSatisfy { $0.isFinite })
        #expect(output[3] > 0.5)
    }

    /// Полоса 3 стоит на пике слоя, полоса 4 на 10 dB ниже. `level` это уровень полосы 4.
    private static func bassPair(level: Float) -> [Float] {
        levels([3: level + 10, 4: level])
    }

    @Test func autoModeEqualizesQuietAndLoud() {
        let expected = Float(pow(23.0 / 33.0, 1.4))
        // В тихом отрезке пик упирается в minPeakDB, поэтому там ожидание чуть ниже, но в допуске.
        let tolerance: Float = 0.05

        for quietFirst in [true, false] {
            var processor = Self.makeProcessor()
            let quiet = Self.bassPair(level: -50)
            let loud = Self.bassPair(level: -20)
            let segments = quietFirst ? [quiet, loud] : [loud, quiet]

            Self.run(&processor, segments[0], seconds: 9.9)
            let firstEnd = Self.run(&processor, segments[0], seconds: 0.1)
            #expect(abs(firstEnd[4] - expected) < tolerance)
            #expect(firstEnd[0..<3].allSatisfy { $0 == 0 })
            #expect(firstEnd[7...].allSatisfy { $0 == 0 })

            // После смены уровня значение должно войти в допуск не позже чем через 7 с.
            Self.run(&processor, segments[1], seconds: 6.9)
            let afterSeven = Self.run(&processor, segments[1], seconds: 0.1)
            #expect(abs(afterSeven[4] - expected) < tolerance)
            Self.run(&processor, segments[1], seconds: 2.9)
            let secondEnd = Self.run(&processor, segments[1], seconds: 0.1)
            #expect(abs(secondEnd[4] - expected) < tolerance)
            #expect(secondEnd[7...].allSatisfy { $0 == 0 })
        }
    }

    @Test func kicksPumpTheBassLayer() {
        var processor = Self.makeProcessor()
        Self.run(&processor, Self.levels([2: -20]), seconds: 1)
        let output = processor.normalize(Self.levels([2: -26]), dt: Self.frame, settings: LevelSettings(followSystemVolume: false))
        let expected = Float(pow(27.0 / 33.0, 1.4))
        #expect(abs(output[2] - expected) < 0.02)
        #expect(output[2] < 0.8)
    }

    /// Припев 10 с, затем куплет на 6 dB тише: удержанный пик спадает за 1...2 с, опора остается в
    /// мертвой зоне и уходит медленно, куплет остается ниже припева (около 0.80 от него).
    @Test func verseStaysBelowChorus() {
        var processor = Self.makeProcessor()
        let chorus = Self.run(&processor, Self.bassPair(level: -20), seconds: 10)
        let verse = Self.run(&processor, Self.bassPair(level: -26), seconds: 6)
        #expect(abs(chorus[4] - Float(pow(23.0 / 33.0, 1.4))) < 0.001)
        #expect(verse[4] <= 0.85 * chorus[4])
        #expect(verse[4] >= 0.5 * chorus[4])
    }

    /// Тишина между припевом и куплетом опору не двигает: куплет после нее тоже ниже припева.
    @Test func silenceThenVerseStaysBelowChorus() {
        var processor = Self.makeProcessor()
        let chorus = Self.run(&processor, Self.bassPair(level: -20), seconds: 10)
        Self.run(&processor, Self.levels([:]), seconds: 10)
        let first = processor.normalize(Self.bassPair(level: -26), dt: Self.frame, settings: LevelSettings(followSystemVolume: false))
        #expect(first[4] < 0.7 * chorus[4])
        let verse = Self.run(&processor, Self.bassPair(level: -26), seconds: 6)
        #expect(verse[4] <= 0.85 * chorus[4])
        #expect(verse[4] >= 0.5 * chorus[4])
    }

    @Test func loudJumpTakesTopInstantly() {
        var processor = Self.makeProcessor()
        Self.run(&processor, Self.levels([3: -40]), seconds: 5)
        let output = processor.normalize(Self.levels([3: -10]), dt: Self.frame, settings: LevelSettings(followSystemVolume: false))
        #expect(output.allSatisfy { (0...1).contains($0) })
        #expect(output[3] == 1)
    }

    @Test func silenceFreezesReference() {
        var processor = Self.makeProcessor()
        let chorus = Self.run(&processor, Self.bassPair(level: -20), seconds: 10)
        #expect(processor.layerReferencesDB[0] == -10)
        var drift: Float = 0
        for _ in 0..<600 {
            _ = processor.normalize(Self.levels([:]), dt: Self.frame, settings: LevelSettings(followSystemVolume: false))
            drift = max(drift, abs(processor.layerReferencesDB[0] + 10))
        }
        #expect(drift == 0)
        let after = processor.normalize(Self.bassPair(level: -20), dt: Self.frame, settings: LevelSettings(followSystemVolume: false))
        #expect(abs(after[4] - chorus[4]) < 0.02)
    }

    /// Гонит `DeadBandAGC` `frames` кадров по 1/60 с с одним и тем же пиком (он же уровень кадра).
    private static func agc(from reference: Float, peak: Float, frames: Int) -> DeadBandAGC {
        var agc = DeadBandAGC(referenceDB: reference)
        for _ in 0..<frames {
            agc.update(heldPeakDB: peak, currentDB: peak, dt: frame)
        }
        return agc
    }

    /// Пик на 6 dB под опорой (доля 0.82...0.84, в зоне): опора идет с tau 8 с, за 1 с до -10.705.
    @Test func deadBandMovesSlowlyInsideZone() {
        let agc = Self.agc(from: -10, peak: -16, frames: 60)
        #expect(agc.referenceDB >= -10.8 && agc.referenceDB <= -10.6)
        #expect(agc.isFast == false)
    }

    /// Пик на 20 dB под опорой (доля 0.394, ниже зоны): быстрый путь до 0.5 dB, затем медленный.
    @Test func fastOutsideZone() {
        let agc = Self.agc(from: -10, peak: -30, frames: 60)
        #expect(agc.referenceDB >= -29.6 && agc.referenceDB <= -29.5)
        #expect(agc.isFast == false)
    }

    /// Защелка держит быстрый путь, хотя доля уже на втором кадре вернулась в зону.
    @Test func fastModeLatchesThroughZone() {
        let agc = Self.agc(from: -10, peak: -30, frames: 18)
        #expect(agc.isFast == true)
        #expect(agc.referenceDB <= -27.2)
    }

    @Test func absoluteModeFollowsLoudness() {
        var processor = Self.makeProcessor()
        let settings = LevelSettings(mode: .absolute, followSystemVolume: false)
        let quiet = processor.normalize(Self.levels([5: -40]), dt: Self.frame, settings: settings)
        let loud = processor.normalize(Self.levels([5: -10]), dt: Self.frame, settings: settings)
        #expect(abs(quiet[5] - Float(pow(20.0 / 60.0, 1.4))) < 0.01)
        #expect(loud[5] > quiet[5] + 0.3)
    }

    @Test func systemVolumeScalesOutput() {
        let input = Self.levels([4: -40, 5: -30])
        for mode in LevelMode.allCases {
            var full = Self.makeProcessor()
            var quarter = Self.makeProcessor()
            var ignored = Self.makeProcessor()
            let reference = Self.run(&full, input, seconds: 0.5, settings: LevelSettings(mode: mode, followSystemVolume: true, systemVolume: 1))
            let scaled = Self.run(&quarter, input, seconds: 0.5, settings: LevelSettings(mode: mode, followSystemVolume: true, systemVolume: 0.25))
            let unfollowed = Self.run(&ignored, input, seconds: 0.5, settings: LevelSettings(mode: mode, followSystemVolume: false, systemVolume: 0.25))

            #expect(reference[4] > 0 && reference[4] < 1)
            #expect(abs(scaled[4] - reference[4] / 2) < 0.001)
            #expect(unfollowed[4] == reference[4])
        }
    }

    @Test func outputAlwaysInUnitRange() {
        var rng = TestRNG(seed: 42)
        for mode in LevelMode.allCases {
            var processor = Self.makeProcessor()
            let settings = LevelSettings(mode: mode, sensitivity: 3)
            for _ in 0..<1000 {
                // nextUnit() в [-1, 1): переводим в диапазон от -200 до +20 dB.
                let input = (0..<24).map { _ in -90 + 110 * rng.nextUnit() }
                let output = processor.normalize(input, dt: Self.frame, settings: settings)
                #expect(output.count == 24)
                #expect(output.allSatisfy { $0.isFinite && (0...1).contains($0) })
            }
        }
    }
}
