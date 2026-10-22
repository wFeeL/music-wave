import Foundation

/// Оценка темпа: период доли и признак смены темпа (новый период, а не подстройка старого).
public struct TempoEstimate: Sendable, Equatable {
    /// Период доли в секундах.
    public var period: Double
    /// Период задан заново: первая оценка или переход на другой темп.
    public var switched: Bool

    public init(period: Double, switched: Bool) {
        self.period = period
        self.switched = switched
    }
}

/// Темп по автокорреляции широкополосной функции онсетов с гребенкой гармоник (`beat-sync.md` 2.4).
///
/// `append` принимает функцию онсетов каждого шага анализа, `update` вызывается каждые
/// `updateInterval` секунд времени потока и смотрит на последние `historySeconds`:
/// 1. функция возводится в куб, прореживается вдвое (средние пар) и центрируется. Куб отдает
///    автокорреляцию громким акцентам (бочка, малый), а не частым тихим (хэт): у широкополосной
///    функции хэт восьмыми почти так же силен, как бочка с хэтом на доле, и без степени на 160 BPM
///    выигрывал лаг в три восьмых (107 BPM), а на 90 BPM восьмые (180 BPM). Квадрата не хватало при
///    неровной игре (165 и 170 BPM уходили в 3:2);
/// 2. автокорреляция `acf[l]` нормирована на число пар `n - l`, чтобы длинные лаги (медленные темпы,
///    старшие гармоники) не проигрывали коротким только из-за короткой истории, и сглажена ядром
///    [1, 2, 1] / 4;
/// 3. для лагов τ темпов 70-180 BPM `S(τ) = Σ_{h=1..4} max(acf[hτ-1...hτ+1]) / √h` умножается на
///    лог-гауссов приоритет вокруг 120 BPM с σ = 0.9 октавы. τ перебирается с шагом в половину шага
///    истории: при целом τ четвертая гармоника уходит от настоящего пика на два шага, за окно ±1, и
///    гребенка выбирала темп, у которого лаг ближе к целому (на 90 BPM лаг 62.5 проигрывал 31).
///    Пока история коротка, гармоники, у которых меньше секунды пар, не считаются, а сумма остальных
///    растягивается на полный вес гребенки: иначе в первые секунды быстрый темп собирал бы больше
///    гармоник и выигрывал октавой;
/// 4. лучший лаг уточняется параболой по трем соседним `S`;
/// 5. шаг устойчивости `accept(period:)` с удержанием от кратных перебросов.
///
/// Тишина или история без периодичности дают `nil`. Буферы выделены в `init`, `update` не выделяет.
public struct TempoEstimator: Sendable {
    public static let minBPM = 70.0
    public static let maxBPM = 180.0
    public static let priorBPM = 120.0
    public static let priorSigmaOctaves = 0.9
    public static let historySeconds = 6.0
    public static let updateInterval = 0.25
    public static let minimumHistory = 2.0
    /// Сколько подряд согласных оценок нужно, чтобы сменить установившийся темп на кратный ему
    /// (2, ½, 3/2, 2/3, 4/3, 3/4 в пределах 4 %). 8 и меньше пропускали переброс 170 и 85 BPM при
    /// разбросе бочки 8 мс; 12 оценок это 3 с.
    public static let relatedSwitchUpdates = 12
    /// Через столько секунд потока после первой оценки темп считается установившимся.
    public static let establishedAfter = 3.0

    /// Оценка в пределах этой доли от текущего периода подтягивает его на `followRate`.
    static let followTolerance = 0.06
    static let followRate = 0.2
    /// Далекая оценка принимается, когда следующая совпадает с ней в пределах этой доли.
    static let switchTolerance = 0.03
    static let harmonics = 4
    /// Кратные отношения, переход на которые сдерживается, и допуск к ним.
    static let relatedRatios: [Double] = [2, 0.5, 1.5, 2.0 / 3, 4.0 / 3, 0.75]
    static let relatedTolerance = 0.04
    /// Меньше стольких секунд пар гармоника не учитывается.
    static let minimumOverlapSeconds = 1.0

    public let framesPerSecond: Double
    /// Текущий период доли в секундах, `nil` до первой оценки.
    public private(set) var period: Double?
    private var candidate: Double?
    /// Сколько оценок подряд совпали с кандидатом, включая первую.
    private var agreeingUpdates = 0
    /// Шагов функции онсетов с `reset` и номер шага первой оценки.
    private var framesAppended = 0
    private var firstEstimateFrame: Int?

