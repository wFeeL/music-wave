import Foundation

/// Прогон записи ритма с устройства (`RhythmLog` и его WAV) через `OfflineBeatChain` с той же
/// задержкой вывода, сдвигом и частотой отрисовки (`wave-eval --replay`). Вспышки устройства
/// сравниваются со вспышками прогона: если они совпадают, а в долю не попадают, ошибается анализ;
/// если прогон попадает, а устройство нет, дело в задержке или рендере.
///
/// Сравниваются вспышки на общем отрезке `[0, until]`: `until` это меньшее из последнего кадра
/// рендера (`meta.renderedUntil`) и слышимого конца звука (звук плюс задержка вывода плюс
/// положительный сдвиг). Если запись кончилась раньше (не `complete`), анализ на устройстве
/// остановился и сбросил расписание вскоре после последнего сэмпла, поэтому `until` не дальше
/// `audioSeconds`: вспышки устройства позже этого могли пропасть. Прогон начинает с холодного трекера, а устройство к началу записи уже
/// могло держать ритм, поэтому есть и строка "after lock": только вспышки после того, как оба
/// захватили ритм.
public enum RhythmReplay {
    public enum Error: Swift.Error, Equatable {
        case sampleRateMismatch(log: Double, wav: Double)
        case emptyAudio
    }

    public struct Options: Sendable {
        public var seed: UInt64
        /// Окно совпадения вспышек, секунды.
        public var window: Double
        public var trackerParameters: BeatTracker.Parameters
        /// Печатать каждую вспышку устройства с ближайшей вспышкой прогона.
        public var listFlashes: Bool

        public init(seed: UInt64 = 1, window: Double = 0.030, trackerParameters: BeatTracker.Parameters = .init(), listFlashes: Bool = false) {
            self.seed = seed
            self.window = window
            self.trackerParameters = trackerParameters
            self.listFlashes = listFlashes
        }
    }

    /// Вспышки устройства против вспышек прогона.
    public struct Comparison: Sendable, Equatable {
        public var deviceCount: Int
        public var replayCount: Int
        /// Пар один к одному в окне.
        public var matched: Int
        /// `matched / deviceCount`, 0 без вспышек устройства.
        public var matchedShare: Double
        /// Средняя разность "устройство минус прогон" по парам, секунды; плюс значит устройство позже.
        public var meanDifference: Double?
        /// 95-й процентиль той же разности (со знаком).
        public var p95Difference: Double?
        /// 95-й процентиль модуля разности.
        public var p95AbsoluteDifference: Double?
    }

    /// Темп и захват по времени.
    public struct Timeline: Sendable, Equatable {
        /// Первая публикация с захватом, секунды оси.
        public var firstLock: Double?
        /// Доля времени `[0, end]` с захватом (до первой публикации захвата нет).
        public var lockedShare: Double
        /// Сколько раз захват появлялся или пропадал.
        public var lockChanges: Int
        public var lastBPM: Double?
        /// Медиана темпа по публикациям с захватом.
        public var medianLockedBPM: Double?

        public init(schedules: [RhythmLog.Schedule], end: Double) {
            self.init(points: schedules.map { ($0.time, $0.locked, $0.bpm) }, end: end)
        }

        public init(states: [OfflineBeatChain.State], end: Double) {
            self.init(points: states.map { ($0.time, $0.locked, $0.bpm) }, end: end)
        }

        private init(points: [(time: Double, locked: Bool, bpm: Double?)], end: Double) {
            firstLock = points.first(where: \.locked)?.time
            var locked = 0.0
            var changes = 0
            for (index, point) in points.enumerated() where point.time < end {
                if index > 0, points[index - 1].locked != point.locked { changes += 1 }
                guard point.locked else { continue }
                let next = index + 1 < points.count ? min(points[index + 1].time, end) : end
                locked += max(next - max(point.time, 0), 0)
            }
            lockedShare = end > 0 ? min(locked / end, 1) : 0
            lockChanges = changes
            lastBPM = points.last(where: { $0.time < end })?.bpm
            let tempos = points.filter { $0.locked && $0.time < end }.compactMap(\.bpm).sorted()
            if tempos.isEmpty {
                medianLockedBPM = nil
            } else if tempos.count % 2 == 1 {
                medianLockedBPM = tempos[tempos.count / 2]
            } else {
                medianLockedBPM = (tempos[tempos.count / 2 - 1] + tempos[tempos.count / 2]) / 2
            }
        }
    }

