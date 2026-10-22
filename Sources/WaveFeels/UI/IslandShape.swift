import SwiftUI

/// Остров у выреза. Верхний край прямой и лежит на краю экрана, у верхних углов вогнутые
/// «плечи» радиуса `shoulderRadius`, как у самого выреза, нижние углы скруглены радиусом
/// `bottomRadius`.
///
/// Плечи лежат внутри прямоугольника: тело острова уже его на `shoulderRadius` с каждой
/// стороны, а сверху плечи расходятся до краев. Так раскрытый остров шириной во всю панель
/// не обрезается ее краями. Нижний угол начинается на `cornerExtent * bottomRadius` от угла,
/// опорные точки кривой стоят ближе к углу, чем у дуги окружности: кривизна нарастает плавно,
/// без излома на стыке с прямой, как у скруглений `.continuous`.
struct IslandShape: Shape {
    nonisolated static let cornerExtent: CGFloat = 1.3
    /// Доля длины угла, на которую опорная точка кривой отстоит от его начала.
    nonisolated static let cornerHandle: CGFloat = 0.62

    var bottomRadius: CGFloat
    var shoulderRadius: CGFloat

    nonisolated var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, shoulderRadius) }
        set {
            bottomRadius = newValue.first
            shoulderRadius = newValue.second
        }
    }

    nonisolated func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 0, rect.height > 0 else { return path }

        let shoulder = min(max(shoulderRadius, 0), rect.width / 4, rect.height / 2)
        let left = rect.minX + shoulder
        let right = rect.maxX - shoulder
        let corner = min(max(bottomRadius, 0) * Self.cornerExtent, (right - left) / 2, rect.height - shoulder)
        let handle = corner * (1 - Self.cornerHandle)
        let top = rect.minY
        let bottom = rect.maxY

        path.move(to: CGPoint(x: rect.minX, y: top))
        path.addLine(to: CGPoint(x: rect.maxX, y: top))
        path.addQuadCurve(to: CGPoint(x: right, y: top + shoulder), control: CGPoint(x: right, y: top))
        path.addLine(to: CGPoint(x: right, y: bottom - corner))
        path.addCurve(
            to: CGPoint(x: right - corner, y: bottom),
            control1: CGPoint(x: right, y: bottom - handle),
            control2: CGPoint(x: right - handle, y: bottom)
        )
        path.addLine(to: CGPoint(x: left + corner, y: bottom))
        path.addCurve(
            to: CGPoint(x: left, y: bottom - corner),
            control1: CGPoint(x: left + handle, y: bottom),
            control2: CGPoint(x: left, y: bottom - handle)
        )
        path.addLine(to: CGPoint(x: left, y: top + shoulder))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: top), control: CGPoint(x: left, y: top))
        path.closeSubpath()
        return path
    }
}
