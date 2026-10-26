import Foundation

/// Фаза одного слоя волны: свой накопитель у несущей и свой у гармоники. Каждый держится
/// в 0..<2π и переходит через 2π сам по себе, поэтому гармоника не прыгает, когда
/// переходит несущая.
public struct WavePhase: Sendable, Equatable {
    public var carrier: Double
    public var harmonic: Double

    public init(carrier: Double, harmonic: Double) {
        self.carrier = carrier
        self.harmonic = harmonic
    }

    /// Та же волна, сдвинутая на `offset` рад несущей: гармоника сдвигается на
    /// `harmonicRatio × offset`, обе фазы снова в 0..<2π.
    public func shifted(by offset: Double) -> WavePhase {
        let offset = offset.isFinite ? offset : 0
        return WavePhase(
            carrier: Self.wrapped(carrier + offset),
            harmonic: Self.wrapped(harmonic + WaveMotion.harmonicRatio * offset)
        )
    }

    /// `value` в 0..<2π, в том числе для отрицательных; не конечное значение дает 0.
    static func wrapped(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        let twoPi = 2 * Double.pi
        var result = value.truncatingRemainder(dividingBy: twoPi)
        if result < 0 { result += twoPi }
        return result < twoPi ? result : 0
    }
}

/// Фазы трех слоев волны для крыла и для панели. Скорость задает звук: в тишине волны почти
/// стоят, на громкой музыке бегут быстрее. Скорость идет от громкости, сглаженной за 0.4 с,
/// а не от мгновенного уровня, поэтому удары не дергают гребни.
public struct WaveMotion: Sendable {
    /// Во сколько раз гармоника бежит быстрее несущей по фазе.
    static let harmonicRatio: Double = 1.7
    /// Угловая скорость слоев (бас, середина, верх) в крыле, рад/с.
    static let wingSpeeds: [Double] = [1.6, 2.8, 4.4]
    /// То же в панели: гребни идут с той же скоростью в точках, что и в крыле.
    static let panelSpeeds: [Double] = [0.85, 1.6, 3.0]
    /// Постоянная времени медленной громкости, с.
    static let loudnessTau = 0.4
    /// Самый длинный учитываемый кадр, с.
    static let maxStep = 1.0

    private var slow: [Double] = [0, 0, 0]
    private var wing = [WavePhase](repeating: WavePhase(carrier: 0, harmonic: 0), count: 3)
    private var panel = [WavePhase](repeating: WavePhase(carrier: 0, harmonic: 0), count: 3)

    public init() {}

    /// `layers` это уровни слоев 0...1 в порядке `WaveLayer`, `dt` в секундах.
    public mutating func advance(layers: [Float], dt: Double) {
        let step = dt.isFinite ? min(max(0, dt), Self.maxStep) : 0
        let blend = 1 - exp(-step / Self.loudnessTau)
        for index in 0..<slow.count {
            let raw = index < layers.count ? layers[index] : 0
            let level = raw.isFinite ? Double(min(max(raw, 0), 1)) : 0
            slow[index] += blend * (level - slow[index])
        }
        Self.advance(&wing, speeds: Self.wingSpeeds, slow: slow, step: step)
        Self.advance(&panel, speeds: Self.panelSpeeds, slow: slow, step: step)
    }

    private static func advance(_ phases: inout [WavePhase], speeds: [Double], slow: [Double], step: Double) {
        let twoPi = 2 * Double.pi
        for index in phases.indices {
            let turn = speeds[index] * (0.3 + 1.7 * slow[index]) * step
            phases[index].carrier = (phases[index].carrier + turn).truncatingRemainder(dividingBy: twoPi)
            phases[index].harmonic = (phases[index].harmonic + harmonicRatio * turn).truncatingRemainder(dividingBy: twoPi)
        }
    }

    public func phase(_ layer: WaveLayer, profile: WaveProfile = .wing) -> WavePhase {
        switch profile {
        case .wing: wing[layer.rawValue]
        case .panel: panel[layer.rawValue]
        }
    }

    /// Громкость слоя, сглаженная за `loudnessTau`, 0...1.
    public func slowLevel(_ layer: WaveLayer) -> Float {
        Float(slow[layer.rawValue])
    }
}

/// Где рисуется волна.
public enum WaveProfile: Sendable, CaseIterable {
    /// Крыло: x = 0 у выреза, x = 1 у внешнего края, у выреза амплитуда уходит в ноль.
    case wing
    /// Панель и капсула: одна линия во всю ширину, симметрично от середины и без шва в ней.
    case panel
}

