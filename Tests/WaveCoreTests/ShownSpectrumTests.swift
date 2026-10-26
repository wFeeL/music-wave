import Foundation
import Testing
@testable import WaveCore

/// «Спектр» на кадрах острова: пружины идут только при стиле «Спектр», смена стиля сбрасывает их,
/// кадры получают полосы и пики в своих массивах, в тишине и на паузе все приходит в 0 и
/// детектор простоя уходит в редкие кадры.
struct ShownSpectrumTests {
    private static let bandCount = BandMapper.bandCount
    private static let dt = 1.0 / 60

    private static func random(_ rng: inout SplitMix64) -> [Float] {
        (0..<bandCount).map { _ in Float(Double(rng.next() >> 11) / Double(1 << 53)) }
    }

    private static func address(_ array: [Float]) -> UnsafePointer<Float>? {
        array.withUnsafeBufferPointer { $0.baseAddress }
    }

    /// Кадр со стилем `look`, у которого есть полосы.
    private static func frame(
        _ shown: inout ShownSpectrum, look: WaveLook, bands: [Float], dt: Double
    ) throws -> SpectrumLevels {
        let levels = shown.step(look: look, bands: bands, dt: dt)
        return try #require(levels)
    }

    /// Кадр без полос (другой стиль).
    private static func skipped(_ shown: inout ShownSpectrum, look: WaveLook, bands: [Float], dt: Double) -> Bool {
        shown.step(look: look, bands: bands, dt: dt) == nil
    }

    /// Пока стиль «Волны», пружины стоят в нуле и кадр полос не получает; «Спектр» шагает,
    /// возврат к «Волнам» сразу сбрасывает все в ноль, новый «Спектр» растет с нуля.
    @Test func stepsOnlyWhileSpectrum() throws {
        let loud = [Float](repeating: 0.8, count: Self.bandCount)
        var shown = ShownSpectrum()
        for _ in 0..<30 {
            let skipped = Self.skipped(&shown, look: .waves, bands: loud, dt: Self.dt)
            #expect(skipped)
        }
        #expect(shown.highest == 0)
        #expect(shown.motion.values.allSatisfy { $0 == 0 })

        var levels = try Self.frame(&shown, look: .spectrum, bands: loud, dt: Self.dt)
        #expect(levels.values.allSatisfy { $0 > 0 && $0 < 0.8 })
        for _ in 0..<60 {
            levels = try Self.frame(&shown, look: .spectrum, bands: loud, dt: Self.dt)
        }
        #expect(levels.values == loud && levels.peaks == loud)
        #expect(levels.values == shown.motion.values && levels.peaks == shown.motion.peaks)
        #expect(shown.highest == 0.8)

        let skipped = Self.skipped(&shown, look: .waves, bands: loud, dt: Self.dt)
        #expect(skipped)
        #expect(shown.highest == 0)
        #expect(shown.motion.values.allSatisfy { $0 == 0 } && shown.motion.peaks.allSatisfy { $0 == 0 })
        let again = try Self.frame(&shown, look: .spectrum, bands: loud, dt: Self.dt)
        #expect(again.values.allSatisfy { $0 > 0 && $0 < 0.8 })
    }

    /// Кадр получает полосы и пики не в массивах движения: следующий шаг пишет во второй
    /// набор, через шаг в первый, если его уже никто не держит. Копии при записи нет, массивы
    /// прошлого кадра не меняются. Повторный кадр без шага отдает те же массивы.
    @Test func framesAlternateTwoBuffers() throws {
        var rng = SplitMix64(seed: 41)
        var shown = ShownSpectrum()
        var firstValues: UnsafePointer<Float>?
        var firstPeaks: UnsafePointer<Float>?
        do {
            let first = try Self.frame(&shown, look: .spectrum, bands: Self.random(&rng), dt: Self.dt)
            firstValues = Self.address(first.values)
            firstPeaks = Self.address(first.peaks)
        }
        let second = try Self.frame(&shown, look: .spectrum, bands: Self.random(&rng), dt: Self.dt)
        let secondCopy = second.values.map { $0 }
        let third = try Self.frame(&shown, look: .spectrum, bands: Self.random(&rng), dt: Self.dt)
        #expect(Self.address(third.values) == firstValues)
        #expect(Self.address(third.peaks) == firstPeaks)
        #expect(Self.address(second.values) != firstValues)
        #expect(Self.address(third.values) != Self.address(shown.motion.values))
        #expect(Self.address(third.peaks) != Self.address(shown.motion.peaks))
        #expect(third.values == shown.motion.values && third.peaks == shown.motion.peaks)
        #expect(second.values == secondCopy)

        let repeated = try Self.frame(&shown, look: .spectrum, bands: Self.random(&rng), dt: 0)
        #expect(Self.address(repeated.values) == Self.address(third.values))
        #expect(repeated == third)
    }