    public struct Report: Sendable {
        public var meta: RhythmLog.Meta
        public var options: Options
        /// Конец общего отрезка сравнения, секунды оси.
        public var until: Double
        public var all: Comparison
        /// Только вспышки после того, как и устройство, и прогон захватили ритм; `nil`, если
        /// кто-то не захватил.
        public var afterLock: Comparison?
        public var afterLockFrom: Double?
        public var device: Timeline
        public var replay: Timeline
        /// Вспышки устройства и прогона на отрезке сравнения.
        public var deviceFlashes: [RhythmLog.Flash]
        public var replayFlashes: [OfflineBeatChain.Flash]
    }

    /// Пары один к одному: каждая вспышка устройства по порядку берет ближайшую свободную
    /// вспышку прогона в окне ±`window`.
    public static func compare(device: [Double], replay: [Double], window: Double) -> Comparison {
        let device = device.sorted()
        let replay = replay.sorted()
        var used = [Bool](repeating: false, count: replay.count)
        var differences: [Double] = []
        for time in device {
            var best: Int?
            for (index, other) in replay.enumerated() where !used[index] && abs(time - other) <= window + 1e-9 {
                if let current = best, abs(time - replay[current]) <= abs(time - other) { continue }
                best = index
            }
            if let best {
                used[best] = true
                differences.append(time - replay[best])
            }
        }
        let mean = differences.isEmpty ? nil : differences.reduce(0, +) / Double(differences.count)
        return Comparison(
            deviceCount: device.count,
            replayCount: replay.count,
            matched: differences.count,
            matchedShare: device.isEmpty ? 0 : Double(differences.count) / Double(device.count),
            meanDifference: mean,
            p95Difference: percentile95(differences),
            p95AbsoluteDifference: percentile95(differences.map(abs))
        )
    }

    /// Настройка цепочки для записи: задержка, сдвиг и частота отрисовки устройства.
    public static func config(for meta: RhythmLog.Meta, options: Options) -> OfflineBeatChain.Config {
        var config = OfflineBeatChain.Config(seed: options.seed)
        config.outputLatency = meta.outputLatency
        config.syncOffset = meta.syncOffset
        if meta.renderPeriod.isFinite, meta.renderPeriod > 0 {
            config.renderRate = 1 / meta.renderPeriod
        }
        config.trackerParameters = options.trackerParameters
        return config
    }

    /// Разбирает запись и ее WAV и прогоняет.
    public static func replay(logData: Data, wavData: Data, options: Options) throws -> Report {
        let log = try RhythmLog.decode(logData)
        let (samples, rate) = try WAVReader.read(wavData)
        return try replay(log: log, samples: samples, sampleRate: rate, options: options)
    }

    public static func replay(log: RhythmLog, samples: [Float], sampleRate: Double, options: Options) throws -> Report {
        let meta = log.meta
        guard meta.sampleRate == sampleRate else {
            throw Error.sampleRateMismatch(log: meta.sampleRate, wav: sampleRate)
        }
        guard !samples.isEmpty else { throw Error.emptyAudio }
        let result = OfflineBeatChain.run(samples: samples, sampleRate: sampleRate, config: config(for: meta, options: options))

        let audioEnd = Double(samples.count) / sampleRate + meta.outputLatency + max(meta.syncOffset, 0)
        var until = min(meta.renderedUntil ?? audioEnd, audioEnd)
        if meta.endReason != .complete {
            until = min(until, Double(samples.count) / sampleRate)
        }
        let deviceFlashes = log.flashes.filter { $0.time >= 0 && $0.time <= until }
        let replayFlashes = result.flashes.filter { $0.time >= 0 && $0.time <= until }
        let all = compare(device: deviceFlashes.map(\.time), replay: replayFlashes.map(\.time), window: options.window)

        let device = Timeline(schedules: log.schedules, end: until)
        let replay = Timeline(states: result.states, end: until)
        var afterLock: Comparison?
        var afterLockFrom: Double?
        if let deviceLock = device.firstLock, let replayLock = replay.firstLock {
            let from = max(deviceLock, replayLock)
            afterLockFrom = from
            afterLock = compare(
                device: deviceFlashes.map(\.time).filter { $0 >= from },
                replay: replayFlashes.map(\.time).filter { $0 >= from },
                window: options.window
            )
        }
        return Report(
            meta: meta, options: options, until: until, all: all, afterLock: afterLock, afterLockFrom: afterLockFrom,
            device: device, replay: replay, deviceFlashes: deviceFlashes, replayFlashes: replayFlashes
        )
    }

