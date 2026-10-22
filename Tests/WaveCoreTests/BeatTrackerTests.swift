import Foundation
import Testing
@testable import WaveCore

/// Части трекера без сцен: идут на всех платформах.
struct BeatTrackerPartsTests {
    @Test func selectFindsTheRank() {
        var rng = TestRNG(seed: 7)
        for count in [1, 2, 3, 10, 281] {
            let values = (0..<count).map { _ in Float(Int(rng.nextUnit() * 20)) }
            let sorted = values.sorted()
            for rank in [0, count / 2, count - 1] {
                var copy = values
                let picked = copy.withUnsafeMutableBufferPointer { BeatTracker.select($0, rank: rank) }
                #expect(picked == sorted[rank], "count \(count) rank \(rank)")
            }
        }
    }

    @Test func circularDifferenceWrapsIntoHalfPeriod() {
        #expect(abs(BeatTracker.circularDifference(0.26, period: 0.5) - -0.24) < 1e-12)
        #expect(abs(BeatTracker.circularDifference(-0.26, period: 0.5) - 0.24) < 1e-12)
        #expect(abs(BeatTracker.circularDifference(1.1, period: 0.5) - 0.1) < 1e-12)
        #expect(BeatTracker.circularDifference(0.25, period: 0.5) == 0.25)
        #expect(BeatTracker.circularDifference(-0.25, period: 0.5) == 0.25)
    }
}

/// Трекер на готовых шагах анализа: синтетические барабаны (только Linux, как остальные сцены) и
/// искусственные шаги с онсетами точно на долях.
@Suite(.enabled(if: TestPlatform.isLinux))
struct BeatTrackerTests {
    /// Шаги анализа сцены, считаются один раз за прогон.
    private enum Hops {
        static let steady = StreamAnalyzer(sampleRate: 48_000).processSignal(SharedScenes.steady120.samples)
        static let breakdown = StreamAnalyzer(sampleRate: 48_000).processSignal(SharedScenes.breakdown.samples)
    }

    private static let fps = AnalysisConfig(sampleRate: 48_000).framesPerSecond

    @Test func locksOnSteadyBeat() async {
        let hops = await runOffCooperativePool { Hops.steady }
        var tracker = BeatTracker(framesPerSecond: Self.fps)
        var lockTime: Double?
        var worstError = 0.0
        for hop in hops {
            tracker.process(hop)
            if lockTime == nil, tracker.locked { lockTime = hop.endTime }
            if tracker.locked, let next = tracker.nextBeat {
                worstError = max(worstError, abs(BeatTracker.circularDifference(next, period: 0.5)))
            }
        }
        #expect(lockTime.map { $0 <= 8 } == true, "lock at \(String(describing: lockTime))")
        #expect(tracker.confidence >= 0.6)
        #expect(worstError <= 0.01, "worst distance of the next beat from the grid \(worstError)")
    }

    @Test func unlocksWhenBeatStops() async {
        let hops = await runOffCooperativePool { Hops.breakdown }
        var tracker = BeatTracker(framesPerSecond: Self.fps)
        var wasLocked = false
        for hop in hops {
            tracker.process(hop)
            if hop.endTime < 10 { wasLocked = wasLocked || tracker.locked }
            guard hop.endTime >= 14, hop.endTime < 18 else { continue }
            let predicted = tracker.schedule.events.filter { $0.predicted && $0.time > hop.endTime }
            let quiet = predicted.allSatisfy { $0.amplitude < 0.2 }
            #expect(tracker.confidence < 0.35 || quiet, "t \(hop.endTime): confidence \(tracker.confidence)")
        }
        #expect(wasLocked)
    }

