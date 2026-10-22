import Foundation

/// Список файлов `wave-eval`: строки `<wav>\t<аннотация>\t<группа>[\t<tune|heldout>]`. Пустые строки и
/// строки с `#` в начале пропускаются. Без четвертой колонки файл считается `tune`.
public enum EvalList {
    public struct Entry: Sendable, Equatable {
        public var wavPath: String
        public var annotationPath: String
        public var group: String
        /// `true` для отложенной выборки (`heldout`), которую не трогают при подборе параметров.
        public var heldout: Bool

        public init(wavPath: String, annotationPath: String, group: String, heldout: Bool) {
            self.wavPath = wavPath
            self.annotationPath = annotationPath
            self.group = group
            self.heldout = heldout
        }
    }

    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        case malformed(line: Int)
        case unknownSplit(line: Int, value: String)

        public var description: String {
            switch self {
            case .malformed(let line): "list line \(line): expected 3 or 4 tab-separated fields"
            case .unknownSplit(let line, let value): "list line \(line): split '\(value)' is not tune or heldout"
            }
        }
    }

    public static func parse(_ text: String) throws -> [Entry] {
        var entries: [Entry] = []
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for (offset, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = rawLine.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3 || fields.count == 4, !fields[0].isEmpty, !fields[1].isEmpty, !fields[2].isEmpty
            else { throw Error.malformed(line: offset + 1) }
            var heldout = false
            if fields.count == 4 {
                switch fields[3].trimmingCharacters(in: .whitespaces) {
                case "tune": heldout = false
                case "heldout": heldout = true
                default: throw Error.unknownSplit(line: offset + 1, value: fields[3])
                }
            }
            entries.append(Entry(wavPath: fields[0], annotationPath: fields[1], group: fields[2], heldout: heldout))
        }
        return entries
    }

    /// Записи нужной выборки, в порядке списка, не больше `limit`.
    public static func select(_ entries: [Entry], split: EvalArguments.Split, limit: Int?) -> [Entry] {
        let chosen = entries.filter {
            switch split {
            case .all: true
            case .tune: !$0.heldout
            case .heldout: $0.heldout
            }
        }
        if let limit { return Array(chosen.prefix(limit)) }
        return chosen
    }
}

/// Файл аннотаций долей: по строке на долю, первая колонка секунды (GTZAN, Ballroom), остальное
/// (номер доли в такте) игнорируется.
public enum BeatAnnotations {
    /// Времена по возрастанию. Строки без числа в первой колонке, пустые и с `#` пропускаются;
    /// отрицательные и нечисловые времена отбрасываются.
    public static func parse(_ text: String) -> [Double] {
        var times: [Double] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let first = line.split(whereSeparator: { $0 == "\t" || $0 == " " || $0 == "," }).first
            guard let first, let time = Double(first), time.isFinite, time >= 0 else { continue }
            times.append(time)
        }
        return times.sorted()
    }
}

/// Оценка одного файла и сводка по группам.
///
/// Что именно считается (все числа на слышимой оси, см. `BeatMetrics`):
/// - вспышки обрезаются до `time <= длительность + задержка` (цепочка рендерит хвост 0.5 с), потом
///   сливаются вспышки ближе `dedupeGap` друг к другу (онсет и предсказание у одной доли это одна
///   вспышка для глаза; без слияния вторая считалась бы промахом);
/// - аннотации файла сдвигаются на задержку вывода (`Result.audible`);
/// - lockedPrecision: доля вспышек при захвате, попавших в окно (один к одному);
/// - F, meanOffset и непрерывность: по всем вспышкам;
/// - lockedCoverage: доля времени файла, на которой опубликован захват.
public enum BeatEvaluation {
    /// Вспышки ближе этого друг к другу (секунды) считаются одной.
    public static let dedupeGap = 0.05

    public struct Options: Sendable, Equatable {
        /// Окно совпадения, секунды.
        public var window = 0.07
        /// Сколько первых секунд файла не считать.
        public var skipSeconds = 0.0

        public init(window: Double = 0.07, skipSeconds: Double = 0) {
            self.window = window
            self.skipSeconds = skipSeconds
        }
    }

