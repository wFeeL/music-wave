import AppKit
import Testing
import WaveCore
@testable import WaveFeels

/// Кадр острова: уровни из истории кадров анализа на момент кадра, снимки без шага анимации,
/// раздел диагностики «Отрисовка».
@MainActor
struct AppModelRenderTests {
    @Test func interpolatesPublishedFrames() throws {
        let (model, defaults, suite) = try Self.makeModel("render-interpolation")
        defer { defaults.removePersistentDomain(forName: suite) }
        let t = 1_000.0
        model.store.publish(Self.frame(bass: 0.2), at: t)
        model.store.publish(Self.frame(bass: 0.6), at: t + 1.0 / 60)
        // Кадр анализа берется на 1/60 с раньше момента кадра: посередине между двумя кадрами.
        let visuals = model.islandVisuals(now: t + 1.0 / 60 + 1.0 / 120, timelineTime: 0, reduceMotion: false)
        #expect(abs(visuals.sampled.layers[0] - 0.4) < 0.02)
    }

    @Test func previewKeepsFrameValues() throws {
        let (model, defaults, suite) = try Self.makeModel("render-preview")
        defer { defaults.removePersistentDomain(forName: suite) }
        let frame = Self.frame(bass: 0.8)
        model.showPreview(
            state: .collapsed, track: nil, palette: nil, frame: frame, motion: WaveMotion(),
            pulse: BeatPulse(), time: 5, nowPlayingAvailable: true
        )
        #expect(model.previewing)
        let first = model.islandVisuals(now: 5, timelineTime: 5, reduceMotion: false)
        #expect(first.frame.layers[0] == 0.8)
        #expect(first.frame.level == frame.level)
        #expect(first.sampled == frame)
        // Снимок не сглаживает уровни и на следующих кадрах.
        let later = model.islandVisuals(now: 5.5, timelineTime: 5.5, reduceMotion: false)
        #expect(later.frame.layers == frame.layers)
        #expect(later.pulse == 0)
    }

    @Test func diagnosticsHaveRenderSection() throws {
        let (model, defaults, suite) = try Self.makeModel("render-diagnostics")
        defer { defaults.removePersistentDomain(forName: suite) }
        let section = try #require(model.diagnosticsSections().first { $0.title == "Отрисовка" })
        let labels = section.rows.map(\.label)
        #expect(labels == ["Экран", "Свернутый", "Раскрытый", "Переход", "Кадров анализа на кадр", "Разброс"])
        #expect(section.rows[0].value.hasPrefix("60 Гц | энергосбережение: "))
        #expect(section.rows[1].value == AppModel.noRenderData)
        let titles = model.diagnosticsSections().map(\.title)
        let output = try #require(titles.firstIndex(of: "Устройство вывода"))
        #expect(titles[output + 1] == "Отрисовка")
    }

    private static func frame(bass: Float) -> WaveFrame {
        WaveFrame(
            bands: [Float](repeating: bass, count: BandMapper.bandCount),
            layers: [bass, bass / 2, bass / 4],
            beat: 0,
            level: bass,
            rawLevelDB: -20
        )
    }

    private static func makeModel(_ name: String) throws -> (AppModel, UserDefaults, String) {
        _ = NSApplication.shared
        let suite = "com.wfeels.wavefeels.tests.\(name)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (AppModel(defaults: defaults), defaults, suite)
    }
}
