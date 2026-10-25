import Foundation

/// Метрики попадания в долю для офлайн-оценки (`wave-eval`): детекции против аннотаций долей.
///
/// Ось времени. Метрики считают только разности, поэтому обе стороны должны быть на одной оси. Вспышки
/// `OfflineBeatChain` даны на слышимой оси (секунды от первого сэмпла, как слышно: момент файла плюс
/// `outputLatency`), поэтому аннотации долей из файла сначала переводятся туда же
/// (`OfflineBeatChain.Result.audible(_:)`), иначе в сдвиге появится задержка вывода.
///
/// Определения взяты у mir_eval (Davies и др., Böck и др.), упрощены и отличаются так:
/// - F-мера: сопоставление один к одному в окне ±`window`, наибольшее по числу пар (как у mir_eval),
///   но без отбрасывания первых 5 с: вызывающий обрезает списки сам. Если пусты детекции или
///   аннотации, все три значения 0.
/// - Непрерывность: для каждой аннотации берется ближайшая детекция; доля верна, если фаза в пределах
///   17.5 % интервала до предыдущей аннотации (у первой до следующей) и интервал самой детекции до
///   ее предыдущей соседки (у первой до следующей) отличается от интервала аннотаций не больше чем
///   на 17.5 %. Условие "предыдущая доля тоже верна" не требуется (оно у mir_eval только для
///   непрерывной части), поэтому CMLt это доля верных долей, CMLc длиннейший непрерывный отрезок
///   верных долей.
/// - AMLt и AMLc берут лучший из пяти уровней: исходные аннотации, двойной темп (аннотации плюс
///   середины между ними), половинный темп (четные и нечетные аннотации) и оборот доли (середины
///   между аннотациями). Доли считаются от числа долей самого уровня.
public enum BeatMetrics {
    /// Допуск фазы и интервала непрерывности, доля интервала аннотаций.
    public static let continuityTolerance = 0.175

    /// Запас на ошибку округления на границе окна, секунды.
    private static let edge = 1e-9

    /// Точность, полнота и F-мера вспышек или детекций `detections` против `annotations` в окне
    /// ±`window` секунд, каждая аннотация и детекция участвует в одной паре.
    public static func fMeasure(
        detections: [Double], annotations: [Double], window: Double
    ) -> (precision: Double, recall: Double, f: Double) {
        guard !detections.isEmpty, !annotations.isEmpty else { return (0, 0, 0) }
        let matched = Double(matchCount(detections.sorted(), annotations.sorted(), window: window))
        let precision = matched / Double(detections.count)
        let recall = matched / Double(annotations.count)
        let f = matched == 0 ? 0 : 2 * matched / Double(detections.count + annotations.count)
        return (precision, recall, f)
    }

    /// Средняя разность "детекция минус ближайшая аннотация" по детекциям, у которых аннотация есть в
    /// окне ±`window`; плюс значит позже. `nil`, если таких детекций нет. Сопоставление не взаимно
    /// однозначное: две детекции могут указать на одну аннотацию.
    public static func meanOffset(detections: [Double], annotations: [Double], window: Double) -> Double? {
        let found = offsets(detections: detections, annotations: annotations, window: window)
        return found.isEmpty ? nil : found.reduce(0, +) / Double(found.count)
    }

    /// Разности "детекция минус ближайшая аннотация" для детекций, у которых аннотация есть в окне
    /// ±`window` (те же, что усредняет `meanOffset`).
    public static func offsets(detections: [Double], annotations: [Double], window: Double) -> [Double] {
        let sorted = annotations.sorted()
        var found: [Double] = []
        for detection in detections {
            guard let nearest = nearestIndex(of: detection, in: sorted) else { continue }
            let difference = detection - sorted[nearest]
            if abs(difference) <= window + edge { found.append(difference) }
        }
        return found
    }

    public struct Continuity: Sendable, Equatable {
        /// Доля верных долей на правильном уровне.
        public var cmlt: Double
        /// Длиннейший непрерывный отрезок верных долей на правильном уровне, доля.
        public var cmlc: Double
        /// Как `cmlt`, но допустимы двойной, половинный темп и оборот доли.
        public var amlt: Double
        /// Как `cmlc`, но допустимы двойной, половинный темп и оборот доли.
        public var amlc: Double
    }

    /// CMLt, CMLc, AMLt и AMLc (см. описание типа). Нужны хотя бы две аннотации и одна детекция, иначе 0.
    public static func continuity(
        detections: [Double], annotations: [Double], tolerance: Double = continuityTolerance
    ) -> Continuity {
        let detections = detections.sorted()
        let annotations = annotations.sorted()
        let direct = scores(detections: detections, annotations: annotations, tolerance: tolerance)
        var amlt = direct.total
        var amlc = direct.continuous
        for variant in metricalVariants(of: annotations) {
            let score = scores(detections: detections, annotations: variant, tolerance: tolerance)
            amlt = max(amlt, score.total)
            amlc = max(amlc, score.continuous)
        }
        return Continuity(cmlt: direct.total, cmlc: direct.continuous, amlt: amlt, amlc: amlc)
    }

    /// Доля вспышек с `locked == true`, попавших в окно ±`window` вокруг аннотации (сопоставление один
    /// к одному, как у `fMeasure`). `nil`, если таких вспышек нет.
    public static func lockedPrecision(
        flashes: [OfflineBeatChain.Flash], annotations: [Double], window: Double
    ) -> Double? {
        let locked = flashes.filter(\.locked).map(\.time)
        guard !locked.isEmpty else { return nil }
        return Double(matchCount(locked.sorted(), annotations.sorted(), window: window)) / Double(locked.count)
    }

