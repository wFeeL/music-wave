import Foundation

/// Мягкая остановка на паузе: когда звук пропал, показанные волны, полосы, уровень и свечение
/// не обрываются, а затихают за `duration` секунд.
///
/// Пока звук идет, вход проходит как есть, а его значения запоминаются (последний кадр со звуком).
/// После перехода в тишину слои, полосы и уровень считаются как
/// `max(вход, удержанное × (1 − smoothstep(0, duration, t)))`, где `t` отсчитывается от последнего
/// кадра со звуком; свечение как удержанное × тот же множитель, поэтому новые вспышки, пока тихо,
/// не проходят. Множитель зависит только от времени, не от частоты кадров. Буферы удержания
/// выделяются один раз: на кадре нет выделений, а значения, которые не меняются, не записываются
/// (массив вызывающего не копируется). Слои и полосы другой длины, чем при запоминании, проходят
/// как есть. Часы ведут себя как в `PaletteFade`: назад, и угасание начинается заново с того же
/// места; не конечное время кончает угасание.
public struct SoftStop: Sendable {
    /// Время угасания, с.
    public static let duration = 0.6

    private var heldLayers: [Float] = []
    private var heldBands: [Float] = []
    private var heldLevel: Float = 0
    private var heldGlow: Float = 0
    /// Время последнего кадра со звуком, пока звук идет; `nil` без звука или с не конечным временем.
    private var lastSound: Double?
    /// Начало угасания; `nil`, пока звук идет или когда угасание кончилось.
    private var fadeStart: Double?

    public init() {}

    /// Угасание идет: последний `apply` был в тишине, и множитель еще больше нуля. Остров по нему
    /// не уходит в редкие кадры простоя, пока волны затихают.
    public var isFading: Bool { fadeStart != nil }

    /// Пропускает показанные значения одного кадра. `silent`: звука нет (тишина или пауза
    /// источника), `now`: время кадра, с.
    public mutating func apply(
        layers: inout [Float], bands: inout [Float], level: inout Float, glow: inout Float, silent: Bool, now: Double
    ) {
        guard silent else {
            Self.hold(layers, into: &heldLayers)
            Self.hold(bands, into: &heldBands)
            heldLevel = Self.finite(level)
            heldGlow = Self.finite(glow)
            lastSound = now.isFinite ? now : nil
            fadeStart = nil
            return
        }
        if let lastSound {
            fadeStart = lastSound
            self.lastSound = nil
        }
        let factor = Float(fadeFactor(now: now))
        Self.fade(&layers, held: heldLayers, factor: factor)
        Self.fade(&bands, held: heldBands, factor: factor)
        level = Self.faded(level, held: heldLevel, factor: factor)
        glow = heldGlow * factor
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

    /// Копирует `values` в `held` без нового выделения, если длина та же.
    private static func hold(_ values: [Float], into held: inout [Float]) {
        if held.count != values.count {
            held.removeAll(keepingCapacity: true)
            held.append(contentsOf: repeatElement(0, count: values.count))
        }
        for index in values.indices {
            held[index] = finite(values[index])
        }
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

    private static func finite(_ value: Float) -> Float {
        value.isFinite ? value : 0
    }
}
