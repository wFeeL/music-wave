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
        let helperPrefix = bundleID.isEmpty ? nil : bundleID + "."
        let includesWebKitGPU = bundleID == safariBundleID

        var result: [UInt32] = []
        for process in processes {
            var isMatch = false
            if let pathPrefix, let path = process.executablePath,
               normalized(path).hasPrefix(pathPrefix) {
                isMatch = true
            }
            if !isMatch, let id = process.bundleID {
                isMatch = (!bundleID.isEmpty && id == bundleID)
                    || (helperPrefix.map { id.hasPrefix($0) } ?? false)
                    || (includesWebKitGPU && id == webKitGPUBundleID)
            }
            if isMatch { result.append(process.objectID) }
        }
        return Array(Set(result)).sorted()
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
