import Testing
@testable import WaveCore

struct AdapterSilenceMonitorTests {
    /// Подает одинаковые входы каждые 100 мс от `start` до `end` включительно; возвращает момент
    /// первого срабатывания.
    private static func run(
        _ monitor: inout AdapterSilenceMonitor,
        audible: Bool,
        trackSeen: Bool = false,
        adapterAvailable: Bool = true,
        from start: Double,
        to end: Double
    ) -> Double? {
        let steps = Int(((end - start) / 0.1).rounded())
        var firedAt: Double?
        for i in 0...steps {
            let now = start + Double(i) * 0.1
            let fired = monitor.update(
                sourceAudible: audible, trackSeen: trackSeen, adapterAvailable: adapterAvailable, now: now
            )
            if fired, firedAt == nil { firedAt = now }
        }
        return firedAt
    }

    /// Источник звучит две минуты, а Now Playing ни разу не прислал его трек: адаптер молчит.
    /// Срабатывает один раз.
    @Test func twoMinutesOfSoundWithoutTrackMarksAdapterSilent() throws {
        var monitor = AdapterSilenceMonitor()
        let firedAt = try #require(Self.run(&monitor, audible: true, from: 0, to: 200))
        #expect(abs(firedAt - AdapterSilenceMonitor.defaultLimit) < 0.15)
        let again = Self.run(&monitor, audible: true, from: 200.1, to: 400)
        #expect(again == nil)
    }

    /// Считается только время, когда источник звучит: паузы между треками не обнуляют счет.
    @Test func onlyAudibleTimeCounts() throws {
        var monitor = AdapterSilenceMonitor()
        let early = Self.run(&monitor, audible: true, from: 0, to: 60)
        #expect(early == nil)
        let quiet = Self.run(&monitor, audible: false, from: 60.1, to: 300)
        #expect(quiet == nil)
        let firedAt = try #require(Self.run(&monitor, audible: true, from: 300.1, to: 500))
        #expect(abs(firedAt - 360.1) < 0.25)
    }

    @Test func trackForSourceKeepsAdapterWorking() {
        var monitor = AdapterSilenceMonitor()
        let firedAt = Self.run(&monitor, audible: true, trackSeen: true, from: 0, to: 600)
        #expect(firedAt == nil)
    }

    /// Пока адаптер не работает или проверяется, счет стоит.
    @Test func unavailableAdapterIsNotCounted() {
        var monitor = AdapterSilenceMonitor()
        let firedAt = Self.run(&monitor, audible: true, adapterAvailable: false, from: 0, to: 600)
        #expect(firedAt == nil)
        #expect(monitor.audibleTime == 0)
    }

    /// Долгий промежуток между вызовами (сон) засчитывается не больше чем на `maxStep`.
    @Test func longGapCountsAsOneStep() {
        var monitor = AdapterSilenceMonitor()
        _ = monitor.update(sourceAudible: true, trackSeen: false, adapterAvailable: true, now: 0)
        let fired = monitor.update(sourceAudible: true, trackSeen: false, adapterAvailable: true, now: 1000)
        #expect(!fired)
        #expect(monitor.audibleTime == AdapterSilenceMonitor.maxStep)
    }

    /// Смена источника или пробуждение: счет заново, снова может сработать.
    @Test func resetStartsOver() {
        var monitor = AdapterSilenceMonitor()
        let first = Self.run(&monitor, audible: true, from: 0, to: 200)
        #expect(first != nil)
        monitor.reset()
        #expect(monitor.audibleTime == 0)
        let early = Self.run(&monitor, audible: true, from: 1000, to: 1100)
        #expect(early == nil)
        let second = Self.run(&monitor, audible: true, from: 1100.1, to: 1200)
        #expect(second != nil)
    }
}
