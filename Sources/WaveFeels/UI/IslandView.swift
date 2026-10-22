import QuartzCore
import SwiftUI
import WaveCore

/// Остров у выреза во весь размер `NotchPanel`. Вне острова все прозрачно, кроме свечения и
/// тени под ним.
///
/// Свернутый остров: черная форма на вырез и крылья, волны только в крыльях, зеркально, x = 0
/// у края выреза; над самим вырезом ничего не рисуется. Раскрытый: черная панель с мягкой
/// тенью и плечами 9 pt (у свернутого 6 pt), волны во всю ширину вдоль нижнего края, над ними
/// `ExpandedPanelView` (обложка, название, прогресс, кнопки). На паузе волны панели, затихнув,
/// гаснут до 15 %.
/// Капсула на экране без выреза (ровно `NotchGeometry.pillSize`, без крыльев): волны идут
/// через нее одной линией от середины, по краю свернутой капсулы тонкая светлая обводка. Скрытый остров сжимается в вырез и становится полностью прозрачным.
///
/// Кадры идут от `TimelineView(.animation)`, на паузе, пока остров скрыт; в режиме
/// энергосбережения не чаще 30 в секунду. На каждом кадре модель берет кадр анализа и свечение
/// доли на момент показа кадра по часам хоста (`CACurrentMediaTime()` плюс два периода
/// отрисовки), сглаживает уровни пружинами и двигает фазы волн, «вздох» и переход палитры
/// (`AppModel.islandVisuals`). Сцена из трех слоев (`IslandScene.swift`): свечение под островом
/// (`BeatGlowView`), черное тело (`IslandBodyView`, на кадрах не пересчитывается) и волны
/// (`IslandWavesView`, каждый прямоугольник волн своей текстурой `drawingGroup`). «Вздох»
/// масштабирует тело и волны вместе. Волны крыльев и панели сменяют друг друга прозрачностью,
/// оба слоя считаются только в переходе (`IslandTransition`). С `clock` остров рисуется один
/// раз на момент `clock()`, без `TimelineView`: так его снимает `ImageRenderer`.
///
/// Содержимое панели живет отдельно от сцены: вне `TimelineView` и текстур волн, поэтому
/// не пересчитывается на каждом кадре, текст остается четким, а кнопки принимают клики (сама
/// сцена клики пропускает). Оно обрезано той же формой острова, что и волны: пока панель
/// раскрывается, содержимое открывается краем формы и проявляется с небольшой задержкой.
///
/// «Уменьшение движения»: нет «вздоха» и никакого свечения, волны вдвое медленнее, содержимое
/// панели появляется и уходит одной прозрачностью.
struct IslandView: View {
    static let expandAnimation = Animation.spring(response: 0.42, dampingFraction: 0.78)
    static let collapseAnimation = Animation.spring(response: 0.35, dampingFraction: 0.9)
    /// «Вздох»: насколько остров увеличивается на полном ударе.
    static let breathDepth: CGFloat = 0.03
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

    var body: some View {
        let state = model.islandState
        let panel = layout.panelFrame
        let geometry = IslandGeometry(layout: layout, wingWidth: CGFloat(model.settings.wingWidth))
        ZStack(alignment: .topLeading) {
            Group {
                if let clock {
                    let time = clock()
                    scene(state: state, geometry: geometry, now: time, timelineTime: time)
                } else {
                    TimelineView(.animation(minimumInterval: model.lowPower ? 1.0 / 30 : nil, paused: state == .hidden)) { context in
                        scene(
                            state: state,
                            geometry: geometry,
                            now: CACurrentMediaTime(),
                            timelineTime: context.date.timeIntervalSinceReferenceDate
                        )
                    }
                }
            }
            .allowsHitTesting(false)
            panelContent(state: state, geometry: geometry)
        }
        .frame(width: panel.width, height: panel.height, alignment: .topLeading)
        .ignoresSafeArea()
        .animation(state == .expanded ? Self.expandAnimation : Self.collapseAnimation, value: state)
        .animation(Self.collapseAnimation, value: model.settings.wingWidth)
    }

    // MARK: - Содержимое панели

    /// `ExpandedPanelView` в `IslandGeometry.panelContent`, только у раскрытого острова,
    /// под маской формы острова в ее текущем (анимированном) положении.
    private func panelContent(state: IslandState, geometry: IslandGeometry) -> some View {
        let content = geometry.panelContent
        return ZStack(alignment: .topLeading) {
            if state == .expanded {
                ExpandedPanelView(
                    model: model, width: content.width, inset: geometry.panelInset,
                    date: clock.map { Date(timeIntervalSinceReferenceDate: $0()) }
                )
                    .frame(width: content.width, height: content.height)
                    .offset(x: content.minX, y: content.minY)
                    .transition(reduceMotion ? AnyTransition.opacity : Self.panelContentTransition)
            }
        }
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        .mask(alignment: .topLeading) {
            IslandOutline(geometry: geometry, state: state)
        }
    }

