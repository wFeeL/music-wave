import Foundation

/// Фазы трех слоев волны. Фаза копится в Double и держится в 0..<2π.
/// Скорость задает звук: в тишине волны почти стоят, на громкой музыке бегут быстрее.
public struct WaveMotion: Sendable {
    /// Угловая скорость слоев (бас, середина, верх), рад/с.
    private static let speeds: [Double] = [1.6, 2.8, 4.4]

    private var phases: [Double] = [0, 0, 0]

    public init() {}

    /// `layers` это уровни слоев 0...1 в порядке `WaveLayer`, `dt` в секундах.
    public mutating func advance(layers: [Float], dt: Double) {
        let step = max(0, dt)
        let twoPi = 2 * Double.pi
        for index in 0..<phases.count {
            let level = index < layers.count ? Double(min(max(layers[index], 0), 1)) : 0
            let advanced = phases[index] + Self.speeds[index] * (0.3 + 1.7 * level) * step
            phases[index] = advanced.truncatingRemainder(dividingBy: twoPi)
        }
    }

    public func phase(_ layer: WaveLayer) -> Double {
        phases[layer.rawValue]
    }
}

/// Форма одного слоя волны вдоль крыла острова.
public enum WaveShape {
    private static let carriers: [Double] = [1.25, 2.5, 5.0]
    private static let offsets: [Double] = [0, 2.1, 4.2]
    private static let peaks: [Double] = [0.3, 0.5, 0.7]

    /// Значения y в -1...1 для x = i / (count - 1): x = 0 у выреза, x = 1 у внешнего края крыла.
    /// `amplitude` ограничивается диапазоном 0...1.
    public static func samples(layer: WaveLayer, amplitude: Float, phase: Double, count: Int) -> [Float] {
        guard count > 0 else { return [] }
        let c = carriers[layer.rawValue]
        let p = offsets[layer.rawValue]
        let k = log(0.5) / log(peaks[layer.rawValue])
        let amp = Double(min(max(amplitude, 0), 1))
        let denominator = Double(max(count - 1, 1))
        let twoPi = 2 * Double.pi

        return (0..<count).map { i in
            let x = Double(i) / denominator
            let envelope = pow(max(0, sin(Double.pi * pow(x, k))), 1.5)
            let carrier = 0.75 * sin(twoPi * c * x + phase + p) + 0.25 * sin(twoPi * 2.3 * c * x - 1.7 * phase)
            return Float(amp * envelope * carrier)
        }
    }
}