    @Test func gateHoldsBetweenKicks() async {
        let hops = await runOffCooperativePool { Hops.steady }
        var tracker = BeatTracker(framesPerSecond: Self.fps)
        var checked = 0
        for hop in hops {
            // Ворот на момент предсказанной доли: состояние после последнего шага перед ней.
            if tracker.locked, let next = tracker.nextBeat, next > hop.endTime - 1 / Self.fps, next <= hop.endTime {
                #expect(tracker.energyGate >= 0.9, "beat \(next): gate \(tracker.energyGate)")
                checked += 1
            }
            tracker.process(hop)
        }
        #expect(checked >= 30)
    }

    @Test func gateClosesInBreakdown() async {
        let hops = await runOffCooperativePool { Hops.breakdown }
        let lastKick = SharedScenes.breakdown.kicks.last { $0 < 10 } ?? 0
        var tracker = BeatTracker(framesPerSecond: Self.fps)
        var worst: Float = 0
        for hop in hops {
            tracker.process(hop)
            if hop.endTime >= lastKick + 2 * 0.5, hop.endTime < 18 {
                worst = max(worst, tracker.energyGate)
            }
        }
        #expect(worst <= 0.2, "gate in the breakdown up to \(worst)")
    }

    @Test func predictedBeatKeepsIdWhenNudged() throws {
        var tracker = BeatTracker(framesPerSecond: Self.fps)
        var hops = SyntheticBeats(bpm: 120)
        hops.feed(&tracker, until: 10)
        try #require(tracker.locked)
        let beat = try #require(tracker.nextBeat)
        // Шаги без онсетов до момента сразу после доли, окно совпадения еще открыто.
        hops.feedSilence(&tracker, until: beat + 0.03)
        let delay = tracker.parameters.beatDelay
        let before = try #require(tracker.schedule.events.first { $0.predicted && abs($0.time - delay - beat) < 0.001 })
        let after = tracker.schedule.events.first { $0.predicted && $0.time - delay > beat + 0.25 }
        // Онсет на 20 мс позже доли: поправка фазы 0.25 × 20 = 5 мс.
        hops.feedSilence(&tracker, until: beat + 0.04, broadband: OnsetEvent(time: beat + 0.020, strength: 1))
        let nudged = try #require(tracker.schedule.events.first { $0.id == before.id })
        #expect(abs(nudged.time - before.time - 0.005) < 1e-9)
        #expect(tracker.schedule.events.first { $0.id == after?.id } != nil)
    }

    @Test func kickOnsetsDoNotFeedThePLL() throws {
        var tracker = BeatTracker(framesPerSecond: Self.fps)
        var hops = SyntheticBeats(bpm: 120)
        hops.feed(&tracker, until: 10)
        try #require(tracker.locked)
        let beat = try #require(tracker.nextBeat)
        hops.feedSilence(&tracker, until: beat + 0.03)
        // Один и тот же шаг трем копиям: без онсетов, с онсетом бочки и с широкополосным онсетом.
        let onset = OnsetEvent(time: beat + 0.020, strength: 1)
        let end = hops.endTime + hops.hop
        var plain = tracker
        var kick = tracker
        var broadband = tracker
        plain.process(SyntheticBeats.hop(endTime: end, broadband: nil, kick: nil))
        kick.process(SyntheticBeats.hop(endTime: end, broadband: nil, kick: onset))
        broadband.process(SyntheticBeats.hop(endTime: end, broadband: onset, kick: nil))
        #expect(kick.nextBeat == plain.nextBeat)
        #expect(kick.period == plain.period)
        #expect(broadband.nextBeat != plain.nextBeat)
        // Бочка у предсказанной доли при захвате отдельно не светится.
        #expect(!kick.schedule.events.contains { !$0.predicted && $0.time == onset.time })
    }

