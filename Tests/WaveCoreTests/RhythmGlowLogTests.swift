import Foundation
import Testing
@testable import WaveCore

/// Режим свечения в записи ритма: `Meta.glowMode`, метка `Flash.reactive`, прогон в режиме записи и
/// единая точка настройки режима (`GlowMode.apply`).
struct RhythmGlowLogTests {
    /// Расписание с одной долей и одним реактивным событием.
    static func schedule(beat: Double, reactive: Double) -> BeatSchedule {
        let events = [
            GlowEvent(id: 1, time: beat, amplitude: 1, predicted: true),
            GlowEvent(id: BeatTracker.reactiveIDFlag | 1, time: reactive, amplitude: 0.5, predicted: false, reactive: true),
        ]
        return BeatSchedule(events: events, bpm: 120, period: 0.5, confidence: 0.8, locked: true)
    }

    @Test func recorderMarksFlashesStartedByReactiveEvents() throws {
        var meta = RhythmLogTests.meta()
        meta.glowMode = GlowMode.hybrid.rawValue
        var recorder = RhythmRecorder(duration: 10, meta: meta)
        RhythmLogTests.hop(&recorder, endSample: 600)
        let schedule = Self.schedule(beat: 501, reactive: 501.4)
        recorder.appendFrame(presentedHost: 500.99, glowRise: 0.9, schedule: schedule, refreshPeriod: 1.0 / 60)
        recorder.appendFrame(presentedHost: 501.45, glowRise: 0.5, schedule: schedule, refreshPeriod: 1.0 / 60)
        let log = recorder.finish()
        #expect(log.flashes.count == 2)
        #expect(log.flashes[0].predicted && log.flashes[0].reactive != true)
        #expect(!log.flashes[1].predicted && log.flashes[1].reactive == true)
        #expect(log.meta.glowMode == "hybrid")
        #expect(try RhythmLog.decode(try log.encoded()) == log)
    }

    @Test func rhythmFlashesWriteNoReactiveKey() throws {
        var recorder = RhythmRecorder(duration: 10, meta: RhythmLogTests.meta())
        RhythmLogTests.hop(&recorder, endSample: 600)
        let schedule = RhythmLogTests.schedule(locked: true, bpm: 120, confidence: 0.8, beats: [501], onset: 501.2)
        recorder.appendFrame(presentedHost: 501.0, glowRise: 0.9, schedule: schedule, refreshPeriod: 1.0 / 60)
        let log = recorder.finish()
        #expect(log.flashes.count == 1 && log.flashes[0].reactive == nil && log.meta.glowMode == nil)
        let text = String(decoding: try log.encoded(), as: UTF8.self)
        #expect(!text.contains("reactive") && !text.contains("glowMode"))
    }

    @Test func oldLogsReadAsRhythm() throws {
        for version in [1, 2] {
            let old = Data(
                """
                {"schemaVersion": \(version), "kicks": [], "onsets": [],
                 "flashes": [{"time": 1, "predicted": true, "locked": true}],
                 "meta": {"appVersion": "1.2.0", "build": "1", "commit": "abc1234", "swiftVersion": "6.2.3",
                          "deviceName": "d", "deviceUID": "u", "latencyMode": "auto", "outputLatency": 0.02,
                          "syncOffset": 0, "sampleRate": 48000, "renderPeriod": 0.0166, "reduceMotion": false,
                          "glowIntensity": 1, "beatPulse": true, "lowPower": false, "clippedSamples": 0,
                          "startHostSeconds": 100, "duration": 30, "audioSeconds": 30, "renderedFrames": 1800,
                          "renderedUntil": 30, "endReason": "complete"},
                 "schedules": []}
                """.utf8
            )
            let log = try RhythmLog.decode(old)
            #expect(log.schemaVersion == version)
            #expect(log.meta.glowMode == nil && log.flashes[0].reactive == nil)
            let config = RhythmReplay.config(for: log.meta, options: RhythmReplay.Options())
            #expect(config.glowMode == .rhythm)
        }
    }

    @Test func replayConfigTakesTheRecordedMode() {
        var meta = RhythmLogTests.meta()
        for mode in GlowMode.allCases {
            meta.glowMode = mode.rawValue
            #expect(RhythmReplay.config(for: meta, options: RhythmReplay.Options()).glowMode == mode)
        }
        meta.glowMode = "future-mode"
        #expect(RhythmReplay.config(for: meta, options: RhythmReplay.Options()).glowMode == .rhythm)
    }

    @Test func changingTheModeEndsTheRecording() {
        var meta = RhythmLogTests.meta()
        meta.glowMode = GlowMode.hybrid.rawValue
        var recorder = RhythmRecorder(duration: 10, meta: meta)
        RhythmLogTests.hop(&recorder, endSample: 600)
        recorder.noteGlowMode(.hybrid)
        #expect(recorder.endReason == nil)
        recorder.noteGlowMode(.sound)
        #expect(recorder.endReason == .settingsChanged)
        let session = RhythmSession(RhythmRecorder(duration: 10, meta: meta))
        session.noteGlowMode(.rhythm)
        #expect(session.status.endReason == .settingsChanged)
    }

    @Test(arguments: GlowMode.allCases)
    func applyConfiguresAnalyzerAndTrackerTogether(mode: GlowMode) {
        let analyzer = StreamAnalyzer(sampleRate: 48_000)
        var tracker = BeatTracker(framesPerSecond: analyzer.config.framesPerSecond)
        mode.apply(to: analyzer, tracker: &tracker)
        #expect(tracker.glowMode == mode)
        #expect(analyzer.measuresBassLevel == (mode != .rhythm))
        GlowMode.rhythm.apply(to: analyzer, tracker: &tracker)
        #expect(tracker.glowMode == .rhythm && !analyzer.measuresBassLevel)
    }

    @Test func reportSplitsFlashesIntoGridAndReactive() {
        let meta = RhythmLogTests.meta()
        let device = [
            RhythmLog.Flash(time: 1, predicted: true, locked: true),
            RhythmLog.Flash(time: 2, predicted: false, locked: true, reactive: true),
            RhythmLog.Flash(time: 3, predicted: false, locked: true, reactive: true),
        ]
        let replay = [
            OfflineBeatChain.Flash(time: 1, predicted: true, locked: true),
            OfflineBeatChain.Flash(time: 2, predicted: false, locked: true, reactive: true),
        ]
        let timeline = RhythmReplay.Timeline(schedules: [], end: 10)
        let comparison = RhythmReplay.compare(device: [], replay: [], window: 0.03)
        let report = RhythmReplay.Report(
            meta: meta, options: RhythmReplay.Options(), until: 10, all: comparison, afterLock: nil, afterLockFrom: nil,
            device: timeline, replay: timeline, deviceFlashes: device, replayFlashes: replay, replayAmbientShare: 0, replayAmbientPeak: 0
        )
        #expect(report.text.contains("grid/reactive flashes: device 1/2, replay 1/1"))
        #expect(report.text.contains("glow mode: rhythm"))
    }
}
