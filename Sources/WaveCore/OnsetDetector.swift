import Foundation

/// Функция онсетов SuperFlux (Böck, Widmer 2013): логарифмический спектральный поток с
/// максимум-фильтром по соседям и задержкой сравнения.
///
/// `L_k = log1p(γ A_k)`, `ODF = Σ_k w_k · max(0, L_k(n) − max(L_{k−1..k+1}(n − μ_k)))`, соседи за
/// краями вектора не берутся. Логарифм делает порог почти независимым от громкости, а максимум по
/// соседним элементам на прошлом шаге убирает медленные глиссандо (хвост 808) и вибрато. Пока в
/// истории меньше `μ_k` шагов, элемент k в поток не входит.
public struct SuperFlux: Sendable {
    public let gamma: Float
    private let lags: [Int]
    private let weights: [Float]
    private let count: Int
    private let depth: Int
    /// Кольцо прошлых L: `depth` строк по `count`, строка `newestRow` это шаг n - 1.
    private var history: [Float]
    private var current: [Float]
    private var newestRow = 0
    private var filled = 0

    /// - Parameters:
    ///   - lags: μ_k для каждого элемента входа, не меньше 1.
    ///   - weights: w_k для каждого элемента входа.
    public init(lags: [Int], weights: [Float], gamma: Float = 1000) {
        precondition(lags.count == weights.count, "lags and weights must have the same count")
        precondition(lags.allSatisfy { $0 >= 1 }, "lags must be at least 1")
        self.gamma = gamma
        self.lags = lags
        self.weights = weights
        count = lags.count
        depth = lags.max() ?? 1
        history = [Float](repeating: 0, count: depth * count)
        current = [Float](repeating: 0, count: count)
    }

    /// Поток для очередного шага. Без выделения памяти.
    /// - Precondition: `amplitudes.count` равно числу элементов из `init`.
    public mutating func process(_ amplitudes: UnsafeBufferPointer<Float>) -> Float {
        precondition(amplitudes.count == count, "amplitudes.count must match lags.count")
        guard count > 0 else { return 0 }
        let gamma = gamma
        let depth = depth
        let count = count
        let filled = filled
        let newestRow = newestRow
        var flux: Float = 0

        current.withUnsafeMutableBufferPointer { current in
            for k in 0..<count {
                // NaN и отрицательные амплитуды считаются нулем, бесконечность ограничена.
                let a = amplitudes[k]
                current[k] = log1p(gamma * (a > 0 ? min(a, 1e6) : 0))
            }
            history.withUnsafeMutableBufferPointer { history in
                lags.withUnsafeBufferPointer { lags in
                    weights.withUnsafeBufferPointer { weights in
                        for k in 0..<count where lags[k] <= filled {
                            let row = (newestRow - (lags[k] - 1) + depth) % depth
                            let base = row * count
                            var reference = history[base + k]
                            if k > 0 { reference = max(reference, history[base + k - 1]) }
                            if k + 1 < count { reference = max(reference, history[base + k + 1]) }
                            flux += weights[k] * max(0, current[k] - reference)
                        }
                    }
                }
                let next = (newestRow + 1) % depth
                let base = next * count
                for k in 0..<count {
                    history[base + k] = current[k]
                }
            }
        }
        self.newestRow = (newestRow + 1) % depth
        self.filled = min(filled + 1, depth)
        return flux
    }

    /// Забывает историю: следующий шаг сравнивать не с чем, он дает 0.
    public mutating func reset() {
        filled = 0
        newestRow = 0
    }
}