    /// `BeatGlow` помнит id 2 с: id, который ушел из расписания, больше не появляется никогда, в том
    /// числе после сброса и смены темпа.
    @Test func idsNeverRepeatAcrossResetAndTempoSwitch() {
        var tracker = BeatTracker(framesPerSecond: Self.fps)
        var ids = IDLifetimes()

        var hops = SyntheticBeats(bpm: 120)
        hops.feed(&tracker, until: 8) { ids.record($0) }
        let beforeReset = ids.seen
        tracker.reset()
        // Новый поток с нуля, затем смена темпа 120 -> 100.
        hops = SyntheticBeats(bpm: 120)
        hops.feed(&tracker, until: 8) { ids.record($0) }
        hops.bpm = 100
        var switches = 0
        var lastPeriod = tracker.period
        hops.feed(&tracker, until: 20) { tracker in
            ids.record(tracker)
            if let period = tracker.period, let last = lastPeriod, abs(period / last - 1) > 0.1 { switches += 1 }
            lastPeriod = tracker.period
        }
        #expect(beforeReset.contains { $0 & BeatTracker.onsetIDFlag == 0 })
        #expect(beforeReset.contains { $0 & BeatTracker.onsetIDFlag != 0 })
        #expect(switches >= 1)
        #expect(tracker.period.map { abs($0 - 0.6) < 0.01 } == true)
        #expect(ids.reused.isEmpty, "ids back after leaving the schedule: \(ids.reused)")
        #expect(ids.mislabeled.isEmpty, "onset flag does not match the kind: \(ids.mislabeled)")
    }

    /// Смена частоты 48 -> 44.1 кГц посреди потока: трекер начинает заново, снова захватывает 120 BPM
    /// и не повторяет ни одного id.
    @Test func rateChangeRelocksWithNewIDs() async {
        let first = await runOffCooperativePool { Hops.steady }
        let second = await runOffCooperativePool {
            StreamAnalyzer(sampleRate: 44_100).processSignal(Drums.fourOnFloor(bpm: 120, seconds: 12, sampleRate: 44_100, hats: .eighths).samples)
        }
        var tracker = BeatTracker(framesPerSecond: Self.fps)
        var ids = IDLifetimes()
        for hop in first where hop.endTime < 12 {
            tracker.process(hop)
            ids.record(tracker)
        }
        #expect(tracker.locked)
        let before = ids.seen
        tracker.reconfigure(framesPerSecond: AnalysisConfig(sampleRate: 44_100).framesPerSecond)
        #expect(tracker.framesPerSecond == AnalysisConfig(sampleRate: 44_100).framesPerSecond)
        #expect(!tracker.locked && tracker.period == nil)
        var relock: Double?
        for hop in second {
            tracker.process(hop)
            ids.record(tracker)
            if relock == nil, tracker.locked { relock = hop.endTime }
        }
        #expect(relock.map { $0 <= 8 } == true, "relock at \(String(describing: relock)) s of the new stream")
        #expect(tracker.period.map { abs($0 / 0.5 - 1) < 0.04 } == true, "period \(String(describing: tracker.period))")
        #expect(ids.reused.isEmpty, "ids back after leaving the schedule: \(ids.reused)")
        #expect(ids.seen.subtracting(before).count > 0)
    }

    /// Бочка между долями при захвате дает отблеск не выше порога вспышки, а не вспышку мимо доли.
    @Test func offGridKickStaysBelowFlashWhenLocked() throws {
        var tracker = BeatTracker(framesPerSecond: Self.fps)
        var hops = SyntheticBeats(bpm: 120)
        hops.feed(&tracker, until: 10)
        try #require(tracker.locked)
        try #require(tracker.blend == 1)
        let beat = try #require(tracker.nextBeat)
        // Бочка на «и», посередине между долями: дальше `dropWindow` от обеих.
        let onset = OnsetEvent(time: beat + 0.25, strength: 1)
        hops.feedSilence(&tracker, until: onset.time + 0.002, kick: onset)
        try #require(tracker.locked)
        let glow = try #require(tracker.schedule.events.first { !$0.predicted && $0.time == onset.time })
        #expect(glow.amplitude <= OfflineBeatChain.eventRise)
        #expect(glow.amplitude >= 0.15)
    }