/// Форма одного слоя волны.
///
/// Несущая `sin(2π·c·x − phase.carrier + p)` и гармоника `sin(2π·2.3·c·x − phase.harmonic)`:
/// с ростом фазы гребни бегут от выреза наружу. В крыле волн мало (0.6, 1.1, 1.8 периода на
/// бас, середину и верх), у баса нет гармоники. В панели линия идет через середину: волна считается от
/// `u = sqrt(x² + 0.03²)`, мягкого модуля без излома, и в середине амплитуда не пропадает.
public enum WaveShape {
    static let wingCarriers: [Double] = [0.6, 1.1, 1.8]
    static let panelCarriers: [Double] = [1.25, 2.5, 5.0]
    static let wingHarmonics: [Double] = [0, 0.12, 0.12]
    static let panelHarmonics: [Double] = [0.15, 0.15, 0.15]
    private static let offsets: [Double] = [0, 2.1, 4.2]
    /// Где огибающая слоя достигает максимума (доля от выреза или от середины панели).
    static let peaks: [Double] = [0.2, 0.4, 0.6]
    /// Мягкий модуль в середине панели.
    static let centerSoftness = 0.03
    /// Огибающая панели: `panelFloor + (1 − panelFloor)·sin(π·u^k)`, к краям затухает
    /// от `panelTaperStart` до нуля.
    static let panelFloor = 0.6
    static let panelTaperStart = 0.75
    /// Крыло: размах в 1.3 раза больше, выше `wingKnee` он плавно упирается в 1 (в панели
    /// так же упирается размах, усиленный настройкой «Размах»).
    static let wingGain = 1.3
    static let wingKnee = 0.8

    /// Значения y в -1...1. `.wing`: x = i / (count - 1) от выреза к краю, размах усилен в
    /// `wingGain` раз с мягким пределом. `.panel`: x = -1 + 2i / (count - 1) через всю ширину.
    /// `amplitude` ограничивается диапазоном 0...1. `gain` (настройка «Размах») умножает размах
    /// до мягкого предела: ниже `wingKnee` y растет ровно в `gain` раз, выше упирается в ±1.
    /// Отрицательный `gain` дает 0, не конечный считается 1.
    public static func samples(
        layer: WaveLayer, amplitude: Float, phase: WavePhase, count: Int, profile: WaveProfile = .wing,
        gain: Double = 1
    ) -> [Float] {
        guard count > 0 else { return [] }
        let envelope = Envelope(layer: layer, count: count, profile: profile)
        var output = [Float](repeating: 0, count: count)
        output.withUnsafeMutableBufferPointer {
            samples(amplitude: amplitude, phase: phase, envelope: envelope, gain: gain, into: $0)
        }
        return output
    }

    /// То же, что `samples(layer:amplitude:phase:count:profile:gain:)`, но в готовый буфер и с
    /// готовой огибающей: на точку остаются только синусы несущей и гармоники. Значения бит в
    /// бит те же.
    /// - Precondition: `output.count == envelope.count`.
    public static func samples(
        amplitude: Float, phase: WavePhase, envelope: Envelope, gain: Double = 1,
        into output: UnsafeMutableBufferPointer<Float>
    ) {
        precondition(output.count == envelope.count, "output.count must equal envelope.count")
        let swing = (gain.isFinite ? max(gain, 0) : 1) * (envelope.profile == .wing ? wingGain : 1)
        let index = envelope.layer.rawValue
        let p = offsets[index]
        let amp = Double(min(max(amplitude, 0), 1))
        let carrierPhase = phase.carrier.isFinite ? phase.carrier : 0
        let harmonicPhase = phase.harmonic.isFinite ? phase.harmonic : 0
        let twoPi = 2 * Double.pi

        let c: Double, h: Double
        switch envelope.profile {
        case .wing:
            c = wingCarriers[index]
            h = wingHarmonics[index]
        case .panel:
            c = panelCarriers[index]
            h = panelHarmonics[index]
        }
        // Те же произведения и в том же порядке, что `twoPi * c * u` и `twoPi * 2.3 * c * u`.
        let carrierRate = twoPi * c
        let harmonicRate = twoPi * 2.3 * c

        envelope.positions.withUnsafeBufferPointer { positions in
            envelope.values.withUnsafeBufferPointer { values in
                for i in 0..<output.count {
                    let u = positions[i]
                    let carrier = (1 - h) * sin(carrierRate * u - carrierPhase + p) + h * sin(harmonicRate * u - harmonicPhase)
                    let y = amp * values[i] * carrier
                    output[i] = Float(softLimit(swing * y))
                }
            }
        }
    }

