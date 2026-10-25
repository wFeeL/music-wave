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
        #expect(abs(RenderPacing.timelineInterval(refreshPeriod: 1.0 / 120, lowPower: false) - slack / 120) < 1e-9)
        // Энергосбережение как в 1.1: ровно 1/30 (IslandView.swift:101), не больше 30 кадров.
        #expect(RenderPacing.timelineInterval(refreshPeriod: 1.0 / 60, lowPower: true) == 1.0 / 30)
        #expect(RenderPacing.timelineInterval(refreshPeriod: 1.0 / 120, lowPower: true) == 1.0 / 30)
        // Странный период экрана: как у экрана 60 Гц.
        #expect(abs(RenderPacing.timelineInterval(refreshPeriod: 0, lowPower: false) - slack / 60) < 1e-9)
        #expect(abs(RenderPacing.timelineInterval(refreshPeriod: .nan, lowPower: false) - slack / 60) < 1e-9)
    }

    @Test func effectivePeriodNeverBelowScreen() {
        #expect(RenderPacing.effectivePeriod(measured: 1.0 / 120, refreshPeriod: 1.0 / 60) == 1.0 / 60)
        #expect(RenderPacing.effectivePeriod(measured: 1.0 / 40, refreshPeriod: 1.0 / 60) == 1.0 / 40)
        #expect(RenderPacing.effectivePeriod(measured: nil, refreshPeriod: 1.0 / 60) == 1.0 / 60)
        // Энергосбережение: замер 30 Гц дает упреждение показа от 33 мс и больше.
        let lowPower = RenderPacing.effectivePeriod(measured: 1.0 / 30, refreshPeriod: 1.0 / 60)
        #expect(lowPower == 1.0 / 30)
        #expect(LatencyCalculator.presentationLead(refreshPeriod: lowPower) >= 0.033)
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