/// Выбор пиков функции онсетов в реальном времени (Böck, Krebs, Schedl 2012): только прошлые шаги,
/// поэтому онсет находится на фронте, без ожидания будущих кадров.
///
/// Онсет на шаге n, если выполнено все (окна в шагах, `round(секунды / шаг)`, не меньше 1):
/// ```
/// odf(n) >= max(odf[n-preMax ... n-1])
/// odf(n) >  mean(odf[n-preAvg ... n-1]) + delta * P(n)       // P = max(odf, P * exp(-hop / 3 s))
/// odf(n) >  longFactor * P_long(n)                            // то же с 10 с
/// odf(n) >  max(F(n), relativeFloor * P(n))  и  levelDB(n) > minLevelDB
///     F = floor или, с peakContrast > 0, min(floor, max(lowFloor, peakContrast * T, accentFloor * A))
/// levelDB(n) - levelDB(n - riseLag) >= minRiseDB              // настоящий подъем, не колебание шума
/// n - lastOnset >= combine
/// ```
/// Подъем уровня считается от уровня окна `riseLag` (около 16 мс, почти длина окна) назад, а не от
/// минимума за 150 мс: в полосе бочки всего три бина, и уровень шума за 150 мс проваливается на
/// 10-18 дБ ниже среднего, так что выход из провала выглядел бы как подъем бочки.
/// После `init` и `reset()` прошлые odf считаются нулями, а уровни равными -120 dBFS.
public struct OnlinePeakPicker: Sendable {
    public struct Parameters: Sendable, Equatable {
        /// Окно локального максимума, секунды.
        public var preMax: Double
        /// Окно среднего odf, секунды.
        public var preAvg: Double
        public var delta: Float
        /// Время спада следящего пика P, секунды.
        public var followerRelease: Double
        /// Время спада длинного следящего пика P_long, секунды.
        public var longRelease: Double
        public var longFactor: Float
        /// Абсолютный порог odf.
        public var floor: Float
        /// Порог odf относительно следящего пика P: при громких ударах порог растет вместе с ними,
        /// а абсолютный `floor` держит шум и тишину.
        public var relativeFloor: Float
        /// Опускание порога по типичному пику: порог `floor` опускается до
        /// `max(lowFloor, peakContrast * T, accentFloor * A)`, но не выше `floor`. Тихая доля, которая
        /// стоит над типичным пиком T намного выше пиков фона, проходит и под абсолютным порогом;
        /// случайный пик шума стоит над T меньше чем в `peakContrast` раз. 0 выключает правило.
        ///
        /// T это скользящее среднее логарифмов высот локальных максимумов odf (максимум в окне
        /// ±`preMax`, узнается через `preMax` шагов), шаг `typicalGain` на максимум. После `init` и
        /// `reset()` T = `floor / peakContrast`, то есть порог начинается с `floor`.
        public var peakContrast: Float
        /// Нижняя граница опущенного порога.
        public var lowFloor: Float
        /// Шаг средних T и A на один локальный максимум.
        public var typicalGain: Float
        /// Уровень акцента A: скользящее среднее логарифмов локальных максимумов выше
        /// `peakContrast * T`, шаг `typicalGain`; после `init` и `reset()` A = `floor / accentFloor`.
        /// Опущенный порог не ниже `accentFloor * A`: после громких долей он опускается медленно, а
        /// слабая доля намного ниже акцентов не проходит. 0 выключает.
        public var accentFloor: Float
        public var minLevelDB: Float
        public var minRiseDB: Float
        /// Насколько назад берется уровень для проверки подъема, секунды.
        public var riseLag: Double
        /// Наименьший промежуток между онсетами, секунды.
        public var combine: Double

        public init(
            preMax: Double = 0.030,
            preAvg: Double = 0.150,
            delta: Float = 0.3,
            followerRelease: Double = 3.0,
            longRelease: Double = 10.0,
            longFactor: Float = 0.25,
            floor: Float = 0.3,
            relativeFloor: Float = 0,
            peakContrast: Float = 0,
            lowFloor: Float = 0,
            typicalGain: Float = 0.05,
            accentFloor: Float = 0,
            minLevelDB: Float = -60,
            minRiseDB: Float = 9,
            riseLag: Double = 0.016,
            combine: Double = 0.150
        ) {
            self.preMax = preMax
            self.preAvg = preAvg
            self.delta = delta
            self.followerRelease = followerRelease
            self.longRelease = longRelease
            self.longFactor = longFactor
            self.floor = floor
            self.relativeFloor = relativeFloor
            self.peakContrast = peakContrast
            self.lowFloor = lowFloor
            self.typicalGain = typicalGain
            self.accentFloor = accentFloor
            self.minLevelDB = minLevelDB
            self.minRiseDB = minRiseDB
            self.riseLag = riseLag
            self.combine = combine
        }
    }

    private static let floorDB: Float = -120

    public let parameters: Parameters
    public let hopDuration: Double

    private let preMaxHops: Int
    private let preAvgHops: Int
    private let riseLagHops: Int
    private let combineHops: Int
    private let followerDecay: Float
    private let longDecay: Float

    /// Кольца прошлых odf и уровней, `ringIndex` это место следующей записи.
    private var odfRing: [Float]
    private var levelRing: [Float]
    private var ringIndex = 0
    private var follower: Float = 0
    private var longFollower: Float = 0
    private var hopsSinceOnset = Int.max
    /// Логарифм и значение типичного пика T и уровня акцента A (`Parameters.peakContrast`).
    private var logTypical: Float = 0
    private var typical: Float = 0
    private var logAccent: Float = 0
    private var accent: Float = 0