    /// Огибающая слоя на `count` точках: от размаха и фазы не зависит, поэтому считается один раз
    /// на форму, профиль и число точек и годится для всех кадров и для эха. Степени и синус
    /// огибающей это большая часть цены точки.
    public struct Envelope: Sendable {
        public let layer: WaveLayer
        public let profile: WaveProfile
        /// `u` каждой точки: в крыле доля от выреза, в панели мягкий модуль от середины.
        let positions: [Double]
        let values: [Double]

        public var count: Int { values.count }

        /// Отрицательное `count` дает пустую огибающую.
        public init(layer: WaveLayer, count: Int, profile: WaveProfile = .wing) {
            self.layer = layer
            self.profile = profile
            let count = max(count, 0)
            let k = log(0.5) / log(WaveShape.peaks[layer.rawValue])
            let denominator = Double(max(count - 1, 1))
            var positions = [Double]()
            var values = [Double]()
            positions.reserveCapacity(count)
            values.reserveCapacity(count)
            for i in 0..<count {
                let t = Double(i) / denominator
                let u: Double
                let envelope: Double
                switch profile {
                case .wing:
                    u = t
                    envelope = pow(max(0, sin(Double.pi * pow(u, k))), 1.5)
                case .panel:
                    let x = 2 * t - 1
                    u = min((x * x + WaveShape.centerSoftness * WaveShape.centerSoftness).squareRoot(), 1)
                    let body = WaveShape.panelFloor + (1 - WaveShape.panelFloor) * sin(Double.pi * pow(u, k))
                    envelope = body * WavePaint.smoothstep(1, WaveShape.panelTaperStart, u)
                }
                positions.append(u)
                values.append(envelope)
            }
            self.positions = positions
            self.values = values
        }
    }

    /// Линейно до `wingKnee`, дальше плавно (с той же касательной) к ±1: громкая волна не
    /// упирается в край крыла углом.
    static func softLimit(_ v: Double) -> Double {
        let magnitude = abs(v)
        guard magnitude > wingKnee else { return v }
        let headroom = 1 - wingKnee
        let limited = wingKnee + headroom * tanh((magnitude - wingKnee) / headroom)
        return v < 0 ? -limited : limited
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

    /// «Вздох» кадра по весу показа (`BeatSchedule.weight`): с весом 1 пружина `spring` (свечение с
    /// упреждением `AppModel.breathLead`), с весом 0 само свечение `glow`, между ними смесь
    /// `glow + weight × (spring − glow)`. Вес вне 0...1 обрезается, нечисловой считается нулем;
    /// нечисловые `spring` или `glow` дают 0 (в итоге 0...1).
    public static func breath(spring: Float, glow: Float, weight: Float) -> Float {
        let spring = spring.isFinite ? min(max(spring, 0), 1) : 0
        let glow = glow.isFinite ? min(max(glow, 0), 1) : 0
        let weight = weight.isFinite ? weight : 0
        if weight >= 1 { return spring }
        if weight <= 0 { return glow }
        return glow + weight * (spring - glow)
    }
}

/// Цвет и прозрачность вдоль одной волны.
///
/// Градиент между цветом слоя `palette[i]` и следующим `palette[(i + 1) % 3]` течет от выреза
/// (или от середины панели) наружу на `flowSpeed` ширины в секунду и замыкается по кругу.
/// Слишком близкие цвета палитры разводятся поворотом оттенка, бас темнее, верх светлее,
/// светлота не выше `maxLightness`, чтобы теплые палитры не выгорали в белый. В тишине
/// линия тусклая, но сохраняет оттенок обложки. В крыле линия ярко выходит из выреза, в панели
/// идет через середину без провала, к внешнему краю растворяется.
///
/// `Options` добавляют переливание (цвета слоев плывут по кругу, `PaletteFlow`), цвет по
/// частотам (каждая линия своим цветом) и повышенный контраст. `Options.standard` дает тот же
/// результат бит в бит, что и вызов без них.
public enum WavePaint {
    /// Как красить линии.
    public struct Options: Sendable, Equatable {
        /// «Цвет по частотам»: линия слоя одним своим цветом, «следующий» цвет градиента это он
        /// же, поднятый по светлоте на `bandLightnessLift`.
        public var colorByBand = false
        /// Системное «Увеличить контраст»: прозрачность `contrastRestOpacity`...`contrastFullOpacity`.
        public var highContrast = false
        /// Фаза переливания 0..<1 (`PaletteFlow.phase`), 0 без переливания.
        public var flowPhase = 0.0

        public static let standard = Options()

        public init(colorByBand: Bool = false, highContrast: Bool = false, flowPhase: Double = 0) {
            self.colorByBand = colorByBand
            self.highContrast = highContrast
            self.flowPhase = flowPhase
        }
    }

