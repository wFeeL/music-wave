import Foundation

/// Линия стиля «Спектр»: форма вдоль крыла идет через уровни 24 полос (`BandMapper.bandCount`).
///
/// Кривая монотонная кубическая (Fritsch-Carlson): проходит ровно через уровень каждой полосы и
/// между двумя полосами не выходит за них, поэтому выбросов выше громкой полосы и ниже нуля нет.
/// В крыле бас у выреза (x = 0), верх у внешнего края. В панели бас в середине, к обоим краям
/// идут верхние полосы, симметрично. Касательная у баса нулевая: в середине панели линия
/// проходит без излома. y без знака, от нижней базовой линии (`WaveLookGeometry.Baseline.bottom`).
public enum SpectrumShape {
    /// Значения y в 0...1 в `output`. `.wing`: точка i лежит на полосе `23 × i / (count − 1)`.
    /// `.panel`: на полосе `23 × |2i − (count − 1)| / (count − 1)`. Плохие (не конечные и
    /// отрицательные) уровни считаются нулем, больше 1 ограничиваются 1, недостающие полосы
    /// это ноль, полосы сверх 24 не читаются. `gain` (настройка «Размах») как в
    /// `WaveShape.samples`: y умножается на него до мягкого предела `WaveShape.softLimit`,
    /// отрицательный дает 0, не конечный считается 1.
    /// - Precondition: `output.count == max(count, 0)`.
    public static func samples(
        bands: [Float], count: Int, profile: WaveProfile, gain: Double,
        into output: UnsafeMutableBufferPointer<Float>
    ) {
        let count = max(count, 0)
        precondition(output.count == count, "output.count must equal count")
        guard count > 0 else { return }
        let swing = gain.isFinite ? max(gain, 0) : 1
        let bandCount = BandMapper.bandCount
        let last = bandCount - 1

        withUnsafeTemporaryAllocation(of: Double.self, capacity: 2 * bandCount) { scratch in
            // Уровни полос и касательные в них.
            let levels = UnsafeMutableBufferPointer(rebasing: scratch[0..<bandCount])
            let slopes = UnsafeMutableBufferPointer(rebasing: scratch[bandCount..<(2 * bandCount)])
            for band in 0..<bandCount {
                let raw = band < bands.count ? bands[band] : 0
                levels[band] = raw.isFinite ? Double(min(max(raw, 0), 1)) : 0
            }
            tangents(levels: levels, into: slopes)

            let span = max(count - 1, 1)
            for i in 0..<count {
                let steps = switch profile {
                case .wing: i
                case .panel: abs(2 * i - (count - 1))
                }
                // Произведение целое и точное: точки на полосах попадают в них ровно.
                let position = Double(steps * last) / Double(span)
                let segment = min(Int(position), last - 1)
                let t = position - Double(segment)
                let y0 = levels[segment], y1 = levels[segment + 1]
                let t2 = t * t, t3 = t2 * t
                let y = (2 * t3 - 3 * t2 + 1) * y0 + (t3 - 2 * t2 + t) * slopes[segment]
                    + (-2 * t3 + 3 * t2) * y1 + (t3 - t2) * slopes[segment + 1]
                output[i] = Float(WaveShape.softLimit(swing * min(max(y, 0), 1)))
            }
        }
    }

    /// Касательные Fritsch-Carlson с шагом 1 между полосами: внутри среднее соседних наклонов,
    /// ноль на экстремуме и на ровном участке, затем ограничение `α² + β² ≤ 9`, которое держит
    /// каждый отрезок монотонным. У баса касательная 0 (без излома в середине панели), у
    /// последней полосы наклон последнего отрезка.
    private static func tangents(levels: UnsafeMutableBufferPointer<Double>, into slopes: UnsafeMutableBufferPointer<Double>) {
        let last = levels.count - 1
        slopes[0] = 0
        for k in 1..<last {
            let before = levels[k] - levels[k - 1]
            let after = levels[k + 1] - levels[k]
            slopes[k] = before * after > 0 ? (before + after) / 2 : 0
        }
        slopes[last] = levels[last] - levels[last - 1]
        for k in 0..<last {
            let delta = levels[k + 1] - levels[k]
            guard delta != 0 else {
                slopes[k] = 0
                slopes[k + 1] = 0
                continue
            }
            let alpha = slopes[k] / delta
            let beta = slopes[k + 1] / delta
            let radius = alpha * alpha + beta * beta
            if radius > 9 {
                let tau = 3 / radius.squareRoot()
                slopes[k] = tau * alpha * delta
                slopes[k + 1] = tau * beta * delta
            }
        }
    }
}
