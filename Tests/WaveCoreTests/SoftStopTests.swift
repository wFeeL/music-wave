import Foundation
import Testing
@testable import WaveCore

/// Мягкая остановка: на паузе показанные волны, полосы, уровень, свечение, «вздох» и мягкий пульс
/// затихают за 0,6 с.
struct SoftStopTests {
    private static let start = 10.0
    private static let soundLayers: [Float] = [0.8, 0.5, 0.3]
    private static let soundGlow: Float = 0.6

    /// Показанные значения одного кадра после `SoftStop.apply`.
    private struct Shown {
        var layers: [Float]
        var bands: [Float]
        var level: Float
        var glow: Float
    }

    /// Один кадр через `stop`.
    private static func frame(
        _ stop: inout SoftStop, layers: [Float], bands: [Float] = [], level: Float, glow: Float, silent: Bool,
        now: Double
    ) -> Shown {
        var shown = Shown(layers: layers, bands: bands, level: level, glow: glow)
        stop.apply(
            layers: &shown.layers, bands: &shown.bands, level: &shown.level, glow: &shown.glow, silent: silent,
            now: now
        )
        return shown
    }

    /// Кадр со звуком на `start`: слои [0.8, 0.5, 0.3], уровень 0.8, свечение 0.6.
    private static func playing(bands: [Float] = []) -> SoftStop {
        var stop = SoftStop()
        _ = frame(&stop, layers: soundLayers, bands: bands, level: 0.8, glow: soundGlow, silent: false, now: start)
        return stop
    }

    /// Тихий кадр с нулевым входом на `start + t`.
    private static func quiet(_ stop: inout SoftStop, at t: Double, bands: Int = 0, glow: Float = 0) -> Shown {
        frame(
            &stop, layers: [0, 0, 0], bands: [Float](repeating: 0, count: bands), level: 0, glow: glow, silent: true,
            now: start + t
        )
    }

    private static func factor(_ t: Double) -> Float {
        Float(1 - WavePaint.smoothstep(0, SoftStop.duration, t))
    }

    @Test func easesOutOverSixTenths() {
        #expect(SoftStop.duration == 0.6)
        var stop = Self.playing()
        #expect(!stop.isFading)

        let early = Self.quiet(&stop, at: 0.01)
        #expect(abs(Self.factor(0.01) - 0.99918) < 1e-5)
        #expect(abs(early.layers[0] - 0.7993) < 1e-4)
        #expect(stop.isFading)

        let middle = Self.quiet(&stop, at: 0.3)
        #expect(abs(middle.layers[0] - 0.4) < 1e-4)
        #expect(abs(middle.layers[1] - 0.25) < 1e-4)
        #expect(abs(middle.layers[2] - 0.15) < 1e-4)
        #expect(abs(middle.level - 0.4) < 1e-4)
        #expect(abs(middle.glow - 0.3) < 1e-4)
        #expect(stop.isFading)

        let end = Self.quiet(&stop, at: 0.6)
        #expect(end.layers == [0, 0, 0])
        #expect(end.level == 0)
        #expect(end.glow == 0)
        #expect(!stop.isFading)
    }

    @Test func bandsFadeWithLayers() {
        let bands = [Float](repeating: 0.6, count: BandMapper.bandCount)
        var stop = Self.playing(bands: bands)
        let middle = Self.quiet(&stop, at: 0.3, bands: BandMapper.bandCount)
        #expect(middle.bands.count == BandMapper.bandCount)
        #expect(middle.bands.allSatisfy { abs($0 - 0.3) < 1e-4 })
        let end = Self.quiet(&stop, at: 0.6, bands: BandMapper.bandCount)
        #expect(end.bands == [Float](repeating: 0, count: BandMapper.bandCount))

        // Полосы другой длины, чем при запоминании, проходят как есть.
        var other = Self.playing(bands: bands)
        let short: [Float] = [0.1, 0, 0.2, 0, 0, 0, 0, 0, 0, 0.05]
        let shown = Self.frame(&other, layers: [0, 0, 0], bands: short, level: 0, glow: 0, silent: true, now: Self.start + 0.3)
        #expect(shown.bands == short)
        #expect(abs(shown.layers[0] - 0.4) < 1e-4)
    }

