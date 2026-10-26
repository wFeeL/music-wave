import Foundation

/// Разбор командной строки `wave-eval`. Лежит в WaveCore, чтобы разбор можно было проверять тестами.
///
/// Формы: `--name value` и `--name=value`; `--tracker` повторяется (`--tracker alpha=0.3`). Значения
/// могут быть отрицательными (`--offset-ms -20`): следующий аргумент берется как значение всегда.
public struct EvalArguments: Sendable, Equatable {
    public enum Split: String, Sendable, CaseIterable, Codable {
        case tune
        case heldout
        case all
    }

    public struct Override: Sendable, Equatable {
        public var name: String
        public var value: Double

        public init(name: String, value: Double) {
            self.name = name
            self.value = value
        }
    }

    /// Группа-объединение: строка отчета "name" по файлам нескольких групп.
    public struct Union: Sendable, Equatable {
        public var name: String
        public var groups: [String]

        public init(name: String, groups: [String]) {
            self.name = name
            self.groups = groups
        }
    }

    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        case unknownOption(String)
        case missingValue(String)
        case invalidValue(option: String, value: String)
        case unknownTrackerParameter(String)
        case missingList
        case extraArgument(String)
        case unknownUnionGroup(union: String, group: String)

        public var description: String {
            switch self {
            case .unknownOption(let name): "unknown option \(name)"
            case .missingValue(let name): "option \(name) needs a value"
            case .invalidValue(let option, let value): "invalid value '\(value)' for \(option)"
            case .unknownTrackerParameter(let name): "unknown tracker parameter '\(name)'"
            case .missingList: "missing list.tsv"
            case .extraArgument(let value): "unexpected argument '\(value)'"
            case .unknownUnionGroup(let union, let group): "--union \(union): no group '\(group)' in the list"
            }
        }
    }

    public var listPath = ""
    public var help = false
    /// Ручной сдвиг вспышек, мс (`Config.syncOffset`).
    public var offsetMs = 0.0
    /// Задержка вывода, мс (`Config.outputLatency`); по умолчанию 0, чтобы оси файла и слышимая совпадали.
    public var latencyMs = 0.0
    public var overrides: [Override] = []
    public var json = false
    public var perFile = false
    public var split = Split.tune
    /// Число потоков; `nil` берет число ядер.
    public var jobs: Int?
    public var unions: [Union] = []
    public var seed: UInt64 = 1
    public var renderHz = 60.0
    /// Окно совпадения вспышки с долей, мс.
    public var windowMs = 70.0
    /// Сколько первых секунд файла не оценивать (у mir_eval 5 с); по умолчанию 0: захват входит в счет.
    public var skipSeconds = 0.0
    /// Взять только первые N файлов списка после фильтра по выборке (быстрые прогоны).
    public var maxFiles: Int?

    public init() {}

    public static let usage = """
        usage: wave-eval [options] <list.tsv>
          list.tsv lines: <wav>\\t<annotation>\\t<group>[\\t<tune|heldout>]  (no 4th column means tune)
          --split tune|heldout|all   file subset to score (default tune; heldout numbers appear only with
                                     heldout or all, keep them out of tuning loops)
          --offset-ms N              manual flash shift, Config.syncOffset (default 0)
          --latency-ms N             output latency, Config.outputLatency (default 0)
          --tracker name=value       override a BeatTracker.Parameters field, repeatable
          --union name=g1,g2,...     extra report row over several groups, repeatable
          --render-hz N              render frame rate (default 60)
          --seed N                   base noise seed; each file mixes in its own name (default 1)
          --window-ms N              hit window (default 70)
          --skip-seconds N           ignore the first N seconds of every file (default 0)
          --jobs N                   worker threads (default: all cores)
          --max-files N              score only the first N files
          --per-file                 print one row per file as well
          --json                     write the report as JSON to stdout
        """

    public static func parse(_ arguments: [String]) throws -> EvalArguments {
        var result = EvalArguments()
        var positional: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            guard argument.hasPrefix("--") else {
                positional.append(argument)
                continue
            }
            var name = argument
            var inline: String?
            if let equals = argument.firstIndex(of: "=") {
                name = String(argument[..<equals])
                inline = String(argument[argument.index(after: equals)...])
            }
            func value() throws -> String {
                if let inline { return inline }
                guard index < arguments.count else { throw Error.missingValue(name) }
                defer { index += 1 }
                return arguments[index]
            }
            func number() throws -> Double {
                let text = try value()
                guard let parsed = Double(text), parsed.isFinite else {
                    throw Error.invalidValue(option: name, value: text)
                }
                return parsed
            }
            switch name {
            case "--help":
                result.help = true
            case "--json":
                result.json = true
            case "--per-file":
                result.perFile = true
            case "--split":
                let text = try value()
                guard let split = Split(rawValue: text) else { throw Error.invalidValue(option: name, value: text) }
                result.split = split
            case "--offset-ms":
                result.offsetMs = try number()
            case "--latency-ms":
                let latency = try number()
                guard latency >= 0 else { throw Error.invalidValue(option: name, value: String(latency)) }
                result.latencyMs = latency
            case "--render-hz":
                let hz = try number()
                guard hz > 0 else { throw Error.invalidValue(option: name, value: String(hz)) }
                result.renderHz = hz
            case "--window-ms":
                let window = try number()
                guard window > 0 else { throw Error.invalidValue(option: name, value: String(window)) }
                result.windowMs = window
            case "--skip-seconds":
                let skip = try number()
                guard skip >= 0 else { throw Error.invalidValue(option: name, value: String(skip)) }
                result.skipSeconds = skip
            case "--seed":
                let text = try value()
                guard let seed = UInt64(text) else { throw Error.invalidValue(option: name, value: text) }
                result.seed = seed
            case "--jobs":
                let text = try value()
                guard let jobs = Int(text), jobs >= 1 else { throw Error.invalidValue(option: name, value: text) }
                result.jobs = jobs
            case "--max-files":
                let text = try value()
                guard let count = Int(text), count >= 1 else { throw Error.invalidValue(option: name, value: text) }
                result.maxFiles = count
            case "--tracker":
                let text = try value()
                guard let equals = text.firstIndex(of: "="),
                    let parsed = Double(text[text.index(after: equals)...]), parsed.isFinite
                else { throw Error.invalidValue(option: name, value: text) }
                guard parsed >= 0 else { throw Error.invalidValue(option: name, value: text) }
                let override = Override(name: String(text[..<equals]), value: parsed)
                var probe = BeatTracker.Parameters()
                guard probe.set(override.name, to: override.value) else {
                    if BeatTracker.Parameters.names.contains(override.name) {
                        throw Error.invalidValue(option: name, value: text)
                    }
                    throw Error.unknownTrackerParameter(override.name)
                }
                result.overrides.append(override)
            case "--union":
                let text = try value()
                guard let equals = text.firstIndex(of: "=") else { throw Error.invalidValue(option: name, value: text) }
                let groups = text[text.index(after: equals)...].split(separator: ",").map(String.init)
                let unionName = String(text[..<equals])
                guard !unionName.isEmpty, !groups.isEmpty else { throw Error.invalidValue(option: name, value: text) }
                result.unions.append(Union(name: unionName, groups: groups))
            default:
                throw Error.unknownOption(name)
            }
        }
        if result.help { return result }
        guard let path = positional.first else { throw Error.missingList }
        if positional.count > 1 { throw Error.extraArgument(positional[1]) }
        result.listPath = path
        return result
    }

    /// Проверка, что все группы объединений есть в списке (опечатка в имени не должна молча сужать строку).
    public func validateUnions(knownGroups: Set<String>) throws {
        for union in unions {
            for group in union.groups where !knownGroups.contains(group) {
                throw Error.unknownUnionGroup(union: union.name, group: group)
            }
        }
    }

    /// Настройка цепочки для файла. Зерно складывается из `seed` и имени файла (FNV-1a), поэтому
    /// результат файла не зависит ни от порядка списка, ни от выборки, ни от числа потоков, а фаза
    /// рендера у файлов разная (иначе общий сдвиг фазы на кадр искажал бы средний сдвиг).
    public func chainConfig(forFile name: String) -> OfflineBeatChain.Config {
        var config = OfflineBeatChain.Config(seed: seed ^ Self.fnv1a(name))
        config.renderRate = renderHz
        config.outputLatency = latencyMs / 1000
        config.syncOffset = offsetMs / 1000
        for override in overrides {
            _ = config.trackerParameters.set(override.name, to: override.value)
        }
        return config
    }

    static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3
        }
        return hash
    }
}