    public init(hopDuration: Double, parameters: Parameters = .init()) {
        precondition(hopDuration > 0, "hopDuration must be positive")
        self.hopDuration = hopDuration
        self.parameters = parameters
        func hops(_ seconds: Double) -> Int {
            max(1, Int((seconds / hopDuration).rounded()))
        }
        preMaxHops = hops(parameters.preMax)
        preAvgHops = hops(parameters.preAvg)
        riseLagHops = hops(parameters.riseLag)
        combineHops = hops(parameters.combine)
        followerDecay = Float(exp(-hopDuration / parameters.followerRelease))
        longDecay = Float(exp(-hopDuration / parameters.longRelease))
        let capacity = max(2 * preMaxHops + 1, preAvgHops, riseLagHops)
        odfRing = [Float](repeating: 0, count: capacity)
        levelRing = [Float](repeating: Self.floorDB, count: capacity)
        resetTypical()
    }

    /// Порог odf сейчас: `floor` или ниже, по типичному пику и уровню акцента.
    var effectiveFloor: Float {
        let p = parameters
        guard p.peakContrast > 0 else { return p.floor }
        return min(p.floor, max(p.lowFloor, p.peakContrast * typical, p.accentFloor * accent))
    }

    /// T и A с начала такие, что порог равен `floor`.
    private mutating func resetTypical() {
        let p = parameters
        typical = p.peakContrast > 0 ? p.floor / p.peakContrast : 0
        logTypical = typical > 0 ? log(typical) : 0
        accent = p.accentFloor > 0 ? p.floor / p.accentFloor : 0
        logAccent = accent > 0 ? log(accent) : 0
    }

    /// Обрабатывает шаг. Возвращает силу онсета `clamp(odf / P, 0, 1)`, если онсет сработал.
    /// Без выделения памяти.
    public mutating func process(_ odf: Float, levelDB: Float) -> Float? {
        let odf = odf.isFinite ? max(odf, 0) : 0
        let level = levelDB.isNaN ? Self.floorDB : max(levelDB, Self.floorDB)
        follower = max(odf, follower * followerDecay)
        longFollower = max(odf, longFollower * longDecay)
        if hopsSinceOnset < Int.max { hopsSinceOnset += 1 }

        let capacity = odfRing.count
        var recentMax: Float = 0
        var olderMax: Float = 0
        var sum: Float = 0
        for age in 1...capacity {
            let index = (ringIndex - age + capacity) % capacity
            if age < preMaxHops {
                recentMax = max(recentMax, odfRing[index])
            } else if age > preMaxHops, age <= 2 * preMaxHops {
                olderMax = max(olderMax, odfRing[index])
            }
            if age <= preAvgHops { sum += odfRing[index] }
        }
        let mean = sum / Float(preAvgHops)
        let earlierLevel = levelRing[(ringIndex - riseLagHops + capacity) % capacity]

        let p = parameters
        // Шаг `preMax` назад: локальный максимум в окне ±preMax вокруг него обновляет типичный пик.
        let candidate = odfRing[(ringIndex - preMaxHops + capacity) % capacity]
        if p.peakContrast > 0, candidate > 0, candidate > recentMax, candidate > odf, candidate >= olderMax {
            if p.accentFloor > 0, candidate > p.peakContrast * typical {
                logAccent += p.typicalGain * (log(candidate) - logAccent)
                accent = exp(logAccent)
            }
            logTypical += p.typicalGain * (log(candidate) - logTypical)
            typical = exp(logTypical)
        }
        recentMax = max(recentMax, candidate)
        let fires = odf >= recentMax
            && odf > mean + p.delta * follower
            && odf > p.longFactor * longFollower
            && odf > max(effectiveFloor, p.relativeFloor * follower)
            && level > p.minLevelDB
            && level - earlierLevel >= p.minRiseDB
            && hopsSinceOnset >= combineHops

        odfRing[ringIndex] = odf
        levelRing[ringIndex] = level
        ringIndex = (ringIndex + 1) % capacity

        guard fires else { return nil }
        hopsSinceOnset = 0
        return follower > 0 ? min(max(odf / follower, 0), 1) : 1
    }

    public mutating func reset() {
        for index in odfRing.indices {
            odfRing[index] = 0
            levelRing[index] = Self.floorDB
        }
        ringIndex = 0
        follower = 0
        longFollower = 0
        hopsSinceOnset = Int.max
        resetTypical()
    }
}
