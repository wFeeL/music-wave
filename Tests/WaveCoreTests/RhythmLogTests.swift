import Foundation
import Testing
@testable import WaveCore

/// Запись ритма (`RhythmRecorder`, `RhythmSession`), файл WAV записи и сравнение записи с прогоном
/// на Linux (`RhythmReplay`).
struct RhythmLogTests {
    /// Частота, при которой номера сэмплов легко читать: 1000 сэмплов в секунду.
    static let rate = 1_000.0
    static let startHost = 500.0

    static func meta() -> RhythmLog.Meta {
        RhythmLog.Meta(
            appVersion: "1.1.0", build: "2026102212", commit: "abc1234", swiftVersion: "6.2.3",
            deviceName: "MacBook Pro Speakers", deviceUID: "BuiltInSpeakerDevice", latencyMode: "авто",
            renderPeriod: 1.0 / 60
        )
    }

    /// Шаг анализа: окно `count` сэмплов со значением `value`, кончается на `endSample`.
    static func hop(
        _ recorder: inout RhythmRecorder,
        endSample: Int,
        count: Int = 512,
        value: Float = 0.25,
        latency: Double = 0.02,
        syncOffset: Double = 0.01,
        kick: Double? = nil,
        onset: Double? = nil
    ) {
        let window = [Float](repeating: value, count: count)
        let first = startHost + Double(endSample - count - 88) / rate
        window.withUnsafeBufferPointer {
            recorder.appendHop(
                window: $0, endSample: endSample, firstSampleHost: first, sampleRate: rate,
                outputLatency: latency, syncOffset: syncOffset, kick: kick, onset: onset
            )
        }
    }

    // MARK: Звук

    @Test func firstHopTakesTheWholeWindowAndLaterHopsOnlyNewSamples() {
        var recorder = RhythmRecorder(duration: 1, meta: Self.meta())
        #expect(!recorder.hasStarted)
        Self.hop(&recorder, endSample: 600)
        #expect(recorder.hasStarted)
        #expect(recorder.samples.count == 512)
        Self.hop(&recorder, endSample: 728, value: -0.5)
        #expect(recorder.samples.count == 640)
        #expect(recorder.samples[511] == 8_192)
        #expect(recorder.samples[512] == -16_384)
        // Тот же шаг еще раз ничего не добавляет.
        Self.hop(&recorder, endSample: 728)
        #expect(recorder.samples.count == 640)
        let log = recorder.finish()
        #expect(log.meta.startHostSeconds == Self.startHost)
        #expect(log.meta.sampleRate == Self.rate)
        #expect(log.meta.outputLatency == 0.02)
        #expect(log.meta.syncOffset == 0.01)
        #expect(log.meta.audioSeconds == 0.64)
    }

    @Test func audioIsBoundedToTheDurationAndCompletes() {
        var recorder = RhythmRecorder(duration: 1, meta: Self.meta())
        var end = 600
        while end < 2_000 {
            Self.hop(&recorder, endSample: end)
            end += 128
        }
        #expect(recorder.samples.count == 1_000)
        #expect(recorder.endReason == .complete)
        #expect(recorder.finish().meta.audioSeconds == 1)
        #expect(recorder.finish().meta.endReason == .complete)
    }

    @Test func samplesAreClampedTo16Bit() {
        var recorder = RhythmRecorder(duration: 1, meta: Self.meta())
        let window: [Float] = [2, -2, 1, -1, .nan, 0.5]
        window.withUnsafeBufferPointer {
            recorder.appendHop(
                window: $0, endSample: 6, firstSampleHost: 1, sampleRate: Self.rate,
                outputLatency: 0, syncOffset: 0, kick: nil, onset: nil
            )
        }
        #expect(recorder.samples == [32_767, -32_767, 32_767, -32_767, 0, 16_384])
    }

    @Test func aGapInTheStreamEndsTheRecording() {
        var recorder = RhythmRecorder(duration: 10, meta: Self.meta())
        Self.hop(&recorder, endSample: 600)
        Self.hop(&recorder, endSample: 1_400)
        #expect(recorder.endReason == .gap)
        #expect(recorder.samples.count == 512)
    }

    @Test func changedLatencyOrOffsetEndsTheRecording() {
        var recorder = RhythmRecorder(duration: 10, meta: Self.meta())
        Self.hop(&recorder, endSample: 600)
        Self.hop(&recorder, endSample: 728, syncOffset: 0.03)
        #expect(recorder.endReason == .settingsChanged)
        #expect(recorder.samples.count == 512)
    }

