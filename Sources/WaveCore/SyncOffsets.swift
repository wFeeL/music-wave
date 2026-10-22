import Foundation

/// «Сдвиг синхронизации» по устройствам вывода, миллисекунды: -100...100 с шагом 5. Минус ставит
/// свечение и волны раньше звука, плюс позже.
///
/// У каждого устройства (ключ `byDevice`, UID из Core Audio) может быть свой сдвиг, остальные
/// берут общий `fallbackMs`. Пустой UID (устройство неизвестно) всегда означает общий сдвиг:
/// `set` с ним меняет `fallbackMs`. Все значения, в том числе из JSON, проходят `clamp`.
public struct SyncOffsets: Codable, Equatable, Sendable {
    /// Свой сдвиг устройства и его имя для подписи в настройках.
    public struct DeviceOffset: Codable, Equatable, Sendable {
        public var ms: Int
        public var name: String

        public init(ms: Int, name: String) {
            self.ms = ms
            self.name = name
        }
    }

    public static let range: ClosedRange<Int> = -100...100
    public static let step = 5

    public private(set) var fallbackMs: Int
    public private(set) var byDevice: [String: DeviceOffset]

    public init(fallbackMs: Int = 0, byDevice: [String: DeviceOffset] = [:]) {
        self.fallbackMs = Self.clamp(fallbackMs)
        var entries: [String: DeviceOffset] = [:]
        for (uid, entry) in byDevice where !uid.isEmpty {
            entries[uid] = DeviceOffset(ms: Self.clamp(entry.ms), name: entry.name)
        }
        self.byDevice = entries
    }

    /// Старый общий сдвиг (`wf.syncOffset` до 1.1) становится `fallbackMs`; без него все по нулям.
    public static func migrated(legacyMs: Int?) -> SyncOffsets {
        SyncOffsets(fallbackMs: legacyMs ?? 0)
    }

    /// В пределах `range`, до ближайшего кратного `step` (-37 дает -35).
    public static func clamp(_ milliseconds: Int) -> Int {
        let clamped = min(max(milliseconds, range.lowerBound), range.upperBound)
        return Int((Double(clamped) / Double(step)).rounded()) * step
    }

    /// Сдвиг для устройства: свой, если задан, иначе общий.
    public func offset(forDeviceUID uid: String) -> Int {
        byDevice[uid]?.ms ?? fallbackMs
    }

    /// У устройства свой сдвиг (в настройках тогда видна кнопка «Сбросить»).
    public func hasOwnOffset(forDeviceUID uid: String) -> Bool {
        byDevice[uid] != nil
    }

    /// Свой сдвиг устройства; с пустым UID меняет общий.
    public mutating func set(_ ms: Int, deviceUID uid: String, name: String) {
        let value = Self.clamp(ms)
        if uid.isEmpty {
            fallbackMs = value
        } else {
            byDevice[uid] = DeviceOffset(ms: value, name: name)
        }
    }

    /// Устройство снова берет общий сдвиг.
    public mutating func reset(deviceUID uid: String) {
        byDevice[uid] = nil
    }

    // MARK: - JSON

    private enum CodingKeys: String, CodingKey {
        case fallbackMs, byDevice
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            fallbackMs: try container.decodeIfPresent(Int.self, forKey: .fallbackMs) ?? 0,
            byDevice: try container.decodeIfPresent([String: DeviceOffset].self, forKey: .byDevice) ?? [:]
        )
    }
}
