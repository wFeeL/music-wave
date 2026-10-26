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

    /// Брейк без бочки 8 с посреди захвата (`Drums.breakdown`, бочка возвращается на 18 с на той же
    /// сетке): вспышки гаснут вместе с воротом, а после возврата сетка продолжается без нового захвата
    /// с нуля. Вспышка предсказанной доли (яркость от `eventRise`) есть на одной из первых трех бочек
    /// после возврата и стоит на бочке; в 1.1 нужно было 5 новых попаданий и еще доля смеси.
    @Test func breakdownCoasts() async throws {
        let hops = await runOffCooperativePool { Hops.breakdown }
        let scene = SharedScenes.breakdown
        let returned = try #require(scene.kicks.first { $0 >= 18 - 0.01 })
        let firstKicks = scene.kicks.filter { $0 >= returned }.prefix(3)
        var tracker = BeatTracker(framesPerSecond: Self.fps)
        var brightest: [UInt64: (time: Double, amplitude: Float)] = [:]
        var lockedBefore = false
        for hop in hops {
            tracker.process(hop)
            if hop.endTime < 10 { lockedBefore = lockedBefore || tracker.locked }
            guard hop.endTime >= returned - 0.5 else { continue }
            for event in tracker.schedule.events where event.predicted {
                let known = brightest[event.id]?.amplitude ?? 0
                if event.amplitude > known { brightest[event.id] = (event.time, event.amplitude) }
            }
        }
        try #require(lockedBefore)
        let flashes = brightest.values.filter { $0.amplitude >= OfflineBeatChain.eventRise }.map(\.time).sorted()
        let last = try #require(firstKicks.last)
        let early = flashes.filter { $0 >= returned - 0.1 && $0 <= last + 0.05 }
        let first = try #require(early.first, "no predicted flash on the first three kicks; flashes \(flashes.prefix(6))")
        let distance = scene.kicks.map { abs($0 - first) }.min() ?? .infinity
        #expect(distance < 0.04, "first flash after the break at \(first), \(distance) s from a kick")
    }

    /// Брейк, после которого доли вернулись на полпериода позже (сетка наката больше не та): первая
    /// доля после возврата промахивается и сразу отпускает захват, ни одной яркой предсказанной
    /// вспышки мимо новых долей (уверенная вспышка не на ту долю хуже темноты).
    @Test func coastReturnOffTheGridUnlocks() throws {
        var tracker = BeatTracker(framesPerSecond: Self.fps)
        var hops = SyntheticBeats(bpm: 120)
        hops.feed(&tracker, until: 10)
        try #require(tracker.locked)
        // Тишина 4 с (уровень бочки -40 dBFS): ворот закрывается, захват держится накатом.
        hops.feedSilence(&tracker, until: 14)
        try #require(tracker.energyGate < tracker.parameters.coastGate)
        try #require(tracker.locked)
        // Доли возвращаются на 0.5 + k · 0.5 с вместо 0.25 + k · 0.5 с.
        hops.nextBeatTime = 14.5
        var unlockedAt: Double?
        // Яркость доли, когда время потока до нее дошло (дальше она зафиксирована).
        var shown: [UInt64: (time: Double, amplitude: Float)] = [:]
        hops.feed(&tracker, until: 18) { tracker in
            if unlockedAt == nil, !tracker.locked { unlockedAt = tracker.now }
            for event in tracker.schedule.events where event.predicted && event.time <= tracker.now && event.time > 14 {
                if shown[event.id] == nil { shown[event.id] = (event.time, event.amplitude) }
            }
        }
        let unlock = try #require(unlockedAt, "still locked on the old grid")
        // Окно первой старой доли после возврата (14.75 с) закрывается через 0.15 периода.
        #expect(unlock <= 14.75 + 0.5 * 0.15 + 0.01, "unlocked at \(unlock)")
        #expect(tracker.lastUnlockReason == .misses || tracker.locked)
        let offGrid = shown.values.filter {
            $0.amplitude >= OfflineBeatChain.eventRise && abs(BeatTracker.circularDifference($0.time - 0.5, period: 0.5)) > 0.07
        }
        #expect(offGrid.isEmpty, "bright predicted flashes off the new beats: \(offGrid)")
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
        let before = try #require(tracker.schedule.events.first { $0.predicted && abs($0.time - beat) < 0.001 })
        let after = tracker.schedule.events.first { $0.predicted && $0.time > beat + 0.25 }
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
    /// перебрасывает и захват держится, вдвое сильнее перебрасывает на «и». С B3 при уверенном
    /// захвате это гонка: тень на «и» побеждает голосами гребенки (`raceVotes`), а не сразу.
    @Test(arguments: [(Float(60), false), (Float(100), true)])
    func phaseJumpNeedsAClearlyStrongerComb(offbeat: Float, jumps: Bool) throws {
        var tracker = BeatTracker(framesPerSecond: Self.fps)
        var hops = SyntheticBeats(bpm: 120)
        hops.feed(&tracker, until: 10)
        try #require(tracker.locked)
        hops.offbeatODF = offbeat
        hops.nextOffbeatTime = hops.nextBeatTime + 0.25
        var shadowSeen = false
        hops.feed(&tracker, until: 16) { shadowSeen = shadowSeen || $0.shadowNext != nil }
        #expect(shadowSeen == jumps)
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

    /// Гонка по попаданиям (голоса гребенки выключены, `raceVotes` 0). Гребенка на «и» без онсетов
    /// до старта тени, потом ее нет; тень не попадает: сетка не перехватывается, захват
    /// держится всю гонку. Вспышка гребенки, а затем все доли уходят на «и» (текущая фаза
    /// промахивается): тень впереди с `raceMargin` 4 доли подряд, перехватывает не раньше 4 и не позже
    /// 8 своих долей и приносит свой счет, захват на новой фазе без захода в «нет захвата» с нуля.
    @Test(arguments: [false, true])
    func shadowWinsOnlyWhenBetter(better: Bool) throws {
        var parameters = BeatTracker.Parameters()
        parameters.raceVotes = 0
        var tracker = BeatTracker(framesPerSecond: Self.fps, parameters: parameters)
        var hops = SyntheticBeats(bpm: 120)
        hops.feed(&tracker, until: 10)
        try #require(tracker.locked && tracker.confidence >= parameters.lockConfidence)
        hops.offbeatODF = 100
        hops.nextOffbeatTime = hops.nextBeatTime + 0.25
        var shadowStart: Double?
        var takeover: (time: Double, confidence: Double, hits: Int)?
        var alwaysLocked = true
        var previous = tracker
        let watch = { (tracker: BeatTracker) in
            if shadowStart == nil, tracker.shadowNext != nil { shadowStart = tracker.now }
            if takeover == nil, previous.shadowNext != nil, tracker.shadowNext == nil, tracker.nextBeat.map({
                abs(BeatTracker.circularDifference($0 - 0.5, period: 0.5)) < 0.03
            }) == true {
                takeover = (tracker.now, tracker.confidence, tracker.hits)
            }
            alwaysLocked = alwaysLocked && tracker.locked
            previous = tracker
        }
        // Гребенка на «и» до старта тени (не дольше 2 с).
        while shadowStart == nil, hops.endTime < 12 {
            hops.feed(&tracker, until: hops.endTime + 0.05, each: watch)
        }
        let started = try #require(shadowStart, "no shadow phase")
        hops.offbeatODF = 0
        if better {
            // Доли переходят на 0.5 + k · 0.5 с, туда же, где тень.
            hops.nextBeatTime += 0.25
        }
        hops.feed(&tracker, until: 18, each: watch)
        let next = try #require(tracker.nextBeat)
        if better {
            let won = try #require(takeover, "the shadow never took over")
            let beats = (won.time - started) / 0.5
            #expect(beats >= 4 && beats <= 8.5, "takeover \(beats) beats after the shadow started")
            #expect(won.confidence > 0.6 && won.hits >= 4, "\(won)")
            #expect(abs(BeatTracker.circularDifference(next - 0.5, period: 0.5)) < 0.03, "next beat \(next)")
            #expect(tracker.locked)
        } else {
            #expect(takeover == nil)
            #expect(alwaysLocked)
            #expect(abs(BeatTracker.circularDifference(next - 0.25, period: 0.5)) < 0.02, "next beat \(next)")
        }
    }

    /// Голоса гребенки: при уверенном захвате гребенка на «и» (100 против 50, без онсетов) не
    /// перебрасывает фазу сразу. Захват держится, пока идет гонка, и сетка уходит к тени через
    /// `raceVotes` проверок темпа (по 0.25 с) после ее старта, а не раньше (в 1.1 скачок и сброс
    /// уверенности шли на второй проверке).
    @Test func combVotesDecideTheRace() throws {
        var tracker = BeatTracker(framesPerSecond: Self.fps)
        var hops = SyntheticBeats(bpm: 120)
        hops.feed(&tracker, until: 10)
        try #require(tracker.locked)
        hops.offbeatODF = 100
        hops.nextOffbeatTime = hops.nextBeatTime + 0.25
        var shadowStart: Double?
        var moved: Double?
        var lockedUntilMove = true
        hops.feed(&tracker, until: 16) { tracker in
            if shadowStart == nil, tracker.shadowNext != nil { shadowStart = tracker.now }
            let onOffbeat = tracker.nextBeat.map { abs(BeatTracker.circularDifference($0 - 0.5, period: 0.5)) < 0.03 } == true
            if moved == nil, onOffbeat { moved = tracker.now }
            if moved == nil, shadowStart != nil { lockedUntilMove = lockedUntilMove && tracker.locked }
        }
        let start = try #require(shadowStart, "no shadow phase")
        let move = try #require(moved, "the grid never moved")
        let votes = Double(tracker.parameters.raceVotes) * TempoEstimator.updateInterval
        // Перехват при закрытии окна тени после последнего голоса: до одного периода позже.
        #expect(move - start >= votes - 0.01 && move - start <= votes + 0.5 + 0.01, "moved \(move - start) s after the shadow started")
        #expect(lockedUntilMove)
    }

    /// Пока идет гонка фаз, предсказанные доли текущей сетки светятся с `raceDim` (0.3, замер на
    /// GTZAN) от обычной яркости: уверенная вспышка на доле, в которой гребенка уже сомневается, хуже
    /// тусклой. Сравнение с двойником без приглушения на тех же шагах: состояние и id у них общие.
    @Test func raceDimsTheGrid() throws {
        #expect(BeatTracker.Parameters().raceDim == 0.3)
        var tracker = BeatTracker(framesPerSecond: Self.fps)
        var plain = BeatTracker.Parameters()
        plain.raceDim = 1
        var twin = BeatTracker(framesPerSecond: Self.fps, parameters: plain)
        var hops = SyntheticBeats(bpm: 120)
        var twinHops = hops
        hops.feed(&tracker, until: 10)
        twinHops.feed(&twin, until: 10)
        try #require(tracker.locked)
        hops.offbeatODF = 100
        hops.nextOffbeatTime = hops.nextBeatTime + 0.25
        twinHops.offbeatODF = 100
        twinHops.nextOffbeatTime = twinHops.nextBeatTime + 0.25
        // Яркость доли, когда время потока до нее дошло, и шла ли в этот момент гонка.
        var shown: [UInt64: (amplitude: Float, racing: Bool)] = [:]
        var twinShown: [UInt64: Float] = [:]
        hops.feed(&tracker, until: 16) { tracker in
            for event in tracker.schedule.events where event.predicted && event.time <= tracker.now && event.time > 10 {
                if shown[event.id] == nil { shown[event.id] = (event.amplitude, tracker.shadowNext != nil) }
            }
        }
        twinHops.feed(&twin, until: 16) { twin in
            for event in twin.schedule.events where event.predicted && event.time <= twin.now && event.time > 10 {
                if twinShown[event.id] == nil { twinShown[event.id] = event.amplitude }
            }
        }
        let racing = shown.filter { $0.value.racing }
        #expect(!racing.isEmpty, "no beat shown during the race")
        for (id, beat) in racing {
            let reference = try #require(twinShown[id])
            #expect(reference > 0.5, "beat \(id): \(reference) without dimming")
            #expect(abs(beat.amplitude - 0.3 * reference) < 1e-4, "beat \(id): \(beat.amplitude) of \(reference)")
        }
        // Вне гонки яркость та же, что у двойника.
        for (id, beat) in shown where !beat.racing {
            #expect(beat.amplitude == twinShown[id], "beat \(id) outside the race")
        }
    }

    /// Захват с нуля на пятом попадании подряд (уверенность 0.76, после четырех 0.68 уже выше 0.6, но
    /// попаданий мало), отпускание, когда уверенность падает ниже 0.25.
    @Test func locksOnTheFifthHitAndReleasesBelowAQuarter() throws {
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
        #expect(hitsAtLock == 5)
        #expect((0.6..<0.8).contains(confidenceAtLock), "confidence at lock \(confidenceAtLock)")
        try #require(tracker.locked)
        var before = tracker.confidence
        var released: (before: Double, after: Double)?
        // Шаги без атак с уровнем бочки как на долях: ворот открыт, доли считаются промахами (при
        // закрытом вороте идет накат и промахи не считаются, это `breakdownCoasts`).
        var time = hops.endTime
        while released == nil, time < 20 {
            time += hops.hop
            var hop = SyntheticBeats.hop(endTime: time, broadband: nil, kick: nil)
            hop.kickLevelDB = -6
            tracker.process(hop)
            if !tracker.locked { released = (before, tracker.confidence) }
            before = tracker.confidence
        }
        let release = try #require(released)
        #expect(release.before >= 0.25 && release.after < 0.25, "\(release)")
    }

    /// Скачок темпа 100 -> 140 BPM на 12 с: первую потерю захвата дает смена темпа, и причина видна в
    /// расписании, пока захвата нет.
    @Test func unlockReasonTempoSwitch() async throws {
        let hops = await runOffCooperativePool {
            StreamAnalyzer(sampleRate: 48_000).processSignal(Drums.tempoJump(from: 100, to: 140, at: 12).samples)
        }
        var tracker = BeatTracker(framesPerSecond: Self.fps)
        var wasLocked = false
        var first: (time: Double, reason: UnlockReason?, published: UnlockReason?)?
        for hop in hops {
            tracker.process(hop)
            if first == nil, wasLocked, !tracker.locked {
                first = (hop.endTime, tracker.lastUnlockReason, tracker.schedule.unlockReason)
            }
            wasLocked = tracker.locked
        }
        let unlock = try #require(first)
        #expect(unlock.reason == .tempoSwitch, "first unlock at \(unlock.time) s")
        #expect(unlock.published == .tempoSwitch)
        #expect(unlock.time > 12, "first unlock at \(unlock.time) s, before the jump")
    }

    /// Захват на ровных долях, потом шаги без атак с уровнем бочки как на долях (ворот открыт): захват
    /// уходит по промахам. С захватом причины в расписании нет; `reset()` забывает причину.
    @Test func unlockReasonMisses() throws {
        var tracker = BeatTracker(framesPerSecond: Self.fps)
        var hops = SyntheticBeats(bpm: 120)
        hops.feed(&tracker, until: 10)
        try #require(tracker.locked)
        #expect(tracker.lastUnlockReason == nil && tracker.schedule.unlockReason == nil)
        var time = hops.endTime
        var unlockedAt: Double?
        while unlockedAt == nil, time < 20 {
            time += hops.hop
            var hop = SyntheticBeats.hop(endTime: time, broadband: nil, kick: nil)
            hop.kickLevelDB = -6
            tracker.process(hop)
            if !tracker.locked { unlockedAt = time }
        }
        try #require(unlockedAt != nil)
        #expect(tracker.energyGate > 0.9)
        #expect(tracker.lastUnlockReason == .misses)
        #expect(tracker.schedule.unlockReason == .misses)
        // Захвата уже нет: сброс говорит «захвата еще не было», а не «потерян сбросом».
        tracker.reset()
        #expect(tracker.lastUnlockReason == nil && tracker.schedule.unlockReason == nil)
    }

    /// Пауза, перемотка или смена источника посреди захвата (`reset()`) и смена частоты
    /// (`reconfigure`) это потеря захвата с причиной `.reset`, иначе журнал устройства показал бы
    /// потерю без причины.
    @Test func resetWhileLockedIsAnUnlockReason() throws {
        var tracker = BeatTracker(framesPerSecond: Self.fps)
        var hops = SyntheticBeats(bpm: 120)
        hops.feed(&tracker, until: 10)
        try #require(tracker.locked)
        tracker.reset()
        #expect(!tracker.locked)
        #expect(tracker.lastUnlockReason == .reset && tracker.schedule.unlockReason == .reset)
        tracker.reset()
        #expect(tracker.lastUnlockReason == nil)

        var other = BeatTracker(framesPerSecond: Self.fps)
        var more = SyntheticBeats(bpm: 120)
        more.feed(&other, until: 10)
        try #require(other.locked)
        other.reconfigure(framesPerSecond: 44_100.0 / 256)
        #expect(!other.locked && other.schedule.unlockReason == .reset)
    }

    /// Смесь доходит от онсетов до предсказания за одну долю после захвата.
    @Test func blendCrossfadesInOneBeat() throws {
        var tracker = BeatTracker(framesPerSecond: Self.fps)
        var hops = SyntheticBeats(bpm: 120)
        let hop = hops.hop
        var steps = 0
        var lockStep: Int?
        var fullStep: Int?
        hops.feed(&tracker, until: 10) { tracker in
            steps += 1
            if lockStep == nil, tracker.locked { lockStep = steps }
            if fullStep == nil, tracker.blend == 1 { fullStep = steps }
        }
        let lock = Double(try #require(lockStep)) * hop
        let full = Double(try #require(fullStep)) * hop
        #expect(abs(full - lock - 0.5) <= 2 * hop, "lock \(lock), full blend \(full)")
    }

    /// Захват на «и»: доли сдвинулись на полпериода (трекер оказался на слабой доле). Захват на старой
    /// фазе держится не дольше 2 с, на новой фазе захват снова есть не позже чем через 5 с.
    @Test func offbeatLockRecovers() throws {
        var tracker = BeatTracker(framesPerSecond: Self.fps)
        var hops = SyntheticBeats(bpm: 120)
        hops.feed(&tracker, until: 10)
        try #require(tracker.locked)
        let shift = hops.endTime
        hops.nextBeatTime += 0.25
        // Новые доли на 0.5 + k · 0.5 с, старые на 0.25 + k · 0.5 с.
        func onNewGrid(_ time: Double) -> Bool { abs(BeatTracker.circularDifference(time - 0.5, period: 0.5)) < 0.03 }
        var lockedOld: Double?
        var relocked: Double?
        var steps = 0
        hops.feed(&tracker, until: shift + 8) { tracker in
            steps += 1
            let now = shift + Double(steps) * 256.0 / 48_000
            guard tracker.locked, let next = tracker.nextBeat else { return }
            if onNewGrid(next) {
                if relocked == nil { relocked = now }
            } else {
                lockedOld = now
            }
        }
        #expect((lockedOld ?? shift) - shift <= 2, "locked on the old phase until \(String(describing: lockedOld))")
        let relock = try #require(relocked)
        #expect(relock - shift <= 5, "relocked at \(relock - shift) s after the shift")
    }

    /// Переключение темпа на 6 % при тех же позициях долей (журнал 2 владельца: 77.9 -> 73.5 BPM, 6.1 %,
    /// далекая смена в оценке темпа) захват не сбрасывает: захват, счет попаданий, уверенность и
    /// следующая доля остаются, меняется только период.
    @Test(arguments: [0.94, 1.06])
    func smallTempoMoveKeepsLock(ratio: Double) throws {
        var tracker = BeatTracker(framesPerSecond: Self.fps)
        var hops = SyntheticBeats(bpm: 120)
        hops.feed(&tracker, until: 10)
        try #require(tracker.locked)
        let period = try #require(tracker.period)
        let (hits, confidence, next) = (tracker.hits, tracker.confidence, tracker.nextBeat)
        tracker.updateTempo(TempoEstimate(period: period * ratio, switched: true))
        #expect(tracker.locked)
        #expect(tracker.hits == hits)
        #expect(tracker.confidence == confidence)
        #expect(tracker.nextBeat == next)
        #expect(tracker.period == period * ratio)
        // Дальше доли идут как шли: захват держится.
        hops.feed(&tracker, until: 14)
        #expect(tracker.locked && tracker.lastUnlockReason == nil)
    }

    /// Переход ровно на половинный темп (144 -> 72 BPM, период ×2) с теми же позициями долей
    /// уверенность не сбрасывает, следующая доля остается на долях сцены. Удвоение темпа (80 -> 160
    /// BPM) сбрасывает: доли между старыми прежняя уверенность не подтверждала.
    @Test(arguments: [(144.0, 2.0, true), (80.0, 0.5, false)])
    func octaveRelatedKeepsPhase(bpm: Double, factor: Double, carries: Bool) throws {
        var tracker = BeatTracker(framesPerSecond: Self.fps)
        var hops = SyntheticBeats(bpm: bpm)
        hops.feed(&tracker, until: 10)
        try #require(tracker.locked)
        let period = try #require(tracker.period)
        try #require(abs(period * bpm / 60 - 1) < 0.02, "locked at \(60 / period) BPM")
        let (hits, confidence) = (tracker.hits, tracker.confidence)
        tracker.updateTempo(TempoEstimate(period: period * factor, switched: true))
        guard carries else {
            #expect(!tracker.locked && tracker.hits == 0 && tracker.lastUnlockReason == .tempoSwitch)
            return
        }
        #expect(tracker.locked)
        #expect(tracker.hits == hits)
        #expect(tracker.confidence == confidence)
        let next = try #require(tracker.nextBeat)
        // Доли сцены на 0.25 + k · 60 / bpm.
        #expect(abs(BeatTracker.circularDifference(next - 0.25, period: 60 / bpm)) < 0.02, "next beat \(next)")
    }

    /// Близкая смена темпа, пока ФАПЧ отстала от долей (журнал 2: доли на 0.18 периода позже ФАПЧ,
    /// потом смена 77.9 -> 73.5 BPM): уверенность и захват остаются, фаза переходит к гребенке. Те же
    /// доли на «и» (полпериода) это другая сетка, захват сбрасывается.
    @Test(arguments: [(0.09, true), (0.25, false)])
    func nearTempoMoveFollowsTheComb(shift: Double, carries: Bool) throws {
        var tracker = BeatTracker(framesPerSecond: Self.fps)
        var hops = SyntheticBeats(bpm: 120)
        hops.feed(&tracker, until: 10)
        try #require(tracker.locked)
        // Доли сдвигаются позже окна совпадения (0.075 с): ФАПЧ их не видит, три промаха подряд.
        hops.nextBeatTime += shift
        hops.feed(&tracker, until: 11.5)
        try #require(tracker.locked)
        let period = try #require(tracker.period)
        let confidence = tracker.confidence
        tracker.updateTempo(TempoEstimate(period: period * 1.06, switched: true))
        let next = try #require(tracker.nextBeat)
        let newPeriod = try #require(tracker.period)
        // Доли сцены теперь на 0.25 + shift + k · 0.5 с. Сетка ставится от последней доли гребенки
        // с новым периодом, поэтому на долю сцены ложится доля перед `next`.
        let offset = BeatTracker.circularDifference(next - newPeriod - 0.25 - shift, period: 0.5)
        #expect(abs(offset) < 0.02, "next beat \(next), period \(newPeriod), off the scene by \(offset)")
        if carries {
            #expect(tracker.locked && tracker.confidence == confidence)
        } else {
            #expect(!tracker.locked && tracker.lastUnlockReason == .tempoSwitch)
        }
    }

    /// Смена на некратный темп (×1.3) по-прежнему сбрасывает захват: это другая сетка.
    @Test func unrelatedTempoSwitchStillResets() throws {
        var tracker = BeatTracker(framesPerSecond: Self.fps)
        var hops = SyntheticBeats(bpm: 120)
        hops.feed(&tracker, until: 10)
        try #require(tracker.locked)
        let period = try #require(tracker.period)
        tracker.updateTempo(TempoEstimate(period: period / 1.3, switched: true))
        #expect(!tracker.locked)
        #expect(tracker.hits == 0)
        #expect(tracker.lastUnlockReason == .tempoSwitch)
    }

    /// Подтверждение бочки: отношение широкополосной функции на онсете к медиане за 1.5 с (плюс 0.5)
    /// проходит smoothstep от 7 до 11. Отношение 7 не светится, 9 вполовину, 11 полностью.
    @Test(arguments: [(Float(7), Float(0)), (Float(9), Float(0.5)), (Float(11), Float(1))])
    func kickConfirmationBand(ratio: Float, amplitude: Float) {
        var tracker = BeatTracker(framesPerSecond: Self.fps)
        let hop = 256.0 / 48_000
        var time = 0.0
        // Ровная широкополосная функция 1.5 без онсетов: медиана 1.5, знаменатель 2, темпа нет.
        func step(odf: Float, kick: OnsetEvent?) {
            time += hop
            var result = SyntheticBeats.hop(endTime: time, broadband: nil, kick: kick)
            result.broadbandODF = odf
            tracker.process(result)
        }
        for _ in 0..<Int(2 / hop) { step(odf: 1.5, kick: nil) }
        let onset = OnsetEvent(time: time + hop, strength: 1)
        step(odf: 2 * ratio, kick: onset)
        let glow = tracker.schedule.events.first { !$0.predicted && $0.time == onset.time }
        #expect(abs((glow?.amplitude ?? 0) - amplitude) < 1e-4, "ratio \(ratio): \(String(describing: glow))")
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
    /// Больше нуля: на каждом таком «и» (по счету) еще и широкополосный онсет.
    var offbeatOnsetEvery = 0
    private var offbeatCount = 0

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
                if offbeatOnsetEvery > 0, offbeatCount % offbeatOnsetEvery == 0, hop.broadbandOnset == nil {
                    hop.broadbandOnset = OnsetEvent(time: nextOffbeatTime, strength: 1)
                }
                offbeatCount += 1
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
