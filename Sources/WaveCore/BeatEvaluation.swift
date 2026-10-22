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
        /// Вспышки, попавшие в окно (один к одному), из `flashCount`.
        public var matched: Int
        public var lockedFlashCount: Int
        public var lockedMatched: Int
        public var unlockedFlashCount: Int
        public var unlockedMatched: Int
        /// `nil`, если захвата со вспышками не было.
        public var lockedPrecision: Double?
        /// Точность вспышек без захвата; `nil`, если таких вспышек не было.
        public var unlockedPrecision: Double?
        public var precision: Double
        public var recall: Double
        public var f: Double
        /// Средний сдвиг вспышки от доли, мс (минус раньше); `nil`, если ни одна вспышка не попала в окно.
        public var meanOffsetMs: Double?
        /// Сумма и число сдвигов вспышек в окне отдельно для вспышек с захватом и без (для среднего по
        /// набору файлов с весом вспышки).
        public var offsetLockedSumMs: Double
        public var offsetLockedCount: Int
        public var offsetUnlockedSumMs: Double
        public var offsetUnlockedCount: Int
        public var cmlt: Double
        public var amlt: Double
        public var lockedCoverage: Double
        /// Первый захват, секунды от начала файла.
        public var lockTime: Double?
        public var tempoBPM: Double?
    }

    /// Слияние вспышек: идут по времени, каждая ближе `gap` к последней оставленной выпадает; если
    /// выпадающая с захватом, а оставленная без, остается вспышка с захватом.
    public static func dedupe(_ flashes: [OfflineBeatChain.Flash], gap: Double = dedupeGap) -> [OfflineBeatChain.Flash] {
        var kept: [OfflineBeatChain.Flash] = []
        for flash in flashes.sorted(by: { $0.time < $1.time }) {
            if let last = kept.last, flash.time - last.time < gap {
                if flash.locked, !last.locked { kept[kept.count - 1] = flash }
                continue
            }
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
        let unlockedTimes = flashes.filter { !$0.locked }.map(\.time)
        let window = options.window
        // Точность каждого вида считается отдельно против всех аннотаций (один к одному внутри вида).
        func matches(_ detections: [Double]) -> (precision: Double?, matched: Int) {
            guard !detections.isEmpty else { return (nil, 0) }
            let precision = BeatMetrics.fMeasure(detections: detections, annotations: audibleBeats, window: window).precision
            return (precision, Int((precision * Double(detections.count)).rounded()))
        }
        let locked = matches(lockedTimes)
        let unlocked = matches(unlockedTimes)
        let all = matches(times)
        let f = BeatMetrics.fMeasure(detections: times, annotations: audibleBeats, window: window)
        let offset = BeatMetrics.meanOffset(detections: times, annotations: audibleBeats, window: window)
        let lockedOffsets = BeatMetrics.offsets(detections: lockedTimes, annotations: audibleBeats, window: window)
        let unlockedOffsets = BeatMetrics.offsets(detections: unlockedTimes, annotations: audibleBeats, window: window)
        let continuity = BeatMetrics.continuity(detections: times, annotations: audibleBeats)
        let coverage = Self.coverage(states: result.states, from: skip, duration: duration)

        return FileScore(
            path: path, group: group, heldout: heldout, duration: duration, annotationCount: beats.count,
            flashCount: flashes.count, matched: all.matched, lockedFlashCount: lockedTimes.count,
            lockedMatched: locked.matched, unlockedFlashCount: unlockedTimes.count, unlockedMatched: unlocked.matched,
            lockedPrecision: locked.precision, unlockedPrecision: unlocked.precision,
            precision: f.precision, recall: f.recall, f: f.f, meanOffsetMs: offset.map { $0 * 1000 },
            offsetLockedSumMs: lockedOffsets.reduce(0, +) * 1000, offsetLockedCount: lockedOffsets.count,
            offsetUnlockedSumMs: unlockedOffsets.reduce(0, +) * 1000, offsetUnlockedCount: unlockedOffsets.count,
            cmlt: continuity.cmlt, amlt: continuity.amlt,
            lockedCoverage: coverage, lockTime: result.lockTime, tempoBPM: result.tempoBPM
        )
    }

    /// Доля времени от `from` до `duration` с захватом. Состояние, действовавшее в момент `from`,
    /// считается с этого момента.
    static func coverage(states: [OfflineBeatChain.State], from: Double, duration: Double) -> Double {
        guard from > 0 else { return BeatMetrics.lockedCoverage(states: states, duration: duration) }
        let ordered = states.sorted { $0.time < $1.time }
        var shifted: [OfflineBeatChain.State] = []
        if var current = ordered.last(where: { $0.time <= from }) {
            current.time = from
            shifted.append(current)
        }
        shifted += ordered.filter { $0.time > from }
        for index in shifted.indices { shifted[index].time -= from }
        return BeatMetrics.lockedCoverage(states: shifted, duration: duration - from)
    }

    /// Сводка по набору файлов: среднее по файлам (каждый файл весит одинаково).
    public struct Summary: Sendable, Equatable, Codable {
        public var name: String
        public var files: Int
        /// Сколько файлов имели вспышки при захвате (только они входят в `lockedPrecision`).
        public var lockedFiles: Int
        /// Среднее lockedPrecision по этим файлам; файлы без захвата в него не входят.
        public var lockedPrecision: Double?
        /// lockedPrecision по сумме вспышек всех файлов (основное число: файл с большим числом вспышек
        /// весит больше, файлы без захвата не входят, потому что вспышек у них нет).
        public var lockedPrecisionPooled: Double?
        /// Точность по всем вспышкам (с захватом и без), по сумме вспышек всех файлов.
        public var precisionPooled: Double?
        /// Точность вспышек без захвата по сумме вспышек; `nil`, если таких не было.
        public var unlockedPrecisionPooled: Double?
        public var f: Double
        /// Среднее по файлам точности и полноты (каждый файл весит одинаково).
        public var precision: Double
        public var recall: Double
        /// Среднее по файлам, у которых оно есть.
        public var meanOffsetMs: Double?
        /// Средний сдвиг вспышек с захватом и без по сумме вспышек в окне; `nil`, если таких нет.
        public var meanOffsetLockedMs: Double?
        public var meanOffsetUnlockedMs: Double?
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
        func sum(_ value: (FileScore) -> Int) -> Int { scores.reduce(0) { $0 + value($1) } }
        func ratio(_ matched: Int, _ total: Int) -> Double? { total == 0 ? nil : Double(matched) / Double(total) }
        func offset(_ total: Double, _ count: Int) -> Double? { count == 0 ? nil : total / Double(count) }
        return Summary(
            name: name, files: scores.count, lockedFiles: scores.filter { $0.lockedPrecision != nil }.count,
            lockedPrecision: optionalMean(scores.map(\.lockedPrecision)),
            lockedPrecisionPooled: ratio(sum(\.lockedMatched), sum(\.lockedFlashCount)),
            precisionPooled: ratio(sum(\.matched), sum(\.flashCount)),
            unlockedPrecisionPooled: ratio(sum(\.unlockedMatched), sum(\.unlockedFlashCount)),
            f: mean(scores.map(\.f)), precision: mean(scores.map(\.precision)), recall: mean(scores.map(\.recall)),
            meanOffsetMs: optionalMean(scores.map(\.meanOffsetMs)),
            meanOffsetLockedMs: offset(scores.reduce(0) { $0 + $1.offsetLockedSumMs }, sum(\.offsetLockedCount)),
            meanOffsetUnlockedMs: offset(scores.reduce(0) { $0 + $1.offsetUnlockedSumMs }, sum(\.offsetUnlockedCount)),
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
        "flashes clipped to time <= duration + latency, flashes closer than 50 ms merged (a locked flash wins a pair); annotations shifted onto the audible axis",
        "LPpool (headline) = locked flashes that hit a beat / all locked flashes, pooled over files; lockedFiles = files that had locked flashes at all",
        "lockedPrec = mean of per-file locked precision over those lockedFiles only: files that never lock are NOT in it (they show up only in lockedCov and in lockedFiles < files)",
        "prec / unlockedPrec: pooled precision over all flashes / over flashes under an unlocked schedule (one-to-one, window); each kind is matched on its own against all beats",
        "meanOff = mean of per-file mean offsets over all flashes; offLocked / offUnlocked = mean signed offset (ms) of the flashes inside the window, pooled over flashes",
        "F, CMLt, AMLt, lockedCov: means over files, every file weighs the same",
        "CMLt omits mir_eval's previous-beat-also-correct condition, so it is more lenient than mir_eval and not comparable to published numbers",
        "flashes lead the beat by design (BeatGlow.lead 15 ms): a negative meanOffset is expected",
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
        let heads = [
            "files", "lockedFiles", "LPpool", "lockedPrec", "prec", "unlockedPrec", "F", "meanOff", "offLocked",
            "offUnlocked", "AMLt", "CMLt", "lockedCov",
        ]
        lines.append(pad("group", width) + "  " + heads.map { right($0, max($0.count, 7)) }.joined(separator: " "))
        for row in summaries {
            let cells = [
                String(row.files), String(row.lockedFiles), fraction(row.lockedPrecisionPooled), fraction(row.lockedPrecision),
                fraction(row.precisionPooled), fraction(row.unlockedPrecisionPooled), fraction(row.f), milliseconds(row.meanOffsetMs),
                milliseconds(row.meanOffsetLockedMs), milliseconds(row.meanOffsetUnlockedMs), fraction(row.amlt),
                fraction(row.cmlt), fraction(row.lockedCoverage),
            ]
            lines.append(
                pad(row.name, width) + "  "
                    + zip(cells, heads).map { right($0, max($1.count, 7)) }.joined(separator: " ")
            )
        }
        return lines.joined(separator: "\n")
    }

    private static func milliseconds(_ value: Double?) -> String {
        value.map { String(format: "%+.1f", $0) } ?? "-"
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