    /// Звук вернулся посреди угасания: пол угасания `удержанное × множитель` идет дальше по тем же
    /// часам, вход поверх него (`max`), пока множитель не дойдет до нуля; новые вспышки проходят.
    @Test func soundReturnKeepsTheFadingFloor() {
        var stop = Self.playing(bands: [Float](repeating: 0.6, count: BandMapper.bandCount))
        _ = Self.quiet(&stop, at: 0.2, bands: BandMapper.bandCount)
        #expect(stop.isFading)
        let layers: [Float] = [0.1, 0.05, 0.02]
        let bands = [Float](repeating: 0.03, count: BandMapper.bandCount)
        let back = Self.frame(&stop, layers: layers, bands: bands, level: 0.1, glow: 0.9, silent: false, now: Self.start + 0.25)
        let floor = Self.factor(0.25)
        #expect(abs(back.layers[0] - 0.8 * floor) < 1e-5)
        #expect(abs(back.layers[1] - 0.5 * floor) < 1e-5)
        #expect(abs(back.layers[2] - 0.3 * floor) < 1e-5)
        #expect(back.bands.allSatisfy { abs($0 - 0.6 * floor) < 1e-5 })
        #expect(abs(back.level - 0.8 * floor) < 1e-5)
        #expect(back.glow == 0.9)
        #expect(stop.isFading)

        // Громче пола вход проходит как есть.
        let loud = Self.frame(&stop, layers: [0.9, 0.6, 0.4], level: 0.9, glow: 0, silent: false, now: Self.start + 0.3)
        #expect(loud.layers == [0.9, 0.6, 0.4])
        #expect(loud.level == 0.9)
        #expect(abs(loud.glow - Self.soundGlow * Self.factor(0.3)) < 1e-5)

        // Множитель дошел до нуля: вход идет как есть, угасания больше нет.
        let through = Self.frame(&stop, layers: layers, bands: bands, level: 0.1, glow: 0, silent: false, now: Self.start + 0.6)
        #expect(through.layers == layers)
        #expect(through.bands == bands)
        #expect(through.level == 0.1)
        #expect(through.glow == 0)
        #expect(!stop.isFading)
    }

    /// Звук вернулся посреди угасания, а пружины поднимаются от нуля: показанное значение не
    /// проваливается на кадр к входу, а спускается не быстрее пола угасания (у 0.8 за 0,6 с не
    /// больше 2 в секунду, 0.034 за кадр 60 Гц).
    @Test func soundReturnHasNoDip() {
        var stop = Self.playing()
        var previous = Self.quiet(&stop, at: 0.2).layers[0]
        for step in 1...60 {
            let t = 0.2 + Double(step) / 60
            let rising = Float(step) * 0.004
            let shown = Self.frame(
                &stop, layers: [rising, 0, 0], level: rising, glow: 0, silent: false, now: Self.start + t
            )
            #expect(shown.layers[0] >= rising)
            #expect(previous - shown.layers[0] < 0.034, "t \(t): \(previous) -> \(shown.layers[0])")
            previous = shown.layers[0]
        }
        #expect(!stop.isFading)
    }

    /// Тишина снова наступила, пока пол угасания еще держался со звуком: новое угасание идет от
    /// того, что было показано на последнем кадре со звуком, без скачка вверх или вниз.
    @Test func silenceAfterShortReturnFadesFromShown() {
        var stop = Self.playing(bands: [Float](repeating: 0.6, count: BandMapper.bandCount))
        _ = Self.quiet(&stop, at: 0.2, bands: BandMapper.bandCount)
        let bands = [Float](repeating: 0.03, count: BandMapper.bandCount)
        let back = Self.frame(&stop, layers: [0.1, 0.05, 0.02], bands: bands, level: 0.1, glow: 0.9, silent: false, now: Self.start + 0.25)
        let next = Self.quiet(&stop, at: 0.25 + 0.3, bands: BandMapper.bandCount)
        #expect(abs(next.layers[0] - back.layers[0] * 0.5) < 1e-4)
        #expect(abs(next.level - back.level * 0.5) < 1e-4)
        #expect(abs(next.glow - 0.45) < 1e-4)
        #expect(next.bands.allSatisfy { abs($0 - back.bands[0] * 0.5) < 1e-4 })

        // Сразу после звука угасание начинается почти с показанного.
        var again = Self.playing()
        _ = Self.quiet(&again, at: 0.2)
        let shown = Self.frame(&again, layers: [0, 0, 0], level: 0, glow: 0, silent: false, now: Self.start + 0.25)
        let first = Self.quiet(&again, at: 0.25 + 1.0 / 120)
        #expect(abs(first.layers[0] - shown.layers[0]) < 1e-3)
    }