    /// Пауза или тишина (полосы после мягкой остановки в нуле): линия и призрак приходят ровно в
    /// 0, детектор простоя с входом `highest` уходит в простой меньше чем за 2 с.
    @Test func silenceReachesZeroAndIdles() throws {
        var rng = SplitMix64(seed: 9)
        var shown = ShownSpectrum()
        var detector = RenderIdleDetector()
        var now = 0.0
        for _ in 0..<300 {
            _ = shown.step(look: .spectrum, bands: Self.random(&rng), dt: Self.dt)
            now += Self.dt
            let idle = detector.update(level: shown.highest, glow: 0, pulse: 0, now: now)
            #expect(!idle)
        }
        #expect(shown.highest > 0.5)
        let silence = [Float](repeating: 0, count: Self.bandCount)
        let start = now
        var idleAt: Double?
        var last: SpectrumLevels?
        for _ in 0..<(60 * 3) {
            last = shown.step(look: .spectrum, bands: silence, dt: Self.dt)
            now += Self.dt
            if detector.update(level: shown.highest, glow: 0, pulse: 0, now: now), idleAt == nil {
                idleAt = now - start
            }
        }
        let levels = try #require(last)
        #expect(levels.values.allSatisfy { $0 == 0 } && levels.peaks.allSatisfy { $0 == 0 })
        #expect(shown.highest == 0)
        #expect(idleAt.map { $0 <= 2 } == true, "\(String(describing: idleAt))")
    }

    /// Снимки ставят готовое состояние (линия и призрак над ней) без шага; предпросмотр на
    /// первом кадре встает на полосы. Другой стиль сбрасывает и такое состояние.
    @Test func showSetsStateWithoutStepping() throws {
        var motion = SpectrumMotion()
        let loud = [Float](repeating: 0.9, count: Self.bandCount)
        for _ in 0..<30 { motion.step(bands: loud, dt: Self.dt) }
        for _ in 0..<12 { motion.step(bands: [Float](repeating: 0.2, count: Self.bandCount), dt: Self.dt) }
        #expect(zip(motion.peaks, motion.values).allSatisfy { $0 > $1 })

        var shown = ShownSpectrum()
        shown.show(motion)
        let shot = try Self.frame(&shown, look: .spectrum, bands: [], dt: 0)
        #expect(shot.values == motion.values && shot.peaks == motion.peaks)
        #expect(shown.highest == motion.highest)
        let bad = try Self.frame(&shown, look: .spectrum, bands: [], dt: .nan)
        #expect(bad == shot)

        shown.show(motion)
        #expect(shown.idleLevel(showsPeaks: true) == motion.highest)
        // Без «Следа пиков» скрытый призрак над линией не держит частые кадры.
        #expect(shown.idleLevel(showsPeaks: false) == motion.values.max())
        #expect(shown.idleLevel(showsPeaks: false) < shown.idleLevel(showsPeaks: true))
        let skipped = Self.skipped(&shown, look: .waves, bands: loud, dt: 0)
        #expect(skipped)
        #expect(shown.highest == 0)
        #expect(shown.idleLevel(showsPeaks: true) == 0 && shown.idleLevel(showsPeaks: false) == 0)

        let bands = (0..<Self.bandCount).map { Float($0) / 23 }
        shown.show(bands: bands)
        let preview = try Self.frame(&shown, look: .spectrum, bands: bands, dt: 0)
        #expect(preview.values == bands && preview.peaks == bands)
    }
}
