import Foundation
import Testing
@testable import WaveCore

struct RenderPacingTests {
    private static let period = 1.0 / 60

    /// Пишет кадры с интервалами `intervals` (первый кадр только начинает замер). Шкала
    /// `TimelineView` идет ровно с тем же шагом, номер кадра анализа растет на `sequenceSteps`
    /// (по кругу), по умолчанию на 1.
    private func record(
        _ intervals: [Double],
        bucket: RenderBucket = .collapsed,
        sequenceSteps: [UInt64] = [1],
        into pacing: inout RenderPacing,
        start: Double = 100
    ) {
        var now = start
        var sequence: UInt64 = 10
        pacing.record(now: now, timelineTime: now + 5_000, bucket: bucket, analysisSequence: sequence)
        for (index, interval) in intervals.enumerated() {
            now += interval
            sequence += sequenceSteps[index % sequenceSteps.count]
            pacing.record(now: now, timelineTime: now + 5_000, bucket: bucket, analysisSequence: sequence)
        }
    }

    @Test func bucketsIntervals() throws {
        var pacing = RenderPacing()
        let intervals = [Double](repeating: 0.0167, count: 90)
            + [Double](repeating: 0.0333, count: 8)
            + [Double](repeating: 0.050, count: 2)
        record(intervals, into: &pacing)
        let summary = try #require(pacing.summary(.collapsed, refreshPeriod: Self.period))
        #expect(summary.frames == 100)
        #expect(abs(summary.onTime - 0.9) < 1e-9)
        #expect(abs(summary.oneMissed - 0.08) < 1e-9)
        #expect(abs(summary.twoOrMore - 0.02) < 1e-9)
        #expect(abs(summary.p50Ms - 16.7) < 0.1)
        #expect(abs(summary.p95Ms - 33.3) < 0.1)
        #expect(abs(summary.maxMs - 50) < 0.1)
        #expect(abs(summary.timelineSigmaMs - summary.intervalSigmaMs) < 1e-3)
        #expect(pacing.summary(.expanded, refreshPeriod: Self.period) == nil)
        #expect(pacing.summary(.transition, refreshPeriod: Self.period) == nil)
    }

    @Test func sigmaOfIntervalsAndTimeline() throws {
        var pacing = RenderPacing()
        var now = 10.0
        var timeline = 0.0
        pacing.record(now: now, timelineTime: timeline, bucket: .expanded, analysisSequence: 0)
        // Интервалы чередуются 15 и 18 мс (σ 1.5 мс), шкала идет ровно по 16.5 мс (σ 0).
        for index in 0..<100 {
            now += index.isMultiple(of: 2) ? 0.015 : 0.018
            timeline += 0.0165
            pacing.record(now: now, timelineTime: timeline, bucket: .expanded, analysisSequence: UInt64(index + 1))
        }
        let summary = try #require(pacing.summary(.expanded, refreshPeriod: Self.period))
        #expect(abs(summary.intervalSigmaMs - 1.5) < 1e-6)
        #expect(summary.timelineSigmaMs < 1e-6)
    }

    @Test func skipsLongGaps() throws {
        var pacing = RenderPacing()
        record([0.0167, 0.0167, 0.3, 0.0167], into: &pacing)
        let summary = try #require(pacing.summary(.collapsed, refreshPeriod: Self.period))
        #expect(summary.frames == 3)
        #expect(abs(summary.maxMs - 16.7) < 0.1)
        #expect(summary.onTime == 1)
    }

    @Test func ignoresInvalidTime() throws {
        var pacing = RenderPacing()
        pacing.record(now: 1, timelineTime: 1, bucket: .collapsed, analysisSequence: 0)
        pacing.record(now: .nan, timelineTime: 1, bucket: .collapsed, analysisSequence: 1)
        pacing.record(now: 0.5, timelineTime: 1, bucket: .collapsed, analysisSequence: 2)
        #expect(pacing.summary(.collapsed, refreshPeriod: Self.period) == nil)
        pacing.record(now: 0.52, timelineTime: .infinity, bucket: .collapsed, analysisSequence: 3)
        let summary = try #require(pacing.summary(.collapsed, refreshPeriod: Self.period))
        #expect(summary.frames == 1)
        #expect(summary.timelineSigmaMs == 0)
        #expect(pacing.summary(.collapsed, refreshPeriod: 0)?.frames == 1)
    }

