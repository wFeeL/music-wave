import Foundation

/// Готовая палитра волн: три цвета (бас, середина, верх).
public enum WavePreset: String, Codable, CaseIterable, Sendable {
    case aurora, sunset, ocean, neon, fire, mono

    public var title: String {
        switch self {
        case .aurora: "Аврора"
        case .sunset: "Закат"
        case .ocean: "Океан"
        case .neon: "Неон"
        case .fire: "Огонь"
        case .mono: "Моно"
        }
    }

    public var colors: [RGBColor] {
        let hex: [UInt32] = switch self {
        case .aurora: [0x4BE3C1, 0x5B8CFF, 0xB06CFF]
        case .sunset: [0xFF7A45, 0xFF4F8B, 0xFFC15E]
        case .ocean: [0x2EC4F1, 0x2F6BFF, 0x45E0C8]
        case .neon: [0x39FF88, 0x29E6FF, 0xFF3DDB]
        case .fire: [0xFF3B1F, 0xFF8C1A, 0xFFD23F]
        case .mono: [0xFFFFFF, 0xD9D9D9, 0xB3B3B3]
        }
        return hex.map(RGBColor.init(hex:))
    }
}

/// Откуда берутся цвета волн, свечения и волны панели.
public enum WaveColorMode: Codable, Equatable, Sendable {
    /// «Из обложки».
    case artwork
    case preset(WavePreset)
    /// «Свой цвет»: три цвета строятся из одного (`WaveAppearance.customPalette`).
    case custom(RGBColor)
}

/// Одна нарисованная линия волны. Основные линии идут от уровня своего слоя, эхо повторяет
/// основную линию тише и прозрачнее со сдвигом фазы, чтобы читаться как глубина.
public struct WaveLine: Sendable, Equatable {
    /// Чей уровень двигает линию.
    public enum Source: Sendable, Equatable {
        case layer(WaveLayer)
        /// Общий уровень (одна волна).
        case overall
    }

    public var source: Source
    /// Форма и фаза: `WaveShape.samples(layer: shape, ...)` с фазой
    /// `motion.phase(shape, profile:).shifted(by: phaseOffset)`.
    public var shape: WaveLayer
    /// Сдвиг фазы несущей, рад.
    public var phaseOffset: Double
    /// Множитель уровня.
    public var amplitudeScale: Float
    /// Множитель прозрачности.
    public var opacity: Float

    public init(source: Source, shape: WaveLayer, phaseOffset: Double, amplitudeScale: Float, opacity: Float) {
        self.source = source
        self.shape = shape
        self.phaseOffset = phaseOffset
        self.amplitudeScale = amplitudeScale
        self.opacity = opacity
    }

    /// Сдвиг фазы эха, рад.
    static let echoPhase = 0.6
    /// Эхо баса, середины и верха: (размах, прозрачность).
    static let echoes: [(layer: WaveLayer, amplitude: Float, opacity: Float)] = [
        (.bass, 0.72, 0.45), (.mid, 0.52, 0.3), (.high, 0.38, 0.28),
    ]

    /// Линии для «Количества волн» `count` (ограничивается 1...6): одна волна показывает
    /// общий уровень формой середины, две: бас и верх, три: бас, середина, верх, 4-6
    /// добавляют эхо баса, середины и верха.
    public static func lines(count: Int) -> [WaveLine] {
        let count = min(max(count, WaveAppearance.Limits.lineCount.lowerBound), WaveAppearance.Limits.lineCount.upperBound)
        func main(_ layer: WaveLayer) -> WaveLine {
            WaveLine(source: .layer(layer), shape: layer, phaseOffset: 0, amplitudeScale: 1, opacity: 1)
        }
        switch count {
        case 1:
            return [WaveLine(source: .overall, shape: .mid, phaseOffset: 0, amplitudeScale: 1, opacity: 1)]
        case 2:
            return [main(.bass), main(.high)]
        default:
            return WaveLayer.allCases.map(main) + echoes.prefix(count - 3).map { echo in
                WaveLine(
                    source: .layer(echo.layer), shape: echo.layer, phaseOffset: echoPhase,
                    amplitudeScale: echo.amplitude, opacity: echo.opacity
                )
            }
        }
    }
}

/// Настройки вида волн (вкладка «Вид»). Каждое значение держится в своем диапазоне `Limits`:
/// и в `init`, и при записи в свойство, и при чтении из сохраненных настроек. Не конечное
/// значение заменяется значением по умолчанию.
public struct WaveAppearance: Codable, Equatable, Sendable {
    public enum Limits {
        /// Ширина крыла, pt. На экране с вырезом ее еще ограничивает `NotchLayout.wingLimit`.
        public static let wingWidth: ClosedRange<Double> = 40...200
        /// «Радиус свечения», множитель.
        public static let glowRadius: ClosedRange<Double> = 0.5...3
        /// «Количество волн».
        public static let lineCount: ClosedRange<Int> = 1...6
        /// «Заливка», доля.
        public static let fill: ClosedRange<Double> = 0...1
        /// «Толщина линий», множитель.
        public static let thickness: ClosedRange<Double> = 0.5...2
        /// «Размах», множитель (`WaveShape.samples(gain:)`).
        public static let amplitude: ClosedRange<Double> = 0.5...2
    }