    /// Доля `duration` секунд от первого сэмпла, на которую опубликован захват. Состояние держится от
    /// своей публикации до следующей (последнее до `duration`); публикации вне 0...`duration` обрезаются.
    public static func lockedCoverage(states: [OfflineBeatChain.State], duration: Double) -> Double {
        guard duration > 0, duration.isFinite else { return 0 }
        let ordered = states.sorted { $0.time < $1.time }
        var locked = 0.0
        for (index, state) in ordered.enumerated() where state.locked {
            let start = min(max(state.time, 0), duration)
            let end = index + 1 < ordered.count ? min(max(ordered[index + 1].time, 0), duration) : duration
            locked += max(end - start, 0)
        }
        return locked / duration
    }

    /// Самая длинная серия аннотаций подряд, у которых нет ни одной детекции в окне ±`window` (темные
    /// доли: глаз не видел вспышки на этой доле).
    public static func longestDarkRun(detections: [Double], annotations: [Double], window: Double) -> Int {
        let sorted = detections.sorted()
        var longest = 0
        var current = 0
        for annotation in annotations.sorted() {
            if let nearest = nearestIndex(of: annotation, in: sorted), abs(sorted[nearest] - annotation) <= window + edge {
                current = 0
            } else {
                current += 1
                longest = max(longest, current)
            }
        }
        return longest
    }

    /// Смены захвата в опубликованных состояниях с моментом в `[from, through]` (начальное состояние
    /// сменой не считается) и потери захвата среди них по причинам; потеря без причины входит только в
    /// `changes`.
    public static func lockChanges(
        states: [OfflineBeatChain.State], from: Double, through: Double
    ) -> (changes: Int, unlocks: [UnlockReason: Int]) {
        let ordered = states.sorted { $0.time < $1.time }
        var changes = 0
        var unlocks: [UnlockReason: Int] = [:]
        for index in ordered.indices.dropFirst() where ordered[index].time >= from && ordered[index].time <= through {
            let state = ordered[index]
            guard ordered[index - 1].locked != state.locked else { continue }
            changes += 1
            if !state.locked, let reason = state.unlockReason { unlocks[reason, default: 0] += 1 }
        }
        return (changes, unlocks)
    }

    /// Процентиль по ближайшему рангу: значение с номером `ceil(fraction · n)` по возрастанию; `nil`
    /// для пустого списка.
    public static func percentile(_ values: [Double], _ fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    // MARK: Внутреннее

    /// Наибольшее число пар в окне для отсортированных списков: жадный проход слева направо оптимален,
    /// потому что окно у всех одной ширины.
    private static func matchCount(_ detections: [Double], _ annotations: [Double], window: Double) -> Int {
        var i = 0
        var j = 0
        var pairs = 0
        while i < detections.count, j < annotations.count {
            if annotations[j] < detections[i] - window - edge {
                j += 1
            } else if detections[i] < annotations[j] - window - edge {
                i += 1
            } else {
                pairs += 1
                i += 1
                j += 1
            }
        }
        return pairs
    }

    private static func nearestIndex(of time: Double, in sorted: [Double]) -> Int? {
        guard !sorted.isEmpty else { return nil }
        var low = 0
        var high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] < time { low = mid + 1 } else { high = mid }
        }
        if low == 0 { return 0 }
        if low == sorted.count { return low - 1 }
        return time - sorted[low - 1] <= sorted[low] - time ? low - 1 : low
    }

    /// Уровни AML кроме исходного: двойной темп, половинный (две фазы) и оборот доли.
    private static func metricalVariants(of annotations: [Double]) -> [[Double]] {
        guard annotations.count >= 2 else { return [] }
        let middles = zip(annotations, annotations.dropFirst()).map { ($0 + $1) / 2 }
        var double: [Double] = []
        for (index, beat) in annotations.enumerated() {
            double.append(beat)
            if index < middles.count { double.append(middles[index]) }
        }
        let even = annotations.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        let odd = annotations.enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
        return [middles, double, even, odd]
    }

    /// Доля верных долей и доля длиннейшего непрерывного отрезка верных для одного уровня аннотаций.
    private static func scores(
        detections: [Double], annotations: [Double], tolerance: Double
    ) -> (total: Double, continuous: Double) {
        guard annotations.count >= 2, !detections.isEmpty else { return (0, 0) }
        var correct = 0
        var run = 0
        var longest = 0
        for (index, beat) in annotations.enumerated() {
            let interval = index > 0 ? beat - annotations[index - 1] : annotations[1] - beat
            var good = false
            if interval > 0, let nearest = nearestIndex(of: beat, in: detections) {
                let phase = abs(detections[nearest] - beat) <= tolerance * interval + edge
                let own: Double? = if nearest > 0 {
                    detections[nearest] - detections[nearest - 1]
                } else if nearest + 1 < detections.count {
                    detections[nearest + 1] - detections[nearest]
                } else {
                    nil
                }
                let period = own.map { abs(1 - $0 / interval) <= tolerance + edge } ?? false
                good = phase && period
            }
            if good {
                correct += 1
                run += 1
                longest = max(longest, run)
            } else {
                run = 0
            }
        }
        let count = Double(annotations.count)
        return (Double(correct) / count, Double(longest) / count)
    }
}