    public struct Stop: Sendable, Equatable {
        /// 0...1 вдоль градиента: в крыле от выреза к краю, в панели от левого края к правому.
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
    public static let restOpacity: Float = 0.06
    public static let fullOpacity: Float = 0.75
    /// То же при «Увеличить контраст».
    public static let contrastRestOpacity: Float = 0.12
    public static let contrastFullOpacity: Float = 0.95
    /// Бас чуть прозрачнее остальных.
    public static let layerOpacity: [Float] = [0.8, 1, 1]
    /// Заливка под линией: у самой линии прозрачность `fillTopOpacity × fill` («Заливка» 0...1),
    /// не зависящая от прозрачности линии, к оси спадает до нуля. Так «Заливка» 100 % читается
    /// полосой, а не оттенком (решение по снимкам, в спецификации было 0.35 от цвета линии).
    public static let fillTopOpacity: Float = 0.55
    /// Уровень, на котором линия набирает полную яркость.
    static let opacityKnee: Float = 0.35
    /// Насыщенность в тишине (доля от цвета палитры) и уровни, между которыми она растет до полной.
    static let restChroma: Float = 0.6
    static let chromaRange: (from: Float, to: Float) = (0.02, 0.3)
    /// Сдвиг светлоты OKLab по слоям и ее потолок.
    static let layerLightness: [Float] = [-0.06, 0, 0.06]
    public static let maxLightness: Float = 0.88
    /// «Цвет по частотам»: насколько светлее свой цвет линии в другой точке ее градиента.
    static let bandLightnessLift: Float = 0.08
    /// Ширина смешения соседних участков на линии с цветом по частотам, доля ширины.
    static let bandBlend = 0.06
    /// Цвета палитры ближе этого расстояния в OKLab разводятся поворотом оттенка на `separationTurn`.
    static let minimumSeparation: Float = 0.08
    static let separationTurn: Float = 25
    /// Крыло: прозрачность у самого выреза и ширина набора полной яркости.
    static let fadeInStart = 0.85
    static let fadeInWidth = 0.04
    /// Отсюда до внешнего края линия растворяется.
    static let fadeOutStart = 0.82
    /// Свечение под островом: насыщенность не ниже `glowChroma`, затем цвет на `glowWhiteMix`
    /// смешивается с белым и светлота поднимается до `glowLightness`.
    static let glowChroma: Float = 0.12
    static let glowWhiteMix: Float = 0.35
    static let glowLightness: Float = 0.78

    /// Расстояния от выреза (или от середины панели), где стоят точки градиента: шаг 1/8 для
    /// течения цвета, плюс частые точки на проявлении у выреза (0...0.04) и на растворении у
    /// внешнего края (0.82...1), иначе линейная интерполяция между редкими точками их съедает.
    static let fadeDistances: [Double] = [0, 0.125, 0.25, 0.375, 0.5, 0.625, 0.75, 0.82, 0.86, 0.9, 0.95, 1]
    static let notchDistances: [Double] = [0.01, 0.02, 0.04]

    /// Положения точек градиента для профиля: в крыле от выреза к краю, в панели через всю
    /// ширину, симметрично от середины.
    public static func locations(for profile: WaveProfile) -> [Double] {
        switch profile {
        case .wing:
            return (fadeDistances + notchDistances).sorted()
        case .panel:
            let right = fadeDistances.map { 0.5 + $0 / 2 }
            let left = fadeDistances.dropFirst().reversed().map { 0.5 - $0 / 2 }
            return left + right
        }
    }

    /// Положения точек градиента линии с цветом по частотам (`sectionStops`): `locations(for:)`
    /// плюс края смешения участков `bandEdges ± bandBlend / 2` (в панели симметрично от середины).
    /// Без них линейная интерполяция между точками шага 1/8 растягивает смешение 0.06 на весь шаг.
    public static func sectionLocations(for profile: WaveProfile) -> [Double] {
        let half = bandBlend / 2
        let edges = [bandEdges.low - half, bandEdges.low + half, bandEdges.high - half, bandEdges.high + half]
        let added: [Double] = switch profile {
        case .wing: edges
        case .panel: edges.flatMap { [0.5 - $0 / 2, 0.5 + $0 / 2] }
        }
        return Array(Set(locations(for: profile) + added)).sorted()
    }

    /// `count` точек градиента с шагом `1 / (count - 1)`; меньше двух точек дают пустой массив.
    public static func stops(
        palette: [RGBColor], layer: WaveLayer, level: Float, time: Double, count: Int, profile: WaveProfile = .wing,
        options: Options = .standard
    ) -> [Stop] {
        guard count >= 2 else { return [] }
        let locations = (0..<count).map { Double($0) / Double(count - 1) }
        return stops(
            palette: palette, layer: layer, level: level, time: time, locations: locations, profile: profile, options: options
        )
    }