    public struct FileScore: Sendable, Equatable, Codable {
        public var path: String
        public var group: String
        public var heldout: Bool
        public var duration: Double
        public var annotationCount: Int
        /// Вспышек после обрезки и слияния.
        public var flashCount: Int
        public var lockedFlashCount: Int
        public var lockedMatched: Int
        /// `nil`, если захвата со вспышками не было.
        public var lockedPrecision: Double?
        public var precision: Double
        public var recall: Double
        public var f: Double
        /// Средний сдвиг вспышки от доли, мс (минус раньше); `nil`, если ни одна вспышка не попала в окно.
        public var meanOffsetMs: Double?
        public var cmlt: Double
        public var amlt: Double
        public var lockedCoverage: Double
        /// Первый захват, секунды от начала файла.
        public var lockTime: Double?
        public var tempoBPM: Double?
    }

    /// Слияние вспышек: идут по времени, каждая ближе `gap` к последней оставленной выпадает.
    public static func dedupe(_ flashes: [OfflineBeatChain.Flash], gap: Double = dedupeGap) -> [OfflineBeatChain.Flash] {
        var kept: [OfflineBeatChain.Flash] = []
        for flash in flashes.sorted(by: { $0.time < $1.time }) {
            if let last = kept.last, flash.time - last.time < gap { continue }
            kept.append(flash)
        }
        return kept
    }

    /// Оценка прогона цепочки на файле длиной `duration` секунд с аннотациями `annotations` (моменты
    /// файла, не слышимые).
    public static func score(
        result: OfflineBeatChain.Result, annotations: [Double], duration: Double, options: Options,
        path: String, group: String, heldout: Bool
    ) -> FileScore {
        let latency = result.outputLatency
        let skip = options.skipSeconds
        let beats = annotations.filter { $0 >= skip && $0 <= duration }
        let audibleBeats = result.audible(beats)
        // Начало отсекается с запасом на окно, чтобы вспышка чуть раньше первой оцениваемой доли не пропала.
        let from = skip > 0 ? skip + latency - options.window : -Double.infinity
        let clipped = result.flashes.filter { $0.time <= duration + latency && $0.time >= from }
        let flashes = dedupe(clipped)
        let times = flashes.map(\.time)

        let lockedTimes = flashes.filter(\.locked).map(\.time)
        let lockedPrecision = BeatMetrics.lockedPrecision(
            flashes: flashes, annotations: audibleBeats, window: options.window
        )
        let lockedMatched = lockedPrecision.map { Int(($0 * Double(lockedTimes.count)).rounded()) } ?? 0
        let f = BeatMetrics.fMeasure(detections: times, annotations: audibleBeats, window: options.window)
        let offset = BeatMetrics.meanOffset(detections: times, annotations: audibleBeats, window: options.window)
        let continuity = BeatMetrics.continuity(detections: times, annotations: audibleBeats)
        let coverageStates = result.states.filter { $0.time >= skip }
        let coverage = BeatMetrics.lockedCoverage(states: coverageStates, duration: duration)

        return FileScore(
            path: path, group: group, heldout: heldout, duration: duration, annotationCount: beats.count,
            flashCount: flashes.count, lockedFlashCount: lockedTimes.count, lockedMatched: lockedMatched,
            lockedPrecision: lockedPrecision, precision: f.precision, recall: f.recall, f: f.f,
            meanOffsetMs: offset.map { $0 * 1000 }, cmlt: continuity.cmlt, amlt: continuity.amlt,
            lockedCoverage: coverage, lockTime: result.lockTime, tempoBPM: result.tempoBPM
        )
    }

    /// Сводка по набору файлов: среднее по файлам (каждый файл весит одинаково).
    public struct Summary: Sendable, Equatable, Codable {
        public var name: String
        public var files: Int
        /// Среднее lockedPrecision по файлам, у которых были вспышки при захвате.
        public var lockedPrecision: Double?
        /// Сколько файлов вошло в `lockedPrecision`.
        public var lockedFiles: Int
        /// lockedPrecision по сумме вспышек всех файлов (файлы с большим числом вспышек весят больше).
        public var lockedPrecisionPooled: Double?
        public var f: Double
        public var precision: Double
        public var recall: Double
        /// Среднее по файлам, у которых оно есть.
        public var meanOffsetMs: Double?
        public var cmlt: Double
        public var amlt: Double
        public var lockedCoverage: Double
    }

