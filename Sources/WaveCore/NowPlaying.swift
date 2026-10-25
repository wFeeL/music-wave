import Foundation

/// Снимок «Сейчас играет», собранный из потока mediaremote-adapter.
public struct NowPlayingInfo: Sendable, Equatable {
    public var bundleIdentifier: String
    public var parentBundleIdentifier: String?
    public var title: String
    public var artist: String?
    public var album: String?
    public var isPlaying: Bool
    /// Секунды. `nil`, если адаптер не знает длительность или она бессмысленна.
    public var duration: Double?
    /// Секунды на момент `timestamp`.
    public var elapsedTime: Double?
    public var timestamp: Date?
    public var artworkData: Data?

    public init(
        bundleIdentifier: String,
        parentBundleIdentifier: String? = nil,
        title: String,
        artist: String? = nil,
        album: String? = nil,
        isPlaying: Bool = false,
        duration: Double? = nil,
        elapsedTime: Double? = nil,
        timestamp: Date? = nil,
        artworkData: Data? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.parentBundleIdentifier = parentBundleIdentifier
        self.title = title
        self.artist = artist
        self.album = album
        self.isPlaying = isPlaying
        self.duration = duration
        self.elapsedTime = elapsedTime
        self.timestamp = timestamp
        self.artworkData = artworkData
    }

    /// bundle ID приложений, чей значок можно показать для записи: сначала родитель (помощник
    /// браузера сообщает свой bundle ID, а пользователь знает сам браузер), затем свой. Пустые
    /// и повторы пропускаются.
    public var appBundleIDs: [String] {
        var result: [String] = []
        for id in [parentBundleIdentifier, bundleIdentifier].compactMap({ $0 }) where !id.isEmpty && !result.contains(id) {
            result.append(id)
        }
        return result
    }

    /// Позиция воспроизведения на момент `now`: `elapsedTime` плюс время с `timestamp`,
    /// пока трек играет, в пределах `0...duration`.
    public func elapsed(at now: Date) -> Double? {
        guard let raw = rawElapsed(at: now) else { return nil }
        return Self.clamped(raw, duration: duration)
    }

    /// Позиция без ограничения длительностью: из нее считают и `elapsed(at:)`,
    /// и `playbackPosition(at:)`.
    func rawElapsed(at now: Date) -> Double? {
        Self.rawPosition(elapsed: elapsedTime, timestamp: timestamp, isPlaying: isPlaying, at: now)
    }

    /// Сырая позиция: `elapsed` плюс время с `timestamp`, пока трек играет. Время до метки
    /// (часы ушли назад) не вычитается.
    static func rawPosition(elapsed: Double?, timestamp: Date?, isPlaying: Bool, at now: Date) -> Double? {
        guard var position = elapsed else { return nil }
        if isPlaying, let timestamp {
            position += max(0, now.timeIntervalSince(timestamp))
        }
        return position
    }

    /// Позиция в пределах `0...duration` (без длительности только снизу).
    static func clamped(_ position: Double, duration: Double?) -> Double {
        var position = position
        if let duration {
            position = min(position, duration)
        }
        return max(position, 0)
    }
}

/// Позиция трека для полосы прогресса: прошедшее и оставшееся время в целых секундах
/// и заполненная доля полосы.
public struct PlaybackPosition: Sendable, Equatable {
    /// На сколько секунд сырая позиция может уйти за длительность, прежде чем прогресс
    /// скрывается: такая позиция осталась от прошлого трека или от давней метки.
    public static let overrunTolerance = 2.0

    /// Секунды, в пределах `0...duration`.
    public let elapsed: Double
    /// Секунды.
    public let duration: Double

    public init(elapsed: Double, duration: Double) {
        self.duration = duration
        self.elapsed = duration > 0 ? min(max(elapsed, 0), duration) : max(elapsed, 0)
    }

    /// Заполненная часть полосы, `0...1`.
    public var fraction: Double {
        duration > 0 ? min(max(elapsed / duration, 0), 1) : 0
    }

    /// Длительность в целых секундах, вниз.
    private var totalSeconds: Int {
        duration.isFinite ? max(Int(duration.rounded(.down)), 0) : 0
    }