extension BeatTracker.Parameters {
    /// Имена полей, которые можно менять по имени (`--tracker name=value`).
    public static let names: [String] = [
        "alpha", "beta", "matchWindow", "confidenceGain", "lockConfidence", "lockHits", "unlockConfidence",
        "phaseJump", "phaseJumpChecks", "phaseJumpMargin", "dropWindow", "offGridScale", "onsetFloor", "weightLow",
        "weightHigh", "weightRiseBeats", "weightFallBeats", "weightHits", "kickConfirmFloor", "kickConfirmLow",
        "carryTolerance", "carryPhase", "raceBeats", "raceMargin", "raceLimit", "raceVotes", "raceDim", "coastGate",
        "gateFallPerBeatDB", "gateFallNoTempoDB",
    ]

    /// Задает поле по имени. `false`, если имени нет или значение не подходит (целые поля берут только
    /// целые значения).
    public mutating func set(_ name: String, to value: Double) -> Bool {
        guard value.isFinite else { return false }
        switch name {
        case "alpha": alpha = value
        case "beta": beta = value
        case "matchWindow": matchWindow = value
        case "confidenceGain": confidenceGain = value
        case "lockConfidence": lockConfidence = value
        case "unlockConfidence": unlockConfidence = value
        case "phaseJump": phaseJump = value
        case "phaseJumpMargin": phaseJumpMargin = value
        case "dropWindow": dropWindow = value
        case "weightLow": weightLow = value
        case "weightHigh": weightHigh = value
        case "weightRiseBeats": weightRiseBeats = value
        case "weightFallBeats": weightFallBeats = value
        case "kickConfirmFloor": kickConfirmFloor = Float(value)
        case "kickConfirmLow": kickConfirmLow = Float(value)
        case "carryTolerance": carryTolerance = value
        case "carryPhase": carryPhase = value
        case "raceMargin": raceMargin = value
        case "offGridScale": offGridScale = Float(value)
        case "onsetFloor": onsetFloor = Float(value)
        case "coastGate": coastGate = Float(value)
        case "raceDim": raceDim = Float(value)
        case "gateFallPerBeatDB": gateFallPerBeatDB = Float(value)
        case "gateFallNoTempoDB": gateFallNoTempoDB = Float(value)
        case "lockHits", "phaseJumpChecks", "raceBeats", "raceLimit", "raceVotes", "weightHits":
            guard value == value.rounded(), abs(value) < 1e9 else { return false }
            switch name {
            case "lockHits": lockHits = Int(value)
            case "phaseJumpChecks": phaseJumpChecks = Int(value)
            case "raceBeats": raceBeats = Int(value)
            case "raceLimit": raceLimit = Int(value)
            case "weightHits": weightHits = Int(value)
            default: raceVotes = Int(value)
            }
        default: return false
        }
        return true
    }
}
