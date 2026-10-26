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
/// `append` принимает функции онсетов каждого шага анализа (широкополосную и бочки), `update`
/// вызывается каждые `updateInterval` секунд времени потока и смотрит на последние `historySeconds`:
/// 1. широкополосная функция возводится в квадрат, прореживается вдвое (средние пар) и центрируется.
///    Квадрат отдает автокорреляцию громким акцентам (бочка, малый), а не частым тихим (хэт): у этой
///    функции хэт восьмыми почти так же силен, как бочка с хэтом на доле, и без степени на 160 BPM
///    выигрывал лаг в три восьмых (107 BPM), а на 90 BPM восьмые (180 BPM);
/// 2. автокорреляция взвешена по свежести (вес шага `exp(-возраст / recencySeconds)`, нормировка на
///    сумму весов пар), так что смена темпа видна через 2-3 с, а не когда новый темп займет половину
///    шести секунд. Нормировка на пары не дает длинным лагам проигрывать из-за короткой истории;
/// 3. для лагов τ темпов 70-180 BPM `S(τ) = Σ_{h=1..4} max(acf[hτ-1...hτ+1]) / √h` умножается на
///    лог-гауссов приоритет вокруг 120 BPM с σ = 0.9 октавы. τ перебирается с шагом в половину шага
///    истории: при целом τ четвертая гармоника уходит от настоящего пика на два шага, за окно ±1, и
///    гребенка выбирала темп, у которого лаг ближе к целому (на 90 BPM лаг 62.5 проигрывал 31).
///    Пока история коротка, гармоники, у которых меньше секунды пар, не считаются, а сумма остальных
///    растягивается на полный вес гребенки: иначе в первые секунды быстрый темп собирал бы больше
///    гармоник и выигрывал октавой;
/// 4. когда темп установился, лаги в пределах 6 % от текущего периода получают `currentBonus`:
///    почти равные октавы (140 и 70 BPM с малым на слабых долях) не перебрасываются туда и обратно;
/// 5. спор 3:2, 2:3, 4:3 и 3:4 решает бочка: если такой лаг набирает не меньше 85 % от лучшего,
///    он выбирается, только когда в той же гребенке по функции бочки (без приоритета) он сильнее
///    лучшего хотя бы на 10 %. Без запаса шумная бочка без долей отдавала спор лагу ближе к 120 BPM
///    (160 уходил в 107), а с ним шум оставляет широкополосный выбор. Хэт и малый между долями
///    поднимают широкополосную функцию на лагах в три восьмых, бочка на каждой доле их не поддерживает
///    (неровная игра на 160-175 BPM уходила в 107-117 BPM);
/// 6. выбранный лаг уточняется параболой по трем соседним `S`;
/// 7. шаг устойчивости `accept(period:)` с удержанием от кратных перебросов.
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
    /// Сколько из последних `relatedWindow` оценок должны совпасть с кандидатом (октава до 6 %, 3:2 и
    /// 4:3 до 4 %), чтобы сменить установившийся темп на кратный ему (2, ½, 3/2, 2/3, 4/3, 3/4 в
    /// пределах 4 %, октава с поправкой на дрейф до 10 %).
    public static let relatedSwitchUpdates = 12
    public static let relatedWindow = 16
    /// Через столько секунд потока после первой оценки темп считается установившимся.
    public static let establishedAfter = 2.0

    /// Оценка в пределах этой доли от текущего периода подтягивает его на `followRate`.
    static let followTolerance = 0.06
    static let followRate = 0.2
    /// Далекая некратная оценка принимается, когда следующая совпадает с ней в пределах этой доли.
    static let switchTolerance = 0.03
    static let harmonics = 4
    /// Кратные отношения, переход на которые сдерживается, и допуск к ним.
    static let relatedRatios: [Double] = [2, 0.5, 1.5, 2.0 / 3, 4.0 / 3, 0.75]
    static let relatedTolerance = 0.04
    /// Насколько оценка рядом с октавой (2 или ½) может уйти от точной октавы текущего периода, если
    /// она продолжает уже принятые кратные оценки: темп мог уплыть, пока период держался. Только для
    /// октав: соседние 4/3 и 3/2 отстоят друг от друга на 12.5 %, окно 10 % вокруг них накрыло бы весь
    /// диапазон 1.2-1.65, и обычная смена темпа (100 -> 140, 90 -> 128) ждала бы правила кратных.
    static let octaveDriftTolerance = 0.10
    /// Отношения, спор которых решает функция бочки, и насколько соперник может уступать лучшему.
    static let kickTieRatios: [Double] = [1.5, 2.0 / 3, 4.0 / 3, 0.75]
    static let kickTieMargin = 0.15
    /// На сколько поддержка бочки у соперника должна превышать поддержку лучшего лага.
    static let kickSupportMargin = 0.1
    /// Прибавка к оценке лагов рядом с установившимся периодом.
    static let currentBonus = 0.15
    /// Постоянная времени веса свежести в секундах.
    static let recencySeconds = 2.0
    /// Меньше стольких секунд пар гармоника не учитывается.
    static let minimumOverlapSeconds = 1.0

    public let framesPerSecond: Double
    /// Текущий период доли в секундах, `nil` до первой оценки.
    public private(set) var period: Double?
    /// Прошлая далекая оценка (для некратной смены темпа по двум согласным).
    private var previousFar: Double?
    /// `previousFar` была признана кратной: с ней не образует пару оценка в окне той же октавы.
    private var previousFarRelated = false
    /// Кольцо последних `relatedWindow` оценок после первой.
    private var recent: [Double]
    /// Оценка в том же слоте `recent` была признана кратной текущему периоду.
    private var recentRelated: [Bool]
    /// Рабочий буфер медианы кратных оценок, `relatedWindow` мест.
    private var medianScratch: [Double]
    private var recentCount = 0
    private var recentIndex = 0
    /// Шагов функции онсетов с `reset` и номер шага первой оценки.
    private var framesAppended = 0
    private var firstEstimateFrame: Int?

    /// Кольца функций онсетов на `historySeconds`.
    private var history: [Float]
    private var kickHistory: [Float]
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
    /// Вес свежести по возрасту в шагах прореженной истории.
    private let recency: [Double]

    private var decimated: [Double]
    private var weights: [Double]
    private var acf: [Double]
    /// Суммы весов пар по лагу для истории из `normCount` шагов прореживания.
    private var norms: [Double]
    private var normCount = 0
    /// Оценки гребенки: широкополосная с 0, бочки с `scoreStride`.
    private var scores: [Double]
    private let scoreStride: Int

    public init(framesPerSecond: Double) {
        precondition(framesPerSecond > 0, "framesPerSecond must be positive")
        self.framesPerSecond = framesPerSecond
        let capacity = max(Int((Self.historySeconds * framesPerSecond).rounded()), 2)
        history = [Float](repeating: 0, count: capacity)
        kickHistory = history
        recent = [Double](repeating: 0, count: Self.relatedWindow)
        recentRelated = [Bool](repeating: false, count: Self.relatedWindow)
        medianScratch = recent
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
        recency = (0..<(capacity / 2)).map { exp(-Double($0) / (Self.recencySeconds * rate)) }
        decimated = [Double](repeating: 0, count: capacity / 2)
        weights = decimated
        acf = [Double](repeating: 0, count: Self.center(harmonic: Self.harmonics, halfLag: halfLagMax + 1) + 2)
        norms = acf
        scoreStride = halfLagMax + 2
        scores = [Double](repeating: 0, count: 2 * scoreStride)
    }

    /// Функции онсетов очередного шага анализа: широкополосная (`HopResult.broadbandODF`) и бочки
    /// (`HopResult.kickODF`). При нулевой функции бочки спор 3:2 решает только широкополосная.
    public mutating func append(_ odf: Float, kick: Float) {
        history[writeIndex] = odf.isFinite ? max(odf, 0) : 0
        kickHistory[writeIndex] = kick.isFinite ? max(kick, 0) : 0
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
    /// далекое некратное принимается, когда следующее совпадает с ним до 3 %. Когда темп установился
    /// (`establishedAfter` секунд потока после первой оценки), кратное ему значение (`relatedRatios`)
    /// принимается, только когда `relatedSwitchUpdates` из последних `relatedWindow` оценок совпадают с
    /// ним (октава до 6 %, `followTolerance`: кандидат плывет вместе с музыкой так же, как период
    /// следует за своими оценками; 3:2 и 4:3 до 4 %): переброс октавы или 3:2 сбрасывает захват. Кратной считается и
    /// оценка рядом с октавой, ушедшая от нее до 10 % вместе с уже принятыми кратными оценками
    /// (`continuesDriftingOctave`): иначе при замедлении удвоенная оценка выходила из допуска 4 % и
    /// переключала темп по правилу двух далеких. Оценки, которые еще идут за старым темпом, счет не
    /// обнуляют. Значение не больше нуля или не конечное пропускается: возвращается текущий период
    /// (без него 0.5 с) без переключения.
    public mutating func accept(period estimate: Double) -> TempoEstimate {
        guard estimate.isFinite, estimate > 0 else {
            return TempoEstimate(period: period ?? 60 / Self.priorBPM, switched: false)
        }
        guard let current = period else {
            period = estimate
            firstEstimateFrame = framesAppended
            clearRecent()
            return TempoEstimate(period: estimate, switched: true)
        }
        let slot = recentIndex
        recent[slot] = estimate
        recentRelated[slot] = false
        recentIndex = (recentIndex + 1) % recent.count
        recentCount = min(recentCount + 1, recent.count)

        if abs(estimate - current) / current < Self.followTolerance {
            let moved = current + Self.followRate * (estimate - current)
            period = moved
            previousFar = nil
            previousFarRelated = false
            return TempoEstimate(period: moved, switched: false)
        }
        if isEstablished, Self.isRelated(estimate, to: current) || continuesDriftingOctave(estimate, current: current) {
            recentRelated[slot] = true
            previousFar = estimate
            previousFarRelated = true
            // Октава плывет вместе с музыкой: согласие до `followTolerance`; 3:2 и 4:3 до 4 %.
            let agreement = Self.isNearOctave(estimate, to: current) ? Self.followTolerance : Self.relatedTolerance
            var agreeing = 0
            for index in 0..<recentCount where abs(recent[index] - estimate) / estimate < agreement {
                agreeing += 1
            }
            guard agreeing >= Self.relatedSwitchUpdates else {
                return TempoEstimate(period: current, switched: false)
            }
            return switchTo(estimate)
        }
        if let previousFar, abs(estimate - previousFar) / previousFar < Self.switchTolerance {
            return switchTo(estimate)
        }
        previousFar = estimate
        previousFarRelated = false
        return TempoEstimate(period: current, switched: false)
    }

    /// Новая частота шагов (смена частоты дискретизации): буферы и окна пересчитываются, история и
    /// темп начинаются заново.
    public mutating func reconfigure(framesPerSecond: Double) {
        self = TempoEstimator(framesPerSecond: framesPerSecond)
    }

    /// Пауза, перемотка или смена источника: история и темп начинаются заново. С `keepPeriod` (пауза
    /// в том же треке, `BeatTracker.reset(keepTempo:)`) период остается: первая оценка нового потока
    /// рядом с ним идет как подстройка, а не как смена темпа. Темп тогда считается установившимся,
    /// как только наберется история первой оценки (`minimumHistory`), и кратная оценка не
    /// перебрасывает его без `relatedSwitchUpdates` согласных.
    public mutating func reset(keepPeriod: Bool = false) {
        for index in history.indices {
            history[index] = 0
            kickHistory[index] = 0
        }
        writeIndex = 0
        count = 0
        framesAppended = 0
        if keepPeriod, period != nil {
            firstEstimateFrame = 0
        } else {
            period = nil
            firstEstimateFrame = nil
        }
        clearRecent()
    }

    private mutating func switchTo(_ estimate: Double) -> TempoEstimate {
        period = estimate
        clearRecent()
        return TempoEstimate(period: estimate, switched: true)
    }

    /// Оценка в пределах `octaveDriftTolerance` от октавы текущего периода, которая продолжает ряд
    /// кратных: идет сразу за кратной оценкой или совпадает (до `followTolerance`, как период следует
    /// за своими оценками) с медианой кратных оценок той же октавы в окне `recent`. Первое условие
    /// нужно при быстром дрейфе, когда медиана отстает: иначе такая оценка шла бы в правило двух
    /// далеких и образовала пару с прошлой кратной (158, 158, 158, 158, 151, 148.5 при 78.5 BPM
    /// переключали на 148.5). Ряд кратных начинается только с оценки в пределах `relatedTolerance`,
    /// поэтому скачок прямо на 1.9× (80 -> 150 BPM, 6.25 % от удвоения) остается далеким и
    /// принимается по двум согласным. Журнал 2 владельца: 157.9 при 78.8 кратная, затем 149.0 (5.5 %
    /// от удвоения) и 150.7 ее продолжают, и темп не уходит на 150.
    private mutating func continuesDriftingOctave(_ estimate: Double, current: Double) -> Bool {
        guard Self.isNearOctave(estimate, to: current) else { return false }
        if previousFarRelated { return true }
        let target = (estimate > current ? 2 : 0.5) * current
        var count = 0
        for index in 0..<recentCount where recentRelated[index] {
            let value = recent[index]
            guard abs(value / target - 1) < Self.octaveDriftTolerance else { continue }
            // Вставкой по возрастанию: не больше `relatedWindow` значений раз в `updateInterval`.
            var position = count
            while position > 0, medianScratch[position - 1] > value {
                medianScratch[position] = medianScratch[position - 1]
                position -= 1
            }
            medianScratch[position] = value
            count += 1
        }
        guard count > 0 else { return false }
        let median = count % 2 == 1
            ? medianScratch[count / 2]
            : 0.5 * (medianScratch[count / 2 - 1] + medianScratch[count / 2])
        return abs(estimate - median) / median < Self.followTolerance
    }

    private mutating func clearRecent() {
        recentCount = 0
        recentIndex = 0
        previousFar = nil
        previousFarRelated = false
    }

    private var isEstablished: Bool {
        guard let firstEstimateFrame else { return false }
        return Double(framesAppended - firstEstimateFrame) / framesPerSecond >= Self.establishedAfter
    }

    /// Оценка в пределах `octaveDriftTolerance` от удвоенного или половинного текущего периода.
    private static func isNearOctave(_ estimate: Double, to current: Double) -> Bool {
        let octave: Double = estimate > current ? 2 : 0.5
        return abs(estimate / (octave * current) - 1) < octaveDriftTolerance
    }

    private static func isRelated(_ estimate: Double, to current: Double) -> Bool {
        let ratio = estimate / current
        return relatedRatios.contains { abs(ratio / $0 - 1) < relatedTolerance }
    }

    /// Центр окна гармоники `h` лага `halfLag / 2`: `h · halfLag / 2`, половина вверх.
    private static func center(harmonic: Int, halfLag: Int) -> Int {
        (harmonic * halfLag + 1) / 2
    }

    /// Лаг доли в половинах шага прореженной истории с дробной частью, `nil` без периодичности.
    private mutating func bestHalfLag() -> Double? {
        guard comb(kick: false) else { return nil }
        if isEstablished, let period {
            for halfLag in halfLagMin...halfLagMax where scores[halfLag] > 0 {
                let lagPeriod = Double(halfLag) / 2 / decimatedRate
                if abs(lagPeriod - period) / period < Self.followTolerance {
                    scores[halfLag] *= 1 + Self.currentBonus
                }
            }
        }

        var best = halfLagMin
        for halfLag in halfLagMin...halfLagMax where scores[halfLag] > scores[best] {
            best = halfLag
        }
        guard scores[best] > 0 else { return nil }
        best = kickTieBreak(best)

        let left = scores[best - 1]
        let middle = scores[best]
        let right = scores[best + 1]
        let curvature = left - 2 * middle + right
        guard curvature < 0 else { return Double(best) }
        let offset = 0.5 * (left - right) / curvature
        return Double(best) + min(max(offset, -0.5), 0.5)
    }

    /// Соперники лучшего лага в отношениях `kickTieRatios`, набравшие не меньше `1 - kickTieMargin`
    /// от него, сравниваются по гребенке функции бочки: соперник выбирается, только если его
    /// поддержка выше поддержки лучшего на `kickSupportMargin` от ее величины.
    private mutating func kickTieBreak(_ best: Int) -> Int {
        let threshold = (1 - Self.kickTieMargin) * scores[best]
        var hasRival = false
        for ratio in Self.kickTieRatios {
            if let rival = rival(of: best, ratio: ratio), scores[rival] >= threshold {
                hasRival = true
                break
            }
        }
        guard hasRival, comb(kick: true) else { return best }
        let incumbent = kickSupport(best)
        var chosen = best
        var support = incumbent + Self.kickSupportMargin * abs(incumbent)
        for ratio in Self.kickTieRatios {
            guard let rival = rival(of: best, ratio: ratio), scores[rival] >= threshold else { continue }
            let rivalSupport = kickSupport(rival)
            if rivalSupport > support {
                chosen = rival
                support = rivalSupport
            }
        }
        return chosen
    }

    /// Лучший лаг в пределах ±2 половин шага от `best × ratio`, `nil` вне диапазона темпов.
    private func rival(of best: Int, ratio: Double) -> Int? {
        let target = Int((Double(best) * ratio).rounded())
        guard target >= halfLagMin, target <= halfLagMax else { return nil }
        var result = max(halfLagMin, target - 2)
        for halfLag in result...min(halfLagMax, target + 2) where scores[halfLag] > scores[result] {
            result = halfLag
        }
        return result
    }

    /// Наибольшая оценка гребенки бочки в пределах ±1 половины шага.
    private func kickSupport(_ halfLag: Int) -> Double {
        var support = -Double.infinity
        for lag in max(halfLagMin, halfLag - 1)...min(halfLagMax, halfLag + 1) {
            support = max(support, scores[scoreStride + lag])
        }
        return support
    }

    /// Гребенка по широкополосной истории (в квадрате, с приоритетом) или по истории бочки (без
    /// приоритета) в `scores`.
    /// `false`, если в истории нет энергии или она слишком коротка.
    private mutating func comb(kick: Bool) -> Bool {
        let capacity = history.count
        let n = count / 2
        // Пары от самого старого из последних 2n шагов; среднее вычитается.
        var start = (writeIndex - 2 * n + capacity) % capacity
        var mean = 0.0
        for i in 0..<n {
            let next = (start + 1) % capacity
            let value: Double
            if kick {
                value = 0.5 * (Double(kickHistory[start]) + Double(kickHistory[next]))
            } else {
                let first = Double(history[start])
                let second = Double(history[next])
                value = 0.5 * (first * first + second * second)
            }
            decimated[i] = value
            mean += value
            start = (next + 1) % capacity
        }
        mean /= Double(max(n, 1))
        var energy = 0.0
        for i in 0..<n {
            let centered = decimated[i] - mean
            energy += centered * centered
            weights[i] = recency[n - 1 - i]
            decimated[i] = centered * weights[i]
        }
        guard energy > 1e-9 * Double(max(n, 1)) else { return false }

        // Автокорреляция с весом свежести; лаги, у которых меньше `minimumOverlap` пар, не считаются.
        let maxLag = min(acf.count - 1, n - minimumOverlap)
        guard maxLag >= Self.center(harmonic: 1, halfLag: halfLagMax + 1) + 1 else { return false }
        if normCount != n {
            // Веса зависят только от длины истории: после заполнения суммы не меняются.
            for l in 1..<norms.count where l < n {
                var norm = 0.0
                for i in 0..<(n - l) {
                    norm += weights[i] * weights[i + l]
                }
                norms[l] = norm
            }
            normCount = n
        }
        for l in 1...maxLag {
            var sum = 0.0
            for i in 0..<(n - l) {
                sum += decimated[i] * decimated[i + l]
            }
            acf[l] = sum / norms[l]
        }

        // Соседи по краям диапазона нужны только параболе.
        let offset = kick ? scoreStride : 0
        for halfLag in (halfLagMin - 1)...(halfLagMax + 1) {
            var sum = 0.0
            var weight = 0.0
            for h in 1...Self.harmonics {
                let center = Self.center(harmonic: h, halfLag: halfLag)
                guard center + 1 <= maxLag else { break }
                let w = 1 / Double(h).squareRoot()
                sum += max(acf[center - 1], acf[center], acf[center + 1]) * w
                weight += w
            }
            scores[offset + halfLag] = sum / weight * combWeight * (kick ? 1 : prior[halfLag])
        }
        return true
    }
}
