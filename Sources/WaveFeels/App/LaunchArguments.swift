import Foundation

/// Аргументы запуска для проверок и CI. Неизвестные аргументы (в том числе
/// системные вида `-NSDocumentRevisionsDebugMode YES`) пропускаются.
struct LaunchArguments: Equatable {
    /// `--demo <path>`: звук из файла вместо захвата.
    var demoFile: URL?
    /// `--render-snapshots <dir>`: отрисовать снимки острова и выйти.
    var snapshotDirectory: URL?
    /// `--fake-notch`: рисовать искусственный вырез на любом экране.
    var fakeNotch: Bool
    /// `--no-capture`: не запускать захват звука.
    var noCapture: Bool
    /// `--exit-after <seconds>`: завершиться через заданное число секунд.
    var exitAfter: Double?
    /// `--settings-suite <name>`: настройки из набора `UserDefaults(suiteName:)` вместо настроек
    /// пользователя. Им пользуется замер CPU (scripts/cpu-probe.sh), чтобы мерить на заданных
    /// настройках, а не на тех, что выбраны на этом маке.
    var settingsSuite: String?

    init(
        demoFile: URL? = nil,
        snapshotDirectory: URL? = nil,
        fakeNotch: Bool = false,
        noCapture: Bool = false,
        exitAfter: Double? = nil,
        settingsSuite: String? = nil
    ) {
        self.demoFile = demoFile
        self.snapshotDirectory = snapshotDirectory
        self.fakeNotch = fakeNotch
        self.noCapture = noCapture
        self.exitAfter = exitAfter
        self.settingsSuite = settingsSuite
    }

    static func parse(_ args: [String]) -> LaunchArguments {
        var result = LaunchArguments()
        var index = 0

        // Значение флага: следующий аргумент, если он есть и сам не флаг `--...`.
        func takeValue() -> String? {
            let next = index + 1
            guard next < args.count, !args[next].hasPrefix("--") else { return nil }
            index = next
            return args[next]
        }

        while index < args.count {
            switch args[index] {
            case "--demo":
                result.demoFile = takeValue().map { URL(fileURLWithPath: $0) }
            case "--render-snapshots":
                result.snapshotDirectory = takeValue().map { URL(fileURLWithPath: $0, isDirectory: true) }
            case "--fake-notch":
                result.fakeNotch = true
            case "--no-capture":
                result.noCapture = true
            case "--exit-after":
                result.exitAfter = takeValue()
                    .flatMap(Double.init)
                    .flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            case "--settings-suite":
                result.settingsSuite = takeValue().flatMap { $0.isEmpty ? nil : $0 }
            default:
                break
            }
            index += 1
        }
        return result
    }
}