    /// Кольцо функции онсетов на `historySeconds`.
    private var history: [Float]
    private var writeIndex = 0
    private var count = 0

    /// Шагов прореженной истории в секунду.
    private let decimatedRate: Double
    /// Границы лага доли в половинах шага прореженной истории.
    private let halfLagMin: Int
    private let halfLagMax: Int
    private let minimumOverlap: Int
    private let minimumCount: Int
    /// Лог-гауссов приоритет по лагу в половинах шага, `0...halfLagMax + 1`.
    private let prior: [Double]
    private let combWeight: Double

    private var decimated: [Double]
    private var acf: [Double]
    /// `acf`, сглаженная ядром [1, 2, 1] / 4.
    private var smoothedACF: [Double]
    private var score: [Double]

    public init(framesPerSecond: Double) {
        precondition(framesPerSecond > 0, "framesPerSecond must be positive")
        self.framesPerSecond = framesPerSecond
        let capacity = max(Int((Self.historySeconds * framesPerSecond).rounded()), 2)
        history = [Float](repeating: 0, count: capacity)
        let rate = framesPerSecond / 2
        decimatedRate = rate
        halfLagMin = max(Int((2 * rate * 60 / Self.maxBPM).rounded()), 4)
        halfLagMax = max(Int((2 * rate * 60 / Self.minBPM).rounded()), halfLagMin)
        minimumOverlap = Int((Self.minimumOverlapSeconds * rate).rounded())
        minimumCount = Int((Self.minimumHistory * framesPerSecond).rounded())
        prior = (0...(halfLagMax + 1)).map { halfLag in
            guard halfLag > 0 else { return 0 }
            let octaves = log2(2 * 60 * rate / Double(halfLag) / Self.priorBPM) / Self.priorSigmaOctaves
            return exp(-0.5 * octaves * octaves)
        }
        combWeight = (1...Self.harmonics).reduce(0) { $0 + 1 / Double($1).squareRoot() }
        decimated = [Double](repeating: 0, count: capacity / 2)
        acf = [Double](repeating: 0, count: Self.center(harmonic: Self.harmonics, halfLag: halfLagMax + 1) + 3)
        smoothedACF = acf
        score = [Double](repeating: 0, count: halfLagMax + 2)
    }

    /// Функция онсетов очередного шага анализа.
    public mutating func append(_ odf: Float) {
        history[writeIndex] = odf.isFinite ? max(odf, 0) : 0
        writeIndex = (writeIndex + 1) % history.count
        count = min(count + 1, history.count)
        framesAppended += 1
    }

    /// Новая оценка по последним `historySeconds`; `nil`, пока истории меньше `minimumHistory` или в
    /// ней нет периодичности (тишина).
    public mutating func update() -> TempoEstimate? {
        guard count >= minimumCount, let halfLag = bestHalfLag() else { return nil }
        let low = 60 / Self.maxBPM
        let high = 60 / Self.minBPM
        return accept(period: min(max(halfLag / 2 / decimatedRate, low), high))
    }

    /// Шаг устойчивости отдельно от оценки: близкое значение (до 6 %) подтягивает период на 20 %,
    /// далекое становится кандидатом и принимается, только если следующее совпадает с ним до 3 %.
    /// Когда темп установился (`establishedAfter` секунд потока после первой оценки), кандидат в
    /// кратном отношении к нему (`relatedRatios`) принимается только после `relatedSwitchUpdates`
    /// согласных оценок подряд: переброс октавы или 3:2 сбрасывает захват трекера. Первые секунды
    /// и некратные кандидаты (настоящая смена темпа) переключаются как раньше. Значение не больше нуля
    /// или не конечное пропускается: возвращается текущий период (без него 0.5 с) без переключения.
    public mutating func accept(period estimate: Double) -> TempoEstimate {
        guard estimate.isFinite, estimate > 0 else {
            return TempoEstimate(period: period ?? 60 / Self.priorBPM, switched: false)
        }
        guard let current = period else {
            period = estimate
            candidate = nil
            agreeingUpdates = 0
            firstEstimateFrame = framesAppended
            return TempoEstimate(period: estimate, switched: true)
        }
        if abs(estimate - current) / current < Self.followTolerance {
            let moved = current + Self.followRate * (estimate - current)
            period = moved
            candidate = nil
            agreeingUpdates = 0
            return TempoEstimate(period: moved, switched: false)
        }
        if let candidate, abs(estimate - candidate) / candidate < Self.switchTolerance {
            agreeingUpdates += 1
            let needed = isEstablished && Self.isRelated(estimate, to: current) ? Self.relatedSwitchUpdates : 2
            if agreeingUpdates >= needed {
                period = estimate
                self.candidate = nil
                agreeingUpdates = 0
                return TempoEstimate(period: estimate, switched: true)
            }
            self.candidate = estimate
            return TempoEstimate(period: current, switched: false)
        }
        candidate = estimate
        agreeingUpdates = 1
        return TempoEstimate(period: current, switched: false)
    }