    /// «Вздох» и мягкий пульс угасают, как свечение: на тишине удержанное × множитель, новых
    /// вздохов и горбов нет; со звуком посреди угасания `max(вход, пол)`. Вызов без них тот же, что
    /// с нулями.
    @Test func pulseAndAmbientFadeLikeGlow() {
        var bands: [Float] = []
        var stop = SoftStop()
        var layers = Self.soundLayers
        var level: Float = 0.8
        var glow: Float = 0.6
        var pulse: Float = 0.5
        var ambient: Float = 0.16
        stop.apply(
            layers: &layers, bands: &bands, level: &level, glow: &glow, pulse: &pulse, ambient: &ambient,
            silent: false, now: Self.start
        )
        #expect(pulse == 0.5 && ambient == 0.16)
        for t in [0.1, 0.3, 0.5, 0.6, 2] {
            var quietLayers: [Float] = [0, 0, 0]
            var quietLevel: Float = 0
            var quietGlow: Float = 0.9
            var phantomPulse: Float = 1
            var phantomAmbient: Float = 0.18
            stop.apply(
                layers: &quietLayers, bands: &bands, level: &quietLevel, glow: &quietGlow, pulse: &phantomPulse,
                ambient: &phantomAmbient, silent: true, now: Self.start + t
            )
            #expect(abs(phantomPulse - 0.5 * Self.factor(t)) < 1e-6, "t \(t): \(phantomPulse)")
            #expect(abs(phantomAmbient - 0.16 * Self.factor(t)) < 1e-6, "t \(t): \(phantomAmbient)")
        }
        #expect(!stop.isFading)

        var returning = SoftStop()
        var l = Self.soundLayers
        var lv: Float = 0.8
        var g: Float = 0.6
        var p: Float = 0.5
        var a: Float = 0.16
        returning.apply(layers: &l, bands: &bands, level: &lv, glow: &g, pulse: &p, ambient: &a, silent: false, now: Self.start)
        var q: [Float] = [0, 0, 0]
        var ql: Float = 0
        var qg: Float = 0
        var qp: Float = 0
        var qa: Float = 0
        returning.apply(
            layers: &q, bands: &bands, level: &ql, glow: &qg, pulse: &qp, ambient: &qa, silent: true, now: Self.start + 0.2
        )
        var lowPulse: Float = 0.05
        var lowAmbient: Float = 0.01
        returning.apply(
            layers: &q, bands: &bands, level: &ql, glow: &qg, pulse: &lowPulse, ambient: &lowAmbient, silent: false,
            now: Self.start + 0.3
        )
        #expect(abs(lowPulse - 0.25) < 1e-5)
        #expect(abs(lowAmbient - 0.08) < 1e-5)
        var highPulse: Float = 0.9
        var highAmbient: Float = 0.17
        returning.apply(
            layers: &q, bands: &bands, level: &ql, glow: &qg, pulse: &highPulse, ambient: &highAmbient, silent: false,
            now: Self.start + 0.35
        )
        #expect(highPulse == 0.9 && highAmbient == 0.17)
    }

    @Test func phantomGlowSuppressedWhileSilent() {
        var stop = Self.playing()
        for t in [0.01, 0.1, 0.3, 0.5, 0.59, 0.6, 1, 5] {
            let shown = Self.quiet(&stop, at: t, glow: 0.9)
            #expect(shown.glow <= Self.soundGlow * Self.factor(t) + 1e-6, "t \(t): \(shown.glow)")
        }
        #expect(!stop.isFading)
    }

    @Test func louderInputWinsDuringFade() {
        var stop = Self.playing()
        let shown = Self.frame(&stop, layers: [0.9, 0.1, 0.5], level: 0.9, glow: 0, silent: true, now: Self.start + 0.3)
        #expect(shown.layers[0] == 0.9)
        #expect(abs(shown.layers[1] - 0.25) < 1e-4)
        #expect(shown.layers[2] == 0.5)
        #expect(shown.level == 0.9)
        #expect(abs(shown.glow - 0.3) < 1e-4)
    }

