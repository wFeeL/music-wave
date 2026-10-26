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
public enum WavePaint {
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

    /// `count` точек градиента с шагом `1 / (count - 1)`; меньше двух точек дают пустой массив.
    public static func stops(
        palette: [RGBColor], layer: WaveLayer, level: Float, time: Double, count: Int, profile: WaveProfile = .wing
    ) -> [Stop] {
        guard count >= 2 else { return [] }
        let locations = (0..<count).map { Double($0) / Double(count - 1) }
        return stops(palette: palette, layer: layer, level: level, time: time, locations: locations, profile: profile)
    }

    /// Точки градиента в заданных положениях 0...1 (по возрастанию).
    public static func stops(
        palette: [RGBColor], layer: WaveLayer, level: Float, time: Double, locations: [Double], profile: WaveProfile
    ) -> [Stop] {
        let placeholder = Stop(location: 0, color: RGBColor(r: 0, g: 0, b: 0), opacity: 0)
        var output = [Stop](repeating: placeholder, count: locations.count)
        output.withUnsafeMutableBufferPointer {
            stops(palette: palette, layer: layer, level: level, time: time, locations: locations, profile: profile, into: $0)
        }
        return output
    }

    /// То же, что `stops(palette:layer:level:time:locations:profile:)`, но в готовый буфер:
    /// точки нескольких линий ложатся в один массив без выделения памяти на каждую линию.
    /// Значения бит в бит те же.
    /// - Precondition: `output.count == locations.count`.
    public static func stops(
        palette: [RGBColor], layer: WaveLayer, level: Float, time: Double, locations: [Double], profile: WaveProfile,
        into output: UnsafeMutableBufferPointer<Stop>
    ) {
        precondition(output.count == locations.count, "output.count must equal locations.count")
        let colors = distinct(palette.isEmpty ? PaletteExtractor.fallback : palette)
        let index = layer.rawValue
        let own = colors[index % colors.count]
        let next = colors[(index + 1) % colors.count]
        let lightnessShift = layerLightness[index]

        let level = level.isFinite ? min(max(level, 0), 1) : 0
        let chroma = restChroma + (1 - restChroma) * smoothstep(chromaRange.from, chromaRange.to, level)
        let opacity = (restOpacity + (fullOpacity - restOpacity) * smoothstep(0, opacityKnee, level)) * layerOpacity[index]
        let shift = time.isFinite ? (flowSpeed * time).truncatingRemainder(dividingBy: 1) : 0

        for (index, raw) in locations.enumerated() {
            let location = raw.isFinite ? min(max(raw, 0), 1) : 0
            let u: Double
            let fadeIn: Double
            switch profile {
            case .wing:
                u = location
                fadeIn = fadeInStart + (1 - fadeInStart) * smoothstep(0, fadeInWidth, u)
            case .panel:
                u = abs(2 * location - 1)
                fadeIn = 1
            }
            let weight = Float(0.5 - 0.5 * cos(2 * Double.pi * (u - shift)))
            let lab = OKLab(
                l: min(own.l + (next.l - own.l) * weight + lightnessShift, maxLightness),
                a: (own.a + (next.a - own.a) * weight) * chroma,
                b: (own.b + (next.b - own.b) * weight) * chroma
            )
            let fadeOut = smoothstep(1, fadeOutStart, u)
            output[index] = Stop(location: location, color: RGBColor(oklab: lab), opacity: opacity * Float(fadeIn * fadeOut))
        }
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
