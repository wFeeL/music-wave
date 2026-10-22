import Dispatch
import Foundation
import Synchronization
import WaveCore

/// `wave-eval`: прогоняет цепочку свечения на записанных файлах и печатает, как вспышки попадают в
/// аннотированные доли. Разбор аргументов, список, метрики и таблицы живут в WaveCore (проверяются
/// тестами); здесь чтение файлов, параллельный прогон и вывод.
enum WaveEval {
    struct Failure: Codable {
        var path: String
        var error: String
    }

    struct Report: Codable {
        struct Settings: Codable {
            var split: String
            var offsetMs: Double
            var latencyMs: Double
            var renderHz: Double
            var seed: UInt64
            var windowMs: Double
            var skipSeconds: Double
            var tracker: [String: Double]
        }

        var settings: Settings
        var notes: [String]
        var splits: [String: [BeatEvaluation.Summary]]
        var files: [BeatEvaluation.FileScore]
        var failed: [Failure]
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }

    static func run(arguments: [String]) -> Int32 {
        let parsed: EvalArguments
        do {
            parsed = try EvalArguments.parse(arguments)
        } catch {
            log("wave-eval: \(error)\n\(EvalArguments.usage)\n")
            return 64
        }
        if parsed.help {
            print(EvalArguments.usage)
            return 0
        }

        let entries: [EvalList.Entry]
        let allEntries: [EvalList.Entry]
        do {
            let text = try String(contentsOfFile: parsed.listPath, encoding: .utf8)
            allEntries = try EvalList.parse(text)
            entries = EvalList.select(allEntries, split: parsed.split, limit: parsed.maxFiles)
        } catch {
            log("wave-eval: \(error)\n")
            return 66
        }
        do {
            try parsed.validateUnions(knownGroups: Set(allEntries.map(\.group)))
        } catch {
            log("wave-eval: \(error)\n")
            return 64
        }
        guard !entries.isEmpty else {
            log("wave-eval: no files in the selected split\n")
            return 66
        }

        let started = Date()
        let jobs = min(parsed.jobs ?? ProcessInfo.processInfo.activeProcessorCount, entries.count)
        let outcomes = evaluate(entries, arguments: parsed, jobs: jobs)
        var scores: [BeatEvaluation.FileScore] = []
        var failures: [Failure] = []
        for (entry, outcome) in zip(entries, outcomes) {
            switch outcome {
            case .success(let score): scores.append(score)
            case .failure(let message): failures.append(Failure(path: entry.wavPath, error: message))
            }
        }
        let wall = Date().timeIntervalSince(started)
        log(String(format: "wave-eval: %d files, %d failed, %d jobs, %.1f s\n", entries.count, failures.count, jobs, wall))
        for failure in failures { log("wave-eval: \(failure.path): \(failure.error)\n") }
        guard !scores.isEmpty else { return 1 }

        let splits: [EvalArguments.Split] = parsed.split == .all ? [.all, .tune, .heldout] : [parsed.split]
        var summaries: [String: [BeatEvaluation.Summary]] = [:]
        for split in splits {
            let chosen = BeatEvaluation.filter(scores, split: split)
            if !chosen.isEmpty { summaries[split.rawValue] = BeatEvaluation.summaries(scores: chosen, unions: parsed.unions) }
        }

        var tracker: [String: Double] = [:]
        for override in parsed.overrides { tracker[override.name] = override.value }
        let settings = Report.Settings(
            split: parsed.split.rawValue, offsetMs: parsed.offsetMs, latencyMs: parsed.latencyMs, renderHz: parsed.renderHz,
            seed: parsed.seed, windowMs: parsed.windowMs, skipSeconds: parsed.skipSeconds, tracker: tracker
        )

        if parsed.json {
            let report = Report(settings: settings, notes: BeatEvaluation.notes, splits: summaries, files: scores, failed: failures)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            do {
                let data = try encoder.encode(report)
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            } catch {
                log("wave-eval: \(error)\n")
                return 70
            }
        } else {
            var out = ["wave-eval | \(scores.count) files | " + describe(settings)]
            out += BeatEvaluation.notes.map { "note: \($0)" }
            if parsed.perFile {
                out += ["", BeatEvaluation.perFileTable(scores)]
            }
            for split in splits {
                guard let rows = summaries[split.rawValue] else { continue }
                out += ["", BeatEvaluation.table(title: "split: \(split.rawValue)", summaries: rows)]
            }
            if !failures.isEmpty {
                out += ["", "failed files (\(failures.count)):"] + failures.map { "  \($0.path): \($0.error)" }
            }
            print(out.joined(separator: "\n"))
        }
        return failures.isEmpty ? 0 : 2
    }

    private static func describe(_ s: Report.Settings) -> String {
        let tracker = s.tracker.isEmpty
            ? "tracker defaults"
            : "tracker " + s.tracker.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        return "split=\(s.split) window=\(s.windowMs) ms latency=\(s.latencyMs) ms offset=\(s.offsetMs) ms "
            + "render=\(s.renderHz) Hz seed=\(s.seed) skip=\(s.skipSeconds) s \(tracker)"
    }

    enum Outcome: Sendable {
        case success(BeatEvaluation.FileScore)
        case failure(String)
    }

    /// Файлы разбираются `jobs` потоками из общей очереди; результат лежит на месте своей записи, поэтому
    /// порядок и числа не зависят от числа потоков.
    private static func evaluate(_ entries: [EvalList.Entry], arguments: EvalArguments, jobs: Int) -> [Outcome] {
        let results = Mutex([Outcome?](repeating: nil, count: entries.count))
        let next = Mutex(0)
        let done = Mutex(0)
        DispatchQueue.concurrentPerform(iterations: jobs) { _ in
            while true {
                let index = next.withLock { value -> Int in
                    defer { value += 1 }
                    return value
                }
                guard index < entries.count else { return }
                let outcome = evaluate(entries[index], arguments: arguments)
                results.withLock { $0[index] = outcome }
                let finished = done.withLock { value -> Int in
                    value += 1
                    return value
                }
                if finished % 100 == 0 { log("wave-eval: \(finished)/\(entries.count)\n") }
            }
        }
        return results.withLock { $0 }.map { $0 ?? .failure("not evaluated") }
    }

    private static func evaluate(_ entry: EvalList.Entry, arguments: EvalArguments) -> Outcome {
        do {
            let audio = try WAVReader.read(try Data(contentsOf: URL(fileURLWithPath: entry.wavPath)))
            let text = try String(contentsOfFile: entry.annotationPath, encoding: .utf8)
            let beats = BeatAnnotations.parse(text)
            guard beats.count >= 2 else { return .failure("fewer than two annotated beats") }
            let duration = Double(audio.samples.count) / audio.sampleRate
            let name = (entry.wavPath as NSString).lastPathComponent
            let result = OfflineBeatChain.run(
                samples: audio.samples, sampleRate: audio.sampleRate, config: arguments.chainConfig(forFile: name)
            )
            let options = BeatEvaluation.Options(window: arguments.windowMs / 1000, skipSeconds: arguments.skipSeconds)
            return .success(
                BeatEvaluation.score(
                    result: result, annotations: beats, duration: duration, options: options,
                    path: entry.wavPath, group: entry.group, heldout: entry.heldout
                )
            )
        } catch {
            return .failure("\(error)")
        }
    }
}
