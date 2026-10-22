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
/// (два крыла, линии и свечение).
nonisolated struct WaveSet: Sendable {
    /// Одна линия (`WaveLine`).
    struct Layer: Sendable {
        /// Форма линии: по ней толщина и цвет.
        let shape: WaveLayer
        /// Уровень, с которым нарисована линия: уровень источника × `amplitudeScale`.
        let level: Float
        /// Есть ли у линии свечение: основная линия баса или середины с уровнем от `glowLevel`.
        let glows: Bool
        /// y в -1...1: в крыле от выреза к краю, в панели от левого края к правому.
        let samples: [Float]
        let stops: [WavePaint.Stop]
    }

    /// Точек на крыло и на всю ширину панели.
    static let wingPoints = 64
    /// В панели около 2 pt между точками: гармоника на 436 pt рисуется без потери размаха.
    static let panelPoints = 224
    /// Положения точек градиента: частые на проявлении у выреза и растворении у края.
    static let wingLocations = WavePaint.locations(for: .wing)
    static let panelLocations = WavePaint.locations(for: .panel)
    /// Ниже этого уровня у слоя нет свечения.
    static let glowLevel: Float = 0.05

    let style: WaveStyle
    let layers: [Layer]
    /// «Толщина линий», множитель.
    let thickness: CGFloat
    /// «Заливка» 0...1; 0 без заливки.
    let fill: Double

    /// Пустой набор: холст ничего не рисует. Так стоит слой волн, которого сейчас не видно.
    init(empty style: WaveStyle) {
        self.style = style
        layers = []
        thickness = 1
        fill = 0
    }

    /// По линии на каждую `appearance.lines`: размах от уровня источника (общий уровень у
    /// одной волны) × `amplitudeScale` и «Размаха», фаза формы со сдвигом `phaseOffset`. Цвет
    /// идет от уровня источника, прозрачность × `opacity`: эхо делит точки градиента со своей
    /// основной линией и отличается от нее только прозрачностью.
    init(
        frame: WaveFrame, palette: [PaletteColor], motion: WaveMotion, time: Double, style: WaveStyle,
        appearance: WaveAppearance
    ) {
        let points = style == .wing ? Self.wingPoints : Self.panelPoints
        let locations = style == .wing ? Self.wingLocations : Self.panelLocations
        self.style = style
        thickness = CGFloat(appearance.thickness)
        fill = appearance.fill
        var computed: [(source: WaveLine.Source, shape: WaveLayer, stops: [WavePaint.Stop])] = []
        layers = appearance.lines.map { line in
            let sourceLevel: Float = switch line.source {
            case .overall: frame.level
            case .layer(let layer): layer.rawValue < frame.layers.count ? frame.layers[layer.rawValue] : 0
            }
            let level = sourceLevel * line.amplitudeScale
            let stops: [WavePaint.Stop]
            if let shared = computed.first(where: { $0.source == line.source && $0.shape == line.shape }) {
                stops = shared.stops
            } else {
                stops = WavePaint.stops(
                    palette: palette, layer: line.shape, level: sourceLevel, time: time, locations: locations,
                    profile: style.profile
                )
                computed.append((line.source, line.shape, stops))
            }
            let phase = motion.phase(line.shape, profile: style.profile).shifted(by: line.phaseOffset)
            return Layer(
                shape: line.shape,
                level: level,
                glows: line.phaseOffset == 0 && line.shape != .high && level >= Self.glowLevel,
                samples: WaveShape.samples(
                    layer: line.shape, amplitude: level, phase: phase, count: points, profile: style.profile,
                    gain: appearance.amplitude
                ),
                stops: line.opacity == 1 ? stops : stops.map { stop in
                    WavePaint.Stop(location: stop.location, color: stop.color, opacity: stop.opacity * line.opacity)
                }
            )
        }
    }
}

/// Линии волн (`WaveSet`, по умолчанию бас, середина, верх) в своей области.
///
/// Путь сглажен квадратичными кривыми через середины соседних точек, линии с круглыми концами:
/// в крыле 1.75 / 1.5 / 1.25 pt, в панели 2 / 1.75 / 1.5 pt (по форме: бас, середина, верх),
/// × «Толщина линий». Размах `(высота / 2 - поле) * y`, поле 6 pt в крыле и 3 pt в панели.
/// Цвет из `WavePaint`. Волны складываются в режиме `.plusLighter`, заливка под ними.
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
        let middle = size.height / 2
        let swing = max(size.height / 2 - (isWing ? Self.wingEdgeMargin : Self.panelEdgeMargin), 0)
        let widths = isWing ? Self.wingLineWidths : Self.panelLineWidths
        // Крыло идет от выреза: слева направо или зеркально. Панель всегда слева направо.
        let start: CGFloat = isWing && mirrored ? size.width : 0
        let end: CGFloat = isWing && mirrored ? 0 : size.width

        let lines: [(layer: WaveSet.Layer, path: Path)] = waves.layers.compactMap { layer in
            let count = layer.samples.count
            guard count > 1, pass == .lines || layer.glows else { return nil }
            let step = (end - start) / CGFloat(count - 1)
            let points = layer.samples.enumerated().map { i, y in
                CGPoint(x: start + step * CGFloat(i), y: middle - swing * CGFloat(y))
            }
            return (layer: layer, path: Self.smoothPath(through: points))
        }
        func shading(_ stops: [WavePaint.Stop], opacity: (Float) -> Double) -> GraphicsContext.Shading {
            let gradient = Gradient(stops: stops.map { stop in
                Gradient.Stop(color: Color(palette: stop.color, opacity: opacity(stop.opacity)), location: CGFloat(stop.location))
            })
            return .linearGradient(gradient, startPoint: CGPoint(x: start, y: middle), endPoint: CGPoint(x: end, y: middle))
        }

        if pass == .lines, waves.fill > 0, !lines.isEmpty {
            drawFill(lines, in: context, size: size, start: start, end: end, middle: middle, swing: swing) { stops in
                let top = Double(WavePaint.fillTopOpacity) * waves.fill
                return shading(stops) { min(top * Double($0), 1) }
            }
        }

        for line in lines {
            let width = widths[line.layer.shape.rawValue] * waves.thickness * (pass == .glow ? Self.glowLineScale : 1)
            context.stroke(
                line.path,
                with: shading(line.layer.stops) { Double($0) },
                style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
            )
        }
    }

    /// Заливка между каждой линией и осью. Цвет по горизонтали тот же, что у линии, с
    /// прозрачностью `fillTopOpacity × fill` × ее собственная (`colors`). По вертикали одна маска
    /// на холст (`clipToLayer`, единственный слой вне экрана, и только при заливке): у каждой
    /// линии верхняя и нижняя половины обрезаются по оси отдельно, градиент маски от полной
    /// у гребня линии в этой половине до нуля у оси. Так под гребнем видна вся заливка, сколько
    /// бы ни был размах. Маски линий складываются обычным наложением.
    private func drawFill(
        _ lines: [(layer: WaveSet.Layer, path: Path)], in context: GraphicsContext, size: CGSize,
        start: CGFloat, end: CGFloat, middle: CGFloat, swing: CGFloat,
        colors: ([WavePaint.Stop]) -> GraphicsContext.Shading
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
            fills.fill(area, with: colors(line.layer.stops))
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
