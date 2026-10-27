import AppKit
import Testing
import WaveCore
@testable import WaveFeels

/// Кадр острова: уровни и свечение доли на момент показа кадра (`now` плюс два периода экрана,
/// `AppModel.presentationTiming`), снимки без шага анимации, разделы диагностики «Отрисовка» и «Ритм».
@MainActor
struct AppModelRenderTests {
    @Test func interpolatesPublishedFrames() throws {
        let (model, defaults, suite) = try Self.makeModel("render-interpolation")
        defer { defaults.removePersistentDomain(forName: suite) }
        let t = 1_000.0
        model.store.publish(Self.frame(bass: 0.2), at: t)
        model.store.publish(Self.frame(bass: 0.6), at: t + 1.0 / 60)
        // Кадр анализа берется на момент показа, на два периода экрана позже: посередине между
        // двумя кадрами. До 60 кадров период отрисовки равен периоду кадров (экран, «Частота кадров»).
        model.lowPower = false
        #expect(model.renderPeriod == model.cadencePeriod)
        #expect(model.renderPeriod == model.refreshPeriod)
        let lead = model.presentationTiming.lead
        #expect(abs(lead - 2 * model.refreshPeriod) < 1e-12)
        let visuals = model.islandVisuals(now: t + 1.0 / 120 - lead, timelineTime: 0, reduceMotion: false)
        #expect(abs(visuals.sampled.layers[0] - 0.4) < 0.02)
    }

    /// «Частота кадров» 30: период кадров и отрисовки 1/30 с на экране 60 и 120 Гц, шаг
    /// `TimelineView` не короче 0.9 периода; 60 на экране 120 Гц остается 60. Упреждение показа
    /// при любой частоте и в энергосбережении два периода экрана, период выборки свечения идет за
    /// частотой кадров (`presentationTiming`). Простой остается 12 кадров в секунду.
    @Test func frameRateSettingSetsCadenceAndRenderDelay() throws {
        let (model, defaults, suite) = try Self.makeModel("render-frame-rate")
        defer { defaults.removePersistentDomain(forName: suite) }
        model.lowPower = false
        for screen in [1.0 / 60, 1.0 / 120] {
            model.refreshPeriod = screen
            model.settings.frameRate = 30
            #expect(model.cadencePeriod == 1.0 / 30)
            #expect(model.renderPeriod == 1.0 / 30)
            #expect(model.presentationTiming.framePeriod == 1.0 / 30)
            #expect(abs(model.presentationTiming.lead - 2 * screen) < 1e-12)
            #expect(abs(model.timelineInterval - RenderPacing.intervalSlack / 30) < 1e-12)
            model.settings.frameRate = 60
            #expect(model.cadencePeriod == 1.0 / 60)
            #expect(model.renderPeriod == 1.0 / 60)
            #expect(model.presentationTiming.framePeriod == 1.0 / 60)
            #expect(abs(model.presentationTiming.lead - 2 * screen) < 1e-12)
            #expect(abs(model.timelineInterval - RenderPacing.intervalSlack / 60) < 1e-12)
            model.lowPower = true
            #expect(model.presentationTiming.framePeriod == 1.0 / 30)
            #expect(abs(model.presentationTiming.lead - 2 * screen) < 1e-12)
            model.lowPower = false
        }
    }

