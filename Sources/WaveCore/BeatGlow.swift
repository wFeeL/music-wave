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

/// Вход мягкого пульса (`BeatGlow.ambient`), который трекер публикует в расписании рядом с событиями:
/// сетка доли для горба и энергия бочки. Время на той же оси, что и события расписания.
public struct AmbientInfo: Sendable, Equatable {
    /// Доля сетки: горб пульса на `anchor + k × period` для любого целого k.
    public var anchor: Double
    /// Период доли, секунды; 0 без темпа (горба нет).
    public var period: Double
    /// Высота горба 0...1: уверенность сетки, умноженная на энергетический ворот трекера (в брейке
    /// без бочки горб гаснет вместе с воротом).
    public var confidence: Float
    /// Отношение короткой огибающей уровня полосы бочки (атака 10 мс, спад 150 мс) к ее длинному
    /// среднему (2 с): около 1 при ровном уровне, выше на ударах бочки, 0 в тишине. Трекер в расписании
    /// пишет 0: энергия идет к рендеру в кадре анализа на слышимой оси (`WaveFrame.kickEnergy`,
    /// `BeatGlow.ambient(at:info:frame:)`). Поле нужно формуле `BeatGlow.ambient(at:info:)`.
    public var energy: Float

    public init(anchor: Double, period: Double, confidence: Float, energy: Float) {
        self.anchor = anchor
        self.period = period
        self.confidence = confidence
        self.energy = energy
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
    /// Захват для диагностики и метрик; на показ не влияет, показ идет по `weight`.
    public var locked: Bool
    /// Вес показа 0...1 (`BeatTracker.displayWeight`): плавная уверенность в сетке. От него зависит
    /// приглушение онсетов бочки в `BeatGlow`.
    public var weight: Float
    /// Почему захват потерян (`BeatTracker.lastUnlockReason`); `nil` с захватом и до первого захвата.
    public var unlockReason: UnlockReason?
    /// Вход мягкого пульса (`BeatGlow.ambient`); `nil`, когда расписание не от трекера (метроном,
    /// пустое): тогда пульса нет. На свечение `BeatGlow.value` не влияет.
    public var ambient: AmbientInfo?

    public static let empty = BeatSchedule(events: [], bpm: nil, period: nil, confidence: 0, locked: false)

    /// Без `weight` вес берется из захвата (1 с захватом, 0 без), как показ был до веса.
    public init(
        events: [GlowEvent], bpm: Double?, period: Double?, confidence: Double, locked: Bool, unlockReason: UnlockReason? = nil,
        weight: Float? = nil, ambient: AmbientInfo? = nil
    ) {
        self.events = events
        self.bpm = bpm
        self.period = period
        self.confidence = confidence
        self.locked = locked
        self.weight = weight ?? (locked ? 1 : 0)
        self.unlockReason = unlockReason
        self.ambient = ambient
    }

    /// То же расписание на другой оси времени (поток в хост, задержка вывода, сдвиг синхронизации):
    /// меняются только времена событий и доля сетки пульса, id остаются.
    public func shifted(by offset: Double) -> BeatSchedule {
        var copy = self
        for index in copy.events.indices {
            copy.events[index].time += offset
        }
        copy.ambient?.anchor += offset
        return copy
    }
}

/// Форма свечения (`beat-sync.md` 2.7-2.8): мгновенная атака за λ до звука и экспоненциальный спад.
///
/// `shape(a) = a < 0 ? 0 : exp(-a / decay)` при `a = t - (event.time - lead) + R / 2`, где `t` это
/// время показа кадра, а `R` период обновления экрана (`+R/2` центрирует ошибку квантования кадрами).
/// Свечение равно максимуму `amplitude × shape` по событиям и не бывает больше 1. Онсет бочки
/// (`predicted == false`) светится с `amplitude × (reactiveScale + (1 − reactiveScale) × weight)` по
/// весу расписания: без веса вполовину, с полным весом полностью. Изменяемый вариант берет вес один
/// раз, когда событие впервые видно, чтобы рост веса не зажигал его заново.
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
    /// захваченной (0.58 против 0.91), поэтому светится вполовину: заметно, но не как доля. С ростом веса
    /// показа (`BeatSchedule.weight`) приглушение плавно уходит, при весе 1 онсет светится полностью.
    public static let reactiveScale: Float = 0.5
    /// Мягкий пульс (`ambient(at:info:)`): слой энергии бочки до `ambientEnergyScale`, горб на доле до
    /// `ambientBeatScale`, сумма не выше `ambientCeiling`, ниже порога вспышки
    /// `OfflineBeatChain.eventRise` (0.2), поэтому метрики вспышек от пульса не зависят.
    public static let ambientEnergyScale: Float = 0.12
    public static let ambientBeatScale: Float = 0.08
    public static let ambientCeiling: Float = 0.18
    /// Энергия бочки от `ambientEnergyLow` (слоя нет) до `ambientEnergyHigh` (полный слой). Нижний край
    /// 1.2, а не 1.0: на ровном шуме без ударов отношение колеблется около 1 (95-й процентиль 1.24), и
    /// от 1.0 случайные всплески давали мерцание мимо долей на каждом пятом шаге.
    public static let ambientEnergyLow: Float = 1.2
    public static let ambientEnergyHigh: Float = 1.6
    /// Допуск округления на границе атаки.
    private static let edgeTolerance = 1e-9