    /// Точки градиента в заданных положениях 0...1 (по возрастанию).
    public static func stops(
        palette: [RGBColor], layer: WaveLayer, level: Float, time: Double, locations: [Double], profile: WaveProfile,
        options: Options = .standard
    ) -> [Stop] {
        let placeholder = Stop(location: 0, color: RGBColor(r: 0, g: 0, b: 0), opacity: 0)
        var output = [Stop](repeating: placeholder, count: locations.count)
        output.withUnsafeMutableBufferPointer {
            stops(
                palette: palette, layer: layer, level: level, time: time, locations: locations, profile: profile,
                options: options, into: $0
            )
        }
        return output
    }

    /// То же, что `stops(palette:layer:level:time:locations:profile:options:)`, но в готовый буфер:
    /// точки нескольких линий ложатся в один массив без выделения памяти на каждую линию.
    /// Значения бит в бит те же.
    /// - Precondition: `output.count == locations.count`.
    public static func stops(
        palette: [RGBColor], layer: WaveLayer, level: Float, time: Double, locations: [Double], profile: WaveProfile,
        options: Options = .standard, into output: UnsafeMutableBufferPointer<Stop>
    ) {
        precondition(output.count == locations.count, "output.count must equal locations.count")
        let colors = flowingColors(palette, phase: options.flowPhase)
        let index = layer.rawValue
        let tint = LayerTint(colors: colors, layer: layer, colorByBand: options.colorByBand)
        let paint = LevelPaint(level: level, options: options)
        let opacity = paint.opacity * layerOpacity[index]
        let shift = flowShift(time: time)

        for (index, raw) in locations.enumerated() {
            let point = LinePoint(raw, profile: profile)
            let weight = flowWeight(u: point.u, shift: shift)
            let lab = tint.color(weight: weight, chroma: paint.chroma)
            output[index] = Stop(location: point.location, color: RGBColor(oklab: lab), opacity: opacity * point.fade)
        }
    }

    /// Границы баса и середины, середины и верха на линии с цветом по частотам: доли
    /// логарифмической оси частот `WaveLayer.bass.frequencyRange.lowerBound`...
    /// `WaveLayer.high.frequencyRange.upperBound` (40 Гц...16 кГц), около 0.306 и 0.769.
    static let bandEdges: (low: Double, high: Double) = {
        let bottom = log(WaveLayer.bass.frequencyRange.lowerBound)
        let span = log(WaveLayer.high.frequencyRange.upperBound) - bottom
        return (
            (log(WaveLayer.bass.frequencyRange.upperBound) - bottom) / span,
            (log(WaveLayer.mid.frequencyRange.upperBound) - bottom) / span
        )
    }()

    /// Точки градиента одной линии с цветом по частотам (одна волна и спектр при `colorByBand`):
    /// вдоль x участки баса, середины и верха по `bandEdges`, каждый с цветом и светлотой линии
    /// своего слоя (как `stops(..., options:)` с `colorByBand`), соседние смешиваются в OKLab на
    /// ширине `bandBlend`. В крыле бас у выреза, в панели в середине и симметрично к краям.
    /// Прозрачность как у линии середины. `options.colorByBand` здесь не читается: цвет по
    /// частотам включен всегда. Смешение видно шириной `bandBlend` на точках `sectionLocations(for:)`.
    /// - Precondition: `output.count == locations.count`.
    public static func sectionStops(
        palette: [RGBColor], level: Float, time: Double, locations: [Double], profile: WaveProfile,
        options: Options = .standard, into output: UnsafeMutableBufferPointer<Stop>
    ) {
        precondition(output.count == locations.count, "output.count must equal locations.count")
        let colors = flowingColors(palette, phase: options.flowPhase)
        let tints = WaveLayer.allCases.map { LayerTint(colors: colors, layer: $0, colorByBand: true) }
        let paint = LevelPaint(level: level, options: options)
        let opacity = paint.opacity * layerOpacity[WaveLayer.mid.rawValue]
        let shift = flowShift(time: time)
        let half = bandBlend / 2

        for (index, raw) in locations.enumerated() {
            let point = LinePoint(raw, profile: profile)
            let weight = flowWeight(u: point.u, shift: shift)
            let toMid = Float(smoothstep(bandEdges.low - half, bandEdges.low + half, point.u))
            let toHigh = Float(smoothstep(bandEdges.high - half, bandEdges.high + half, point.u))
            let bass = tints[0].color(weight: weight, chroma: paint.chroma)
            let mid = tints[1].color(weight: weight, chroma: paint.chroma)
            let high = tints[2].color(weight: weight, chroma: paint.chroma)
            let lower = toMid <= 0 ? bass : toMid >= 1 ? mid : mix(bass, mid, toMid)
            let lab = toHigh <= 0 ? lower : toHigh >= 1 ? high : mix(lower, high, toHigh)
            output[index] = Stop(location: point.location, color: RGBColor(oklab: lab), opacity: opacity * point.fade)
        }
    }

