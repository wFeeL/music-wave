import Foundation

/// Линия стиля «Спектр»: форма вдоль крыла идет через уровни 24 полос (`BandMapper.bandCount`).
///
/// Сначала гауссово сглаживание по полосам с отражением у краев (σ в полосах, `sigma(halfWidth:)`:
/// на узком крыле шире, чтобы мягкость в точках была одной и той же) и компенсация пика
/// `1 + 0.1 σ`. Полосы логарифмические, поэтому это сглаживание в долях октавы; оно же убирает
/// ступеньки на стыках слоев. Затем однородный кубический B-сплайн через сглаженные уровни с
/// отраженными концами: кривая C2 (без скачков кривизны, без плоских вершин на экстремумах), не
/// выходит за контрольные точки (ни ниже нуля, ни выше 1), ровные полосы дают ровную линию.
/// Затем «дыхание» (`Ripple.floor`, подъем середины линии) и бегущая рябь: множитель
/// `1 + depth × w(u)`, рябь умножает линию, поэтому тишина остается ровно нулем. В конце
/// «Размах» и мягкий предел `WaveShape.softLimit`, как у волн.
///
/// В крыле бас у выреза (x = 0), верх у внешнего края. В панели бас в середине, к обоим краям
/// идут верхние полосы, симметрично; касательная у баса нулевая, середина панели без излома.
/// y без знака, от нижней базовой линии (`WaveLookGeometry.Baseline.bottom`).
public enum SpectrumShape {
    /// Наименьшее и наибольшее σ из `sigma(halfWidth:)`, полосы.
    public static let minimumSigma = 1.0
    public static let maximumSigma = 3.0
    /// Ширина в точках, на которую приходится σ = 1: 24 полосы по 6 pt.
    static let sigmaWidth = 144.0
    /// Компенсация пика: уровни после сглаживания × `1 + peakCompensation × σ`.
    static let peakCompensation = 0.1

    /// σ сглаживания в полосах для половины линии шириной `halfWidth` pt (крыло или половина
    /// панели): clamp(144 / halfWidth, 1, 3). Крыло 64 pt дает 2.25, 200 pt и панель дают 1.
    /// Нулевая, отрицательная и NaN ширина дают наибольшее σ.
    public static func sigma(halfWidth: Double) -> Double {
        guard !halfWidth.isNaN, halfWidth > 0 else { return maximumSigma }
        return min(max(sigmaWidth / halfWidth, minimumSigma), maximumSigma)
    }

    /// Живое движение линии: бегущая рябь и «дыхание».
    ///
    /// Рябь `w(u) = (1 − h) sin(2π κ u − φc) + h sin(2π 2.3 κ u − φh)` с κ = 1.25 периода на
    /// крыло (в панели на половину, симметрично) и h = 0.15; с ростом фазы гребни бегут от выреза
    /// наружу. Фаза `motion.phase(.mid, profile:)`: скорость идет от медленной громкости середины.
    /// «Дыхание» `floor` поднимает линию на эту долю высоты, к вырезу и к внешнему краю подъем
    /// сходит на нет, в панели только к краям; подъем идет вместе с рябью.
    public struct Ripple: Sendable, Equatable {
        /// Глубина ряби по умолчанию: линия × (1 ± 0.12).
        public static let standardDepth = 0.12
        /// Подъем «дыхания» на полной медленной громкости середины.
        public static let floorScale = 0.04
        /// Периодов несущей на крыло (в панели на половину).
        static let cycles = 1.25
        /// Доля гармоники и во сколько раз она чаще несущей.
        static let harmonicShare = 0.15
        static let harmonicRatio = 2.3
        /// Где кончается сход подъема на нет у выреза и где начинается у внешнего края, доля
        /// половины линии.
        static let floorTaperIn = 0.25
        static let floorTaperOut = WaveShape.panelTaperStart

        /// Без ряби и без подъема.
        public static let none = Ripple(phase: WavePhase(carrier: 0, harmonic: 0), depth: 0, floor: 0)

        public var phase: WavePhase
        /// Глубина ряби, 0...1; 0 дает линию без ряби бит в бит.
        public var depth: Double
        /// Подъем «дыхания», доля высоты 0...1.
        public var floor: Double

