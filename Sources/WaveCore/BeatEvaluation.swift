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
/// - lockedCoverage: доля времени файла, на которой опубликован захват;
/// - longestDarkBeats: самая длинная серия размеченных долей подряд без вспышки (любой, с захватом или
///   без) в окне; longestDarkBeatsAfterLock: то же только по долям, слышимым после первого захвата
///   (без холодного старта); lockFlipsPerMinute и unlocks: смены захвата и его потери по причинам.
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
        /// Самая длинная серия размеченных долей подряд без вспышки в окне (темные доли).
        public var longestDarkBeats = 0
        /// То же по долям, слышимым не раньше первого захвата (`lockTime` плюс задержка вывода): темнота
        /// посреди песни без холодного старта. `nil`, если захвата не было.
        public var longestDarkBeatsAfterLock: Int?
        /// Смены захвата (появился или пропал) в минуту оцениваемого отрезка.
        public var lockFlipsPerMinute = 0.0
        /// Потери захвата по причинам.
        public var unlocks: [UnlockReason: Int] = [:]
        /// Возобновления после принудительных сбросов (`OfflineBeatChain.Config.resetInterval`); `nil` без них.
        public var resume: ResumeScore?
    }

    // MARK: Возобновление

    /// Сколько секунд после сброса считается точность возобновления.
    public static let resumeWindow = 2.0
    /// Сколько первых вспышек после сброса определяют, на «и» ли возобновился показ.
    public static let resumeFlashes = 4

    /// Возобновления после сбросов с памятью темпа (`BeatTracker.reset(keepTempo:)`): куда легли первые
    /// вспышки и как точны вспышки первых `resumeWindow` секунд. Считаются сбросы, после которых до конца
    /// файла есть `resumeWindow` секунд.
    public struct ResumeScore: Sendable, Equatable, Codable {
        public var resets = 0
        /// Сбросы, перед которыми трекер держал захват.
        public var lockedAtReset = 0
        /// Сбросы, после которых до следующего сброса (или конца) была хоть одна вспышка.
        public var withFlash = 0
        /// Первая вспышка после сброса на доле.
        public var firstOn = 0
        /// Все первые `resumeFlashes` вспышек (меньше, если раньше пришел следующий сброс или конец) на
        /// середине между долями: показ возобновился на «и».
        public var offBeat = 0
        /// Среди первых вспышек есть и на «и», и в другом месте.
        public var partlyOffBeat = 0
        /// Секунды от сброса до первой вспышки (на слышимой оси от слышимого момента сброса).
        public var delays: [Double] = []
        /// Вспышки первых `resumeWindow` секунд после всех сбросов и сколько из них попали в долю.
        public var flashes = 0
        public var matched = 0
        /// То же только после сбросов с захватом.
        public var lockedResetFlashes = 0
        public var lockedResetMatched = 0
        /// Вспышки с захватом в первые `resumeWindow` секунд после сбросов с захватом: быстрый новый захват
        /// по двум долям новой истории.
        public var relockedFlashes = 0
        public var relockedMatched = 0

        public init() {}

        /// Сумма двух счетов (задержки подряд).
        public mutating func add(_ other: ResumeScore) {
            resets += other.resets
            lockedAtReset += other.lockedAtReset
            withFlash += other.withFlash
            firstOn += other.firstOn
            offBeat += other.offBeat
            partlyOffBeat += other.partlyOffBeat
            delays += other.delays
            flashes += other.flashes
            matched += other.matched
            lockedResetFlashes += other.lockedResetFlashes
            lockedResetMatched += other.lockedResetMatched
            relockedFlashes += other.relockedFlashes
            relockedMatched += other.relockedMatched
        }

        /// Медиана задержки первой вспышки; `nil` без вспышек.
        public var medianDelay: Double? { BeatMetrics.percentile(delays, 0.5) }
    }

    /// Счет возобновлений прогона с принудительными сбросами (`result.resets`) против аннотаций файла
    /// `annotations` (моменты файла) длиной `duration` секунд. Вспышки сливаются как в `score`. Место
    /// вспышки по `BeatMetrics.place`, точность один к одному в окне `window`.
    public static func resume(
        result: OfflineBeatChain.Result, annotations: [Double], duration: Double, window: Double
    ) -> ResumeScore {
        let latency = result.outputLatency
        let beats = result.audible(annotations.filter { $0 <= duration }).sorted()
        let flashes = dedupe(result.flashes.filter { $0.time <= duration + latency })
        let resets = result.resets.sorted { $0.time < $1.time }
        var score = ResumeScore()
        func precisionCount(_ times: [Double], from: Double, to: Double) -> Int {
            guard !times.isEmpty else { return 0 }
            let near = beats.filter { $0 >= from - window && $0 <= to + window }
            let precision = BeatMetrics.fMeasure(detections: times, annotations: near, window: window).precision
            return Int((precision * Double(times.count)).rounded())
        }
        for (index, reset) in resets.enumerated() where reset.time + resumeWindow <= duration {
            let start = reset.time + latency
            let next = index + 1 < resets.count ? resets[index + 1].time + latency : duration + latency
            score.resets += 1
            if reset.locked { score.lockedAtReset += 1 }
            let span = flashes.filter { $0.time > start && $0.time < next }
            if let first = span.first {
                score.withFlash += 1
                score.delays.append(first.time - start)
                let places = span.prefix(resumeFlashes).map { BeatMetrics.place(of: $0.time, beats: beats, window: window) }
                if places.first == .on { score.firstOn += 1 }
                let halves = places.filter { $0 == .half }.count
                if halves == places.count {
                    score.offBeat += 1
                } else if halves > 0 {
                    score.partlyOffBeat += 1
                }
            }
            let end = min(start + resumeWindow, next)
            let early = span.filter { $0.time < end }
            let times = early.map(\.time)
            let matched = precisionCount(times, from: start, to: end)
            score.flashes += times.count
            score.matched += matched
            if reset.locked {
                score.lockedResetFlashes += times.count
                score.lockedResetMatched += matched
                let locked = early.filter(\.locked).map(\.time)
                score.relockedFlashes += locked.count
                score.relockedMatched += precisionCount(locked, from: start, to: end)
            }
        }
        return score
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
        let lockChanges = BeatMetrics.lockChanges(states: result.states, from: skip, through: duration)
        let span = duration - skip
        // `lockTime` это момент публикации по часам хоста, доли на слышимой оси: доля после захвата
        // слышна не раньше `lockTime + latency`.
        let darkAfterLock = result.lockTime.map { lock in
            BeatMetrics.longestDarkRun(detections: times, annotations: audibleBeats.filter { $0 >= lock + latency }, window: window)
        }

        return FileScore(
            path: path, group: group, heldout: heldout, duration: duration, annotationCount: beats.count,
            flashCount: flashes.count, matched: all.matched, lockedFlashCount: lockedTimes.count,
            lockedMatched: locked.matched, unlockedFlashCount: unlockedTimes.count, unlockedMatched: unlocked.matched,
            lockedPrecision: locked.precision, unlockedPrecision: unlocked.precision,
            precision: f.precision, recall: f.recall, f: f.f, meanOffsetMs: offset.map { $0 * 1000 },
            offsetLockedSumMs: lockedOffsets.reduce(0, +) * 1000, offsetLockedCount: lockedOffsets.count,
            offsetUnlockedSumMs: unlockedOffsets.reduce(0, +) * 1000, offsetUnlockedCount: unlockedOffsets.count,
            cmlt: continuity.cmlt, amlt: continuity.amlt,
            lockedCoverage: coverage, lockTime: result.lockTime, tempoBPM: result.tempoBPM,
            longestDarkBeats: BeatMetrics.longestDarkRun(detections: times, annotations: audibleBeats, window: window),
            longestDarkBeatsAfterLock: darkAfterLock,
            lockFlipsPerMinute: span > 0 ? Double(lockChanges.changes) * 60 / span : 0, unlocks: lockChanges.unlocks,
            resume: result.resets.isEmpty ? nil : resume(result: result, annotations: annotations, duration: duration, window: window)
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
        /// Файлы, где захват в основном мимо долей: не меньше `wrongLockMinFlashes` вспышек при захвате и
        /// точность захвата ниже `wrongLockPrecision`. Уверенное свечение на «и» целыми кусками песни.
        public var wrongLockFiles: Int
        /// Вспышки при захвате мимо долей в этих файлах.
        public var wrongLockFlashes: Int
        /// Медиана и 90-й процентиль самой длинной темной серии файла (ближайший ранг по файлам), долей;
        /// 0 без файлов.
        public var darkRunMedian: Double
        public var darkRunP90: Double
        /// Медиана и 90-й процентиль `longestDarkBeatsAfterLock` по `darkAfterLockFiles` файлам, у которых
        /// был захват (ближайший ранг); 0 без таких файлов. Реже захватывать значит выкинуть файлы из
        /// этого числа: смотреть вместе с `darkAfterLockFiles`, recall и lockedCov.
        public var darkRunAfterLockMedian: Double
        public var darkRunAfterLockP90: Double
        public var darkAfterLockFiles: Int
        /// Среднее по файлам смен захвата в минуту.
        public var lockFlipsPerMinute: Double
        /// Потери захвата по причинам, сумма по файлам.
        public var unlocks: [UnlockReason: Int]
        /// Сумма возобновлений по файлам; `nil`, если сбросов не было.
        public var resume: ResumeScore?
    }

    public static let wrongLockMinFlashes = 10
    public static let wrongLockPrecision = 0.5

    /// Файл с захватом в основном мимо долей (см. `Summary.wrongLockFiles`).
    public static func isWrongLock(_ score: FileScore) -> Bool {
        score.lockedFlashCount >= wrongLockMinFlashes
            && Double(score.lockedMatched) < wrongLockPrecision * Double(score.lockedFlashCount)
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
        let afterLock = scores.compactMap(\.longestDarkBeatsAfterLock).map { Double($0) }
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
            lockedCoverage: mean(scores.map(\.lockedCoverage)),
            wrongLockFiles: scores.filter(isWrongLock).count,
            wrongLockFlashes: scores.filter(isWrongLock).reduce(0) { $0 + $1.lockedFlashCount - $1.lockedMatched },
            darkRunMedian: BeatMetrics.percentile(scores.map { Double($0.longestDarkBeats) }, 0.5) ?? 0,
            darkRunP90: BeatMetrics.percentile(scores.map { Double($0.longestDarkBeats) }, 0.9) ?? 0,
            darkRunAfterLockMedian: BeatMetrics.percentile(afterLock, 0.5) ?? 0,
            darkRunAfterLockP90: BeatMetrics.percentile(afterLock, 0.9) ?? 0,
            darkAfterLockFiles: afterLock.count,
            lockFlipsPerMinute: mean(scores.map(\.lockFlipsPerMinute)),
            unlocks: scores.reduce(into: [:]) { total, score in total.merge(score.unlocks, uniquingKeysWith: +) },
            resume: scores.reduce(nil) { (total: ResumeScore?, score) in
                guard let resume = score.resume else { return total }
                var sum = total ?? ResumeScore()
                sum.add(resume)
                return sum
            }
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
        "wrongLock = files with >= 10 locked flashes and locked precision < 0.5 (locked mostly off the beat); wrongLockFl = their locked flashes that miss",
        "CMLt omits mir_eval's previous-beat-also-correct condition, so it is more lenient than mir_eval and not comparable to published numbers",
        "flashes lead the beat by design (BeatGlow.lead 15 ms): a negative meanOffset is expected",
        "recall = mean over files of annotated beats matched one-to-one by a flash (beat coverage)",
        "dark beat = annotated beat with no flash (rise above 0.2, locked or not) within the window; dark50 / dark90 = median / 90th percentile (nearest rank) over files of the longest run of dark beats in a file",
        "darkL50 / darkL90 = the same over beats heard after the file's first lock only (no cold start), over files that locked (darkAfterLockFiles in JSON); locking fewer files drops them from it, read with recall and lockedCov",
        "flips/min = lock changes (gained or lost) per minute, mean over files; unlocks t/p/m = lock losses by tempo switch / phase jump / misses, summed over files (reset never happens offline)",
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
            "offUnlocked", "AMLt", "CMLt", "lockedCov", "wrongLock", "wrongLockFl", "recall", "dark50", "dark90",
            "darkL50", "darkL90", "flips/min", "unlocks t/p/m",
        ]
        lines.append(pad("group", width) + "  " + heads.map { right($0, max($0.count, 7)) }.joined(separator: " "))
        for row in summaries {
            let cells = [
                String(row.files), String(row.lockedFiles), fraction(row.lockedPrecisionPooled), fraction(row.lockedPrecision),
                fraction(row.precisionPooled), fraction(row.unlockedPrecisionPooled), fraction(row.f), milliseconds(row.meanOffsetMs),
                milliseconds(row.meanOffsetLockedMs), milliseconds(row.meanOffsetUnlockedMs), fraction(row.amlt),
                fraction(row.cmlt), fraction(row.lockedCoverage), String(row.wrongLockFiles), String(row.wrongLockFlashes),
                fraction(row.recall), String(format: "%.0f", row.darkRunMedian), String(format: "%.0f", row.darkRunP90),
                row.darkAfterLockFiles == 0 ? "-" : String(format: "%.0f", row.darkRunAfterLockMedian),
                row.darkAfterLockFiles == 0 ? "-" : String(format: "%.0f", row.darkRunAfterLockP90),
                String(format: "%.2f", row.lockFlipsPerMinute), unlockCounts(row.unlocks),
            ]
            lines.append(
                pad(row.name, width) + "  "
                    + zip(cells, heads).map { right($0, max($1.count, 7)) }.joined(separator: " ")
            )
        }
        return lines.joined(separator: "\n")
    }

    public static let resumeNotes = [
        "resume: forced StreamAnalyzer.reset() + BeatTracker.reset(keepTempo: true) every --reset-every seconds of stream, audio continues; resets with 2 s of file left are scored",
        "resume columns: lockedAt = tracker locked before the reset; flashed = a flash before the next reset; firstOn = first flash on a beat; offBeat = all of the first 4 flashes on the half-beat (fewer if the next reset comes first); partly = some of them on the half-beat",
        "delay50 = median seconds from the reset to the first flash; prec2s = precision of all flashes in the 2 s after every reset; lockedRst = the same after resets that were locked; relockLP = locked flashes in those 2 s after locked resets",
    ]

    /// Таблица возобновлений по строкам сводки, у которых они есть; `nil`, если сбросов не было.
    public static func resumeTable(title: String, summaries: [Summary]) -> String? {
        resumeTable(title: title, rows: summaries.compactMap { row in row.resume.map { (row.name, $0) } })
    }

    /// Таблица возобновлений по именованным строкам; `nil` без строк.
    public static func resumeTable(title: String, rows: [(String, ResumeScore)]) -> String? {
        guard !rows.isEmpty else { return nil }
        let width = max(8, rows.map(\.0.count).max() ?? 0)
        let heads = ["resets", "lockedAt", "flashed", "firstOn", "offBeat", "partly", "delay50", "prec2s", "n", "lockedRst", "n", "relockLP", "n"]
        var lines = [title, pad("group", width) + "  " + heads.map { right($0, max($0.count, 7)) }.joined(separator: " ")]
        for (name, resume) in rows {
            func ratio(_ matched: Int, _ total: Int) -> String {
                total == 0 ? "-" : String(format: "%.3f", Double(matched) / Double(total))
            }
            let cells = [
                String(resume.resets), String(resume.lockedAtReset), String(resume.withFlash), String(resume.firstOn),
                String(resume.offBeat), String(resume.partlyOffBeat), resume.medianDelay.map { String(format: "%.2f", $0) } ?? "-",
                ratio(resume.matched, resume.flashes), String(resume.flashes),
                ratio(resume.lockedResetMatched, resume.lockedResetFlashes), String(resume.lockedResetFlashes),
                ratio(resume.relockedMatched, resume.relockedFlashes), String(resume.relockedFlashes),
            ]
            lines.append(pad(name, width) + "  " + zip(cells, heads).map { right($0, max($1.count, 7)) }.joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }

    /// Потери захвата `t/p/m`: смена темпа, скачок фазы, промахи.
    private static func unlockCounts(_ unlocks: [UnlockReason: Int]) -> String {
        [UnlockReason.tempoSwitch, .phaseJump, .misses].map { String(unlocks[$0] ?? 0) }.joined(separator: "/")
    }

    private static func milliseconds(_ value: Double?) -> String {
        value.map { String(format: "%+.1f", $0) } ?? "-"
    }

    /// Таблица по файлам.
    public static func perFileTable(_ scores: [FileScore]) -> String {
        let heads = ["lockedPrec", "F", "meanOff ms", "AMLt", "CMLt", "lockedCov", "recall", "dark", "darkL", "flips/min", "t/p/m"]
        var lines = [pad("file", 26) + " " + pad("group", 10) + " " + heads.map { right($0, 10) }.joined(separator: " ")]
        for score in scores {
            let cells = [
                fraction(score.lockedPrecision), fraction(score.f),
                score.meanOffsetMs.map { String(format: "%+.1f", $0) } ?? "-", fraction(score.amlt),
                fraction(score.cmlt), fraction(score.lockedCoverage), fraction(score.recall), String(score.longestDarkBeats),
                score.longestDarkBeatsAfterLock.map(String.init) ?? "-",
                String(format: "%.2f", score.lockFlipsPerMinute), unlockCounts(score.unlocks),
            ]
            let name = (score.path as NSString).lastPathComponent
            lines.append(pad(name, 26) + " " + pad(score.group, 10) + " " + cells.map { right($0, 10) }.joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }
}
