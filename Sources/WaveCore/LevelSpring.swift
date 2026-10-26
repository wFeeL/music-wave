import Foundation

/// Критически демпфированная пружина для уровня слоя при отрисовке. Экспоненциальное
/// сглаживание оставляет скачки скорости, пружина второго порядка их убирает и не дает
/// перелета. По умолчанию вверх она идет быстро (половина пути за 37 мс), вниз медленнее
/// (за 140 мс); полосы «Спектра» берут свою частоту спада (`SpectrumMotion`).
/// Шаг точный, поэтому результат не зависит от частоты кадров.
public struct LevelSpring: Sendable {
    /// Собственная частота при росте и при спаде уровня по умолчанию, рад/с.
    public static let riseOmega = 45.0
    public static let fallOmega = 12.0
    /// Самый длинный учитываемый кадр, с.
    static let maxStep = 0.25

    public private(set) var value: Float
    /// Скорость изменения `value` в единицах в секунду.
    public private(set) var velocity: Float
    /// Собственная частота этой пружины при росте и при спаде, рад/с.
    public let riseOmega: Double
    public let fallOmega: Double

    /// Не конечная или не положительная частота заменяется частотой по умолчанию.
    public init(value: Float = 0, riseOmega: Double = LevelSpring.riseOmega, fallOmega: Double = LevelSpring.fallOmega) {
        self.value = value.isFinite ? value : 0
        velocity = 0
        self.riseOmega = riseOmega.isFinite && riseOmega > 0 ? riseOmega : Self.riseOmega
        self.fallOmega = fallOmega.isFinite && fallOmega > 0 ? fallOmega : Self.fallOmega
    }

    /// Шаг к `target` за `dt` секунд. Не конечная цель или `dt`, `dt <= 0` ничего не меняют.
    @discardableResult
    public mutating func step(toward target: Float, dt: Double) -> Float {
        guard target.isFinite, dt.isFinite, dt > 0 else { return value }
        let step = min(dt, Self.maxStep)
        let goal = Double(target)
        let omega = goal > Double(value) ? riseOmega : fallOmega
        let y = Double(value) - goal
        let v = Double(velocity)
        let decay = exp(-omega * step)
        let drift = (v + omega * y) * step
        value = Float(goal + (y + drift) * decay)
        velocity = Float((v - omega * drift) * decay)
        return value
    }

    /// Ставит значение без движения.
    public mutating func reset(to value: Float = 0) {
        self.value = value.isFinite ? value : 0
        velocity = 0
    }
}
