import Foundation

/// Готовая палитра волн: три цвета (бас, середина, верх).
public enum WavePreset: String, Codable, CaseIterable, Sendable {
    case aurora, sunset, ocean, neon, fire, mono
    case lavender, mint, coral, forest, amber, sakura, ice, sand, rainbow

    public var title: String {
        switch self {
        case .aurora: "Аврора"
        case .sunset: "Закат"
        case .ocean: "Океан"
        case .neon: "Неон"
        case .fire: "Огонь"
        case .mono: "Моно"
        case .lavender: "Лаванда"
        case .mint: "Мята"
        case .coral: "Коралл"
        case .forest: "Лес"
        case .amber: "Янтарь"
        case .sakura: "Сакура"
        case .ice: "Лед"
        case .sand: "Песок"
        case .rainbow: "Радуга"
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
        case .lavender: [0xB79CFF, 0xF0A6E8, 0x6F9BFF]
        case .mint: [0x3FE0A0, 0xB8F5A0, 0x2FC7D9]
        case .coral: [0xFF6F61, 0xFFA07A, 0xFF4F9A]
        case .forest: [0x6BD66B, 0xC2E05A, 0x3FC2A0]
        case .amber: [0xFFA500, 0xFFD84A, 0xFF6A1A]
        case .sakura: [0xFF8FB1, 0xFFB8D0, 0xD58CFF]
        case .ice: [0x8FDCFF, 0xD0F0FF, 0x7F9CFF]
        case .sand: [0xE8B070, 0xF2D6A6, 0xD27F55]
        case .rainbow: [0xFF5A5A, 0x52E57A, 0x5A8CFF]
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

/// Стиль волн (вкладка «Вид»). Имя не `WaveStyle`: так в приложении называется раскладка
/// крыло или панель.
public enum WaveLook: String, Codable, CaseIterable, Sendable {
    /// Бегущие волны слоев, по умолчанию.
    case waves
    /// Одна линия через уровни 24 полос (`SpectrumShape`), бас у выреза.
    case spectrum

    public var title: String {
        switch self {
        case .waves: "Волны"
        case .spectrum: "Спектр"
        }
    }

    /// Сохраненный стиль 1.2 `minimal` или `pulse` и любое неизвестное слово открываются как
    /// «Волны». Нечитаемое значение (не строка) бросает ошибку, как у обычного `Decodable`.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .waves
    }
}

/// Как стиль рисуется: базовая линия (она же ось заливки) и множитель толщины линий.
/// Единственный путь, по которому стиль передает это рисованию.
public struct WaveLookGeometry: Sendable, Equatable {
    public enum Baseline: Sendable, Equatable {
        /// Волна вверх и вниз от середины.
        case center
        /// y без знака от нижней базовой линии, заливка до нее же.
        case bottom
    }

    public var baseline: Baseline
    public var widthScale: Double

    public init(baseline: Baseline, widthScale: Double) {
        self.baseline = baseline
        self.widthScale = widthScale
    }

    public static let standard = WaveLookGeometry(baseline: .center, widthScale: 1)
}

/// Одна нарисованная линия волны. Основные линии идут от уровня своего слоя, эхо повторяет
/// основную линию тише и прозрачнее со сдвигом фазы, чтобы читаться как глубина.
public struct WaveLine: Sendable, Equatable {
    /// Чей уровень двигает линию.
    public enum Source: Sendable, Equatable {
        case layer(WaveLayer)
        /// Общий уровень (одна волна).
        case overall
        /// Уровни 24 полос: форма `SpectrumShape.samples`, а не `WaveShape`.
        case spectrum
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

    public init(
        source: Source, shape: WaveLayer, phaseOffset: Double, amplitudeScale: Float, opacity: Float
    ) {
        self.source = source
        self.shape = shape
        self.phaseOffset = phaseOffset
        self.amplitudeScale = amplitudeScale
        self.opacity = opacity
    }

    /// Есть ли у линии свечение (размытая копия толстой линии под ней): только у основных линий
    /// баса и середины. Верх должен быть четким, эхо тоже.
    public var glows: Bool { phaseOffset == 0 && shape != .high }

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

/// Системные настройки экрана, под которые подстраивается вид (`WaveAppearance.adapted(to:)`).
public struct DisplayOptions: Sendable, Equatable {
    /// «Увеличить контраст».
    public var increaseContrast: Bool
    /// «Уменьшить прозрачность».
    public var reduceTransparency: Bool

    public init(increaseContrast: Bool = false, reduceTransparency: Bool = false) {
        self.increaseContrast = increaseContrast
        self.reduceTransparency = reduceTransparency
    }

    /// Обе выключены: вид как в настройках.
    public static let standard = DisplayOptions()
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
        /// «Скорость переливания» (`PaletteFlow.advance(dt:speed:)`), 0 выключает.
        public static let colorFlow: ClosedRange<Double> = 0...1
    }

    private enum Defaults {
        static let wingWidth = 64.0
        static let glowRadius = 1.0
        static let lineCount = 3
        static let fill = 0.0
        static let thickness = 1.0
        static let amplitude = 1.0
        static let colorFlow = 0.0
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
    /// «Скорость переливания»: по умолчанию 0, вид после обновления сам не меняется.
    public var colorFlow: Double {
        didSet { colorFlow = Self.clamped(colorFlow, Limits.colorFlow, Defaults.colorFlow) }
    }
    /// «Цвет по частотам»: бас, середина и верх каждый своим цветом палитры. По умолчанию выключен.
    public var colorByBand: Bool
    /// Стиль волн: по умолчанию «Волны», неизвестный сохраненный стиль тоже дает «Волны».
    public var look: WaveLook
    /// Рисуется ли свечение линий (размытая копия под ними). Не настройка и не сохраняется:
    /// выключают его только `lightened()` и `adapted(to:)` при «Уменьшить прозрачность».
    public private(set) var glowPass = true
    /// Системное «Увеличить контраст» (`adapted(to:)`): линии толще (`contrastWidthScale` в
    /// `lookGeometry`) и ярче (`WavePaint.Options.highContrast`). Не настройка и не сохраняется.
    public private(set) var highContrast = false

    public init(
        wingWidth: Double, colorMode: WaveColorMode, glowRadius: Double,
        lineCount: Int, fill: Double, thickness: Double, amplitude: Double,
        colorFlow: Double = 0, colorByBand: Bool = false, look: WaveLook = .waves
    ) {
        self.wingWidth = Self.clamped(wingWidth, Limits.wingWidth, Defaults.wingWidth)
        self.colorMode = colorMode
        self.glowRadius = Self.clamped(glowRadius, Limits.glowRadius, Defaults.glowRadius)
        self.lineCount = Self.clamped(lineCount)
        self.fill = Self.clamped(fill, Limits.fill, Defaults.fill)
        self.thickness = Self.clamped(thickness, Limits.thickness, Defaults.thickness)
        self.amplitude = Self.clamped(amplitude, Limits.amplitude, Defaults.amplitude)
        self.colorFlow = Self.clamped(colorFlow, Limits.colorFlow, Defaults.colorFlow)
        self.colorByBand = colorByBand
        self.look = look
    }

    private enum CodingKeys: String, CodingKey {
        case wingWidth, colorMode, glowRadius, lineCount, fill, thickness, amplitude, colorFlow, colorByBand, look
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
            amplitude: value(.amplitude, standard.amplitude),
            colorFlow: value(.colorFlow, standard.colorFlow),
            colorByBand: value(.colorByBand, standard.colorByBand),
            look: value(.look, standard.look)
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

    /// Линии свернутого острова (`lines(for: .wing)`).
    public var lines: [WaveLine] { lines(for: .wing) }

    /// Линии стиля. `profile` здесь раскладка: `.wing` это свернутый остров (крылья у выреза и
    /// капсула без выреза, у «Волн» и «Спектра» линии в обоих случаях одни и те же),
    /// `.panel` это раскрытая панель.
    /// - «Волны»: `WaveLine.lines(count: lineCount)`.
    /// - «Спектр»: одна линия `.spectrum` формы середины.
    public func lines(for profile: WaveProfile) -> [WaveLine] {
        switch look {
        case .waves:
            return WaveLine.lines(count: lineCount)
        case .spectrum:
            return [WaveLine(source: .spectrum, shape: .mid, phaseOffset: 0, amplitudeScale: 1, opacity: 1)]
        }
    }

    /// Множитель толщины линий при «Увеличить контраст» (`highContrast`).
    public static let contrastWidthScale = 1.4

    /// Базовая линия и толщина стиля: «Спектр» от нижней базовой линии, «Волны» как раньше.
    /// При `highContrast` толщина еще × `contrastWidthScale` (1.4).
    public var lookGeometry: WaveLookGeometry {
        var geometry = switch look {
        case .waves: WaveLookGeometry.standard
        case .spectrum: WaveLookGeometry(baseline: .bottom, widthScale: 1)
        }
        if highContrast {
            geometry.widthScale *= Self.contrastWidthScale
        }
        return geometry
    }

    /// Сколько линий остается в режиме энергосбережения и при «Увеличить контраст»: три
    /// основные, без эха.
    static let lightenedLineLimit = 3

    /// Вид для режима энергосбережения: эхо не рисуется (больше трех линий рисуются тремя
    /// основными) и нет свечения линий. Остальное как в настройках, сами настройки не меняются.
    public func lightened() -> WaveAppearance {
        var light = self
        light.lineCount = min(lineCount, Self.lightenedLineLimit)
        light.glowPass = false
        return light
    }

    /// Вид под системные настройки экрана, как `lightened()`: сами настройки не меняются, флаги
    /// не сохраняются. «Увеличить контраст»: эха нет (больше трех линий рисуются тремя основными)
    /// и `highContrast`. «Уменьшить прозрачность»: нет свечения линий и заливки. Свечение под
    /// островом от этого не зависит и остается. Без опций (`.standard`) вид тот же.
    public func adapted(to options: DisplayOptions) -> WaveAppearance {
        var adapted = self
        if options.increaseContrast {
            adapted.lineCount = min(lineCount, Self.lightenedLineLimit)
            adapted.highContrast = true
        }
        if options.reduceTransparency {
            adapted.glowPass = false
            adapted.fill = 0
        }
        return adapted
    }

    /// Порог `renderCost`, выше которого вкладка «Вид» предупреждает о нагрузке на процессор.
    public static let renderCostWarning = 2.5

    /// Цена выше `renderCostWarning`.
    public var isRenderCostHigh: Bool { renderCost > Self.renderCostWarning }

    /// Примерная цена кадра относительно вида по умолчанию (1): безразмерная, не убывает ни по
    /// одному ползунку и годится для сравнения видов, а не для процентов процессора. Грубая
    /// модель по замеру и профилю на M2 (60 Гц): кадр стоит столько, сколько проходов по путям
    /// линий (построение, разбиение кривых, закраска) и размытия свечения.
    /// - Обводка линии: `0.75 + 0.25 × толщина`. Точек у линии постоянное число, путь строится
    ///   одинаково, с толщиной растет только закрашиваемая полоса.
    /// - Заливка (любая больше 0): еще `0.5` на линию. Путь общий с обводкой, но маска и цвет это
    ///   две закраски площади.
    /// - Свечение (основные бас и середина, `WaveLine.glows`): обводка × «Радиус свечения».
    ///   Размытие разделимое, его цена на пиксель растет линейно с радиусом (поле текстуры тоже).
    ///   Без прохода свечения (`lightened()`) ноль.
    /// - Ширина крыла: множитель `0.75 + 0.25 × ширина / 64`. Число точек от ширины не зависит,
    ///   растет только площадь.
    /// Цвет (с переливанием и цветом по частотам) и «Размах» на цену не влияют, яркость свечения
    /// не часть вида и сюда не входит.
    /// По умолчанию (три линии, два свечения, без заливки) работа 5 условных проходов.
    /// Это цена свернутого острова, `renderCost(for: .wing)`.
    public var renderCost: Double {
        renderCost(for: .wing)
    }

    /// Цена кадра стиля в раскладке `profile` (как в `lines(for:)`: `.wing` свернутый остров,
    /// `.panel` раскрытая панель) по той же модели, что `renderCost`, от линий `lines(for:)`.
    /// Обе цены делятся на работу вида по умолчанию в крыле и сравниваются между собой.
    /// - Толщина обводки и свечения умножается на `lookGeometry.widthScale`.
    /// - Панель: ширина панели от «Ширины крыла» не зависит, множителя ширины нет.
    public func renderCost(for profile: WaveProfile) -> Double {
        Self.work(self, profile: profile) / Self.work(.standard, profile: .wing)
    }

    private static func work(_ appearance: WaveAppearance, profile: WaveProfile) -> Double {
        let lines = appearance.lines(for: profile)
        let stroke = 0.75 + 0.25 * appearance.thickness * appearance.lookGeometry.widthScale
        let strokes = Double(lines.count) * stroke
        let fills = appearance.fill > 0 ? 0.5 * Double(lines.count) : 0
        let glows = appearance.glowPass
            ? Double(lines.filter(\.glows).count) * stroke * appearance.glowRadius
            : 0
        let span = switch profile {
        case .wing: 0.75 + 0.25 * appearance.wingWidth / Defaults.wingWidth
        case .panel: 1.0
        }
        return span * (strokes + fills + glows)
    }

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