        public init(phase: WavePhase, depth: Double = Ripple.standardDepth, floor: Double = 0) {
            self.phase = phase
            self.depth = depth
            self.floor = floor
        }

        /// Подъем «дыхания» от медленной громкости середины `slowLevel` (`WaveMotion.slowLevel(.mid)`):
        /// `0.04 × slowLevel`, громкость ограничивается 0...1. Ниже порога детектора простоя
        /// (`RenderIdleDetector.level`) ровно 0: медленная громкость в тишине спадает
        /// экспоненциально и иначе держала бы линию чуть выше нуля.
        public static func floor(slowLevel: Float) -> Double {
            guard slowLevel.isFinite, slowLevel >= RenderIdleDetector.level else { return 0 }
            return floorScale * Double(min(slowLevel, 1))
        }
    }

    /// Значения y в 0...1 в `output`. `.wing`: точка i лежит на полосе `23 × i / (count − 1)`.
    /// `.panel`: на полосе `23 × |2i − (count − 1)| / (count − 1)`. Плохие (не конечные и
    /// отрицательные) уровни считаются нулем, больше 1 ограничиваются 1, недостающие полосы
    /// это ноль, полосы сверх 24 не читаются. `smoothing`: σ в полосах (`sigma(halfWidth:)`),
    /// ограничивается 0...3, не конечное считается 0 (без сглаживания и без компенсации).
    /// `ripple`: рябь и «дыхание», глубина и подъем ограничиваются 0...1, не конечные считаются 0.
    /// `gain` (настройка «Размах») как в `WaveShape.samples`: y умножается на него до мягкого
    /// предела `WaveShape.softLimit`, отрицательный дает 0, не конечный считается 1.
    /// - Precondition: `output.count == max(count, 0)`.
    public static func samples(
        bands: [Float], count: Int, profile: WaveProfile, gain: Double, smoothing: Double, ripple: Ripple,
        into output: UnsafeMutableBufferPointer<Float>
    ) {
        let count = max(count, 0)
        precondition(output.count == count, "output.count must equal count")
        guard count > 0 else { return }
        let swing = gain.isFinite ? max(gain, 0) : 1
        let sigma = smoothing.isFinite ? min(max(smoothing, 0), maximumSigma) : 0
        let depth = unit(ripple.depth)
        let floor = unit(ripple.floor)
        let carrierPhase = ripple.phase.carrier.isFinite ? ripple.phase.carrier : 0
        let harmonicPhase = ripple.phase.harmonic.isFinite ? ripple.phase.harmonic : 0
        let carrierRate = 2 * Double.pi * Ripple.cycles
        let harmonicRate = carrierRate * Ripple.harmonicRatio
        let bandCount = BandMapper.bandCount
        let last = bandCount - 1

        withUnsafeTemporaryAllocation(of: Double.self, capacity: 2 * bandCount + 2) { scratch in
            let levels = UnsafeMutableBufferPointer(rebasing: scratch[0..<bandCount])
            // Контрольные точки сплайна: сглаженные уровни и по одной отраженной точке с каждого
            // края (`points[0]` это полоса −1, `points[k + 1]` полоса k).
            let points = UnsafeMutableBufferPointer(rebasing: scratch[bandCount..<(2 * bandCount + 2)])
            for band in 0..<bandCount {
                let raw = band < bands.count ? bands[band] : 0
                levels[band] = raw.isFinite ? Double(min(max(raw, 0), 1)) : 0
            }
            smooth(levels, sigma: sigma, into: UnsafeMutableBufferPointer(rebasing: points[1...bandCount]))
            let compensation = 1 + peakCompensation * sigma
            for band in 1...bandCount {
                points[band] = min(points[band] * compensation, 1)
            }
            points[0] = points[2]
            points[bandCount + 1] = points[bandCount - 1]

            let span = max(count - 1, 1)
            for i in 0..<count {
                let steps = switch profile {
                case .wing: i
                case .panel: abs(2 * i - (count - 1))
                }
                // Произведение целое и точное: точки на полосах попадают в них ровно.
                let position = Double(steps * last) / Double(span)
                let segment = min(Int(position), last - 1)
                var y = spline(points, segment: segment, t: position - Double(segment))
                if floor > 0 || depth > 0 {
                    // Расстояние от выреза (в панели от середины, мягкий модуль как у `WaveShape`).
                    let x = Double(steps) / Double(span)
                    let u: Double = switch profile {
                    case .wing: x
                    case .panel: min((x * x + WaveShape.centerSoftness * WaveShape.centerSoftness).squareRoot(), 1)
                    }
                    if floor > 0 {
                        let taperIn = profile == .wing ? WavePaint.smoothstep(0, Ripple.floorTaperIn, u) : 1
                        y += floor * taperIn * WavePaint.smoothstep(1, Ripple.floorTaperOut, u)
                    }
                    if depth > 0 {
                        let wave = (1 - Ripple.harmonicShare) * sin(carrierRate * u - carrierPhase)
                            + Ripple.harmonicShare * sin(harmonicRate * u - harmonicPhase)
                        y *= 1 + depth * wave
                    }
                }
                output[i] = Float(WaveShape.softLimit(swing * max(y, 0)))
            }
        }
    }

