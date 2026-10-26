import Foundation
import Testing
@testable import WaveCore

/// Анализ по шагам 256 сэмплов. Часть случаев перенесена из тестов `Analyzer` 0.9.0 и огибающей удара.
struct StreamAnalyzerTests {
    private static let rate = 48_000.0

    @Test func configScalesWithRate() {
        for (rate, size, hop) in [(44_100.0, 1024, 256), (48_000, 1024, 256), (96_000, 2048, 512)] {
            let config = AnalysisConfig(sampleRate: rate)
            #expect(config.sampleRate == rate)
            #expect(config.fftSize == size)
            #expect(config.hopSize == hop)
            #expect(abs(config.hopDuration - Double(hop) / rate) < 1e-12)
            #expect(abs(config.framesPerSecond - rate / Double(hop)) < 1e-9)
        }
        let analyzer = StreamAnalyzer(sampleRate: 96_000)
        #expect(analyzer.config == AnalysisConfig(sampleRate: 96_000))
        analyzer.reconfigure(sampleRate: 44_100)
        #expect(analyzer.config == AnalysisConfig(sampleRate: 44_100))
    }

    @Test func bassSineDrivesBassLayer() throws {
        let samples = TestSignals.sine(frequency: 80, amplitude: 0.5, sampleRate: Self.rate, count: 48_000)
        let frame = try #require(StreamAnalyzer(sampleRate: Self.rate).processSignal(samples).last?.frame)
        #expect(frame.layers[WaveLayer.bass.rawValue] > 0.5)
        #expect(frame.layers[WaveLayer.high.rawValue] < 0.1)
    }

    @Test func hihatNoiseDrivesHighLayer() throws {
        // Равномерный шум с σ = 0.3 (амплитуда σ * sqrt(3)), затем разность соседних сэмплов.
        let noise = TestSignals.whiteNoise(amplitude: Float(0.3 * 3.0.squareRoot()), count: 48_001, seed: 42)
        let samples = (1..<noise.count).map { noise[$0] - noise[$0 - 1] }
        let frame = try #require(StreamAnalyzer(sampleRate: Self.rate).processSignal(samples).last?.frame)
        #expect(frame.layers[WaveLayer.high.rawValue] > frame.layers[WaveLayer.bass.rawValue] + 0.3)
    }

    @Test func silenceDecaysToFlat() throws {
        let tone = TestSignals.sine(frequency: 440, amplitude: 0.5, sampleRate: Self.rate, count: 48_000)
        let hops = StreamAnalyzer(sampleRate: Self.rate).processSignal(tone + TestSignals.silence(count: 48_000))
        let toneHop = try #require(hops.last { $0.endTime <= 1.0 })
        #expect(toneHop.frame.level > 0.5)
        let last = try #require(hops.last)
        #expect(last.endTime == 2.0)
        #expect(last.frame.level < 0.02)
        #expect(last.frame.beat < 0.01)
    }

    @Test func frameTimeIsWindowCentre() {
        let analyzer = StreamAnalyzer(sampleRate: Self.rate)
        let window = [Float](repeating: 0, count: analyzer.config.fftSize)
        let hop = window.withUnsafeBufferPointer {
            analyzer.processHop(window: $0, endSample: 48_000, settings: LevelSettings())
        }
        #expect(hop.frameTime == (48_000.0 - 512) / 48_000)
        #expect(hop.endTime == 1.0)
    }

    /// Простой острова: один шаг на пробуждение, уровни и сглаживание идут на время с прошлого
    /// пробуждения (`dt`). Явный шаг, равный длине шага, дает тот же кадр, что и без него.
    @Test func levelStepOverride() {
        let tone = TestSignals.sine(frequency: 80, amplitude: 0.5, sampleRate: Self.rate, count: 1024)
        let plain = StreamAnalyzer(sampleRate: Self.rate)
        let same = StreamAnalyzer(sampleRate: Self.rate)
        let slow = StreamAnalyzer(sampleRate: Self.rate)
        let settings = LevelSettings()
        tone.withUnsafeBufferPointer { window in
            for step in 1...3 {
                let end = 1024 * step
                let a = plain.processHop(window: window, endSample: end, settings: settings)
                let b = same.processHop(window: window, endSample: end, settings: settings, dt: plain.config.hopDuration)
                let c = slow.processHop(window: window, endSample: end, settings: settings, dt: 1.0 / 15)
                #expect(a.frame == b.frame)
                // За 67 мс атака 10 мс доходит до цели, за 5.3 мс нет.
                #expect(c.frame.layers[WaveLayer.bass.rawValue] > a.frame.layers[WaveLayer.bass.rawValue] + 0.05)
                #expect(c.endTime == a.endTime)
            }
        }
    }

