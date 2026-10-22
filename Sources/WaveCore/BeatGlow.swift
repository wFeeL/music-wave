import Foundation

/// Одна вспышка свечения: предсказанная доля или онсет бочки.
///
/// Правило id (соблюдает трекер): предсказанная доля сохраняет id при подстройке ФАПЧ и при
/// `BeatSchedule.shifted(by:)`; скачок фазы или смена темпа начинают новые id; онсеты берут id из
/// отдельного счетчика с установленным старшим битом. Один id не должен означать другое событие
/// раньше чем через `BeatGlow.memory` секунд, иначе изменяемый `BeatGlow` примет его за старое.
public struct GlowEvent: Sendable, Equatable {
    public var id: UInt64
    /// Слышимое время события в секундах той же оси, что и время рендера.
    public var time: Double
    /// Яркость вспышки 0...1.
    public var amplitude: Float
    public var predicted: Bool

    public init(id: UInt64, time: Double, amplitude: Float, predicted: Bool) {
        self.id = id
        self.time = time
        self.amplitude = amplitude
        self.predicted = predicted
    }
}

/// Расписание свечения, которое анализ публикует для рендера.
public struct BeatSchedule: Sendable, Equatable {
    /// До 8 последних событий и 2 следующих предсказанных, по времени.
    public var events: [GlowEvent]
    public var bpm: Double?
    /// Период доли в секундах.
    public var period: Double?
    public var confidence: Double
    public var locked: Bool

    public static let empty = BeatSchedule(events: [], bpm: nil, period: nil, confidence: 0, locked: false)

    public init(events: [GlowEvent], bpm: Double?, period: Double?, confidence: Double, locked: Bool) {
        self.events = events
        self.bpm = bpm
        self.period = period
        self.confidence = confidence
        self.locked = locked
    }

    /// То же расписание на другой оси времени (поток в хост, задержка вывода, сдвиг синхронизации):
    /// меняются только времена событий, id остаются.
    public func shifted(by offset: Double) -> BeatSchedule {
        var copy = self
        for index in copy.events.indices {
            copy.events[index].time += offset
        }
        return copy
    }
}

/// Форма свечения (`beat-sync.md` 2.7-2.8): мгновенная атака за λ до звука и экспоненциальный спад.
///
/// `shape(a) = a < 0 ? 0 : exp(-a / decay)` при `a = t - (event.time - lead) + R / 2`, где `t` это
/// время показа кадра, а `R` период обновления экрана (`+R/2` центрирует ошибку квантования кадрами).
/// Свечение равно максимуму `amplitude × shape` по событиям и не бывает больше 1. Онсет бочки
/// (`predicted == false`) в расписании без захвата светится с `amplitude × reactiveScale`; изменяемый
/// вариант решает это один раз, когда событие впервые видно, чтобы захват не зажигал его заново.
///
/// Изменяемый вариант помнит события по id. Событие, которое впервые видно уже после своего начала
/// (не позже `lateLimit`), вспыхивает в полную яркость на этом кадре: вспышку, которая начинается уже
/// спавшей, легко пропустить. Событие, впервые видное позже `lateLimit`, не светится совсем.
/// Начавшееся событие держит свое начало, поэтому подстройка времени того же id не дает второй
/// вспышки. Id, которых нет в расписании дольше `memory`, забываются, поэтому один id не должен
/// означать другое событие раньше чем через `memory` секунд.
///
/// Нечисловые время кадра, время или яркость события не светятся.
public struct BeatGlow: Sendable {
    /// λ, на сколько вспышка опережает звук.
    public static let lead = 0.015
    /// Прибавка к басовому слою при полном свечении.
    public static let bassAccent: Float = 0.15
    /// Сколько секунд помнить id, которого нет в расписании.
    public static let memory = 2.0
    /// Событие, впервые видное позже своего начала не больше чем на столько секунд, считается
    /// опоздавшим и вспыхивает полностью. Более старое уже прошлое (например, первое расписание после
    /// появления рендера) и в изменяемом варианте не светится вовсе.
    public static let lateLimit = 0.2
    /// Яркость онсета бочки, впервые видного без захвата, относительно его `amplitude`. Такая вспышка
    /// идет за звуком (обнаружение и показ, на GTZAN в среднем +36 мс) и попадает в долю реже
    /// захваченной (0.58 против 0.91), поэтому светится вполовину: заметно, но не как доля. Захваченные
    /// события, в том числе онсеты, светятся как раньше.
    public static let reactiveScale: Float = 0.5
    /// Допуск округления на границе атаки.
    private static let edgeTolerance = 1e-9

