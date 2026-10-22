import Foundation
import Observation
import WaveCore

/// Настройки пользователя в `UserDefaults`, ключи с префиксом `wf.`.
///
/// Перечисления хранятся как JSON. Сеттеры ограничивают диапазоны, бесконечность и NaN
/// заменяются значением по умолчанию. Значения из хранилища при чтении проходят те же проверки,
/// испорченный JSON дает значение по умолчанию. Каждое свойство отслеживается отдельно
/// (`access` и `withMutation`), присваивание того же значения ничего не меняет и не пишет.
@MainActor
@Observable
final class AppSettings {
    enum Key {
        static let source = "wf.source"
        static let sensitivity = "wf.sensitivity"
        static let levelMode = "wf.levelMode"
        static let followSystemVolume = "wf.followSystemVolume"
        static let latencyMode = "wf.latencyMode"
        static let syncOffset = "wf.syncOffset"
        static let wingWidth = "wf.wingWidth"
        static let glowIntensity = "wf.glowIntensity"
        static let beatPulse = "wf.beatPulse"
        static let hideDelay = "wf.hideDelay"
        static let hideInFullscreen = "wf.hideInFullscreen"
        static let paused = "wf.paused"
    }

    enum Limits {
        static let sensitivity: ClosedRange<Float> = 0.25...3
        static let manualLatency: ClosedRange<Int> = 0...LatencyCalculator.maxMilliseconds
        static let syncOffset: ClosedRange<Int> = -100...100
        static let wingWidth: ClosedRange<Double> = 40...120
        static let glowIntensity: ClosedRange<Double> = 0...1
        static let hideDelay: ClosedRange<Double> = 1...30
    }

    enum Default {
        static let sensitivity: Float = 1.0
        static let levelMode = LevelMode.auto
        static let followSystemVolume = true
        static let latencyMode = LatencyMode.auto
        static let syncOffset = 0
        static let wingWidth = 64.0
        static let glowIntensity = 0.6
        static let beatPulse = true
        static let hideDelay = 5.0
        static let hideInFullscreen = true
        static let paused = false
    }

    @ObservationIgnored private let defaults: UserDefaults

