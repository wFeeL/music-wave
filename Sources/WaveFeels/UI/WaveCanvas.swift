import SwiftUI
import WaveCore

/// Где рисуются волны.
enum WaveStyle: Sendable {
    /// Одно крыло: x = 0 у выреза, волна уходит к внешнему краю (`mirrored`: справа налево).
    case wing
    /// Панель или капсула: две половины расходятся из середины, `mirrored` не нужен.
    case panel
}

/// Три волны (бас, середина, верх) в своей области.
///
/// Каждая волна: 64 точки `WaveShape.samples` с фазой из `motion`, размах
/// `(высота / 2 - 3) * layers[i]`, путь сглажен квадратичными кривыми через середины соседних
/// точек, линия 2 pt (бас 2.5 pt) с круглыми концами. Цвет из `WavePaint`: градиент между двумя
/// цветами палитры течет вдоль волны, прозрачность растет с уровнем и уходит в ноль у краев.
/// Волны складываются в режиме `.plusLighter`, пересечения светлеют.
struct WaveCanvas: View {
    let frame: WaveFrame
    let palette: [PaletteColor]
    let motion: WaveMotion
    let time: Double
    let mirrored: Bool
    let style: WaveStyle
    /// Множитель толщины линий: копия для свечения рисуется толще.
    var lineScale: CGFloat = 1

    var body: some View {
        let drawing = WaveDrawing(
            layers: frame.layers,
            palette: palette,
            phases: WaveLayer.allCases.map { motion.phase($0) },
            time: time,
            mirrored: mirrored,
            style: style,
            lineScale: lineScale
        )
        Canvas { context, size in
            drawing.draw(in: &context, size: size)
        }
    }
}

/// Все входные данные кадра волн. Замыкание `Canvas` захватывает только это значение.
nonisolated struct WaveDrawing: Sendable {
    static let pointCount = 64
    static let gradientStops = 9
    static let edgeMargin: CGFloat = 3
    static let bassLineWidth: CGFloat = 2.5
    static let lineWidth: CGFloat = 2

    let layers: [Float]
    let palette: [PaletteColor]
    let phases: [Double]
    let time: Double
    let mirrored: Bool
    let style: WaveStyle
    let lineScale: CGFloat

    func draw(in context: inout GraphicsContext, size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        context.blendMode = .plusLighter
        switch style {
        case .wing:
            drawSide(in: &context, origin: mirrored ? size.width : 0, length: size.width, direction: mirrored ? -1 : 1, height: size.height)
        case .panel:
            let half = size.width / 2
            drawSide(in: &context, origin: half, length: half, direction: -1, height: size.height)
            drawSide(in: &context, origin: half, length: half, direction: 1, height: size.height)
        }
    }

    /// Одна сторона: от `origin` (x = 0 волны) на `length` в направлении `direction`.
    private func drawSide(in context: inout GraphicsContext, origin: CGFloat, length: CGFloat, direction: CGFloat, height: CGFloat) {
        let middle = height / 2
        let swing = max(height / 2 - Self.edgeMargin, 0)
        let count = Self.pointCount
        let step = direction * length / CGFloat(count - 1)

        for layer in WaveLayer.allCases {
            let index = layer.rawValue
            let level = index < layers.count ? layers[index] : 0
            let phase = index < phases.count ? phases[index] : 0
            let samples = WaveShape.samples(layer: layer, amplitude: level, phase: phase, count: count)
            let points = samples.enumerated().map { i, y in
                CGPoint(x: origin + step * CGFloat(i), y: middle - swing * CGFloat(y))
            }

            let stops = WavePaint.stops(
                palette: palette, layer: layer, level: level, time: time, count: Self.gradientStops
            ).map { stop in
                Gradient.Stop(color: Color(palette: stop.color, opacity: Double(stop.opacity)), location: CGFloat(stop.location))
            }
            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(stops: stops),
                startPoint: CGPoint(x: origin, y: middle),
                endPoint: CGPoint(x: origin + direction * length, y: middle)
            )
            let width = (layer == .bass ? Self.bassLineWidth : Self.lineWidth) * lineScale
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