    @Test func firstHopWithoutHostTimeIsSkipped() {
        var recorder = RhythmRecorder(duration: 1, meta: Self.meta())
        let window = [Float](repeating: 0, count: 4)
        window.withUnsafeBufferPointer {
            recorder.appendHop(
                window: $0, endSample: 4, firstSampleHost: nil, sampleRate: Self.rate,
                outputLatency: 0, syncOffset: 0, kick: nil, onset: nil
            )
        }
        #expect(!recorder.hasStarted)
        #expect(recorder.samples.isEmpty)
    }

    // MARK: События

    @Test func kicksAndOnsetsAreOnTheAudibleAxisFromTheFirstSample() {
        var recorder = RhythmRecorder(duration: 10, meta: Self.meta())
        // Первый сэмпл записи 88, то есть 0.088 с потока; слышен через 20 мс.
        Self.hop(&recorder, endSample: 600, kick: 0.5, onset: 0.05)
        Self.hop(&recorder, endSample: 728, kick: 0.6, onset: 0.588)
        let log = recorder.finish()
        #expect(log.kicks.count == 2)
        #expect(abs(log.kicks[0] - 0.432) < 1e-9)
        #expect(abs(log.kicks[1] - 0.532) < 1e-9)
        // Онсет раньше начала записи (0.05 − 0.088 + 0.02 < 0) не пишется.
        #expect(log.onsets.count == 1)
        #expect(abs(log.onsets[0] - 0.52) < 1e-9)
    }

    static func schedule(locked: Bool, bpm: Double?, confidence: Double, beats: [Double], onset: Double? = nil) -> BeatSchedule {
        var events = beats.enumerated().map { GlowEvent(id: UInt64($0.offset), time: $0.element, amplitude: 1, predicted: true) }
        if let onset {
            events.append(GlowEvent(id: BeatTracker.onsetIDFlag | 1, time: onset, amplitude: 1, predicted: false))
        }
        events.sort { $0.time < $1.time }
        return BeatSchedule(events: events, bpm: bpm, period: bpm.map { 60 / $0 }, confidence: confidence, locked: locked)
    }

    @Test func schedulesKeepOnlyChangesAndPredictedBeats() {
        var recorder = RhythmRecorder(duration: 10, meta: Self.meta())
        let early = Self.schedule(locked: false, bpm: nil, confidence: 0.1, beats: [501])
        // До начала записи расписание не пишется.
        recorder.appendSchedule(early, publishedAtHost: 499)
        Self.hop(&recorder, endSample: 600)
        let first = Self.schedule(locked: false, bpm: 120, confidence: 0.3, beats: [501, 501.5], onset: 500.9)
        recorder.appendSchedule(first, publishedAtHost: 500.5)
        // Та же картина чуть позже: не пишется.
        recorder.appendSchedule(first, publishedAtHost: 500.51)
        let nudged = Self.schedule(locked: false, bpm: 120, confidence: 0.304, beats: [501.0002, 501.5002])
        recorder.appendSchedule(nudged, publishedAtHost: 500.52)
        let locked = Self.schedule(locked: true, bpm: 121, confidence: 0.6, beats: [501, 501.5])
        recorder.appendSchedule(locked, publishedAtHost: 500.6)
        let log = recorder.finish()
        #expect(log.schedules.count == 2)
        #expect(log.schedules[0].time == 0.5)
        #expect(log.schedules[0].bpm == 120)
        #expect(log.schedules[0].beats == [1, 1.5])
        #expect(!log.schedules[0].locked)
        #expect(abs(log.schedules[1].time - 0.6) < 1e-9)
        #expect(log.schedules[1].locked)
        #expect(log.schedules[1].confidence == 0.6)
    }

    @Test func flashesFollowTheRiseRuleAndNameTheirSource() {
        var recorder = RhythmRecorder(duration: 10, meta: Self.meta())
        let schedule = Self.schedule(locked: true, bpm: 120, confidence: 0.8, beats: [501, 501.5], onset: 501.2)
        // До начала записи кадры не считаются.
        recorder.appendFrame(presentedHost: 499.9, glowRise: 0.9, schedule: schedule, refreshPeriod: 1.0 / 60)
        Self.hop(&recorder, endSample: 600)
        recorder.appendFrame(presentedHost: 500.99, glowRise: 0.9, schedule: schedule, refreshPeriod: 1.0 / 60)
        recorder.appendFrame(presentedHost: 501.0, glowRise: 0.2, schedule: schedule, refreshPeriod: 1.0 / 60)
        recorder.appendFrame(presentedHost: 501.19, glowRise: 0.5, schedule: schedule, refreshPeriod: 1.0 / 60)
        let unlocked = Self.schedule(locked: false, bpm: nil, confidence: 0, beats: [])
        recorder.appendFrame(presentedHost: 501.3, glowRise: 0.0, schedule: unlocked, refreshPeriod: 1.0 / 60)
        let log = recorder.finish()
        #expect(log.flashes.count == 2)
        #expect(abs(log.flashes[0].time - 0.99) < 1e-9)
        #expect(log.flashes[0].predicted)
        #expect(log.flashes[0].locked)
        #expect(abs(log.flashes[1].time - 1.19) < 1e-9)
        #expect(!log.flashes[1].predicted)
        #expect(log.meta.renderedFrames == 4)
        #expect(log.meta.renderedUntil.map { abs($0 - 1.3) < 1e-9 } == true)
    }