    @Test func countsAnalysisFrames() throws {
        var pacing = RenderPacing()
        record([Double](repeating: 0.0167, count: 6), sequenceSteps: [1, 1, 0, 2, 3, 5], into: &pacing)
        let summary = try #require(pacing.summary(.collapsed, refreshPeriod: Self.period))
        let expected = [1.0 / 6, 2.0 / 6, 1.0 / 6, 2.0 / 6]
        #expect(summary.analysisFrames.count == 4)
        for (value, target) in zip(summary.analysisFrames, expected) {
            #expect(abs(value - target) < 1e-9)
        }
    }

    @Test func samplesGoToTheCurrentBucket() throws {
        var pacing = RenderPacing()
        pacing.record(now: 1, timelineTime: 1, bucket: .collapsed, analysisSequence: 0)
        pacing.record(now: 1.0167, timelineTime: 1.0167, bucket: .collapsed, analysisSequence: 1)
        pacing.record(now: 1.0500, timelineTime: 1.0500, bucket: .transition, analysisSequence: 2)
        pacing.record(now: 1.0667, timelineTime: 1.0667, bucket: .expanded, analysisSequence: 3)
        #expect(pacing.summary(.collapsed, refreshPeriod: Self.period)?.frames == 1)
        #expect(pacing.summary(.transition, refreshPeriod: Self.period)?.frames == 1)
        #expect(pacing.summary(.expanded, refreshPeriod: Self.period)?.frames == 1)
        let transition = try #require(pacing.summary(.transition, refreshPeriod: Self.period))
        #expect(transition.oneMissed == 1)
    }

    @Test func transitionWindow() {
        #expect(RenderPacing.transitionWindow == 1.0)
        #expect(RenderBucket.classify(state: .expanded, sinceStateChange: 0.5) == .transition)
        #expect(RenderBucket.classify(state: .collapsed, sinceStateChange: 0.99) == .transition)
        #expect(RenderBucket.classify(state: .expanded, sinceStateChange: 1.2) == .expanded)
        #expect(RenderBucket.classify(state: .collapsed, sinceStateChange: 3) == .collapsed)
        #expect(RenderBucket.classify(state: .hidden, sinceStateChange: 5) == .collapsed)
        #expect(RenderBucket.classify(state: .expanded, sinceStateChange: .infinity) == .expanded)
        #expect(RenderBucket.allCases == [.collapsed, .expanded, .transition])
    }

    @Test func keepsLast3600() throws {
        #expect(RenderPacing.window == 3600)
        #expect(RenderPacing.maxGap == 0.25)
        var pacing = RenderPacing()
        // Первые 400 интервалов опоздали на кадр, следующие 3600 вовремя: старые вытеснены.
        let intervals = [Double](repeating: 0.0333, count: 400) + [Double](repeating: 0.0167, count: 3600)
        record(intervals, into: &pacing)
        let summary = try #require(pacing.summary(.collapsed, refreshPeriod: Self.period))
        #expect(summary.frames == 3600)
        #expect(summary.onTime == 1)
        #expect(abs(summary.maxMs - 16.7) < 0.1)
    }

    @Test func medianOfRecentIntervals() throws {
        var pacing = RenderPacing()
        #expect(pacing.medianInterval(last: 60) == nil)
        record([Double](repeating: 0.0167, count: 59) + [0.050], into: &pacing)
        let median = try #require(pacing.medianInterval(last: 60))
        #expect(abs(median - 0.0167) < 1e-4)
        #expect(pacing.medianInterval(last: 61) == nil)
        #expect(pacing.medianInterval(last: 0) == nil)
        #expect(abs((pacing.medianInterval(last: 1) ?? 0) - 0.050) < 1e-9)
    }

    /// Медиана пересчитывается на 60-м интервале и дальше раз в 15 новых.
    @Test func medianIsRefreshedEveryFifteenIntervals() throws {
        var pacing = RenderPacing()
        func refresh() -> Double? {
            pacing.refreshedMedian(last: 60, every: 15)
        }
        record([Double](repeating: 0.0167, count: 59), into: &pacing)
        #expect(refresh() == nil)
        record([0.0167], into: &pacing, start: 10)
        let first = try #require(refresh())
        #expect(abs(first - 0.0167) < 1e-9)

        record([Double](repeating: 0.0333, count: 14), into: &pacing, start: 30)
        #expect(refresh() == nil)
        record([Double](repeating: 0.0333, count: 1), into: &pacing, start: 40)
        #expect(refresh() != nil)
        #expect(refresh() == nil)

        record([Double](repeating: 0.0333, count: 30), into: &pacing, start: 50)
        let later = try #require(refresh())
        #expect(abs(later - 0.0333) < 1e-9)
    }