    /// Прошедшие целые секунды, не больше длительности.
    public var passedSeconds: Int {
        guard elapsed.isFinite else { return 0 }
        return min(max(Int(elapsed.rounded(.down)), 0), totalSeconds)
    }

    /// Оставшиеся целые секунды: вместе с прошедшими дают длительность.
    public var remainingSeconds: Int {
        totalSeconds - passedSeconds
    }

    /// «1:03».
    public var passedText: String {
        Self.clock(passedSeconds)
    }

    /// «−2:31» (знак U+2212).
    public var remainingText: String {
        "\u{2212}" + Self.clock(remainingSeconds)
    }

    /// «0:07», «3:41», «1:02:03».
    public static func clock(_ seconds: Int) -> String {
        let seconds = max(seconds, 0)
        let hours = seconds / 3600
        let minutes = seconds / 60 % 60
        let rest = seconds % 60
        let tail = rest < 10 ? "0\(rest)" : "\(rest)"
        if hours > 0 {
            return "\(hours):" + (minutes < 10 ? "0\(minutes)" : "\(minutes)") + ":" + tail
        }
        return "\(minutes):" + tail
    }
}

extension NowPlayingInfo {
    /// Позиция для полосы прогресса на момент `now`. `nil`, если нет длительности или позиции,
    /// а также если сырая позиция ушла за длительность больше чем на
    /// `PlaybackPosition.overrunTolerance`: тогда тайминг устарел, и полная полоса с «−0:00»
    /// была бы неправдой.
    public func playbackPosition(at now: Date) -> PlaybackPosition? {
        guard let duration, duration.isFinite, duration > 0,
              let raw = rawElapsed(at: now), raw.isFinite,
              raw <= duration + PlaybackPosition.overrunTolerance
        else { return nil }
        return PlaybackPosition(elapsed: raw, duration: duration)
    }
}

/// Какие строки о тайминге писать в лог адаптера: каждая не чаще раза на трек. По этим
/// строкам на маке видно, присылает ли Яндекс Музыка смену трека раньше его позиции.
public struct NowPlayingTimingWatch: Sendable {
    public enum Event: Sendable, Equatable {
        /// У записи есть длительность и позиция, но прогресс скрыт: позиция дальше
        /// длительности больше чем на допуск. `stampAge`: сколько секунд назад метка.
        case positionBeyondDuration(elapsed: Double, duration: Double, stampAge: Double?)
        /// Трек сменился, у нового нет ни длительности, ни позиции, а у прошлого были.
        case trackChangedWithoutTiming
        /// Трек сменился, новый принес длительность без позиции, а у прошлого были обе:
        /// прогресс скрыт до позиции.
        case trackChangedWithoutPosition

        /// Строка лога.
        public var logMessage: String {
            switch self {
            case .trackChangedWithoutTiming:
                return "адаптер: трек сменился без длительности и позиции"
            case .trackChangedWithoutPosition:
                return "адаптер: трек сменился с длительностью, но без позиции"
            case let .positionBeyondDuration(elapsed, duration, stampAge):
                let stamp = stampAge.map { "метка \(Self.seconds($0)) с назад" } ?? "без метки"
                return "адаптер: позиция вне длительности (позиция \(Self.seconds(elapsed)) с, "
                    + "длительность \(Self.seconds(duration)) с, \(stamp))"
            }
        }

        private static func seconds(_ value: Double) -> String {
            String(format: "%.1f", value)
        }
    }

    private struct Track: Sendable, Equatable {
        var bundleIdentifier: String
        var title: String
        var artist: String?
        var album: String?
    }

    /// Последний трек; пустые снимки между треками его не стирают.
    private var last: Track?
    /// У последнего снимка `last` были и длительность, и позиция.
    private var lastHadTiming = false
    /// Трек, о позиции которого уже написано.
    private var reportedOverrun: Track?
    /// Последнее непустое состояние: по нему `check(at:)` проверяет позицию без новой строки.
    /// Пустой снимок его снимает.
    private var lastInfo: NowPlayingInfo?

    /// Насколько позже границы допуска проверять позицию: в сам момент границы она еще видна.
    public static let checkMargin = 0.1

    public init() {}

