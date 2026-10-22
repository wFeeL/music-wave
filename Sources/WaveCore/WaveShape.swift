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
        let step = dt.isFinite ? max(0, dt) : 0
        let twoPi = 2 * Double.pi
        for index in 0..<phases.count {
            let raw = index < layers.count ? layers[index] : 0
            let level = raw.isFinite ? Double(min(max(raw, 0), 1)) : 0
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

/// «Вздох» острова на сильной доле. Огибающая удара спадает за десятки миллисекунд, и остров
/// дергался бы от кадра к кадру. Здесь удар захватывается сразу и отпускается с постоянной
/// времени `release`, а значение идет за ним пружиной: быстрый вдох, медленный выдох.
public struct BeatPulse: Sendable {
    /// Постоянная времени выдоха, с.
    public static let release = 0.2
    /// Период пружины, с.
    public static let response = 0.12
    public static let damping = 0.75
    /// Самый длинный шаг интегрирования пружины, с.
    private static let substep = 1.0 / 240
    /// Самый длинный учитываемый кадр, с.
    private static let maxStep = 0.25

    /// Текущий «вздох», 0...1.
    public private(set) var value: Float = 0

    private var held = 0.0
    private var position = 0.0
    private var velocity = 0.0

    public init() {}

    /// `beat` это огибающая удара кадра 0...1, `dt` в секундах. Возвращает новое значение.
    @discardableResult
    public mutating func step(beat: Float, dt: Double) -> Float {
        guard dt.isFinite, dt > 0 else { return value }
        let step = min(dt, Self.maxStep)
        let input = beat.isFinite ? Double(min(max(beat, 0), 1)) : 0
        held = max(input, held * exp(-step / Self.release))

        let omega = 2 * Double.pi / Self.response
        let count = max(1, Int((step / Self.substep).rounded(.up)))
        let h = step / Double(count)
        for _ in 0..<count {
            velocity += h * (omega * omega * (held - position) - 2 * Self.damping * omega * velocity)
            position += h * velocity
        }
        value = Float(min(max(position, 0), 1))
        return value
    }
}

/// Цвет и прозрачность вдоль одной волны.
///
/// Градиент между цветом слоя `palette[i]` и следующим `palette[(i + 1) % 3]` течет от выреза
/// наружу на `flowSpeed` ширины в секунду и замыкается по кругу. В тишине линия теряет цвет
/// и становится тусклой серой, с уровнем цвет и яркость возвращаются. У выреза линия
/// проявляется, к внешнему краю растворяется.
public enum WavePaint {
    public struct Stop: Sendable, Equatable {
        /// 0 у выреза, 1 у внешнего края.
        public var location: Double
        public var color: RGBColor
        public var opacity: Float

        public init(location: Double, color: RGBColor, opacity: Float) {
            self.location = location
            self.color = color
            self.opacity = opacity
        }
    }

    /// Скорость течения градиента, доля ширины в секунду.
    public static let flowSpeed = 0.05
    /// Прозрачность линии в тишине и на полном уровне.
    public static let restOpacity: Float = 0.14
    public static let fullOpacity: Float = 0.9
    /// Уровень, на котором линия набирает полную яркость.
    static let opacityKnee: Float = 0.35
    /// Уровни, между которыми серая линия набирает цвет.
    static let chromaRange: (from: Float, to: Float) = (0.02, 0.3)
    /// Доля прозрачности у самого выреза и ширина проявления.
    static let fadeInStart = 0.08
    static let fadeInWidth = 0.25
    /// Отсюда до внешнего края линия растворяется.
    static let fadeOutStart = 0.7

    /// `count` точек градиента с шагом `1 / (count - 1)`; меньше двух точек дают пустой массив.
    public static func stops(palette: [RGBColor], layer: WaveLayer, level: Float, time: Double, count: Int) -> [Stop] {
        guard count >= 2 else { return [] }
        let colors = palette.isEmpty ? PaletteExtractor.fallback : palette
        let own = colors[layer.rawValue % colors.count].oklab
        let next = colors[(layer.rawValue + 1) % colors.count].oklab

        let level = level.isFinite ? min(max(level, 0), 1) : 0
        let chroma = smoothstep(chromaRange.from, chromaRange.to, level)
        let opacity = restOpacity + (fullOpacity - restOpacity) * smoothstep(0, opacityKnee, level)
        let shift = time.isFinite ? (flowSpeed * time).truncatingRemainder(dividingBy: 1) : 0

        return (0..<count).map { index in
            let location = Double(index) / Double(count - 1)
            let weight = Float(0.5 - 0.5 * cos(2 * Double.pi * (location - shift)))
            let lab = OKLab(
                l: own.l + (next.l - own.l) * weight,
                a: (own.a + (next.a - own.a) * weight) * chroma,
                b: (own.b + (next.b - own.b) * weight) * chroma
            )
            let fadeIn = fadeInStart + (1 - fadeInStart) * smoothstep(0, fadeInWidth, location)
            let fadeOut = smoothstep(1, fadeOutStart, location)
            return Stop(location: location, color: RGBColor(oklab: lab), opacity: opacity * Float(fadeIn * fadeOut))
        }
    }

    /// Плавная ступенька: 0 при `x = edge0`, 1 при `x = edge1`; края могут идти в любом порядке.
    static func smoothstep<T: BinaryFloatingPoint>(_ edge0: T, _ edge1: T, _ x: T) -> T {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
