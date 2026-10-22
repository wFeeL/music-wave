import AppKit
import AVFoundation
import Foundation
import Testing
import WaveCore
@testable import WaveFeels

@MainActor
struct IslandPreviewTests {
    /// Предпросмотр тратит процессор, только когда его видно: окно открыто, не закрыто другими
    /// окнами и выбрана вкладка «Вид». Вся таблица истинности.
    @Test func previewRunsOnlyWhenVisible() {
        let table: [(open: Bool, visible: Bool, tab: SettingsView.Tab, active: Bool)] = [
            (false, false, .general, false),
            (false, false, .appearance, false),
            (false, true, .general, false),
            (false, true, .appearance, false),
            (true, false, .general, false),
            (true, false, .appearance, false),
            (true, true, .general, false),
            (true, true, .appearance, true),
        ]
        #expect(table.count == 2 * 2 * SettingsView.Tab.allCases.count)
        for row in table {
            let active = PreviewPlayer.isActive(windowOpen: row.open, windowVisible: row.visible, tab: row.tab)
            #expect(active == row.active, "открыто \(row.open), видно \(row.visible), вкладка \(row.tab)")
        }
    }

    /// Момент берется по кругу: время за длиной прогона и отрицательное сворачиваются в него.
    @Test func timelineLoops() {
        let sampleRate = 44_100.0
        // Секунда тишины, затем секунда тона 110 Гц: кадры в двух половинах разные.
        let silence = Int(sampleRate)
        let samples = (0..<(2 * silence)).map { index -> Float in
            guard index >= silence else { return 0 }
            let phase = 2 * Float.pi * 110 * Float(index) / Float(sampleRate)
            return 0.5 * sin(phase)
        }
        let timeline = DemoTimeline(samples: samples, sampleRate: sampleRate, duration: 2, mutedFrom: nil)
        let duration = timeline.duration
        #expect(abs(duration - 2) < 1e-9)

        let late = timeline.moment(at: 25)
        let early = timeline.moment(at: 25 - duration)
        #expect(late.frame == early.frame)
        #expect(late.time == early.time)
        #expect(timeline.moment(at: 1).time == late.time)
        #expect(timeline.moment(at: -1).time == late.time)
        #expect(timeline.moment(at: 0.5).frame != timeline.moment(at: 1.5).frame)
        #expect(timeline.moment(at: 1.5).frame == timeline.moment(at: 1.5 + 3 * duration).frame)
    }