    /// Остров снова виден: `resetOnsets()` начинает заново историю функций онсетов и выбор пиков
    /// (со следящими пиками), а уровни остаются. Дальше онсеты те же, что у свежего анализатора,
    /// уровни нет: автоуровень помнит громкое начало.
    @Test func resetOnsetsKeepsLevels() {
        let rate = Self.rate
        let loud = TestSignals.clickTrack(bpm: 120, sampleRate: rate, seconds: 3).samples.map { $0 * 1.1 }
        let quiet = TestSignals.clickTrack(bpm: 120, sampleRate: rate, seconds: 3).samples.map { $0 * 0.3 }
        let used = StreamAnalyzer(sampleRate: rate)
        _ = used.processSignal(loud)
        used.resetOnsets()
        let fresh = StreamAnalyzer(sampleRate: rate)
        let afterReset = used.processSignal(quiet, firstSample: loud.count)
        let fromFresh = fresh.processSignal(quiet, firstSample: loud.count)
        #expect(afterReset.count == fromFresh.count)
        var onsetMismatches = 0
        var levelDifference: Float = 0
        for (a, b) in zip(afterReset, fromFresh) {
            if a.kickODF != b.kickODF || a.broadbandODF != b.broadbandODF
                || a.kickOnset != b.kickOnset || a.broadbandOnset != b.broadbandOnset {
                onsetMismatches += 1
            }
            levelDifference = max(levelDifference, abs(a.frame.level - b.frame.level))
        }
        #expect(onsetMismatches == 0)
        #expect(fromFresh.contains { $0.kickOnset != nil })
        #expect(levelDifference > 0.1, "уровни не должны сброситься: \(levelDifference)")
    }

    @Test func noNaNOnZerosAndDenormals() {
        let analyzer = StreamAnalyzer(sampleRate: Self.rate)
        let denormal = Float(sign: .plus, exponentBitPattern: 0, significandBitPattern: 1_000)
        #expect(denormal != 0 && denormal.isSubnormal)
        for input in [Float(0), denormal] {
            let hops = analyzer.processSignal([Float](repeating: input, count: 24_000))
            #expect(!hops.isEmpty)
            for hop in hops {
                let frame = hop.frame
                let values = frame.bands + frame.layers + [frame.beat, frame.level]
                #expect(values.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
                #expect(frame.rawLevelDB.isFinite)
                #expect(hop.broadbandODF.isFinite && hop.broadbandODF >= 0)
                #expect(hop.kickLevelDB.isFinite && hop.kickLevelDB >= -120)
                #expect(hop.kickOnset == nil && hop.broadbandOnset == nil)
            }
        }
    }