    /// Свечение по расписанию на момент показа кадра, акцент доли на басу после пружин; при
    /// «Уменьшении движения» ни свечения, ни акцента.
    @Test func glowFollowsScheduleAtPresentationTime() throws {
        let (model, defaults, suite) = try Self.makeModel("render-glow")
        defer { defaults.removePersistentDomain(forName: suite) }
        let t = 2_000.0
        let lead = model.presentationTiming.lead
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

    /// Мягкий пульс идет отдельным каналом: сетка из расписания, энергия бочки из кадра анализа на
    /// момент показа (энергия расписания не используется), 0 при «Уменьшении движения» и при
    /// выключенном «Мягком пульсе»; свечение доли от него не меняется.
    @Test func softPulseIsASeparateChannel() throws {
        let (model, defaults, suite) = try Self.makeModel("render-soft-pulse")
        defer { defaults.removePersistentDomain(forName: suite) }
        let t = 3_000.0
        let lead = model.presentationTiming.lead
        var energetic = Self.frame(bass: 0.2)
        energetic.kickEnergy = 1.6
        model.store.publish(energetic, at: t)
        let info = AmbientInfo(anchor: t + lead, period: 0.5, confidence: 1, energy: 0)
        model.store.publishSchedule(
            BeatSchedule(events: [], bpm: 120, period: 0.5, confidence: 0.9, locked: false, ambient: info)
        )
        #expect(model.settings.softPulse)
        // На доле энергия кадра и горб вместе упираются в потолок пульса.
        let on = model.islandVisuals(now: t, timelineTime: 1, reduceMotion: false)
        #expect(on.ambient == BeatGlow.ambientCeiling)
        #expect(on.glow == 0)
        let calm = model.islandVisuals(now: t + 0.01, timelineTime: 2, reduceMotion: true)
        #expect(calm.ambient == 0)
        model.settings.softPulse = false
        let off = model.islandVisuals(now: t + 0.02, timelineTime: 3, reduceMotion: false)
        #expect(off.ambient == 0)
    }

    /// Мягкая остановка: после последнего кадра со звуком показанные уровни и полосы угасают за
    /// 0.6 с от показанных (на 0.3 с ровно вдвое), пружины падают своим ходом, вспышки по
    /// расписанию, пока тихо, не проходят. С выключенной настройкой уровни идут за пружинами.
    @Test func softStopFadesShownValuesOnSilence() throws {
        func run(softStop: Bool) throws -> (loud: IslandVisuals, middle: IslandVisuals, end: IslandVisuals) {
            let (model, defaults, suite) = try Self.makeModel("render-soft-stop-\(softStop)")
            defer { defaults.removePersistentDomain(forName: suite) }
            #expect(model.settings.softStop)
            model.settings.softStop = softStop
            let t = 4_000.0
            let lead = model.presentationTiming.lead
            model.store.publish(Self.frame(bass: 0.8), at: t)
            model.store.publish(Self.frame(bass: 0.8), at: t + 1 + lead)
            var loud = model.islandVisuals(now: t, timelineTime: 0, reduceMotion: false)
            for step in 1...60 {
                loud = model.islandVisuals(now: t + Double(step) / 60, timelineTime: 0, reduceMotion: false)
            }
            // Тишина с ближайшего кадра, а на нем по расписанию полная вспышка.
            model.store.publish(.silent, at: t + 1 + lead + 1.0 / 60)
            let beat = GlowEvent(id: 1, time: t + 1 + 10.0 / 60 + lead + BeatGlow.lead, amplitude: 1, predicted: true)
            model.store.publishSchedule(BeatSchedule(events: [beat], bpm: 120, period: 0.5, confidence: 0.9, locked: true))
            var middle = loud
            var end = loud
            for step in 1...42 {
                let visuals = model.islandVisuals(now: t + 1 + Double(step) / 60, timelineTime: 0, reduceMotion: false)
                if step == 10, softStop {
                    #expect(visuals.glow == 0)
                    #expect(visuals.pulse == 0)
                }
                if step == 18 { middle = visuals }
                end = visuals
            }
            return (loud, middle, end)
        }

        let on = try run(softStop: true)
        let loudLevel = on.loud.frame.level
        #expect(loudLevel > 0.7)
        #expect(abs(on.middle.frame.level - loudLevel * 0.5) < 1e-3)
        #expect(abs(on.middle.frame.layers[1] - on.loud.frame.layers[1] * 0.5) < 1e-3)
        #expect(on.middle.frame.bands.allSatisfy { abs($0 - 0.4) < 1e-3 })
        #expect(on.middle.sampled == .silent)
        #expect(on.end.frame.bands.allSatisfy { $0 == 0 })
        #expect(on.end.frame.level < 0.05)

        let off = try run(softStop: false)
        #expect(off.middle.frame.level < loudLevel * 0.2)
        #expect(off.middle.frame.bands.allSatisfy { $0 == 0 })
    }

    /// «Длительность вспышки» меняет только показанное свечение. Запись ритма и «вздох» идут от
    /// свечения со спадом 1× (второе состояние `steadyGlowState`): две модели с длительностью 1 и 2 на
    /// одном расписании дают кадр в кадр один и тот же вход записи (`RhythmRecording.previousGlow`) и
    /// один «вздох», а показанное свечение с длительностью 2 после пика гаснет медленнее. Вес показа
    /// 0.5: «вздох» смешивает пружину и свечение и зависит от свечения.
    @Test func flashLengthChangesOnlyTheShownGlow() throws {
        let (short, shortDefaults, shortSuite) = try Self.makeModel("render-flash-length-1")
        defer { shortDefaults.removePersistentDomain(forName: shortSuite) }
        let (long, longDefaults, longSuite) = try Self.makeModel("render-flash-length-2")
        defer { longDefaults.removePersistentDomain(forName: longSuite) }
        short.settings.flashLength = 1
        long.settings.flashLength = 2
        #expect(long.settings.flashLength == 2)
        let t = 5_000.0
        for model in [short, long] {
            model.lowPower = false
            model.store.publish(Self.frame(bass: 0.2), at: t)
            let time = t + 0.1 + model.presentationTiming.lead + BeatGlow.lead
            let beat = GlowEvent(id: 1, time: time, amplitude: 1, predicted: true)
            model.store.publishSchedule(
                BeatSchedule(events: [beat], bpm: 120, period: 0.5, confidence: 0.9, locked: true, weight: 0.5)
            )
        }
        var peak: Float = 0
        var slowerAfterPeak = false
        for step in 0..<60 {
            let now = t + Double(step) / 60
            let one = short.islandVisuals(now: now, timelineTime: now, reduceMotion: false)
            let two = long.islandVisuals(now: now, timelineTime: now, reduceMotion: false)
            #expect(short.rhythmRecording.previousGlow == one.glow, "step \(step)")
            #expect(long.rhythmRecording.previousGlow == one.glow, "step \(step)")
            #expect(two.pulse == one.pulse, "step \(step)")
            #expect(two.glow >= one.glow, "step \(step)")
            peak = max(peak, one.glow)
            if peak > 0.9, two.glow > one.glow + 0.05 { slowerAfterPeak = true }
        }
        #expect(peak > 0.9)
        #expect(slowerAfterPeak)
    }

    /// «Спектр» в тишине: линия и призрак приходят ровно в 0, а детектор простоя доходит до простоя
    /// не позже чем через 2.5 с после того, как звук стих, с «Следом пиков» и без него, с «Мягкой
    /// остановкой» и без нее. Расчет той же цепочки в WaveCore (`SoftStop`, `ShownSpectrum`,
    /// `RenderIdleDetector`, 60 кадров): с мягкой остановкой и следом простой через 1.83 с, без нее
    /// через 1.18 с; призрак ровно в нуле через 2.12 и 1.45 с.
    @Test func spectrumReachesRenderIdleInSilence() throws {
        for softStop in [true, false] {
            for peaks in [true, false] {
                let label = "soft stop \(softStop), peaks \(peaks)"
                let (model, defaults, suite) = try Self.makeModel("render-spectrum-idle-\(softStop)-\(peaks)")
                defer { defaults.removePersistentDomain(forName: suite) }
                model.lowPower = false
                model.settings.look = .spectrum
                model.settings.spectrumPeaks = peaks
                model.settings.softStop = softStop
                let t = 6_000.0
                let lead = model.presentationTiming.lead
                model.store.publish(Self.frame(bass: 0.8), at: t)
                model.store.publish(Self.frame(bass: 0.8), at: t + 0.5 + lead)
                model.store.publish(.silent, at: t + 0.5 + lead + 1.0 / 60)
                // Звук на экране стихает около `t + 0.5`.
                let silence = t + 0.5
                var idleAt: Double?
                var last: IslandVisuals?
                for step in 0...(60 * 4) {
                    let now = t + Double(step) / 60
                    let visuals = model.islandVisuals(now: now, timelineTime: now, reduceMotion: false)
                    if step == 25 {
                        #expect((visuals.spectrum?.values.max() ?? 0) > 0.5, "\(label)")
                        #expect(!model.renderIdleDetector.isIdle, "\(label)")
                    }
                    if idleAt == nil, model.renderIdleDetector.isIdle { idleAt = now }
                    last = visuals
                }
                let idle = try #require(idleAt, "\(label)")
                #expect(idle - silence >= RenderIdleDetector.settle, "\(label), idle after \(idle - silence) s")
                #expect(idle - silence <= 2.5, "\(label), idle after \(idle - silence) s")
                #expect(model.renderIdleDetector.isIdle, "\(label)")
                let spectrum = try #require(last?.spectrum, "\(label)")
                #expect(spectrum.values.allSatisfy { $0 == 0 }, "\(label)")
                #expect(spectrum.peaks.allSatisfy { $0 == 0 }, "\(label)")
            }
        }
    }

    /// Пауза по Now Playing считается для мягкой остановки только у источника-приложения; полоса
    /// панели гаснет по `nowPlayingPaused` у любого источника. Текущая запись Now Playing из
    /// `nowPlayingStub`, последний трек источника из `showPreview`.
    @Test func sourcePausedOnlyForApplications() throws {
        let (model, defaults, suite) = try Self.makeModel("render-source-paused")
        defer { defaults.removePersistentDomain(forName: suite) }
        var paused = NowPlayingInfo(bundleIdentifier: "ru.yandex.desktop.music", title: "Трек", artist: nil, isPlaying: false)
        model.showPreview(
            state: .collapsed, track: paused, palette: nil, frame: Self.frame(bass: 0.5), motion: WaveMotion(),
            glow: 0, pulse: 0, time: 1, nowPlayingAvailable: true
        )
        model.nowPlayingStub = paused
        model.settings.source = .systemWide
        #expect(model.nowPlayingPaused)
        #expect(!model.sourcePaused)
        model.settings.source = Self.yandex
        #expect(model.sourcePaused)
        paused.isPlaying = true
        model.showPreview(
            state: .collapsed, track: paused, palette: nil, frame: Self.frame(bass: 0.5), motion: WaveMotion(),
            glow: 0, pulse: 0, time: 1, nowPlayingAvailable: true
        )
        model.nowPlayingStub = paused
        #expect(!model.nowPlayingPaused)
        #expect(!model.sourcePaused)
    }

    /// Яндекс Музыка на паузе, затем Now Playing перешел к видео в Safari или опустел, а последний
    /// трек источника так и остался на паузе: пауза источника по нему не считается, иначе мягкая
    /// остановка держала бы остров ровным, когда Яндекс Музыка снова играет.
    @Test func sourcePausedIgnoresStaleLastTrack() throws {
        let (model, defaults, suite) = try Self.makeModel("render-source-paused-stale")
        defer { defaults.removePersistentDomain(forName: suite) }
        let paused = NowPlayingInfo(bundleIdentifier: "ru.yandex.desktop.music", title: "Трек", artist: nil, isPlaying: false)
        model.showPreview(
            state: .collapsed, track: paused, palette: nil, frame: Self.frame(bass: 0.5), motion: WaveMotion(),
            glow: 0, pulse: 0, time: 1, nowPlayingAvailable: true
        )
        model.settings.source = Self.yandex
        model.nowPlayingStub = paused
        #expect(model.sourcePaused)

        model.nowPlayingStub = NowPlayingInfo(bundleIdentifier: "com.apple.Safari", title: "Видео", artist: nil, isPlaying: true)
        #expect(model.nowPlayingPaused)
        #expect(!model.sourcePaused)

        model.nowPlayingStub = nil
        #expect(!model.sourcePaused)
    }

    private static let yandex = AudioSource.application(
        bundleID: "ru.yandex.desktop.music", bundlePath: "/Applications/Яндекс Музыка.app", displayName: "Яндекс Музыка"
    )

    /// Переливание двигается на ограниченный шаг (`maxVisualStep`: после сна цвет не прыгает),
    /// «Уменьшение движения» его останавливает; снимки держат заданную фазу. Палитра кадра без
    /// течения, свечение берет первый цвет с течением.
    @Test func paletteFlowAdvancesWithCappedStep() throws {
        let (model, defaults, suite) = try Self.makeModel("render-flow")
        defer { defaults.removePersistentDomain(forName: suite) }
        model.store.publish(Self.frame(bass: 0.5), at: 0)
        model.settings.colorFlow = 1
        let first = model.islandVisuals(now: 5, timelineTime: 0, reduceMotion: false)
        #expect(first.flowPhase == 0)
        #expect(first.glowSourceColor == first.palette[0])
        // Час без кадров (сон): шаг не длиннее 0.1 с, период на скорости 1 равен 8 с.
        let woke = model.islandVisuals(now: 3_605, timelineTime: 0, reduceMotion: false)
        #expect(abs(woke.flowPhase - AppModel.maxVisualStep / PaletteFlow.fastestPeriod) < 1e-9)
        let calm = model.islandVisuals(now: 3_605.05, timelineTime: 0, reduceMotion: true)
        #expect(calm.flowPhase == woke.flowPhase)
        #expect(calm.palette == woke.palette)
        #expect(woke.glowSourceColor == PaletteFlow.apply(woke.palette, phase: woke.flowPhase)[0])

        model.showPreview(
            state: .collapsed, track: nil, palette: nil, frame: Self.frame(bass: 0.5), motion: WaveMotion(),
            glow: 0, pulse: 0, time: 10, nowPlayingAvailable: true, flowPhase: 0.4
        )
        #expect(model.islandVisuals(now: 10, timelineTime: 10, reduceMotion: false).flowPhase == 0.4)
        #expect(model.islandVisuals(now: 11, timelineTime: 11, reduceMotion: false).flowPhase == 0.4)
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

    /// «Цвет волн» задает палитру острова поверх обложки; смена режима перетекает за 0.8 с,
    /// как новая обложка.
    @Test func colorModeFadesLikeNewArtwork() throws {
        let (model, defaults, suite) = try Self.makeModel("render-color-mode")
        defer { defaults.removePersistentDomain(forName: suite) }
        let artwork = PaletteExtractor.fallback
        model.showPreview(
            state: .collapsed, track: nil, palette: artwork, frame: Self.frame(bass: 0.5), motion: WaveMotion(),
            glow: 0, pulse: 0, time: 10, nowPlayingAvailable: true
        )
        #expect(model.islandVisuals(now: 10, timelineTime: 10, reduceMotion: false).palette == artwork)

        model.settings.colorMode = .preset(.neon)
        #expect(model.wavePalette == WavePreset.neon.colors)
        #expect(model.palette == artwork)
        let start = model.islandVisuals(now: 10, timelineTime: 10, reduceMotion: false).palette
        #expect(start == artwork)
        let middle = model.islandVisuals(now: 10.4, timelineTime: 10.4, reduceMotion: false).palette
        #expect(middle != artwork && middle != WavePreset.neon.colors)
        let end = model.islandVisuals(now: 10 + PaletteFade.duration, timelineTime: 10.8, reduceMotion: false).palette
        #expect(end == WavePreset.neon.colors)

        model.settings.colorMode = .custom(PaletteColor(hex: 0x7A5CFF))
        #expect(model.wavePalette == WaveAppearance.customPalette(PaletteColor(hex: 0x7A5CFF)))
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
        // Задержка вывода зависит от устройства машины (на CI 13 мс): ожидание считается так же.
        let latency = LatencyCalculator.outputLatency(model.output.latency, mode: model.settings.latencyMode)
        let output = "\(AppModel.milliseconds(latency)) мс"
        #expect(empty.rows.map(\.value) == ["нет", "0.00", "нет", output, "33 мс", "7 мс", "0 мс"])

        model.store.publishSchedule(BeatSchedule(events: [], bpm: 123.6, period: 60 / 123.6, confidence: 0.817, locked: true))
        model.settings.syncOffsets.set(15, deviceUID: model.output.deviceUID, name: model.output.deviceName)
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
