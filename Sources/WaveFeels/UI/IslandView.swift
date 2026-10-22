import SwiftUI
import WaveCore

/// Остров у выреза во весь размер `NotchPanel`. Вне острова все прозрачно, кроме свечения и
/// тени под ним.
///
/// Свернутый остров: черная форма на вырез и крылья, волны только в крыльях, зеркально, x = 0
/// у края выреза; над самим вырезом ничего не рисуется. Раскрытый: черная панель с мягкой
/// тенью, волны во всю ширину вдоль нижнего края, над ними `ExpandedPanelView` (обложка,
/// название, прогресс, кнопки).
/// Капсула на экране без выреза (ровно `NotchGeometry.pillSize`, без крыльев): волны идут
/// через нее одной линией от середины, по краю свернутой капсулы тонкая светлая обводка. Скрытый остров сжимается в вырез и становится полностью прозрачным.
///
/// Кадры идут от `TimelineView(.animation)`, на паузе, пока остров скрыт; в режиме
/// энергосбережения не чаще 30 в секунду. На каждом кадре модель берет последний кадр анализа
/// и двигает фазы волн, «вздох» и переход палитры (`AppModel.islandVisuals`), точки и цвета волн
/// считаются один раз на кадр (`WaveSet`). Весь остров рисуется одной текстурой
/// (`drawingGroup`). С `clock` остров рисуется один раз на момент `clock()`, без
/// `TimelineView`: так его снимает `ImageRenderer`.
///
/// Содержимое панели живет отдельно от сцены: вне `TimelineView` и `drawingGroup`, поэтому
/// не пересчитывается на каждом кадре, текст остается четким, а кнопки принимают клики (сама
/// сцена клики пропускает). Оно обрезано той же формой острова, что и волны: пока панель
/// раскрывается, содержимое открывается краем формы и проявляется с небольшой задержкой.
///
/// «Уменьшение движения»: нет «вздоха» и никакого свечения, волны вдвое медленнее.
struct IslandView: View {
    static let expandAnimation = Animation.spring(response: 0.42, dampingFraction: 0.78)
    static let collapseAnimation = Animation.spring(response: 0.35, dampingFraction: 0.9)
    static let collapsedRadius: CGFloat = 10
    static let expandedRadius: CGFloat = 28
    /// «Вздох»: насколько остров увеличивается на полном ударе.
    static let breathDepth: CGFloat = 0.03
    /// Свечение линий: размытая копия волн.
    static let glowBlur: CGFloat = 2
    static let glowOpacity = 0.25
    /// Свечение под островом на сильной доле.
    static let beatGlowBlur: CGFloat = 14
    static let beatGlowWidth: CGFloat = 0.7
    static let beatGlowHeight: CGFloat = 16
    /// На сколько центр свечения выше нижнего края острова.
    static let beatGlowLift: CGFloat = 6
    /// Яркость свечения на полном ударе при яркости по умолчанию: на темной и светлой строке меню.
    static let beatGlowDark = 0.45
    static let beatGlowLight = 0.25
    /// У раскрытой панели свечение слабее.
    static let beatGlowExpanded = 0.3
    /// Точка удара у края выреза, где сходятся волны крыла.
    static let accentSize: CGFloat = 3
    static let accentOpacity = 0.6
    /// Тень раскрытой панели.
    static let expandedShadowOpacity = 0.25
    static let expandedShadowRadius: CGFloat = 16
    static let expandedShadowOffset: CGFloat = 4
    /// Обводка свернутой капсулы.
    static let pillStrokeWidth: CGFloat = 0.5
    static let pillStrokeOpacity = 0.08
    /// Содержимое панели: появляется чуть позже формы, слегка вырастая от верха, исчезает быстро.
    static var panelContentTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                .animation(.easeOut(duration: 0.28).delay(0.08)),
            removal: .opacity.animation(.easeIn(duration: 0.12))
        )
    }

    @Bindable var model: AppModel
    let layout: NotchLayout
    /// Время кадра в секундах вместо часов; нужно снимкам.
    var clock: (() -> Double)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let state = model.islandState
        let panel = layout.panelFrame
        ZStack(alignment: .topLeading) {
            Group {
                if let clock {
                    scene(state: state, now: clock())
                } else {
                    TimelineView(.animation(minimumInterval: model.lowPower ? 1.0 / 30 : nil, paused: state == .hidden)) { context in
                        scene(state: state, now: context.date.timeIntervalSinceReferenceDate)
                    }
                }
            }
            .allowsHitTesting(false)
            panelContent(state: state)
        }
        .frame(width: panel.width, height: panel.height, alignment: .topLeading)
        .ignoresSafeArea()
        .animation(state == .expanded ? Self.expandAnimation : Self.collapseAnimation, value: state)
        .animation(Self.collapseAnimation, value: model.settings.wingWidth)
    }

    // MARK: - Содержимое панели

    /// `ExpandedPanelView` в `IslandGeometry.panelContent`, только у раскрытого острова,
    /// под маской формы острова в ее текущем (анимированном) положении.
    private func panelContent(state: IslandState) -> some View {
        let geometry = IslandGeometry(layout: layout, wingWidth: CGFloat(model.settings.wingWidth))
        let rect = geometry.island(for: state)
        let content = geometry.panelContent
        return ZStack(alignment: .topLeading) {
            if state == .expanded {
                ExpandedPanelView(model: model, date: clock.map { Date(timeIntervalSinceReferenceDate: $0()) })
                    .frame(width: content.width, height: content.height)
                    .offset(x: content.minX, y: content.minY)
                    .transition(Self.panelContentTransition)
            }
        }
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        .mask(alignment: .topLeading) {
            Group {
                if layout.hasNotch {
                    IslandShape(
                        bottomRadius: state == .expanded ? Self.expandedRadius : Self.collapsedRadius,
                        shoulderRadius: IslandGeometry.shoulderRadius
                    )
                } else {
                    RoundedRectangle(
                        cornerRadius: state == .expanded ? Self.expandedRadius : rect.height / 2,
                        style: .continuous
                    )
                }
            }
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
        }
    }

    // MARK: - Сцена

    private func scene(state: IslandState, now: Double) -> some View {
        let visuals = model.islandVisuals(now: now, reduceMotion: reduceMotion)
        let geometry = IslandGeometry(layout: layout, wingWidth: CGFloat(model.settings.wingWidth))
        let rect = geometry.island(for: state)
        // Без «Уменьшения движения» яркость свечения из настроек, с ним свечения нет.
        let glow = reduceMotion ? 0 : model.settings.glowIntensity
        let breathes = state == .collapsed && model.settings.beatPulse && !reduceMotion
        let scale = breathes ? 1 + Self.breathDepth * CGFloat(visuals.pulse) : 1
        let anchor = geometry.anchor
        let style: WaveStyle = state == .expanded || !layout.hasNotch ? .panel : .wing
        let waves = WaveSet(
            frame: visuals.frame, palette: visuals.palette, motion: visuals.motion, time: visuals.time, style: style
        )

        return ZStack(alignment: .topLeading) {
            beatGlow(below: rect, state: state, scale: scale, anchorY: geometry.notch.minY, visuals: visuals, intensity: glow)
            Group {
                if layout.hasNotch {
                    island(
                        IslandShape(
                            bottomRadius: state == .expanded ? Self.expandedRadius : Self.collapsedRadius,
                            shoulderRadius: IslandGeometry.shoulderRadius
                        ),
                        rect: rect, state: state, geometry: geometry, waves: waves, visuals: visuals, glow: glow
                    )
                } else {
                    let capsule = RoundedRectangle(
                        cornerRadius: state == .expanded ? Self.expandedRadius : rect.height / 2,
                        style: .continuous
                    )
                    ZStack(alignment: .topLeading) {
                        island(capsule, rect: rect, state: state, geometry: geometry, waves: waves, visuals: visuals, glow: glow)
                        capsule
                            .strokeBorder(Color.white.opacity(Self.pillStrokeOpacity), lineWidth: Self.pillStrokeWidth)
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                            .opacity(state == .expanded ? 0 : 1)
                    }
                }
            }
            .scaleEffect(scale, anchor: UnitPoint(x: anchor.x / geometry.size.width, y: anchor.y / geometry.size.height))
        }
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        .opacity(state == .hidden ? 0 : 1)
        .drawingGroup()
    }

    /// Черная форма острова (с тенью, когда он раскрыт) и волны, обрезанные по ней.
    private func island<S: Shape>(
        _ shape: S, rect: CGRect, state: IslandState, geometry: IslandGeometry,
        waves: WaveSet, visuals: IslandVisuals, glow: Double
    ) -> some View {
        ZStack(alignment: .topLeading) {
            shape
                .fill(Color.black)
                .frame(width: rect.width, height: rect.height)
                .shadow(
                    color: Color.black.opacity(state == .expanded ? Self.expandedShadowOpacity : 0),
                    radius: Self.expandedShadowRadius, x: 0, y: Self.expandedShadowOffset
                )
                .offset(x: rect.minX, y: rect.minY)
            content(state: state, geometry: geometry, waves: waves, visuals: visuals, glow: glow)
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
    private func content(
        state: IslandState, geometry: IslandGeometry, waves: WaveSet, visuals: IslandVisuals, glow: Double
    ) -> some View {
        ZStack(alignment: .topLeading) {
            switch state {
            case .expanded:
                waveLayer(waves, rect: geometry.panelWaves, mirrored: false, glow: glow)
                    .transition(.opacity)
            case .collapsed, .hidden:
                if layout.hasNotch {
                    Group {
                        waveLayer(waves, rect: geometry.leftWing, mirrored: true, glow: glow)
                        waveLayer(waves, rect: geometry.rightWing, mirrored: false, glow: glow)
                        if glow > 0 {
                            accent(at: CGPoint(x: geometry.notch.minX - Self.accentSize / 2, y: geometry.leftWing.midY), visuals: visuals)
                            accent(at: CGPoint(x: geometry.notch.maxX + Self.accentSize / 2, y: geometry.rightWing.midY), visuals: visuals)
                        }
                    }
                    .transition(.opacity)
                } else {
                    waveLayer(waves, rect: geometry.pillWaves, mirrored: false, glow: glow)
                        .transition(.opacity)
                }
            }
        }
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
    }

    /// Волны и их свечение: размытая копия толстых линий под ними, обе складываются со всем,
    /// что под ними, в режиме `.plusLighter`.
    private func waveLayer(_ waves: WaveSet, rect: CGRect, mirrored: Bool, glow: Double) -> some View {
        ZStack {
            if glow > 0 {
                WaveCanvas(waves: waves, mirrored: mirrored, pass: .glow)
                    .blur(radius: Self.glowBlur)
                    .opacity(Self.glowOpacity * glow)
                    .blendMode(.plusLighter)
            }
            WaveCanvas(waves: waves, mirrored: mirrored)
                .blendMode(.plusLighter)
        }
        .frame(width: rect.width, height: rect.height)
        .offset(x: rect.minX, y: rect.minY)
    }

    /// Мягкая точка у края выреза, где сходятся волны крыла, вспыхивает на ударе.
    @ViewBuilder
    private func accent(at center: CGPoint, visuals: IslandVisuals) -> some View {
        let opacity = Self.accentOpacity * Double(visuals.pulse)
        if opacity > 0.005 {
            let color = WavePaint.glowColor(visuals.palette.first ?? PaletteExtractor.fallback[0])
            Circle()
                .fill(Color(palette: color))
                .frame(width: Self.accentSize, height: Self.accentSize)
                .blur(radius: 1)
                .opacity(opacity)
                .blendMode(.plusLighter)
                .offset(x: center.x - Self.accentSize / 2, y: center.y - Self.accentSize / 2)
        }
    }

    /// Мягкое свечение цвета `palette[0]`, поднятого до светлого и насыщенного, под нижним
    /// краем острова. Яркость `pulse` с пиком 0.45 на темной строке меню и 0.25 на светлой при
    /// яркости по умолчанию, у раскрытой панели втрое слабее.
    @ViewBuilder
    private func beatGlow(
        below rect: CGRect, state: IslandState, scale: CGFloat, anchorY: CGFloat, visuals: IslandVisuals, intensity: Double
    ) -> some View {
        let peak = colorScheme == .dark ? Self.beatGlowDark : Self.beatGlowLight
        let relative = intensity / AppSettings.Default.glowIntensity
        let expanded = state == .expanded ? Self.beatGlowExpanded : 1
        let opacity = min(Double(visuals.pulse) * peak * relative * expanded, 1)
        if Double(visuals.pulse) * intensity >= 0.005, opacity > 0 {
            let color = WavePaint.glowColor(visuals.palette.first ?? PaletteExtractor.fallback[0])
            let width = rect.width * Self.beatGlowWidth
            let bottom = anchorY + (rect.maxY - anchorY) * scale
            Ellipse()
                .fill(Color(palette: color))
                .frame(width: width, height: Self.beatGlowHeight)
                .blur(radius: Self.beatGlowBlur)
                .opacity(opacity)
                .offset(x: rect.midX - width / 2, y: bottom - Self.beatGlowLift - Self.beatGlowHeight / 2)
        }
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
    let hasNotch: Bool
    let notch: CGRect
    let collapsed: CGRect
    let expanded: CGRect

    init(layout: NotchLayout, wingWidth: CGFloat) {
        let panel = layout.panelFrame
        func local(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX - panel.minX, y: panel.maxY - rect.maxY, width: rect.width, height: rect.height)
        }
        size = panel.size
        hasNotch = layout.hasNotch
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

    /// Место содержимого раскрытой панели: вся ширина, от низа выреза до верха полосы волн.
    /// Верх панели под вырезом закрыт камерой, там ничего нет; у капсулы выреза нет, и место
    /// начинается от верха панели.
    var panelContent: CGRect {
        let top = hasNotch ? min(max(notch.maxY, expanded.minY), panelWaves.minY) : expanded.minY
        return CGRect(x: expanded.minX, y: top, width: expanded.width, height: max(panelWaves.minY - top, 0))
    }

    var pillWaves: CGRect {
        collapsed.insetBy(dx: min(Self.pillWaveInset, collapsed.width / 2), dy: 0)
    }
}