    // MARK: - Сцена

    /// `now`: момент кадра по часам хоста (`CACurrentMediaTime()`), по нему берутся кадры анализа
    /// и идет анимация; `timelineTime`: дата `TimelineView`, только для замера отрисовки.
    /// Здесь, и только здесь, сцена читает модель; слои получают готовые значения.
    private func scene(state: IslandState, geometry: IslandGeometry, now: Double, timelineTime: Double) -> some View {
        let visuals = model.islandVisuals(now: now, timelineTime: timelineTime, reduceMotion: reduceMotion)
        // Без «Уменьшения движения» яркость свечения из настроек, с ним свечения нет.
        let glow = reduceMotion ? 0 : model.settings.glowIntensity
        let appearance = model.settings.appearance
        let breathes = state == .collapsed && model.settings.beatPulse && !reduceMotion
        let scale = breathes ? 1 + Self.breathDepth * CGFloat(visuals.pulse) : 1
        let anchor = geometry.anchor
        let layers = IslandTransition.waveLayers(state: state, sinceStateChange: now - model.islandStateChangedAt)
        // На паузе волны панели сначала затихают в линию, затем полоса гаснет.
        let paused = model.nowPlayingAvailable && model.lastTrack?.isPlaying == false

        return ZStack(alignment: .topLeading) {
            if BeatGlowView.isVisible(glow: visuals.glow, intensity: glow) {
                BeatGlowView(
                    geometry: geometry, state: state, scale: scale, glow: visuals.glow, intensity: glow,
                    radius: appearance.glowRadius, color: visuals.palette.first ?? PaletteExtractor.fallback[0]
                )
            }
            ZStack(alignment: .topLeading) {
                IslandBodyView(geometry: geometry, state: state)
                    .equatable()
                IslandWavesView(
                    visuals: visuals, geometry: geometry, state: state, layers: layers, glow: glow,
                    appearance: appearance, paused: paused
                )
            }
            .scaleEffect(scale, anchor: UnitPoint(x: anchor.x / geometry.size.width, y: anchor.y / geometry.size.height))
        }
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        .opacity(state == .hidden ? 0 : 1)
    }
}

/// Прямоугольники острова и волн в координатах панели (начало сверху слева, ось Y вниз).
struct IslandGeometry: Equatable, Sendable {
    /// Вогнутые плечи формы у верхних углов (только у выреза), у свернутого острова.
    static let shoulderRadius: CGFloat = 6
    /// Плечи раскрытой панели шире, форма переходит к ним анимацией вместе с остальным.
    static let expandedShoulderRadius: CGFloat = NotchGeometry.expandedShoulderRadius

    static func shoulder(for state: IslandState) -> CGFloat {
        state == .expanded ? expandedShoulderRadius : shoulderRadius
    }
    /// Отступ волн крыла от внешнего края тела острова, сверх плеча.
    static let wingOuterInset: CGFloat = 4
    /// Содержимое и волны раскрытой панели отстоят от видимого края тела на столько.
    static let panelVisibleInset: CGFloat = 16
    /// От низа волн до низа панели: у выреза и у капсулы.
    static let panelWaveBottomInset: CGFloat = 8
    static let pillWaveBottomInset: CGFloat = 16
    static let panelWaveHeight: CGFloat = 36
    /// Высота полосы содержимого панели: обложка.
    static let panelContentHeight: CGFloat = 72
    /// Отступ волн капсулы от ее скругленных концов.
    static let pillWaveInset: CGFloat = 14

    let size: CGSize
    let hasNotch: Bool
    let notch: CGRect
    let collapsed: CGRect
    let expanded: CGRect
    /// От верха раскрытого острова до содержимого (`NotchLayout.expandedContentTop`).
    let contentTop: CGFloat

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
        contentTop = layout.expandedContentTop
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

    /// От края рамки раскрытой панели до линии содержимого: плечо (у выреза) и 16 pt.
    var panelInset: CGFloat {
        (hasNotch ? Self.expandedShoulderRadius : 0) + Self.panelVisibleInset
    }

    var panelWaves: CGRect {
        let bottom = hasNotch ? Self.panelWaveBottomInset : Self.pillWaveBottomInset
        return CGRect(
            x: expanded.minX + panelInset,
            y: expanded.maxY - bottom - Self.panelWaveHeight,
            width: max(expanded.width - 2 * panelInset, 0),
            height: Self.panelWaveHeight
        )
    }

    /// Полоса содержимого раскрытой панели: во всю ширину рамки, высотой с обложку, ниже
    /// выреза на `NotchGeometry.notchClearance` (у капсулы на 16 pt от верха).
    var panelContent: CGRect {
        CGRect(x: expanded.minX, y: expanded.minY + contentTop, width: expanded.width, height: Self.panelContentHeight)
    }

    var pillWaves: CGRect {
        collapsed.insetBy(dx: min(Self.pillWaveInset, collapsed.width / 2), dy: 0)
    }
}
