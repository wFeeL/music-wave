import SwiftUI
import WaveCore

/// Остров у выреза во весь размер `NotchPanel`. Вне острова все прозрачно, кроме свечения под
/// ним на сильной доле.
///
/// Свернутый остров: черная форма на вырез и крылья, волны только в крыльях, зеркально, x = 0
/// у края выреза; над самим вырезом ничего не рисуется. Раскрытый: черная панель, волны во всю
/// ширину вдоль нижнего края, верх свободен под содержимое панели. Капсула на экране без
/// выреза: волны расходятся из ее середины. Скрытый остров сжимается в вырез и становится
/// полностью прозрачным.
///
/// Кадры идут от `TimelineView(.animation)`, на паузе, пока остров скрыт; в режиме
/// энергосбережения не чаще 30 в секунду. На каждом кадре модель берет последний кадр анализа
/// и двигает фазы волн, «вздох» и переход палитры (`AppModel.islandVisuals`). Весь остров
/// рисуется одной текстурой (`drawingGroup`). С `clock` остров рисуется один раз на момент
/// `clock()`, без `TimelineView` и `drawingGroup`: так его снимает `ImageRenderer`.
struct IslandView: View {
    static let expandAnimation = Animation.spring(response: 0.42, dampingFraction: 0.78)
    static let collapseAnimation = Animation.spring(response: 0.35, dampingFraction: 0.9)
    static let collapsedRadius: CGFloat = 10
    static let expandedRadius: CGFloat = 28
    /// «Вздох»: насколько остров увеличивается на полном ударе.
    static let breathDepth: CGFloat = 0.025
    /// Свечение линий: размытая копия волн.
    static let glowBlur: CGFloat = 3
    static let glowLineScale: CGFloat = 1.75
    /// Свечение под островом на сильной доле.
    static let beatGlowBlur: CGFloat = 18
    static let beatGlowWidth: CGFloat = 0.7
    static let beatGlowHeight: CGFloat = 22
    /// На сколько центр свечения выше нижнего края острова.
    static let beatGlowLift: CGFloat = 6

    @Bindable var model: AppModel
    let layout: NotchLayout
    /// Время кадра в секундах вместо часов; нужно снимкам.
    var clock: (() -> Double)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let state = model.islandState
        let panel = layout.panelFrame
        Group {
            if let clock {
                scene(state: state, now: clock())
            } else {
                TimelineView(.animation(minimumInterval: model.lowPower ? 1.0 / 30 : nil, paused: state == .hidden)) { _ in
                    scene(state: state, now: ProcessInfo.processInfo.systemUptime)
                }
            }
        }
        .frame(width: panel.width, height: panel.height, alignment: .topLeading)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .animation(state == .expanded ? Self.expandAnimation : Self.collapseAnimation, value: state)
        .animation(Self.collapseAnimation, value: model.settings.wingWidth)
    }

    // MARK: - Сцена

    private func scene(state: IslandState, now: Double) -> some View {
        let visuals = model.islandVisuals(now: now, reduceMotion: reduceMotion)
        let geometry = IslandGeometry(layout: layout, wingWidth: CGFloat(model.settings.wingWidth))
        let rect = geometry.island(for: state)
        let glow = model.settings.glowIntensity
        let breathes = state == .collapsed && model.settings.beatPulse && !reduceMotion
        let scale = breathes ? 1 + Self.breathDepth * CGFloat(visuals.pulse) : 1
        let anchor = geometry.anchor

        let content = ZStack(alignment: .topLeading) {
            if !reduceMotion {
                beatGlow(below: rect, scale: scale, anchorY: geometry.notch.minY, visuals: visuals, intensity: glow)
            }
            Group {
                if layout.hasNotch {
                    island(
                        IslandShape(
                            bottomRadius: state == .expanded ? Self.expandedRadius : Self.collapsedRadius,
                            shoulderRadius: IslandGeometry.shoulderRadius
                        ),
                        rect: rect, state: state, geometry: geometry, visuals: visuals, glow: glow
                    )
                } else {
                    island(
                        RoundedRectangle(
                            cornerRadius: state == .expanded ? Self.expandedRadius : rect.height / 2,
                            style: .continuous
                        ),
                        rect: rect, state: state, geometry: geometry, visuals: visuals, glow: glow
                    )
                }
            }
            .scaleEffect(scale, anchor: UnitPoint(x: anchor.x / geometry.size.width, y: anchor.y / geometry.size.height))
        }
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        .opacity(state == .hidden ? 0 : 1)
        return flattened(content)
    }

    /// На экране остров рисуется одной текстурой (`drawingGroup`). Снимок (`clock`) рисует то же
    /// дерево без этого шага: `ImageRenderer` растрирует сцену сам, а сложение `.plusLighter`
    /// внутри черной формы дает тот же результат.
    @ViewBuilder
    private func flattened<Content: View>(_ content: Content) -> some View {
        if clock == nil {
            content.drawingGroup()
        } else {
            content
        }
    }

    /// Черная форма острова и волны, обрезанные по ней.
    private func island<S: Shape>(
        _ shape: S, rect: CGRect, state: IslandState, geometry: IslandGeometry, visuals: IslandVisuals, glow: Double
    ) -> some View {
        ZStack(alignment: .topLeading) {
            shape
                .fill(Color.black)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
            waves(state: state, geometry: geometry, visuals: visuals, glow: glow)
                .mask(alignment: .topLeading) {
                    shape
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                }
        }
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
    }

    /// Волны в координатах панели. В крыльях они стоят на своих местах, пока остров
    /// раскрывается или прячется, и открываются или закрываются краем формы.
    private func waves(state: IslandState, geometry: IslandGeometry, visuals: IslandVisuals, glow: Double) -> some View {
        ZStack(alignment: .topLeading) {
            switch state {
            case .expanded:
                waveLayer(visuals, rect: geometry.panelWaves, mirrored: false, style: .panel, glow: glow)
                    .transition(.opacity)
            case .collapsed, .hidden:
                if layout.hasNotch {
                    Group {
                        waveLayer(visuals, rect: geometry.leftWing, mirrored: true, style: .wing, glow: glow)
                        waveLayer(visuals, rect: geometry.rightWing, mirrored: false, style: .wing, glow: glow)
                    }
                    .transition(.opacity)
                } else {
                    waveLayer(visuals, rect: geometry.pillWaves, mirrored: false, style: .panel, glow: glow)
                        .transition(.opacity)
                }
            }
        }
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
    }

    /// Волны и их свечение: размытая копия с толстыми линиями под ними, обе складываются
    /// со всем, что под ними, в режиме `.plusLighter`.
    private func waveLayer(_ visuals: IslandVisuals, rect: CGRect, mirrored: Bool, style: WaveStyle, glow: Double) -> some View {
        ZStack {
            if glow > 0 {
                canvas(visuals, mirrored: mirrored, style: style, lineScale: Self.glowLineScale)
                    .blur(radius: Self.glowBlur)
                    .opacity(0.5 * glow)
                    .blendMode(.plusLighter)
            }
            canvas(visuals, mirrored: mirrored, style: style, lineScale: 1)
                .blendMode(.plusLighter)
        }
        .frame(width: rect.width, height: rect.height)
        .offset(x: rect.minX, y: rect.minY)
    }

    private func canvas(_ visuals: IslandVisuals, mirrored: Bool, style: WaveStyle, lineScale: CGFloat) -> WaveCanvas {
        WaveCanvas(
            frame: visuals.frame,
            palette: visuals.palette,
            motion: visuals.motion,
            time: visuals.time,
            mirrored: mirrored,
            style: style,
            lineScale: lineScale
        )
    }

    /// Мягкое свечение цвета `palette[0]` под нижним краем острова, яркость `pulse * glow`.
    private func beatGlow(below rect: CGRect, scale: CGFloat, anchorY: CGFloat, visuals: IslandVisuals, intensity: Double) -> some View {
        let color = visuals.palette.first ?? PaletteExtractor.fallback[0]
        let width = rect.width * Self.beatGlowWidth
        let bottom = anchorY + (rect.maxY - anchorY) * scale
        return Ellipse()
            .fill(Color(palette: color))
            .frame(width: width, height: Self.beatGlowHeight)
            .blur(radius: Self.beatGlowBlur)
            .opacity(min(Double(visuals.pulse) * intensity, 1))
            .offset(x: rect.midX - width / 2, y: bottom - Self.beatGlowLift - Self.beatGlowHeight / 2)
    }
}

