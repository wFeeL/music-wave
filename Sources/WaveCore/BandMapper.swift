import Foundation

/// Слой волны: к какому диапазону частот относится полоса спектра.
public enum WaveLayer: Int, CaseIterable, Sendable {
    case bass, mid, high

    public var frequencyRange: ClosedRange<Double> {
        switch self {
        case .bass: 40...250
        case .mid: 250...4000
        case .high: 4000...16_000
        }
    }
}

/// Сводит амплитудный спектр БПФ к 24 логарифмическим полосам с уровнем в dBFS.
///
/// Уровень полосы это суммарная мощность бинов внутри полосы, деленная на ENBW окна Ханна (1.5),
/// поэтому синус амплитуды A дает A² при любом сдвиге относительно бина. Бин 0 (постоянная
/// составляющая) не учитывается. Если в полосу не попал ни один бин, мощность линейно
/// интерполируется между двумя бинами, окружающими центр полосы.
public struct BandMapper: Sendable {
    public static let bandCount = 24

    /// Эквивалентная шумовая полоса окна Ханна в бинах.
    private static let hannENBW: Double = 1.5
    private static let floorPower: Double = 1e-12
    private static let floorDB: Float = -120

    /// 25 границ полос, логарифмически равномерных от `minHz` до `maxHz`.
    public let edges: [Double]
    /// Геометрические центры полос.
    public let centers: [Double]

    private enum Source: Sendable {
        case bins(Range<Int>)
        /// Бины `lower` и `lower + 1`, `fraction` это положение центра полосы между ними.
        case interpolated(lower: Int, fraction: Double)
    }

    private let sources: [Source]
    private let layerRanges: [Range<Int>]

    public init(fftSize: Int, sampleRate: Double, minHz: Double = 40, maxHz: Double = 16_000) {
        precondition(fftSize >= 4, "fftSize must be at least 4")
        precondition(sampleRate > 0, "sampleRate must be positive")
        precondition(minHz > 0 && maxHz > minHz, "frequency range must be positive and ascending")

        let count = Self.bandCount
        let ratio = maxHz / minHz
        var edges = (0...count).map { minHz * pow(ratio, Double($0) / Double(count)) }
        edges[count] = maxHz
        self.edges = edges
        let centers = (0..<count).map { (edges[$0] * edges[$0 + 1]).squareRoot() }
        self.centers = centers

        // Бины 1..<fftSize/2 по полосам, бин 0 пропускаем.
        let binWidth = sampleRate / Double(fftSize)
        let binCount = fftSize / 2
        var firstBin = [Int?](repeating: nil, count: count)
        var lastBin = [Int](repeating: 0, count: count)
        for k in 1..<binCount {
            if let band = Self.bandIndex(containing: Double(k) * binWidth, edges: edges) {
                if firstBin[band] == nil { firstBin[band] = k }
                lastBin[band] = k
            }
        }
        sources = (0..<count).map { band in
            if let first = firstBin[band] {
                return .bins(first..<(lastBin[band] + 1))
            }
            let position = centers[band] / binWidth
            let lower = min(max(Int(position.rounded(.down)), 1), binCount - 2)
            let fraction = min(max(position - Double(lower), 0), 1)
            return .interpolated(lower: lower, fraction: fraction)
        }

        // Полоса относится к слою, в диапазон которого попадает ее центр.
        let layers = WaveLayer.allCases
        let assignment = centers.map { center in
            layers.first { center <= $0.frequencyRange.upperBound } ?? layers[layers.count - 1]
        }
        layerRanges = layers.map { layer in
            let members = assignment.indices.filter { assignment[$0] == layer }
            guard let first = members.first, let last = members.last else { return 0..<0 }
            return first..<(last + 1)
        }
    }

    /// Уровни полос в dBFS, пол -120. Бины сверх `amplitudes.count` считаются нулевыми.
    public func bandLevels(_ amplitudes: [Float]) -> [Float] {
        var levels = [Float](repeating: 0, count: Self.bandCount)
        amplitudes.withUnsafeBufferPointer { amplitudes in
            levels.withUnsafeMutableBufferPointer { bandLevels(amplitudes, into: $0) }
        }
        return levels
    }

    /// То же, что `bandLevels(_:)`, но в готовый буфер и без выделения памяти.
    /// - Precondition: `levels.count == BandMapper.bandCount`.
    public func bandLevels(_ amplitudes: UnsafeBufferPointer<Float>, into levels: UnsafeMutableBufferPointer<Float>) {
        precondition(levels.count == Self.bandCount, "levels.count must equal bandCount")
        for band in 0..<Self.bandCount {
            var power = 0.0
            switch sources[band] {
            case .bins(let range):
                for k in range where k < amplitudes.count {
                    let a = Double(amplitudes[k])
                    power += a * a
                }
            case .interpolated(let lower, let fraction):
                let a0 = lower < amplitudes.count ? Double(amplitudes[lower]) : 0
                let a1 = lower + 1 < amplitudes.count ? Double(amplitudes[lower + 1]) : 0
                power = (1 - fraction) * a0 * a0 + fraction * a1 * a1
            }
            let scaled = max(power / Self.hannENBW, Self.floorPower)
            levels[band] = max(Float(10 * log10(scaled)), Self.floorDB)
        }
    }

    /// Показатель наклона спектра для волн: уровень полосы поднимается как `(center / tiltReferenceHz)^0.35`.
    ///
    /// В cava `f^0.85` множит среднюю амплитуду бина. У нас мощность в логарифмической полосе
    /// суммируется, а ширина полосы растет пропорционально f, то есть уровень полосы уже несет
    /// множитель `f^0.5` по амплитуде. Поэтому эквивалент у нас `f^(0.85 - 0.5) = f^0.35`, около
    /// +2.1 дБ на октаву. Прямой перенос `f^0.85` дал бы примерно 44 дБ разницы между краями диапазона.
    public static let tiltExponent = 0.35
    /// Частота, на которой наклон равен 0 дБ.
    public static let tiltReferenceHz = 1000.0

    /// Наклон каждой полосы в дБ: `max(0, 20 × tiltExponent × log10(center / tiltReferenceHz))`.
    /// Наклон только поднимает: ниже 1 кГц он 0, поэтому бас и низ середины от него не меняются.
    /// Нормировка идет по слоям, и внутри слоя наклон почти сокращается; заметен он там, где слой
    /// прижат к `minPeakDB` или к разбросу слоев, то есть на тихих верхах. Срез ниже 1 кГц там же
    /// уводил бы бас на 7...10 дБ под `minPeakDB`, и тихие записи давали бы меньше баса.
    /// Прибавляется к уровням только для волн в режиме `auto`.
    public func tiltDB() -> [Float] {
        centers.map { Float(max(0, 20 * Self.tiltExponent * log10($0 / Self.tiltReferenceHz))) }
    }

    /// Полосы слоя (по центру полосы), подряд идущий диапазон индексов.
    public func bands(for layer: WaveLayer) -> Range<Int> {
        layerRanges[layer.rawValue]
    }

    /// Индекс полосы, для которой `edges[i] <= hz < edges[i + 1]` (последняя включает верхнюю границу).
    public func band(containing hz: Double) -> Int? {
        Self.bandIndex(containing: hz, edges: edges)
    }

    private static func bandIndex(containing hz: Double, edges: [Double]) -> Int? {
        let count = edges.count - 1
        guard hz >= edges[0], hz <= edges[count] else { return nil }
        if hz == edges[count] { return count - 1 }
        return (0..<count).first { hz >= edges[$0] && hz < edges[$0 + 1] }
    }
}
