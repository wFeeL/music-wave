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

/// Проход отрисовки: сами линии или их размытая копия для свечения.
enum WavePass: Sendable {
    case lines
    /// Толстые линии баса и середины (верх без свечения, он должен быть четким), только
    /// слои с уровнем от `WaveSet.glowLevel`.
    case glow
}

/// Волны одного кадра: точки и цвета считаются один раз и общие для всех холстов кадра
/// (два крыла, линии и свечение).
nonisolated struct WaveSet: Sendable {
    struct Layer: Sendable {
        let layer: WaveLayer
        let level: Float
        /// y в -1...1: в крыле от выреза к краю, в панели от левого края к правому.
        let samples: [Float]
        let stops: [WavePaint.Stop]
    }

    /// Точек на крыло и на всю ширину панели.
    static let wingPoints = 64
    static let panelPoints = 128
    static let wingStops = 9
    static let panelStops = 17
    /// Ниже этого уровня у слоя нет свечения.
    static let glowLevel: Float = 0.05

    let style: WaveStyle
    let layers: [Layer]

    init(frame: WaveFrame, palette: [PaletteColor], motion: WaveMotion, time: Double, style: WaveStyle) {
        let points = style == .wing ? Self.wingPoints : Self.panelPoints
        let stopCount = style == .wing ? Self.wingStops : Self.panelStops
        self.style = style
        layers = WaveLayer.allCases.map { layer in
            let level = layer.rawValue < frame.layers.count ? frame.layers[layer.rawValue] : 0
            return Layer(
                layer: layer,
                level: level,
                samples: WaveShape.samples(
                    layer: layer, amplitude: level, phase: motion.phase(layer), count: points, profile: style.profile
                ),
                stops: WavePaint.stops(
                    palette: palette, layer: layer, level: level, time: time, count: stopCount, profile: style.profile
                )
            )
        }
    }
}

/// Три волны (бас, середина, верх) в своей области.
///
/// Путь сглажен квадратичными кривыми через середины соседних точек, линии с круглыми концами:
/// в крыле 1.75 / 1.5 / 1.25 pt, в панели 2 / 1.75 / 1.5 pt (бас, середина, верх). Размах
/// `(высота / 2 - поле) * уровень`, поле 6 pt в крыле и 3 pt в панели. Цвет из `WavePaint`.
/// Волны складываются в режиме `.plusLighter`.
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
    init(frame: WaveFrame, palette: [PaletteColor], motion: WaveMotion, time: Double, mirrored: Bool, style: WaveStyle) {
        self.init(waves: WaveSet(frame: frame, palette: palette, motion: motion, time: time, style: style), mirrored: mirrored)
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

        for layer in waves.layers {
            if pass == .glow, layer.layer == .high || layer.level < WaveSet.glowLevel {
                continue
            }
            let count = layer.samples.count
            guard count > 1 else { continue }
            let step = (end - start) / CGFloat(count - 1)
            let points = layer.samples.enumerated().map { i, y in
                CGPoint(x: start + step * CGFloat(i), y: middle - swing * CGFloat(y))
            }
            let gradient = Gradient(stops: layer.stops.map { stop in
                Gradient.Stop(color: Color(palette: stop.color, opacity: Double(stop.opacity)), location: CGFloat(stop.location))
            })
            let shading = GraphicsContext.Shading.linearGradient(
                gradient,
                startPoint: CGPoint(x: start, y: middle),
                endPoint: CGPoint(x: end, y: middle)
            )
            let width = widths[layer.layer.rawValue] * (pass == .glow ? Self.glowLineScale : 1)
            context.stroke(
                Self.smoothPath(through: points),
                with: shading,
                style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
            )
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