    /// Доля кольца палитры на половину линии «Спектра» (крыло или половина панели).
    static let spectrumSpan = 0.67
    /// Подсветка по высоте линии h: светлота + `spectrumLightnessLift × h`, насыщенность
    /// × (`spectrumChromaBase` + `spectrumChromaLift × h`), прозрачность × (`spectrumOpacityBase` +
    /// (1 − `spectrumOpacityBase`) × h).
    static let spectrumLightnessLift: Float = 0.10
    static let spectrumChromaBase: Float = 0.75
    static let spectrumChromaLift: Float = 0.35
    static let spectrumOpacityBase: Float = 0.7
    /// Шаг точек градиента «Спектра» вдоль половины линии.
    static let spectrumStep = 1.0 / 16

    /// Расстояния от выреза (от середины панели), где стоят точки градиента «Спектра»: 17 точек с
    /// шагом 1/16 (цвет меняется по положению), точки проявления у выреза и растворения у края.
    private static let spectrumDistances: [Double] = {
        let uniform = (0...16).map { Double($0) * spectrumStep }
        let fades = fadeDistances.filter { $0 > fadeOutStart - 1e-9 }
        return Array(Set(uniform + fades)).sorted()
    }()

    private static let spectrumWingLocations: [Double] = (spectrumDistances + notchDistances).sorted()
    private static let spectrumPanelLocations: [Double] = {
        let right = spectrumDistances.map { 0.5 + $0 / 2 }
        let left = spectrumDistances.dropFirst().reversed().map { 0.5 - $0 / 2 }
        return left + right
    }()

    /// Положения точек градиента линии «Спектра» (`spectrumStops`): в крыле от выреза к краю
    /// (24 точки), в панели через всю ширину, симметрично от середины (41 точка).
    public static func spectrumLocations(for profile: WaveProfile) -> [Double] {
        switch profile {
        case .wing: spectrumWingLocations
        case .panel: spectrumPanelLocations
        }
    }

    /// Точки градиента линии «Спектра» в положениях `spectrumLocations(for: profile)`.
    ///
    /// Цвет идет по частотам. Без «Цвета по частотам» цвета палитры (после `distinct`) стоят
    /// кольцом c0 → c1 → c2 → c0, точка на расстоянии u от выреза (в панели от середины) берет
    /// место кольца `0.67 × u − flowSpeed × time + options.flowPhase`: у выреза цвет баса, к краю
    /// цвета идут по кольцу и со временем плывут наружу, все три цвета в деле. Фаза переливания
    /// поворачивает кольцо в другую сторону: цвет у выреза идет c0, c1, c2, как у линии баса
    /// «Волн» (`PaletteFlow.apply`). Поэтому на самой малой скорости переливания (период 20 с,
    /// те же 0.05 оборота в секунду) цвета стоят, на большей идут внутрь. С «Цветом по частотам» сдвига нет и кольцо не замыкается:
    /// цвет баса у выреза, середины в середине, верха у края (палитра после переливания, как у
    /// `sectionStops`). Внутри каждого отрезка между двумя цветами смешение в OKLab по smoothstep
    /// на весь отрезок, без резких краев.
    ///
    /// Подсветка по высоте линии в точке h (`heights`: точки линии, те же, что рисуются, линейно
    /// между ними; плохие считаются нулем, ограничиваются 0...1): светлота + 0.10 h (не выше
    /// `maxLightness`), насыщенность × (0.75 + 0.35 h) и затем в гамму sRGB, прозрачность ×
    /// (0.7 + 0.3 h). Насыщенность и прозрачность всей линии от уровня `level`, как у
    /// линии середины, проявление у выреза и растворение у края как у волн.
    /// - Precondition: `output.count == spectrumLocations(for: profile).count`.
    public static func spectrumStops(
        palette: [RGBColor], heights: UnsafeBufferPointer<Float>, level: Float, time: Double, profile: WaveProfile,
        options: Options = .standard, into output: UnsafeMutableBufferPointer<Stop>
    ) {
        let locations = spectrumLocations(for: profile)
        precondition(output.count == locations.count, "output.count must equal spectrumLocations(for:).count")
        let source = palette.isEmpty ? PaletteExtractor.fallback : palette
        let colors = options.colorByBand ? flowingColors(source, phase: options.flowPhase) : distinct(source)
        let paint = LevelPaint(level: level, options: options)
        let opacity = paint.opacity * layerOpacity[WaveLayer.mid.rawValue]
        // Переливание поворачивает кольцо навстречу течению: цвет у выреза идет c0, c1, c2, как
        // цвет линии баса у «Волн» (`PaletteFlow.apply`) и свечение под островом.
        let flow = options.flowPhase.isFinite ? options.flowPhase : 0
        let shift = flowShift(time: time) - flow

        for (index, raw) in locations.enumerated() {
            let point = LinePoint(raw, profile: profile)
            let base = options.colorByBand
                ? pathColor(colors, position: point.u)
                : ringColor(colors, position: spectrumSpan * point.u - shift)
            let height = height(heights, at: point.location)
            let chroma = paint.chroma * (spectrumChromaBase + spectrumChromaLift * height)
            let lab = OKLab(
                l: min(base.l + spectrumLightnessLift * height, maxLightness),
                a: base.a * chroma,
                b: base.b * chroma
            ).fittedToSRGBGamut()
            let tint = spectrumOpacityBase + (1 - spectrumOpacityBase) * height
            output[index] = Stop(location: point.location, color: RGBColor(oklab: lab), opacity: opacity * tint * point.fade)
        }
    }