    /// Очередное состояние Now Playing на момент `now`; возвращает строки, которые пора написать.
    public mutating func observe(_ info: NowPlayingInfo?, at now: Date) -> [Event] {
        lastInfo = info
        guard let info else { return [] }
        let track = Self.track(of: info)
        let hasTiming = info.duration != nil && info.elapsedTime != nil
        var events: [Event] = []
        if track != last {
            if last != nil, lastHadTiming, info.elapsedTime == nil {
                events.append(info.duration == nil ? .trackChangedWithoutTiming : .trackChangedWithoutPosition)
            }
            last = track
        }
        lastHadTiming = hasTiming
        events += overrun(of: info, at: now)
        return events
    }

    /// Когда звать `check(at:)`: последний трек играет, и его позиция уйдет за длительность
    /// дальше допуска сама, без новой строки (так полоса пропадает посреди трека). `nil`, если
    /// трек на паузе, тайминга нет или о позиции этого трека уже написано.
    public var overrunDeadline: Date? {
        guard let info = lastInfo, info.isPlaying, reportedOverrun != Self.track(of: info),
              let duration = info.duration, let elapsed = info.elapsedTime, let timestamp = info.timestamp,
              duration.isFinite, elapsed.isFinite
        else { return nil }
        return timestamp.addingTimeInterval(duration + PlaybackPosition.overrunTolerance - elapsed + Self.checkMargin)
    }

    /// Проверка позиции последнего трека без новой строки, не чаще раза на трек.
    public mutating func check(at now: Date) -> [Event] {
        guard let info = lastInfo else { return [] }
        return overrun(of: info, at: now)
    }

    private mutating func overrun(of info: NowPlayingInfo, at now: Date) -> [Event] {
        let track = Self.track(of: info)
        guard reportedOverrun != track, info.elapsedTime != nil, let duration = info.duration,
              info.playbackPosition(at: now) == nil, let raw = info.rawElapsed(at: now)
        else { return [] }
        reportedOverrun = track
        return [.positionBeyondDuration(
            elapsed: raw, duration: duration, stampAge: info.timestamp.map { now.timeIntervalSince($0) })]
    }

    private static func track(of info: NowPlayingInfo) -> Track {
        Track(bundleIdentifier: info.bundleIdentifier, title: info.title, artist: info.artist, album: info.album)
    }
}

public enum NowPlayingParseError: Error, Equatable, Sendable {
    case invalidJSON
}

