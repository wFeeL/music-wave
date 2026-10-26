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

    /// Мягкий пульс по шагам: на каждом шаге сетка и горб из расписания, энергия из кадра шага
    /// (`WaveFrame.kickEnergy`, как у анализа приложения), время конец шага.
    private static func ambientTrace(_ hops: [HopResult]) -> (values: [(time: Double, value: Float)], tracker: BeatTracker) {
        var tracker = BeatTracker(framesPerSecond: fps)
        var values: [(time: Double, value: Float)] = []
        values.reserveCapacity(hops.count)
        for hop in hops {
            tracker.process(hop)
            var frame = hop.frame
            frame.kickEnergy = tracker.ambientEnergy
            values.append((hop.endTime, BeatGlow.ambient(at: hop.endTime, info: tracker.schedule.ambient, frame: frame)))
        }
        return (values, tracker)
    }

    /// Пульс на отрезке: наибольший, наименьший и доля шагов от 0.01.
    private static func ambientStats(
        _ values: [(time: Double, value: Float)], _ range: Range<Double>
    ) -> (peak: Float, low: Float, lit: Double) {
        let part = values.filter { range.contains($0.time) }.map(\.value)
        let lit = Double(part.filter { $0 >= 0.01 }.count) / Double(max(part.count, 1))
        return (part.max() ?? 0, part.min() ?? 0, lit)
    }

    /// Мягкий пульс трекера (`BeatSchedule.ambient` и энергия кадра): энергия бочки (короткая
    /// огибающая уровня полосы бочки против ее длинного среднего) и горб на сетке (уверенность × ворот)
    /// дают пульс в такт, который в брейке без бочки (`Drums.breakdown`, 10-18 с) гаснет вместе с
    /// энергией и воротом, а после возврата бочки возвращается. То же, когда под всей сценой лежит
    /// ровная подложка в полосе бочки (коричневый шум -24 dBFS и бас 55 Гц): бочка над ней дает
    /// ясный горб (замер: пик у бочек 6-10 с в медиане 0.13, не ниже 0.08), а в брейке пульс почти
    /// гаснет (пик 0.025, от 0.01 4 % шагов). После `reset()` пульса нет, энергия в расписании всегда 0.
    @Test func ambientFollowsKicksAndFadesInBreakdown() async {
        let (bare, bed) = await runOffCooperativePool {
            let scene = SharedScenes.breakdown
            let bed = Drums.bassBed(levelDB: -24, bassGain: 1, count: scene.samples.count, sampleRate: scene.sampleRate, seed: 9)
            let mixed = zip(scene.samples, bed).map { $0 + $1 }
            return (Hops.breakdown, StreamAnalyzer(sampleRate: scene.sampleRate).processSignal(mixed))
        }
        var (values, tracker) = Self.ambientTrace(bare)
        let before = Self.ambientStats(values, 6..<10)
        #expect(before.peak > 0.1, "peak before the break \(before.peak)")
        // Пульс в такт, а не ровный слой: между бочками он опускается.
        #expect(before.low < before.peak / 2, "low \(before.low) peak \(before.peak)")
        #expect(Self.ambientStats(values, 12..<18).peak < 0.02, "peak in the break")
        #expect(Self.ambientStats(values, 20..<24).peak > 0.1, "peak after the break")
        #expect(tracker.schedule.ambient?.energy == 0)
        tracker.reset()
        #expect(BeatGlow.ambient(at: 0, info: tracker.schedule.ambient, frame: .silent) == 0)
        #expect(tracker.ambientEnergy == 0)

        (values, tracker) = Self.ambientTrace(bed)
        let bedBefore = Self.ambientStats(values, 6..<10)
        let bedBreak = Self.ambientStats(values, 12..<18)
        #expect(bedBefore.peak > 0.1, "peak over the bed before the break \(bedBefore.peak)")
        #expect(bedBefore.low < bedBefore.peak / 2, "low \(bedBefore.low) peak \(bedBefore.peak)")
        let kickPeaks = SharedScenes.breakdown.kicks.filter { (6..<10).contains($0) }.map { kick in
            values.filter { $0.time >= kick - 0.03 && $0.time <= kick + 0.1 }.map(\.value).max() ?? 0
        }.sorted()
        #expect(kickPeaks.count >= 7)
        #expect(kickPeaks[kickPeaks.count / 2] > 0.1 && kickPeaks[0] > 0.05, "kick peaks over the bed \(kickPeaks)")
        #expect(bedBreak.peak < 0.05 && bedBreak.lit < 0.1, "break over the bed: peak \(bedBreak.peak), lit \(bedBreak.lit)")
        #expect(Self.ambientStats(values, 20..<24).peak > 0.1, "peak over the bed after the break")
    }

    /// Ровный неровный звук без ударов (коричневый шум -20 dBFS, основная энергия в полосе бочки): в
    /// среднем энергия около 1 (95-й процентиль 1.24), и с нижним краем 1.2 пульс от 0.01 только на
    /// редких всплесках шума (замер: 4.0 % шагов, при крае 1.0 было 18 %), а не постоянным слоем.
    /// Против среднего сырого уровня было около 1.4 и слой 0.086.
    @Test func steadyNoiseKeepsThePulseLow() async {
        let hops = await runOffCooperativePool {
            StreamAnalyzer(sampleRate: 48_000).processSignal(Drums.brownNoise(levelDB: -20, count: 48_000 * 12, seed: 5))
        }
        let values = Self.ambientTrace(hops).values
        let stats = Self.ambientStats(values, 3..<12)
        #expect(stats.lit < 0.08, "share of steps with pulse >= 0.01: \(stats.lit)")
        let sorted = values.filter { (3..<12).contains($0.time) }.map(\.value).sorted()
        #expect(sorted[sorted.count / 2] == 0, "median pulse \(sorted[sorted.count / 2])")
    }

    /// Звук ниже порога шума волн (`LevelProcessor.noiseFloorDB`): коричневый шум -80 dBFS в полосе
    /// бочки не дает ни энергии, ни горба, остров может уйти в простой.
    @Test func noiseBelowTheFloorHasNoPulse() async {
        let hops = await runOffCooperativePool {
            StreamAnalyzer(sampleRate: 48_000).processSignal(Drums.brownNoise(levelDB: -80, count: 48_000 * 6, seed: 5))
        }
        let (values, tracker) = Self.ambientTrace(hops)
        #expect(values.allSatisfy { $0.value == 0 })
        #expect(tracker.ambientEnergy == 0)
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
    /// вспышки мимо новых долей (уверенная вспышка не на ту долю хуже темноты). С одиночной атакой на
    /// старой доле посреди брейка (ворот закрыт) то же самое: решает только доля с открытым воротом.
    @Test(arguments: [false, true])
    func coastReturnOffTheGridUnlocks(strayHit: Bool) throws {
        var tracker = BeatTracker(framesPerSecond: Self.fps)
        var hops = SyntheticBeats(bpm: 120)
        hops.feed(&tracker, until: 10)
        try #require(tracker.locked)
        // Тишина 4 с (уровень бочки -40 dBFS): ворот закрывается, захват держится накатом.
        hops.feedSilence(&tracker, until: 14)
        if strayHit {
            // Атака на последней старой доле перед возвратом (14.25 с), уровень бочки не растет.
            hops.feedSilence(&tracker, until: 14.25)
            hops.endTime += hops.hop
            var hop = SyntheticBeats.hop(endTime: hops.endTime, broadband: OnsetEvent(time: 14.25, strength: 1), kick: nil)
            hop.kickLevelDB = -40
            tracker.process(hop)
            hops.feedSilence(&tracker, until: 14.45)
        }
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
        try #require(tracker.displayWeight == 1)
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
        var takeover: (time: Double, confidence: Double, hits: Int, shadowConfidence: Double, shadowHits: Int)?
        var alwaysLocked = true
        var previous = tracker
        let watch = { (tracker: BeatTracker) in
            if shadowStart == nil, tracker.shadowNext != nil { shadowStart = tracker.now }
            if takeover == nil, previous.shadowNext != nil, tracker.shadowNext == nil, tracker.nextBeat.map({
                abs(BeatTracker.circularDifference($0 - 0.5, period: 0.5)) < 0.03
            }) == true {
                takeover = (tracker.now, tracker.confidence, tracker.hits, previous.shadowConfidence, previous.shadowHits)
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
            // Счет тени после попадания на доле перехвата, а не счет прежней сетки.
            let gain = tracker.parameters.confidenceGain
            #expect(abs(won.confidence - (won.shadowConfidence + gain * (1 - won.shadowConfidence))) < 1e-9, "\(won)")
            #expect(won.hits == won.shadowHits + 1, "\(won)")
            #expect(tracker.shadowConfidence == 0 && tracker.shadowHits == 0)
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

    /// Тень от PLP (`plpShadow`): гребенка выключена огромным запасом (`phaseJumpMargin`), «и» без
    /// онсетов вдвое сильнее доли. PLP переходит на «и» за несколько секунд, и когда он там уверен (не
    /// ниже `plpShadow`), он запускает тень и голосует за нее: сетка уходит на «и» без потери
    /// захвата. С выключенным PLP (0) тени нет и сетка стоит.
    @Test(arguments: [(0.8, true), (0.0, false)])
    func confidentPLPProposesTheShadow(plpShadow: Double, moves: Bool) throws {
        #expect(BeatTracker.Parameters().plpShadow == 0.8)
        var parameters = BeatTracker.Parameters()
        parameters.plpShadow = plpShadow
        parameters.phaseJumpMargin = 1e9
        var tracker = BeatTracker(framesPerSecond: Self.fps, parameters: parameters)
        var hops = SyntheticBeats(bpm: 120)
        hops.feed(&tracker, until: 10)
        try #require(tracker.locked && tracker.confidence >= parameters.lockConfidence)
        hops.offbeatODF = 100
        hops.nextOffbeatTime = hops.nextBeatTime + 0.25
        var shadowStart: (time: Double, plpConfidence: Float, plpBeat: Double)?
        var moved: Double?
        var lockedUntilMove = true
        // Доля PLP на каждом шаге в конце сцены (не только на проверках темпа раз в 0.25 с, где фаза на
        // 120 BPM всегда около 0 или 0.5), когда PLP уверен.
        var worstPLPBeat = 0.0
        var confidentSteps = 0
        hops.feed(&tracker, until: 18) { tracker in
            if tracker.now >= 16, Double(tracker.plpConfidence) >= 0.8, let beat = tracker.plpBeat {
                worstPLPBeat = max(worstPLPBeat, abs(BeatTracker.circularDifference(beat.time - 0.5, period: 0.5)))
                confidentSteps += 1
            }
            if shadowStart == nil, let shadow = tracker.shadowNext {
                shadowStart = (tracker.now, tracker.plpConfidence, tracker.plpBeat?.time ?? .nan)
                #expect(abs(BeatTracker.circularDifference(shadow - 0.5, period: 0.5)) < 0.03, "shadow at \(shadow)")
            }
            let onOffbeat = tracker.nextBeat.map { abs(BeatTracker.circularDifference($0 - 0.5, period: 0.5)) < 0.03 } == true
            if moved == nil, onOffbeat { moved = tracker.now }
            if moved == nil { lockedUntilMove = lockedUntilMove && tracker.locked }
        }
        let next = try #require(tracker.nextBeat)
        #expect(confidentSteps > 300)
        #expect(worstPLPBeat < 0.03, "PLP beat off the offbeat by \(worstPLPBeat) s")
        if moves {
            let start = try #require(shadowStart, "no shadow phase")
            #expect(Double(start.plpConfidence) >= plpShadow, "PLP confidence \(start.plpConfidence) at the shadow start")
            #expect(abs(BeatTracker.circularDifference(start.plpBeat - 0.5, period: 0.5)) < 0.03, "PLP beat \(start.plpBeat)")
            let move = try #require(moved, "the grid never moved")
            let votes = Double(parameters.raceVotes) * TempoEstimator.updateInterval
            #expect(move - start.time >= votes - 0.01 && move - start.time <= votes + 0.5 + 0.01, "moved \(move - start.time) s after the shadow")
            #expect(lockedUntilMove)
            #expect(abs(BeatTracker.circularDifference(next - 0.5, period: 0.5)) < 0.03, "next beat \(next)")
        } else {
            #expect(shadowStart == nil)
            #expect(moved == nil)
            #expect(abs(BeatTracker.circularDifference(next - 0.25, period: 0.5)) < 0.02, "next beat \(next)")
        }
    }

    /// Счет расхождений (`disagreements`) общий у гребенки и PLP, но идет подряд только от одного
    /// предлагающего. «И» без онсетов в полтора раза сильнее доли, порог PLP занижен до 0.3, чтобы
    /// предлагающий менялся от проверки к проверке: без сброса тень стартовала по голосу PLP и
    /// следующему голосу гребенки. На каждой смене счет начинается заново, поэтому сразу после нее в
    /// нем не больше одного голоса.
    @Test func disagreementsRestartWhenTheProposerChanges() throws {
        var parameters = BeatTracker.Parameters()
        parameters.plpShadow = 0.3
        var tracker = BeatTracker(framesPerSecond: Self.fps, parameters: parameters)
        var hops = SyntheticBeats(bpm: 120)
        hops.feed(&tracker, until: 10)
        try #require(tracker.locked && tracker.confidence >= parameters.lockConfidence)
        hops.offbeatODF = 75
        hops.nextOffbeatTime = hops.nextBeatTime + 0.25
        var previous = tracker.proposedByPLP
        var changes = 0
        var worst = 0
        hops.feed(&tracker, until: 20) { tracker in
            guard tracker.proposedByPLP != previous else { return }
            previous = tracker.proposedByPLP
            changes += 1
            worst = max(worst, tracker.disagreements)
        }
        #expect(changes > 2)
        #expect(worst <= 1, "\(worst) disagreements right after a proposer change")
    }

    /// Перехват тенью (голоса гребенки, `combVotesDecideTheRace`) дает новую сетку со счетом тени:
    /// вес сразу не выше цели по уверенности тени, полный вес старой сетки не переходит на «и».
    @Test func shadowTakeoverTakesItsOwnWeight() throws {
        let parameters = BeatTracker.Parameters()
        var tracker = BeatTracker(framesPerSecond: Self.fps)
        var hops = SyntheticBeats(bpm: 120)
        hops.feed(&tracker, until: 10)
        try #require(tracker.locked && tracker.displayWeight == 1)
        hops.offbeatODF = 100
        hops.nextOffbeatTime = hops.nextBeatTime + 0.25
        var atMove: (weight: Float, confidence: Double)?
        hops.feed(&tracker, until: 16) { tracker in
            let onOffbeat = tracker.nextBeat.map { abs(BeatTracker.circularDifference($0 - 0.5, period: 0.5)) < 0.03 } == true
            if atMove == nil, onOffbeat { atMove = (tracker.displayWeight, tracker.confidence) }
        }
        let move = try #require(atMove, "the grid never moved")
        let target = BeatTracker.smoothstep(Float(parameters.weightLow), Float(parameters.weightHigh), Float(move.confidence))
        #expect(target < 0.5, "shadow confidence \(move.confidence)")
        #expect(move.weight <= target, "weight \(move.weight) after the takeover, target \(target)")
    }

    /// Пока идет гонка фаз, предсказанные доли текущей сетки светятся с `raceDim` (0.2, замер на
    /// GTZAN) от обычной яркости: уверенная вспышка на доле, в которой гребенка уже сомневается, хуже
    /// тусклой. Сравнение с двойником без приглушения на тех же шагах: состояние и id у них общие.
    @Test func raceDimsTheGrid() throws {
        #expect(BeatTracker.Parameters().raceDim == 0.2)
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
            #expect(abs(beat.amplitude - 0.2 * reference) < 1e-4, "beat \(id): \(beat.amplitude) of \(reference)")
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

    /// Пауза в том же треке (`reset(keepTempo: true)`): период, половина уверенности и захват в счете
    /// попаданий остаются, фазу гребенка находит заново по прежнему периоду, как только в истории две
    /// доли, и через 1,5 с после возобновления доли снова вспыхивают на новых местах. Полный сброс
    /// (`false`) до первой оценки темпа (2 с истории) долей не показывает.
    @Test(arguments: [true, false])
    func resetKeepingTempoResumesFast(keepTempo: Bool) throws {
        var tracker = BeatTracker(framesPerSecond: Self.fps)
        var hops = SyntheticBeats(bpm: 120)
        hops.feed(&tracker, until: 10)
        try #require(tracker.locked)
        let confidence = tracker.confidence
        tracker.reset(keepTempo: keepTempo)
        #expect(!tracker.locked && tracker.lastUnlockReason == .reset)
        #expect(tracker.nextBeat == nil && tracker.schedule.events.isEmpty)
        #expect(tracker.resumingTempo == keepTempo)
        if keepTempo {
            #expect(tracker.confidence == confidence * 0.5)
            #expect(tracker.period.map { abs($0 - 0.5) < 0.005 } == true, "period \(String(describing: tracker.period))")
        } else {
            #expect(tracker.confidence == 0 && tracker.period == nil)
        }

        // Новый поток с нуля, доли не там, где были до паузы: 0.37 против 0.25 по кругу периода.
        var resumed = SyntheticBeats(bpm: 120)
        resumed.nextBeatTime = 0.37
        // Меньше двух долей истории: фазы еще нет, и вес показа без сетки не растет (иначе онсеты бочки
        // приглушались бы как при сетке, которой нет).
        resumed.feed(&tracker, until: 0.9)
        #expect(tracker.nextBeat == nil && tracker.displayWeight == 0)
        resumed.feed(&tracker, until: 1.5)
        let flashes = tracker.schedule.events.filter { $0.predicted && $0.time > 1.5 && $0.amplitude > OfflineBeatChain.eventRise }
        if keepTempo {
            #expect(!flashes.isEmpty, "events \(tracker.schedule.events)")
            for flash in flashes {
                #expect(abs(BeatTracker.circularDifference(flash.time - 0.37, period: 0.5)) < 0.02, "flash at \(flash.time)")
            }
        } else {
            #expect(flashes.isEmpty, "flashes \(flashes)")
            #expect(tracker.period == nil)
        }

        // Первая настоящая оценка темпа (после 2 с истории) идет как подстройка: вернувшийся захват не
        // теряется, сетка на месте, память больше не нужна.
        var relocked = tracker.locked
        var lost = false
        resumed.feed(&tracker, until: 6) { tracker in
            if tracker.locked {
                relocked = true
            } else if relocked {
                lost = true
            }
        }
        #expect(relocked && !lost && tracker.locked)
        #expect(!tracker.resumingTempo)
        #expect(tracker.nextBeat.map { abs(BeatTracker.circularDifference($0 - 0.37, period: 0.5)) < 0.01 } == true)
    }

    /// Память темпа не копится: второй сброс с памятью без шагов между ними уверенность снова не делит,
    /// полный сброс память стирает, и сброс с памятью после него сохранять нечего.
    @Test func keptTempoHalvesOnceAndFullResetForgetsIt() throws {
        var tracker = BeatTracker(framesPerSecond: Self.fps)
        var hops = SyntheticBeats(bpm: 120)
        hops.feed(&tracker, until: 10)
        try #require(tracker.locked)
        tracker.reset(keepTempo: true)
        let kept = tracker.confidence
        let period = tracker.period
        #expect(kept > 0.4 && period != nil)
        tracker.reset(keepTempo: true)
        #expect(tracker.confidence == kept && tracker.period == period && tracker.resumingTempo)
        tracker.reset()
        #expect(tracker.confidence == 0 && tracker.period == nil && !tracker.resumingTempo)
        tracker.reset(keepTempo: true)
        #expect(tracker.confidence == 0 && tracker.period == nil && !tracker.resumingTempo)
    }

    /// Без захвата память дает только период и уверенность: новый захват ждет `lockHits` новых
    /// попаданий подряд на сетке, найденной заново.
    @Test func keptTempoWithoutLockNeedsNewHits() throws {
        var tracker = BeatTracker(framesPerSecond: Self.fps)
        var hops = SyntheticBeats(bpm: 120)
        hops.feed(&tracker, until: 3)
        try #require(!tracker.locked && tracker.period != nil)
        let confidence = tracker.confidence
        tracker.reset(keepTempo: true)
        #expect(tracker.confidence == confidence * 0.5 && tracker.resumingTempo)
        var resumed = SyntheticBeats(bpm: 120)
        resumed.nextBeatTime = 0.37
        var lockedAt: Double?
        resumed.feed(&tracker, until: 6) { tracker in
            if lockedAt == nil, tracker.locked { lockedAt = tracker.now }
        }
        // Сетка с 1 с потока, пять попаданий подряд с доли 1.37: захват на закрытии окна пятой доли
        // (3.37 + 0.075 с, замер 3.445 с), не раньше и не на долю позже.
        #expect(lockedAt.map { $0 >= 3.3 && $0 < 3.6 } == true, "locked at \(String(describing: lockedAt))")
    }

    /// Вес показа в трекере: 0, пока уверенность не выше `weightLow`, и доходит до 1 не позже чем за
    /// `weightRiseBeats` долей (плюс шаг на границе) после того, как уверенность дошла до `weightHigh`.
    /// Заменяет `blendCrossfadesInOneBeat`: смесь шла по захвату за одну долю, вес идет по уверенности и
    /// начинает расти до захвата.
    @Test func weightFollowsConfidence() throws {
        let parameters = BeatTracker.Parameters()
        var tracker = BeatTracker(framesPerSecond: Self.fps)
        var hops = SyntheticBeats(bpm: 120)
        let hop = hops.hop
        var steps = 0
        var highStep: Int?
        var fullStep: Int?
        var weightBelowLow: Float = 0
        hops.feed(&tracker, until: 10) { tracker in
            steps += 1
            if tracker.confidence <= parameters.weightLow { weightBelowLow = max(weightBelowLow, tracker.displayWeight) }
            if highStep == nil, tracker.confidence >= parameters.weightHigh { highStep = steps }
            if fullStep == nil, tracker.displayWeight == 1 { fullStep = steps }
        }
        #expect(weightBelowLow == 0)
        let high = Double(try #require(highStep)) * hop
        let full = Double(try #require(fullStep)) * hop
        #expect(full - high <= parameters.weightRiseBeats * 0.5 + 2 * hop, "confidence high at \(high), full weight at \(full)")
        #expect(tracker.schedule.weight == tracker.displayWeight)
    }

    /// Уверенность скачком 0 -> 0.8: вес растет примерно за полторы доли, через 2 доли он выше 0.6, но
    /// не сразу (через полдоли меньше 0.5).
    @Test func weightRisesInAboutOneAndHalfBeats() {
        let parameters = BeatTracker.Parameters()
        #expect(parameters.weightLow == 0.30 && parameters.weightHigh == 0.60)
        #expect(parameters.weightRiseBeats == 1.5 && parameters.weightFallBeats == 6)
        #expect(parameters.weightHits == 3)
        let step = 0.01
        var weight: Float = 0
        var trace: [Float] = []
        for _ in 0..<200 {
            weight = BeatTracker.nextWeight(weight, confidence: 0.8, beats: step, parameters: parameters)
            trace.append(weight)
        }
        #expect(trace[49] < 0.5, "after half a beat \(trace[49])")
        #expect(abs(trace[99] - 1 / 1.5) < 0.01, "after a beat \(trace[99])")
        #expect(trace[199] > 0.6, "after 2 beats \(trace[199])")
        // Ниже `weightLow` цель 0: вес не растет. Посередине между краями цель 0.5, плавно, а не скачком.
        #expect(BeatTracker.nextWeight(0, confidence: 0.3, beats: 1, parameters: parameters) == 0)
        #expect(abs(BeatTracker.nextWeight(0, confidence: 0.45, beats: 10, parameters: parameters) - 0.5) < 1e-5)
        #expect(abs(BeatTracker.nextWeight(1, confidence: 0.45, beats: 10, parameters: parameters) - 0.5) < 1e-5)
    }

    /// Уверенность 0.8 -> 0.1: вес спадает примерно за 6 долей, через 2 доли выше 0.4, через 8 ниже 0.15.
    @Test func weightFallsOverAboutSixBeats() {
        let parameters = BeatTracker.Parameters()
        let step = 0.01
        var weight = BeatTracker.nextWeight(0, confidence: 0.8, beats: 10, parameters: parameters)
        #expect(weight == 1)
        var trace: [Float] = []
        for _ in 0..<800 {
            weight = BeatTracker.nextWeight(weight, confidence: 0.1, beats: step, parameters: parameters)
            trace.append(weight)
        }
        #expect(trace[199] > 0.4, "after 2 beats \(trace[199])")
        #expect(abs(trace[299] - 0.5) < 0.01, "after 3 beats \(trace[299])")
        #expect(trace[799] < 0.15, "after 8 beats \(trace[799])")
    }

    /// Захват, потом доли без атак при открытом вороте: уверенность падает за доли, вес идет за ней
    /// медленно, и предсказанные доли гаснут постепенно, а не за одну долю.
    @Test func weightFadesAfterUnlock() throws {
        var tracker = BeatTracker(framesPerSecond: Self.fps)
        var hops = SyntheticBeats(bpm: 120)
        hops.feed(&tracker, until: 10)
        try #require(tracker.locked && tracker.displayWeight == 1)
        var time = hops.endTime
        var unlockedAt: Double?
        var weightAtUnlock: Float = 0
        while time < 16 {
            time += hops.hop
            var hop = SyntheticBeats.hop(endTime: time, broadband: nil, kick: nil)
            hop.kickLevelDB = -6
            tracker.process(hop)
            if unlockedAt == nil, !tracker.locked {
                unlockedAt = time
                weightAtUnlock = tracker.displayWeight
            }
        }
        let unlock = try #require(unlockedAt)
        // Уверенность ниже 0.25 при отпускании, вес еще не догнал свою цель 0.
        #expect(weightAtUnlock > 0.2, "weight at the unlock \(unlock) s: \(weightAtUnlock)")
        #expect(tracker.displayWeight == 0)
    }

    /// Новая сетка (смена темпа на другую сетку) не наследует вес старой: сразу не выше цели по своей
    /// половинной уверенности. Старый вес эту сетку не подтверждал.
    @Test func newGridTakesItsOwnWeight() throws {
        let parameters = BeatTracker.Parameters()
        var tracker = BeatTracker(framesPerSecond: Self.fps)
        var hops = SyntheticBeats(bpm: 120)
        hops.feed(&tracker, until: 10)
        try #require(tracker.locked && tracker.displayWeight == 1)
        let period = try #require(tracker.period)
        tracker.updateTempo(TempoEstimate(period: period / 1.3, switched: true))
        let target = BeatTracker.smoothstep(Float(parameters.weightLow), Float(parameters.weightHigh), Float(tracker.confidence))
        #expect(target < 0.8)
        #expect(tracker.displayWeight <= target, "weight \(tracker.displayWeight), target \(target)")
    }

    /// Без захвата сетка, которая попадает только через долю (уверенность ходит около 0.43-0.57, два
    /// попадания подряд не бывает), не набирает веса: свечение остается за бочками. С `weightHits` 0
    /// та же сетка светилась бы почти в полную силу.
    @Test(arguments: [(3, false), (2, false), (0, true)])
    func weightNeedsHitsInARowWhileUnlocked(weightHits: Int, rises: Bool) throws {
        var parameters = BeatTracker.Parameters()
        parameters.weightHits = weightHits
        var tracker = BeatTracker(framesPerSecond: Self.fps, parameters: parameters)
        let hop = 256.0 / 48_000
        var time = 0.0
        var next = 0.25
        var beat = 0
        var peak: Float = 0
        var peakConfidence = 0.0
        // Широкополосная функция и бочка на каждой доле 120 BPM (темп 120), атака только на четных.
        while time < 16 {
            time += hop
            var onset: OnsetEvent?
            var kick: OnsetEvent?
            if next <= time {
                kick = OnsetEvent(time: next, strength: 1)
                if beat % 2 == 0 { onset = kick }
                beat += 1
                next += 0.5
            }
            tracker.process(SyntheticBeats.hop(endTime: time, broadband: onset, kick: kick))
            if time > 8 {
                peak = max(peak, tracker.displayWeight)
                peakConfidence = max(peakConfidence, tracker.confidence)
            }
        }
        try #require(tracker.period.map { abs($0 - 0.5) < 0.02 } == true)
        #expect(!tracker.locked)
        #expect(peakConfidence > parameters.weightLow, "confidence \(peakConfidence)")
        if rises {
            #expect(peak > 0.4, "weight \(peak)")
        } else {
            #expect(peak == 0, "weight \(peak)")
        }
    }

    /// Без захвата сетка, которая попадает два раза подряд и промахивается на третьей доле (уверенность
    /// около 0.57-0.74, захвата нет: нужно 5 подряд), при `weightHits` 3 (по умолчанию) не набирает
    /// веса; при 2 набрала бы. Три попадания подряд выбраны по приоритету владельца: на GTZAN tune
    /// вспышек мимо долей 2391 против 2617 при 2.
    @Test(arguments: [(3, false), (2, true)])
    func weightNeedsThreeHitsInARow(weightHits: Int, rises: Bool) throws {
        var parameters = BeatTracker.Parameters()
        parameters.weightHits = weightHits
        var tracker = BeatTracker(framesPerSecond: Self.fps, parameters: parameters)
        let hop = 256.0 / 48_000
        var time = 0.0
        var next = 0.25
        var beat = 0
        var peak: Float = 0
        var peakConfidence = 0.0
        var everLocked = false
        // Функция онсетов и бочка на каждой доле 120 BPM, атака на двух долях из трех.
        while time < 16 {
            time += hop
            var onset: OnsetEvent?
            var kick: OnsetEvent?
            if next <= time {
                kick = OnsetEvent(time: next, strength: 1)
                if beat % 3 != 2 { onset = kick }
                beat += 1
                next += 0.5
            }
            tracker.process(SyntheticBeats.hop(endTime: time, broadband: onset, kick: kick))
            everLocked = everLocked || tracker.locked
            if time > 8 {
                peak = max(peak, tracker.displayWeight)
                peakConfidence = max(peakConfidence, tracker.confidence)
            }
        }
        try #require(tracker.period.map { abs($0 - 0.5) < 0.02 } == true)
        #expect(!everLocked)
        #expect(peakConfidence > parameters.weightHigh, "confidence \(peakConfidence)")
        if rises {
            #expect(peak > 0.5, "weight \(peak)")
        } else {
            #expect(peak == 0, "weight \(peak)")
        }
    }

    /// Бочка у доли сетки отбрасывается, только когда сама доля вспыхнет (яркость выше `eventRise`):
    /// при полном весе, но слабых атаках (сила 0.15, яркость доли около 0.15) бочка на доле остается в
    /// расписании, при сильных (сила 1) отбрасывается. Раньше решал один вес (выше 0.5).
    @Test(arguments: [(Float(0.15), true), (Float(1), false)])
    func kickNearTheGridDroppedOnlyWhenTheBeatFlashes(strength: Float, kept: Bool) throws {
        var tracker = BeatTracker(framesPerSecond: Self.fps)
        let hop = 256.0 / 48_000
        var time = 0.0
        var next = 0.25
        var kicks: [Double] = []
        var seenKicks: Set<Double> = []
        var beatAmplitude: Float = 0
        while time < 10 {
            time += hop
            var onset: OnsetEvent?
            if next <= time {
                onset = OnsetEvent(time: next, strength: strength)
                if time > 8 { kicks.append(next) }
                next += 0.5
            }
            tracker.process(SyntheticBeats.hop(endTime: time, broadband: onset, kick: onset))
            for event in tracker.schedule.events where event.time > 8 {
                if !event.predicted { seenKicks.insert(event.time) }
                if event.predicted, event.time <= tracker.now { beatAmplitude = max(beatAmplitude, event.amplitude) }
            }
        }
        try #require(tracker.locked && tracker.displayWeight == 1)
        try #require(!kicks.isEmpty)
        if kept {
            #expect(beatAmplitude <= OfflineBeatChain.eventRise, "beat \(beatAmplitude)")
            #expect(kicks.allSatisfy { seenKicks.contains($0) }, "kicks \(kicks), in schedule \(seenKicks.sorted())")
        } else {
            #expect(beatAmplitude > OfflineBeatChain.eventRise, "beat \(beatAmplitude)")
            #expect(seenKicks.isEmpty, "kicks in schedule \(seenKicks.sorted())")
        }
    }

    /// Яркость предсказанной доли фиксируется, когда время потока доходит до доли, и дальше не
    /// меняется, хотя вес и ворот растут: проверка на захвате с нуля, где вес идет вверх.
    @Test func amplitudeFrozenAtFirstSight() throws {
        var tracker = BeatTracker(framesPerSecond: Self.fps)
        var hops = SyntheticBeats(bpm: 120)
        var firstSight: [UInt64: Float] = [:]
        var changedAfterSight = 0
        var rising = 0
        var lastWeight: Float = 0
        hops.feed(&tracker, until: 8) { tracker in
            if tracker.displayWeight > lastWeight { rising += 1 }
            lastWeight = tracker.displayWeight
            for event in tracker.schedule.events where event.predicted && event.time <= tracker.now {
                if let seen = firstSight[event.id] {
                    if seen != event.amplitude { changedAfterSight += 1 }
                } else {
                    firstSight[event.id] = event.amplitude
                }
            }
        }
        #expect(rising > 0)
        #expect(firstSight.values.contains { $0 > 0 })
        #expect(changedAfterSight == 0)
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

    /// Быстрая сетка (160 BPM), бочка через долю, широкополосный онсет на каждой (на долях с бочкой
    /// сильнее, как в музыке): предсказанные доли вспыхивают через одну, на долях с бочкой, а мягкий
    /// пульс стоит на каждой доле (период сетки). Четность решает широкополосный акцент: с акцентом на
    /// долях без бочки вспыхивают они. Тот же рисунок на 100 BPM (период выше `everyOtherPeriod`) и с
    /// выключенным правилом светит каждую долю.
    @Test(arguments: [
        (160.0, 0.42, true, true), (160.0, 0.42, false, true), (100.0, 0.42, true, false), (160.0, 0.0, true, false),
    ])
    func fastTempoFlashesEveryOtherBeat(bpm: Double, everyOtherPeriod: Double, accentOnKicks: Bool, halves: Bool) throws {
        var tracker = BeatTracker(framesPerSecond: Self.fps, parameters: .init(everyOtherPeriod: everyOtherPeriod))
        var hops = SyntheticBeats(bpm: bpm)
        hops.kickEvery = 2
        hops.beatODF = accentOnKicks ? [60, 50] : [50, 60]
        hops.feed(&tracker, until: 8)
        try #require(tracker.locked)
        let period = try #require(tracker.period)
        try #require(abs(period * bpm / 60 - 1) < 0.02, "locked at \(60 / period) BPM")
        // Доли сцены на 0.25 + k · 60 / bpm, бочка на четных k. Яркость доли берется, когда время
        // потока до нее дошло (дальше она не меняется).
        let scenePeriod = 60 / bpm
        let amplitudes = Self.predictedAmplitudes(&tracker, &hops, from: 9, until: 14, scenePeriod: scenePeriod) { tracker in
            guard let ambient = tracker.schedule.ambient else { return }
            #expect(abs(ambient.period - scenePeriod) / scenePeriod < 0.05, "pulse period \(ambient.period)")
            #expect(abs(BeatTracker.circularDifference(ambient.anchor - 0.25, period: scenePeriod)) < 0.05 * scenePeriod)
            #expect(ambient.confidence > 0.5, "pulse height \(ambient.confidence)")
        }
        try #require(Double(amplitudes.count) >= 4.5 / scenePeriod, "\(amplitudes.count) beats checked")
        let shown = accentOnKicks ? 0 : 1
        for (beat, amplitude) in amplitudes.sorted(by: { $0.key < $1.key }) {
            let flashes = amplitude > OfflineBeatChain.eventRise
            #expect(flashes == (!halves || beat % 2 == shown), "beat \(beat): amplitude \(amplitude)")
        }
    }

    /// Бочка раз в 2T и тишина в полосе бочки между ними (160 BPM): удержание ворота тянется на период
    /// показа, и показанные доли с бочкой вспыхивают. С удержанием на T ворот к доле с бочкой уже
    /// закрыт (28 дБ спада) и сетка через долю темнеет; без правила вспыхивают только доли без бочки,
    /// куда ворот еще открыт (так было в `ritardandoKeepsGlow` после смены на удвоенный темп).
    @Test(arguments: [(0.42, true), (0.0, false)])
    func everyOtherKeepsTheGateOpenForShownBeats(everyOtherPeriod: Double, kickBeatsFlash: Bool) throws {
        var tracker = BeatTracker(framesPerSecond: Self.fps, parameters: .init(everyOtherPeriod: everyOtherPeriod))
        var hops = SyntheticBeats(bpm: 160)
        hops.kickEvery = 2
        hops.beatODF = [60, 50]
        hops.quietBetweenKicks = true
        hops.feed(&tracker, until: 8)
        try #require(tracker.locked)
        let amplitudes = Self.predictedAmplitudes(&tracker, &hops, from: 9, until: 14, scenePeriod: 60.0 / 160)
        let kickBeats = amplitudes.filter { $0.key % 2 == 0 }.map(\.value)
        try #require(kickBeats.count >= 5)
        let flashing = kickBeats.filter { $0 > OfflineBeatChain.eventRise }.count
        // Без правила яркость доли фиксируется по вороту до звука бочки; доля, которую ФАПЧ поставила чуть
        // позже шага бочки, еще может вспыхнуть.
        #expect(kickBeatsFlash ? flashing == kickBeats.count : flashing <= 1, "kick beats \(kickBeats)")
    }

    /// Яркость предсказанных долей сцены (номер доли k на 0.25 + k · период сцены) с `from` до `until`,
    /// какой она была, когда время потока до доли дошло.
    private static func predictedAmplitudes(
        _ tracker: inout BeatTracker, _ hops: inout SyntheticBeats, from: Double, until end: Double, scenePeriod: Double,
        each: (BeatTracker) -> Void = { _ in }
    ) -> [Int: Float] {
        var amplitudes: [Int: Float] = [:]
        hops.feed(&tracker, until: end) { tracker in
            for event in tracker.schedule.events where event.predicted && event.time <= tracker.now && event.time >= from {
                amplitudes[Int(((event.time - 0.25) / scenePeriod).rounded())] = event.amplitude
            }
            each(tracker)
        }
        return amplitudes
    }

    /// Четность показа через долю держится, пока гребенка другой четности не выше больше чем на
    /// `everyOtherHold` (по умолчанию в 1.5 раза): на 160 BPM с акцентом на четных долях вспыхивают
    /// четные; акцент на нечетных в 1.3 раза сильнее показ не перебрасывает (без удержания
    /// перебрасывает), в 2.6 раза перебрасывает.
    @Test(arguments: [(nil, false), (0.0, true)] as [(Double?, Bool)])
    func everyOtherParityHoldsUntilClearlyBeaten(hold: Double?, flipsOnWeakAccent: Bool) throws {
        let parameters = hold.map { BeatTracker.Parameters(everyOtherHold: $0) } ?? BeatTracker.Parameters()
        var tracker = BeatTracker(framesPerSecond: Self.fps, parameters: parameters)
        var hops = SyntheticBeats(bpm: 160)
        let scenePeriod = 60.0 / 160
        // Какая четность долей сцены вспыхивала за последние 1.5 с отрезка: 0, 1 или nil (обе или ни
        // одной).
        func shownParity(until end: Double) throws -> Int? {
            var bright: Set<Int> = []
            var dark: Set<Int> = []
            hops.feed(&tracker, until: end) { tracker in
                for event in tracker.schedule.events where event.predicted && event.time <= tracker.now && event.time >= end - 1.5 {
                    let beat = Int(((event.time - 0.25) / scenePeriod).rounded())
                    if event.amplitude > OfflineBeatChain.eventRise { bright.insert(beat % 2) } else { dark.insert(beat % 2) }
                }
            }
            try #require(tracker.locked, "lost the lock by \(end) s")
            let period = try #require(tracker.period)
            try #require(abs(period / scenePeriod - 1) < 0.02, "tempo \(60 / period) BPM at \(end) s")
            guard bright.count == 1, let parity = bright.first, !dark.contains(parity) else { return nil }
            return parity
        }
        hops.beatODF = [60, 50]
        #expect(try shownParity(until: 10) == 0)
        hops.beatODF = [50, 65]
        #expect(try shownParity(until: 17) == (flipsOnWeakAccent ? 1 : 0))
        // Сильный акцент берет показ раньше, чем оценка темпа уходит на половинный темп.
        hops.beatODF = [50, 130]
        #expect(try shownParity(until: 20.5) == 1)
    }

    /// Близкая смена темпа, пока ФАПЧ отстала от долей (журнал 2: доли на 0.18 периода позже ФАПЧ,
    /// потом смена 77.9 -> 73.5 BPM): уверенность и захват остаются, фаза переходит к гребенке. Те же
    /// доли на «и» (полпериода) это другая сетка, захват сбрасывается. Если гребенка у старой фазы не
    /// слабее с запасом (там осталась функция онсетов без онсетов), фаза не прыгает: захват остается на
    /// ФАПЧ.
    @Test(arguments: [(0.09, true, false), (0.25, false, false), (0.09, true, true)])
    func nearTempoMoveFollowsTheComb(shift: Double, carries: Bool, oldPhaseStaysStrong: Bool) throws {
        var tracker = BeatTracker(framesPerSecond: Self.fps)
        var hops = SyntheticBeats(bpm: 120)
        hops.feed(&tracker, until: 10)
        try #require(tracker.locked)
        // Доли сдвигаются позже окна совпадения (0.075 с): ФАПЧ их не видит, три промаха подряд.
        let oldNext = hops.nextBeatTime
        hops.nextBeatTime += shift
        if oldPhaseStaysStrong {
            // Функция онсетов на старых долях (60, онсетов нет): гребенка у новой фазы сильнее, но без
            // запаса `phaseJumpMargin`.
            hops.offbeatODF = 60
            hops.nextOffbeatTime = oldNext
        }
        hops.feed(&tracker, until: 11.5)
        try #require(tracker.locked)
        let period = try #require(tracker.period)
        let confidence = tracker.confidence
        tracker.updateTempo(TempoEstimate(period: period * 1.06, switched: true))
        let next = try #require(tracker.nextBeat)
        let newPeriod = try #require(tracker.period)
        if oldPhaseStaysStrong {
            // Фаза ФАПЧ осталась на старых долях 0.25 + k · 0.5 с.
            let offset = BeatTracker.circularDifference(next - 0.25, period: 0.5)
            #expect(abs(offset) < 0.03, "next beat \(next) left the PLL phase by \(offset)")
            #expect(tracker.locked && tracker.confidence == confidence)
            return
        }
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

    /// Мягкий пол подтверждения бочки для показа (`kickConfirmFloor`, по умолчанию выключен, см.
    /// отчет B4): онсет бочки с отношением 6 (ниже строгого порога 7) светится не тусклее 0.3 силы,
    /// только когда темп известен, сетка уже набрала уверенность от `weightLow` и ворот открыт. Без
    /// темпа, без уверенности (темп от одних бочек, как у ложных онсетов розового шума) или при
    /// закрытом вороте прежнее подтверждение 7...11, и такой онсет не светится. Уверенная сетка здесь
    /// попадает через долю: уверенность около 0.43-0.57, а вес 0 (`weightHits`), поэтому бочка не
    /// приглушена весом.
    @Test(arguments: ["confident", "noConfidence", "noTempo", "gateClosed"])
    func kickConfirmationFloorOnlyWithTempo(scenario: String) throws {
        #expect(BeatTracker.Parameters().kickConfirmFloor == 0)
        var parameters = BeatTracker.Parameters()
        parameters.kickConfirmFloor = 0.3
        // Ниже, чтобы после короткой тишины (ворот закрыт) уверенность еще проходила.
        parameters.weightLow = 0.1
        var tracker = BeatTracker(framesPerSecond: Self.fps, parameters: parameters)
        let hop = 256.0 / 48_000
        var time = 0.0
        var next = 0.25
        var beat = 0
        while time < 8 {
            time += hop
            var result: HopResult
            if scenario == "noTempo" {
                // Уровень как на долях, широкополосная функция 0: темпа нет, медиана 0.
                result = SyntheticBeats.hop(endTime: time, broadband: nil, kick: nil)
                result.kickLevelDB = -6
            } else {
                var kick: OnsetEvent?
                var onset: OnsetEvent?
                if next <= time {
                    kick = OnsetEvent(time: next, strength: 1)
                    if scenario != "noConfidence", beat % 2 == 0 { onset = kick }
                    beat += 1
                    next += 0.5
                }
                result = SyntheticBeats.hop(endTime: time, broadband: onset, kick: kick)
            }
            tracker.process(result)
        }
        #expect((tracker.period != nil) == (scenario != "noTempo"))
        #expect((tracker.confidence >= parameters.weightLow) == (scenario == "confident" || scenario == "gateClosed"))
        #expect(tracker.displayWeight == 0 && !tracker.locked)
        // До середины между долями: последняя бочка была на доле, следующий онсет на «и».
        let quiet = scenario == "gateClosed"
        let until = scenario == "noTempo" ? time + 0.25 : next - 0.25 + (quiet ? 1.0 : 0)
        while time < until {
            time += hop
            var result = SyntheticBeats.hop(endTime: time, broadband: nil, kick: nil)
            if !quiet { result.kickLevelDB = -6 }
            tracker.process(result)
        }
        // Медиана широкополосной функции за 1.5 с 0, знаменатель 0.5: значение 3 дает отношение 6.
        time += hop
        let onset = OnsetEvent(time: time, strength: 1)
        var result = SyntheticBeats.hop(endTime: time, broadband: nil, kick: onset)
        result.broadbandODF = 3
        if quiet { result.kickLevelDB = -40 }
        tracker.process(result)
        #expect((tracker.energyGate >= 0.5) == !quiet, "gate \(tracker.energyGate)")
        let glow = tracker.schedule.events.first { !$0.predicted && $0.time == onset.time }
        if scenario == "confident" {
            #expect((glow?.amplitude ?? 0) >= 0.3 - 1e-6, "\(String(describing: glow))")
        } else {
            #expect(glow == nil, "\(scenario): \(String(describing: glow))")
        }
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

/// Чей темп помнит трекер (`TrackTempoMemory`): пауза в том же треке сохраняет темп, без трека и
/// после смены трека нет. Смена известного трека на другой известный сбрасывает трекер всегда (сетка
/// прежнего трека новому не нужна), пропажа или появление трека только пока трекер идет по памяти.
struct TrackTempoMemoryTests {
    private let first = TrackKey(title: "Первый", artist: "Исполнитель", source: "ru.yandex.desktop.music")
    private let second = TrackKey(title: "Второй", artist: "Исполнитель", source: "ru.yandex.desktop.music")

    @Test func keepsTempoOnlyForTheSameKnownTrack() {
        var memory = TrackTempoMemory()
        #expect(!memory.keepsTempo(current: nil))
        #expect(!memory.keepsTempo(current: first))
        let dropOnStart = memory.feeding(current: first, resuming: false)
        #expect(!dropOnStart && memory.track == first)
        #expect(memory.keepsTempo(current: first))
        #expect(!memory.keepsTempo(current: second))
        #expect(!memory.keepsTempo(current: nil))
        // Трек пропал посреди звука без памяти: сброса нет, метка остается, сохранять темп без трека
        // нельзя.
        let dropWithoutTrack = memory.feeding(current: nil, resuming: false)
        #expect(!dropWithoutTrack && memory.track == first)
        #expect(!memory.keepsTempo(current: nil))
        let backToFirst = memory.feeding(current: first, resuming: false)
        #expect(!backToFirst && memory.keepsTempo(current: first))
    }

    @Test(arguments: [false, true])
    func knownTrackChangeAlwaysDropsTheMemory(resuming: Bool) {
        var memory = TrackTempoMemory()
        _ = memory.feeding(current: first, resuming: false)
        let sameTrack = memory.feeding(current: first, resuming: resuming)
        #expect(!sameTrack)
        let nextTrack = memory.feeding(current: second, resuming: resuming)
        #expect(nextTrack && memory.track == second)
        #expect(memory.keepsTempo(current: second) && !memory.keepsTempo(current: first))
    }

    /// Пропажа трека и трек после нее: сброс, только пока трекер идет по памяти; без памяти трек после
    /// пропажи сравнивается с прежней меткой.
    @Test func trackGapDropsOnlyWhileResumingOrOnANewTrack() {
        var memory = TrackTempoMemory()
        _ = memory.feeding(current: first, resuming: false)
        let lostWhileResuming = memory.feeding(current: nil, resuming: true)
        #expect(lostWhileResuming && memory.track == nil)
        let afterReset = memory.feeding(current: second, resuming: false)
        #expect(!afterReset && memory.track == second)
        let lostMidSound = memory.feeding(current: nil, resuming: false)
        #expect(!lostMidSound && memory.track == second)
        let newAfterGap = memory.feeding(current: first, resuming: false)
        #expect(newAfterGap && memory.track == first)
        var fresh = TrackTempoMemory()
        let appeared = fresh.feeding(current: first, resuming: true)
        #expect(appeared && fresh.track == first)
    }

    /// Ключ трека только у источника-приложения: у всего звука системы Now Playing может описывать
    /// плеер на паузе, пока играет другой звук.
    @Test func keyOnlyForApplicationSources() {
        let yandex = AudioSource.application(bundleID: "ru.yandex.desktop.music", bundlePath: "/Applications/Яндекс Музыка.app", displayName: "Яндекс Музыка")
        #expect(TrackTempoMemory.key(first, source: yandex) == first)
        #expect(TrackTempoMemory.key(nil, source: yandex) == nil)
        #expect(TrackTempoMemory.key(first, source: .systemWide) == nil)
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
    /// Онсет и функция бочки только на каждой `kickEvery`-й доле (с первой), широкополосный онсет на
    /// каждой.
    var kickEvery = 1
    /// Широкополосная функция на долях по кругу (доля k берет `beatODF[k % count]`).
    var beatODF: [Float] = [50]
    /// Уровень бочки громкий только на шагах с онсетом бочки (иначе на любой доле).
    var quietBetweenKicks = false
    private var beatIndex = 0

    init(bpm: Double) {
        self.bpm = bpm
    }

    mutating func feed(_ tracker: inout BeatTracker, until end: Double, each: (BeatTracker) -> Void = { _ in }) {
        while endTime + hop <= end {
            endTime += hop
            var onset: OnsetEvent?
            var kick: OnsetEvent?
            var odf: Float = 50
            if nextBeatTime <= endTime {
                onset = OnsetEvent(time: nextBeatTime, strength: 1)
                if beatIndex % max(kickEvery, 1) == 0 { kick = onset }
                if !beatODF.isEmpty { odf = beatODF[beatIndex % beatODF.count] }
                beatIndex += 1
                nextBeatTime += 60 / bpm
            }
            var hop = Self.hop(endTime: endTime, broadband: onset, kick: kick)
            if onset != nil { hop.broadbandODF = odf }
            if quietBetweenKicks, kick == nil { hop.kickLevelDB = -40 }
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
