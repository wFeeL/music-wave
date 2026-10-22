import Foundation

/// Источник звука, который пользователь выбрал для визуализации.
public enum AudioSource: Codable, Sendable, Hashable {
    case application(bundleID: String, bundlePath: String, displayName: String)
    case systemWide

    public var displayName: String {
        switch self {
        case .application(_, _, let displayName): displayName
        case .systemWide: "Весь звук системы"
        }
    }
}

/// Снимок процесса из списка процессов Core Audio.
public struct AudioProcessInfo: Sendable, Equatable {
    public var objectID: UInt32
    public var pid: Int32
    public var bundleID: String?
    public var executablePath: String?
    public var isRunningOutput: Bool

    public init(
        objectID: UInt32,
        pid: Int32,
        bundleID: String?,
        executablePath: String?,
        isRunningOutput: Bool
    ) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.executablePath = executablePath
        self.isRunningOutput = isRunningOutput
    }
}

/// Сопоставляет источник с процессами: основной процесс приложения и его помощники
/// (Electron, Chromium, Firefox, WebKit).
public enum ProcessMatcher {
    public static let safariBundleID = "com.apple.Safari"
    public static let webKitGPUBundleID = "com.apple.WebKit.GPU"
    public static let yandexMusicCandidates: [String] = ["ru.yandex.desktop.music", "ru.yandex.music"]

    /// `objectID` подходящих процессов по возрастанию.
    public static func matches(_ source: AudioSource, in processes: [AudioProcessInfo]) -> [UInt32] {
        guard case .application(let bundleID, let bundlePath, _) = source else { return [] }

        let pathPrefix = directoryPrefix(of: bundlePath)
        let includesWebKitGPU = bundleID == safariBundleID

        var result: [UInt32] = []
        for process in processes {
            var isMatch = false
            if let pathPrefix, let path = process.executablePath,
               normalized(path).hasPrefix(pathPrefix) {
                isMatch = true
            }
            if !isMatch, let id = process.bundleID {
                isMatch = bundleIDBelongs(id, to: bundleID)
                    || (includesWebKitGPU && id == webKitGPUBundleID)
            }
            if isMatch { result.append(process.objectID) }
        }
        return Array(Set(result)).sorted()
    }

    /// bundle ID процесса или записи Now Playing относится к приложению `appBundleID`: равен ему
    /// или начинается с него и точки (помощники вроде `com.google.Chrome.helper`). Пустой bundle ID
    /// приложения не подходит ни к чему.
    public static func bundleIDBelongs(_ candidate: String, to appBundleID: String) -> Bool {
        guard !appBundleID.isEmpty else { return false }
        return candidate == appBundleID || candidate.hasPrefix(appBundleID + ".")
    }

    /// Истинно, когда множество подходящих процессов отличается от `current` (порядок не важен).
    public static func needsRebuild(
        source: AudioSource,
        current: [UInt32],
        processes: [AudioProcessInfo]
    ) -> Bool {
        Set(matches(source, in: processes)) != Set(current)
    }

    /// Путь бандла как префикс каталога: без хвостового "/" и с добавленным "/".
    /// Пустой путь префикса не дает, иначе совпал бы любой абсолютный путь.
    private static func directoryPrefix(of bundlePath: String) -> String? {
        var path = normalized(bundlePath)
        while path.hasSuffix("/") { path.removeLast() }
        return path.isEmpty ? nil : path + "/"
    }

    private static func normalized(_ string: String) -> String {
        string.precomposedStringWithCanonicalMapping
    }
}

extension NowPlayingInfo {
    /// Запись Now Playing относится к источнику: bundle ID приложения или его родителя подходит
    /// по правилам `ProcessMatcher.bundleIDBelongs`. Для всего звука системы подходит любая.
    public func belongs(to source: AudioSource) -> Bool {
        switch source {
        case .systemWide:
            return true
        case .application(let bundleID, _, _):
            if ProcessMatcher.bundleIDBelongs(bundleIdentifier, to: bundleID) { return true }
            guard let parentBundleIdentifier else { return false }
            return ProcessMatcher.bundleIDBelongs(parentBundleIdentifier, to: bundleID)
        }
    }
}

/// Пункты списка «Источник звука» в настройках: найденная Яндекс Музыка, приложения со звуком,
/// установленные браузеры и выбранное приложение, которого нет в этих списках.
public struct SourceChoices: Sendable, Equatable {
    /// Браузеры, которые предлагаются, если установлены.
    public static let browserBundleIDs = [
        "ru.yandex.desktop.yandex-browser",
        "com.google.Chrome",
        "org.mozilla.firefox",
        "com.apple.Safari",
    ]

    public var yandexMusic: AudioSource?
    public var playing: [AudioSource]
    public var browsers: [AudioSource]
    /// Выбранное приложение вне списков, например через «Выбрать приложение…».
    public var other: AudioSource?

    public init(yandexMusic: AudioSource?, playing: [AudioSource], browsers: [AudioSource], other: AudioSource?) {
        self.yandexMusic = yandexMusic
        self.playing = playing
        self.browsers = browsers
        self.other = other
    }

    /// Списки без повторов в порядке Яндекс Музыка, приложения со звуком, браузеры. Приложение
    /// узнается по пути бандла, без пути по bundle ID; весь звук системы в списки не попадает.
    /// Пункт того же приложения, что `selected`, заменяется самим `selected`: имя в списках
    /// может отличаться от сохраненного, а меню ищет выбранный пункт по равенству.
    public static func make(
        selected: AudioSource?,
        yandexMusic: AudioSource?,
        playing: [AudioSource],
        browsers: [AudioSource]
    ) -> SourceChoices {
        let selectedKey = selected.flatMap(key)
        var seen = Set<String>()
        func take(_ source: AudioSource) -> AudioSource? {
            guard let key = key(source), seen.insert(key).inserted else { return nil }
            return key == selectedKey ? selected : source
        }
        let yandex = yandexMusic.flatMap(take)
        let playingApps = playing.compactMap(take)
        let browserApps = browsers.compactMap(take)
        let other = selectedKey.flatMap { seen.contains($0) ? nil : selected }
        return SourceChoices(yandexMusic: yandex, playing: playingApps, browsers: browserApps, other: other)
    }

    /// Приложения, которые сейчас выводят звук, первыми; внутри обеих групп порядок прежний.
    public static func outputtingFirst(_ apps: [(source: AudioSource, outputting: Bool)]) -> [AudioSource] {
        apps.filter(\.outputting).map(\.source) + apps.filter { !$0.outputting }.map(\.source)
    }

    /// Есть ли пункт для `source`. Весь звук системы есть всегда.
    public func contains(_ source: AudioSource) -> Bool {
        source == .systemWide || source == yandexMusic || source == other
            || playing.contains(source) || browsers.contains(source)
    }

    /// Ключ приложения: путь бандла в канонической форме Unicode, без пути bundle ID.
    private static func key(_ source: AudioSource) -> String? {
        guard case .application(let bundleID, let bundlePath, _) = source else { return nil }
        if !bundlePath.isEmpty {
            return "path:" + bundlePath.precomposedStringWithCanonicalMapping
        }
        return bundleID.isEmpty ? nil : "id:" + bundleID
    }
}
