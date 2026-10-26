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
        #expect(recorder.finish().meta.clippedSamples == 2)
    }

    @Test func reduceMotionOnAFrameIsKept() {
        let session = RhythmSession(RhythmRecorder(duration: 1, meta: Self.meta()))
        #expect(!session.finish().log.meta.reduceMotion)
        session.noteReduceMotion()
        #expect(session.finish().log.meta.reduceMotion)
    }

    @Test func startedEventKeepsTheLatestStartedAndTheFirstOnTies() {
        let events = [
            GlowEvent(id: 1, time: 1.0, amplitude: 1, predicted: false),
            GlowEvent(id: 2, time: 1.2, amplitude: 1, predicted: true),
            GlowEvent(id: 3, time: 1.2, amplitude: 1, predicted: false),
            GlowEvent(id: 4, time: .nan, amplitude: 1, predicted: false),
            GlowEvent(id: 5, time: 2.0, amplitude: 1, predicted: false),
        ]
        let schedule = BeatSchedule(events: events, bpm: nil, period: nil, confidence: 0, locked: false)
        #expect(OfflineBeatChain.startedEvent(in: schedule, by: 1.19, refreshPeriod: 1.0 / 60)?.id == 2)
        #expect(OfflineBeatChain.startedEvent(in: schedule, by: 1.1, refreshPeriod: 1.0 / 60)?.id == 1)
        #expect(OfflineBeatChain.startedEvent(in: schedule, by: 0.5, refreshPeriod: 1.0 / 60) == nil)
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
        #expect(log.schemaVersion == RhythmLog.currentSchemaVersion)
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
        #expect(object["schemaVersion"] as? Int == 2)
        #expect(Set(object.keys) == ["schemaVersion", "meta", "kicks", "onsets", "schedules", "flashes"])
        let meta = try #require(object["meta"] as? [String: Any])
        #expect(meta["commit"] as? String == "abc1234")
        #expect(meta["endReason"] as? String == "stopped")
        let schedules = try #require(object["schedules"] as? [[String: Any]])
        // Темпа нет: ключа нет.
        #expect(schedules[0]["bpm"] == nil)
        #expect(schedules[1]["bpm"] as? Double == 128)
    }

    /// Журнал 1.1 без поля причины потери захвата читается, причина у его расписаний `nil`; новый
    /// журнал пишет причину только у расписаний без захвата после его потери.
    @Test func rhythmLogDecodesWithoutUnlockReason() throws {
        let old = Data(
            """
            {"schemaVersion": 1, "kicks": [0.5], "onsets": [0.5], "flashes": [],
             "meta": {"appVersion": "1.1.0", "build": "1", "commit": "abc1234", "swiftVersion": "6.2.3",
                      "deviceName": "d", "deviceUID": "u", "latencyMode": "auto", "outputLatency": 0.02,
                      "syncOffset": 0, "sampleRate": 48000, "renderPeriod": 0.0166, "reduceMotion": false,
                      "glowIntensity": 1, "beatPulse": true, "lowPower": false, "clippedSamples": 0,
                      "startHostSeconds": 100, "duration": 30, "audioSeconds": 30, "renderedFrames": 1800,
                      "renderedUntil": 30, "endReason": "complete"},
             "schedules": [{"time": 1, "bpm": 120, "confidence": 0.7, "locked": true, "beats": [1.2]},
                           {"time": 2, "bpm": 120, "confidence": 0.2, "locked": false, "beats": [2.2]}]}
            """.utf8
        )
        let log = try RhythmLog.decode(old)
        #expect(log.schedules.count == 2)
        #expect(log.schedules.allSatisfy { $0.unlockReason == nil })

        var recorder = RhythmRecorder(duration: 10, meta: Self.meta())
        Self.hop(&recorder, endSample: 600)
        recorder.appendSchedule(Self.schedule(locked: true, bpm: 120, confidence: 0.7, beats: [501]), publishedAtHost: 500.3)
        var lost = Self.schedule(locked: false, bpm: 120, confidence: 0.2, beats: [501.5])
        lost.unlockReason = .phaseJump
        recorder.appendSchedule(lost, publishedAtHost: 500.8)
        var reset = Self.schedule(locked: false, bpm: nil, confidence: 0, beats: [])
        reset.unlockReason = .reset
        recorder.appendSchedule(reset, publishedAtHost: 501.2)
        let data = try recorder.finish().encoded()
        let decoded = try RhythmLog.decode(data)
        #expect(decoded.schedules.map(\.unlockReason) == [nil, .phaseJump, .reset])
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let schedules = try #require(object["schedules"] as? [[String: Any]])
        #expect(schedules[0]["unlockReason"] == nil)
        #expect(schedules[1]["unlockReason"] as? String == "phaseJump")
        #expect(schedules[2]["unlockReason"] as? String == "reset")
    }

    /// Вес показа пишется в расписания (новое расписание, когда вес сменился на 0.02 и больше), мягкий
    /// пульс кадров в итог записи (кадров с пульсом от `ambientVisible` и пик), выключатель пульса в
    /// meta. Журнал без этих полей (1.1 и B4) читается с `nil`, ключи `nil` не пишутся.
    @Test func weightAndSoftPulseAreOptional() throws {
        let old = Data(
            """
            {"schemaVersion": 1, "kicks": [], "onsets": [], "flashes": [],
             "meta": {"appVersion": "1.1.0", "build": "1", "commit": "abc1234", "swiftVersion": "6.2.3",
                      "deviceName": "d", "deviceUID": "u", "latencyMode": "auto", "outputLatency": 0.02,
                      "syncOffset": 0, "sampleRate": 48000, "renderPeriod": 0.0166, "reduceMotion": false,
                      "glowIntensity": 1, "beatPulse": true, "lowPower": false, "clippedSamples": 0,
                      "startHostSeconds": 100, "duration": 30, "audioSeconds": 30, "renderedFrames": 1800,
                      "renderedUntil": 30, "endReason": "complete"},
             "schedules": [{"time": 1, "bpm": 120, "confidence": 0.7, "locked": true, "beats": [1.2]}]}
            """.utf8
        )
        let decodedOld = try RhythmLog.decode(old)
        #expect(decodedOld.schedules.map(\.weight) == [nil])
        #expect(decodedOld.meta.softPulse == nil)
        #expect(decodedOld.meta.ambientFrames == nil && decodedOld.meta.ambientPeak == nil)

        var meta = Self.meta()
        meta.softPulse = true
        var recorder = RhythmRecorder(duration: 10, meta: meta)
        Self.hop(&recorder, endSample: 600)
        func weighted(_ weight: Float) -> BeatSchedule {
            var schedule = Self.schedule(locked: false, bpm: 120, confidence: 0.4, beats: [501])
            schedule.weight = weight
            return schedule
        }
        recorder.appendSchedule(weighted(0.3), publishedAtHost: 500.2)
        // Вес сдвинулся меньше чем на 0.02: картина та же.
        recorder.appendSchedule(weighted(0.31), publishedAtHost: 500.21)
        recorder.appendSchedule(weighted(0.35), publishedAtHost: 500.22)
        recorder.appendFrame(presentedHost: 500.3, glowRise: 0, schedule: .empty, refreshPeriod: 1.0 / 60, ambient: 0.12)
        recorder.appendFrame(presentedHost: 500.32, glowRise: 0, schedule: .empty, refreshPeriod: 1.0 / 60, ambient: 0.01)
        recorder.appendFrame(presentedHost: 500.34, glowRise: 0, schedule: .empty, refreshPeriod: 1.0 / 60, ambient: .nan)
        recorder.appendFrame(presentedHost: 500.36, glowRise: 0, schedule: .empty, refreshPeriod: 1.0 / 60)
        let log = recorder.finish()
        #expect(log.schedules.map(\.weight) == [0.3, 0.35])
        #expect(log.meta.softPulse == true)
        #expect(log.meta.renderedFrames == 4)
        #expect(log.meta.ambientFrames == 1)
        #expect(log.meta.ambientPeak == 0.12)
        let data = try log.encoded()
        #expect(try RhythmLog.decode(data) == log)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let schedules = try #require(object["schedules"] as? [[String: Any]])
        #expect(schedules[0]["weight"] != nil)
        let encodedMeta = try #require(object["meta"] as? [String: Any])
        #expect(encodedMeta["softPulse"] as? Bool == true)

        // Без пульса на кадрах (старые вызовы) итога пульса нет.
        var plain = RhythmRecorder(duration: 10, meta: Self.meta())
        Self.hop(&plain, endSample: 600)
        plain.appendFrame(presentedHost: 500.3, glowRise: 0, schedule: .empty, refreshPeriod: 1.0 / 60)
        let plainData = try plain.finish().encoded()
        let plainObject = try #require(try JSONSerialization.jsonObject(with: plainData) as? [String: Any])
        let plainMeta = try #require(plainObject["meta"] as? [String: Any])
        #expect(plainMeta["softPulse"] == nil && plainMeta["ambientFrames"] == nil && plainMeta["ambientPeak"] == nil)
    }

    /// Читаются схемы 1 (до 1.3) и 2 (гонка фаз и яркость долей), другие нет.
    @Test func otherSchemaVersionsAreRejected() throws {
        #expect(RhythmLog.currentSchemaVersion == 2)
        for version in [0, 3] {
            var log = RhythmRecorder(duration: 1, meta: Self.meta()).finish()
            log.schemaVersion = version
            let data = try log.encoded()
            #expect(throws: RhythmLog.DecodeError.unsupportedSchema(version)) {
                try RhythmLog.decode(data)
            }
        }
        var old = RhythmRecorder(duration: 1, meta: Self.meta()).finish()
        old.schemaVersion = 1
        #expect(try RhythmLog.decode(try old.encoded()).schemaVersion == 1)
    }

    /// Схема 2: у расписания яркость каждой предсказанной доли (как ее опубликовал трекер, с гонкой и
    /// весом), доля тени и множитель гонки, пока идет гонка, и отношение гребенки последней проверки.
    /// Новая строка пишется, когда начинается или кончается гонка, яркость доли меняется на 0.02 и больше
    /// или отношение гребенки на 0.01 и больше. Журнал 1.2 (схема 1) без этих полей читается с `nil`,
    /// незнакомые поля meta (например, `flashLength` из параллельной задачи) не мешают.
    @Test func raceStateAndBeatAmplitudesAreLogged() throws {
        var recorder = RhythmRecorder(duration: 10, meta: Self.meta())
        Self.hop(&recorder, endSample: 600)
        func published(_ amplitude: Float, race: RaceInfo? = nil, ratio: Double? = 1.02) -> BeatSchedule {
            var schedule = Self.schedule(locked: true, bpm: 120, confidence: 0.9, beats: [501, 501.5], onset: 500.9)
            for index in schedule.events.indices where schedule.events[index].predicted {
                schedule.events[index].amplitude = amplitude
            }
            schedule.race = race
            schedule.combRatio = ratio
            return schedule
        }
        recorder.appendSchedule(published(0.8), publishedAtHost: 500.2)
        // Яркость на 0.01 и отношение на 0.005: та же картина.
        recorder.appendSchedule(published(0.81, ratio: 1.025), publishedAtHost: 500.21)
        recorder.appendSchedule(published(0.16, race: RaceInfo(shadow: 501.25, dim: 0.2), ratio: 1.4), publishedAtHost: 500.22)
        recorder.appendSchedule(published(0.16, race: RaceInfo(shadow: 501.25, dim: 0.2), ratio: 1.3), publishedAtHost: 500.23)
        recorder.appendSchedule(published(0.8, ratio: 1.3), publishedAtHost: 500.24)
        let log = recorder.finish()
        #expect(log.schemaVersion == 2)
        #expect(log.schedules.count == 4)
        #expect(log.schedules.map(\.amplitudes) == [[0.8, 0.8], [0.16, 0.16], [0.16, 0.16], [0.8, 0.8]])
        #expect(log.schedules.map(\.combRatio) == [1.02, 1.4, 1.3, 1.3])
        #expect(log.schedules[0].race == nil)
        let race = try #require(log.schedules[1].race)
        // Доля тени на оси записи, как доли расписания.
        #expect(abs(race.shadow - 1.25) < 1e-9)
        #expect(race.dim == 0.2)
        #expect(log.schedules[3].race == nil)
        let data = try log.encoded()
        #expect(try RhythmLog.decode(data) == log)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let schedules = try #require(object["schedules"] as? [[String: Any]])
        #expect(schedules[0]["race"] == nil)
        #expect(schedules[1]["race"] != nil)

        let old = Data(
            """
            {"schemaVersion": 1, "kicks": [], "onsets": [], "flashes": [],
             "meta": {"appVersion": "1.2.0", "build": "1", "commit": "25cb42f", "swiftVersion": "6.2.3",
                      "deviceName": "d", "deviceUID": "u", "latencyMode": "auto", "outputLatency": 0.134,
                      "syncOffset": -0.03, "sampleRate": 44100, "renderPeriod": 0.0166, "reduceMotion": false,
                      "glowIntensity": 1, "beatPulse": true, "softPulse": true, "lowPower": false, "clippedSamples": 0,
                      "startHostSeconds": 100, "duration": 30, "audioSeconds": 30, "renderedFrames": 1800,
                      "renderedUntil": 30, "ambientFrames": 10, "ambientPeak": 0.1, "endReason": "complete",
                      "flashLength": 1.5},
             "schedules": [{"time": 1, "bpm": 120, "confidence": 0.7, "locked": true, "beats": [1.2], "weight": 1}]}
            """.utf8
        )
        let decoded = try RhythmLog.decode(old)
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.schedules.count == 1)
        #expect(decoded.schedules[0].amplitudes == nil && decoded.schedules[0].race == nil && decoded.schedules[0].combRatio == nil)
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
            RhythmLog.Schedule(time: 6, bpm: 124, confidence: 0.2, locked: false, beats: [], unlockReason: .misses),
            RhythmLog.Schedule(time: 8, bpm: 122, confidence: 0.6, locked: true, beats: []),
            RhythmLog.Schedule(time: 9, bpm: 122, confidence: 0.3, locked: false, beats: []),
            RhythmLog.Schedule(time: 9.5, bpm: 122, confidence: 0.8, locked: true, beats: []),
            RhythmLog.Schedule(time: 9.8, bpm: 122, confidence: 0, locked: false, beats: [], unlockReason: .reset),
        ]
        let timeline = RhythmReplay.Timeline(schedules: schedules, end: 10)
        #expect(timeline.firstLock == 2)
        #expect(abs(timeline.lockedShare - 0.53) < 1e-12)
        #expect(timeline.lockChanges == 6)
        #expect(timeline.lastBPM == 122)
        #expect(timeline.medianLockedBPM == 122)
        // Потери захвата по времени; у журнала 1.1 причины нет.
        #expect(
            timeline.unlocks == [.init(time: 6, reason: .misses), .init(time: 9, reason: nil), .init(time: 9.8, reason: .reset)]
        )
    }

    /// Средний вес показа за `[0, end]` по времени, до первого расписания 0; без веса хотя бы у одного
    /// расписания (журнал до B5) среднего нет.
    /// Гонка фаз в линии времени: секунды гонки до `end` и сколько раз она начиналась, медиана отношения
    /// гребенки. У журнала схемы 1 (нет `amplitudes`) гонка не записана, а не «ноль секунд».
    @Test func timelineRaceFromSchedules() throws {
        let race = RhythmLog.Schedule.Race(shadow: 3.3, dim: 0.2)
        let schedules = [
            RhythmLog.Schedule(time: 1, bpm: 100, confidence: 1, locked: true, beats: [], amplitudes: [], combRatio: 1.0),
            RhythmLog.Schedule(time: 3, bpm: 100, confidence: 1, locked: true, beats: [], amplitudes: [], race: race, combRatio: 1.4),
            RhythmLog.Schedule(time: 5, bpm: 100, confidence: 1, locked: true, beats: [], amplitudes: [], combRatio: 1.2),
            RhythmLog.Schedule(time: 8, bpm: 100, confidence: 1, locked: true, beats: [], amplitudes: [], race: race, combRatio: 1.5),
            RhythmLog.Schedule(time: 12, bpm: 100, confidence: 1, locked: true, beats: [], amplitudes: [], race: race, combRatio: 9),
        ]
        let timeline = RhythmReplay.Timeline(schedules: schedules, end: 10)
        // 3-5 и 8-10 с.
        #expect(timeline.raceSeconds.map { abs($0 - 4) < 1e-12 } == true)
        #expect(timeline.raceStarts == 2)
        // Медиана 1.0, 1.4, 1.2, 1.5 (ближний ранг): 1.2.
        #expect(timeline.medianCombRatio == 1.2)
        let old = schedules.map { RhythmLog.Schedule(time: $0.time, bpm: $0.bpm, confidence: $0.confidence, locked: $0.locked, beats: []) }
        #expect(RhythmReplay.Timeline(schedules: old, end: 10).raceSeconds == nil)
        #expect(RhythmReplay.Timeline(schedules: old, end: 10).raceStarts == nil)
        let states = [
            OfflineBeatChain.State(time: 0, locked: true, bpm: 100, confidence: 1),
            OfflineBeatChain.State(time: 2, locked: true, bpm: 100, confidence: 1, racing: true, combRatio: 1.3),
            OfflineBeatChain.State(time: 2.5, locked: true, bpm: 100, confidence: 1),
        ]
        let replay = RhythmReplay.Timeline(states: states, end: 4)
        #expect(replay.raceSeconds == 0.5 && replay.raceStarts == 1 && replay.medianCombRatio == 1.3)
    }

    @Test func timelineMeanWeight() {
        let schedules = [
            RhythmLog.Schedule(time: 2, bpm: 120, confidence: 0.5, locked: false, beats: [], weight: 0.5),
            RhythmLog.Schedule(time: 6, bpm: 120, confidence: 0.8, locked: true, beats: [], weight: 1),
            RhythmLog.Schedule(time: 12, bpm: 120, confidence: 0.8, locked: true, beats: [], weight: 0),
        ]
        let timeline = RhythmReplay.Timeline(schedules: schedules, end: 10)
        #expect(timeline.meanWeight.map { abs($0 - 0.6) < 1e-12 } == true)
        var old = schedules
        old[1].weight = nil
        #expect(RhythmReplay.Timeline(schedules: old, end: 10).meanWeight == nil)
        #expect(RhythmReplay.Timeline(schedules: [], end: 10).meanWeight == nil)
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
                RhythmLog.Schedule(
                    time: $0.time, bpm: $0.bpm, confidence: $0.confidence, locked: $0.locked, beats: [], weight: $0.weight
                )
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
        // Вес показа и мягкий пульс: прогон с другой фазой дает тот же средний вес, пульс у прогона
        // считается всегда, у записи без итога пульса его нет.
        let deviceWeight = try #require(report.device.meanWeight)
        let replayWeight = try #require(report.replay.meanWeight)
        #expect(abs(deviceWeight - replayWeight) < 0.05, "mean weight \(deviceWeight) vs \(replayWeight)")
        #expect(report.replayAmbientShare > 0 && report.replayAmbientShare < 1)
        #expect(report.replayAmbientPeak > 0 && report.replayAmbientPeak <= BeatGlow.ambientCeiling)
        let text = report.text
        #expect(text.contains("soft pulse: device not logged"))
        #expect(text.contains("mean weight"))
        #expect(text.contains("unlocks replay:"))
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

    @Test func earlyEndComparesOnlyUpToTheLastSample() throws {
        var meta = Self.meta()
        meta.sampleRate = 8_000
        meta.outputLatency = 0.1
        meta.audioSeconds = 2
        meta.renderedUntil = 2.3
        meta.endReason = .islandHidden
        meta.reduceMotion = true
        let flashes = [0.5, 1.5, 1.9, 2.05].map { RhythmLog.Flash(time: $0, predicted: false, locked: false) }
        let log = RhythmLog(meta: meta, kicks: [], onsets: [], schedules: [], flashes: flashes)
        let wav = WAVWriter.pcm16Mono([Int16](repeating: 0, count: 16_000), sampleRate: 8_000)
        let report = try RhythmReplay.replay(logData: try log.encoded(), wavData: wav, options: RhythmReplay.Options())
        #expect(report.until == 2)
        #expect(report.all.deviceCount == 3)
        #expect(report.text.contains("reduce motion was on"))

        var complete = log
        complete.meta.endReason = .complete
        complete.meta.reduceMotion = false
        let full = try RhythmReplay.replay(logData: try complete.encoded(), wavData: wav, options: RhythmReplay.Options())
        #expect(abs(full.until - 2.1) < 1e-12)
        #expect(full.all.deviceCount == 4)
        #expect(!full.text.contains("NOTE"))
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