/// Значение JSON внутри парсера. Свое, потому что `[String: Any]` не `Sendable`.
enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init?(any value: Any) {
        switch value {
        case is NSNull:
            self = .null
        case let string as String:
            self = .string(string)
        case let bool as Bool where type(of: value) == Bool.self:
            self = .bool(bool)
        case let number as NSNumber:
            // Булевы значения Foundation на Darwin приходят как NSNumber с типом "c".
            if String(cString: number.objCType) == "c", number.intValue == 0 || number.intValue == 1 {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let array as [Any]:
            self = .array(array.compactMap { JSONValue(any: $0) })
        case let dictionary as [String: Any]:
            self = .object(dictionary.compactMapValues { JSONValue(any: $0) })
        default:
            return nil
        }
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var double: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    /// `true`/`false` или число 0/1.
    var flag: Bool? {
        switch self {
        case .bool(let value): return value
        case .number(let value): return value == 0 ? false : (value == 1 ? true : nil)
        default: return nil
        }
    }
}

/// Разбирает строки `stream --micros` из mediaremote-adapter и ведет накопленное состояние.
public struct NowPlayingStreamParser: Sendable {
    private static let maxDuration: Double = 24 * 3600

    private struct TrackKey: Sendable, Equatable {
        var title: String
        var artist: String?
        var album: String?
    }

    private var state: [String: JSONValue] = [:]
    private var current: NowPlayingInfo?
    /// Обложка последнего трека. Переживает строки, после которых играть нечему,
    /// и сбрасывается только при смене трека.
    private var lastArtwork: (key: TrackKey, data: Data)?
    /// Результат последнего разбора base64, чтобы не декодировать одну и ту же строку заново.
    /// Трек, которому принадлежит строка `state["artworkData"]`. `nil`, пока трек неизвестен.
    private var artworkOwner: TrackKey?
    private var decodedArtwork: (encoded: String, data: Data?)?
    /// Трек, которому принадлежат длительность, позиция и метка в `state`. `nil`, пока трек
    /// неизвестен: тогда тайминг достается первому названию, как обложка.
    private var timingOwner: TrackKey?
    /// Когда пришла последняя строка, в payload которой был ключ тайминга (не `null`).
    private var lastTimingAt: Date?

    private static let timingKeys = ["durationMicros", "elapsedTimeMicros", "timestampEpochMicros"]
    /// Тайминг при смене трека свежий, если сырая позиция не дальше этого от начала (секунды)...
    static let freshPosition: Double = 3
    /// ...или строка с ключом тайминга пришла не раньше этого до смены (секунды).
    static let freshTimingWindow: Double = 1

    public init() {}

    /// Принимает одну строку потока. Возвращает текущее состояние или `nil`, если играть нечему.
    /// Строки другого `type`, пустые строки и пустой diff состояние не меняют.
    /// Невалидный JSON бросает ошибку.
    ///
    /// Тайминг (длительность, позиция, метка) принадлежит треку. Дифф со сменой трека удаляет
    /// каждый ключ тайминга, которого в нем нет: позиция прошлого трека иначе досталась бы
    /// новому, и прогресс стоял бы на «−0:00». Свежий тайминг остается (позиция у начала трека
    /// или строка с таймингом только что): адаптер шлет в диффе только изменившиеся ключи, и
    /// тайминг нового трека, пришедший раньше названия или совпавший с прошлым, он больше не
    /// повторит. `receivedAt`: когда строка пришла. Позиция без
    /// метки отсчитывается от этого момента, а смена `playing` без метки переносит позицию
    /// на него, чтобы пауза не попадала во время игры.
    @discardableResult
    public mutating func consume(line: String, receivedAt: Date = Date()) throws -> NowPlayingInfo? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return current }

        guard let raw = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)),
              let root = raw as? [String: Any]
        else { throw NowPlayingParseError.invalidJSON }

        guard root["type"] as? String == "data" else { return current }

        let payload: [String: JSONValue]
        if let object = root["payload"] as? [String: Any] {
            payload = object.compactMapValues { JSONValue(any: $0) }
        } else {
            payload = [:]
        }
        let isDiff = (root["diff"] as? NSNumber)?.boolValue ?? false

        if payload.isEmpty {
            // Слияние пустого diff ничего не меняет; пустой полный снимок значит «ничего не играет».
            if isDiff { return current }
            state = [:]
            current = nil
            timingOwner = nil
            lastTimingAt = nil
            return nil
        }

        // Позиция прежнего состояния на момент строки: нужна, если дифф сменит `playing` без метки.
        let wasPlaying = state["playing"]?.flag ?? false
        let previousPosition = NowPlayingInfo.rawPosition(
            elapsed: stateElapsed, timestamp: stateTimestamp, isPlaying: wasPlaying, at: receivedAt)
        let previousDuration = stateDuration

        if isDiff {
            for (key, value) in payload {
                if case .null = value { state[key] = nil } else { state[key] = value }
            }
        } else {
            state = payload.filter { $0.value != .null }
        }

        var broughtArtwork = false
        if case .string = payload["artworkData"] { broughtArtwork = true }
        let key = currentTrackKey()

        if !isDiff {
            timingOwner = key
        } else if timingOwner == nil {
            // Тайминг пришел раньше названия: он принадлежит первому названию.
            timingOwner = key
        } else if let key, key != timingOwner {
            // Трек сменился: тайминг, не пришедший в этом диффе, остался от прошлого трека,
            // если только он не свежий.
            if !timingIsFresh(payload: payload, receivedAt: receivedAt) {
                for timingKey in Self.timingKeys where payload[timingKey] == nil {
                    state[timingKey] = nil
                }
            }
            timingOwner = key
        }
        if Self.timingKeys.contains(where: { name in payload[name].map { $0 != .null } ?? false }) {
            lastTimingAt = receivedAt
        }

        let stamp = JSONValue.number(receivedAt.timeIntervalSince1970 * 1_000_000)
        if payload["timestampEpochMicros"] == nil {
            if payload["elapsedTimeMicros"]?.double != nil {
                // Позиция без метки: она на момент получения строки.
                state["timestampEpochMicros"] = stamp
            } else if isDiff, payload["playing"] != nil, payload["elapsedTimeMicros"] == nil,
                      wasPlaying != (state["playing"]?.flag ?? false),
                      state["elapsedTimeMicros"] != nil,
                      let previousPosition, previousPosition.isFinite,
                      previousPosition <= (previousDuration ?? .infinity) + PlaybackPosition.overrunTolerance {
                // Пауза или продолжение без метки: позиция переносится на момент строки.
                // Позицию, которую прогресс все равно скрыл бы как устаревшую, не переносим.
                let position = NowPlayingInfo.clamped(previousPosition, duration: previousDuration)
                state["elapsedTimeMicros"] = .number(position * 1_000_000)
                state["timestampEpochMicros"] = stamp
            }
        }

        if state["artworkData"] == nil {
            artworkOwner = nil
        } else if broughtArtwork {
            artworkOwner = key
        } else if let owner = artworkOwner, let key, owner != key {
            // Трек сменился, а новая обложка не пришла: старая строка чужая.
            state["artworkData"] = nil
            artworkOwner = nil
        } else if artworkOwner == nil {
            artworkOwner = key
        }

        var info = makeInfo()
        if var built = info, let key {
            if let artwork = built.artworkData {
                lastArtwork = (key, artwork)
            } else if let last = lastArtwork, last.key == key {
                built.artworkData = last.data
            } else {
                lastArtwork = nil
            }
            info = built
        }
        current = info
        return info
    }

    /// Тайминг в `state` (после слияния строки) при смене трека свежий: сырая позиция на момент
    /// строки не дальше `freshPosition` от начала, или прошлая строка с ключом тайминга пришла
    /// не раньше `freshTimingWindow` назад. Позиция без метки считается на момент строки.
    private func timingIsFresh(payload: [String: JSONValue], receivedAt: Date) -> Bool {
        if let last = lastTimingAt, receivedAt.timeIntervalSince(last) <= Self.freshTimingWindow {
            return true
        }
        let unstamped = payload["elapsedTimeMicros"]?.double != nil && payload["timestampEpochMicros"] == nil
        let position = NowPlayingInfo.rawPosition(
            elapsed: stateElapsed,
            timestamp: unstamped ? receivedAt : stateTimestamp,
            isPlaying: state["playing"]?.flag ?? false,
            at: receivedAt)
        guard let position, position.isFinite else { return false }
        return position <= Self.freshPosition
    }

    private func currentTrackKey() -> TrackKey? {
        guard let title = state["title"]?.string else { return nil }
        return TrackKey(title: title, artist: state["artist"]?.string, album: state["album"]?.string)
    }

    private var stateDuration: Double? {
        state["durationMicros"]?.double.flatMap(Self.duration(fromMicros:))
    }

    private var stateElapsed: Double? {
        state["elapsedTimeMicros"]?.double.flatMap { $0.isFinite ? $0 / 1_000_000 : nil }
    }

    private var stateTimestamp: Date? {
        state["timestampEpochMicros"]?.double.flatMap {
            $0.isFinite ? Date(timeIntervalSince1970: $0 / 1_000_000) : nil
        }
    }

    private mutating func makeInfo() -> NowPlayingInfo? {
        guard let bundle = state["bundleIdentifier"]?.string,
              let title = state["title"]?.string
        else { return nil }

        return NowPlayingInfo(
            bundleIdentifier: bundle,
            parentBundleIdentifier: state["parentApplicationBundleIdentifier"]?.string,
            title: title,
            artist: state["artist"]?.string,
            album: state["album"]?.string,
            isPlaying: state["playing"]?.flag ?? false,
            duration: stateDuration,
            elapsedTime: stateElapsed,
            timestamp: stateTimestamp,
            artworkData: state["artworkData"]?.string.flatMap { decodeArtwork($0) }
        )
    }

    private mutating func decodeArtwork(_ encoded: String) -> Data? {
        if let cached = decodedArtwork, cached.encoded == encoded { return cached.data }
        let data = Data(base64Encoded: encoded)
        decodedArtwork = (encoded, data)
        return data
    }

    private static func duration(fromMicros micros: Double) -> Double? {
        let seconds = micros / 1_000_000
        guard seconds.isFinite, seconds > 0, seconds <= maxDuration else { return nil }
        return seconds
    }
}
