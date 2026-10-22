import AppKit
import CoreAudio
import Darwin
import WaveCore

/// Процессы, которые Core Audio знает как клиентов звука, и сводка по приложениям.
@MainActor
final class AudioProcessList {
    /// Вызывается на главном потоке, когда меняется `kAudioHardwarePropertyProcessObjectList`.
    var onChange: (() -> Void)?

    private var token: CAListenerToken?

    func start() {
        guard token == nil else { return }
        token = CAProperty.listen(CAProperty.systemObject, kAudioHardwarePropertyProcessObjectList, queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                self?.onChange?()
            }
        }
    }

    func stop() {
        token?.cancel()
        token = nil
    }

    func snapshot() -> [AudioProcessInfo] {
        let objects: [AudioObjectID] = CAProperty.readArray(CAProperty.systemObject, kAudioHardwarePropertyProcessObjectList)
        return objects.compactMap { object -> AudioProcessInfo? in
            let pid: pid_t = CAProperty.read(object, kAudioProcessPropertyPID, default: -1)
            guard pid > 0 else { return nil }
            let bundleID = CAProperty.readCFString(object, kAudioProcessPropertyBundleID)
            let output: UInt32 = CAProperty.read(object, kAudioProcessPropertyIsRunningOutput, default: 0)
            return AudioProcessInfo(
                objectID: object,
                pid: pid,
                bundleID: (bundleID?.isEmpty ?? true) ? nil : bundleID,
                executablePath: Self.executablePath(pid: pid),
                isRunningOutput: output != 0
            )
        }
    }

    /// Процессы, которые сейчас выводят звук, кроме этого приложения. Дешевле `snapshot()`:
    /// для каждого процесса читается только `kAudioProcessPropertyIsRunningOutput`, а PID лишь
    /// у выводящих. Нужен, чтобы раз в секунду проверять весь звук системы в приостановке.
    func outputtingProcessIDs() -> Set<AudioObjectID> {
        let own = getpid()
        let objects: [AudioObjectID] = CAProperty.readArray(CAProperty.systemObject, kAudioHardwarePropertyProcessObjectList)
        var result = Set<AudioObjectID>()
        for object in objects {
            let output: UInt32 = CAProperty.read(object, kAudioProcessPropertyIsRunningOutput, default: 0)
            guard output != 0 else { continue }
            let pid: pid_t = CAProperty.read(object, kAudioProcessPropertyPID, default: -1)
            if pid > 0, pid != own {
                result.insert(object)
            }
        }
        return result
    }

    /// Приложения, у которых есть процессы со звуком: сначала те, что выводят звук сейчас,
    /// внутри групп по имени. Помощник относится к приложению, внутри бандла которого лежит
    /// его исполняемый файл.
    func runningAudioApps() -> [AudioSource] {
        var runningByPath: [String: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard let url = app.bundleURL else { continue }
            runningByPath[Self.canonicalPath(url)] = app
        }
        let ownPath = Self.canonicalPath(Bundle.main.bundleURL)

        var indexByPath: [String: Int] = [:]
        var apps: [(source: AudioSource, outputting: Bool)] = []
        for process in snapshot() {
            let executable = process.executablePath
                ?? NSRunningApplication(processIdentifier: process.pid)?.executableURL?.path(percentEncoded: false)
            guard let executable, let appPath = Self.outermostAppBundle(of: executable) else { continue }
            let canonical = Self.canonicalPath(URL(fileURLWithPath: appPath))
            guard canonical != ownPath else { continue }
            if let index = indexByPath[canonical] {
                apps[index].outputting = apps[index].outputting || process.isRunningOutput
                continue
            }

            let app = runningByPath[canonical]
            let bundle = Bundle(path: canonical)
            let bundleID = app?.bundleIdentifier ?? bundle?.bundleIdentifier ?? ""
            let fallbackName = URL(fileURLWithPath: canonical).deletingPathExtension().lastPathComponent
            let name = app?.localizedName
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? fallbackName
            indexByPath[canonical] = apps.count
            apps.append((.application(bundleID: bundleID, bundlePath: canonical, displayName: name), process.isRunningOutput))
        }
        let byName = apps.sorted {
            $0.source.displayName.localizedStandardCompare($1.source.displayName) == .orderedAscending
        }
        return SourceChoices.outputtingFirst(byName)
    }

    /// Путь исполняемого файла процесса через `proc_pidpath`.
    nonisolated static func executablePath(pid: pid_t) -> String? {
        let capacity = Int(MAXPATHLEN) * 4
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        let length = proc_pidpath(pid, buffer, UInt32(capacity))
        guard length > 0 else { return nil }
        return String(decoding: UnsafeBufferPointer(start: buffer, count: Int(length)), as: UTF8.self)
    }

    /// Путь самого внешнего `.app` в пути файла, например `/Applications/Yandex Music.app`
    /// для `/Applications/Yandex Music.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper`.
    nonisolated static func outermostAppBundle(of path: String) -> String? {
        let components = (path as NSString).pathComponents
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return NSString.path(withComponents: Array(components[...index]))
    }

    /// Путь бандла без символических ссылок, как его ждет `ProcessMatcher`.
    nonisolated static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().path(percentEncoded: false)
    }
}