    @Test func silenceFromStartStaysSilent() {
        var stop = SoftStop()
        for step in 0..<10 {
            let shown = Self.frame(
                &stop, layers: [0, 0, 0], bands: [Float](repeating: 0, count: BandMapper.bandCount), level: 0,
                glow: 0.8, silent: true, now: Self.start + Double(step) / 60
            )
            #expect(shown.layers == [0, 0, 0])
            #expect(shown.bands == [Float](repeating: 0, count: BandMapper.bandCount))
            #expect(shown.level == 0)
            #expect(shown.glow == 0)
            #expect(!stop.isFading)
        }
    }

    @Test func fadeIsFrameRateIndependent() {
        func shown(step: Double) -> Shown {
            var stop = Self.playing(bands: [Float](repeating: 0.6, count: BandMapper.bandCount))
            var result = Shown(layers: [], bands: [], level: 0, glow: 0)
            // Кадры через `step`, последний ровно на 0.3 с (0.3 не кратно 1/12).
            var times = Array(stride(from: step, to: 0.3 - 1e-9, by: step))
            times.append(0.3)
            for t in times {
                result = Self.quiet(&stop, at: t, bands: BandMapper.bandCount)
            }
            return result
        }
        let fast = shown(step: 1.0 / 120)
        let slow = shown(step: 1.0 / 12)
        for (a, b) in zip(fast.layers, slow.layers) {
            #expect(abs(a - b) < 1e-4)
        }
        for (a, b) in zip(fast.bands, slow.bands) {
            #expect(abs(a - b) < 1e-4)
        }
        #expect(abs(fast.level - slow.level) < 1e-4)
        #expect(abs(fast.glow - slow.glow) < 1e-4)
        #expect(abs(fast.layers[0] - 0.4) < 1e-4)
    }

