import SwiftUI
import WaveCore

/// Где рисуются волны.
enum WaveStyle: Sendable {
    /// Одно крыло: x = 0 у выреза, волна уходит к внешнему краю (`mirrored`: справа налево).
    case wing
    /// Панель или капсула: одна линия во всю ширину, симметрично от середины, `mirrored` не нужен.
    case panel

    var profile: WaveProfile {
        switch self {
        case .wing: .wing
        case .panel: .panel
        }
    }
}

/// Проход отрисовки: сами линии (с заливкой под ними) или их размытая копия для свечения.
enum WavePass: Sendable {
    case lines
    /// Толстые основные линии баса и середины (верх без свечения, он должен быть четким, эхо
    /// тоже), только линии с уровнем от `WaveSet.glowLevel`.
    case glow
}

/// Волны одного кадра: точки и цвета считаются один раз и общие для всех холстов кадра
/// (два крыла, линии и свечение). Точки всех линий лежат в одном массиве, точки градиента всех
/// наборов в другом, линии держат свои срезы: на кадр два выделения памяти, а не по паре на линию.
/// Градиенты обводки и заливки (`Gradient` из цветов `Color`) тоже строятся здесь один раз, холст
/// только ставит их между своими краями. Стиль (`WaveLook`) доходит до холста только через
/// линии, заливку и `geometry`.
nonisolated struct WaveSet: Sendable {
    /// Одна линия (`WaveLine`).
    struct Layer: Sendable {
        /// Форма линии: по ней толщина и цвет.
        let shape: WaveLayer
        /// Уровень, с которым нарисована линия: уровень источника × `amplitudeScale`.
        let level: Float
        /// Есть ли у линии свечение: основная линия баса или середины с уровнем от `glowLevel`.
        let glows: Bool
        /// Заливается ли линия при «Заливке» (`WaveLine.fills`): все, кроме призрака пика.
        let fills: Bool
        /// Множитель толщины самой линии (`WaveLine.widthScale`): у призрака пика 0.7.
        let widthScale: CGFloat
        /// y в -1...1 (у спектра 0...1): в крыле от выреза к краю, в панели от левого края к
        /// правому. Срез общего массива набора, индексы не с нуля.
        let samples: ArraySlice<Float>
        /// Точки градиента источника и формы линии с прозрачностью основной линии: у основной
        /// линии и ее эха (у спектра и призрака пика) один и тот же срез.
        let baseStops: ArraySlice<WavePaint.Stop>
        /// Номер набора `baseStops`: у основной линии и ее эха один, по нему холст строит градиент
        /// заливки один раз на набор.
        let stopSet: Int
        /// Множитель прозрачности линии (`WaveLine.opacity`).
        let opacity: Float
        /// Градиент обводки линии и ее свечения: `stops` цветами `Color`.
        let gradient: Gradient
        /// Тот же градиент со смешением цветов в перцептивном пространстве
        /// (`Gradient.colorSpace(.perceptual)`), только у линий «Спектра»; холст тогда рисует его.
        let perceptualGradient: AnyGradient?

        /// Точки градиента самой линии: `baseStops` с прозрачностью × `opacity`.
        var stops: [WavePaint.Stop] {
            baseStops.map { WavePaint.Stop(location: $0.location, color: $0.color, opacity: $0.opacity * opacity) }
        }
    }

    /// Точек на крыло и на всю ширину панели.
    static let wingPoints = 64
    /// В панели около 2 pt между точками: гармоника на 436 pt рисуется без потери размаха.
    static let panelPoints = 224
    /// Эхо середины и верха в крыле: вдвое меньше точек. Путь эха строится и закрашивается
    /// вдвое быстрее, а расхождение с эхом на 64 точках не больше 0.15 pt (0.5 pt при «Размахе»
    /// 2×). У баса огибающая у выреза растет круто (`u^0.43`), на 32 точках его эхо у выреза
    /// расходится до 1 pt, поэтому бас, как и панель (гармоника), остается с полным числом точек.
    static let wingEchoPoints = wingPoints / 2
    /// Положения точек градиента: частые на проявлении у выреза и растворении у края.
    static let wingLocations = WavePaint.locations(for: .wing)
    static let panelLocations = WavePaint.locations(for: .panel)
    /// Они же плюс края смешения участков: у линии, раскрашенной по частотам (`paintsSections`).
    static let wingSectionLocations = WavePaint.sectionLocations(for: .wing)
    static let panelSectionLocations = WavePaint.sectionLocations(for: .panel)
    /// У «Спектра» свои: шаг 1/16 плюс проявление и растворение (`WavePaint.spectrumLocations`).
    static let wingSpectrumLocations = WavePaint.spectrumLocations(for: .wing)
    static let panelSpectrumLocations = WavePaint.spectrumLocations(for: .panel)
    /// Ниже этого уровня у слоя нет свечения.
    static let glowLevel: Float = 0.05

    /// Огибающие по форме (`WaveLayer.rawValue`): от кадра не зависят, считаются один раз.
    private static let wingEnvelopes = envelopes(count: wingPoints, profile: .wing)
    private static let wingEchoEnvelopes = envelopes(count: wingEchoPoints, profile: .wing)
    private static let panelEnvelopes = envelopes(count: panelPoints, profile: .panel)

    private static func envelopes(count: Int, profile: WaveProfile) -> [WaveShape.Envelope] {
        WaveLayer.allCases.map { WaveShape.Envelope(layer: $0, count: count, profile: profile) }
    }

    /// Огибающая линии: число точек по стилю и по тому, эхо ли это (`wingEchoPoints`). У линии
    /// спектра огибающая задает только число точек (`wingPoints` или `panelPoints`), призрак пика
    /// в крыле идет на 32 точках, как эхо.
    static func envelope(for line: WaveLine, style: WaveStyle) -> WaveShape.Envelope {
        let index = line.shape.rawValue
        switch style {
        case .wing:
            let echo = (line.phaseOffset != 0 && line.shape != .bass) || line.source == .spectrumPeak
            return echo ? wingEchoEnvelopes[index] : wingEnvelopes[index]
        case .panel:
            return panelEnvelopes[index]
        }
    }

    /// Красится ли линия участками баса, середины и верха (`WavePaint.sectionStops`): одна линия
    /// общего уровня при «Цвете по частотам». Линия слоя при нем красится своим цветом
    /// (`WavePaint.Options.colorByBand`), «Спектр» своими точками (`WavePaint.spectrumStops`).
    static func paintsSections(_ source: WaveLine.Source, colorByBand: Bool) -> Bool {
        guard colorByBand else { return false }
        switch source {
        case .overall: return true
        case .layer, .spectrum, .spectrumPeak: return false
        }
    }

    /// Набор точек градиента, которым красится источник: призрак пика берет набор линии спектра
    /// и отличается от нее только прозрачностью.
    static func stopSource(_ source: WaveLine.Source) -> WaveLine.Source {
        source == .spectrumPeak ? .spectrum : source
    }

    /// Половина ширины линии «Спектра», pt, по которой выбирается σ сглаживания полос
    /// (`SpectrumShape.sigma(halfWidth:)`): в крыле «Ширина крыльев», в панели половина ширины ее
    /// полосы волн `panelWidth`. Без `panelWidth` панель считается широкой (σ наименьшее).
    static func spectrumHalfWidth(style: WaveStyle, appearance: WaveAppearance, panelWidth: Double?) -> Double {
        switch style {
        case .wing: appearance.wingWidth
        case .panel: panelWidth.map { $0 / 2 } ?? .infinity
        }
    }

    let style: WaveStyle
    let layers: [Layer]
    /// «Толщина линий», множитель.
    let thickness: CGFloat
    /// Заливка стиля 0...1 (`WaveAppearance.fill`); 0 без заливки.
    let fill: Double
    /// Базовая линия (она же ось заливки) и множитель толщины линий стиля
    /// (`WaveAppearance.lookGeometry`). Холст берет их только отсюда.
    let geometry: WaveLookGeometry
    /// Градиенты заливки по номеру набора точек градиента (`Layer.stopSet`): цвет набора с
    /// прозрачностью `fillTopOpacity × fill`, без прозрачности линии, поэтому у основной линии и
    /// ее эха один. Пустой без заливки.
    let fillGradients: [Gradient]
    /// Те же градиенты заливки со смешением в перцептивном пространстве: у наборов «Спектра»
    /// градиент, у остальных `nil`. Пустой без заливки.
    let perceptualFillGradients: [AnyGradient?]

    /// Пустой набор: холст ничего не рисует.
    init(empty style: WaveStyle) {
        self.style = style
        layers = []
        thickness = 1
        fill = 0
        geometry = .standard
        fillGradients = []
        perceptualFillGradients = []
    }

    /// Градиент из точек `stops`, прозрачность каждой точки через `opacity`.
    static func gradient(_ stops: ArraySlice<WavePaint.Stop>, opacity: (Float) -> Double) -> Gradient {
        Gradient(stops: stops.map { stop in
            Gradient.Stop(color: Color(palette: stop.color, opacity: opacity(stop.opacity)), location: CGFloat(stop.location))
        })
    }

    /// Градиент набора с источником `source` со смешением цветов в перцептивном пространстве: у
    /// «Спектра» соседние точки далеких оттенков (кольцо палитры) смешиваются без серой середины.
    /// У «Волн» `nil`, их вид не меняется.
    static func perceptual(_ gradient: Gradient, source: WaveLine.Source) -> AnyGradient? {
        stopSource(source) == .spectrum ? gradient.colorSpace(.perceptual) : nil
    }

    /// По линии на каждую `appearance.lines(for: style.profile)`: размах от уровня источника
    /// (общий уровень у одной волны и спектра) × `amplitudeScale` и «Размаха», фаза формы со
    /// сдвигом `phaseOffset`. Цвет идет от уровня источника с переливанием `flowPhase`, «Цветом по
    /// частотам» и контрастом (`WavePaint.Options`), прозрачность × `opacity`: эхо делит точки
    /// градиента со своей основной линией и отличается от нее только прозрачностью. Заливка `fill`,
    /// геометрия `lookGeometry`.
    ///
    /// «Спектр» (`SpectrumShape`): линия идет через полосы после пружин `spectrum.values`, призрак
    /// пика через `spectrum.peaks`; без `spectrum` обе через полосы кадра `frame.bands`. σ
    /// сглаживания по ширине (`spectrumHalfWidth`, в панели по `panelWidth`), бегущая рябь с фазой
    /// середины `motion.phase(.mid, profile:)` и «дыхание» от ее медленной громкости. Цвет из
    /// `WavePaint.spectrumStops` с высотой самой линии в каждой точке, призрак берет тот же набор,
    /// градиенты смешивают цвета в перцептивном пространстве (`perceptualGradient`).
    ///
    /// Раскладка `style` здесь совпадает с той, что нужна `lines(for:)`: у «Волн» и «Спектра»
    /// линии от раскладки не зависят.
    init(
        frame: WaveFrame, palette: [PaletteColor], motion: WaveMotion, time: Double, style: WaveStyle,
        appearance: WaveAppearance, flowPhase: Double = 0, spectrum: SpectrumLevels? = nil, panelWidth: Double? = nil
    ) {
        let profile = style.profile
        let colorByBand = appearance.colorByBand
        let fillAmount = appearance.fill
        self.style = style
        thickness = CGFloat(appearance.thickness)
        fill = fillAmount
        geometry = appearance.lookGeometry
        let lines = appearance.lines(for: profile)
        let options = WavePaint.Options(
            colorByBand: colorByBand, highContrast: appearance.highContrast, flowPhase: flowPhase
        )
        func sourceLevel(_ source: WaveLine.Source) -> Float {
            switch source {
            case .overall, .spectrum, .spectrumPeak: frame.level
            case .layer(let layer): layer.rawValue < frame.layers.count ? frame.layers[layer.rawValue] : 0
            }
        }

        // Точки линий: все в одном массиве, у каждой линии свой отрезок. Они нужны раньше цвета:
        // «Спектр» берет подсветку по высоте своей линии.
        let envelopes = lines.map { Self.envelope(for: $0, style: style) }
        let levels = lines.map { sourceLevel($0.source) * $0.amplitudeScale }
        var ranges: [Range<Int>] = []
        var total = 0
        for envelope in envelopes {
            ranges.append(total..<(total + envelope.count))
            total += envelope.count
        }
        let bands = spectrum?.values ?? frame.bands
        let peaks = spectrum?.peaks ?? bands
        let smoothing = SpectrumShape.sigma(
            halfWidth: Self.spectrumHalfWidth(style: style, appearance: appearance, panelWidth: panelWidth)
        )
        let ripple = SpectrumShape.Ripple(
            phase: motion.phase(.mid, profile: profile),
            floor: SpectrumShape.Ripple.floor(slowLevel: motion.slowLevel(.mid))
        )
        var samples = [Float](repeating: 0, count: total)
        samples.withUnsafeMutableBufferPointer { buffer in
            for (index, line) in lines.enumerated() {
                let output = UnsafeMutableBufferPointer(rebasing: buffer[ranges[index]])
                switch line.source {
                case .spectrum, .spectrumPeak:
                    SpectrumShape.samples(
                        bands: line.source == .spectrumPeak ? peaks : bands, count: output.count, profile: profile,
                        gain: appearance.amplitude * Double(line.amplitudeScale), smoothing: smoothing, ripple: ripple,
                        into: output
                    )
                case .overall, .layer:
                    let phase = motion.phase(line.shape, profile: profile).shifted(by: line.phaseOffset)
                    WaveShape.samples(
                        amplitude: levels[index], phase: phase, envelope: envelopes[index], gain: appearance.amplitude,
                        into: output
                    )
                }
            }
        }

        // Наборы точек градиента: по одному на источник и форму, эхо берет набор основной линии,
        // призрак пика набор линии спектра (`stopSource`).
        var keys: [(source: WaveLine.Source, shape: WaveLayer)] = []
        let stopSets = lines.map { line -> Int in
            let source = Self.stopSource(line.source)
            if let index = keys.firstIndex(where: { $0.source == source && $0.shape == line.shape }) {
                return index
            }
            keys.append((source, line.shape))
            return keys.count - 1
        }
        // Положения точек набора: у линии, раскрашенной по частотам, еще края смешения участков,
        // у «Спектра» свои.
        let keyLocations: [[Double]] = keys.map { key in
            if key.source == .spectrum {
                return style == .wing ? Self.wingSpectrumLocations : Self.panelSpectrumLocations
            }
            let sections = Self.paintsSections(key.source, colorByBand: colorByBand)
            switch style {
            case .wing: return sections ? Self.wingSectionLocations : Self.wingLocations
            case .panel: return sections ? Self.panelSectionLocations : Self.panelLocations
            }
        }
        var stopRanges: [Range<Int>] = []
        var stopTotal = 0
        for locations in keyLocations {
            stopRanges.append(stopTotal..<(stopTotal + locations.count))
            stopTotal += locations.count
        }
        // Высоты для подсветки «Спектра»: точки его линии (первой с этим набором).
        let spectrumRange = lines.firstIndex { Self.stopSource($0.source) == .spectrum }.map { ranges[$0] }
        let placeholder = WavePaint.Stop(location: 0, color: PaletteColor(r: 0, g: 0, b: 0), opacity: 0)
        var stops = [WavePaint.Stop](repeating: placeholder, count: stopTotal)
        stops.withUnsafeMutableBufferPointer { buffer in
            samples.withUnsafeBufferPointer { drawn in
                for (index, key) in keys.enumerated() {
                    let output = UnsafeMutableBufferPointer(rebasing: buffer[stopRanges[index]])
                    let level = sourceLevel(key.source)
                    if key.source == .spectrum {
                        let heights = spectrumRange.map { UnsafeBufferPointer(rebasing: drawn[$0]) }
                            ?? UnsafeBufferPointer<Float>(start: nil, count: 0)
                        WavePaint.spectrumStops(
                            palette: palette, heights: heights, level: level, time: time, profile: profile,
                            options: options, into: output
                        )
                    } else if Self.paintsSections(key.source, colorByBand: colorByBand) {
                        WavePaint.sectionStops(
                            palette: palette, level: level, time: time, locations: keyLocations[index],
                            profile: profile, options: options, into: output
                        )
                    } else {
                        WavePaint.stops(
                            palette: palette, layer: key.shape, level: level, time: time,
                            locations: keyLocations[index], profile: profile, options: options, into: output
                        )
                    }
                }
            }
        }

        layers = lines.indices.map { index in
            let line = lines[index]
            let set = stopSets[index]
            let baseStops = stops[stopRanges[set]]
            let opacity = line.opacity
            let gradient = Self.gradient(baseStops) { Double($0 * opacity) }
            return Layer(
                shape: line.shape,
                level: levels[index],
                glows: line.glows && levels[index] >= Self.glowLevel,
                fills: line.fills,
                widthScale: CGFloat(line.widthScale),
                samples: samples[ranges[index]],
                baseStops: baseStops,
                stopSet: set,
                opacity: opacity,
                gradient: gradient,
                perceptualGradient: Self.perceptual(gradient, source: line.source)
            )
        }
        if fillAmount > 0 {
            let top = min(Double(WavePaint.fillTopOpacity) * fillAmount, 1)
            let gradients = stopRanges.map { range in
                Self.gradient(stops[range]) { _ in top }
            }
            fillGradients = gradients
            perceptualFillGradients = keys.indices.map { Self.perceptual(gradients[$0], source: keys[$0].source) }
        } else {
            fillGradients = []
            perceptualFillGradients = []
        }
    }
}

