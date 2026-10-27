import Testing
@testable import WaveCore

struct BeatMetricsTests {
    /// 20 долей по 0.5 с (120 BPM).
    private static let beats = (0..<20).map { Double($0) * 0.5 }

    @Test func perfectMatch() {
        let f = BeatMetrics.fMeasure(detections: Self.beats, annotations: Self.beats, window: 0.07)
        #expect(f.precision == 1 && f.recall == 1 && f.f == 1)
        #expect(BeatMetrics.meanOffset(detections: Self.beats, annotations: Self.beats, window: 0.07) == 0)
        let c = BeatMetrics.continuity(detections: Self.beats, annotations: Self.beats)
        #expect(c.cmlt == 1 && c.cmlc == 1 && c.amlt == 1 && c.amlc == 1)
    }

    @Test func thirtyMillisecondsLate() throws {
        let late = Self.beats.map { $0 + 0.030 }
        let f = BeatMetrics.fMeasure(detections: late, annotations: Self.beats, window: 0.07)
        #expect(f.f == 1)
        let offset = try #require(BeatMetrics.meanOffset(detections: late, annotations: Self.beats, window: 0.07))
        #expect(abs(offset - 0.030) < 1e-12)
        // Допуск фазы 17.5 % от 0.5 с это 87.5 мс.
        #expect(BeatMetrics.continuity(detections: late, annotations: Self.beats).cmlt == 1)
    }

    @Test func outsideTheWindowIsAMiss() {
        let late = Self.beats.map { $0 + 0.100 }
        let f = BeatMetrics.fMeasure(detections: late, annotations: Self.beats, window: 0.07)
        #expect(f.precision == 0 && f.recall == 0 && f.f == 0)
        #expect(BeatMetrics.meanOffset(detections: late, annotations: Self.beats, window: 0.07) == nil)
        #expect(BeatMetrics.continuity(detections: late, annotations: Self.beats).cmlt == 0)
    }

    @Test func eachAnnotationMatchesOnce() {
        let doubled = Self.beats + Self.beats.map { $0 + 0.01 }
        let f = BeatMetrics.fMeasure(detections: doubled.sorted(), annotations: Self.beats, window: 0.07)
        #expect(f.precision == 0.5)
        #expect(f.recall == 1)
        #expect(abs(f.f - 2.0 / 3) < 1e-12)
    }

    @Test func matchingIsMaximal() {
        // Детекция 1.05 ближе к 1.0, но если взять ее, 1.1 останется без пары.
        let f = BeatMetrics.fMeasure(detections: [1.05, 1.15], annotations: [1.0, 1.1], window: 0.06)
        #expect(f.f == 1)
    }

    @Test func unsortedInputIsAccepted() {
        let f = BeatMetrics.fMeasure(detections: Self.beats.reversed(), annotations: Self.beats.shuffled(), window: 0.07)
        #expect(f.f == 1)
    }

    @Test func emptyInputs() {
        let f = BeatMetrics.fMeasure(detections: [], annotations: Self.beats, window: 0.07)
        #expect(f.precision == 0 && f.recall == 0 && f.f == 0)
        #expect(BeatMetrics.fMeasure(detections: Self.beats, annotations: [], window: 0.07).f == 0)
        #expect(BeatMetrics.meanOffset(detections: [], annotations: Self.beats, window: 0.07) == nil)
        let c = BeatMetrics.continuity(detections: [], annotations: Self.beats)
        #expect(c.cmlt == 0 && c.amlt == 0)
        #expect(BeatMetrics.continuity(detections: Self.beats, annotations: [1]).amlt == 0)
    }

    @Test func doubleTempoIsWrongLevelButAcceptedByAML() {
        let double = (0..<40).map { Double($0) * 0.25 }
        let c = BeatMetrics.continuity(detections: double, annotations: Self.beats)
        #expect(c.cmlt == 0)
        #expect(c.amlt == 1)
        let f = BeatMetrics.fMeasure(detections: double, annotations: Self.beats, window: 0.07)
        #expect(f.precision == 0.5 && f.recall == 1)
    }

    @Test func halfTempoBothPhases() {
        for start in [0.0, 0.5] {
            let half = (0..<10).map { start + Double($0) }
            let c = BeatMetrics.continuity(detections: half, annotations: Self.beats)
            #expect(c.cmlt == 0, "start \(start)")
            #expect(c.amlt == 1, "start \(start)")
        }
    }

    @Test func offbeatIsAcceptedByAML() {
        let off = Self.beats.map { $0 + 0.25 }
        let c = BeatMetrics.continuity(detections: off, annotations: Self.beats)
        #expect(c.cmlt == 0)
        #expect(c.amlt == 1)
    }

