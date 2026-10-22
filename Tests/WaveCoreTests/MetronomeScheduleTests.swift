import Testing
import Foundation
@testable import WaveCore

struct MetronomeScheduleTests {
    private let start = 1000.0
    private let tolerance = 1e-9

    // MARK: - Щелчки

    @Test func clicksAreSixHundredthsApartAtOneHundredBPM() {
        let metronome = MetronomeSchedule(start: start)
        #expect(MetronomeSchedule.bpm == 100)
        #expect(abs(metronome.period - 0.6) < tolerance)
        #expect(abs(metronome.clickTime(0) - start) < tolerance)
        #expect(abs(metronome.clickTime(1) - (start + 0.6)) < tolerance)
        #expect(abs(metronome.clickTime(10) - (start + 6)) < tolerance)
    }

    @Test func everyFourthClickIsAccented() {
        let accents = (0..<9).map(MetronomeSchedule.isAccent)
        #expect(accents == [true, false, false, false, true, false, false, false, true])
    }

    @Test func firstQueueHoldsClicksWithinTheHorizon() {
        // Метроном запускается за `startDelay` до первого щелчка.
        let metronome = MetronomeSchedule(start: start)
        let now = start - MetronomeSchedule.startDelay
        // Горизонт 1.5 с: щелчки на 0 и 0.6 с после старта, 1.2 с уже за ним.
        #expect(metronome.clicksToQueue(from: 0, now: now) == 0..<2)
    }

    @Test func rollingQueueAddsOnlyNewClicks() {
        let metronome = MetronomeSchedule(start: start)
        #expect(metronome.clicksToQueue(from: 2, now: start + 0.1) == 2..<3)
        // Следующий щелчок еще за горизонтом: ставить нечего.
        #expect(metronome.clicksToQueue(from: 3, now: start + 0.1).isEmpty)
    }

    @Test func queueKeepsTwoToFourClicksAhead() {
        let metronome = MetronomeSchedule(start: start)
        var next = 0
        var now = start - MetronomeSchedule.startDelay
        while now < start + 20 {
            next = metronome.clicksToQueue(from: next, now: now).upperBound
            let queued = next - metronome.firstIndex(notBefore: now)
            #expect((2...4).contains(queued))
            now += 0.1
        }
    }

    @Test func stalledQueueSkipsClicksThatAreTooLate() {
        // Таймер стоял 5 с: щелчки, до которых меньше `minimumLead`, не ставятся.
        let metronome = MetronomeSchedule(start: start)
        let now = start + 5
        let due = metronome.clicksToQueue(from: 1, now: now)
        #expect(due == 9..<11)
        #expect(metronome.clickTime(due.lowerBound) >= now + MetronomeSchedule.minimumLead)
    }

    @Test func firstIndexCountsAClickExactlyAtTheTime() {
        let metronome = MetronomeSchedule(start: start)
        #expect(metronome.firstIndex(notBefore: metronome.clickTime(7)) == 7)
        #expect(metronome.firstIndex(notBefore: metronome.clickTime(7) + 0.001) == 8)
        #expect(metronome.firstIndex(notBefore: start - 10) == 0)
        #expect(metronome.firstIndex(notBefore: -.infinity) == 0)
        #expect(metronome.firstIndex(notBefore: .nan) == 0)
    }

    @Test func lastIndexCountsAClickExactlyAtTheTime() {
        let metronome = MetronomeSchedule(start: start)
        #expect(metronome.lastIndex(notAfter: metronome.clickTime(7)) == 7)
        #expect(metronome.lastIndex(notAfter: metronome.clickTime(7) - 0.001) == 6)
        #expect(metronome.lastIndex(notAfter: start - 0.001) == -1)
        #expect(metronome.lastIndex(notAfter: .nan) == -1)
    }

    // MARK: - Расписание свечения

    @Test func scheduleIsLockedWithFullConfidence() {
        let schedule = MetronomeSchedule(start: start).beatSchedule(at: start + 3, outputLatency: 0.02, offsetMs: 0)
        #expect(schedule.locked)
        #expect(schedule.confidence == 1)
        #expect(schedule.bpm == 100)
        #expect(abs((schedule.period ?? 0) - 0.6) < tolerance)
        #expect(!schedule.events.isEmpty)
        #expect(schedule.events.allSatisfy { $0.predicted && $0.amplitude == 1 })
    }

    @Test func eventsAreClicksPlusOutputLatencyAndOffset() {
        let metronome = MetronomeSchedule(start: start)
        let schedule = metronome.beatSchedule(at: start + 3, outputLatency: 0.025, offsetMs: -40)
        for event in schedule.events {
            let click = metronome.clickTime(Int(event.id))
            #expect(abs(event.time - (click + 0.025 - 0.040)) < tolerance)
        }
    }

    @Test func eventsSurroundTheFrameTime() {
        let metronome = MetronomeSchedule(start: start)
        let latency = 0.03
        let now = metronome.clickTime(5) + latency + 0.2
        let schedule = metronome.beatSchedule(at: now, outputLatency: latency, offsetMs: 0)
        #expect(schedule.events.map(\.id) == [4, 5, 6, 7])
        #expect(schedule.events.map(\.time) == schedule.events.map(\.time).sorted())
        #expect(schedule.events.contains { $0.time <= now })
        #expect(schedule.events.contains { $0.time > now })
    }

    @Test func noEventsBeforeTheFirstClick() {
        let metronome = MetronomeSchedule(start: start)
        let schedule = metronome.beatSchedule(at: start - 0.5, outputLatency: 0.02, offsetMs: 0)
        #expect(schedule.events.map(\.id) == [0, 1])
    }

    @Test func offsetMovesEventsButKeepsTheirIDs() {
        // Ползунок двигает ту же долю: id прежний, поэтому `BeatGlow` не вспыхивает второй раз.
        let metronome = MetronomeSchedule(start: start)
        let now = metronome.clickTime(5) + 0.3
        let before = metronome.beatSchedule(at: now, outputLatency: 0.02, offsetMs: 0)
        let after = metronome.beatSchedule(at: now, outputLatency: 0.02, offsetMs: 50)
        #expect(before.events.map(\.id) == after.events.map(\.id))
        for (old, new) in zip(before.events, after.events) {
            #expect(abs(new.time - old.time - 0.05) < tolerance)
        }
    }

    @Test func offsetIsClampedLikeTheSlider() {
        let metronome = MetronomeSchedule(start: start)
        let now = metronome.clickTime(5)
        let wild = metronome.beatSchedule(at: now, outputLatency: 0, offsetMs: 900)
        let limit = metronome.beatSchedule(at: now, outputLatency: 0, offsetMs: SyncOffsets.range.upperBound)
        #expect(wild == limit)
    }

    @Test func flashStartsOneLeadBeforeTheAudibleClick() {
        // Вспышка по правилам острова: за `BeatGlow.lead` до слышимого щелчка, не раньше. До нее
        // светится только хвост прошлой доли.
        let metronome = MetronomeSchedule(start: start)
        let latency = 0.02
        let audible = metronome.clickTime(5) + latency + 0.010
        let schedule = metronome.beatSchedule(at: audible, outputLatency: latency, offsetMs: 10)
        let onset = audible - BeatGlow.lead
        #expect(BeatGlow.value(at: onset - 0.01, schedule: schedule, refreshPeriod: 0) < 0.1)
        #expect(BeatGlow.value(at: onset + 0.001, schedule: schedule, refreshPeriod: 0) > 0.9)
    }
}
