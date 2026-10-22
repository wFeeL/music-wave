import Foundation

/// Односторонний экспоненциальный сглаживатель с разной скоростью роста и спада.
///
/// Коэффициент шага `1 - exp(-dt / tau)`, где `tau` равен `attack`, если цель выше
/// текущего значения, и `release` в остальных случаях.
public struct AttackRelease: Sendable {
    public let attack: Double
    public let release: Double
    public private(set) var value: Float

    public init(attack: Double = 0.03, release: Double = 0.25) {
        self.attack = attack
        self.release = release
        self.value = 0
    }

    /// Сдвигает значение к цели за `dt` секунд и возвращает новое значение.
    @discardableResult
    public mutating func step(toward target: Float, dt: Double) -> Float {
        guard dt > 0 else { return value }
        let tau = target > value ? attack : release
        let coefficient = tau > 0 ? 1 - exp(-dt / tau) : 1
        value += Float(coefficient) * (target - value)
        return value
    }

    public mutating func reset(to value: Float = 0) {
        self.value = value
    }
}
