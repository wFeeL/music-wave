import Foundation
import Testing
@testable import WaveCore

/// Длина записи ритма: допустимые секунды, подписи, разбор ввода, длинная запись и ее WAV.
struct RhythmRecordingLengthTests {
    @Test func rangePresetsAndDefault() {
        #expect(RhythmRecordingLength.range == 10...600)
        #expect(RhythmRecordingLength.defaultSeconds == 120)
        #expect(RhythmRecordingLength.presets == [30, 60, 120, 300])
        #expect(RhythmRecordingLength.presets.allSatisfy { RhythmRecordingLength.range.contains($0) })
        #expect(RhythmRecordingLength.range.contains(RhythmRecordingLength.defaultSeconds))
    }

    @Test func normalizedClamps() {
        #expect(RhythmRecordingLength.normalized(5) == 10)
        #expect(RhythmRecordingLength.normalized(-3) == 10)
        #expect(RhythmRecordingLength.normalized(45) == 45)
        #expect(RhythmRecordingLength.normalized(601) == 600)
        #expect(RhythmRecordingLength.normalized(Int.max) == 600)
        #expect(RhythmRecordingLength.normalized(44.6) == 45)
        #expect(RhythmRecordingLength.normalized(1e12) == 600)
        #expect(RhythmRecordingLength.normalized(Double.nan) == 120)
        #expect(RhythmRecordingLength.normalized(Double.infinity) == 120)
    }

    @Test func combineMinutesAndSeconds() {
        #expect(RhythmRecordingLength.combine(minutes: 2, seconds: 0) == 120)
        #expect(RhythmRecordingLength.combine(minutes: 0, seconds: 45) == 45)
        #expect(RhythmRecordingLength.combine(minutes: 1, seconds: 30) == 90)
        #expect(RhythmRecordingLength.combine(minutes: 0, seconds: 90) == 90)
        #expect(RhythmRecordingLength.combine(minutes: 0, seconds: 3) == 10)
        #expect(RhythmRecordingLength.combine(minutes: 0, seconds: 0) == 10)
        #expect(RhythmRecordingLength.combine(minutes: -4, seconds: 20) == 20)
        #expect(RhythmRecordingLength.combine(minutes: 11, seconds: 0) == 600)
        #expect(RhythmRecordingLength.combine(minutes: Int.max, seconds: Int.max) == 600)
        #expect(RhythmRecordingLength.combine(minutes: 0, seconds: Int.max) == 600)
    }

    @Test func texts() {
        #expect(RhythmRecordingLength.text(seconds: 30) == "30 с")
        #expect(RhythmRecordingLength.text(seconds: 60) == "1 мин")
        #expect(RhythmRecordingLength.text(seconds: 125) == "2 мин 5 с")
        #expect(RhythmRecordingLength.text(seconds: -5) == "0 с")
        #expect(RhythmRecordingLength.buttonTitle(seconds: 120) == "Записать 2 мин")
        #expect(RhythmRecordingLength.buttonTitle(seconds: 45) == "Записать 45 с")
        #expect(RhythmRecordingLength.buttonTitle(seconds: 90) == "Записать 1 мин 30 с")
        #expect(RhythmRecordingLength.progressTitle(seconds: 7) == "Запись… 7 с")
        #expect(RhythmRecordingLength.progressTitle(seconds: 65) == "Запись… 1 мин 5 с")
        for seconds in RhythmRecordingLength.presets + [RhythmRecordingLength.defaultSeconds] {
            let title = RhythmRecordingLength.buttonTitle(seconds: seconds)
            #expect(!title.contains("—") && !title.contains("ё") && !title.contains("·") && !title.contains("•"))
        }
    }