    @Test func medianSpansBuckets() throws {
        var pacing = RenderPacing()
        record([Double](repeating: 0.0333, count: 30), bucket: .collapsed, into: &pacing, start: 10)
        // Пауза больше `maxGap`: замер начинается заново, интервалы в другой корзине.
        record([Double](repeating: 0.0333, count: 30), bucket: .expanded, into: &pacing, start: 20)
        let median = try #require(pacing.medianInterval(last: 60))
        #expect(abs(median - 0.0333) < 1e-9)
    }

    @Test func refreshPeriodFromScreenRate() {
        #expect(RenderPacing.refreshPeriod(framesPerSecond: 60) == 1.0 / 60)
        #expect(RenderPacing.refreshPeriod(framesPerSecond: 120) == 1.0 / 120)
        #expect(RenderPacing.refreshPeriod(framesPerSecond: 0) == 1.0 / 60)
        #expect(RenderPacing.refreshPeriod(framesPerSecond: -5) == 1.0 / 60)
    }

    @Test func timelineIntervalFollowsScreen() {
        let slack = RenderPacing.intervalSlack
        #expect(slack == 0.9)
        #expect(abs(RenderPacing.timelineInterval(refreshPeriod: 1.0 / 60, lowPower: false) - slack / 60) < 1e-9)
        // Частота кадров по умолчанию 60 ограничивает и экран 120 Гц (до 1.3 он рисовался на 120).
        #expect(abs(RenderPacing.timelineInterval(refreshPeriod: 1.0 / 120, lowPower: false) - slack / 60) < 1e-9)
        // Энергосбережение как в 1.1: ровно 1/30 (IslandView.swift:101), не больше 30 кадров.
        #expect(RenderPacing.timelineInterval(refreshPeriod: 1.0 / 60, lowPower: true) == 1.0 / 30)
        #expect(RenderPacing.timelineInterval(refreshPeriod: 1.0 / 120, lowPower: true) == 1.0 / 30)
        // Странный период экрана: как у экрана 60 Гц.
        #expect(abs(RenderPacing.timelineInterval(refreshPeriod: 0, lowPower: false) - slack / 60) < 1e-9)
        #expect(abs(RenderPacing.timelineInterval(refreshPeriod: .nan, lowPower: false) - slack / 60) < 1e-9)
    }

    @Test func frameRateChoiceIsThirtyOrSixty() {
        #expect(RenderPacing.frameRates == [30, 60])
        #expect(RenderPacing.defaultFrameRate == 60)
        #expect(RenderPacing.normalizedFrameRate(30) == 30)
        #expect(RenderPacing.normalizedFrameRate(60) == 60)
        for stray in [0, -30, 24, 45, 120, Int.max] {
            #expect(RenderPacing.normalizedFrameRate(stray) == 60)
        }
    }

    @Test func thirtyFpsGivesThirtyFpsCadenceOnAnyScreen() {
        let slack = RenderPacing.intervalSlack
        for screen in [1.0 / 60, 1.0 / 120] {
            #expect(RenderPacing.cadencePeriod(refreshPeriod: screen, frameRate: 30, lowPower: false) == 1.0 / 30)
            let interval = RenderPacing.timelineInterval(refreshPeriod: screen, lowPower: false, frameRate: 30)
            #expect(abs(interval - slack / 30) < 1e-12)
            // Тик сетки 120 Гц через 25 мс не проходит, через 33.3 мс проходит: 30 кадров в секунду.
            #expect(interval > 3.0 / 120)
            #expect(interval <= 4.0 / 120)
        }
        // Низкая частота энергосбережения и выбранные 30 дают те же ровно 1/30.
        #expect(RenderPacing.timelineInterval(refreshPeriod: 1.0 / 60, lowPower: true, frameRate: 30) == 1.0 / 30)
    }