/// Прямоугольники острова и волн в координатах панели (начало сверху слева, ось Y вниз).
struct IslandGeometry {
    /// Вогнутые плечи формы у верхних углов (только у выреза).
    static let shoulderRadius: CGFloat = 6
    /// Отступ волн крыла от внешнего края тела острова, сверх плеча.
    static let wingOuterInset: CGFloat = 4
    /// Отступы волн раскрытой панели от боковых краев и снизу, их высота.
    static let panelWaveSideInset: CGFloat = 22
    static let panelWaveBottomInset: CGFloat = 12
    static let panelWaveHeight: CGFloat = 36
    /// Отступ волн капсулы от ее скругленных концов.
    static let pillWaveInset: CGFloat = 14

    let size: CGSize
    let notch: CGRect
    let collapsed: CGRect
    let expanded: CGRect

    init(layout: NotchLayout, wingWidth: CGFloat) {
        let panel = layout.panelFrame
        func local(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX - panel.minX, y: panel.maxY - rect.maxY, width: rect.width, height: rect.height)
        }
        size = panel.size
        notch = local(layout.notch)
        collapsed = local(layout.collapsedIsland(wingWidth: wingWidth))
        expanded = local(layout.expandedIsland)
    }

    /// Остров в состоянии `state`; скрытый совпадает с вырезом.
    func island(for state: IslandState) -> CGRect {
        switch state {
        case .hidden: notch
        case .collapsed: collapsed
        case .expanded: expanded
        }
    }

    /// Точка у верхнего края выреза посередине: отсюда остров «вздыхает».
    var anchor: CGPoint {
        CGPoint(x: notch.midX, y: notch.minY)
    }

    /// Ширина волн крыла: от края выреза до тела острова за плечом.
    private var wingWaveWidth: CGFloat {
        max(notch.minX - collapsed.minX - Self.shoulderRadius - Self.wingOuterInset, 0)
    }

    var leftWing: CGRect {
        CGRect(x: notch.minX - wingWaveWidth, y: collapsed.minY, width: wingWaveWidth, height: collapsed.height)
    }

    var rightWing: CGRect {
        CGRect(x: notch.maxX, y: collapsed.minY, width: wingWaveWidth, height: collapsed.height)
    }

    var panelWaves: CGRect {
        CGRect(
            x: expanded.minX + Self.panelWaveSideInset,
            y: expanded.maxY - Self.panelWaveBottomInset - Self.panelWaveHeight,
            width: max(expanded.width - 2 * Self.panelWaveSideInset, 0),
            height: Self.panelWaveHeight
        )
    }

    var pillWaves: CGRect {
        collapsed.insetBy(dx: min(Self.pillWaveInset, collapsed.width / 2), dy: 0)
    }
}