    public static func summarize(name: String, scores: [FileScore]) -> Summary {
        func mean(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }
        func optionalMean(_ values: [Double?]) -> Double? {
            let present = values.compactMap { $0 }
            return present.isEmpty ? nil : mean(present)
        }
        let lockedFlashes = scores.reduce(0) { $0 + $1.lockedFlashCount }
        let lockedMatched = scores.reduce(0) { $0 + $1.lockedMatched }
        return Summary(
            name: name, files: scores.count,
            lockedPrecision: optionalMean(scores.map(\.lockedPrecision)),
            lockedFiles: scores.filter { $0.lockedPrecision != nil }.count,
            lockedPrecisionPooled: lockedFlashes == 0 ? nil : Double(lockedMatched) / Double(lockedFlashes),
            f: mean(scores.map(\.f)), precision: mean(scores.map(\.precision)), recall: mean(scores.map(\.recall)),
            meanOffsetMs: optionalMean(scores.map(\.meanOffsetMs)),
            cmlt: mean(scores.map(\.cmlt)), amlt: mean(scores.map(\.amlt)),
            lockedCoverage: mean(scores.map(\.lockedCoverage))
        )
    }

    /// Строки отчета: группы по алфавиту, затем объединения (в порядке заданных), затем итог.
    public static func summaries(
        scores: [FileScore], unions: [EvalArguments.Union], total: String = "TOTAL"
    ) -> [Summary] {
        var rows: [Summary] = []
        for group in Set(scores.map(\.group)).sorted() {
            rows.append(summarize(name: group, scores: scores.filter { $0.group == group }))
        }
        for union in unions {
            let members = Set(union.groups)
            let chosen = scores.filter { members.contains($0.group) }
            if !chosen.isEmpty { rows.append(summarize(name: union.name, scores: chosen)) }
        }
        rows.append(summarize(name: total, scores: scores))
        return rows
    }

    /// Выборка файлов по `split`; `all` берет все.
    public static func filter(_ scores: [FileScore], split: EvalArguments.Split) -> [FileScore] {
        switch split {
        case .all: scores
        case .tune: scores.filter { !$0.heldout }
        case .heldout: scores.filter(\.heldout)
        }
    }

    // MARK: Текст

    public static let notes = [
        "flashes clipped to time <= duration + latency, flashes closer than 50 ms merged; annotations shifted onto the audible axis",
        "lockedPrecision: share of flashes under a locked schedule that hit a beat (one-to-one, window); F, meanOffset, CMLt, AMLt: all flashes",
        "CMLt omits mir_eval's previous-beat-also-correct condition, so it is more lenient than mir_eval and not comparable to published numbers",
        "flashes lead the beat by design (BeatGlow.lead 15 ms): a negative meanOffset is expected",
        "group rows are means over files (every file weighs the same); LPpool pools flashes over files",
    ]

    private static func fraction(_ value: Double?) -> String {
        value.map { String(format: "%.3f", $0) } ?? "-"
    }

    private static func pad(_ text: String, _ count: Int) -> String {
        text.count >= count ? text : text + String(repeating: " ", count: count - text.count)
    }

    private static func right(_ text: String, _ count: Int) -> String {
        text.count >= count ? text : String(repeating: " ", count: count - text.count) + text
    }

    /// Таблица сводок с заголовком `title`.
    public static func table(title: String, summaries: [Summary]) -> String {
        let width = max(8, summaries.map(\.name.count).max() ?? 0)
        var lines = [title]
        let heads = ["files", "lockedPrec", "LPpool", "F", "meanOff ms", "AMLt", "CMLt", "lockedCov"]
        lines.append(pad("group", width) + "  " + heads.map { right($0, 10) }.joined(separator: " "))
        for row in summaries {
            let cells = [
                String(row.files), fraction(row.lockedPrecision), fraction(row.lockedPrecisionPooled), fraction(row.f),
                row.meanOffsetMs.map { String(format: "%+.1f", $0) } ?? "-", fraction(row.amlt), fraction(row.cmlt),
                fraction(row.lockedCoverage),
            ]
            lines.append(pad(row.name, width) + "  " + cells.map { right($0, 10) }.joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }

    /// Таблица по файлам.
    public static func perFileTable(_ scores: [FileScore]) -> String {
        let heads = ["lockedPrec", "F", "meanOff ms", "AMLt", "CMLt", "lockedCov"]
        var lines = [pad("file", 26) + " " + pad("group", 10) + " " + heads.map { right($0, 10) }.joined(separator: " ")]
        for score in scores {
            let cells = [
                fraction(score.lockedPrecision), fraction(score.f),
                score.meanOffsetMs.map { String(format: "%+.1f", $0) } ?? "-", fraction(score.amlt),
                fraction(score.cmlt), fraction(score.lockedCoverage),
            ]
            let name = (score.path as NSString).lastPathComponent
            lines.append(pad(name, 26) + " " + pad(score.group, 10) + " " + cells.map { right($0, 10) }.joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }
}
