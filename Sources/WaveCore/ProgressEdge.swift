import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Полоса прогресса по нижней кромке свернутого острова: тонкая линия, заполненная на долю
/// прошедшего трека (`PlaybackPosition.fraction`). Координаты с осью Y вниз, как у
/// `IslandGeometry` в приложении. Доля отсчитывается по всей ширине полосы, в том числе под
/// аппаратным вырезом, где пикселей нет и середины полосы не видно.
public enum ProgressEdge {
    /// Толщина полосы, pt.
    public static let height: CGFloat = 1.5
    /// От низа полосы до низа острова, pt.
    public static let bottomInset: CGFloat = 1
    /// Непрозрачность цвета полосы.
    public static let opacity = 0.55
    /// Шаг заполненной ширины, pt: полпикселя Retina. На трехминутном треке ширина меняется
    /// несколько раз в секунду, и вид полосы перерисовывается только тогда.
    public static let step: CGFloat = 0.5

    /// Полоса рисуется только у свернутого острова без баннера и при включенной функции.
    public static func isShown(enabled: Bool, state: IslandState, banner: Bool) -> Bool {
        enabled && state == .collapsed && !banner
    }

    /// Полоса во всю длину в острове `island`: по краям отступ `sideInset` (скругление низа),
    /// низ на `bottomInset` выше низа острова. Отступ шире половины острова дает полосу нулевой
    /// ширины посередине; отрицательный и не конечный отступ считается нулем.
    public static func track(island: CGRect, sideInset: CGFloat) -> CGRect {
        let inset = sideInset.isFinite ? min(max(sideInset, 0), island.width / 2) : 0
        return CGRect(
            x: island.minX + inset, y: island.maxY - bottomInset - height,
            width: max(island.width - 2 * inset, 0), height: height
        )
    }

    /// Заполненная ширина полосы шириной `trackWidth` на доле `fraction`: вниз до `step`, полная
    /// доля дает всю полосу. Не конечная доля и пустая полоса дают 0.
    public static func filledWidth(fraction: Double, trackWidth: CGFloat) -> CGFloat {
        guard fraction.isFinite, trackWidth.isFinite, trackWidth > 0, fraction > 0 else { return 0 }
        guard fraction < 1 else { return trackWidth }
        let raw = trackWidth * CGFloat(fraction)
        return min((raw / step).rounded(.down) * step, trackWidth)
    }
}
