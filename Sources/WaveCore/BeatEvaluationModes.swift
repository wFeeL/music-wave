import Foundation

/// Пары треков для `wave-eval --pairs`: трек B сразу после трека A без сброса (смена секции, системный
/// источник без ключа трека, перемотка), против того же B с холодного старта. Считается только B.
/// Логика скриптов разбора 1.2.1 (`mkpairs.py`, `evalpairs.py`): в каждой группе первые `2n` файлов
/// выборки по порядку списка, пары (0, 1), (2, 3) и дальше, оба трека обрезаны до `clipSeconds`.
public enum EvalPairs {
    /// Длина каждого трека пары, секунды.
    public static let clipSeconds = 29.5

    public struct Pair: Sendable, Equatable {
        /// Трек, который играл раньше.
        public var first: EvalList.Entry
        /// Трек, который оценивается.
        public var second: EvalList.Entry

        public init(first: EvalList.Entry, second: EvalList.Entry) {
            self.first = first
            self.second = second
        }

        /// Имя пары: `A+B` по именам файлов без расширения.
        public var name: String {
            func stem(_ path: String) -> String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
            return stem(first.wavPath) + "+" + stem(second.wavPath)
        }
    }

    /// До `perGroup` пар в каждой группе: группы в порядке первого появления в списке, внутри группы
    /// файлы по порядку. Группа, где файлов меньше `2 × perGroup`, дает сколько получится.
    public static func make(_ entries: [EvalList.Entry], perGroup: Int) -> [Pair] {
        guard perGroup > 0 else { return [] }
        var order: [String] = []
        var byGroup: [String: [EvalList.Entry]] = [:]
        for entry in entries {
            if byGroup[entry.group] == nil { order.append(entry.group) }
            byGroup[entry.group, default: []].append(entry)
        }
        var pairs: [Pair] = []
        for group in order {
            let files = byGroup[group] ?? []
            var index = 0
            while index + 1 < files.count, index / 2 < perGroup {
                pairs.append(Pair(first: files[index], second: files[index + 1]))
                index += 2
            }
        }
        return pairs
    }

    /// Первые `clipSeconds` секунд сэмплов.
    public static func clip(_ samples: [Float], sampleRate: Double) -> [Float] {
        Array(samples.prefix(Int(clipSeconds * sampleRate)))
    }

    /// Счет трека B в прогоне `result` по склейке A + B: аннотации B (моменты в B) сдвигаются на длину A
    /// `firstDuration`, первые `firstDuration` секунд не считаются (захват, темнота, точность только по B),
    /// дальше как `BeatEvaluation.score` с `options.skipSeconds` от начала B.
    public static func scoreSecond(
        result: OfflineBeatChain.Result, firstDuration: Double, secondAnnotations: [Double], secondDuration: Double,
        options: BeatEvaluation.Options, path: String, group: String, heldout: Bool
    ) -> BeatEvaluation.FileScore {
        var shifted = options
        shifted.skipSeconds = firstDuration + options.skipSeconds
        return BeatEvaluation.score(
            result: result, annotations: secondAnnotations.map { $0 + firstDuration }, duration: firstDuration + secondDuration,
            options: shifted, path: path, group: group, heldout: heldout
        )
    }
}

/// Паузы с тишиной для `wave-eval --reset-every S --pause P`: после каждых `every` секунд звука (кроме
/// конца) вставляются `length` секунд нулей, и звук продолжается с того же места, как после паузы плеера,
/// во время которой захват получает нули (поток не встает и анализ не сбрасывается). Доли файла
/// сдвигаются на паузы до них, возобновления в конце каждой паузы считаются как сбросы
/// (`BeatEvaluation.resume`).
public enum EvalPauses {
    /// Звук с паузами и моменты пауз на оси исходного звука, секунды.
    public static func insert(_ samples: [Float], sampleRate: Double, every: Double, length: Double) -> (samples: [Float], cuts: [Double]) {
        let step = max(Int((every * sampleRate).rounded()), 1)
        let gap = [Float](repeating: 0, count: max(Int((length * sampleRate).rounded()), 0))
        var out: [Float] = []
        out.reserveCapacity(samples.count + samples.count / step * gap.count)
        var cuts: [Double] = []
        var position = 0
        while position < samples.count {
            let end = min(position + step, samples.count)
            out += samples[position..<end]
            if end < samples.count {
                out += gap
                cuts.append(Double(end) / sampleRate)
            }
            position = end
        }
        return (out, cuts)
    }

