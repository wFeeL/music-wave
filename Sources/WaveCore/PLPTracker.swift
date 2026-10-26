// Перенос real-time PLP (Predominant Local Pulse) из `realtimeplp.py`:
// P. Meier, C.-Y. Chiu, M. Müller, "A Real-Time Beat Tracking System with Zero Latency and Enhanced
// Controllability", TISMIR 7(1), 2024, https://doi.org/10.5334/tismir.189; P. Meier, S. Schwär,
// M. Müller, "A Real-Time Approach for Estimating Pulse Tracking Parameters for Beat-Synchronous
// Audio Effects", DAFx 2024 (нормировки alpha и beta). Исходник: https://github.com/groupmm/real_time_plp
// (файл realtimeplp.py, автор Peter Meier, версия 0.0.1 от 2024-10-01).
//
// MIT License
//
// Copyright (c) 2024 Fraunhofer IIS
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
// associated documentation files (the "Software"), to deal in the Software without restriction,
// including without limitation the rights to use, copy, modify, merge, publish, distribute,
// sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all copies or
// substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT
// NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES
// OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

import Foundation

/// Фаза доли и уверенность по real-time PLP (Meier, Chiu, Müller 2024, исходник и лицензия в шапке
/// файла): второе мнение о фазе рядом с ФАПЧ `BeatTracker`. Захвата, сброса и счета попаданий нет:
/// фаза есть всегда, уверенность растет и спадает плавно.
///
/// На каждом кадре функции онсетов, как в `realtimeplp.py`:
/// 1. `BeatActivation.normalization`: из значения вычитается среднее последних `localAverageFrames`
///    значений (с текущим, только прошлое), отрицательное обнуляется. Для 10 кадров исходника
///    (512 сэмплов при 48 кГц) это `localAverageSeconds`;
/// 2. `Tempogram`: окно Ханна `np.hanning(N)`, `N = round(window × fps)`, заполнена только прошлая
///    половина (последний кадр в `N / 2 − 1`, будущая половина нули). Для каждого темпа от `minBPM`
///    до `maxBPM` с шагом 1 BPM коэффициент `F(θ) = Σ_m Δ(m) w(m) exp(−2πi (θ / 60) m / fps)`;
/// 3. `Kernel`: лучший темп `θ* = argmax |F|`, ядро `w(t) cos(2π(t ω* − φ))`, `φ = −arg F(θ*) / 2π`, на
///    всем окне (прошлое и будущее);
/// 4. `PredominantLocalPulse`: ядро каждого кадра прибавляется к буферу пульса, буфер сдвигается на
///    кадр. Будущая половина ядра уже несет предсказанные доли;
/// 5. уверенность это огибающая beta (`ControlSignals.beta_confidence`): огибающая буфера, деленная
///    на сумму окон, которые перекрывают место чтения (нормировка alpha), в 0...1. Она высокая, когда
///    ядра подряд согласны по темпу и фазе, и низкая, когда они гасят друг друга.
///
/// Отличия от исходника:
/// - темпограмма считается скользящим ДПФ: окно Ханна это три комплексные экспоненты, поэтому
///   `F(θ) = 0.5 G(ω) − 0.25 G(ω − 1/(N − 1)) − 0.25 G(ω + 1/(N − 1))`, где `G` это ДПФ прошлой
///   половины без окна, а оно сдвигается за O(1) на бин. Результат тот же (сверено с прямой суммой в
///   `tempogramMatchesTheDirectSum`);
/// - ядро комплексное, `w(t) (F / |F|) exp(2πi ω* t)`: его действительная часть равна ядру исходника
///   (`pulseMatchesTheReferenceOverlapAdd`), аргумент суммы это фаза, модуль это огибающая без
///   преобразования Гильберта (в исходнике `|hilbert(x)|` по всему буферу на каждом кадре; для
///   суммы узкополосных ядер это та же огибающая с точностью до краев буфера);
/// - буфер хранит только место чтения и будущее (с `N / 2 − 1` до `N − 1`): прошлое уже не читается;
/// - читается последний кадр (`N / 2 − 1`), а не следующий (`N / 2`, lookahead 0 исходника): фаза
///   относится к последнему поданному кадру;
/// - кадр, у которого в прошлой половине окна нет ни одной ненулевой активации (тишина), ядра не
///   дает: в исходнике argmax нулей дает темп 60 с фазой 0, и тишина копила бы уверенность 1.
///   Тишина определяется счетом ненулевых активаций, а не порогом по |F|²: скользящее ДПФ после
///   вычитания старых значений хранит остаток округления, и после громкого звука он выше любого
///   разумного порога. Когда ненулевых активаций не осталось, суммы ДПФ обнуляются (точное значение).
///
/// Свойства на нашей функции онсетов (замеры задачи B6). Уверенность откалибрована (на GTZAN tune,
/// группа steady, от 0.9 фаза верна в 96 % кадров, ниже 0.5 в 30-44 %), но фаза в целом верна только
/// в половине кадров: максимум темпограммы с половинным окном 3 с широкий, и соседние темпы и «и» с
/// хэтом его перетягивают. Частота хэта восьмыми выше `maxBPM` утекает на край диапазона (на 100 BPM
/// темп стоит на 180). В розовом шуме средняя уверенность около 0.25, пики до 0.67.
///
/// `process` не выделяет памяти: все буферы заданы в `init`. На кадр около 360 комплексных шагов ДПФ
/// и `N / 2 + 1` шагов ядра; на Linux (release) 30 с при 187.5 кадрах в секунду около 0.02 с.
public struct PLPTracker: Sendable {
    /// Окно локального среднего исходника: 10 кадров по 512 сэмплов при 48 кГц.
    public static let localAverageSeconds = 10.0 * 512 / 48_000

