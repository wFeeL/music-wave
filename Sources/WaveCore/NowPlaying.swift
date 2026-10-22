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

    /// Позиция воспроизведения на момент `now`: `elapsedTime` плюс время с `timestamp`,
    /// пока трек играет, в пределах `0...duration`.
    public func elapsed(at now: Date) -> Double? {
        guard var position = elapsedTime else { return nil }
        if isPlaying, let timestamp {
            position += max(0, now.timeIntervalSince(timestamp))
        }
        if let duration {
            position = min(position, duration)
        }
        return max(position, 0)
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

    private var state: [String: JSONValue] = [:]
    private var current: NowPlayingInfo?

    public init() {}

    /// Принимает одну строку потока. Возвращает текущее состояние или `nil`, если играть нечему.
    /// Строки другого `type` и пустые строки состояние не меняют. Невалидный JSON бросает ошибку.
    @discardableResult
    public mutating func consume(line: String) throws -> NowPlayingInfo? {
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
            if !isDiff { state = [:] }
            current = nil
            return nil
        }

        if isDiff {
            for (key, value) in payload {
                if case .null = value { state[key] = nil } else { state[key] = value }
            }
        } else {
            state = payload.filter { $0.value != .null }
        }

        var info = Self.makeInfo(from: state)
        if var built = info {
            if built.artworkData == nil, let previous = current,
               previous.title == built.title, previous.artist == built.artist {
                built.artworkData = previous.artworkData
            }
            info = built
        }
        current = info
        return info
    }

    private static func makeInfo(from state: [String: JSONValue]) -> NowPlayingInfo? {
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
            duration: state["durationMicros"]?.double.flatMap(duration(fromMicros:)),
            elapsedTime: state["elapsedTimeMicros"]?.double.flatMap { $0.isFinite ? $0 / 1_000_000 : nil },
            timestamp: state["timestampEpochMicros"]?.double.flatMap {
                $0.isFinite ? Date(timeIntervalSince1970: $0 / 1_000_000) : nil
            },
            artworkData: state["artworkData"]?.string.flatMap { Data(base64Encoded: $0) }
        )
    }

    private static func duration(fromMicros micros: Double) -> Double? {
        let seconds = micros / 1_000_000
        guard seconds.isFinite, seconds > 0, seconds <= maxDuration else { return nil }
        return seconds
    }
}