    /// Моменты исходного звука на оси звука с паузами: плюс длина всех пауз, вставленных не позже них.
    public static func shift(_ times: [Double], cuts: [Double], length: Double) -> [Double] {
        times.map { time in time + Double(cuts.filter { $0 <= time }.count) * length }
    }

    /// Возобновление в конце каждой паузы (ось звука с паузами) с захватом последней публикации до ее
    /// начала.
    public static func resets(cuts: [Double], length: Double, states: [OfflineBeatChain.State]) -> [OfflineBeatChain.Reset] {
        cuts.enumerated().map { index, cut in
            let start = cut + Double(index) * length
            let locked = states.last { $0.time < start }?.locked ?? false
            return OfflineBeatChain.Reset(time: start + length, locked: locked)
        }
    }
}

/// Записи владельца для `wave-eval --owner`: запись ритма с устройства (`RhythmLog` и WAV рядом) и сетка
/// долей, снятая один раз скриптами разбора (`grid15.py`, `refbeats.py`, `dpcls.py`) и лежащая файлом
/// долей на оси файла. Запись прогоняется как `wave-eval --replay` (задержка, сдвиг и частота кадров из
/// записи, холодный трекер), каждая вспышка прогона ложится на долю, на «и» или мимо
/// (`BeatMetrics.place`). Так виден разрыв между GTZAN и музыкой, которую слушает владелец.
public enum OwnerEvaluation {
    /// Промежуток без вспышек длиннее этого считается темнотой, секунды (как в разборе 1.2.1).
    public static let darkGap = 1.5

    public struct Score: Sendable, Equatable, Codable {
        public var name: String
        public var group: String
        /// Темп сетки по медиане межударных интервалов; `nil`, если долей меньше двух.
        public var gridBPM: Double?
        /// Конец оцениваемого отрезка на слышимой оси (звук плюс задержка вывода плюс положительный сдвиг).
        public var end: Double
        public var flashes = 0
        public var on = 0
        public var half = 0
        public var other = 0
        public var lockedFlashes = 0
        public var lockedOn = 0
        public var lockedHalf = 0
        /// Сумма и самый длинный промежуток без вспышек дольше `darkGap`, секунды.
        public var darkSeconds = 0.0
        public var longestDark = 0.0
        /// Секунды с захватом (публикации трекера).
        public var lockedSeconds = 0.0
        /// Первый захват, секунды от начала; `nil` без захвата.
        public var firstLock: Double?
        public var resume: BeatEvaluation.ResumeScore?
        /// Мягкий пульс прогона (`OfflineBeatChain.Result`): кадров рендера всего и с пульсом от
        /// `RhythmLog.ambientVisible`, то же под расписанием без захвата, вершин пульса и сколько из них в
        /// пределах окна от онсета анализа (широкополосного или бочки).
        public var pulseFrames = 0
        public var pulseVisible = 0
        public var unlockedFrames = 0
        public var unlockedPulseVisible = 0
        public var pulsePeaks = 0
        public var pulsePeaksNearOnset = 0

        public init(name: String, group: String, gridBPM: Double?, end: Double) {
            self.name = name
            self.group = group
            self.gridBPM = gridBPM
            self.end = end
        }

