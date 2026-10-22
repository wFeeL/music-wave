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