    /// Прежний вызов без σ и ряби: в крыле σ ширины крыла по умолчанию
    /// (`WaveAppearance.standard.wingWidth`), в панели `minimumSigma`, без ряби. Для приложения
    /// до того, как оно передает σ своей ширины и рябь.
    /// - Precondition: `output.count == max(count, 0)`.
    public static func samples(
        bands: [Float], count: Int, profile: WaveProfile, gain: Double,
        into output: UnsafeMutableBufferPointer<Float>
    ) {
        let sigma = switch profile {
        case .wing: Self.sigma(halfWidth: WaveAppearance.standard.wingWidth)
        case .panel: minimumSigma
        }
        samples(bands: bands, count: count, profile: profile, gain: gain, smoothing: sigma, ripple: .none, into: output)
    }

    /// Однородный кубический B-сплайн на отрезке `segment` (между полосами `segment` и
    /// `segment + 1`) в доле `t`: контрольные точки `points[segment...segment + 3]` (полосы
    /// `segment − 1...segment + 2`), базис `((1 − t)³, 3t³ − 6t² + 4, −3t³ + 3t² + 3t + 1, t³) / 6`.
    private static func spline(_ points: UnsafeMutableBufferPointer<Double>, segment: Int, t: Double) -> Double {
        let s: Double = 1 - t
        let t2: Double = t * t
        let t3: Double = t2 * t
        let w0: Double = s * s * s
        let w1: Double = 3 * t3 - 6 * t2 + 4
        let w2: Double = -3 * t3 + 3 * t2 + 3 * t + 1
        let sum: Double = w0 * points[segment] + w1 * points[segment + 1] + w2 * points[segment + 2]
            + t3 * points[segment + 3]
        return sum / 6
    }

    /// Гауссово сглаживание `levels` с σ `sigma` полос, радиус ядра ⌈2σ⌉ (не больше 6), края
    /// отражены без повтора крайней полосы (наклон у краев нулевой). σ 0 копирует как есть.
    private static func smooth(
        _ levels: UnsafeMutableBufferPointer<Double>, sigma: Double, into output: UnsafeMutableBufferPointer<Double>
    ) {
        let count = levels.count
        guard sigma > 0 else {
            for band in 0..<count { output[band] = levels[band] }
            return
        }
        let radius = Int((2 * sigma).rounded(.up))
        withUnsafeTemporaryAllocation(of: Double.self, capacity: radius + 1) { weights in
            var total = 0.0
            for offset in 0...radius {
                let z = Double(offset) / sigma
                weights[offset] = exp(-0.5 * z * z)
                total += offset == 0 ? weights[offset] : 2 * weights[offset]
            }
            let last = count - 1
            for band in 0..<count {
                var sum = weights[0] * levels[band]
                for offset in 1...radius {
                    sum += weights[offset] * (levels[reflected(band - offset, last: last)]
                        + levels[reflected(band + offset, last: last)])
                }
                output[band] = sum / total
            }
        }
    }

    /// Индекс с отражением у краев 0 и `last` (без повтора крайнего): −1 → 1, last + 1 → last − 1.
    private static func reflected(_ index: Int, last: Int) -> Int {
        if index < 0 { return -index }
        if index > last { return 2 * last - index }
        return index
    }

    /// 0...1, не конечное дает 0.
    private static func unit(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }
}