        /// Доля вспышек на доле; `nil` без вспышек.
        public var precision: Double? { flashes > 0 ? Double(on) / Double(flashes) : nil }
        public var lockedPrecision: Double? { lockedFlashes > 0 ? Double(lockedOn) / Double(lockedFlashes) : nil }
        public var lockedShare: Double { end > 0 ? lockedSeconds / end : 0 }
        /// Доля кадров с видимым пульсом, всех и без захвата, и доля вершин пульса у онсетов.
        public var pulseShare: Double? { pulseFrames > 0 ? Double(pulseVisible) / Double(pulseFrames) : nil }
        public var unlockedPulseShare: Double? {
            unlockedFrames > 0 ? Double(unlockedPulseVisible) / Double(unlockedFrames) : nil
        }
        public var pulsePeaksOnOnsets: Double? { pulsePeaks > 0 ? Double(pulsePeaksNearOnset) / Double(pulsePeaks) : nil }
    }

    /// Звук записи `count` раз подряд (петля, `--loop`).
    public static func looped(_ samples: [Float], count: Int) -> [Float] {
        guard count > 1 else { return samples }
        var out: [Float] = []
        out.reserveCapacity(samples.count * count)
        for _ in 0..<count { out += samples }
        return out
    }

    /// Сетка долей петли: доли каждого повтора сдвинуты на его начало `k × duration`.
    public static func loopedGrid(_ beats: [Double], duration: Double, count: Int) -> [Double] {
        guard count > 1 else { return beats }
        return (0..<count).flatMap { loop in beats.map { $0 + Double(loop) * duration } }
    }

    /// Счет прогона `result` записи со звуком `audioSeconds` секунд против сетки `grid` (моменты файла,
    /// переводятся на слышимую ось). Вспышки берутся до слышимого конца звука (как `RhythmReplay`), без
    /// слияния: глаз видит каждую.
    public static func score(
        result: OfflineBeatChain.Result, grid: [Double], audioSeconds: Double, syncOffset: Double, window: Double,
        name: String, group: String
    ) -> Score {
        let beats = result.audible(grid).sorted()
        let end = audioSeconds + result.outputLatency + max(syncOffset, 0)
        let intervals = zip(beats, beats.dropFirst()).map { $1 - $0 }
        let bpm = BeatMetrics.percentile(intervals, 0.5).flatMap { $0 > 0 ? 60 / $0 : nil }
        var score = Score(name: name, group: group, gridBPM: bpm, end: end)
        let flashes = result.flashes.filter { $0.time >= 0 && $0.time <= end }
        for flash in flashes {
            let place = BeatMetrics.place(of: flash.time, beats: beats, window: window)
            score.flashes += 1
            switch place {
            case .on: score.on += 1
            case .half: score.half += 1
            case .other: score.other += 1
            }
            if flash.locked {
                score.lockedFlashes += 1
                if place == .on { score.lockedOn += 1 }
                if place == .half { score.lockedHalf += 1 }
            }
        }
        let dark = BeatMetrics.darkSpans(detections: flashes.map(\.time), from: 0, to: end, gap: darkGap)
        score.darkSeconds = dark.total
        score.longestDark = dark.longest
        score.lockedSeconds = BeatMetrics.lockedCoverage(states: result.states, duration: end) * end
        score.firstLock = result.lockTime
        if !result.resets.isEmpty {
            score.resume = BeatEvaluation.resume(result: result, annotations: grid, duration: audioSeconds, window: window)
        }
        score.pulseFrames = result.renderedFrames
        score.pulseVisible = result.ambientFrames
        score.unlockedFrames = result.unlockedFrames
        score.unlockedPulseVisible = result.ambientUnlockedFrames
        let onsets = (result.onsets + result.kickOnsets).sorted()
        score.pulsePeaks = result.ambientPeaks.count
        score.pulsePeaksNearOnset = result.ambientPeaks.filter { BeatMetrics.nearestDistance(to: $0, in: onsets) <= window }.count
        return score
    }