/// Линии волн (`WaveSet`, по умолчанию бас, середина, верх) в своей области.
///
/// Путь сглажен квадратичными кривыми через середины соседних точек, линии с круглыми концами:
/// в крыле 1.75 / 1.5 / 1.25 pt, в панели 2 / 1.75 / 1.5 pt (по форме: бас, середина, верх),
/// × «Толщина линий» × множитель толщины стиля (`WaveSet.geometry.widthScale`) × множитель
/// самой линии (`WaveSet.Layer.widthScale`, у призрака пика «Спектра» 0.7). Базовая линия
/// по `WaveSet.geometry.baseline`: от середины размах `(высота / 2 - поле) * y` вверх и вниз, от
/// нижней (спектр) размах `(высота - 2 × поле) * y` вверх от `высота - поле`; поле 6 pt в крыле
/// и 3 pt в панели. Цвет из `WavePaint`, у «Спектра» градиент в перцептивном пространстве
/// (`WaveSet.Layer.perceptualGradient`). Волны складываются в режиме `.plusLighter`, заливка под
/// ними (кроме призрака пика, `WaveSet.Layer.fills`) до базовой линии.
struct WaveCanvas: View {
    let waves: WaveSet
    let mirrored: Bool
    var pass: WavePass = .lines

    init(waves: WaveSet, mirrored: Bool, pass: WavePass = .lines) {
        self.waves = waves
        self.mirrored = mirrored
        self.pass = pass
    }