    /// То же, что `spectrumStops(palette:heights:level:time:profile:options:into:)`, в новый массив.
    public static func spectrumStops(
        palette: [RGBColor], heights: [Float], level: Float, time: Double, profile: WaveProfile,
        options: Options = .standard
    ) -> [Stop] {
        let placeholder = Stop(location: 0, color: RGBColor(r: 0, g: 0, b: 0), opacity: 0)
        var output = [Stop](repeating: placeholder, count: spectrumLocations(for: profile).count)
        heights.withUnsafeBufferPointer { heights in
            output.withUnsafeMutableBufferPointer {
                spectrumStops(
                    palette: palette, heights: heights, level: level, time: time, profile: profile, options: options,
                    into: $0
                )
            }
        }
        return output
    }

    /// Цвет кольца `colors` (c0 → c1 → ... → c0) на месте `position` (любое, берется по модулю 1):
    /// smoothstep между соседними цветами на весь отрезок.
    private static func ringColor(_ colors: [OKLab], position: Double) -> OKLab {
        let count = colors.count
        guard count > 1 else { return colors[0] }
        let wrapped = position - position.rounded(.down)
        let scaled = (wrapped < 1 ? wrapped : 0) * Double(count)
        let segment = min(Int(scaled), count - 1)
        let t = Float(smoothstep(0, 1, scaled - Double(segment)))
        return mix(colors[segment], colors[(segment + 1) % count], t)
    }

    /// Цвет пути `colors` без замыкания на месте `position` 0...1 (первый цвет в 0, последний в
    /// 1): smoothstep между соседними цветами на весь отрезок.
    private static func pathColor(_ colors: [OKLab], position: Double) -> OKLab {
        let count = colors.count
        guard count > 1 else { return colors[0] }
        let scaled = min(max(position, 0), 1) * Double(count - 1)
        let segment = min(Int(scaled), count - 2)
        let t = Float(smoothstep(0, 1, scaled - Double(segment)))
        return mix(colors[segment], colors[segment + 1], t)
    }

    /// Высота линии `heights` в положении `location` 0...1 (точки линии через всю ее ширину),
    /// линейно между точками; пустая дает 0, не конечная точка считается нулем.
    private static func height(_ heights: UnsafeBufferPointer<Float>, at location: Double) -> Float {
        guard let lastIndex = heights.indices.last else { return 0 }
        let position = location * Double(lastIndex)
        let lower = min(Int(position), lastIndex)
        let upper = min(lower + 1, lastIndex)
        let t = Float(position - Double(lower))
        let value = unitHeight(heights[lower]) + (unitHeight(heights[upper]) - unitHeight(heights[lower])) * t
        return min(max(value, 0), 1)
    }

    private static func unitHeight(_ value: Float) -> Float {
        value.isFinite ? min(max(value, 0), 1) : 0
    }

    /// Цвета слоев: палитра (пустая заменяется `PaletteExtractor.fallback`) после `distinct` и
    /// течения `PaletteFlow` на фазе `phase`. Течение идет после `distinct`: решение о повороте
    /// оттенка зависит только от палитры и не включается и не выключается от кадра к кадру, как
    /// было бы, если бы смешанные цвета пересекали порог `minimumSeparation`.
    static func flowingColors(_ palette: [RGBColor], phase: Double) -> [OKLab] {
        PaletteFlow.apply(distinct(palette.isEmpty ? PaletteExtractor.fallback : palette), phase: phase)
    }

    /// Свой и «следующий» цвет линии слоя и ее сдвиг светлоты.
    private struct LayerTint {
        let own: OKLab
        let next: OKLab
        let lightnessShift: Float