    private struct Record: Sendable {
        /// Время, от которого считается `a` у начавшегося события; `nil`, пока событие не началось.
        var origin: Double?
        /// Впервые видно позже `lateLimit`: не светится.
        var stale = false
        /// Множитель яркости по весу первого кадра, на котором событие видно (`scale(of:weight:)`).
        var scale: Float = 1
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

    /// Пределы «Длительности вспышки» (`decayScale`).
    public static let decayScaleRange: ClosedRange<Double> = 0.5...2

    /// Постоянная спада с множителем показа `scale` («Длительность вспышки»): `decay(period:) × scale`.
    /// Множитель вне `decayScaleRange` ограничивается, нечисловой считается 1. Только показ: офлайн-цепочка,
    /// проигрывание журнала и wave-eval зовут функции без множителя (1).
    public static func decay(period: Double?, scale: Double) -> Double {
        let scale = scale.isFinite ? min(max(scale, decayScaleRange.lowerBound), decayScaleRange.upperBound) : 1
        return decay(period: period) * scale
    }

    /// Свечение без памяти: только расписание и время кадра.
    /// `decayScale`: множитель спада для показа (`decay(period:scale:)`), 1 это расчет без него.
    public static func value(at t: Double, schedule: BeatSchedule, refreshPeriod: Double, decayScale: Double = 1) -> Float {
        guard t.isFinite else { return 0 }
        let decay = decay(period: schedule.period, scale: decayScale)
        var glow: Float = 0
        for event in schedule.events where isValid(event) {
            let a = t - scheduledOrigin(of: event, refreshPeriod: refreshPeriod)
            glow = max(glow, contribution(amplitude(of: event, in: schedule), a: a, decay: decay))
        }
        return glow
    }

