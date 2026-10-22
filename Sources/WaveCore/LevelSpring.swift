import Foundation

/// Критически демпфированная пружина для уровня слоя при отрисовке. Экспоненциальное
/// сглаживание оставляет скачки скорости, пружина второго порядка их убирает и не дает
/// перелета. Вверх она идет быстро (половина пути за 37 мс), вниз медленнее (за 140 мс).
/// Шаг точный, поэтому результат не зависит от частоты кадров.
public struct LevelSpring: Sendable {
    /// Собственная частота при росте и при спаде уровня, рад/с.
    static let riseOmega = 45.0
    static let fallOmega = 12.0
    /// Самый длинный учитываемый кадр, с.
    static let maxStep = 0.25

    public private(set) var value: Float
    /// Скорость изменения `value` в единицах в секунду.
    public private(set) var velocity: Float

    public init(value: Float = 0) {
        self.value = value.isFinite ? value : 0
        velocity = 0
    }

    /// Шаг к `target` за `dt` секунд. Не конечная цель или `dt`, `dt <= 0` ничего не меняют.
    @discardableResult
    public mutating func step(toward target: Float, dt: Double) -> Float {
        guard target.isFinite, dt.isFinite, dt > 0 else { return value }
        let step = min(dt, Self.maxStep)
        let goal = Double(target)
        let omega = goal > Double(value) ? Self.riseOmega : Self.fallOmega
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
