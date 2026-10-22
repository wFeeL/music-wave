import Foundation
import Testing
@testable import WaveCore

struct BeatDetectorTests {
    private static let sampleRate = 48_000.0
    private static let fftSize = 2048
    private static let hop = 800

    /// Прогоняет сигнал кадрами по 800 сэмплов; время кадра это конец окна 2048.
    private static func detectBeats(in samples: [Float]) -> [Double] {
        let fft = RealFFT(size: fftSize)
        let mapper = BandMapper(fftSize: fftSize, sampleRate: sampleRate)
        let lowBands = mapper.centers.indices.filter { mapper.centers[$0] <= 150 }
        var detector = BeatDetector()
        var beats: [Double] = []
        var end = fftSize
        while end <= samples.count {
            let spectrum = fft.amplitudeSpectrum(Array(samples[(end - fftSize)..<end]))
            let levels = mapper.bandLevels(spectrum)
            let amplitudes = lowBands.map { Float(pow(10.0, Double(levels[$0]) / 20)) }
            let time = Double(end) / sampleRate
            if detector.process(lowBandAmplitudes: amplitudes, time: time) { beats.append(time) }
            end += hop
        }
        return beats
    }

    /// Доля найденных ударов после первой секунды и число ложных срабатываний.
    private static func score(beats: [Double], beatTimes: [Double]) -> (found: Double, falsePositives: Int, windows: Int) {
        let tolerance = 0.030 + 1.0 / 60
        let expected = beatTimes.filter { $0 >= 1.0 }
        let found = expected.filter { tb in beats.contains { $0 >= tb && $0 <= tb + tolerance } }
        let falsePositives = beats.filter { beat in
            !beatTimes.contains { beat >= $0 && beat <= $0 + tolerance }
        }
        return (Double(found.count) / Double(expected.count), falsePositives.count, expected.count)
    }

    @Test func clickTrack120BpmDetected() {
        let track = TestSignals.clickTrack(bpm: 120, sampleRate: Self.sampleRate, seconds: 10)
        let beats = Self.detectBeats(in: track.samples)
        let result = Self.score(beats: beats, beatTimes: track.beatTimes)
        #expect(result.found >= 0.95)
        #expect(result.falsePositives <= 2)
    }

    @Test func quietClickTrackDetected() {
        let track = TestSignals.clickTrack(bpm: 120, sampleRate: Self.sampleRate, seconds: 10)
        let quiet = track.samples.map { $0 * 0.01 }
        let beats = Self.detectBeats(in: quiet)
        let result = Self.score(beats: beats, beatTimes: track.beatTimes)
        #expect(result.found >= 0.95)
    }

    /// Частоты идут отдельными случаями теста, Swift Testing гоняет их параллельно: одним циклом
    /// этот тест был самым долгим во всем наборе (около 11 с на Linux и до минуты на маке).
    @Test(arguments: Array(stride(from: 40.0, through: 150.0, by: 5.0)))
    func steadyToneHasNoBeats(frequency: Double) {
        let tone = TestSignals.sine(
            frequency: frequency, amplitude: 0.8, sampleRate: Self.sampleRate, count: Int(Self.sampleRate) * 10)
        let beats = Self.detectBeats(in: tone)
        #expect(beats.count <= 1, "tone \(frequency) Hz gave \(beats.count) beats")
    }

    @Test func silenceHasNoBeats() {
        let beats = Self.detectBeats(in: TestSignals.silence(count: Int(Self.sampleRate) * 5))
        #expect(beats.isEmpty)
    }

    @Test func respectsMinInterval() {
        let track = TestSignals.clickTrack(bpm: 480, sampleRate: Self.sampleRate, seconds: 10)
        let beats = Self.detectBeats(in: track.samples)
        #expect(beats.count > 2)
        for (a, b) in zip(beats, beats.dropFirst()) {
            #expect(b - a >= 0.25 - 1e-9)
        }
    }

    @Test func resetForgetsHistory() {
        var detector = BeatDetector()
        for i in 0..<60 {
            _ = detector.process(lowBandAmplitudes: [0.1, 0.1], time: Double(i) / 60)
        }
        detector.reset()
        // После сброса прогрев начинается заново: резкий скачок сразу не считается ударом.
        let first = detector.process(lowBandAmplitudes: [0.1, 0.1], time: 2)
        let jump = detector.process(lowBandAmplitudes: [5, 5], time: 2 + 1.0 / 60)
        #expect(!first)
        #expect(!jump)
    }

    @Test func envelopeDecaysWithin200ms() {
        var envelope = BeatEnvelope()
        envelope.trigger()
        #expect(envelope.value == 1)
        for _ in 0..<12 { envelope.step(dt: 1.0 / 60) }
        #expect(envelope.value < 0.05)
    }
}