    private var isEstablished: Bool {
        guard let firstEstimateFrame else { return false }
        return Double(framesAppended - firstEstimateFrame) / framesPerSecond >= Self.establishedAfter
    }

    private static func isRelated(_ estimate: Double, to current: Double) -> Bool {
        let ratio = estimate / current
        return relatedRatios.contains { abs(ratio / $0 - 1) < relatedTolerance }
    }

    /// Пауза, перемотка или смена источника: история и темп начинаются заново.
    public mutating func reset() {
        for index in history.indices {
            history[index] = 0
        }
        writeIndex = 0
        count = 0
        period = nil
        candidate = nil
        agreeingUpdates = 0
        framesAppended = 0
        firstEstimateFrame = nil
    }

    /// Центр окна гармоники `h` лага `halfLag / 2`: `h · halfLag / 2`, половина вверх.
    private static func center(harmonic: Int, halfLag: Int) -> Int {
        (harmonic * halfLag + 1) / 2
    }

    /// Лаг доли в половинах шага прореженной истории с дробной частью, `nil` без периодичности.
    private mutating func bestHalfLag() -> Double? {
        let capacity = history.count
        let n = count / 2
        // Пары от самого старого из последних 2n шагов, в кубе; среднее вычитается.
        var start = (writeIndex - 2 * n + capacity) % capacity
        var mean = 0.0
        for i in 0..<n {
            let next = (start + 1) % capacity
            let first = Double(history[start])
            let second = Double(history[next])
            let value = 0.5 * (first * first * first + second * second * second)
            decimated[i] = value
            mean += value
            start = (next + 1) % capacity
        }
        mean /= Double(max(n, 1))
        var energy = 0.0
        for i in 0..<n {
            decimated[i] -= mean
            energy += decimated[i] * decimated[i]
        }
        guard energy > 1e-9 * Double(max(n, 1)) else { return nil }

        // Автокорреляция на число пар; лаги, у которых меньше `minimumOverlap` пар, не считаются.
        // Сглаживание [1, 2, 1] / 4 собирает пик, размазанный неровной игрой (σ 8 мс у бочки дает
        // разброс разности двух ударов 11 мс, больше шага истории), иначе лаги бочки к бочке
        // проигрывали лагам бочки к хэту, и 160 BPM уходил в 107.
        let maxLag = min(acf.count - 1, n - minimumOverlap)
        guard maxLag >= Self.center(harmonic: 1, halfLag: halfLagMax + 1) + 2 else { return nil }
        for l in 1...maxLag {
            var sum = 0.0
            for i in 0..<(n - l) {
                sum += decimated[i] * decimated[i + l]
            }
            acf[l] = sum / Double(n - l)
        }
        for l in 2..<maxLag {
            smoothedACF[l] = 0.25 * (acf[l - 1] + 2 * acf[l] + acf[l + 1])
        }
        let combLag = maxLag - 1

        // Гребенка с приоритетом; соседи по краям диапазона нужны только параболе.
        for halfLag in (halfLagMin - 1)...(halfLagMax + 1) {
            var sum = 0.0
            var weight = 0.0
            for h in 1...Self.harmonics {
                let center = Self.center(harmonic: h, halfLag: halfLag)
                guard center + 1 <= combLag else { break }
                let w = 1 / Double(h).squareRoot()
                sum += max(smoothedACF[center - 1], smoothedACF[center], smoothedACF[center + 1]) * w
                weight += w
            }
            score[halfLag] = sum / weight * combWeight * prior[halfLag]
        }

        var best = halfLagMin
        for halfLag in halfLagMin...halfLagMax where score[halfLag] > score[best] {
            best = halfLag
        }
        guard score[best] > 0 else { return nil }

        let left = score[best - 1]
        let middle = score[best]
        let right = score[best + 1]
        let curvature = left - 2 * middle + right
        guard curvature < 0 else { return Double(best) }
        let offset = 0.5 * (left - right) / curvature
        return Double(best) + min(max(offset, -0.5), 0.5)
    }
}
