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

/// Сглаживатель с гравитацией для баса: рост экспоненциальный, как у `AttackRelease`, а спад
/// после пика идет по параболе, как падение с остановкой в начале.
///
/// После последнего роста значение `hold` секунд держится на пике, затем падает по формуле
/// `max(target, peak * (1 - ((age - hold) / fall)^2))`, где `age` время с пика. Спад считается
/// точно по времени с пика, а не шагами, поэтому шаг 5 мс и большой шаг после простоя дают одно
/// и то же значение. Любой рост (цель выше значения) начинает отсчет заново от нового пика.
public struct GravityRelease: Sendable {
    /// Сколько секунд пик держится до начала спада.
    public static let hold = 0.04
    /// За сколько секунд после удержания значение падает с пика до нуля.
    public static let fall = 0.3

    public let attack: Double
    public private(set) var value: Float
    private var peak: Float
    private var age: Double

    public init(attack: Double = StreamAnalyzer.attack) {
        self.attack = attack
        value = 0
        peak = 0
        age = 0
    }

    /// Сдвигает значение к цели за `dt` секунд и возвращает новое значение.
    @discardableResult
    public mutating func step(toward target: Float, dt: Double) -> Float {
        guard dt > 0 else { return value }
        if target > value {
            let coefficient = attack > 0 ? 1 - exp(-dt / attack) : 1
            value += Float(coefficient) * (target - value)
            peak = value
            age = 0
            return value
        }
        age += dt
        guard age > Self.hold else { return value }
        let progress = min((age - Self.hold) / Self.fall, 1)
        let curve = peak * Float(1 - progress * progress)
        value = min(value, max(target, curve))
        return value
    }

    public mutating func reset(to value: Float = 0) {
        self.value = value
        peak = value
        age = 0
    }
}