    @Test func flashesAreKeptAfterTheAudioCompletesButNotAfterFinish() {
        var recorder = RhythmRecorder(duration: 0.512, meta: Self.meta())
        Self.hop(&recorder, endSample: 600, kick: 0.5)
        #expect(recorder.endReason == .complete)
        // Звук записан, но вспышки по нему еще впереди (задержка вывода).
        Self.hop(&recorder, endSample: 728, kick: 0.6)
        recorder.appendSchedule(Self.schedule(locked: true, bpm: 120, confidence: 1, beats: []), publishedAtHost: 500.6)
        recorder.appendFrame(presentedHost: 500.53, glowRise: 1, schedule: .empty, refreshPeriod: 1.0 / 60)
        let log = recorder.finish()
        #expect(log.kicks.count == 1)
        #expect(log.schedules.isEmpty)
        #expect(log.flashes.count == 1)
    }

    @Test func finishOnAPartialRecordingKeepsWhatWasRecorded() {
        var recorder = RhythmRecorder(duration: 30, meta: Self.meta())
        Self.hop(&recorder, endSample: 600, kick: 0.5)
        Self.hop(&recorder, endSample: 728)
        recorder.stop(.islandHidden)
        // После остановки анализ ничего не добавляет.
        Self.hop(&recorder, endSample: 856, kick: 0.8)
        recorder.stop(.stopped)
        let log = recorder.finish()
        #expect(log.schemaVersion == 1)
        #expect(log.meta.endReason == .islandHidden)
        #expect(log.meta.duration == 30)
        #expect(log.meta.audioSeconds == 0.64)
        #expect(log.kicks.count == 1)
        #expect(log.meta.renderedUntil == nil)
    }

    @Test func finishWithoutAudioSaysSo() {
        let recorder = RhythmRecorder(duration: 30, meta: Self.meta())
        let log = recorder.finish()
        #expect(log.meta.endReason == .noAudio)
        #expect(log.meta.audioSeconds == 0)
    }

    // MARK: JSON

    @Test func jsonRoundTrip() throws {
        var recorder = RhythmRecorder(duration: 10, meta: Self.meta())
        Self.hop(&recorder, endSample: 600, kick: 0.5, onset: 0.5)
        recorder.appendSchedule(Self.schedule(locked: false, bpm: nil, confidence: 0.1, beats: []), publishedAtHost: 500.2)
        recorder.appendSchedule(Self.schedule(locked: true, bpm: 128, confidence: 0.7, beats: [501]), publishedAtHost: 500.3)
        recorder.appendFrame(presentedHost: 500.99, glowRise: 1, schedule: Self.schedule(locked: true, bpm: 128, confidence: 0.7, beats: [501]), refreshPeriod: 1.0 / 60)
        let log = recorder.finish()
        let data = try log.encoded()
        let decoded = try RhythmLog.decode(data)
        #expect(decoded == log)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(Set(object.keys) == ["schemaVersion", "meta", "kicks", "onsets", "schedules", "flashes"])
        let meta = try #require(object["meta"] as? [String: Any])
        #expect(meta["commit"] as? String == "abc1234")
        #expect(meta["endReason"] as? String == "stopped")
        let schedules = try #require(object["schedules"] as? [[String: Any]])
        // Темпа нет: ключа нет.
        #expect(schedules[0]["bpm"] == nil)
        #expect(schedules[1]["bpm"] as? Double == 128)
    }

