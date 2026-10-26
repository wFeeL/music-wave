import Foundation

/// Мягкая остановка на паузе: когда звук пропал, показанные волны, полосы, уровень, свечение,
/// «вздох» и мягкий пульс не обрываются, а затихают за `duration` секунд.
///
/// Пока звук идет, показанные значения запоминаются (последний кадр со звуком). После перехода в
/// тишину слои, полосы и уровень считаются как `max(вход, удержанное × (1 − smoothstep(0, duration,
/// t)))`, где `t` отсчитывается от последнего кадра со звуком; свечение, «вздох» и мягкий пульс как
/// удержанное × тот же множитель, поэтому новые вспышки, вздохи и горбы пульса, пока тихо, не
/// проходят (расписание доли может предсказывать удары и после того, как звук пропал).
/// Если звук вернулся посреди угасания, пол угасания (удержанное × множитель) идет дальше по тем же
/// часам, и все значения, в том числе свечение, «вздох» и пульс, считаются как `max(вход, пол)`, пока множитель не
/// дойдет до нуля: пружины поднимаются от нуля не сразу, и без пола показанное провалилось бы на
/// кадр. Новая тишина в это время угасает от того, что было показано на последнем кадре со звуком.
/// Множитель зависит только от времени, не от частоты кадров. Буферы удержания выделяются один
/// раз: на кадре нет выделений, а значения, которые не меняются, не записываются (массив
/// вызывающего не копируется). Слои и полосы другой длины, чем при запоминании, проходят как есть.
/// Часы ведут себя как в `PaletteFade`: назад, и угасание начинается заново с того же места; не
/// конечное время кончает угасание.
public struct SoftStop: Sendable {
    /// Время угасания, с.
    public static let duration = 0.6

    /// Значения, от которых идет текущее угасание.
    private var held = Values()
    /// Показанные значения последнего кадра со звуком: от них пойдет следующее угасание.
    private var recent = Values()
    /// Время последнего кадра со звуком, пока звук идет; `nil` без звука или с не конечным временем.
    private var lastSound: Double?
    /// Начало угасания; `nil`, пока угасания нет или когда оно кончилось.
    private var fadeStart: Double?

    public init() {}

    /// Источник на паузе по Now Playing (второй повод для тишины, кроме уровня звука): источник
    /// `source` приложение, Now Playing работает (`nowPlayingAvailable`), и его текущая запись
    /// `current` относится к источнику и не играет. Последний трек источника тут не годится: он
    /// обновляется, только пока Now Playing показывает источник, и остался бы на паузе, когда
    /// Now Playing перешел к другому приложению или опустел, а источник снова играет. У всего звука
    /// системы Now Playing не говорит, молчит ли захват (играть может другое приложение): `false`.
    public static func sourcePaused(source: AudioSource, current: NowPlayingInfo?, nowPlayingAvailable: Bool) -> Bool {
        guard case .application = source, nowPlayingAvailable, let current, current.belongs(to: source) else {
            return false
        }
        return !current.isPlaying
    }

    /// Угасание идет: множитель еще больше нуля (тишина или звук, вернувшийся посреди угасания).
    /// Остров по нему не уходит в редкие кадры простоя, пока волны затихают.
    public var isFading: Bool { fadeStart != nil }

    /// Пропускает показанные значения одного кадра без «вздоха» и мягкого пульса. `silent`: звука
    /// нет (тишина или пауза источника), `now`: время кадра, с.
    public mutating func apply(
        layers: inout [Float], bands: inout [Float], level: inout Float, glow: inout Float, silent: Bool, now: Double
    ) {
        var pulse: Float = 0
        var ambient: Float = 0
        apply(
            layers: &layers, bands: &bands, level: &level, glow: &glow, pulse: &pulse, ambient: &ambient,
            silent: silent, now: now
        )
    }