    private struct Record: Sendable {
        /// Время, от которого считается `a` у начавшегося события; `nil`, пока событие не началось.
        var origin: Double?
        /// Впервые видно позже `lateLimit`: не светится.
        var stale = false
        /// Онсет, впервые видный без захвата: светится с `reactiveScale`.
        var reactive = false
        var lastSeen: Double
    }

    private var records: [UInt64: Record] = [:]

    /// Сколько id сейчас помнится (для тестов).
    var rememberedIDs: Int { records.count }

    public init() {}

    /// Постоянная спада: 30 % периода доли в пределах 80-180 мс, 120 мс без темпа.
    public static func decay(period: Double?) -> Double {
        guard let period, period.isFinite else { return 0.12 }
        return min(max(0.3 * period, 0.08), 0.18)
    }

    /// Свечение без памяти: только расписание и время кадра.
    public static func value(at t: Double, schedule: BeatSchedule, refreshPeriod: Double) -> Float {
        guard t.isFinite else { return 0 }
        let decay = decay(period: schedule.period)
        var glow: Float = 0
        for event in schedule.events where isValid(event) {
            let a = t - scheduledOrigin(of: event, refreshPeriod: refreshPeriod)
            glow = max(glow, contribution(amplitude(of: event, in: schedule), a: a, decay: decay))
        }
        return glow
    }

    /// Свечение на кадре, показанном в момент `t`, с памятью о событиях прошлых кадров.
    public mutating func value(at t: Double, schedule: BeatSchedule, refreshPeriod: Double) -> Float {
        guard t.isFinite else { return 0 }
        let decay = Self.decay(period: schedule.period)
        var glow: Float = 0
        for event in schedule.events where Self.isValid(event) {
            let scheduled = Self.scheduledOrigin(of: event, refreshPeriod: refreshPeriod)
            let late = t - scheduled
            var record = records[event.id] ?? {
                // Впервые видно: опоздавшее событие начинается с этого кадра, слишком старое не светится.
                let isLate = late > Self.edgeTolerance && late <= Self.lateLimit
                return Record(
                    origin: isLate ? t : nil, stale: late > Self.lateLimit,
                    reactive: !event.predicted && !schedule.locked, lastSeen: t
                )
            }()
            record.lastSeen = t
            if record.origin == nil, late >= -Self.edgeTolerance {
                record.origin = scheduled
            }
            records[event.id] = record
            guard !record.stale else { continue }
            let a = record.origin.map { t - $0 } ?? late
            let amplitude = record.reactive ? event.amplitude * Self.reactiveScale : event.amplitude
            glow = max(glow, Self.contribution(amplitude, a: a, decay: decay))
        }
        if records.values.contains(where: { t - $0.lastSeen > Self.memory }) {
            records = records.filter { t - $0.value.lastSeen <= Self.memory }
        }
        return glow
    }

    /// Слои волн с акцентом доли: к басу прибавляется `bassAccent × glow`, не выше 1.
    public static func accented(_ layers: [Float], glow: Float) -> [Float] {
        var result = layers
        let bass = WaveLayer.bass.rawValue
        if result.indices.contains(bass) {
            result[bass] = min(result[bass] + bassAccent * glow, 1)
        }
        return result
    }

    /// Момент, когда по расписанию `a = 0`: `event.time - lead - R / 2`. Нечисловой или
    /// отрицательный период обновления считается нулем.
    private static func scheduledOrigin(of event: GlowEvent, refreshPeriod: Double) -> Double {
        let refresh = refreshPeriod.isFinite ? max(refreshPeriod, 0) : 0
        return event.time - lead - refresh / 2
    }

    /// Яркость события в расписании без памяти: онсет без захвата приглушен.
    private static func amplitude(of event: GlowEvent, in schedule: BeatSchedule) -> Float {
        event.predicted || schedule.locked ? event.amplitude : event.amplitude * reactiveScale
    }

    private static func isValid(_ event: GlowEvent) -> Bool {
        event.time.isFinite && event.amplitude.isFinite
    }

    private static func contribution(_ amplitude: Float, a: Double, decay: Double) -> Float {
        guard a >= -edgeTolerance else { return 0 }
        let value = amplitude * Float(exp(-max(a, 0) / decay))
        return min(max(value, 0), 1)
    }
}
