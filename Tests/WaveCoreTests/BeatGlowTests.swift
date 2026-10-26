import Foundation
import Testing
@testable import WaveCore

struct BeatGlowTests {
    private static let refresh = 1.0 / 60

    private static func schedule(_ events: [GlowEvent], period: Double? = 0.5) -> BeatSchedule {
        BeatSchedule(events: events, bpm: period.map { 60 / $0 }, period: period, confidence: 1, locked: true)
    }

    private static func event(id: UInt64, time: Double, amplitude: Float = 1) -> GlowEvent {
        GlowEvent(id: id, time: time, amplitude: amplitude, predicted: true)
    }

    @Test func decayFollowsTempo() {
        #expect(abs(BeatGlow.decay(period: 0.5) - 0.15) < 1e-12)
        #expect(BeatGlow.decay(period: 0.2) == 0.08)
        #expect(BeatGlow.decay(period: 1.0) == 0.18)
        #expect(BeatGlow.decay(period: nil) == 0.12)
    }

    @Test func peaksAtLeadTime() {
        let schedule = Self.schedule([Self.event(id: 1, time: 10)])
        let peak = BeatGlow.value(at: 10.0 - 0.015 - Self.refresh / 2, schedule: schedule, refreshPeriod: Self.refresh)
        #expect(abs(peak - 1) <= 1e-6)
        #expect(BeatGlow.value(at: 9.97, schedule: schedule, refreshPeriod: Self.refresh) == 0)
        // Через одну постоянную спада яркость падает в e раз.
        let later = BeatGlow.value(
            at: 10.0 - 0.015 - Self.refresh / 2 + 0.15, schedule: schedule, refreshPeriod: Self.refresh
        )
        #expect(abs(later - Float(exp(-1.0))) < 1e-4)
        // Изменяемый вариант для события, увиденного заранее, дает ту же форму.
        var glow = BeatGlow()
        #expect(glow.value(at: 9.9, schedule: schedule, refreshPeriod: Self.refresh) == 0)
        let mutatingPeak = glow.value(
            at: 10.0 - 0.015 - Self.refresh / 2, schedule: schedule, refreshPeriod: Self.refresh
        )
        #expect(abs(mutatingPeak - 1) <= 1e-6)
    }

    /// Онсет бочки без захвата светится вполовину, с захватом полностью; доля светится полностью
    /// всегда. Онсет, впервые видный без захвата, остается приглушенным и после захвата.
    @Test func reactiveOnsetGlowsAtHalfUntilLocked() {
        #expect(BeatGlow.reactiveScale == 0.5)
        let onset = GlowEvent(id: BeatTracker.onsetIDFlag | 3, time: 10, amplitude: 0.9, predicted: false)
        let beat = Self.event(id: 4, time: 20, amplitude: 0.9)
        let peakTime = 10.0 - BeatGlow.lead - Self.refresh / 2
        func schedule(_ events: [GlowEvent], locked: Bool) -> BeatSchedule {
            BeatSchedule(events: events, bpm: 120, period: 0.5, confidence: locked ? 1 : 0, locked: locked)
        }
        let unlocked = BeatGlow.value(at: peakTime, schedule: schedule([onset], locked: false), refreshPeriod: Self.refresh)
        let locked = BeatGlow.value(at: peakTime, schedule: schedule([onset], locked: true), refreshPeriod: Self.refresh)
        #expect(abs(unlocked - 0.45) < 1e-6)
        #expect(abs(locked - 0.9) < 1e-6)
        let beatPeak = BeatGlow.value(at: peakTime + 10, schedule: schedule([beat], locked: false), refreshPeriod: Self.refresh)
        #expect(abs(beatPeak - 0.9) < 1e-6)

        var glow = BeatGlow()
        #expect(glow.value(at: peakTime - 0.1, schedule: schedule([onset], locked: false), refreshPeriod: Self.refresh) == 0)
        let peak = glow.value(at: peakTime, schedule: schedule([onset], locked: true), refreshPeriod: Self.refresh)
        #expect(abs(peak - 0.45) < 1e-6)
        var fresh = BeatGlow()
        let lockedPeak = fresh.value(at: peakTime, schedule: schedule([onset], locked: true), refreshPeriod: Self.refresh)
        #expect(abs(lockedPeak - 0.9) < 1e-6)
    }