    /// Волны одного холста из кадра анализа; острову удобнее общий `WaveSet` на кадр.
    init(
        frame: WaveFrame, palette: [PaletteColor], motion: WaveMotion, time: Double, mirrored: Bool, style: WaveStyle,
        appearance: WaveAppearance = .standard
    ) {
        self.init(
            waves: WaveSet(frame: frame, palette: palette, motion: motion, time: time, style: style, appearance: appearance),
            mirrored: mirrored
        )
    }

    var body: some View {
        let drawing = WaveDrawing(waves: waves, mirrored: mirrored, pass: pass)
        Canvas { context, size in
            drawing.draw(in: &context, size: size)
        }
    }
}

/// Входные данные холста. Замыкание `Canvas` захватывает только это значение.
nonisolated struct WaveDrawing: Sendable {
    static let wingLineWidths: [CGFloat] = [1.75, 1.5, 1.25]
    static let panelLineWidths: [CGFloat] = [2, 1.75, 1.5]
    static let wingEdgeMargin: CGFloat = 6
    static let panelEdgeMargin: CGFloat = 3
    /// Во сколько раз толще линии свечения.
    static let glowLineScale: CGFloat = 2.2
    /// Половина волны ниже этого размаха, pt, не заливается: заливать нечего.
    static let minimumFillExtent: CGFloat = 0.5

    let waves: WaveSet
    let mirrored: Bool
    let pass: WavePass

    func draw(in context: inout GraphicsContext, size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        context.blendMode = .plusLighter
        let isWing = waves.style == .wing
        let margin = isWing ? Self.wingEdgeMargin : Self.panelEdgeMargin
        // Базовая линия стиля, она же ось заливки, и размах от нее.
        let baseline: CGFloat
        let swing: CGFloat
        switch waves.geometry.baseline {
        case .center:
            baseline = size.height / 2
            swing = max(size.height / 2 - margin, 0)
        case .bottom:
            baseline = size.height - margin
            swing = max(size.height - 2 * margin, 0)
        }
        let widths = isWing ? Self.wingLineWidths : Self.panelLineWidths
        let widthScale = CGFloat(waves.geometry.widthScale)
        // Крыло идет от выреза: слева направо или зеркально. Панель всегда слева направо.
        let start: CGFloat = isWing && mirrored ? size.width : 0
        let end: CGFloat = isWing && mirrored ? 0 : size.width

        // x точек считаются один раз на холст и число точек: их делят основные линии и эхо.
        var columns = Columns(start: start, end: end)
        // Путь каждой линии строится один раз и идет и в заливку, и в обводку.
        let lines: [(layer: WaveSet.Layer, path: Path)] = waves.layers.compactMap { layer in
            let count = layer.samples.count
            guard count > 1, pass == .lines || layer.glows else { return nil }
            let xs = columns.positions(count: count)
            let points = zip(xs, layer.samples).map { x, y in
                CGPoint(x: x, y: baseline - swing * CGFloat(y))
            }
            return (layer: layer, path: Self.smoothPath(through: points))
        }
        // Градиенты готовы в наборе (общие для крыльев и проходов), холст задает только края.
        let startPoint = CGPoint(x: start, y: baseline)
        let endPoint = CGPoint(x: end, y: baseline)

        // Призрак пика «Спектра» не заливается.
        let filled: [(layer: WaveSet.Layer, path: Path)] = pass == .lines && waves.fill > 0
            ? lines.filter { $0.layer.fills }
            : []
        if !filled.isEmpty {
            // Цвет заливки не зависит от прозрачности линии: у основной линии и ее эха один
            // градиент набора точек градиента.
            let fillGradients = waves.fillGradients
            let perceptualFills = waves.perceptualFillGradients
            drawFill(filled, in: context, size: size, start: start, end: end, middle: baseline, swing: swing) { layer in
                if layer.stopSet < perceptualFills.count, let perceptual = perceptualFills[layer.stopSet] {
                    return .linearGradient(perceptual, startPoint: startPoint, endPoint: endPoint)
                }
                let gradient = layer.stopSet < fillGradients.count ? fillGradients[layer.stopSet] : Gradient(stops: [])
                return .linearGradient(gradient, startPoint: startPoint, endPoint: endPoint)
            }
        }

        for line in lines {
            let scale: CGFloat = waves.thickness * widthScale * line.layer.widthScale
            let width = widths[line.layer.shape.rawValue] * scale * (pass == .glow ? Self.glowLineScale : 1)
            let shading: GraphicsContext.Shading = if let perceptual = line.layer.perceptualGradient {
                .linearGradient(perceptual, startPoint: startPoint, endPoint: endPoint)
            } else {
                .linearGradient(line.layer.gradient, startPoint: startPoint, endPoint: endPoint)
            }
            context.stroke(
                line.path,
                with: shading,
                style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
            )
        }
    }

    /// x точек линий одного холста по числу точек: шаг `(end - start) / (count - 1)` от `start`.
    /// Живет один вызов `draw`, поэтому ширина и зеркальность у всех запросов одни.
    private struct Columns {
        let start: CGFloat
        let end: CGFloat
        private var cached: [(count: Int, xs: [CGFloat])] = []

        init(start: CGFloat, end: CGFloat) {
            self.start = start
            self.end = end
        }

        mutating func positions(count: Int) -> [CGFloat] {
            if let hit = cached.first(where: { $0.count == count }) {
                return hit.xs
            }
            let step = (end - start) / CGFloat(count - 1)
            let xs = (0..<count).map { start + step * CGFloat($0) }
            cached.append((count, xs))
            return xs
        }
    }

    /// Заливка между каждой линией и осью `middle` (базовая линия стиля: середина или, у спектра,
    /// нижняя, тогда нижняя половина пустая). Цвет по горизонтали тот же, что у линии, прозрачность
    /// у линии `fillTopOpacity × fill` без учета прозрачности самой линии (`colors`): к краям
    /// крыла и в тишине заливка сходит на нет вместе с размахом. По вертикали одна маска
    /// на холст (`clipToLayer`, единственный слой вне экрана, и только при заливке): у каждой
    /// линии верхняя и нижняя половины обрезаются по оси отдельно, градиент маски от полной
    /// у гребня линии в этой половине до нуля у оси. Так под гребнем видна вся заливка, сколько
    /// бы ни был размах. Маски линий складываются обычным наложением.
    private func drawFill(
        _ lines: [(layer: WaveSet.Layer, path: Path)], in context: GraphicsContext, size: CGSize,
        start: CGFloat, end: CGFloat, middle: CGFloat, swing: CGFloat,
        colors: (WaveSet.Layer) -> GraphicsContext.Shading
    ) {
        let areas = lines.map { line in
            var area = line.path
            area.addLine(to: CGPoint(x: end, y: middle))
            area.addLine(to: CGPoint(x: start, y: middle))
            area.closeSubpath()
            return area
        }
        let upper = CGRect(x: 0, y: 0, width: size.width, height: middle)
        let lower = CGRect(x: 0, y: middle, width: size.width, height: max(size.height - middle, 0))
        let fade = Gradient(colors: [.white, Color(.sRGB, white: 1, opacity: 0)])
        var fills = context
        fills.clipToLayer { mask in
            mask.blendMode = .normal
            for (line, area) in zip(lines, areas) {
                let crest = swing * CGFloat(max(line.layer.samples.max() ?? 0, 0))
                let trough = swing * CGFloat(max(-(line.layer.samples.min() ?? 0), 0))
                for (half, edge, extent) in [(upper, middle - crest, crest), (lower, middle + trough, trough)]
                where extent >= Self.minimumFillExtent {
                    var clipped = mask
                    clipped.clip(to: Path(half))
                    clipped.fill(
                        area,
                        with: .linearGradient(fade, startPoint: CGPoint(x: 0, y: edge), endPoint: CGPoint(x: 0, y: middle))
                    )
                }
            }
        }
        for (line, area) in zip(lines, areas) {
            fills.fill(area, with: colors(line.layer))
        }
    }

    /// Путь через середины соседних точек, сами точки служат опорными для квадратичных кривых:
    /// касательная непрерывна, пиков и изломов нет. Первая и последняя точки на пути.
    static func smoothPath(through points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            return path
        }
        path.addLine(to: midpoint(points[0], points[1]))
        for index in 1..<(points.count - 1) {
            path.addQuadCurve(to: midpoint(points[index], points[index + 1]), control: points[index])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    private static func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }
}

extension Color {
    /// Цвет палитры в sRGB.
    init(palette color: PaletteColor, opacity: Double = 1) {
        self.init(.sRGB, red: Double(color.r), green: Double(color.g), blue: Double(color.b), opacity: opacity)
    }
}