    @Test func tempoOffByMoreThanToleranceFailsContinuity() {
        // 25 % медленнее: интервал 0.625 против 0.5 вне допуска 17.5 %.
        let slow = (0..<16).map { Double($0) * 0.625 }
        #expect(BeatMetrics.continuity(detections: slow, annotations: Self.beats).cmlt < 0.2)
        // 10 % медленнее на всем отрезке: интервал в допуске, но фаза уплывает; считаются только доли у начала.
        let drifting = (0..<22).map { Double($0) * 0.55 }
        let c = BeatMetrics.continuity(detections: drifting, annotations: Self.beats)
        #expect(c.cmlt > 0.2 && c.cmlt < 0.6, "cmlt \(c.cmlt)")
        #expect(c.cmlc <= c.cmlt)
    }

    @Test func continuousRunIsTheLongestStretch() {
        // Пропуск 3 долей в середине: непрерывный отрезок короче общей доли верных долей.
        var detections = Self.beats
        detections.removeAll { $0 >= 4.0 && $0 < 5.5 }
        let c = BeatMetrics.continuity(detections: detections, annotations: Self.beats)
        #expect(c.cmlt > c.cmlc)
        #expect(c.cmlc >= 0.4)
    }

    @Test func lockedPrecisionCountsOnlyLockedFlashes() throws {
        let flashes = [
            OfflineBeatChain.Flash(time: 0.01, predicted: false, locked: false),
            OfflineBeatChain.Flash(time: 0.52, predicted: true, locked: true),
            OfflineBeatChain.Flash(time: 1.01, predicted: true, locked: true),
            OfflineBeatChain.Flash(time: 1.25, predicted: true, locked: true),
            OfflineBeatChain.Flash(time: 3.30, predicted: false, locked: false),
        ]
        let precision = try #require(BeatMetrics.lockedPrecision(flashes: flashes, annotations: Self.beats, window: 0.07))
        #expect(abs(precision - 2.0 / 3) < 1e-12)
        #expect(BeatMetrics.lockedPrecision(flashes: [flashes[0], flashes[4]], annotations: Self.beats, window: 0.07) == nil)
    }

    @Test func lockedCoverageIsTheLockedShareOfTheTrack() {
        func state(_ time: Double, _ locked: Bool) -> OfflineBeatChain.State {
            OfflineBeatChain.State(time: time, locked: locked, bpm: nil, confidence: 0)
        }
        // Захват с 1 до 3 с из 4: половина.
        let states = [state(0, false), state(1, true), state(2, true), state(3, false)]
        #expect(BeatMetrics.lockedCoverage(states: states, duration: 4) == 0.5)
        // Последнее состояние держится до конца.
        #expect(BeatMetrics.lockedCoverage(states: [state(0, false), state(2, true)], duration: 4) == 0.5)
        // Публикации за пределом длительности не считаются.
        #expect(BeatMetrics.lockedCoverage(states: [state(0, true), state(5, false)], duration: 4) == 1)
        #expect(BeatMetrics.lockedCoverage(states: [], duration: 4) == 0)
        #expect(BeatMetrics.lockedCoverage(states: [state(0, true)], duration: 0) == 0)
    }

    /// Место вспышки как у разбора записей владельца: доля в окне, иначе середина соседних долей в
    /// окне (вспышка на «и»), иначе мимо. До первой и после последней доли середины нет.
    @Test func placeOnTheBeatOnTheHalfBeatOrElsewhere() {
        let beats: [Double] = [1, 1.5, 2, 2.5]
        #expect(BeatMetrics.place(of: 1.5, beats: beats, window: 0.07) == .on)
        #expect(BeatMetrics.place(of: 1.43, beats: beats, window: 0.07) == .on)
        #expect(BeatMetrics.place(of: 1.75, beats: beats, window: 0.07) == .half)
        #expect(BeatMetrics.place(of: 1.31, beats: beats, window: 0.07) == .half)
        #expect(BeatMetrics.place(of: 1.6, beats: beats, window: 0.07) == .other)
        // Перед первой долей и после последней середины нет.
        #expect(BeatMetrics.place(of: 0.75, beats: beats, window: 0.07) == .other)
        #expect(BeatMetrics.place(of: 2.75, beats: beats, window: 0.07) == .other)
        #expect(BeatMetrics.place(of: 1, beats: [], window: 0.07) == .other)
    }

    /// Темнота: промежутки длиннее порога между началом, вспышками и концом; вспышки вне отрезка не в счет.
    @Test func darkSpansSumTheLongGaps() {
        let dark = BeatMetrics.darkSpans(detections: [2, 2.5, 6, 40], from: 0, to: 10, gap: 1.5)
        // 0-2 (2 с), 2.5-6 (3.5 с), 6-10 (4 с).
        #expect(abs(dark.total - 9.5) < 1e-12)
        #expect(dark.longest == 4)
        let none = BeatMetrics.darkSpans(detections: [], from: 0, to: 30, gap: 1.5)
        #expect(none.total == 30 && none.longest == 30)
        let lit = BeatMetrics.darkSpans(detections: [1, 2, 3], from: 0, to: 4, gap: 1.5)
        #expect(lit.total == 0 && lit.longest == 0)
    }
}