    @Test func rawLevelIgnoresSensitivity() throws {
        let samples = TestSignals.sine(frequency: 1000, amplitude: 0.3, sampleRate: Self.rate, count: 24_000)
        let low = try #require(
            StreamAnalyzer(sampleRate: Self.rate).processSignal(samples, settings: LevelSettings(sensitivity: 0.25)).last?.frame
        )
        let high = try #require(
            StreamAnalyzer(sampleRate: Self.rate).processSignal(samples, settings: LevelSettings(sensitivity: 3)).last?.frame
        )
        #expect(low.rawLevelDB == high.rawLevelDB)
        #expect(low.rawLevelDB > -30)
        #expect(low.level != high.level)
    }

    @Test func reconfigureKeepsBandForSineAfterRateChange() throws {
        let analyzer = StreamAnalyzer(sampleRate: Self.rate)
        _ = analyzer.processSignal(TestSignals.sine(frequency: 1000, amplitude: 0.5, sampleRate: Self.rate, count: 48_000))
        analyzer.reconfigure(sampleRate: 44_100)
        #expect(analyzer.config.sampleRate == 44_100)

        let samples = TestSignals.sine(frequency: 1000, amplitude: 0.5, sampleRate: 44_100, count: 44_100)
        let frame = try #require(analyzer.processSignal(samples, firstSample: 44_100).last?.frame)
        let mapper = BandMapper(fftSize: analyzer.config.fftSize, sampleRate: 44_100)
        let expected = try #require(mapper.band(containing: 1000))
        let loudest = try #require(frame.bands.indices.max { frame.bands[$0] < frame.bands[$1] })
        #expect(expected == 12)
        #expect(loudest == expected)
    }

    @Test func resetClearsAutoLevelPeaks() throws {
        let quiet = TestSignals.sine(frequency: 440, amplitude: 0.01, sampleRate: Self.rate, count: 24_000)
        let fresh = try #require(StreamAnalyzer(sampleRate: Self.rate).processSignal(quiet).last?.frame)

        // Громкий припев, пауза (reset), тихий трек: пик громкого не должен держать волны маленькими.
        let analyzer = StreamAnalyzer(sampleRate: Self.rate)
        _ = analyzer.processSignal(TestSignals.sine(frequency: 440, amplitude: 0.5, sampleRate: Self.rate, count: 96_000))
        analyzer.reset()
        // Сразу после сброса тишина дает ровную линию: сглаживание не тянет старый уровень.
        let silent = try #require(analyzer.processSignal(TestSignals.silence(count: analyzer.config.fftSize)).last)
        #expect(silent.frame.bands.allSatisfy { $0 == 0 })
        #expect(silent.frame.beat == 0)

        analyzer.reset()
        let resumed = try #require(analyzer.processSignal(quiet, firstSample: 600_000).last?.frame)
        // Тон -40 dBFS на 440 Гц с наклоном -2.6 дБ стоит ниже minPeakDB, поэтому чуть ниже 0.5.
        #expect(fresh.level > 0.45)
        #expect(abs(resumed.level - fresh.level) < 0.05)
    }

    /// Ступень уровней (автоуровень, наклон, чувствительность) не влияет на функции онсетов и онсеты.
    @Test func onsetFunctionsIgnoreLevelStage() {
        let scene = Drums.fourOnFloor(seconds: 8, hats: .eighths, snareOnBackbeat: true)
        let auto = StreamAnalyzer(sampleRate: scene.sampleRate)
            .processSignal(scene.samples, settings: LevelSettings(mode: .auto))
        let absolute = StreamAnalyzer(sampleRate: scene.sampleRate)
            .processSignal(scene.samples, settings: LevelSettings(mode: .absolute, sensitivity: 3))
        #expect(auto.count == absolute.count)
        #expect(auto.map(\.broadbandODF) == absolute.map(\.broadbandODF))
        #expect(auto.map(\.kickODF) == absolute.map(\.kickODF))
        #expect(auto.map(\.kickOnset) == absolute.map(\.kickOnset))
        #expect(auto.map(\.broadbandOnset) == absolute.map(\.broadbandOnset))
        #expect(auto.contains { $0.kickOnset != nil })
    }

    @Test func envelopeDecaysWithin200ms() {
        var envelope = BeatEnvelope()
        envelope.trigger()
        #expect(envelope.value == 1)
        for _ in 0..<12 { envelope.step(dt: 1.0 / 60) }
        #expect(envelope.value < 0.05)
    }

    /// Мощность бинов бочки делится на ENBW окна Ханна, как у полос `BandMapper`: синус амплитуды A
    /// дает A², здесь 10·log10(0.25) ≈ -6.02 dBFS.
    @Test func kickLevelIsKickBinPower() throws {
        let samples = TestSignals.sine(frequency: 80, amplitude: 0.5, sampleRate: Self.rate, count: 24_000)
        let hop = try #require(StreamAnalyzer(sampleRate: Self.rate).processSignal(samples).last)
        #expect(abs(hop.kickLevelDB - Float(10 * log10(0.25))) < 1)
        let silent = try #require(StreamAnalyzer(sampleRate: Self.rate).processSignal(TestSignals.silence(count: 2048)).last)
        #expect(silent.kickLevelDB == -120)
    }

    @Test func spectrumIntoMatchesArrayVersion() {
        for size in [1024, 2048] {
            let fft = RealFFT(size: size)
            let noise = TestSignals.whiteNoise(amplitude: 0.5, count: size, seed: UInt64(size))
            let expected = fft.amplitudeSpectrum(noise)
            var actual = [Float](repeating: -1, count: size / 2)
            noise.withUnsafeBufferPointer { input in
                actual.withUnsafeMutableBufferPointer { fft.amplitudeSpectrum(input, into: $0) }
            }
            #expect(zip(expected, actual).map { abs($0 - $1) }.max() ?? 1 < 1e-6)

            let mapper = BandMapper(fftSize: size, sampleRate: Self.rate)
            let levels = mapper.bandLevels(expected)
            var levelsInto = [Float](repeating: 1, count: BandMapper.bandCount)
            expected.withUnsafeBufferPointer { input in
                levelsInto.withUnsafeMutableBufferPointer { mapper.bandLevels(input, into: $0) }
            }
            #expect(zip(levels, levelsInto).map { abs($0 - $1) }.max() ?? 1 < 1e-6)

            // Нормировка: два одинаковых процессора, массив и буфер, на одной последовательности.
            let ranges = WaveLayer.allCases.map { mapper.bands(for: $0) }
            var arrayProcessor = LevelProcessor(layerBands: ranges)
            var bufferProcessor = LevelProcessor(layerBands: ranges)
            var normalized = [Float](repeating: -1, count: levels.count)
            for step in 0..<20 {
                let input = levels.map { $0 - Float(step) }
                let viaArray = arrayProcessor.normalize(input, dt: 1.0 / 60, settings: LevelSettings())
                input.withUnsafeBufferPointer { input in
                    normalized.withUnsafeMutableBufferPointer {
                        bufferProcessor.normalize(input, dt: 1.0 / 60, settings: LevelSettings(), into: $0)
                    }
                }
                #expect(viaArray == normalized)
            }
        }
    }
}
