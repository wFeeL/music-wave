import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Полоса прогресса по нижней кромке свернутого острова: тонкая линия, заполненная на долю
/// прошедшего трека (`PlaybackPosition.fraction`). Координаты с осью Y вниз, как у
/// `IslandGeometry` в приложении. Под аппаратным вырезом пикселей нет, поэтому у выреза доля
/// отсчитывается только по видимым кускам полосы в крыльях (`visibleSegments`): сначала
/// заполняется левое крыло, затем правое (`filledWidths`). У капсулы кусок один, вся полоса.
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
    /// Короче этой видимой длины полосы нет (крыльев нет или они уже скруглений), pt.
    public static let minVisibleLength: CGFloat = 2
    /// Ступеней на канал цвета полосы (`quantized`): 8 бит, как на экране.
    public static let colorLevels: Float = 255

    /// Цвет полосы `color`, округленный до `colorLevels` ступеней на канал (значения вне 0...1
    /// прижимаются к краю, не конечные дают 0). С переливанием цвет плывет на каждом кадре на доли
    /// ступени; округленный меняется, только когда сдвиг доходит до ступени, поэтому вид полосы
    /// (`==`) пересчитывается реже, а на экране отличие не больше полуступени.
    public static func quantized(_ color: RGBColor) -> RGBColor {
        func level(_ value: Float) -> Float {
            guard value.isFinite else { return 0 }
            return (min(max(value, 0), 1) * colorLevels).rounded() / colorLevels
        }
        return RGBColor(r: level(color.r), g: level(color.g), b: level(color.b))
    }

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

    /// Видимые куски полосы `track`. У выреза `notch` (в тех же координатах): слева от него
    /// и справа от него, обрезанные полосой, пустые выпадают. Без выреза (`nil`, капсула) вся
    /// полоса одним куском.
    public static func visibleSegments(track: CGRect, notch: CGRect?) -> [CGRect] {
        guard let notch else { return track.width > 0 ? [track] : [] }
        // Ширины считаются до `CGRect`: у него `width` всегда неотрицательна.
        let leftWidth = min(notch.minX, track.maxX) - track.minX
        let rightStart = max(notch.maxX, track.minX)
        let rightWidth = track.maxX - rightStart
        var segments: [CGRect] = []
        if leftWidth > 0 {
            segments.append(CGRect(x: track.minX, y: track.minY, width: leftWidth, height: track.height))
        }
        if rightWidth > 0 {
            segments.append(CGRect(x: rightStart, y: track.minY, width: rightWidth, height: track.height))
        }
        return segments
    }

    /// Заполненная ширина каждого куска `segments` на доле `fraction`: доля берется от их общей
    /// длины (`filledWidth`, шаг `step`) и заполняет куски по порядку, слева направо. `nil`, если
    /// видимая длина короче `minVisibleLength`: тогда полосы нет.
    public static func filledWidths(fraction: Double, segments: [CGRect]) -> [CGFloat]? {
        let total = segments.reduce(CGFloat(0)) { $0 + $1.width }
        guard total.isFinite, total >= minVisibleLength else { return nil }
        var remaining = filledWidth(fraction: fraction, trackWidth: total)
        return segments.map { segment in
            let width = min(remaining, segment.width)
            remaining -= width
            return width
        }
    }
}