    /// «И» без онсетов, которую видит только гребенка фазы: чуть сильнее доли (60 против 50) фазу не
    /// перебрасывает и захват держится, вдвое сильнее перебрасывает на «и».
    @Test(arguments: [(Float(60), false), (Float(100), true)])
    func phaseJumpNeedsAClearlyStrongerComb(offbeat: Float, jumps: Bool) throws {
        var tracker = BeatTracker(framesPerSecond: Self.fps)
        var hops = SyntheticBeats(bpm: 120)
        hops.feed(&tracker, until: 10)
        try #require(tracker.locked)
        hops.offbeatODF = offbeat
        hops.nextOffbeatTime = hops.nextBeatTime + 0.25
        hops.feed(&tracker, until: 16)
        let next = try #require(tracker.nextBeat)
        // Доли сцены на 0.25 + k · 0.5 с.
        let distance = abs(BeatTracker.circularDifference(next - 0.25, period: 0.5))
        if jumps {
            #expect(abs(distance - 0.25) < 0.02, "next beat \(next)")
        } else {
            #expect(distance < 0.02, "next beat \(next)")
            #expect(tracker.locked)
        }
    }

    /// Предсказанные доли публикуются на `beatDelay` (12 мс) позже фазы ФАПЧ, сама ФАПЧ на онсетах.
    @Test func predictedBeatsArePublishedBeatDelayLater() throws {
        var tracker = BeatTracker(framesPerSecond: Self.fps)
        var hops = SyntheticBeats(bpm: 120)
        hops.feed(&tracker, until: 10)
        try #require(tracker.locked)
        let next = try #require(tracker.nextBeat)
        #expect(abs(BeatTracker.circularDifference(next - 0.25, period: 0.5)) < 0.005)
        let published = try #require(tracker.schedule.events.first { $0.predicted && $0.time > next })
        #expect(abs(published.time - next - 0.012) < 1e-9)
    }

    /// Захват с нуля на третьем попадании подряд (уверенность 0.58 ≥ 0.55), отпускание, когда уверенность
    /// падает ниже 0.25.
    @Test func locksOnTheThirdHitAndReleasesBelowAQuarter() throws {
        var tracker = BeatTracker(framesPerSecond: Self.fps)
        var hops = SyntheticBeats(bpm: 120)
        var hitsAtLock: Int?
        var confidenceAtLock = 0.0
        hops.feed(&tracker, until: 10) { tracker in
            if hitsAtLock == nil, tracker.locked {
                hitsAtLock = tracker.hits
                confidenceAtLock = tracker.confidence
            }
        }
        #expect(hitsAtLock == 3)
        #expect((0.55..<0.6).contains(confidenceAtLock), "confidence at lock \(confidenceAtLock)")
        try #require(tracker.locked)
        var before = tracker.confidence
        var released: (before: Double, after: Double)?
        var end = hops.endTime
        while released == nil, end < 20 {
            end += 0.05
            hops.feedSilence(&tracker, until: end)
            if !tracker.locked { released = (before, tracker.confidence) }
            before = tracker.confidence
        }
        let release = try #require(released)
        #expect(release.before >= 0.25 && release.after < 0.25, "\(release)")
    }

    /// Бесконечный или нечисловой уровень бочки считается полом и не застревает в удержании.
    @Test func nonFiniteKickLevelCountsAsFloor() {
        var tracker = BeatTracker(framesPerSecond: Self.fps)
        var hops = SyntheticBeats(bpm: 120)
        hops.feed(&tracker, until: 8)
        let gate = tracker.energyGate
        for level in [Float.infinity, .nan, -.infinity] {
            hops.endTime += hops.hop
            var hop = SyntheticBeats.hop(endTime: hops.endTime, broadband: nil, kick: nil)
            hop.kickLevelDB = level
            tracker.process(hop)
            #expect(tracker.energyGate.isFinite && (0...1).contains(tracker.energyGate), "level \(level)")
        }
        #expect(abs(tracker.energyGate - gate) < 0.1)
        // Без бочек ворот закрывается, а не остается открытым от бесконечного пика.
        hops.feedSilence(&tracker, until: hops.endTime + 2)
        #expect(tracker.energyGate == 0)
        // Следующие доли открывают его снова.
        hops.nextBeatTime = hops.endTime + 0.25
        hops.feed(&tracker, until: hops.endTime + 1.5)
        #expect(tracker.energyGate > 0.9)
    }
}

