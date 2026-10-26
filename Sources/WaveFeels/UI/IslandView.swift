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
/// Кадры идут от `TimelineView(.animation)` с частотой экрана острова
/// (`RenderPacing.timelineInterval`, `AppModel.refreshPeriod`), на паузе, пока остров скрыт
/// (после скрытия еще `IslandTransition.overlap`, чтобы волны двигались, пока остров гаснет);
/// в простое (`AppModel.renderIdle`: волны ровные, свечения и «вздоха» нет) 12 в секунду
/// (`RenderIdleDetector.idleInterval`);
/// в режиме энергосбережения не чаще 30 в секунду, без эха и без свечения линий
/// (`WaveAppearance.lightened()`). На каждом кадре модель берет кадр анализа и свечение
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
/// Баннер нового трека (`AppModel.bannerVisible`): свернутый остров перетекает в укороченную
/// панель 400×84 pt (`IslandGeometry.banner`) с обложкой и текстом (`TrackBannerView`, тоже вне
/// сцены и под маской формы) и волнами справа от выреза; крылья гаснут, «вздоха» нет.
/// Открывается пружиной 0.42 / 0.82, закрывается 0.45 / 1.0. Наведение на баннер раскрывает
/// полную панель (`NotchWindowController`), ее пружина главнее.
///
/// Стиль «Пульс»: у свернутого острова волн нет, остров дышит и светится в такт и с громкостью
/// (`breathing`, `PulseLook`), у выреза и на капсуле одинаково. Вид волн подстраивается под
/// системные «Увеличить контраст» и «Уменьшить прозрачность» (`AppModel.displayOptions`,
/// `WaveAppearance.adapted(to:)`), только для рисования.
///
/// «Уменьшение движения»: нет «вздоха» и никакого свечения, волны вдвое медленнее, содержимое
/// панели появляется и уходит одной прозрачностью. Баннер не перетекает из свернутого острова:
/// тела, волны и содержимое меняются одной прозрачностью за 0.2 с, а уходящее тело гаснет
/// следом за проявившимся входящим (`IslandTransition.reducedBodyFade`).
struct IslandView: View {
    static let expandAnimation = Animation.spring(response: 0.42, dampingFraction: 0.78)
    static let collapseAnimation = Animation.spring(response: 0.35, dampingFraction: 0.9)
    static let bannerOpenAnimation = Animation.spring(response: 0.42, dampingFraction: 0.82)
    static let bannerCloseAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0)
    static let bannerReducedDuration = 0.2
    static let bannerReducedAnimation = Animation.easeInOut(duration: bannerReducedDuration)

    /// «Уменьшение движения»: анимация прозрачности тела острова или баннера
    /// (`IslandTransition.reducedBodyFade`); уходящее тело гаснет после того, как проявилось
    /// входящее.
    static func reducedBodyAnimation(_ fade: IslandTransition.BodyFade) -> Animation? {
        switch fade {
        case .immediate: return nil
        case .fadeIn: return bannerReducedAnimation
        case .fadeOutDelayed: return bannerReducedAnimation.delay(bannerReducedDuration)
        }
    }

    /// Анимация смены `bannerVisible`.
    static func bannerAnimation(visible: Bool, reduceMotion: Bool) -> Animation {
        if reduceMotion { return bannerReducedAnimation }
        return visible ? bannerOpenAnimation : bannerCloseAnimation
    }
    /// «Вздох»: насколько остров увеличивается на полном ударе.
    static let breathDepth: CGFloat = 0.03

    /// Масштаб «вздоха» и свечение под островом на кадре по стилю. `collapsed`: остров свернут и
    /// без баннера; `canBreathe`: к тому же без «Уменьшения движения». «Пульс»: остров дышит всегда,
    /// когда может, без оглядки на «Вздох на битах», масштабом `1 + PulseLook.breathDepth ×
    /// PulseLook.breath`; у свернутого острова свечение `PulseLook.glow` (удары, мягкий пульс и
    /// громкость), у раскрытой панели и баннера свечение доли, как у других стилей, без ровного
    /// свечения от громкости. Остальные стили как раньше: «вздох» `1 + breathDepth × pulse` только с
    /// `beatPulse`, свечение доли.
    static func breathing(
        look: WaveLook, visuals: IslandVisuals, collapsed: Bool, canBreathe: Bool, beatPulse: Bool
    ) -> (scale: CGFloat, glow: Float) {
        switch look {
        case .pulse:
            let level = visuals.frame.level
            let breath = PulseLook.breath(pulse: visuals.pulse, ambient: visuals.ambient, level: level)
            let glow = collapsed
                ? PulseLook.glow(glow: visuals.glow, ambient: visuals.ambient, level: level)
                : visuals.glow
            return (canBreathe ? 1 + CGFloat(PulseLook.breathDepth) * CGFloat(breath) : 1, glow)
        case .waves, .spectrum, .minimal:
            return (canBreathe && beatPulse ? 1 + breathDepth * CGFloat(visuals.pulse) : 1, visuals.glow)
        }
    }
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
    /// Остров скрыт дольше `IslandTransition.overlap`: гаснуть уже нечему, кадры стоят.
    @State private var hideSettled = true

    var body: some View {
        let state = model.islandState
        let bannerVisible = model.bannerVisible
        let panel = layout.panelFrame
        let geometry = IslandGeometry(layout: layout, wingWidth: layout.wingWidth)
        ZStack(alignment: .topLeading) {
            Group {
                if let clock {
                    let time = clock()
                    scene(state: state, geometry: geometry, now: time, timelineTime: time)
                } else {
                    TimelineView(.animation(
                        minimumInterval: model.renderIdle
                            ? RenderIdleDetector.idleInterval
                            : RenderPacing.timelineInterval(refreshPeriod: model.refreshPeriod, lowPower: model.lowPower),
                        paused: state == .hidden && hideSettled
                    )) { context in
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
            bannerContent(state: state, geometry: geometry, visible: bannerVisible)
            // При уменьшении движения тело острова растет не из баннера: маска должна совпадать.
            panelContent(state: state, geometry: geometry, banner: bannerVisible && !reduceMotion)
        }
        .frame(width: panel.width, height: panel.height, alignment: .topLeading)
        .ignoresSafeArea()
        // Окно уже встало на новую рамку: сдвиг координат внутри нее не анимируется, иначе
        // остров съехал бы и вернулся. Ближний к виду модификатор главнее внешних: когда
        // наведение превращает баннер в панель, работает пружина раскрытия.
        .animation(nil, value: panel)
        .animation(state == .expanded ? Self.expandAnimation : Self.collapseAnimation, value: state)
        .animation(Self.bannerAnimation(visible: bannerVisible, reduceMotion: reduceMotion), value: bannerVisible)
        .animation(Self.collapseAnimation, value: layout.wingWidth)
        .task(id: state) {
            // Скрытие (полноэкранный режим, пауза при громкой музыке): кадры идут, пока остров
            // гаснет, и встают через `overlap`.
            guard state == .hidden else {
                hideSettled = false
                return
            }
            guard !hideSettled else { return }
            do {
                try await Task.sleep(for: .seconds(IslandTransition.overlap))
                hideSettled = true
            } catch {
                // Остров снова показан.
            }
        }
    }

    // MARK: - Баннер

    /// `TrackBannerView` на видимом теле баннера, под маской формы острова. Без «Уменьшения
    /// движения» маска перетекает вместе с формой, с ним стоит формой баннера.
    private func bannerContent(state: IslandState, geometry: IslandGeometry, visible: Bool) -> some View {
        let rect = geometry.bannerBody
        return ZStack(alignment: .topLeading) {
            TrackBannerView(content: visible ? currentBanner() : nil, layout: geometry.bannerLayout)
                .frame(width: rect.width, height: rect.height, alignment: .topLeading)
                .offset(x: rect.minX, y: rect.minY)
        }
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        .mask(alignment: .topLeading) {
            IslandOutline(geometry: geometry, state: state, banner: reduceMotion || visible)
        }
        .allowsHitTesting(false)
    }

    /// Что показывает баннер сейчас: трек `AppModel.bannerTrack` (без него ключ из фазы),
    /// обложка или значок (`AppModel.bannerIcon()`), виден ли текст.
    private func currentBanner() -> TrackBannerContent? {
        guard case .showing(let key, let textVisible) = model.bannerPhase else { return nil }
        let track = model.bannerTrack
        let artist = track?.artist ?? (key.artist.isEmpty ? nil : key.artist)
        let artwork = model.bannerArtwork
        return TrackBannerContent(
            title: track?.title ?? key.title,
            artist: artist.flatMap { $0.isEmpty ? nil : $0 },
            artwork: artwork,
            icon: artwork == nil ? model.bannerIcon() : nil,
            textVisible: textVisible
        )
    }

    // MARK: - Содержимое панели

    /// `ExpandedPanelView` в `IslandGeometry.panelContent`, только у раскрытого острова,
    /// под маской формы острова в ее текущем (анимированном) положении. Маска знает о баннере:
    /// когда наведение превращает баннер в панель, она растет из прямоугольника баннера, а не
    /// из свернутого острова.
    private func panelContent(state: IslandState, geometry: IslandGeometry, banner: Bool) -> some View {
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
            IslandOutline(geometry: geometry, state: state, banner: banner)
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
        // Вид под системные «Увеличить контраст» и «Уменьшить прозрачность» (только для рисования,
        // в настройки не пишется), в режиме энергосбережения еще и облегчен: без эха и без свечения
        // линий. Настройки остаются как есть.
        let adapted = model.settings.appearance.adapted(to: model.displayOptions)
        let appearance = model.lowPower ? adapted.lightened() : adapted
        let bannerVisible = model.bannerVisible
        // Баннер открылся или закрылся меньше `overlap` назад: живы и крылья, и волны баннера.
        // Волны баннера только у свернутого острова: у раскрытой панели они не видны.
        let bannerMoving = now - model.bannerVisibleChangedAt < IslandTransition.overlap
        // У выреза и у капсулы на внешнем экране одинаково.
        let collapsedQuiet = state == .collapsed && !bannerVisible
        let breath = Self.breathing(
            look: appearance.look, visuals: visuals, collapsed: collapsedQuiet,
            canBreathe: collapsedQuiet && !reduceMotion, beatPulse: model.settings.beatPulse
        )
        let scale = breath.scale
        let anchor = geometry.anchor
        let layers = IslandTransition.waveLayers(state: state, sinceStateChange: now - model.islandStateChangedAt)
        // На паузе волны панели сначала затихают в линию, затем полоса гаснет.
        let paused = model.nowPlayingAvailable && model.lastTrack?.isPlaying == false

        return ZStack(alignment: .topLeading) {
            if BeatGlowView.isVisible(
                glow: BeatGlowView.brightness(glow: breath.glow, ambient: visuals.ambient), intensity: glow
            ) {
                BeatGlowView(
                    geometry: geometry, state: state, scale: scale, glow: breath.glow, ambient: visuals.ambient,
                    intensity: glow, radius: appearance.glowRadius,
                    color: visuals.palette.first ?? PaletteExtractor.fallback[0], banner: bannerVisible
                )
            }
            ZStack(alignment: .topLeading) {
                if reduceMotion {
                    // Без перетекания: тело баннера сменяет свернутое прозрачностью, входящее
                    // проявляется, пока уходящее еще непрозрачно, и остров нигде не просвечивает.
                    // Тело баннера только у свернутого острова: у раскрытой панели оно было бы
                    // второй такой же панелью. Форма тела острова идет своей пружиной, а не
                    // анимацией прозрачности.
                    let collapsed = state == .collapsed
                    let bannerShown = collapsed && bannerVisible
                    IslandBodyView(geometry: geometry, state: state)
                        .equatable()
                        .animation(state == .expanded ? Self.expandAnimation : Self.collapseAnimation, value: state)
                        .opacity(bannerShown ? 0 : 1)
                        .animation(
                            Self.reducedBodyAnimation(IslandTransition.reducedBodyFade(incoming: !bannerShown, collapsed: collapsed)),
                            value: bannerShown
                        )
                    if collapsed && (bannerVisible || bannerMoving) {
                        IslandBodyView(geometry: geometry, state: state, banner: true)
                            .equatable()
                            .opacity(bannerVisible ? 1 : 0)
                            .animation(
                                Self.reducedBodyAnimation(IslandTransition.reducedBodyFade(incoming: bannerVisible, collapsed: true)),
                                value: bannerVisible
                            )
                    }
                } else {
                    IslandBodyView(geometry: geometry, state: state, banner: bannerVisible)
                        .equatable()
                }
                IslandWavesView(
                    visuals: visuals, geometry: geometry, state: state, layers: layers, glow: glow,
                    appearance: appearance, paused: paused, banner: bannerVisible,
                    bannerLayer: bannerVisible || (bannerMoving && state == .collapsed), wingLayer: !bannerVisible || bannerMoving,
                    reduceMotion: reduceMotion
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
    /// Рамка формы баннера нового трека (`NotchLayout.bannerFrame`, у выреза с плечами).
    let banner: CGRect
    /// Видимое тело баннера 400 pt (`NotchLayout.bannerIsland`): от него отсчитывается
    /// `bannerLayout`.
    let bannerBody: CGRect
    /// Обложка, текст и волны баннера в координатах `bannerBody`.
    let bannerLayout: BannerLayout

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
        banner = local(layout.bannerFrame)
        bannerBody = local(layout.bannerIsland)
        bannerLayout = layout.bannerContent
    }

    /// Остров в состоянии `state`; скрытый совпадает с вырезом. `banner`: свернутый остров
    /// показывает баннер нового трека.
    func island(for state: IslandState, banner: Bool = false) -> CGRect {
        switch state {
        case .hidden: notch
        case .collapsed: banner ? self.banner : collapsed
        case .expanded: expanded
        }
    }

    /// Волны баннера справа от выреза.
    var bannerWaves: CGRect {
        let waves = bannerLayout.waves
        return CGRect(
            x: bannerBody.minX + waves.minX, y: bannerBody.minY + waves.minY, width: waves.width, height: waves.height
        )
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
