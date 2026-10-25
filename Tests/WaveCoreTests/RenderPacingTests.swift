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
        #expect(summary.spreadText.hasPrefix("интервал σ "))
        #expect(summary.spreadText.hasSuffix(" мс | шкала σ \(String(format: "%.1f", summary.timelineSigmaMs)) мс"))
    }
}