    /// Пропускает показанные значения одного кадра вместе с «вздохом» `pulse` и мягким пульсом
    /// `ambient`.
    public mutating func apply(
        layers: inout [Float], bands: inout [Float], level: inout Float, glow: inout Float, pulse: inout Float,
        ambient: inout Float, silent: Bool, now: Double
    ) {
        guard silent else {
            if fadeStart != nil {
                let factor = Float(fadeFactor(now: now))
                if factor > 0 {
                    Self.fade(&layers, held: held.layers, factor: factor)
                    Self.fade(&bands, held: held.bands, factor: factor)
                    level = Self.faded(level, held: held.level, factor: factor)
                    glow = Self.faded(glow, held: held.glow, factor: factor)
                    pulse = Self.faded(pulse, held: held.pulse, factor: factor)
                    ambient = Self.faded(ambient, held: held.ambient, factor: factor)
                }
            }
            recent.store(layers: layers, bands: bands, level: level, glow: glow, pulse: pulse, ambient: ambient)
            lastSound = now.isFinite ? now : nil
            return
        }
        if let lastSound {
            // Буферы меняются местами: без копий и выделений.
            swap(&held, &recent)
            fadeStart = lastSound
            self.lastSound = nil
        }
        let factor = Float(fadeFactor(now: now))
        Self.fade(&layers, held: held.layers, factor: factor)
        Self.fade(&bands, held: held.bands, factor: factor)
        level = Self.faded(level, held: held.level, factor: factor)
        glow = held.glow * factor
        pulse = held.pulse * factor
        ambient = held.ambient * factor
    }

    /// `1 − smoothstep(0, duration, t)` на момент `now`; 0, когда угасание кончилось или его не было.
    private mutating func fadeFactor(now: Double) -> Double {
        guard let start = fadeStart else { return 0 }
        guard now.isFinite else {
            fadeStart = nil
            return 0
        }
        if now < start {
            // Часы пошли назад: угасание начинается заново с того же места.
            fadeStart = now
            return 1
        }
        let elapsed = now - start
        // Допуск как в `PaletteFade`: 10.6 − 10 в Double чуть меньше 0.6.
        if elapsed >= Self.duration - 1e-9 {
            fadeStart = nil
            return 0
        }
        return 1 - WavePaint.smoothstep(0, Self.duration, elapsed)
    }

    private static func fade(_ values: inout [Float], held: [Float], factor: Float) {
        guard values.count == held.count else { return }
        for index in values.indices {
            let value = faded(values[index], held: held[index], factor: factor)
            if value != values[index] { values[index] = value }
        }
    }

    /// `max(вход, удержанное × множитель)`; не конечный вход считается нулем.
    private static func faded(_ value: Float, held: Float, factor: Float) -> Float {
        let floor = held * factor
        return value.isFinite ? max(value, floor) : floor
    }

    fileprivate static func finite(_ value: Float) -> Float {
        value.isFinite ? value : 0
    }

    /// Запомненные значения одного кадра; не конечные хранятся как 0.
    private struct Values: Sendable {
        var layers: [Float] = []
        var bands: [Float] = []
        var level: Float = 0
        var glow: Float = 0
        var pulse: Float = 0
        var ambient: Float = 0

        mutating func store(layers: [Float], bands: [Float], level: Float, glow: Float, pulse: Float, ambient: Float) {
            Self.copy(layers, into: &self.layers)
            Self.copy(bands, into: &self.bands)
            self.level = SoftStop.finite(level)
            self.glow = SoftStop.finite(glow)
            self.pulse = SoftStop.finite(pulse)
            self.ambient = SoftStop.finite(ambient)
        }

        /// Копирует `values` в `stored` без нового выделения, если длина та же.
        private static func copy(_ values: [Float], into stored: inout [Float]) {
            if stored.count != values.count {
                stored.removeAll(keepingCapacity: true)
                stored.append(contentsOf: repeatElement(0, count: values.count))
            }
            for index in values.indices {
                stored[index] = SoftStop.finite(values[index])
            }
        }
    }
}