    @Test func sixtyFpsStaysSixtyOnSixtyAndOneTwentyHertz() {
        let slack = RenderPacing.intervalSlack
        for screen in [1.0 / 60, 1.0 / 120] {
            #expect(RenderPacing.cadencePeriod(refreshPeriod: screen, frameRate: 60, lowPower: false) == 1.0 / 60)
            let interval = RenderPacing.timelineInterval(refreshPeriod: screen, lowPower: false, frameRate: 60)
            #expect(abs(interval - slack / 60) < 1e-12)
        }
        // Без указания частоты как раньше: 60 кадров.
        #expect(
            RenderPacing.timelineInterval(refreshPeriod: 1.0 / 120, lowPower: false)
                == RenderPacing.timelineInterval(refreshPeriod: 1.0 / 120, lowPower: false, frameRate: 60)
        )
        // Экран медленнее выбранной частоты: кадров не больше, чем у экрана.
        #expect(RenderPacing.cadencePeriod(refreshPeriod: 1.0 / 24, frameRate: 60, lowPower: false) == 1.0 / 24)
        #expect(RenderPacing.cadencePeriod(refreshPeriod: .nan, frameRate: 60, lowPower: false) == 1.0 / 60)
        #expect(RenderPacing.cadencePeriod(refreshPeriod: 1.0 / 120, frameRate: 7, lowPower: false) == 1.0 / 60)
        // Энергосбережение держит 30 даже при выбранных 60.
        #expect(RenderPacing.cadencePeriod(refreshPeriod: 1.0 / 120, frameRate: 60, lowPower: true) == 1.0 / 30)
    }

    /// Упреждение показа это два периода экрана при любой «Частоте кадров» и в энергосбережении:
    /// конвейер компоновки идет по кадрам экрана. Период выборки свечения (R/2 в `BeatGlow`) идет за
    /// частотой кадров приложения. На экране 60 Гц и 60 кадрах все как в 1.2: 33 мс и R 1/60.
    @Test func presentationLeadFollowsTheScreenAndCentringTheFrameRate() {
        func timing(screen: Double, rate: Int, lowPower: Bool, measured: Double? = nil) -> PresentationTiming {
            let cadence = RenderPacing.cadencePeriod(refreshPeriod: screen, frameRate: rate, lowPower: lowPower)
            let period = RenderPacing.effectivePeriod(measured: measured, refreshPeriod: cadence)
            return PresentationTiming(refreshPeriod: screen, framePeriod: period)
        }
        let base = timing(screen: 1.0 / 60, rate: 60, lowPower: false)
        #expect(abs(base.lead - 2.0 / 60) < 1e-12)
        #expect(base.framePeriod == 1.0 / 60)
        #expect(base.presented(at: 100) == 100 + base.lead)
        // Экран 60 Гц, 30 кадров: упреждение то же, кадр держится 1/30 с.
        let thirty = timing(screen: 1.0 / 60, rate: 30, lowPower: false)
        #expect(thirty.lead == base.lead)
        #expect(thirty.framePeriod == 1.0 / 30)
        // Экран 120 Гц: упреждение 2/120 и при 60, и при 30 кадрах.
        for rate in [60, 30] {
            let fast = timing(screen: 1.0 / 120, rate: rate, lowPower: false)
            #expect(abs(fast.lead - 2.0 / 120) < 1e-12, "rate \(rate)")
            #expect(fast.framePeriod == 1 / Double(rate), "rate \(rate)")
        }
        // Энергосбережение: кадры 1/30 (до замера и по замеру), упреждение по экрану.
        for screen in [1.0 / 60, 1.0 / 120] {
            for measured in [nil, 1.0 / 30] as [Double?] {
                let saving = timing(screen: screen, rate: 60, lowPower: true, measured: measured)
                #expect(abs(saving.lead - 2 * screen) < 1e-12)
                #expect(saving.framePeriod == 1.0 / 30)
            }
        }
        // Пропуски кадров удлиняют R, но не упреждение.
        let slow = timing(screen: 1.0 / 60, rate: 60, lowPower: false, measured: 1.0 / 40)
        #expect(slow.lead == base.lead)
        #expect(slow.framePeriod == 1.0 / 40)
        // Странные значения: экран 1/60 с, период кадров по экрану.
        for bad in [Double.nan, .infinity, 0, -1] {
            let odd = PresentationTiming(refreshPeriod: bad, framePeriod: bad)
            #expect(abs(odd.lead - 2.0 / 60) < 1e-12)
            #expect(odd.framePeriod == 1.0 / 60)
        }
        #expect(PresentationTiming(refreshPeriod: 1.0 / 120, framePeriod: .nan).framePeriod == 1.0 / 120)
    }

    @Test func resetMedianDropsIntervalsOfTheOldRate() throws {
        var pacing = RenderPacing()
        record([Double](repeating: 1.0 / 30, count: 90), bucket: .expanded, into: &pacing)
        #expect(try #require(pacing.medianInterval(last: 60)) > 0.03)
        pacing.resetMedian()
        #expect(pacing.medianInterval(last: 60) == nil)
        let empty = pacing.refreshedMedian(last: 60, every: 15)
        #expect(empty == nil)
        // Сводка корзины остается, новые интервалы дают новую медиану.
        #expect(pacing.summary(.expanded, refreshPeriod: 1.0 / 30) != nil)
        record([Double](repeating: 1.0 / 60, count: 70), bucket: .expanded, into: &pacing, start: 1000)
        let fresh = pacing.refreshedMedian(last: 60, every: 15)
        let median = try #require(fresh)
        #expect(abs(median - 1.0 / 60) < 1e-9)
    }

    @Test func idleIntervalIgnoresFrameRate() {
        #expect(RenderIdleDetector.idleInterval == 1.0 / 12)
    }

    @Test func effectivePeriodNeverBelowScreen() {
        #expect(RenderPacing.effectivePeriod(measured: 1.0 / 120, refreshPeriod: 1.0 / 60) == 1.0 / 60)
        #expect(RenderPacing.effectivePeriod(measured: 1.0 / 40, refreshPeriod: 1.0 / 60) == 1.0 / 40)
        #expect(RenderPacing.effectivePeriod(measured: nil, refreshPeriod: 1.0 / 60) == 1.0 / 60)
        // Энергосбережение: замер 30 Гц дает период кадров 1/30.
        #expect(RenderPacing.effectivePeriod(measured: 1.0 / 30, refreshPeriod: 1.0 / 60) == 1.0 / 30)
        // Остров переехал на экран 120 Гц, замер еще со старого экрана 60 Гц: держится замер.
        #expect(RenderPacing.effectivePeriod(measured: 1.0 / 60, refreshPeriod: 1.0 / 120) == 1.0 / 60)
        #expect(RenderPacing.effectivePeriod(measured: .nan, refreshPeriod: 1.0 / 60) == 1.0 / 60)
    }

    @Test func summaryText() throws {
        var pacing = RenderPacing()
        let intervals = [Double](repeating: 0.0167, count: 90)
            + [Double](repeating: 0.0333, count: 8)
            + [Double](repeating: 0.050, count: 2)
        record(intervals, sequenceSteps: [1, 1, 1, 1, 1, 1, 1, 1, 0, 2], into: &pacing)
        let summary = try #require(pacing.summary(.collapsed, refreshPeriod: Self.period))
        #expect(summary.pacingText
            == "100 кадров | вовремя 90.0 % | 1 пропуск 8.0 % | 2+ 2.0 % | p50 16.7 мс | p95 33.3 мс | max 50 мс")
        #expect(summary.analysisFramesText == "0: 10 % | 1: 80 % | 2: 10 % | 3+: 0 %")
        // 100 интервалов за 1.8694 с.
        #expect(summary.description == summary.pacingText + " | 53.5 кадров/с")
        #expect(summary.spreadText.hasPrefix("интервал σ "))
        #expect(summary.spreadText.hasSuffix(" мс | шкала σ \(String(format: "%.1f", summary.timelineSigmaMs)) мс"))
    }

    @Test func loggedBuckets() {
        #expect(RenderBucket.logged(state: .expanded, probe: false) == [.expanded])
        #expect(RenderBucket.logged(state: .collapsed, probe: false).isEmpty)
        #expect(RenderBucket.logged(state: .hidden, probe: false).isEmpty)
        for state in [IslandState.hidden, .collapsed, .expanded] {
            #expect(RenderBucket.logged(state: state, probe: true) == [.collapsed, .expanded])
        }
    }

    @Test func framesPerSecondOverDrawnIntervals() throws {
        var pacing = RenderPacing()
        record([0.01, 0.02, 0.03], into: &pacing)
        let summary = try #require(pacing.summary(.collapsed, refreshPeriod: Self.period))
        #expect(abs(summary.framesPerSecond - 50) < 1e-9)
        #expect(summary.description.hasSuffix(" | 50.0 кадров/с"))

        // Пауза длиннее `maxGap` и кадры после `restart()` в секунды отрисовки не идут.
        var gapped = RenderPacing()
        record([0.02, 0.5, 0.02], bucket: .expanded, into: &gapped)
        gapped.restart()
        gapped.record(now: 200, timelineTime: 5_200, bucket: .expanded, analysisSequence: 50)
        gapped.record(now: 200.02, timelineTime: 5_200.02, bucket: .expanded, analysisSequence: 51)
        let expanded = try #require(gapped.summary(.expanded, refreshPeriod: Self.period))
        #expect(expanded.frames == 3)
        #expect(abs(expanded.framesPerSecond - 50) < 1e-6)
    }

    @Test func restartSkipsOneInterval() throws {
        var pacing = RenderPacing()
        record([0.0167, 0.0167], into: &pacing)
        let median = try #require(pacing.medianInterval(last: 2))
        // Кадры простоя через 83 мс: интервал до следующего кадра не пишется, замер не теряется.
        pacing.restart()
        pacing.record(now: 100.12, timelineTime: 5_100.12, bucket: .collapsed, analysisSequence: 20)
        #expect(try #require(pacing.summary(.collapsed, refreshPeriod: Self.period)).frames == 2)
        #expect(pacing.medianInterval(last: 2) == median)
        pacing.record(now: 100.12 + 0.0167, timelineTime: 5_100.12 + 0.0167, bucket: .collapsed, analysisSequence: 21)
        #expect(try #require(pacing.summary(.collapsed, refreshPeriod: Self.period)).frames == 3)
    }
}

