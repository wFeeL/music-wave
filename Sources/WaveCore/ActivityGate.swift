import Foundation

/// Решает, звучит ли источник, по сырому уровню в dBFS с гистерезисом по времени.
///
/// Работает по `rawLevelDB`, а не по нормализованному уровню: чувствительность и громкость
/// системы не должны прятать остров. Включается, когда уровень выше порога непрерывно
/// `holdTime`, выключается, когда он не выше порога непрерывно `holdTime`.
public struct ActivityGate: Sendable {
    public let thresholdDB: Float
    public let holdTime: Double
    public private(set) var isActive = false

    /// С какого момента уровень непрерывно лежит по другую сторону порога, чем `isActive`.
    private var disagreeSince: Double?

    public init(thresholdDB: Float = -60, holdTime: Double = 0.3) {
        self.thresholdDB = thresholdDB
        self.holdTime = holdTime
    }

    /// Возвращает новое значение `isActive`.
    @discardableResult
    public mutating func update(levelDB: Float, now: Double) -> Bool {
        let above = levelDB > thresholdDB
        if above == isActive {
            disagreeSince = nil
        } else {
            let since = disagreeSince ?? now
            disagreeSince = since
            if now - since >= holdTime - 1e-9 {
                isActive = above
                disagreeSince = nil
            }
        }
        return isActive
    }
}