    /// Ближайший ранг: значение с номером `ceil(0.95 n)` по возрастанию.
    static func percentile95(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int((0.95 * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank - 1, 0), sorted.count - 1)]
    }
}

extension RhythmReplay {
    /// Аргументы `wave-eval --replay <rhythm.json> [--seed N] [--window-ms N] [--tracker name=value]
    /// [--list]`.
    public struct Arguments: Sendable {
        public var logPath = ""
        public var options = Options()
        public var help = false

        public init() {}

        public static let usage = """
            usage: wave-eval --replay <rhythm.json> [options]
              replays the WAV next to the rhythm log (same name, .wav) through the offline chain with the
              recorded output latency, sync offset and render rate and compares the device flashes with it
              --seed N                   render phase and jitter seed (default 1)
              --window-ms N              flash match window (default 30)
              --tracker name=value       override a BeatTracker.Parameters field, repeatable
              --list                     print every device flash with the nearest replay flash
            """

        public static func parse(_ arguments: [String]) throws -> Arguments {
            typealias Failure = EvalArguments.Error
            var result = Arguments()
            var index = 0
            func value(_ name: String) throws -> String {
                guard index < arguments.count else { throw Failure.missingValue(name) }
                defer { index += 1 }
                return arguments[index]
            }
            while index < arguments.count {
                let argument = arguments[index]
                index += 1
                switch argument {
                case "--replay":
                    result.logPath = try value(argument)
                case "--help":
                    result.help = true
                case "--seed":
                    let text = try value(argument)
                    guard let seed = UInt64(text) else { throw Failure.invalidValue(option: argument, value: text) }
                    result.options.seed = seed
                case "--window-ms":
                    let text = try value(argument)
                    guard let milliseconds = Double(text), milliseconds.isFinite, milliseconds > 0 else {
                        throw Failure.invalidValue(option: argument, value: text)
                    }
                    result.options.window = milliseconds / 1000
                case "--tracker":
                    let text = try value(argument)
                    guard let equals = text.firstIndex(of: "="), let parsed = Double(text[text.index(after: equals)...]),
                          parsed.isFinite, parsed >= 0
                    else { throw Failure.invalidValue(option: argument, value: text) }
                    let name = String(text[..<equals])
                    guard result.options.trackerParameters.set(name, to: parsed) else {
                        if BeatTracker.Parameters.names.contains(name) {
                            throw Failure.invalidValue(option: argument, value: text)
                        }
                        throw Failure.unknownTrackerParameter(name)
                    }
                case "--list":
                    result.options.listFlashes = true
                default:
                    if argument.hasPrefix("--") { throw Failure.unknownOption(argument) }
                    throw Failure.extraArgument(argument)
                }
            }
            if !result.help, result.logPath.isEmpty { throw Failure.missingValue("--replay") }
            return result
        }
    }
}