    /// Свечение на кадре, показанном в момент `t`, с памятью о событиях прошлых кадров.
    /// `decayScale`: множитель спада для показа (`decay(period:scale:)`), 1 это расчет без него.
    public mutating func value(at t: Double, schedule: BeatSchedule, refreshPeriod: Double, decayScale: Double = 1) -> Float {
        guard t.isFinite else { return 0 }
        let decay = Self.decay(period: schedule.period, scale: decayScale)
        var glow: Float = 0
        for event in schedule.events where Self.isValid(event) {
            let scheduled = Self.scheduledOrigin(of: event, refreshPeriod: refreshPeriod)
            let late = t - scheduled
            var record = records[event.id] ?? {
                // Впервые видно: опоздавшее событие начинается с этого кадра, слишком старое не светится.
                let isLate = late > Self.edgeTolerance && late <= Self.lateLimit
                return Record(
                    origin: isLate ? t : nil, stale: late > Self.lateLimit,
                    scale: Self.scale(of: event, weight: schedule.weight), lastSeen: t
                )
            }()
            record.lastSeen = t
            if record.origin == nil, late >= -Self.edgeTolerance {
                record.origin = scheduled
            }
            records[event.id] = record
            guard !record.stale else { continue }
            let a = record.origin.map { t - $0 } ?? late
            glow = max(glow, Self.contribution(event.amplitude * record.scale, a: a, decay: decay))
        }
        if records.values.contains(where: { t - $0.lastSeen > Self.memory }) {
            records = records.filter { t - $0.value.lastSeen <= Self.memory }
        }
        return glow
    }

    /// Формула мягкого пульса на момент `time` с энергией из `info` (проверки формулы; рендер и
    /// офлайн-цепочка зовут `ambient(at:info:frame:)`, энергия расписания трекера всегда 0):
    /// `0.12 × smoothstep(1.2, 1.6, energy) + 0.08 × confidence ×
    /// ((1 + cos 2πφ) / 2)^6`, `φ = (time − anchor) / period`, не выше `ambientCeiling` (0.18).
    /// Отдельный канал: в `value` не входит, рендер рисует `max(свечение, пульс)`. Горб узкий (вдвое
    /// ниже пика примерно через 0.1 периода от доли), без опережения: момент показа уже учтен. Без
    /// `info`, с нечисловыми входами, без темпа (период не больше 0) соответствующей части нет;
    /// уверенность вне 0...1 обрезается.
    public static func ambient(at time: Double, info: AmbientInfo?) -> Float {
        guard let info, time.isFinite else { return 0 }
        var value: Float = 0
        if info.energy.isFinite {
            value += ambientEnergyScale * BeatTracker.smoothstep(ambientEnergyLow, ambientEnergyHigh, info.energy)
        }
        let confidence = info.confidence.isFinite ? min(max(info.confidence, 0), 1) : 0
        if confidence > 0, info.period.isFinite, info.period > 0, info.anchor.isFinite {
            let phase = (time - info.anchor) / info.period
            let half = (1 + cos(2 * Double.pi * phase)) / 2
            let squared = half * half
            value += ambientBeatScale * confidence * Float(squared * squared * squared)
        }
        return min(max(value, 0), ambientCeiling)
    }

    /// Мягкий пульс кадра: сетка и высота горба из расписания `info`, энергия из кадра анализа на тот же
    /// момент показа (`WaveFrame.kickEnergy`, кадр из `FrameStore.frame(at:)`). Кадр публикуется на
    /// слышимой оси, как уровни волн, поэтому энергия совпадает с бочкой при любой задержке вывода, а
    /// энергия в расписании опережала бы звук на задержку вывода. Без `info` (пустое расписание,
    /// метроном) пульса нет.
    public static func ambient(at time: Double, info: AmbientInfo?, frame: WaveFrame) -> Float {
        guard var info else { return 0 }
        info.energy = frame.kickEnergy
        return ambient(at: time, info: info)
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

    /// Яркость события в расписании без памяти: онсет приглушен по весу.
    private static func amplitude(of event: GlowEvent, in schedule: BeatSchedule) -> Float {
        event.amplitude * scale(of: event, weight: schedule.weight)
    }

    /// Множитель яркости: доля 1, онсет бочки `reactiveScale + (1 − reactiveScale) × weight`; вес вне
    /// 0...1 или нечисловой считается границей или нулем.
    private static func scale(of event: GlowEvent, weight: Float) -> Float {
        guard !event.predicted else { return 1 }
        let clamped = weight.isFinite ? min(max(weight, 0), 1) : 0
        return reactiveScale + (1 - reactiveScale) * clamped
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
