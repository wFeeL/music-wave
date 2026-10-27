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
            var resetEvery: Double?
            var resetTrackerOnly: Bool
            var pairsPerGroup: Int?
            var pause: Double?
            var pairGap: Double?
            var glowMode: String
        }

        var settings: Settings
        var notes: [String]
        /// С `--pairs`: B с холодного старта; иначе файлы как есть.
        var splits: [String: [BeatEvaluation.Summary]]
        var files: [BeatEvaluation.FileScore]
        /// С `--pairs`: B сразу после A (только B в счете).
        var warmSplits: [String: [BeatEvaluation.Summary]]?
        var warmFiles: [BeatEvaluation.FileScore]?
        var failed: [Failure]
    }

    static func log(_ message: String) {
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
        if parsed.owner {
            return Owner.run(parsed)
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
        var scores: [BeatEvaluation.FileScore] = []
        var warmScores: [BeatEvaluation.FileScore]?
        var failures: [Failure] = []
        let jobs: Int
        if let perGroup = parsed.pairs {
            let pairs = EvalPairs.make(entries, perGroup: perGroup)
            guard !pairs.isEmpty else {
                log("wave-eval: no pairs in the selected split\n")
                return 66
            }
            jobs = min(parsed.jobs ?? ProcessInfo.processInfo.activeProcessorCount, pairs.count)
            var warm: [BeatEvaluation.FileScore] = []
            let outcomes = parallel(count: pairs.count, jobs: jobs) { evaluatePair(pairs[$0], arguments: parsed) }
            for (pair, outcome) in zip(pairs, outcomes) {
                switch outcome {
                case .success(let both):
                    scores.append(both.cold)
                    warm.append(both.warm)
                case .failure(let message): failures.append(Failure(path: pair.name, error: message))
                }
            }
            warmScores = warm
        } else {
            jobs = min(parsed.jobs ?? ProcessInfo.processInfo.activeProcessorCount, entries.count)
            let outcomes = parallel(count: entries.count, jobs: jobs) { evaluate(entries[$0], arguments: parsed) }
            for (entry, outcome) in zip(entries, outcomes) {
                switch outcome {
                case .success(let score): scores.append(score)
                case .failure(let message): failures.append(Failure(path: entry.wavPath, error: message))
                }
            }
        }
        let wall = Date().timeIntervalSince(started)
        let unit = parsed.pairs == nil ? "files" : "pairs"
        log(String(format: "wave-eval: %d %@, %d failed, %d jobs, %.1f s\n", scores.count + failures.count, unit, failures.count, jobs, wall))
        for failure in failures { log("wave-eval: \(failure.path): \(failure.error)\n") }
        guard !scores.isEmpty else { return 1 }

        let splits: [EvalArguments.Split] = parsed.split == .all ? [.all, .tune, .heldout] : [parsed.split]
        func summarize(_ scores: [BeatEvaluation.FileScore]) -> [String: [BeatEvaluation.Summary]] {
            var summaries: [String: [BeatEvaluation.Summary]] = [:]
            for split in splits {
                let chosen = BeatEvaluation.filter(scores, split: split)
                if !chosen.isEmpty { summaries[split.rawValue] = BeatEvaluation.summaries(scores: chosen, unions: parsed.unions) }
            }
            return summaries
        }
        let summaries = summarize(scores)
        let warmSummaries = warmScores.map(summarize)

        var tracker: [String: Double] = [:]
        for override in parsed.overrides { tracker[override.name] = override.value }
        let settings = Report.Settings(
            split: parsed.split.rawValue, offsetMs: parsed.offsetMs, latencyMs: parsed.latencyMs, renderHz: parsed.renderHz,
            seed: parsed.seed, windowMs: parsed.windowMs, skipSeconds: parsed.skipSeconds, tracker: tracker,
            resetEvery: parsed.resetEvery, resetTrackerOnly: parsed.resetTrackerOnly, pairsPerGroup: parsed.pairs,
            pause: parsed.pause, pairGap: parsed.pairGap, glowMode: (parsed.glowMode ?? .rhythm).rawValue
        )
        var notes = BeatEvaluation.notes + BeatEvaluation.glowNotes
        if parsed.resetEvery != nil { notes += BeatEvaluation.resumeNotes }
        if let pause = parsed.pause {
            notes.append(
                "pause: instead of the forced reset \(pause) s of silence (zeros) after every --reset-every seconds of audio, the "
                    + "audio continues where it stopped; annotations shifted by the pauses, 'resets' are the ends of the pauses"
            )
        }
        if let gap = parsed.pairGap { notes.append("pair gap: \(gap) s of silence (zeros) between A and B") }
        if parsed.pairs != nil {
            notes.append(
                "pairs: in every group the first 2N files of the split in list order, pairs (0,1), (2,3)...; each track clipped to "
                    + "\(EvalPairs.clipSeconds) s; 'B cold' = B alone, 'B after A' = A then B without reset, scored on B only "
                    + "(lockedCov, dark and flips from the start of B)"
            )
        }

        if parsed.json {
            let report = Report(
                settings: settings, notes: notes, splits: summaries, files: scores, warmSplits: warmSummaries, warmFiles: warmScores,
                failed: failures
            )
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
            var out = ["wave-eval | \(scores.count) \(unit) | " + describe(settings)]
            out += notes.map { "note: \($0)" }
            if parsed.perFile {
                out += ["", BeatEvaluation.perFileTable(scores)]
                if let warmScores {
                    out += ["", "B after A:", BeatEvaluation.perFileTable(warmScores)]
                }
            }
            for split in splits {
                guard let rows = summaries[split.rawValue] else { continue }
                let title = parsed.pairs == nil ? "split: \(split.rawValue)" : "split: \(split.rawValue), B cold"
                out += ["", BeatEvaluation.table(title: title, summaries: rows)]
                let resumeTitle = parsed.pause == nil ? "resume after forced resets" : "resume after silent pauses"
                if let resume = BeatEvaluation.resumeTable(title: "split: \(split.rawValue), \(resumeTitle)", summaries: rows) {
                    out += ["", resume]
                }
                if let warm = warmSummaries?[split.rawValue] {
                    out += ["", BeatEvaluation.table(title: "split: \(split.rawValue), B after A", summaries: warm)]
                }
                out += ["", BeatEvaluation.glowTable(title: "split: \(split.rawValue), glow", rows: rows.map { ($0.name, $0.glow) })]
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
            + "render=\(s.renderHz) Hz seed=\(s.seed) skip=\(s.skipSeconds) s "
            + (s.resetEvery.map { "reset-every=\($0) s" + (s.resetTrackerOnly ? " (tracker only) " : " ") } ?? "")
            + (s.pause.map { "pause=\($0) s " } ?? "") + (s.pairsPerGroup.map { "pairs=\($0)/group " } ?? "")
            + (s.pairGap.map { "pair-gap=\($0) s " } ?? "") + "glow-mode=\(s.glowMode) " + tracker
    }

    enum Outcome<Value: Sendable>: Sendable {
        case success(Value)
        case failure(String)
    }

    /// Задачи `0..<count` разбираются `jobs` потоками из общей очереди; результат лежит на месте своей
    /// задачи, поэтому порядок и числа не зависят от числа потоков.
    static func parallel<Value: Sendable>(
        count: Int, jobs: Int, _ body: @escaping @Sendable (Int) -> Outcome<Value>
    ) -> [Outcome<Value>] {
        let results = Mutex([Outcome<Value>?](repeating: nil, count: count))
        let next = Mutex(0)
        let done = Mutex(0)
        DispatchQueue.concurrentPerform(iterations: max(jobs, 1)) { _ in
            while true {
                let index = next.withLock { value -> Int in
                    defer { value += 1 }
                    return value
                }
                guard index < count else { return }
                let outcome = body(index)
                results.withLock { $0[index] = outcome }
                let finished = done.withLock { value -> Int in
                    value += 1
                    return value
                }
                if finished % 100 == 0 { log("wave-eval: \(finished)/\(count)\n") }
            }
        }
        return results.withLock { $0 }.map { $0 ?? .failure("not evaluated") }
    }

    /// Пара: B один и B после A, оба обрезаны до `EvalPairs.clipSeconds`.
    private static func evaluatePair(
        _ pair: EvalPairs.Pair, arguments: EvalArguments
    ) -> Outcome<(cold: BeatEvaluation.FileScore, warm: BeatEvaluation.FileScore)> {
        do {
            let first = try WAVReader.read(try Data(contentsOf: URL(fileURLWithPath: pair.first.wavPath)))
            let second = try WAVReader.read(try Data(contentsOf: URL(fileURLWithPath: pair.second.wavPath)))
            guard first.sampleRate == second.sampleRate else { return .failure("sample rates differ") }
            let rate = second.sampleRate
            let beats = BeatAnnotations.parse(try String(contentsOfFile: pair.second.annotationPath, encoding: .utf8))
            var a = EvalPairs.clip(first.samples, sampleRate: rate)
            if let gap = arguments.pairGap {
                a += [Float](repeating: 0, count: Int((gap * rate).rounded()))
            }
            let b = EvalPairs.clip(second.samples, sampleRate: rate)
            let firstDuration = Double(a.count) / rate
            let secondDuration = Double(b.count) / rate
            let secondBeats = beats.filter { $0 < secondDuration }
            guard secondBeats.count >= 2 else { return .failure("fewer than two annotated beats in B") }
            let options = BeatEvaluation.Options(window: arguments.windowMs / 1000, skipSeconds: arguments.skipSeconds)
            let name = (pair.second.wavPath as NSString).lastPathComponent
            let cold = OfflineBeatChain.run(samples: b, sampleRate: rate, config: arguments.chainConfig(forFile: name))
            let warm = OfflineBeatChain.run(samples: a + b, sampleRate: rate, config: arguments.chainConfig(forFile: pair.name))
            return .success((
                cold: BeatEvaluation.score(
                    result: cold, annotations: secondBeats, duration: secondDuration, options: options,
                    path: pair.second.wavPath, group: pair.second.group, heldout: pair.second.heldout
                ),
                warm: EvalPairs.scoreSecond(
                    result: warm, firstDuration: firstDuration, secondAnnotations: secondBeats, secondDuration: secondDuration,
                    options: options, path: pair.name, group: pair.second.group, heldout: pair.second.heldout
                )
            ))
        } catch {
            return .failure("\(error)")
        }
    }

    private static func evaluate(_ entry: EvalList.Entry, arguments: EvalArguments) -> Outcome<BeatEvaluation.FileScore> {
        do {
            let audio = try WAVReader.read(try Data(contentsOf: URL(fileURLWithPath: entry.wavPath)))
            let text = try String(contentsOfFile: entry.annotationPath, encoding: .utf8)
            let beats = BeatAnnotations.parse(text)
            guard beats.count >= 2 else { return .failure("fewer than two annotated beats") }
            let name = (entry.wavPath as NSString).lastPathComponent
            let options = BeatEvaluation.Options(window: arguments.windowMs / 1000, skipSeconds: arguments.skipSeconds)
            var samples = audio.samples
            var annotations = beats
            var cuts: [Double] = []
            if let pause = arguments.pause, let every = arguments.resetEvery {
                let paused = EvalPauses.insert(audio.samples, sampleRate: audio.sampleRate, every: every, length: pause)
                samples = paused.samples
                cuts = paused.cuts
                annotations = EvalPauses.shift(beats, cuts: cuts, length: pause)
            }
            var result = OfflineBeatChain.run(samples: samples, sampleRate: audio.sampleRate, config: arguments.chainConfig(forFile: name))
            if let pause = arguments.pause {
                result.resets = EvalPauses.resets(cuts: cuts, length: pause, states: result.states)
            }
            let duration = Double(samples.count) / audio.sampleRate
            return .success(
                BeatEvaluation.score(
                    result: result, annotations: annotations, duration: duration, options: options,
                    path: entry.wavPath, group: entry.group, heldout: entry.heldout
                )
            )
        } catch {
            return .failure("\(error)")
        }
    }
}