struct RenderIdleDetectorTests {
    /// Результаты `update` по кадрам `(level, glow, pulse, now)`; `#expect` не принимает
    /// изменяющий вызов внутри себя.
    private func run(_ detector: inout RenderIdleDetector, _ frames: [(Float, Float, Float, Double)]) -> [Bool] {
        frames.map { detector.update(level: $0.0, glow: $0.1, pulse: $0.2, now: $0.3) }
    }

    @Test func constants() {
        #expect(RenderIdleDetector.level == Float(0.01))
        #expect(RenderIdleDetector.settle == 0.5)
        #expect(RenderIdleDetector.idleInterval == 1.0 / 12)
    }

    @Test func idleAfterHalfSecondFlat() {
        var detector = RenderIdleDetector()
        let early = run(&detector, (0..<24).map { (Float(0.005), Float(0), Float(0), Double($0) / 60) })
        #expect(!early.contains(true))
        let atFourTenths = run(&detector, [(0.005, 0, 0, 0.4)])
        #expect(atFourTenths == [false])
        #expect(!detector.isIdle)
        let atSixTenths = run(&detector, [(0.005, 0, 0, 0.6)])
        #expect(atSixTenths == [true])
        #expect(detector.isIdle)
    }

    @Test func activeImmediatelyOnSound() {
        var detector = RenderIdleDetector()
        let idle = run(&detector, [(0, 0, 0, 0), (0, 0, 0, 1)])
        #expect(idle == [false, true])
        let sound = run(&detector, [(0.05, 0, 0, 1.05)])
        #expect(sound == [false])
        #expect(!detector.isIdle)
        // Звук снова стих: простой через `settle` после последнего ненулевого входа.
        let quiet = run(&detector, [(0, 0, 0, 1.4), (0, 0, 0, 1.6)])
        #expect(quiet == [false, true])
    }

    @Test func glowKeepsActive() {
        var detector = RenderIdleDetector()
        let lit = run(&detector, (0...60).map { (Float(0), Float(0.1), Float(0), Double($0) / 60) })
        #expect(!lit.contains(true))
        let dark = run(&detector, [(0, 0, 0, 1.4), (0, 0, 0, 1.6)])
        #expect(dark == [false, true])
        // «Вздох» и не конечный вход тоже держат полную частоту.
        let breath = run(&detector, [(0, 0, 0.2, 3), (0, 0, 0, 3.5), (Float.nan, 0, 0, 4)])
        #expect(breath == [false, true, false])
    }

    @Test func clockQuirks() {
        var detector = RenderIdleDetector()
        let flat = run(&detector, [(0, 0, 0, 10), (0, 0, 0, 10.6)])
        #expect(flat == [false, true])
        // Не конечный момент ничего не меняет, момент из прошлого начинает выдержку заново.
        let odd = run(&detector, [(0, 0, 0, .nan), (0, 0, 0, 5), (0, 0, 0, 5.4), (0, 0, 0, 5.5)])
        #expect(odd == [true, false, false, true])
    }
}