    /// Приглушение онсета бочки идет по весу показа, а не по захвату: `reactiveScale + (1 − reactiveScale)
    /// × weight`. Захват без веса (вес 0) приглушает, вес без захвата нет. Изменяемый вариант берет вес
    /// первого кадра, на котором онсет виден, и дальше его не меняет.
    @Test func reactiveScaleFollowsWeight() {
        let onset = GlowEvent(id: BeatTracker.onsetIDFlag | 5, time: 10, amplitude: 0.8, predicted: false)
        let peakTime = 10.0 - BeatGlow.lead - Self.refresh / 2
        func schedule(locked: Bool, weight: Float) -> BeatSchedule {
            BeatSchedule(events: [onset], bpm: 120, period: 0.5, confidence: 0.5, locked: locked, weight: weight)
        }
        let half = BeatGlow.value(at: peakTime, schedule: schedule(locked: false, weight: 0.5), refreshPeriod: Self.refresh)
        #expect(abs(half - 0.6) < 1e-6)
        let lockedNoWeight = BeatGlow.value(at: peakTime, schedule: schedule(locked: true, weight: 0), refreshPeriod: Self.refresh)
        #expect(abs(lockedNoWeight - 0.4) < 1e-6)
        let full = BeatGlow.value(at: peakTime, schedule: schedule(locked: false, weight: 1), refreshPeriod: Self.refresh)
        #expect(abs(full - 0.8) < 1e-6)

        var glow = BeatGlow()
        #expect(glow.value(at: peakTime - 0.1, schedule: schedule(locked: false, weight: 0.2), refreshPeriod: Self.refresh) == 0)
        let peak = glow.value(at: peakTime, schedule: schedule(locked: true, weight: 1), refreshPeriod: Self.refresh)
        #expect(abs(peak - 0.8 * 0.6) < 1e-6)
    }

    /// Без явного веса расписание берет его из захвата (1 с захватом, 0 без), чтобы старые места
    /// создания расписания показывали как раньше; `shifted` вес не трогает.
    @Test func weightDefaultsFromLock() {
        #expect(BeatSchedule(events: [], bpm: nil, period: nil, confidence: 1, locked: true).weight == 1)
        #expect(BeatSchedule(events: [], bpm: nil, period: nil, confidence: 1, locked: false).weight == 0)
        #expect(BeatSchedule.empty.weight == 0)
        let weighted = BeatSchedule(events: [], bpm: 120, period: 0.5, confidence: 0.4, locked: false, weight: 0.3)
        #expect(weighted.weight == 0.3)
        #expect(weighted.shifted(by: 0.02).weight == 0.3)
    }

    @Test func lateEventStartsBright() {
        let event = Self.event(id: 7, time: 10, amplitude: 0.8)
        let schedule = Self.schedule([event])
        // Начало по расписанию 10 - λ - R/2; первый кадр, где событие видно, на 30 мс позже.
        let firstSeen = 10 - BeatGlow.lead - Self.refresh / 2 + 0.030
        var glow = BeatGlow()
        #expect(glow.value(at: firstSeen - 0.1, schedule: .empty, refreshPeriod: Self.refresh) == 0)
        let value = glow.value(at: firstSeen, schedule: schedule, refreshPeriod: Self.refresh)
        #expect(abs(value - 0.8) <= 1e-6)
        // Дальше спадает от этого кадра, а не от начала по расписанию.
        let next = glow.value(at: firstSeen + Self.refresh, schedule: schedule, refreshPeriod: Self.refresh)
        #expect(abs(next - 0.8 * Float(exp(-Self.refresh / 0.15))) < 1e-4)
        // Статический вариант памяти не имеет и показывает уже спавшую вспышку.
        #expect(BeatGlow.value(at: firstSeen, schedule: schedule, refreshPeriod: Self.refresh) < 0.8 * 0.85)
    }

    /// Событие, впервые увиденное позже `lateLimit` после своего начала (например, первое расписание
    /// после появления рендера), не светится вовсе: это не опоздание, а прошлое.
    @Test(arguments: [0.25, 1.0])
    func staleEventStaysDark(age: Double) {
        let schedule = Self.schedule([Self.event(id: 3, time: 10)])
        let start = 10 - BeatGlow.lead - Self.refresh / 2
        var glow = BeatGlow()
        #expect(glow.value(at: start + age, schedule: schedule, refreshPeriod: Self.refresh) == 0)
        #expect(glow.value(at: start + age + Self.refresh, schedule: schedule, refreshPeriod: Self.refresh) == 0)
        // Опоздание внутри предела по-прежнему вспыхивает.
        var fresh = BeatGlow()
        let late = fresh.value(at: start + BeatGlow.lateLimit - 0.01, schedule: schedule, refreshPeriod: Self.refresh)
        #expect(abs(late - 1) < 1e-6)
    }