    /// Кадров в локальном среднем при данной частоте кадров, не меньше 1.
    static func localAverageFrames(framesPerSecond: Double) -> Int {
        max(Int((localAverageSeconds * framesPerSecond).rounded()), 1)
    }

    public let framesPerSecond: Double
    public let minBPM: Double
    public let maxBPM: Double
    public let window: Double
    /// Длина окна N в кадрах.
    let windowLength: Int
    /// Место чтения и будущее: `N − N / 2 + 1` кадров.
    private let pulseLength: Int
    private let tempoCount: Int

    /// Частота каждого темпа, циклов на кадр.
    private let omegas: [Double]
    /// Постоянные бинов ДПФ, по четыре на бин `3k + j` (j: ω, ω − 1/(N − 1), ω + 1/(N − 1) темпа k):
    /// поворот за кадр `exp(2πiν)` и множитель нового значения `exp(−2πiν (N / 2 − 1))`.
    private let binConstants: [Double]
    /// ДПФ прошлой половины без окна, по два числа на бин.
    private var binSums: [Double]
    /// Ядро каждого темпа, по четыре числа: `exp(2πi ω (N / 2 − 1))` в месте чтения и шаг `exp(2πi ω)`.
    private let kernelConstants: [Double]
    /// Окно Ханна с места чтения до конца окна.
    private let kernelWindow: [Double]
    /// Сумма `kernelWindow`: огибающая, деленная на нее, в 0...1 (нормировка alpha).
    private let normalization: Double

    /// Кольцо прошлой половины активаций; `historyWrite` указывает на самое старое значение.
    private var history: [Double]
    private var historyWrite = 0
    /// Ненулевых активаций в `history`.
    private var activeFrames = 0
    /// Кольцо сырых значений для локального среднего и их сумма.
    private var rawRing: [Double]
    private var rawWrite = 0
    private var rawSum = 0.0
    /// Буфер пульса с места чтения в будущее, кольцо по два числа на кадр; `pulseRead` это место
    /// последнего кадра.
    private var pulse: [Double]
    private var pulseRead = 0

    /// Фаза доли в последнем кадре, 0..<1: 0 на доле, растет со временем.
    public private(set) var phase: Double = 0
    /// Огибающая beta в последнем кадре, 0...1.
    public private(set) var confidence: Float = 0
    /// Период лучшего темпа последнего кадра, секунды; `nil`, пока в окне нет активаций.
    public private(set) var period: Double?
    /// Значение буфера пульса в последнем кадре (для сверки с исходником).
    private(set) var pulseValue: (re: Double, im: Double) = (0, 0)

