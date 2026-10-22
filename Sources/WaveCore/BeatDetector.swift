import Foundation

/// Детектор ударов по спектральному потоку низких полос.
///
/// Вход это линейные амплитуды полос с центром до 150 Гц. Поток это сумма положительных приростов
/// амплитуд относительно прошлого кадра, деленная на `1e-4 + средняя суммарная амплитуда` за
/// `historySeconds`, поэтому порог не зависит от громкости. Среднее и стандартное отклонение
/// считаются по прошлым кадрам (текущий в историю не входит). Все кадры истории нормируются одним
/// текущим знаменателем: иначе выброс из первых кадров (тишина, потом клик, нормировка по почти
/// нулевой средней) десятки кадров держал бы порог недостижимым. Первые полсекунды истории удар
/// не может сработать.
public struct BeatDetector: Sendable {
    public let historySeconds: Double
    public let thresholdSigma: Float
    public let minInterval: Double
    public let minRelativeFlux: Float

    /// Сколько истории нужно накопить до первого возможного удара.
    private static let warmUpSeconds = 0.5
    private static let normalizationFloor: Float = 1e-4

    private struct Frame: Sendable {
        var time: Double
        var rise: Float
        var total: Float
    }

    private var previous: [Float] = []
    private var history: [Frame] = []
    private var lastBeatTime: Double?

    public init(
        historySeconds: Double = 1.0,
        thresholdSigma: Float = 1.5,
        minInterval: Double = 0.25,
        minRelativeFlux: Float = 0.15
    ) {
        self.historySeconds = historySeconds
        self.thresholdSigma = thresholdSigma
        self.minInterval = minInterval
        self.minRelativeFlux = minRelativeFlux
    }

    /// Обрабатывает кадр, возвращает `true`, если в нем начался удар.
    public mutating func process(lowBandAmplitudes: [Float], time: Double) -> Bool {
        defer { previous = lowBandAmplitudes }
        guard previous.count == lowBandAmplitudes.count else {
            // Первый кадр или смена числа полос: сравнивать не с чем.
            history.removeAll(keepingCapacity: true)
            return false
        }

        var positiveRise: Float = 0
        var total: Float = 0
        for (index, amplitude) in lowBandAmplitudes.enumerated() {
            total += amplitude
            positiveRise += max(amplitude - previous[index], 0)
        }

        // Нормировка: средняя суммарная амплитуда по прошлым кадрам, при пустой истории текущая.
        var meanTotal = total
        if !history.isEmpty {
            meanTotal = history.reduce(0) { $0 + $1.total } / Float(history.count)
        }
        let denominator = Self.normalizationFloor + meanTotal
        let flux = positiveRise / denominator

        var isBeat = false
        if let oldest = history.first, time - oldest.time >= Self.warmUpSeconds - 1e-9 {
            let count = Float(history.count)
            let mean = history.reduce(0) { $0 + $1.rise } / count / denominator
            let variance = history.reduce(0) {
                let d = $1.rise / denominator - mean
                return $0 + d * d
            } / count
            let threshold = mean + thresholdSigma * variance.squareRoot()
            let spaced = lastBeatTime.map { time - $0 >= minInterval - 1e-9 } ?? true
            isBeat = flux > threshold && flux > minRelativeFlux && spaced
        }
        if isBeat { lastBeatTime = time }

        history.append(Frame(time: time, rise: positiveRise, total: total))
        let cutoff = time - historySeconds
        if let firstKept = history.firstIndex(where: { $0.time >= cutoff - 1e-9 }), firstKept > 0 {
            history.removeFirst(firstKept)
        }
        return isBeat
    }

    public mutating func reset() {
        previous.removeAll(keepingCapacity: true)
        history.removeAll(keepingCapacity: true)
        lastBeatTime = nil
    }
}

/// Огибающая удара: 1 в момент удара, затем экспоненциальный спад.
/// Порядок в каждом кадре: сначала `step`, потом `trigger`.
public struct BeatEnvelope: Sendable {
    public let decay: Double
    public private(set) var value: Float = 0

    public init(decay: Double = 0.06) {
        self.decay = decay
    }

    public mutating func trigger() {
        value = 1
    }

    public mutating func step(dt: Double) {
        value *= Float(exp(-dt / decay))
    }
}