    @Test func ignoresNonFiniteInput() {
        let schedule = Self.schedule([
            GlowEvent(id: 1, time: 10, amplitude: .nan, predicted: true),
            GlowEvent(id: 2, time: .nan, amplitude: 1, predicted: true),
            GlowEvent(id: 3, time: 10, amplitude: .infinity, predicted: true),
            GlowEvent(id: 4, time: 10, amplitude: 0.5, predicted: true),
        ])
        let peak = 10 - BeatGlow.lead - Self.refresh / 2
        var glow = BeatGlow()
        #expect(BeatGlow.value(at: peak, schedule: schedule, refreshPeriod: Self.refresh) == 0.5)
        #expect(glow.value(at: peak, schedule: schedule, refreshPeriod: Self.refresh) == 0.5)
        #expect(BeatGlow.value(at: .nan, schedule: schedule, refreshPeriod: Self.refresh) == 0)
        #expect(glow.value(at: .infinity, schedule: schedule, refreshPeriod: Self.refresh) == 0)
        #expect(glow.value(at: peak + 0.001, schedule: schedule, refreshPeriod: Self.refresh) > 0.49)
    }

    /// Кадры через 1 мс: сдвиг приходит, когда вспышка горит меньше 3 мс, и без памяти она погасла
    /// бы и вспыхнула снова.
    @Test func sameIdDoesNotFlashTwice() {
        var glow = BeatGlow()
        var schedule = Self.schedule([Self.event(id: 5, time: 10)])
        var values: [Float] = []
        var stateless: [Float] = []
        var t = 9.95
        var moved = false
        while t < 10.2 {
            // Пока событие светится, оно сдвигается на 3 мс позже с тем же id.
            if !moved, let last = values.last, last > 0.5 {
                schedule.events[0].time += 0.003
                moved = true
            }
            values.append(glow.value(at: t, schedule: schedule, refreshPeriod: Self.refresh))
            stateless.append(BeatGlow.value(at: t, schedule: schedule, refreshPeriod: Self.refresh))
            t += 0.001
        }
        #expect(moved)
        let peak = values.firstIndex { $0 > 0.5 } ?? values.count
        #expect(peak < values.count)
        for index in (peak + 1)..<values.count {
            #expect(values[index] <= values[index - 1], "rise at frame \(index): \(values[index - 1]) -> \(values[index])")
        }
        // Проверка чувствительна: без памяти та же последовательность дает вторую вспышку.
        #expect(stateless[(peak + 1)...].contains(0))
    }

    @Test func neverExceedsOne() {
        let schedule = Self.schedule([Self.event(id: 1, time: 10), Self.event(id: 2, time: 10.004)])
        var glow = BeatGlow()
        var t = 9.95
        while t < 10.3 {
            #expect(BeatGlow.value(at: t, schedule: schedule, refreshPeriod: Self.refresh) <= 1)
            #expect(glow.value(at: t, schedule: schedule, refreshPeriod: Self.refresh) <= 1)
            t += 0.001
        }
    }

    @Test func bassAccentClamps() {
        #expect(BeatGlow.accented([0.9, 0.2, 0.1], glow: 1) == [1, 0.2, 0.1])
        #expect(BeatGlow.accented([0.9, 0.2, 0.1], glow: 0.5) == [min(0.9 + 0.075, 1), 0.2, 0.1])
        #expect(BeatGlow.accented([0.3, 0.2, 0.1], glow: 0) == [0.3, 0.2, 0.1])
        #expect(BeatGlow.accented([], glow: 1) == [])
    }

    @Test func shiftKeepsIds() {
        let schedule = Self.schedule([
            GlowEvent(id: 1 | (1 << 63), time: 9.5, amplitude: 0.6, predicted: false),
            Self.event(id: 2, time: 10),
            Self.event(id: 3, time: 10.5),
        ])
        let shifted = schedule.shifted(by: 0.02)
        #expect(shifted.events.map(\.id) == schedule.events.map(\.id))
        #expect(zip(shifted.events, schedule.events).allSatisfy { abs($0.time - ($1.time + 0.02)) < 1e-12 })
        #expect(shifted.events.map(\.amplitude) == schedule.events.map(\.amplitude))
        #expect(shifted.bpm == schedule.bpm && shifted.period == schedule.period)
        #expect(shifted.confidence == schedule.confidence && shifted.locked == schedule.locked)
        #expect(BeatSchedule.empty.events.isEmpty && BeatSchedule.empty.period == nil && !BeatSchedule.empty.locked)
    }

    @Test func forgetsOldIds() {
        var glow = BeatGlow()
        let schedule = Self.schedule([Self.event(id: 9, time: 10)])
        _ = glow.value(at: 10, schedule: schedule, refreshPeriod: Self.refresh)
        #expect(glow.rememberedIDs == 1)
        _ = glow.value(at: 12.5, schedule: .empty, refreshPeriod: Self.refresh)
        #expect(glow.rememberedIDs == 0)
    }
}