    /// Два игрока (два открытия вкладки) читают демо один раз, и одновременные чтения тоже
    /// сходятся в одно.
    @Test func timelineLoadsOnce() async throws {
        let url = try Self.writeTone(seconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = PreviewTimelineCache()
        let before = DemoTimeline.loadCountForTesting
        let first = PreviewPlayer(cache: cache)
        let second = PreviewPlayer(cache: cache)
        #expect(first.timeline == nil)

        async let firstLoad: Void = first.load(from: url)
        async let secondLoad: Void = second.load(from: url)
        _ = await (firstLoad, secondLoad)
        await second.load(from: url)

        #expect(DemoTimeline.loadCountForTesting - before == 1)
        #expect(first.timeline != nil)
        #expect(second.timeline?.duration == first.timeline?.duration)
        // Следующий игрок берет готовое демо сразу.
        #expect(PreviewPlayer(cache: cache).timeline != nil)
    }

    /// Подпись «ограничено до N pt» только там, где экран с вырезом не дает крылу его ширину.
    @Test func wingCaptionShowsOnlyWhenLimited() {
        #expect(AppearanceSettingsView.wingCaption(wing: 150, limit: 150, hasNotch: true) == nil)
        #expect(AppearanceSettingsView.wingCaption(wing: 120, limit: 150, hasNotch: true) == nil)
        #expect(AppearanceSettingsView.wingCaption(wing: 200, limit: 150, hasNotch: true) == "ограничено до 150 pt")
        #expect(AppearanceSettingsView.wingCaption(wing: 200, limit: 150, hasNotch: false) == nil)
        #expect(AppearanceSettingsView.wingCaption(wing: 200, limit: 151.7, hasNotch: true) == "ограничено до 151 pt")
        #expect(AppearanceSettingsView.wingCaption(wing: 200, limit: nil, hasNotch: true) == nil)
    }

    /// «Высокая нагрузка на процессор» под предпросмотром только у дорогого вида.
    @Test func costHintShowsOnlyForHeavyAppearance() {
        #expect(AppearanceSettingsView.costHint(for: .standard) == nil)
        let heavy = WaveAppearance(
            wingWidth: 200, colorMode: .artwork, glowRadius: 3, lineCount: 6, fill: 1, thickness: 2, amplitude: 2
        )
        #expect(AppearanceSettingsView.costHint(for: heavy) == "Высокая нагрузка на процессор")
        let moderate = WaveAppearance(
            wingWidth: 120, colorMode: .artwork, glowRadius: 1.5, lineCount: 4, fill: 0.3, thickness: 1, amplitude: 1
        )
        #expect(AppearanceSettingsView.costHint(for: moderate) == nil)
    }

    /// «Уменьшение движения»: ни свечения доли, ни «вздоха», хотя в демо они есть.
    @Test func previewReduceMotionHasNoGlowOrPulse() {
        let cache = PreviewTimelineCache()
        cache.timeline = Self.timeline(seconds: 2) { time in
            (level: 0.6, glow: time.truncatingRemainder(dividingBy: 0.5) < 0.1 ? 0.9 : 0, pulse: 0.5)
        }
        let calm = PreviewPlayer(cache: cache)
        let lively = PreviewPlayer(cache: cache)
        var calmMax: Float = 0
        var livelyGlow: Float = 0
        var livelyPulse: Float = 0
        for frame in 0..<120 {
            let now = 100 + Double(frame) / 60
            let quiet = calm.visuals(now: now, palette: PaletteExtractor.fallback, reduceMotion: true)
            calmMax = max(calmMax, quiet.glow, quiet.pulse)
            let normal = lively.visuals(now: now, palette: PaletteExtractor.fallback, reduceMotion: false)
            livelyGlow = max(livelyGlow, normal.glow)
            livelyPulse = max(livelyPulse, normal.pulse)
        }
        #expect(calmMax == 0)
        #expect(livelyGlow > 0.5)
        #expect(livelyPulse > 0)
    }

    /// Шов круга: демо прыгает с уровня 1 на 0, а предпросмотр нет. Уровни идут через пружины,
    /// фазы волн двигаются своим ходом (в демо они нарочно бегут всемеро быстрее, и прыжок к ним
    /// был бы виден).
    @Test func previewIsSmoothAcrossLoopSeam() {
        let cache = PreviewTimelineCache()
        cache.timeline = Self.timeline(seconds: 2) { time in (level: Float(time / 2), glow: 0, pulse: 0) }
        let player = PreviewPlayer(cache: cache)
        var previous: IslandVisuals?
        var seams = 0
        var levelStep: Float = 0
        var phaseStep = 0.0
        for frame in 0..<240 {
            let visuals = player.visuals(now: 50 + Double(frame) / 60, palette: PaletteExtractor.fallback, reduceMotion: false)
            if let previous {
                if previous.sampled.level - visuals.sampled.level > 0.5 {
                    seams += 1
                }
                levelStep = max(levelStep, abs(visuals.frame.level - previous.frame.level))
                for layer in WaveLayer.allCases {
                    let turn = abs(visuals.motion.phase(layer).carrier - previous.motion.phase(layer).carrier)
                    phaseStep = max(phaseStep, min(turn, 2 * .pi - turn))
                }
            }
            previous = visuals
        }
        #expect(seams >= 1)
        #expect(levelStep < 0.25)
        #expect(phaseStep < 0.2)
    }

    /// Первый кадр встает на `loopStart` без запаздывания пружин и с фазами демо; демо короче
    /// `loopStart` играет с начала.
    @Test func previewFirstFrameStartsAtLoopStart() {
        let cache = PreviewTimelineCache()
        let timeline = Self.timeline(seconds: 20) { time in (level: Float(time / 20), glow: 0, pulse: 0) }
        cache.timeline = timeline
        let first = PreviewPlayer(cache: cache).visuals(now: 1000, palette: PaletteExtractor.fallback, reduceMotion: false)
        let start = timeline.moment(at: PreviewPlayer.loopStart)
        #expect(abs(start.time - PreviewPlayer.loopStart) < 1e-9)
        #expect(first.sampled == start.frame)
        #expect(first.frame.level == start.frame.level)
        #expect(first.frame.layers == start.frame.layers)
        for layer in WaveLayer.allCases {
            #expect(first.motion.phase(layer) == start.motion.phase(layer))
        }

        let short = Self.timeline(seconds: 2) { time in (level: Float(time / 2), glow: 0, pulse: 0) }
        cache.timeline = short
        let opening = PreviewPlayer(cache: cache).visuals(now: 7, palette: PaletteExtractor.fallback, reduceMotion: false)
        #expect(opening.sampled == short.moment(at: 0).frame)
    }

    /// Калибровка: свечение только по расписанию метронома на момент показа кадра, как у острова
    /// (`now + presentationLead`, вспышка за `BeatGlow.lead` до слышимого щелчка); волны тихие,
    /// «вздоха» нет, хотя в демо есть и свечение, и «вздох».
    @Test func calibrationGlowFollowsTheMetronomeAtPresentationTime() {
        let cache = PreviewTimelineCache()
        cache.timeline = Self.timeline(seconds: 2) { _ in (level: 0.8, glow: 0.9, pulse: 0.5) }
        let metronome = MetronomeSchedule(start: 100)
        let latency = 0.02
        let player = PreviewPlayer(cache: cache, glowSchedule: { time in
            metronome.beatSchedule(at: time, outputLatency: latency, offsetMs: 0)
        })
        #expect(player.isCalibrating)
        let refresh = 1.0 / 60
        let lead = LatencyCalculator.presentationLead(refreshPeriod: refresh)
        // Начало вспышки щелчка 3 на экране; кадры рисуются за `lead` до показа.
        let onset = metronome.clickTime(3) + latency - BeatGlow.lead - refresh / 2
        let palette = PaletteExtractor.fallback
        let before = player.calibrationVisuals(now: onset - 0.1 - lead, refreshPeriod: refresh, palette: palette)
        let flash = player.calibrationVisuals(now: onset + 0.001 - lead, refreshPeriod: refresh, palette: palette)
        #expect(before.glow < 0.1)
        #expect(flash.glow > 0.9)
        #expect(flash.pulse == 0)
        #expect(flash.sampled == .silent)
        #expect(flash.frame.level == 0)
    }

    /// Окно настроек ужимается до видимой области экрана и сдвигается внутрь нее; окно, которое
    /// уже помещается, остается на месте.
    @Test func settingsWindowFitsVisibleFrame() {
        // 13" MacBook Air: видимая область около 1470 × 919 pt.
        let air = NSRect(x: 0, y: 0, width: 1470, height: 919)
        let fits = NSRect(x: 100, y: 5, width: 520, height: 908)
        #expect(WindowsController.fitted(fits, in: air) == fits)
        let offTop = WindowsController.fitted(NSRect(x: 100, y: 200, width: 520, height: 908), in: air)
        #expect(air.contains(offTop))
        #expect(offTop.size == NSSize(width: 520, height: 908))

        let small = NSRect(x: 0, y: 80, width: 1280, height: 700)
        let tall = WindowsController.fitted(NSRect(x: 900, y: 0, width: 520, height: 908), in: small)
        #expect(tall == NSRect(x: 760, y: 80, width: 520, height: 700))
        #expect(WindowsController.fitted(fits, in: .zero) == fits)
    }

    /// Готовое демо длиной `seconds` с шагом `DemoTimeline.step`: уровень всех слоев, свечение
    /// и «вздох» по времени момента. Фазы в демо бегут всемеро быстрее, чем у живых волн.
    private static func timeline(
        seconds: Double,
        _ value: (Double) -> (level: Float, glow: Float, pulse: Float)
    ) -> DemoTimeline {
        let count = Int((seconds / DemoTimeline.step).rounded())
        var motion = WaveMotion()
        let moments = (1...count).map { step -> DemoMoment in
            let time = Double(step) * DemoTimeline.step
            let sample = value(time)
            let layers = [Float](repeating: sample.level, count: WaveLayer.allCases.count)
            motion.advance(layers: layers, dt: 7 * DemoTimeline.step)
            let frame = WaveFrame(
                bands: [Float](repeating: sample.level, count: WaveFrame.silent.bands.count), layers: layers,
                beat: sample.glow, level: sample.level, rawLevelDB: -20
            )
            return DemoMoment(time: time, frame: frame, motion: motion, glow: sample.glow, pulse: sample.pulse)
        }
        return DemoTimeline(moments: moments)
    }

    /// Тон 220 Гц длиной `seconds` в CAF во временной папке.
    private static func writeTone(seconds: Double) throws -> URL {
        let sampleRate = 44_100.0
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wavefeels-preview-\(UUID().uuidString).caf")
        let frames = AVAudioFrameCount(seconds * sampleRate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.floatChannelData?[0] else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = frames
        for index in 0..<Int(frames) {
            let phase = 2 * Float.pi * 220 * Float(index) / Float(sampleRate)
            channel[index] = 0.5 * sin(phase)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}