    @ObservationIgnored private var storedSource: AudioSource?
    @ObservationIgnored private var storedSensitivity: Float
    @ObservationIgnored private var storedLevelMode: LevelMode
    @ObservationIgnored private var storedFollowSystemVolume: Bool
    @ObservationIgnored private var storedLatencyMode: LatencyMode
    @ObservationIgnored private var storedSyncOffsetMs: Int
    @ObservationIgnored private var storedWingWidth: Double
    @ObservationIgnored private var storedGlowIntensity: Double
    @ObservationIgnored private var storedBeatPulse: Bool
    @ObservationIgnored private var storedHideDelay: Double
    @ObservationIgnored private var storedHideInFullscreen: Bool
    @ObservationIgnored private var storedPaused: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        storedSource = Self.readJSON(AudioSource.self, defaults, Key.source)
        storedSensitivity = Self.clampSensitivity(
            Self.readDouble(defaults, Key.sensitivity).map { Float($0) } ?? Default.sensitivity
        )
        storedLevelMode = Self.readJSON(LevelMode.self, defaults, Key.levelMode) ?? Default.levelMode
        storedFollowSystemVolume = Self.readBool(defaults, Key.followSystemVolume) ?? Default.followSystemVolume
        storedLatencyMode = Self.clampLatency(
            Self.readJSON(LatencyMode.self, defaults, Key.latencyMode) ?? Default.latencyMode
        )
        storedSyncOffsetMs = Self.clampSyncOffset(Self.readInt(defaults, Key.syncOffset) ?? Default.syncOffset)
        storedWingWidth = Self.clamp(
            Self.readDouble(defaults, Key.wingWidth) ?? Default.wingWidth,
            Limits.wingWidth,
            fallback: Default.wingWidth
        )
        storedGlowIntensity = Self.clamp(
            Self.readDouble(defaults, Key.glowIntensity) ?? Default.glowIntensity,
            Limits.glowIntensity,
            fallback: Default.glowIntensity
        )
        storedBeatPulse = Self.readBool(defaults, Key.beatPulse) ?? Default.beatPulse
        storedHideDelay = Self.clamp(
            Self.readDouble(defaults, Key.hideDelay) ?? Default.hideDelay,
            Limits.hideDelay,
            fallback: Default.hideDelay
        )
        storedHideInFullscreen = Self.readBool(defaults, Key.hideInFullscreen) ?? Default.hideInFullscreen
        storedPaused = Self.readBool(defaults, Key.paused) ?? Default.paused
    }

    // MARK: - Свойства

    /// Источник звука; `nil`, пока `AppModel` не выбрал его при первом запуске.
    var source: AudioSource? {
        get {
            access(keyPath: \.source)
            return storedSource
        }
        set {
            guard newValue != storedSource else { return }
            withMutation(keyPath: \.source) { storedSource = newValue }
            if let newValue {
                writeJSON(newValue, Key.source)
            } else {
                defaults.removeObject(forKey: Key.source)
            }
        }
    }

    /// Чувствительность (усиление), 0.25...3.
    var sensitivity: Float {
        get {
            access(keyPath: \.sensitivity)
            return storedSensitivity
        }
        set {
            let value = Self.clampSensitivity(newValue)
            guard value != storedSensitivity else { return }
            withMutation(keyPath: \.sensitivity) { storedSensitivity = value }
            defaults.set(Double(value), forKey: Key.sensitivity)
        }
    }

    var levelMode: LevelMode {
        get {
            access(keyPath: \.levelMode)
            return storedLevelMode
        }
        set {
            guard newValue != storedLevelMode else { return }
            withMutation(keyPath: \.levelMode) { storedLevelMode = newValue }
            writeJSON(newValue, Key.levelMode)
        }
    }

    var followSystemVolume: Bool {
        get {
            access(keyPath: \.followSystemVolume)
            return storedFollowSystemVolume
        }
        set {
            guard newValue != storedFollowSystemVolume else { return }
            withMutation(keyPath: \.followSystemVolume) { storedFollowSystemVolume = newValue }
            defaults.set(newValue, forKey: Key.followSystemVolume)
        }
    }

    /// Задержка волн: авто или вручную 0...500 мс.
    var latencyMode: LatencyMode {
        get {
            access(keyPath: \.latencyMode)
            return storedLatencyMode
        }
        set {
            let value = Self.clampLatency(newValue)
            guard value != storedLatencyMode else { return }
            withMutation(keyPath: \.latencyMode) { storedLatencyMode = value }
            writeJSON(value, Key.latencyMode)
        }
    }

    /// «Сдвиг синхронизации», мс: -100...100 с шагом 5. Минус ставит свечение и волны раньше звука,
    /// плюс позже.
    var syncOffsetMs: Int {
        get {
            access(keyPath: \.syncOffsetMs)
            return storedSyncOffsetMs
        }
        set {
            let value = Self.clampSyncOffset(newValue)
            guard value != storedSyncOffsetMs else { return }
            withMutation(keyPath: \.syncOffsetMs) { storedSyncOffsetMs = value }
            defaults.set(value, forKey: Key.syncOffset)
        }
    }

    /// Ширина каждого крыла в pt, 40...120.
    var wingWidth: Double {
        get {
            access(keyPath: \.wingWidth)
            return storedWingWidth
        }
        set {
            let value = Self.clamp(newValue, Limits.wingWidth, fallback: Default.wingWidth)
            guard value != storedWingWidth else { return }
            withMutation(keyPath: \.wingWidth) { storedWingWidth = value }
            defaults.set(value, forKey: Key.wingWidth)
        }
    }

    /// Яркость свечения, 0...1.
    var glowIntensity: Double {
        get {
            access(keyPath: \.glowIntensity)
            return storedGlowIntensity
        }
        set {
            let value = Self.clamp(newValue, Limits.glowIntensity, fallback: Default.glowIntensity)
            guard value != storedGlowIntensity else { return }
            withMutation(keyPath: \.glowIntensity) { storedGlowIntensity = value }
            defaults.set(value, forKey: Key.glowIntensity)
        }
    }

    /// «Вздох» острова на сильных долях.
    var beatPulse: Bool {
        get {
            access(keyPath: \.beatPulse)
            return storedBeatPulse
        }
        set {
            guard newValue != storedBeatPulse else { return }
            withMutation(keyPath: \.beatPulse) { storedBeatPulse = newValue }
            defaults.set(newValue, forKey: Key.beatPulse)
        }
    }

    /// Через сколько секунд тишины остров прячется, 1...30.
    var hideDelay: Double {
        get {
            access(keyPath: \.hideDelay)
            return storedHideDelay
        }
        set {
            let value = Self.clamp(newValue, Limits.hideDelay, fallback: Default.hideDelay)
            guard value != storedHideDelay else { return }
            withMutation(keyPath: \.hideDelay) { storedHideDelay = value }
            defaults.set(value, forKey: Key.hideDelay)
        }
    }

    var hideInFullscreen: Bool {
        get {
            access(keyPath: \.hideInFullscreen)
            return storedHideInFullscreen
        }
        set {
            guard newValue != storedHideInFullscreen else { return }
            withMutation(keyPath: \.hideInFullscreen) { storedHideInFullscreen = newValue }
            defaults.set(newValue, forKey: Key.hideInFullscreen)
        }
    }

    /// «Приостановить визуализацию».
    var paused: Bool {
        get {
            access(keyPath: \.paused)
            return storedPaused
        }
        set {
            guard newValue != storedPaused else { return }
            withMutation(keyPath: \.paused) { storedPaused = newValue }
            defaults.set(newValue, forKey: Key.paused)
        }
    }

    // MARK: - Ограничения

    private static func clampSensitivity(_ value: Float) -> Float {
        guard value.isFinite else { return Default.sensitivity }
        return min(max(value, Limits.sensitivity.lowerBound), Limits.sensitivity.upperBound)
    }

    private static func clampLatency(_ mode: LatencyMode) -> LatencyMode {
        switch mode {
        case .auto:
            return .auto
        case .manual(let milliseconds):
            let range = Limits.manualLatency
            return .manual(milliseconds: min(max(milliseconds, range.lowerBound), range.upperBound))
        }
    }

    /// В пределах `Limits.syncOffset`, до ближайшего кратного 5 (-37 дает -35).
    private static func clampSyncOffset(_ milliseconds: Int) -> Int {
        let range = Limits.syncOffset
        let clamped = min(max(milliseconds, range.lowerBound), range.upperBound)
        return Int((Double(clamped) / 5).rounded()) * 5
    }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    // MARK: - Хранилище

    private static func readDouble(_ defaults: UserDefaults, _ key: String) -> Double? {
        defaults.object(forKey: key) == nil ? nil : defaults.double(forKey: key)
    }

    /// Целое из числа в хранилище; не число (строка, данные) и нечисловое значение дают `nil`.
    private static func readInt(_ defaults: UserDefaults, _ key: String) -> Int? {
        guard let number = defaults.object(forKey: key) as? NSNumber else { return nil }
        let value = number.doubleValue
        guard value.isFinite, abs(value) < 1e9 else { return nil }
        return Int(value.rounded())
    }

    private static func readBool(_ defaults: UserDefaults, _ key: String) -> Bool? {
        defaults.object(forKey: key) == nil ? nil : defaults.bool(forKey: key)
    }

    private static func readJSON<T: Decodable>(_ type: T.Type, _ defaults: UserDefaults, _ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func writeJSON<T: Encodable>(_ value: T, _ key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}

/// Bundle ID приложений-источников, о которых Now Playing хоть раз сообщал, за все запуски
/// (`UserDefaults`, ключ `wf.nowPlayingSources`). По нему «тишина адаптера» считается только
/// для источников, которые Now Playing вообще публикуют (`AdapterSilenceMonitor.applies`).
@MainActor
final class NowPlayingSourceHistory {
    static let key = "wf.nowPlayingSources"

    private let defaults: UserDefaults
    private(set) var bundleIDs: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        bundleIDs = Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    /// Запоминает bundle ID; пишет в `UserDefaults`, только если его еще не было.
    func insert(_ bundleID: String) {
        guard !bundleID.isEmpty, bundleIDs.insert(bundleID).inserted else { return }
        defaults.set(bundleIDs.sorted(), forKey: Self.key)
    }
}