    @Test func otherSchemaVersionsAreRejected() throws {
        var log = RhythmRecorder(duration: 1, meta: Self.meta()).finish()
        log.schemaVersion = 2
        let data = try log.encoded()
        #expect(throws: RhythmLog.DecodeError.unsupportedSchema(2)) {
            try RhythmLog.decode(data)
        }
    }

    @Test func fileNamesUseTheStartStamp() {
        let names = RhythmLog.fileNames(stamp: "20261022-153012")
        #expect(names.json == "rhythm-20261022-153012.json")
        #expect(names.wav == "rhythm-20261022-153012.wav")
        #expect(RhythmLog.wavPath(forLogPath: "/tmp/a/rhythm-1.json") == "/tmp/a/rhythm-1.wav")
        #expect(RhythmLog.wavPath(forLogPath: "rhythm") == "rhythm.wav")
    }

    // MARK: Сессия

    @Test func sessionForwardsAndReportsStatus() {
        let session = RhythmSession(RhythmRecorder(duration: 0.512, meta: Self.meta()))
        #expect(session.status == RhythmSession.Status(started: false, audioSeconds: 0, endReason: nil, audibleEndHost: nil))
        let window = [Float](repeating: 0.1, count: 512)
        window.withUnsafeBufferPointer {
            session.appendHop(
                window: $0, endSample: 600, firstSampleHost: 10, sampleRate: Self.rate,
                outputLatency: 0.02, syncOffset: 0.01, kick: nil, onset: nil
            )
        }
        session.appendFrame(presentedHost: 10.3, glowRise: 0.5, schedule: .empty, refreshPeriod: 1.0 / 60)
        let status = session.status
        #expect(status.started)
        #expect(status.endReason == .complete)
        #expect(status.audioSeconds == 0.512)
        #expect(status.audibleEndHost.map { abs($0 - 10.542) < 1e-9 } == true)
        let (log, samples) = session.finish()
        #expect(samples.count == 512)
        #expect(log.flashes.count == 1)
    }

    // MARK: WAV

    @Test func wavRoundTripThroughTheReader() throws {
        let samples: [Int16] = [0, 16_384, -32_768, 32_767, -1]
        let data = WAVWriter.pcm16Mono(samples, sampleRate: 48_000)
        #expect(data.count == 44 + samples.count * 2)
        let (read, rate) = try WAVReader.read(data)
        #expect(rate == 48_000)
        #expect(read == samples.map { Float($0) / 32_768 })
    }

    // MARK: Сравнение

    @Test func comparisonMatchesOneToOneWithinTheWindow() {
        let device = [1.0, 1.51, 2.0, 2.9, 4.0]
        let replay = [1.01, 1.5, 2.04, 3.0, 4.0, 5.0]
        let comparison = RhythmReplay.compare(device: device, replay: replay, window: 0.03)
        #expect(comparison.deviceCount == 5)
        #expect(comparison.replayCount == 6)
        #expect(comparison.matched == 3)
        #expect(abs(comparison.matchedShare - 0.6) < 1e-12)
        let differences = [-0.01, 0.01, 0.0]
        let mean = differences.reduce(0, +) / 3
        #expect(comparison.meanDifference.map { abs($0 - mean) < 1e-12 } == true)
        #expect(comparison.p95Difference.map { abs($0 - 0.01) < 1e-12 } == true)
        #expect(comparison.p95AbsoluteDifference.map { abs($0 - 0.01) < 1e-12 } == true)
    }

    @Test func comparisonPrefersTheNearestReplayFlash() {
        let comparison = RhythmReplay.compare(device: [1.0], replay: [0.98, 1.005, 1.02], window: 0.03)
        #expect(comparison.matched == 1)
        #expect(comparison.meanDifference.map { abs($0 + 0.005) < 1e-12 } == true)
    }

    @Test func emptyComparison() {
        let comparison = RhythmReplay.compare(device: [], replay: [1], window: 0.03)
        #expect(comparison.matched == 0)
        #expect(comparison.matchedShare == 0)
        #expect(comparison.meanDifference == nil)
        #expect(comparison.p95Difference == nil)
    }

    @Test func timelineOfDeviceSchedules() {
        let schedules = [
            RhythmLog.Schedule(time: 0.5, bpm: nil, confidence: 0.1, locked: false, beats: []),
            RhythmLog.Schedule(time: 2, bpm: 120, confidence: 0.5, locked: true, beats: []),
            RhythmLog.Schedule(time: 6, bpm: 124, confidence: 0.2, locked: false, beats: []),
            RhythmLog.Schedule(time: 8, bpm: 122, confidence: 0.6, locked: true, beats: []),
        ]
        let timeline = RhythmReplay.Timeline(schedules: schedules, end: 10)
        #expect(timeline.firstLock == 2)
        #expect(abs(timeline.lockedShare - 0.6) < 1e-12)
        #expect(timeline.lockChanges == 3)
        #expect(timeline.lastBPM == 122)
        #expect(timeline.medianLockedBPM == 121)
    }

    @Test func timelineWithoutSchedules() {
        let timeline = RhythmReplay.Timeline(schedules: [], end: 10)
        #expect(timeline.firstLock == nil)
        #expect(timeline.lockedShare == 0)
        #expect(timeline.lastBPM == nil)
    }

    /// Запись "с устройства" здесь делает та же офлайн-цепочка с другой фазой рендера: прогон по
    /// записанному WAV должен найти почти те же вспышки (в пределах кадра).
    @Test(.enabled(if: TestPlatform.isLinux))
    func replayOfASyntheticRecordingMatchesTheDevice() throws {
        let scene = Drums.fourOnFloor(bpm: 120, seconds: 16, hats: .eighths)
        var config = OfflineBeatChain.Config(seed: 7)
        config.outputLatency = 0.03
        config.syncOffset = 0.01
        config.renderPhase = 0.3
        let device = OfflineBeatChain.run(samples: scene.samples, sampleRate: scene.sampleRate, config: config)
        #expect(device.flashes.count > 20)

        var meta = Self.meta()
        meta.outputLatency = config.outputLatency
        meta.syncOffset = config.syncOffset
        meta.sampleRate = scene.sampleRate
        meta.renderPeriod = 1 / config.renderRate
        meta.duration = 16
        meta.audioSeconds = Double(scene.samples.count) / scene.sampleRate
        meta.renderedUntil = meta.audioSeconds + config.outputLatency
        meta.endReason = .complete
        let log = RhythmLog(
            meta: meta,
            kicks: device.kickOnsets,
            onsets: [],
            schedules: device.states.map {
                RhythmLog.Schedule(time: $0.time, bpm: $0.bpm, confidence: $0.confidence, locked: $0.locked, beats: [])
            },
            flashes: device.flashes.map { RhythmLog.Flash(time: $0.time, predicted: $0.predicted, locked: $0.locked) }
        )
        let samples = scene.samples.map { RhythmRecorder.pcm16($0) }
        let wav = WAVWriter.pcm16Mono(samples, sampleRate: Int(scene.sampleRate))

        let report = try RhythmReplay.replay(logData: try log.encoded(), wavData: wav, options: RhythmReplay.Options(seed: 3))
        #expect(report.all.deviceCount > 20)
        #expect(report.all.matchedShare > 0.9)
        #expect(report.all.meanDifference.map { abs($0) < 0.017 } == true)
        #expect(report.device.firstLock != nil)
        #expect(report.replay.firstLock != nil)
        let text = report.text
        #expect(text.contains("matched"))
        #expect(text.contains("device"))
        #expect(text.contains("replay"))
    }

    @Test func replayArguments() throws {
        let parsed = try RhythmReplay.Arguments.parse([
            "--replay", "/tmp/rhythm-1.json", "--seed", "9", "--window-ms", "20", "--tracker", "alpha=0.5", "--list",
        ])
        #expect(parsed.logPath == "/tmp/rhythm-1.json")
        #expect(parsed.options.seed == 9)
        #expect(parsed.options.window == 0.02)
        #expect(parsed.options.trackerParameters.alpha == 0.5)
        #expect(parsed.options.listFlashes)
        #expect(throws: EvalArguments.Error.missingValue("--replay")) {
            try RhythmReplay.Arguments.parse(["--seed", "1"])
        }
        #expect(throws: EvalArguments.Error.unknownTrackerParameter("nope")) {
            try RhythmReplay.Arguments.parse(["--replay", "a.json", "--tracker", "nope=1"])
        }
        #expect(throws: EvalArguments.Error.unknownOption("--json")) {
            try RhythmReplay.Arguments.parse(["--replay", "a.json", "--json"])
        }
        #expect(try RhythmReplay.Arguments.parse(["--help"]).help)
    }

    @Test func replayRejectsAWAVWithAnotherSampleRate() throws {
        var meta = Self.meta()
        meta.sampleRate = 48_000
        meta.audioSeconds = 0.01
        let log = RhythmLog(meta: meta, kicks: [], onsets: [], schedules: [], flashes: [])
        let wav = WAVWriter.pcm16Mono([Int16](repeating: 0, count: 441), sampleRate: 44_100)
        #expect(throws: RhythmReplay.Error.sampleRateMismatch(log: 48_000, wav: 44_100)) {
            try RhythmReplay.replay(logData: try log.encoded(), wavData: wav, options: RhythmReplay.Options())
        }
    }
}