    public init(framesPerSecond: Double, minBPM: Double = 60, maxBPM: Double = 180, window: Double = 6) {
        precondition(framesPerSecond > 0, "framesPerSecond must be positive")
        precondition(minBPM > 0 && maxBPM >= minBPM, "BPM range must be positive and ordered")
        precondition(window > 0, "window must be positive")
        self.framesPerSecond = framesPerSecond
        self.minBPM = minBPM
        self.maxBPM = maxBPM
        self.window = window
        let n = max(Int((window * framesPerSecond).rounded()), 4)
        let half = n / 2
        windowLength = n
        pulseLength = n - half + 1
        tempoCount = Int((maxBPM - minBPM).rounded(.down)) + 1
        let omegas = (0..<tempoCount).map { (minBPM + Double($0)) / 60 / framesPerSecond }
        self.omegas = omegas
        let shift = 1 / Double(n - 1)
        var binConstants: [Double] = []
        var kernelConstants: [Double] = []
        for omega in omegas {
            for nu in [omega, omega - shift, omega + shift] {
                let entry = -2 * Double.pi * Self.fraction(nu * Double(half - 1))
                binConstants += [cos(2 * Double.pi * nu), sin(2 * Double.pi * nu), cos(entry), sin(entry)]
            }
            let start = 2 * Double.pi * Self.fraction(omega * Double(half - 1))
            kernelConstants += [cos(start), sin(start), cos(2 * Double.pi * omega), sin(2 * Double.pi * omega)]
        }
        self.binConstants = binConstants
        self.kernelConstants = kernelConstants
        binSums = [Double](repeating: 0, count: 6 * tempoCount)
        let kernelWindow = ((half - 1)..<n).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n - 1)) }
        self.kernelWindow = kernelWindow
        normalization = kernelWindow.reduce(0, +)
        history = [Double](repeating: 0, count: half)
        rawRing = [Double](repeating: 0, count: Self.localAverageFrames(framesPerSecond: framesPerSecond))
        pulse = [Double](repeating: 0, count: 2 * pulseLength)
    }

    /// Дробная часть, чтобы фаза больших аргументов считалась точно.
    private static func fraction(_ x: Double) -> Double {
        x - x.rounded(.down)
    }

    /// Очередной кадр функции онсетов. NaN, бесконечность и отрицательные значения считаются нулем.
    public mutating func process(odf: Float) {
        let raw = odf.isFinite ? Double(max(odf, 0)) : 0
        // Локальное среднее по прошлому (с текущим кадром) и однополупериодное выпрямление.
        rawSum += raw - rawRing[rawWrite]
        rawRing[rawWrite] = raw
        rawWrite = (rawWrite + 1) % rawRing.count
        let activation = max(raw - max(rawSum, 0) / Double(rawRing.count), 0)

        let oldest = history[historyWrite]
        history[historyWrite] = activation
        historyWrite = (historyWrite + 1) % history.count
        if oldest != 0 { activeFrames -= 1 }
        if activation != 0 { activeFrames += 1 }
        let tempoCount = tempoCount
        // Скользящее ДПФ прошлой половины, G' = r (G − старое) + новое × exp(−2πiν (N/2 − 1)), и argmax
        // модуля темпограммы (строго больше, как `np.argmax`: при равенстве первый, меньший темп).
        let (best, bestIndex, bestRe, bestIm) = binSums.withUnsafeMutableBufferPointer { sums in
            binConstants.withUnsafeBufferPointer { constants in
                var best = 0.0
                var bestIndex = -1
                var bestRe = 0.0
                var bestIm = 0.0
                for k in 0..<tempoCount {
                    var coefficientRe = 0.0
                    var coefficientIm = 0.0
                    for j in 0..<3 {
                        let bin = 3 * k + j
                        let re = sums[2 * bin] - oldest
                        let im = sums[2 * bin + 1]
                        let rotationRe = constants[4 * bin]
                        let rotationIm = constants[4 * bin + 1]
                        let nextRe = rotationRe * re - rotationIm * im + activation * constants[4 * bin + 2]
                        let nextIm = rotationRe * im + rotationIm * re + activation * constants[4 * bin + 3]
                        sums[2 * bin] = nextRe
                        sums[2 * bin + 1] = nextIm
                        let weight = j == 0 ? 0.5 : -0.25
                        coefficientRe += weight * nextRe
                        coefficientIm += weight * nextIm
                    }
                    let magnitude = coefficientRe * coefficientRe + coefficientIm * coefficientIm
                    if magnitude > best {
                        best = magnitude
                        bestIndex = k
                        bestRe = coefficientRe
                        bestIm = coefficientIm
                    }
                }
                return (best, bestIndex, bestRe, bestIm)
            }
        }

        if activeFrames == 0, oldest != 0 {
            // Последняя активация ушла из окна: ДПФ пустой половины точно ноль, остаток округления не нужен.
            for index in binSums.indices {
                binSums[index] = 0
            }
        }

        let read = pulseRead
        let length = pulseLength
        if bestIndex >= 0, activeFrames > 0 {
            // Ядро лучшего темпа в буфер пульса с места чтения до конца окна.
            let magnitude = best.squareRoot()
            let unitRe = bestRe / magnitude
            let unitIm = bestIm / magnitude
            let startRe = kernelConstants[4 * bestIndex]
            let startIm = kernelConstants[4 * bestIndex + 1]
            let stepRe = kernelConstants[4 * bestIndex + 2]
            let stepIm = kernelConstants[4 * bestIndex + 3]
            pulse.withUnsafeMutableBufferPointer { pulse in
                kernelWindow.withUnsafeBufferPointer { window in
                    var re = unitRe * startRe - unitIm * startIm
                    var im = unitRe * startIm + unitIm * startRe
                    var slot = read
                    for t in 0..<length {
                        pulse[2 * slot] += window[t] * re
                        pulse[2 * slot + 1] += window[t] * im
                        let nextRe = re * stepRe - im * stepIm
                        im = re * stepIm + im * stepRe
                        re = nextRe
                        slot += 1
                        if slot == length { slot = 0 }
                    }
                }
            }
            period = 1 / (omegas[bestIndex] * framesPerSecond)
        } else {
            period = nil
        }

        let valueRe = pulse[2 * read]
        let valueIm = pulse[2 * read + 1]
        pulseValue = (valueRe, valueIm)
        let envelope = (valueRe * valueRe + valueIm * valueIm).squareRoot()
        confidence = Float(min(envelope / normalization, 1))
        if envelope > 0 {
            let turns = atan2(valueIm, valueRe) / (2 * Double.pi)
            phase = turns < 0 ? turns + 1 : turns
            if phase >= 1 { phase = 0 }
        } else {
            phase = 0
        }
        // Место последнего кадра больше не читается: оно станет самым дальним будущим.
        pulse[2 * read] = 0
        pulse[2 * read + 1] = 0
        pulseRead = (read + 1) % length
    }

    /// Все начинается заново, как после `init`.
    public mutating func reset() {
        for index in binSums.indices {
            binSums[index] = 0
        }
        for index in history.indices {
            history[index] = 0
        }
        historyWrite = 0
        activeFrames = 0
        for index in rawRing.indices {
            rawRing[index] = 0
        }
        rawWrite = 0
        rawSum = 0
        for index in pulse.indices {
            pulse[index] = 0
        }
        pulseRead = 0
        phase = 0
        confidence = 0
        period = nil
        pulseValue = (0, 0)
    }

    /// Коэффициент темпограммы темпа `minBPM + index` (для сверки с исходником).
    func tempogram(_ index: Int) -> (re: Double, im: Double) {
        var re = 0.0
        var im = 0.0
        for j in 0..<3 {
            let weight = j == 0 ? 0.5 : -0.25
            re += weight * binSums[2 * (3 * index + j)]
            im += weight * binSums[2 * (3 * index + j) + 1]
        }
        return (re, im)
    }

    /// Прошлая половина активаций от старой к новой (для сверки с исходником).
    func recentActivations() -> [Double] {
        (0..<history.count).map { history[(historyWrite + $0) % history.count] }
    }
}
