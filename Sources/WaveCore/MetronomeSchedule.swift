import Foundation

/// Метроном калибровки «Сдвига синхронизации»: 100 BPM, акцент на первой доле из четырех.
///
/// Щелчок `index` звучит из устройства в момент `clickTime(index)` на часах хоста (секунды, тот же
/// отсчет, что у `CACurrentMediaTime()`) плюс задержка вывода, как захваченный звук с той же
/// меткой. Поэтому расписание свечения (`beatSchedule`) ставит событие на
/// `clickTime + outputLatency + offset`, ровно как анализ ставит доли музыки, и вспышка дальше
/// идет по правилам `BeatGlow`: что пользователь подгоняет здесь, то и увидит на острове.
///
/// Щелчки ставятся в очередь плеера скользящим окном (`clicksToQueue`): все, что начинается
/// раньше `now + horizon`, при 100 BPM это 2-3 щелчка впереди. Id события равен номеру щелчка,
/// поэтому сдвиг ползунком двигает ту же вспышку, а не начинает новую.
public struct MetronomeSchedule: Sendable, Equatable {
    public static let bpm = 100.0
    public static let beatsPerBar = 4
    /// Первый щелчок через столько секунд после запуска.
    public static let startDelay = 0.5
    /// В очереди плеера щелчки, которые начинаются раньше `now + horizon`.
    public static let horizon = 1.5
    /// Щелчок, до которого меньше этого, уже не ставится (таймер стоял): он бы прозвучал не вовремя.
    public static let minimumLead = 0.05
    /// Прошлых событий в расписании свечения, кроме последнего начавшегося, и будущих.
    static let pastEvents = 1
    static let futureEvents = 2

    /// Время первого щелчка, секунды хоста.
    public let start: Double
    /// Период доли, с.
    public let period: Double

    public init(start: Double) {
        self.start = start
        period = 60 / Self.bpm
    }

    /// Время щелчка `index` на часах хоста.
    public func clickTime(_ index: Int) -> Double {
        start + Double(index) * period
    }

    /// Акцент на первой доле такта.
    public static func isAccent(_ index: Int) -> Bool {
        index % beatsPerBar == 0
    }

    /// Номер первого щелчка не раньше `time`; щелчок ровно в `time` считается. Не меньше 0.
    public func firstIndex(notBefore time: Double) -> Int {
        let beats = (time - start) / period
        guard beats.isFinite else { return beats > 0 ? Int(Int32.max) : 0 }
        let index = (beats - Self.indexTolerance).rounded(.up)
        return Int(min(max(index, 0), Double(Int32.max)))
    }

    /// Номер последнего щелчка не позже `time`; -1, если еще ни одного.
    func lastIndex(notAfter time: Double) -> Int {
        let beats = (time - start) / period
        guard beats.isFinite else { return beats > 0 ? Int(Int32.max) : -1 }
        let index = (beats + Self.indexTolerance).rounded(.down)
        return Int(min(max(index, -1), Double(Int32.max)))
    }

    /// Какие щелчки поставить в очередь сейчас: с `next` (первый еще не поставленный) до первого
    /// за горизонтом `now + horizon`. Щелчки, до которых меньше `minimumLead`, пропускаются.
    public func clicksToQueue(from next: Int, now: Double) -> Range<Int> {
        let lower = max(next, firstIndex(notBefore: now + Self.minimumLead))
        let upper = firstIndex(notBefore: now + Self.horizon)
        return lower..<max(lower, upper)
    }

    /// Расписание свечения на кадр, показанный в момент `time`: последний начавшийся щелчок, один
    /// до него и два следующих, на слышимой оси `clickTime + outputLatency + offsetMs / 1000`.
    /// Сдвиг ограничен, как у ползунка (`SyncOffsets.clamp`). Захват есть, уверенность 1.
    public func beatSchedule(at time: Double, outputLatency: Double, offsetMs: Int) -> BeatSchedule {
        let shift = outputLatency + Double(SyncOffsets.clamp(offsetMs)) / 1000
        let current = lastIndex(notAfter: time - shift)
        let first = max(current - Self.pastEvents, 0)
        let last = max(current + Self.futureEvents, first)
        let events = (first...last).map { index in
            GlowEvent(id: UInt64(index), time: clickTime(index) + shift, amplitude: 1, predicted: true)
        }
        return BeatSchedule(events: events, bpm: Self.bpm, period: period, confidence: 1, locked: true)
    }

    /// Допуск округления номера щелчка.
    private static let indexTolerance = 1e-9
}
