import Foundation
import WaveCore

/// `wave-eval --owner <owner.tsv>`: записи ритма владельца с сетками долей (`OwnerEvaluation`). Каждая
/// запись прогоняется как `--replay`, итог по записям, группам, объединениям и всем вместе.
enum Owner {
    struct Report: Codable {
        struct Settings: Codable {
            var seed: UInt64
            var windowMs: Double
            var loop: Int
            var resetEvery: Double?
            var resetTrackerOnly: Bool
            var tracker: [String: Double]
        }

        var settings: Settings
        var notes: [String]
        var recordings: [OwnerEvaluation.Score]
        var totals: [OwnerEvaluation.Score]
        var failed: [WaveEval.Failure]
    }

    static func run(_ parsed: EvalArguments) -> Int32 {
        let entries: [EvalList.Entry]
        do {
            entries = try EvalList.parse(try String(contentsOfFile: parsed.listPath, encoding: .utf8))
            try parsed.validateUnions(knownGroups: Set(entries.map(\.group)))
        } catch {
            WaveEval.log("wave-eval: \(error)\n")
            return 66
        }
        guard !entries.isEmpty else {
            WaveEval.log("wave-eval: no recordings in the list\n")
            return 66
        }
        let started = Date()
        let jobs = min(parsed.jobs ?? ProcessInfo.processInfo.activeProcessorCount, entries.count)
        let outcomes = WaveEval.parallel(count: entries.count, jobs: jobs) { evaluate(entries[$0], arguments: parsed) }
        var scores: [OwnerEvaluation.Score] = []
        var failures: [WaveEval.Failure] = []
        for (entry, outcome) in zip(entries, outcomes) {
            switch outcome {
            case .success(let score): scores.append(score)
            case .failure(let message): failures.append(WaveEval.Failure(path: entry.wavPath, error: message))
            }
        }
        WaveEval.log(
            String(format: "wave-eval: %d recordings, %d failed, %d jobs, %.1f s\n", entries.count, failures.count, jobs, Date().timeIntervalSince(started))
        )
        for failure in failures { WaveEval.log("wave-eval: \(failure.path): \(failure.error)\n") }
        guard !scores.isEmpty else { return 1 }

        let totals = OwnerEvaluation.totals(scores, unions: parsed.unions)
        var tracker: [String: Double] = [:]
        for override in parsed.overrides { tracker[override.name] = override.value }
        let settings = Report.Settings(
            seed: parsed.seed, windowMs: parsed.windowMs, loop: parsed.loop, resetEvery: parsed.resetEvery,
            resetTrackerOnly: parsed.resetTrackerOnly, tracker: tracker
        )
        var notes = OwnerEvaluation.notes
        if parsed.resetEvery != nil { notes += BeatEvaluation.resumeNotes }
        if parsed.json {
            let report = Report(settings: settings, notes: notes, recordings: scores, totals: totals, failed: failures)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            do {
                FileHandle.standardOutput.write(try encoder.encode(report))
                FileHandle.standardOutput.write(Data("\n".utf8))
            } catch {
                WaveEval.log("wave-eval: \(error)\n")
                return 70
            }
        } else {
            let trackerText = tracker.isEmpty
                ? "tracker defaults"
                : "tracker " + tracker.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
            var out = [
                "wave-eval --owner | \(scores.count) recordings | window=\(parsed.windowMs) ms seed=\(parsed.seed) loop=\(parsed.loop) "
                    + (parsed.resetEvery.map { "reset-every=\($0) s" + (parsed.resetTrackerOnly ? " (tracker only) " : " ") } ?? "") + trackerText,
            ]
            out += notes.map { "note: \($0)" }
            out += ["", OwnerEvaluation.table(recordings: scores, totals: totals)]
            let resumeRows = (scores + totals).compactMap { score in score.resume.map { (score.name, $0) } }
            if let resume = BeatEvaluation.resumeTable(title: "resume after forced resets", rows: resumeRows) {
                out += ["", resume]
            }
            if !failures.isEmpty {
                out += ["", "failed recordings (\(failures.count)):"] + failures.map { "  \($0.path): \($0.error)" }
            }
            print(out.joined(separator: "\n"))
        }
        return failures.isEmpty ? 0 : 2
    }

    /// Запись из строки списка: в первой колонке JSON записи, WAV рядом, во второй файл долей.
    private static func evaluate(_ entry: EvalList.Entry, arguments: EvalArguments) -> WaveEval.Outcome<OwnerEvaluation.Score> {
        do {
            let log = try RhythmLog.decode(try Data(contentsOf: URL(fileURLWithPath: entry.wavPath)))
            let audio = try WAVReader.read(try Data(contentsOf: URL(fileURLWithPath: RhythmLog.wavPath(forLogPath: entry.wavPath))))
            guard audio.sampleRate == log.meta.sampleRate else {
                return .failure("WAV at \(audio.sampleRate) Hz, log at \(log.meta.sampleRate) Hz")
            }
            guard !audio.samples.isEmpty else { return .failure("empty audio") }
            let grid = BeatAnnotations.parse(try String(contentsOfFile: entry.annotationPath, encoding: .utf8))
            guard grid.count >= 2 else { return .failure("fewer than two grid beats") }
            let seconds = Double(audio.samples.count) / audio.sampleRate
            let samples = OwnerEvaluation.looped(audio.samples, count: arguments.loop)
            let result = OfflineBeatChain.run(samples: samples, sampleRate: audio.sampleRate, config: arguments.ownerConfig(for: log.meta))
            let name = ((entry.wavPath as NSString).lastPathComponent as NSString).deletingPathExtension
            return .success(
                OwnerEvaluation.score(
                    result: result, grid: OwnerEvaluation.loopedGrid(grid, duration: seconds, count: arguments.loop),
                    audioSeconds: Double(samples.count) / audio.sampleRate, syncOffset: log.meta.syncOffset,
                    window: arguments.windowMs / 1000, name: name, group: entry.group
                )
            )
        } catch {
            return .failure("\(error)")
        }
    }
}