    /// Сумма записей под именем `name` (темп сетки не суммируется).
    public static func total(name: String, scores: [Score]) -> Score {
        var sum = Score(name: name, group: name, gridBPM: nil, end: scores.reduce(0) { $0 + $1.end })
        for score in scores {
            sum.flashes += score.flashes
            sum.on += score.on
            sum.half += score.half
            sum.other += score.other
            sum.lockedFlashes += score.lockedFlashes
            sum.lockedOn += score.lockedOn
            sum.lockedHalf += score.lockedHalf
            sum.darkSeconds += score.darkSeconds
            sum.longestDark = max(sum.longestDark, score.longestDark)
            sum.lockedSeconds += score.lockedSeconds
            sum.pulseFrames += score.pulseFrames
            sum.pulseVisible += score.pulseVisible
            sum.unlockedFrames += score.unlockedFrames
            sum.unlockedPulseVisible += score.unlockedPulseVisible
            sum.pulsePeaks += score.pulsePeaks
            sum.pulsePeaksNearOnset += score.pulsePeaksNearOnset
            if let resume = score.resume {
                var merged = sum.resume ?? BeatEvaluation.ResumeScore()
                merged.add(resume)
                sum.resume = merged
            }
        }
        return sum
    }

    /// Итоги: по группам в порядке первого появления, затем объединения, затем `TOTAL`.
    public static func totals(_ scores: [Score], unions: [EvalArguments.Union]) -> [Score] {
        var order: [String] = []
        for score in scores where !order.contains(score.group) { order.append(score.group) }
        var rows = order.map { group in total(name: group, scores: scores.filter { $0.group == group }) }
        for union in unions {
            let members = Set(union.groups)
            let chosen = scores.filter { members.contains($0.group) }
            if !chosen.isEmpty { rows.append(total(name: union.name, scores: chosen)) }
        }
        rows.append(total(name: "TOTAL", scores: scores))
        return rows
    }

    public static let notes = [
        "owner: each rhythm log replayed cold with its own output latency, sync offset and render rate (as --replay); flashes up to the audible end of the audio, not merged",
        "on / half / other: flash within the window of a grid beat / of a midpoint between two grid beats (the and-beat) / elsewhere; prec = on / flashes; L = flashes under a locked schedule",
        "dark s = total of gaps longer than 1.5 s without a flash (start and end included), longest = the longest one; locked = share of time with a published lock",
        "pulse / pulse U = share of render frames (all / under an unlocked schedule) with the soft pulse at or above RhythmLog.ambientVisible; pk@on = share of soft pulse peaks within the window of an analysis onset (broadband or kick)",
    ]

    /// Таблица: записи, пустая строка, итоги.
    public static func table(recordings: [Score], totals: [Score]) -> String {
        let width = max(24, (recordings + totals).map(\.name.count).max() ?? 0)
        let heads = [
            "group", "BPM", "flashes", "on", "half", "other", "prec", "L fl", "L on", "L half", "L prec", "dark s", "longest", "locked", "lock s",
            "pulse", "pulse U", "pk@on",
        ]
        func cells(_ score: Score, total: Bool) -> [String] {
            func fraction(_ value: Double?) -> String { value.map { String(format: "%.3f", $0) } ?? "-" }
            return [
                total ? "" : score.group, score.gridBPM.map { String(format: "%.1f", $0) } ?? "-", String(score.flashes),
                String(score.on), String(score.half), String(score.other), fraction(score.precision), String(score.lockedFlashes),
                String(score.lockedOn), String(score.lockedHalf), fraction(score.lockedPrecision),
                String(format: "%.1f", score.darkSeconds), String(format: "%.1f", score.longestDark), String(format: "%.2f", score.lockedShare),
                total ? "" : score.firstLock.map { String(format: "%.1f", $0) } ?? "never",
                fraction(score.pulseShare), fraction(score.unlockedPulseShare), fraction(score.pulsePeaksOnOnsets),
            ]
        }
        func line(_ name: String, _ values: [String]) -> String {
            let padded = name.count >= width ? name : name + String(repeating: " ", count: width - name.count)
            return padded + "  " + zip(values, heads).map { value, head in
                let size = max(head.count, 7)
                return value.count >= size ? value : String(repeating: " ", count: size - value.count) + value
            }.joined(separator: " ")
        }
        var lines = [line("recording", heads)]
        lines += recordings.map { line($0.name, cells($0, total: false)) }
        lines.append("")
        lines += totals.map { line($0.name, cells($0, total: true)) }
        return lines.joined(separator: "\n")
    }
}
