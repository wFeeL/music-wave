/// «Тишина адаптера»: tap слышит выбранное приложение, о котором Now Playing раньше сообщал
/// (`applies(to:reportedBundleIDs:)`), а теперь за все это время ни разу не прислал его трек. Когда такого звука набралось `limit` секунд (паузы между треками не
/// обнуляют счет), адаптер для этого источника считается неработающим и приложение переходит
/// в запасной режим.
///
/// Время копится, только пока адаптер работает и трек источника не встречался; шаг между
/// вызовами ограничен `maxStep`, чтобы сон или зависание не засчитывались целиком. Срабатывает
/// один раз до `reset()` (смена источника, пробуждение).
public struct AdapterSilenceMonitor: Sendable {
    public static let defaultLimit = 120.0
    public static let maxStep = 1.0

    public let limit: Double
    /// Сколько секунд источник звучал без трека от Now Playing.
    public private(set) var audibleTime = 0.0
    private var lastNow: Double?
    private var fired = false

    public init(limit: Double = AdapterSilenceMonitor.defaultLimit) {
        self.limit = limit
    }

    /// `true` ровно один раз: в момент, когда набралось `limit` секунд звука без трека.
    public mutating func update(sourceAudible: Bool, trackSeen: Bool, adapterAvailable: Bool, now: Double) -> Bool {
        let step = lastNow.map { min(max(now - $0, 0), Self.maxStep) } ?? 0
        lastNow = now
        guard adapterAvailable, !trackSeen, !fired else { return false }
        if sourceAudible {
            audibleTime += step
        }
        guard audibleTime >= limit - 1e-9 else { return false }
        fired = true
        return true
    }

    /// Считать ли для источника. Весь звук системы нет: там звучит что угодно, в том числе
    /// приложения без Now Playing. Приложение только если Now Playing хоть раз (в любом запуске)
    /// сообщал о нем: иначе молчание адаптера ничего не говорит, источник может вовсе не
    /// публиковать Now Playing (Telegram, игры). Адаптер, сломанный с самого начала, ловит
    /// проверка `test` на каждой сборке macOS.
    public static func applies(to source: AudioSource, reportedBundleIDs: Set<String>) -> Bool {
        guard case .application(let bundleID, _, _) = source, !bundleID.isEmpty else { return false }
        return reportedBundleIDs.contains(bundleID)
    }

    public mutating func reset() {
        audibleTime = 0
        lastNow = nil
        fired = false
    }
}