    @Test func badInputSafe() {
        // Не конечные значения входа на тишине дают конечный результат.
        var stop = Self.playing()
        let nan = Self.frame(
            &stop, layers: [.nan, .infinity, -.infinity], level: .nan, glow: .nan, silent: true, now: Self.start + 0.3
        )
        #expect(nan.layers.allSatisfy { $0.isFinite })
        #expect(nan.level.isFinite && nan.glow.isFinite)
        #expect(abs(nan.layers[0] - 0.4) < 1e-4)

        // Не конечный звук не попадает в удержание.
        var poisoned = SoftStop()
        _ = Self.frame(&poisoned, layers: [.nan, 0.5, .infinity], level: .nan, glow: .infinity, silent: false, now: Self.start)
        let after = Self.quiet(&poisoned, at: 0.3)
        #expect(after.layers.allSatisfy { $0.isFinite })
        #expect(after.level.isFinite && after.glow.isFinite)

        // Часы назад: угасание стоит в начале и идет дальше, когда часы пошли вперед.
        var back = Self.playing()
        _ = Self.quiet(&back, at: 0.3)
        let rewound = Self.quiet(&back, at: -1)
        #expect(abs(rewound.layers[0] - 0.8) < 1e-4)
        #expect(back.isFading)
        let resumed = Self.quiet(&back, at: -1 + 0.3)
        #expect(abs(resumed.layers[0] - 0.4) < 1e-4)

        // Не конечное время кончает угасание.
        var clock = Self.playing()
        let broken = Self.frame(&clock, layers: [0, 0, 0], level: 0, glow: 0.9, silent: true, now: .nan)
        #expect(broken.layers == [0, 0, 0])
        #expect(broken.glow == 0)
        #expect(!clock.isFading)

        // Звук с не конечным временем: угасания нет, тишина сразу тихая.
        var timeless = SoftStop()
        _ = Self.frame(&timeless, layers: Self.soundLayers, level: 0.8, glow: 0.6, silent: false, now: .infinity)
        let silentNext = Self.quiet(&timeless, at: 0.1)
        #expect(silentNext.layers == [0, 0, 0] && silentNext.glow == 0)
        #expect(!timeless.isFading)

        // Слои другой длины и пустые массивы проходят как есть.
        var lengths = Self.playing()
        let two = Self.frame(&lengths, layers: [0.2, 0.1], level: 0, glow: 0, silent: true, now: Self.start + 0.1)
        #expect(two.layers == [0.2, 0.1])
        let empty = Self.frame(&lengths, layers: [], level: 0, glow: 0, silent: true, now: Self.start + 0.2)
        #expect(empty.layers.isEmpty && empty.bands.isEmpty)
    }
    /// Пауза источника по Now Playing: только у источника-приложения и только по текущей записи
    /// Now Playing этого приложения. Яндекс Музыка на паузе, затем Now Playing перешел к видео в
    /// Safari или опустел: паузы нет, мягкая остановка идет по тишине.
    @Test func sourcePausedReadsTheCurrentRecord() {
        let yandex = AudioSource.application(
            bundleID: "ru.yandex.desktop.music", bundlePath: "/Applications/Яндекс Музыка.app", displayName: "Яндекс Музыка"
        )
        let paused = NowPlayingInfo(bundleIdentifier: "ru.yandex.desktop.music", title: "Трек", isPlaying: false)
        var playing = paused
        playing.isPlaying = true
        let safari = NowPlayingInfo(bundleIdentifier: "com.apple.Safari", title: "Видео", isPlaying: true)
        let safariPaused = NowPlayingInfo(bundleIdentifier: "com.apple.Safari", title: "Видео", isPlaying: false)

        #expect(SoftStop.sourcePaused(source: yandex, current: paused, nowPlayingAvailable: true))
        #expect(!SoftStop.sourcePaused(source: yandex, current: playing, nowPlayingAvailable: true))
        #expect(!SoftStop.sourcePaused(source: yandex, current: safari, nowPlayingAvailable: true))
        #expect(!SoftStop.sourcePaused(source: yandex, current: safariPaused, nowPlayingAvailable: true))
        #expect(!SoftStop.sourcePaused(source: yandex, current: nil, nowPlayingAvailable: true))
        #expect(!SoftStop.sourcePaused(source: yandex, current: paused, nowPlayingAvailable: false))
        // У всего звука системы пауза по Now Playing не считается.
        #expect(!SoftStop.sourcePaused(source: .systemWide, current: paused, nowPlayingAvailable: true))
    }
    /// Тишина по уровню с запасом на выход: тишина наступает, когда сырой уровень не выше порога
    /// шума волн, и кончается, только когда он поднялся выше порога плюс `returnMarginDB`. Пока
    /// звука нет, уровень у самого порога тишину не прерывает.
    @Test func noiseFloorHasReturnMargin() {
        #expect(SoftStop.returnMarginDB == 3)
        let floor = LevelProcessor.noiseFloorDB
        var stop = SoftStop()
        let levels: [Float] = [floor + 10, floor + 1, floor, floor + 1, floor + 3, floor + 3.5, floor + 1, floor - 1, -.infinity, floor + 20]
        let answers = levels.map { stop.belowNoiseFloor(levelDB: $0) }
        #expect(answers == [false, false, true, true, true, false, false, true, true, false])
    }

    /// Звук пропал, а уровень шума ходит вокруг порога (на кадре ниже, на следующем выше): угасание
    /// идет обычные 0,6 с и кончается, остров может уйти в простой. Без запаса каждый кадр выше
    /// порога начинал угасание заново, и оно не кончалось.
    @Test func noiseAroundFloorStillEndsFade() {
        let floor = LevelProcessor.noiseFloorDB
        var stop = Self.playing()
        _ = stop.belowNoiseFloor(levelDB: -20)
        var last = Shown(layers: [], bands: [], level: 0, glow: 0)
        for step in 1...60 {
            let levelDB = step.isMultiple(of: 2) ? floor + 1 : floor - 1
            let silent = stop.belowNoiseFloor(levelDB: levelDB)
            #expect(silent)
            last = Self.frame(
                &stop, layers: [0, 0, 0], level: 0, glow: 0, silent: silent, now: Self.start + Double(step) / 60
            )
        }
        #expect(last.layers == [0, 0, 0])
        #expect(last.level == 0)
        #expect(!stop.isFading)

        // Тот же шум без запаса: угасание тянется и через секунду еще идет.
        var raw = Self.playing()
        for step in 1...60 {
            let levelDB = step.isMultiple(of: 2) ? floor + 1 : floor - 1
            _ = Self.frame(
                &raw, layers: [0, 0, 0], level: 0, glow: 0, silent: levelDB <= floor, now: Self.start + Double(step) / 60
            )
        }
        #expect(raw.isFading)
    }
}