        init(colors: [OKLab], layer: WaveLayer, colorByBand: Bool) {
            let index = layer.rawValue
            own = colors[index % colors.count]
            next = colorByBand
                ? OKLab(l: min(own.l + bandLightnessLift, maxLightness), a: own.a, b: own.b)
                : colors[(index + 1) % colors.count]
            lightnessShift = layerLightness[index]
        }

        /// Цвет в точке, где доля «следующего» цвета `weight`.
        func color(weight: Float, chroma: Float) -> OKLab {
            OKLab(
                l: min(own.l + (next.l - own.l) * weight + lightnessShift, maxLightness),
                a: (own.a + (next.a - own.a) * weight) * chroma,
                b: (own.b + (next.b - own.b) * weight) * chroma
            )
        }
    }

    /// Насыщенность (доля от цвета палитры) и прозрачность линии без множителя слоя на уровне `level`.
    private struct LevelPaint {
        let chroma: Float
        let opacity: Float

        init(level: Float, options: Options) {
            let level = level.isFinite ? min(max(level, 0), 1) : 0
            let rest = options.highContrast ? contrastRestOpacity : restOpacity
            let full = options.highContrast ? contrastFullOpacity : fullOpacity
            chroma = restChroma + (1 - restChroma) * smoothstep(chromaRange.from, chromaRange.to, level)
            opacity = rest + (full - rest) * smoothstep(0, opacityKnee, level)
        }
    }

    /// Точка градиента: положение, расстояние `u` от выреза (или от середины панели) и множитель
    /// прозрачности от проявления у выреза и растворения у края.
    private struct LinePoint {
        let location: Double
        let u: Double
        let fade: Float

        init(_ raw: Double, profile: WaveProfile) {
            location = raw.isFinite ? min(max(raw, 0), 1) : 0
            let fadeIn: Double
            switch profile {
            case .wing:
                u = location
                fadeIn = fadeInStart + (1 - fadeInStart) * smoothstep(0, fadeInWidth, u)
            case .panel:
                u = abs(2 * location - 1)
                fadeIn = 1
            }
            fade = Float(fadeIn * smoothstep(1, fadeOutStart, u))
        }
    }

    /// Сдвиг течения градиента вдоль линии на момент `time`, доля ширины.
    private static func flowShift(time: Double) -> Double {
        time.isFinite ? (flowSpeed * time).truncatingRemainder(dividingBy: 1) : 0
    }

    /// Доля «следующего» цвета в точке `u` при сдвиге течения `shift`.
    private static func flowWeight(u: Double, shift: Double) -> Float {
        Float(0.5 - 0.5 * cos(2 * Double.pi * (u - shift)))
    }

    private static func mix(_ x: OKLab, _ y: OKLab, _ t: Float) -> OKLab {
        OKLab(l: x.l + (y.l - x.l) * t, a: x.a + (y.a - x.a) * t, b: x.b + (y.b - x.b) * t)
    }

    /// Палитра в OKLab, где каждый цвет, слишком близкий к одному из предыдущих, повернут по
    /// оттенку на ±25°: иначе две волны слились бы в одну.
    static func distinct(_ palette: [RGBColor]) -> [OKLab] {
        var labs = palette.map(\.oklab)
        for i in labs.indices.dropFirst() {
            if labs[..<i].contains(where: { $0.distance(to: labs[i]) < minimumSeparation }) {
                labs[i] = labs[i].rotatedHue(degrees: i % 2 == 1 ? separationTurn : -separationTurn)
            }
        }
        return labs
    }

    /// Цвет свечения под островом. Цвет палитры в OKLab: бледный доводится до насыщенности
    /// `glowChroma`, затем на 35 % смешивается с белым, светлота не ниже `glowLightness`.
    /// Теплые палитры так светятся розово-золотым, а не бурым. Серый остается серым.
    public static func glowColor(_ color: RGBColor) -> RGBColor {
        var lab = color.oklab
        let chroma = lab.chroma
        if chroma > 1e-4, chroma < glowChroma {
            let scale = glowChroma / chroma
            lab.a *= scale
            lab.b *= scale
        }
        lab.l += (1 - lab.l) * glowWhiteMix
        lab.a *= 1 - glowWhiteMix
        lab.b *= 1 - glowWhiteMix
        lab.l = max(lab.l, glowLightness)
        return RGBColor(oklab: lab)
    }

    /// Плавная ступенька: 0 при `x = edge0`, 1 при `x = edge1`; края могут идти в любом порядке.
    static func smoothstep<T: BinaryFloatingPoint>(_ edge0: T, _ edge1: T, _ x: T) -> T {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
