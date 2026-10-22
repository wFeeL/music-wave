import AppKit
import Testing
import WaveCore
@testable import WaveFeels

/// Кадр острова: уровни и свечение доли на момент показа кадра (`now` плюс два периода
/// отрисовки), снимки без шага анимации, разделы диагностики «Отрисовка» и «Ритм».
@MainActor
struct AppModelRenderTests {
    @Test func interpolatesPublishedFrames() throws {
        let (model, defaults, suite) = try Self.makeModel("render-interpolation")
        defer { defaults.removePersistentDomain(forName: suite) }
        let t = 1_000.0
        model.store.publish(Self.frame(bass: 0.2), at: t)
        model.store.publish(Self.frame(bass: 0.6), at: t + 1.0 / 60)
        // Кадр анализа берется на момент показа, на два периода отрисовки позже: посередине между
        // двумя кадрами. До 60 кадров период отрисовки равен периоду экрана.
        #expect(model.renderPeriod == model.refreshPeriod)
        let lead = LatencyCalculator.presentationLead(refreshPeriod: model.renderPeriod)
        let visuals = model.islandVisuals(now: t + 1.0 / 120 - lead, timelineTime: 0, reduceMotion: false)
        #expect(abs(visuals.sampled.layers[0] - 0.4) < 0.02)
    }

    /// Свечение по расписанию на момент показа кадра, акцент доли на басу после пружин; при
    /// «Уменьшении движения» ни свечения, ни акцента.
    @Test func glowFollowsScheduleAtPresentationTime() throws {
        let (model, defaults, suite) = try Self.makeModel("render-glow")
        defer { defaults.removePersistentDomain(forName: suite) }
        let t = 2_000.0
        let lead = LatencyCalculator.presentationLead(refreshPeriod: model.renderPeriod)
        model.store.publish(Self.frame(bass: 0.2), at: t)
        let beat = GlowEvent(id: 1, time: t + lead + BeatGlow.lead, amplitude: 1, predicted: true)
        model.store.publishSchedule(BeatSchedule(events: [beat], bpm: 120, period: 0.5, confidence: 0.9, locked: true))

        let before = model.islandVisuals(now: t - 0.1, timelineTime: 1, reduceMotion: false)
        #expect(before.glow == 0)
        let onBeat = model.islandVisuals(now: t, timelineTime: 2, reduceMotion: false)
        #expect(onBeat.glow > 0.9, "glow \(onBeat.glow)")
        // Пружины линейны: бас вдвое выше середины, плюс акцент.
        let expected = 2 * onBeat.frame.layers[1] + BeatGlow.bassAccent * onBeat.glow
        #expect(abs(onBeat.frame.layers[0] - expected) < 1e-4)

        let calm = model.islandVisuals(now: t + 0.01, timelineTime: 3, reduceMotion: true)
        #expect(calm.glow == 0)
        #expect(calm.pulse == 0)
        #expect(abs(calm.frame.layers[0] - 2 * calm.frame.layers[1]) < 1e-4)
    }

    @Test func previewKeepsFrameValues() throws {
        let (model, defaults, suite) = try Self.makeModel("render-preview")
        defer { defaults.removePersistentDomain(forName: suite) }
        let frame = Self.frame(bass: 0.8)
        model.showPreview(
            state: .collapsed, track: nil, palette: nil, frame: frame, motion: WaveMotion(),
            glow: 0, pulse: 0, time: 5, nowPlayingAvailable: true
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
        #expect(later.glow == 0)

        // Заданные свечение и «вздох» возвращаются как есть, акцент доли на басу.
        model.showPreview(
            state: .collapsed, track: nil, palette: nil, frame: frame, motion: WaveMotion(),
            glow: 0.5, pulse: 0.25, time: 5, nowPlayingAvailable: true
        )
        let lit = model.islandVisuals(now: 5.2, timelineTime: 5.2, reduceMotion: false)
        #expect(lit.glow == 0.5)
        #expect(lit.pulse == 0.25)
        #expect(abs(lit.frame.layers[0] - (0.8 + BeatGlow.bassAccent * 0.5)) < 1e-6)
        #expect(lit.frame.layers[1] == frame.layers[1])
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
        #expect(titles[output + 2] == "Ритм")
    }

    @Test func diagnosticsHaveRhythmSection() throws {
        let (model, defaults, suite) = try Self.makeModel("render-rhythm")
        defer { defaults.removePersistentDomain(forName: suite) }
        let empty = try #require(model.diagnosticsSections().first { $0.title == "Ритм" })
        #expect(empty.rows.map(\.label) == [
            "Темп", "Уверенность", "Захват ритма", "Задержка вывода", "Задержка показа",
            "Запаздывание онсета", "Сдвиг синхронизации",
        ])
        #expect(empty.rows.map(\.value) == ["нет", "0.00", "нет", "0 мс", "33 мс", "7 мс", "0 мс"])

        model.store.publishSchedule(BeatSchedule(events: [], bpm: 123.6, period: 60 / 123.6, confidence: 0.817, locked: true))
        model.settings.syncOffsetMs = 15
        let section = try #require(model.diagnosticsSections().first { $0.title == "Ритм" })
        #expect(section.rows[0].value == "124 BPM")
        #expect(section.rows[1].value == "0.82")
        #expect(section.rows[2].value == "да")
        #expect(section.rows[6].value == "+15 мс")
        #expect(AppModel.syncOffsetText(-20) == "-20 мс")
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
