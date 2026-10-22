import Foundation
import Testing
@testable import WaveCore

struct AnalyzerTests {
    private static let fftSize = Analyzer.fftSize
    private static let hop = 800
    private static let dt = 1.0 / 60

    /// Прогоняет сигнал окнами по 2048 с шагом 800; время кадра это конец окна.
    @discardableResult
    private static func run(
        _ analyzer: Analyzer,
        samples: [Float],
        sampleRate: Double = 48_000,
        timeOffset: Double = 0,
        settings: LevelSettings = LevelSettings()
    ) -> [(time: Double, frame: WaveFrame)] {
        var frames: [(time: Double, frame: WaveFrame)] = []
        var end = fftSize
        while end <= samples.count {
            let time = timeOffset + Double(end) / sampleRate
            let frame = analyzer.process(
                samples: Array(samples[(end - fftSize)..<end]),
                time: time,
                dt: dt,
                settings: settings
            )
            frames.append((time, frame))
            end += hop
        }
        return frames
    }

    @Test func bassSineDrivesBassLayer() throws {
        let analyzer = Analyzer(sampleRate: 48_000)
        let samples = TestSignals.sine(frequency: 80, amplitude: 0.5, sampleRate: 48_000, count: 96_000)
        let frame = try #require(Self.run(analyzer, samples: samples).last?.frame)
        #expect(frame.layers[WaveLayer.bass.rawValue] > 0.6)
        #expect(frame.layers[WaveLayer.high.rawValue] < 0.1)
    }

    @Test func hihatNoiseDrivesHighLayer() throws {
        let analyzer = Analyzer(sampleRate: 48_000)
        // Равномерный шум с σ = 0.3 (амплитуда σ * sqrt(3)), затем разность соседних сэмплов.
        let noise = TestSignals.whiteNoise(amplitude: Float(0.3 * 3.0.squareRoot()), count: 96_001, seed: 42)
        let samples = (1..<noise.count).map { noise[$0] - noise[$0 - 1] }
        let frame = try #require(Self.run(analyzer, samples: samples).last?.frame)
        #expect(frame.layers[WaveLayer.high.rawValue] > frame.layers[WaveLayer.bass.rawValue] + 0.3)
    }

    @Test func silenceDecaysToFlat() throws {
        let analyzer = Analyzer(sampleRate: 48_000)
        let tone = TestSignals.sine(frequency: 440, amplitude: 0.5, sampleRate: 48_000, count: 96_000)
        let quiet = TestSignals.silence(count: 72_000)
        let frames = Self.run(analyzer, samples: tone + quiet)
        let toneFrame = try #require(frames.first { $0.time > 1.9 })
        #expect(toneFrame.frame.level > 0.5)
        let last = try #require(frames.last?.frame)
        #expect(last.level < 0.02)
        #expect(last.beat < 0.01)
    }

    @Test func beatsAppearOnClickTrack() {
        let analyzer = Analyzer(sampleRate: 48_000)
        let (samples, beatTimes) = TestSignals.clickTrack(bpm: 120, sampleRate: 48_000, seconds: 8)
        let frames = Self.run(analyzer, samples: samples)
        // Последний удар без хвоста окна не проверяем.
        let expected = beatTimes.filter { $0 >= 1.0 && $0 <= 7.5 }
        let hit = expected.filter { tb in
            let peak = frames.filter { $0.time >= tb && $0.time <= tb + 0.05 }.map(\.frame.beat).max() ?? 0
            return peak > 0.95
        }
        #expect(Double(hit.count) / Double(expected.count) >= 0.95)
    }

    @Test func reconfigureKeepsBandForSineAfterRateChange() throws {
        let analyzer = Analyzer(sampleRate: 48_000)
        Self.run(analyzer, samples: TestSignals.sine(frequency: 1000, amplitude: 0.5, sampleRate: 48_000, count: 48_000))
        analyzer.reconfigure(sampleRate: 44_100)
        #expect(analyzer.sampleRate == 44_100)

        let samples = TestSignals.sine(frequency: 1000, amplitude: 0.5, sampleRate: 44_100, count: 44_100)
        let frame = try #require(Self.run(analyzer, samples: samples, sampleRate: 44_100, timeOffset: 1).last?.frame)
        let expected = try #require(BandMapper(fftSize: Self.fftSize, sampleRate: 44_100).band(containing: 1000))
        let loudest = try #require(frame.bands.indices.max { frame.bands[$0] < frame.bands[$1] })
        #expect(expected == 12)
        #expect(loudest == expected)
    }

    @Test func noNaNOnZerosAndDenormals() {
        let analyzer = Analyzer(sampleRate: 48_000)
        let denormal = Float(sign: .plus, exponentBitPattern: 0, significandBitPattern: 1_000)
        #expect(denormal != 0 && denormal.isSubnormal)
        for input in [Float(0), denormal] {
            let samples = [Float](repeating: input, count: 48_000)
            for item in Self.run(analyzer, samples: samples) {
                let frame = item.frame
                let values = frame.bands + frame.layers + [frame.beat, frame.level]
                #expect(values.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
                #expect(frame.rawLevelDB.isFinite)
            }
        }
    }

    @Test func rawLevelIgnoresSensitivity() throws {
        let samples = TestSignals.sine(frequency: 1000, amplitude: 0.3, sampleRate: 48_000, count: 24_000)
        let low = try #require(Self.run(Analyzer(sampleRate: 48_000), samples: samples, settings: LevelSettings(sensitivity: 0.25)).last?.frame)
        let high = try #require(Self.run(Analyzer(sampleRate: 48_000), samples: samples, settings: LevelSettings(sensitivity: 3)).last?.frame)
        #expect(low.rawLevelDB == high.rawLevelDB)
        #expect(low.rawLevelDB > -30)
        #expect(low.level != high.level)
    }

    @Test func timeJumpResetsStaleState() throws {
        let analyzer = Analyzer(sampleRate: 48_000)
        let tone = TestSignals.sine(frequency: 440, amplitude: 0.5, sampleRate: 48_000, count: 48_000)
        Self.run(analyzer, samples: tone)
        // Пауза 10 с, затем тишина: сглаживание не должно тянуть старый уровень.
        let silent = analyzer.process(
            samples: TestSignals.silence(count: Self.fftSize), time: 11, dt: Self.dt, settings: LevelSettings()
        )
        #expect(silent.bands.allSatisfy { $0 == 0 })
        #expect(silent.beat == 0)
    }

    @Test func frameStoreReturnsLastPublished() {
        let store = FrameStore()
        #expect(store.latest == .silent)
        let first = WaveFrame(bands: [Float](repeating: 0.1, count: 24), layers: [0.1, 0.2, 0.3], beat: 0.4, level: 0.3, rawLevelDB: -20)
        let second = WaveFrame(bands: [Float](repeating: 0.5, count: 24), layers: [0.5, 0.6, 0.7], beat: 0.8, level: 0.7, rawLevelDB: -10)
        store.publish(first)
        store.publish(second)
        #expect(store.latest == second)
    }

    @Test func silentFrameShape() {
        let frame = WaveFrame.silent
        #expect(frame.bands == [Float](repeating: 0, count: 24))
        #expect(frame.layers == [0, 0, 0])
        #expect(frame.beat == 0 && frame.level == 0 && frame.rawLevelDB == -120)
    }
}