extension RhythmReplay.Report {
    /// Отчет для терминала.
    public var text: String {
        var lines: [String] = []
        let ms = { (seconds: Double) in String(format: "%+.1f", seconds * 1000) }
        lines.append("rhythm log: app \(meta.appVersion) (\(meta.build)), commit \(meta.commit), Swift \(meta.swiftVersion)")
        lines.append(
            "device: \(meta.deviceName) (\(meta.deviceUID)), output latency \(String(format: "%.1f", meta.outputLatency * 1000)) ms "
                + "(\(meta.latencyMode)), sync offset \(ms(meta.syncOffset)) ms, \(Int(meta.sampleRate)) Hz, "
                + "render \(String(format: "%.1f", meta.renderPeriod > 0 ? 1 / meta.renderPeriod : 0)) Hz"
        )
        lines.append(
            "recorded: \(String(format: "%.2f", meta.audioSeconds)) s of \(String(format: "%.0f", meta.duration)) s, "
                + "end \(meta.endReason.rawValue), rendered frames \(meta.renderedFrames)"
                + (meta.renderedUntil.map { " until \(String(format: "%.2f", $0)) s" } ?? "")
        )
        lines.append(
            "device settings: reduce motion \(meta.reduceMotion ? "on" : "off"), glow intensity "
                + "\(String(format: "%.2f", meta.glowIntensity)), beat pulse \(meta.beatPulse ? "on" : "off"), "
                + "low power \(meta.lowPower ? "on" : "off"), clipped samples \(meta.clippedSamples)"
        )
        if meta.reduceMotion {
            lines.append("NOTE: reduce motion was on, the device draws no glow, so 0 device flashes is expected")
        } else if meta.glowIntensity <= 0 {
            lines.append("NOTE: glow intensity was 0, the device flashes below were computed but not visible")
        }
        lines.append(
            "compared: 0...\(String(format: "%.2f", until)) s, match window +-\(String(format: "%.0f", options.window * 1000)) ms, "
                + "replay seed \(options.seed); difference = device minus replay, plus is later"
        )
        lines.append("")
        lines.append(Self.row(["flashes", "device", "replay", "matched", "share", "mean ms", "p95 ms", "p95|d| ms"]))
        lines.append(Self.comparisonRow("all", all))
        if let afterLock, let afterLockFrom {
            lines.append(Self.comparisonRow(String(format: "from %.2f s", afterLockFrom), afterLock))
        } else {
            lines.append("after lock: device or replay never locked")
        }
        let devicePredicted = deviceFlashes.filter(\.predicted).count
        let replayPredicted = replayFlashes.filter(\.predicted).count
        lines.append(
            "predicted flashes: device \(devicePredicted) of \(deviceFlashes.count), replay \(replayPredicted) of \(replayFlashes.count); "
                + "locked flashes: device \(deviceFlashes.filter(\.locked).count), replay \(replayFlashes.filter(\.locked).count)"
        )
        lines.append("")
        lines.append(Self.row(["tempo/lock", "first lock s", "locked share", "lock changes", "median BPM", "last BPM"]))
        lines.append(Self.timelineRow("device", device))
        lines.append(Self.timelineRow("replay", replay))
        if options.listFlashes {
            lines.append("")
            lines.append(Self.row(["device s", "kind", "nearest replay s", "diff ms"]))
            let replayTimes = replayFlashes.map(\.time)
            for flash in deviceFlashes {
                let nearest = replayTimes.min { abs($0 - flash.time) < abs($1 - flash.time) }
                let kind = (flash.predicted ? "beat" : "kick") + (flash.locked ? " L" : "")
                lines.append(Self.row([
                    String(format: "%.3f", flash.time),
                    kind,
                    nearest.map { String(format: "%.3f", $0) } ?? "-",
                    nearest.map { ms(flash.time - $0) } ?? "-",
                ]))
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func row(_ cells: [String]) -> String {
        cells.enumerated().map { index, cell in
            index == 0 ? cell.padding(toLength: 14, withPad: " ", startingAt: 0) : String(repeating: " ", count: max(12 - cell.count, 1)) + cell
        }.joined()
    }

    private static func comparisonRow(_ name: String, _ comparison: RhythmReplay.Comparison) -> String {
        let ms = { (value: Double?) in value.map { String(format: "%+.1f", $0 * 1000) } ?? "-" }
        return row([
            name,
            "\(comparison.deviceCount)",
            "\(comparison.replayCount)",
            "\(comparison.matched)",
            String(format: "%.3f", comparison.matchedShare),
            ms(comparison.meanDifference),
            ms(comparison.p95Difference),
            ms(comparison.p95AbsoluteDifference),
        ])
    }

    private static func timelineRow(_ name: String, _ timeline: RhythmReplay.Timeline) -> String {
        let bpm = { (value: Double?) in value.map { String(format: "%.1f", $0) } ?? "-" }
        return row([
            name,
            timeline.firstLock.map { String(format: "%.2f", $0) } ?? "never",
            String(format: "%.3f", timeline.lockedShare),
            "\(timeline.lockChanges)",
            bpm(timeline.medianLockedBPM),
            bpm(timeline.lastBPM),
        ])
    }
}