/// Жизнь id в расписаниях, взятых на каждом шаге: id, который ушел из расписания, вернуться не может.
struct IDLifetimes {
    private(set) var seen: Set<UInt64> = []
    private var current: Set<UInt64> = []
    private(set) var reused: [UInt64] = []
    private(set) var mislabeled: [UInt64] = []

    mutating func record(_ tracker: BeatTracker) {
        let events = tracker.schedule.events
        let now = Set(events.map(\.id))
        for event in events where event.predicted != (event.id & BeatTracker.onsetIDFlag == 0) {
            mislabeled.append(event.id)
        }
        for id in now where seen.contains(id) && !current.contains(id) {
            reused.append(id)
        }
        seen.formUnion(now)
        current = now
    }
}

/// Искусственные шаги анализа: на шаге, в который попала доля, функции онсетов 50, широкополосный онсет
/// и онсет бочки точно на доле, уровень бочки -6 dBFS; между долями функции 0 и уровень -40 dBFS.
/// Шаг с одним онсетом бочки тоже несет широкополосную функцию 50, иначе бочка не подтверждена.
struct SyntheticBeats {
    var bpm: Double
    var endTime = 0.0
    var nextBeatTime = 0.25
    let hop = 256.0 / 48_000
    /// Широкополосная функция на «и» (без онсета): ее видит только гребенка фазы. 0 выключает.
    var offbeatODF: Float = 0
    var nextOffbeatTime = 0.0

    init(bpm: Double) {
        self.bpm = bpm
    }

    mutating func feed(_ tracker: inout BeatTracker, until end: Double, each: (BeatTracker) -> Void = { _ in }) {
        while endTime + hop <= end {
            endTime += hop
            var onset: OnsetEvent?
            if nextBeatTime <= endTime {
                onset = OnsetEvent(time: nextBeatTime, strength: 1)
                nextBeatTime += 60 / bpm
            }
            var hop = Self.hop(endTime: endTime, broadband: onset, kick: onset)
            if offbeatODF > 0, nextOffbeatTime <= endTime {
                hop.broadbandODF = max(hop.broadbandODF, offbeatODF)
                nextOffbeatTime += 60 / bpm
            }
            tracker.process(hop)
            each(tracker)
        }
    }

    /// Шаги без долей (функции онсетов 0), на последнем из них заданные онсеты.
    mutating func feedSilence(
        _ tracker: inout BeatTracker, until end: Double, broadband: OnsetEvent? = nil, kick: OnsetEvent? = nil
    ) {
        while endTime + hop <= end {
            endTime += hop
            let last = endTime + hop > end
            tracker.process(Self.hop(endTime: endTime, broadband: last ? broadband : nil, kick: last ? kick : nil))
        }
        nextBeatTime = max(nextBeatTime, endTime)
    }

    static func hop(endTime: Double, broadband: OnsetEvent?, kick: OnsetEvent?) -> HopResult {
        let beat = broadband != nil || kick != nil
        return HopResult(
            frame: WaveFrame(bands: [], layers: [], beat: 0, level: 0, rawLevelDB: -120),
            frameTime: endTime - 512.0 / 48_000,
            endTime: endTime,
            kickOnset: kick,
            broadbandOnset: broadband,
            broadbandODF: beat ? 50 : 0,
            kickODF: kick != nil ? 50 : 0,
            kickLevelDB: beat ? -6 : -40
        )
    }
}