    /// Запись длиннее 30 с: звук, онсеты и вспышки после 30-й секунды сохраняются, журнал
    /// читается обратно, метки длины совпадают.
    @Test func recorderKeepsAudioPastThirtySeconds() throws {
        let rate = RhythmLogTests.rate
        var recorder = RhythmRecorder(duration: 95, meta: RhythmLogTests.meta())
        var end = 512
        while recorder.endReason == nil, end < 200_000 {
            let seconds = Double(end) / rate
            RhythmLogTests.hop(&recorder, endSample: end, kick: seconds > 60 ? seconds - 0.1 : nil)
            end += 512
        }
        #expect(recorder.endReason == .complete)
        #expect(recorder.samples.count == 95_000)
        recorder.appendFrame(presentedHost: RhythmLogTests.startHost + 70, glowRise: 0.5, schedule: .empty, refreshPeriod: 1.0 / 60)
        let log = recorder.finish()
        #expect(log.meta.duration == 95)
        #expect(log.meta.audioSeconds == 95)
        #expect(log.kicks.contains { $0 > 60 })
        #expect(log.flashes.count == 1)
        #expect(log.flashes.first.map { $0.time > 69 } == true)
        let decoded = try RhythmLog.decode(try log.encoded())
        #expect(decoded == log)
        #expect(decoded.meta.duration == 95 && decoded.meta.audioSeconds == 95)
    }

    /// Журнал на 45 с проходит прогон: отрезок сравнения не обрезается на 30 с.
    @Test(.enabled(if: TestPlatform.isLinux))
    func replayHandlesALogLongerThanThirtySeconds() throws {
        let scene = Drums.fourOnFloor(bpm: 120, seconds: 45, hats: .eighths)
        var config = OfflineBeatChain.Config(seed: 7)
        config.outputLatency = 0.03
        config.renderPhase = 0.3
        let device = OfflineBeatChain.run(samples: scene.samples, sampleRate: scene.sampleRate, config: config)
        var meta = RhythmLogTests.meta()
        meta.outputLatency = config.outputLatency
        meta.sampleRate = scene.sampleRate
        meta.renderPeriod = 1 / config.renderRate
        meta.duration = 45
        meta.audioSeconds = Double(scene.samples.count) / scene.sampleRate
        meta.renderedUntil = meta.audioSeconds + config.outputLatency
        meta.endReason = .complete
        let log = RhythmLog(
            meta: meta,
            kicks: device.kickOnsets,
            onsets: [],
            schedules: [],
            flashes: device.flashes.map { RhythmLog.Flash(time: $0.time, predicted: $0.predicted, locked: $0.locked) }
        )
        let samples = scene.samples.map { RhythmRecorder.pcm16($0) }
        let wav = WAVWriter.pcm16Mono(samples, sampleRate: Int(scene.sampleRate))
        let report = try RhythmReplay.replay(logData: try log.encoded(), wavData: wav, options: RhythmReplay.Options(seed: 3))
        #expect(report.until > 44)
        #expect(report.all.deviceCount > 60)
        #expect(report.deviceFlashes.contains { $0.time > 35 })
        #expect(report.all.matchedShare > 0.9)
    }

    /// Запись WAV кусками дает те же байты, что `pcm16Mono`, и не оставляет временного файла.
    @Test func chunkedWAVMatchesTheInMemoryWriter() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wf-wav-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let samples = (0..<1_001).map { Int16(truncatingIfNeeded: $0 * 97 - 30_000) }
        let url = directory.appendingPathComponent("a.wav")
        try WAVWriter.write(samples, sampleRate: 44_100, to: url, chunkSamples: 100)
        #expect(try Data(contentsOf: url) == WAVWriter.pcm16Mono(samples, sampleRate: 44_100))
        // Повторная запись заменяет файл.
        try WAVWriter.write([1, 2, 3], sampleRate: 8_000, to: url)
        #expect(try Data(contentsOf: url) == WAVWriter.pcm16Mono([1, 2, 3], sampleRate: 8_000))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["a.wav"])
        // Пустой звук: один заголовок.
        try WAVWriter.write([], sampleRate: 8_000, to: url)
        #expect(try Data(contentsOf: url).count == 44)
    }
}