    private enum Defaults {
        static let wingWidth = 64.0
        static let glowRadius = 1.0
        static let lineCount = 3
        static let fill = 0.0
        static let thickness = 1.0
        static let amplitude = 1.0
    }

    public static let standard = WaveAppearance(
        wingWidth: Defaults.wingWidth, colorMode: .artwork, glowRadius: Defaults.glowRadius,
        lineCount: Defaults.lineCount, fill: Defaults.fill, thickness: Defaults.thickness,
        amplitude: Defaults.amplitude
    )

    public var wingWidth: Double {
        didSet { wingWidth = Self.clamped(wingWidth, Limits.wingWidth, Defaults.wingWidth) }
    }
    public var colorMode: WaveColorMode
    public var glowRadius: Double {
        didSet { glowRadius = Self.clamped(glowRadius, Limits.glowRadius, Defaults.glowRadius) }
    }
    public var lineCount: Int {
        didSet { lineCount = Self.clamped(lineCount) }
    }
    public var fill: Double {
        didSet { fill = Self.clamped(fill, Limits.fill, Defaults.fill) }
    }
    public var thickness: Double {
        didSet { thickness = Self.clamped(thickness, Limits.thickness, Defaults.thickness) }
    }
    public var amplitude: Double {
        didSet { amplitude = Self.clamped(amplitude, Limits.amplitude, Defaults.amplitude) }
    }

    public init(
        wingWidth: Double, colorMode: WaveColorMode, glowRadius: Double,
        lineCount: Int, fill: Double, thickness: Double, amplitude: Double
    ) {
        self.wingWidth = Self.clamped(wingWidth, Limits.wingWidth, Defaults.wingWidth)
        self.colorMode = colorMode
        self.glowRadius = Self.clamped(glowRadius, Limits.glowRadius, Defaults.glowRadius)
        self.lineCount = Self.clamped(lineCount)
        self.fill = Self.clamped(fill, Limits.fill, Defaults.fill)
        self.thickness = Self.clamped(thickness, Limits.thickness, Defaults.thickness)
        self.amplitude = Self.clamped(amplitude, Limits.amplitude, Defaults.amplitude)
    }

    private enum CodingKeys: String, CodingKey {
        case wingWidth, colorMode, glowRadius, lineCount, fill, thickness, amplitude
    }

    /// Пропущенное или нечитаемое поле берется из `standard`, значения вне диапазона ограничиваются.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let standard = Self.standard
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        self.init(
            wingWidth: value(.wingWidth, standard.wingWidth),
            colorMode: value(.colorMode, standard.colorMode),
            glowRadius: value(.glowRadius, standard.glowRadius),
            lineCount: value(.lineCount, standard.lineCount),
            fill: value(.fill, standard.fill),
            thickness: value(.thickness, standard.thickness),
            amplitude: value(.amplitude, standard.amplitude)
        )
    }

    /// Три цвета волн для текущего режима. `artwork`: палитра обложки как есть.
    public func palette(artwork: [RGBColor]) -> [RGBColor] {
        switch colorMode {
        case .artwork: artwork
        case .preset(let preset): preset.colors
        case .custom(let color): Self.customPalette(color)
        }
    }

    /// Линии для текущего «Количества волн».
    public var lines: [WaveLine] { WaveLine.lines(count: lineCount) }

    /// Светлота OKLab «Своего цвета» не ниже этой: на черных крыльях темная волна не видна.
    static let customMinimumLightness: Float = 0.55
    /// Поворот оттенка второго и третьего цвета, градусы.
    static let customHueTurn: Float = 25

    /// «Свой цвет»: сам цвет и он же с оттенком, повернутым в OKLab на +25° и −25°, светлота
    /// поднята до 0.55. Цвет вне гаммы sRGB теряет насыщенность, а не оттенок. Не конечный
    /// цвет заменяется первым цветом `PaletteExtractor.fallback`.
    public static func customPalette(_ color: RGBColor) -> [RGBColor] {
        var base = (color.isFinite ? color : PaletteExtractor.fallback[0]).oklab
        base.l = min(max(base.l, customMinimumLightness), 1)
        return [0, customHueTurn, -customHueTurn].map { turn in
            RGBColor(oklab: base.rotatedHue(degrees: turn).fittedToSRGBGamut())
        }
    }

    private static func clamped(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
    }

    private static func clamped(_ count: Int) -> Int {
        min(max(count, Limits.lineCount.lowerBound), Limits.lineCount.upperBound)
    }
}
