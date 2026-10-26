import SwiftUI
import WaveCore

// Слои сцены острова. Все они получают готовые значения (геометрию, состояние, кадр
// `IslandVisuals`, яркость свечения) и не читают `AppModel`: кадр у модели берет только
// `IslandView`, поэтому эти же виды может рисовать и предпросмотр, не трогая живой остров.

/// Форма острова в состоянии `state` на своем месте в координатах панели: у выреза
/// `IslandShape`, у капсулы скругленный прямоугольник. Заливка из `foregroundStyle`. По ней
/// рисуется тело острова и обрезаются волны и содержимое панели. `banner`: свернутый остров
/// показывает баннер нового трека (`IslandGeometry.banner`, нижние углы 22 pt, у выреза плечи
/// 9 pt, у капсулы плеч нет).
struct IslandOutline: View {
    static let collapsedRadius: CGFloat = 10
    static let expandedRadius: CGFloat = 28

    let geometry: IslandGeometry
    let state: IslandState
    var banner = false

    /// Радиус капсулы: свернутая скруглена на половину высоты.
    static func pillRadius(state: IslandState, rect: CGRect) -> CGFloat {
        state == .expanded ? expandedRadius : rect.height / 2
    }

    var body: some View {
        let form = banner && state == .collapsed
        let rect = geometry.island(for: state, banner: banner)
        Group {
            if geometry.hasNotch {
                IslandShape(
                    bottomRadius: form
                        ? NotchGeometry.bannerBottomRadius
                        : (state == .expanded ? Self.expandedRadius : Self.collapsedRadius),
                    shoulderRadius: form ? NotchGeometry.bannerShoulderRadius : IslandGeometry.shoulder(for: state)
                )
            } else {
                RoundedRectangle(
                    cornerRadius: form ? NotchGeometry.bannerBottomRadius : Self.pillRadius(state: state, rect: rect),
                    style: .continuous
                )
            }
        }
        .frame(width: rect.width, height: rect.height)
        .offset(x: rect.minX, y: rect.minY)
    }
}

/// Черное тело острова: форма, мягкая тень у раскрытой панели и баннера, тонкая обводка
/// свернутой капсулы. От кадров не зависит: пересчитывается только при смене состояния,
/// баннера или геометрии (`==`), а «вздох» снаружи масштабирует его готовым (`scaleEffect`).
struct IslandBodyView: View, Equatable {
    static let expandedShadowOpacity = 0.25
    static let expandedShadowRadius: CGFloat = 16
    static let expandedShadowOffset: CGFloat = 4
    /// Обводка свернутой капсулы.
    static let pillStrokeWidth: CGFloat = 0.5
    static let pillStrokeOpacity = 0.08

    let geometry: IslandGeometry
    let state: IslandState
    /// Свернутый остров показывает баннер нового трека.
    var banner = false

    nonisolated static func == (lhs: IslandBodyView, rhs: IslandBodyView) -> Bool {
        lhs.geometry == rhs.geometry && lhs.state == rhs.state && lhs.banner == rhs.banner
    }

    var body: some View {
        let rect = geometry.island(for: state)
        let panelLike = state == .expanded || (banner && state == .collapsed)
        ZStack(alignment: .topLeading) {
            IslandOutline(geometry: geometry, state: state, banner: banner)
                .foregroundStyle(Color.black)
                .shadow(
                    color: Color.black.opacity(panelLike ? Self.expandedShadowOpacity : 0),
                    radius: Self.expandedShadowRadius, x: 0, y: Self.expandedShadowOffset
                )
            if !geometry.hasNotch {
                RoundedRectangle(cornerRadius: IslandOutline.pillRadius(state: state, rect: rect), style: .continuous)
                    .strokeBorder(Color.white.opacity(Self.pillStrokeOpacity), lineWidth: Self.pillStrokeWidth)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .opacity(panelLike ? 0 : 1)
            }
        }
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
    }
}

/// Волны острова на один кадр, обрезанные его формой.
///
/// Волны свернутого острова (крылья или линия капсулы) и полоса раскрытой панели всегда стоят
/// в дереве и сменяют друг друга прозрачностью под пружиной раскрытия: уходящий слой продолжает
/// двигаться, пока гаснет. Точки и холсты слоя есть, только пока `layers` (`IslandTransition`)
/// говорит, что он жив. У неживого слоя остается пустая оболочка (рамка, маска формой острова,
/// текстура): по ней маска продолжает идти за формой, и входящий слой открывается ее краем, как
/// если бы стоял целиком. Холсты входят в живой слой без перехода, их проявляет прозрачность
/// оболочки под той же пружиной. Каждый прямоугольник волн рисуется своей
/// текстурой (`drawingGroup`) с полем `glowMargin` × «Радиус свечения» (не меньше 1×) под
/// размытую копию линий; линии складываются в ней `.plusLighter` и ложатся на черное тело.
/// Число линий, заливка, толщина, размах и радиус свечения линий берутся из `appearance`; без
/// прохода свечения (`WaveAppearance.glowPass`, режим энергосбережения) размытой копии линий нет.
///
/// На паузе полоса панели сначала затихает в линию (около секунды), затем гаснет до 15 %.
///
/// Баннер нового трека: волны крыльев (линия капсулы) гаснут, справа от выреза идут волны
/// баннера (`IslandGeometry.bannerWaves`) с профилем крыла, не зеркально; точки у них общие
/// с крыльями. Оба слоя считаются, пока баннер открывается или закрывается (`wingLayer`,
/// `bannerLayer`). Без «Уменьшения движения» все слои обрезаются текущей формой (она перетекает
/// из свернутой в баннер), с ним у каждого слоя своя форма и меняется только прозрачность.
///
/// Стиль «Пульс» у свернутого острова волн не рисует (`neededSets`): слоев крыльев, линии капсулы
/// и баннера нет вовсе, ни оболочки, ни текстуры. Остров дышит и светится снаружи (`IslandView`).
struct IslandWavesView: View {
    /// Свечение линий: размытая копия основных волн, радиус размытия × «Радиус свечения».
    /// Выше 1× яркость умножается на корень из радиуса: иначе широкий ореол тусклее, чем при 1×.
    static let glowBlur: CGFloat = 2
    static let glowOpacity = 0.25
    /// Поле текстуры вокруг прямоугольника волн: под размытую копию линий и точку удара.
    static let glowMargin: CGFloat = 6
    /// Точка удара у края выреза, где сходятся волны крыла.
    static let accentSize: CGFloat = 3
    static let accentOpacity = 0.6
    /// Волны раскрытой панели на паузе: гаснут до этой яркости, когда затихли.
    static let pausedWaveOpacity = 0.15
    static let pausedWaveDelay = 1.0
    static let pausedWaveFade = 0.5

    let visuals: IslandVisuals
    let geometry: IslandGeometry
    let state: IslandState
    /// Какие слои считать на этом кадре (`IslandTransition.waveLayers`).
    let layers: (wing: Bool, panel: Bool)
    /// Яркость свечения из настроек, 0 при «Уменьшении движения».
    let glow: Double
    /// Вид волн из настроек.
    let appearance: WaveAppearance
    /// Источник на паузе: полоса панели гаснет.
    let paused: Bool
    /// Свернутый остров показывает баннер нового трека.
    var banner = false
    /// Волны баннера нужны на этом кадре: баннер открыт, открывается или закрывается.
    var bannerLayer = false
    /// Волны крыльев (линия капсулы) нужны на этом кадре: нет, пока баннер давно открыт.
    var wingLayer = true
    /// «Уменьшение движения»: каждый слой обрезается своей формой, без перетекания.
    var reduceMotion = false

    /// Какие наборы волн строить на кадре. `wings`: волны свернутого острова нужны (`layers.wing`
    /// и `wingLayer`), `panelLayer`: слой раскрытой панели жив (`layers.panel`), `bannerLayer`:
    /// нужны волны баннера, `collapsedStyle`: раскладка свернутого острова (`.wing` у выреза,
    /// `.panel` у капсулы, тогда свернутая линия берет набор панели). `collapsed`: есть ли вообще
    /// слои волн свернутого острова и баннера; единственное место, где это решается. «Пульс» волн
    /// у свернутого острова не рисует (ни крыльев, ни линии капсулы, ни волн баннера): этих слоев
    /// нет, набора крыла нет, набор панели только у раскрытой панели.
    static func neededSets(
        look: WaveLook, wings: Bool, panelLayer: Bool, bannerLayer: Bool, collapsedStyle: WaveStyle
    ) -> (wing: Bool, panel: Bool, collapsed: Bool) {
        switch look {
        case .pulse:
            return (wing: false, panel: panelLayer, collapsed: false)
        case .waves, .spectrum, .minimal:
            return (
                wing: (wings && collapsedStyle == .wing) || bannerLayer,
                panel: panelLayer || (wings && collapsedStyle == .panel),
                collapsed: true
            )
        }
    }

    /// Высота точки удара у выреза в прямоугольнике крыла `rect`: там, где начинается линия.
    /// От середины (`rect.midY`, как раньше) или от нижней базовой линии холста
    /// (`WaveDrawing`: высота минус поле крыла `wingEdgeMargin`).
    static func accentY(in rect: CGRect, baseline: WaveLookGeometry.Baseline) -> CGFloat {
        switch baseline {
        case .center: rect.midY
        case .bottom: rect.maxY - WaveDrawing.wingEdgeMargin
        }
    }

    var body: some View {
        // У капсулы свернутая линия и полоса панели одного стиля: точки общие.
        let collapsedStyle: WaveStyle = geometry.hasNotch ? .wing : .panel
        let wings = layers.wing && wingLayer
        // `sets.collapsed`: слоев крыльев, капсулы и баннера может не быть вовсе («Пульс»).
        let sets = Self.neededSets(
            look: appearance.look, wings: wings, panelLayer: layers.panel, bannerLayer: bannerLayer,
            collapsedStyle: collapsedStyle
        )
        // nil: слой сейчас не нужен, холстов в нем нет.
        let panelSet: WaveSet? = sets.panel ? makeSet(.panel) : nil
        let wingSet: WaveSet? = sets.wing ? makeSet(.wing) : nil
        let collapsedSet: WaveSet? = wings && sets.collapsed ? (collapsedStyle == .panel ? panelSet : wingSet) : nil
        let shownPanelSet: WaveSet? = layers.panel ? panelSet : nil
        let form = banner && state == .collapsed
        // Форма, которой обрезаются волны крыльев и панели.
        let mask = reduceMotion ? false : form

        ZStack(alignment: .topLeading) {
            if sets.collapsed {
                collapsedWaves(collapsedSet, maskBanner: mask)
                    .opacity(state == .expanded || form ? 0 : 1)
            }
            if bannerLayer && sets.collapsed {
                waveLayer(wingSet, rect: geometry.bannerWaves, mirrored: false, maskBanner: reduceMotion || form)
                    .opacity(form ? 1 : 0)
            }
            waveLayer(shownPanelSet, rect: geometry.panelWaves, mirrored: false, maskBanner: mask)
                .opacity(paused ? Self.pausedWaveOpacity : 1)
                .animation(
                    .easeInOut(duration: Self.pausedWaveFade).delay(paused ? Self.pausedWaveDelay : 0),
                    value: paused
                )
                .opacity(state == .expanded ? 1 : 0)
        }
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
    }

    private func makeSet(_ style: WaveStyle) -> WaveSet {
        WaveSet(
            frame: visuals.frame, palette: visuals.palette, motion: visuals.motion, time: visuals.time, style: style,
            appearance: appearance, flowPhase: visuals.flowPhase
        )
    }

    /// Волны свернутого острова: два крыла с точками удара у выреза или одна линия капсулы. В
    /// крыльях они стоят на своих местах, пока остров раскрывается или прячется, и
    /// открываются или закрываются краем формы.
    @ViewBuilder
    private func collapsedWaves(_ waves: WaveSet?, maskBanner: Bool) -> some View {
        if geometry.hasNotch {
            let baseline = appearance.lookGeometry.baseline
            ZStack(alignment: .topLeading) {
                waveLayer(
                    waves, rect: geometry.leftWing, mirrored: true, maskBanner: maskBanner,
                    accent: CGPoint(
                        x: geometry.notch.minX - Self.accentSize / 2, y: Self.accentY(in: geometry.leftWing, baseline: baseline)
                    )
                )
                waveLayer(
                    waves, rect: geometry.rightWing, mirrored: false, maskBanner: maskBanner,
                    accent: CGPoint(
                        x: geometry.notch.maxX + Self.accentSize / 2, y: Self.accentY(in: geometry.rightWing, baseline: baseline)
                    )
                )
            }
        } else {
            waveLayer(waves, rect: geometry.pillWaves, mirrored: false, maskBanner: maskBanner)
        }
    }

    /// Волны в `rect` и их свечение (размытая копия толстых линий под ними), обе в режиме
    /// `.plusLighter`, плюс точка удара в `accent` (координаты панели). Все рисуется одной
    /// текстурой размером `rect` плюс поле под свечение с каждой стороны и обрезается формой
    /// острова (`maskBanner`: формой баннера, пока остров свернут). Без `waves` слой пустой:
    /// ни холстов, ни размытия, ни точки удара, только оболочка с маской.
    private func waveLayer(
        _ waves: WaveSet?, rect: CGRect, mirrored: Bool, maskBanner: Bool, accent: CGPoint? = nil
    ) -> some View {
        let radius = CGFloat(appearance.glowRadius)
        let margin = Self.glowMargin * max(radius, 1)
        let origin = CGPoint(x: rect.minX - margin, y: rect.minY - margin)
        return ZStack(alignment: .topLeading) {
            ZStack {
                // Холсты появляются и уходят сразу (`.identity`): в живом слое их проявляет
                // прозрачность оболочки, переход по умолчанию добавил бы к ней вторую.
                if let waves {
                    if glow > 0 && appearance.glowPass {
                        WaveCanvas(waves: waves, mirrored: mirrored, pass: .glow)
                            .blur(radius: Self.glowBlur * radius)
                            .opacity(min(Self.glowOpacity * glow * Double(max(radius, 1)).squareRoot(), 1))
                            .blendMode(.plusLighter)
                            .transition(.identity)
                    }
                    WaveCanvas(waves: waves, mirrored: mirrored)
                        .blendMode(.plusLighter)
                        .transition(.identity)
                }
            }
            .frame(width: rect.width, height: rect.height)
            .offset(x: margin, y: margin)
            if let accent, glow > 0, waves != nil {
                accentDot(at: CGPoint(x: accent.x - origin.x, y: accent.y - origin.y))
            }
        }
        .frame(width: rect.width + 2 * margin, height: rect.height + 2 * margin, alignment: .topLeading)
        .mask(alignment: .topLeading) {
            IslandOutline(geometry: geometry, state: state, banner: maskBanner)
                .offset(x: -origin.x, y: -origin.y)
        }
        .drawingGroup()
        .offset(x: origin.x, y: origin.y)
    }

    /// Мягкая точка у края выреза, где сходятся волны крыла, вспыхивает со свечением доли. Цвет
    /// как у свечения под островом, с переливанием (`IslandVisuals.glowSourceColor`).
    @ViewBuilder
    private func accentDot(at center: CGPoint) -> some View {
        let opacity = Self.accentOpacity * Double(visuals.glow)
        if opacity > 0.005 {
            let color = WavePaint.glowColor(visuals.glowSourceColor)
            Circle()
                .fill(Color(palette: color))
                .frame(width: Self.accentSize, height: Self.accentSize)
                .blur(radius: 1)
                .opacity(opacity)
                .blendMode(.plusLighter)
                .offset(x: center.x - Self.accentSize / 2, y: center.y - Self.accentSize / 2)
                .transition(.identity)
        }
    }
}

/// Мягкое свечение цвета `color`, поднятого до светлого и насыщенного, под нижним краем
/// острова. Яркость по большему из свечения доли `glow` и мягкого пульса `ambient` (`brightness`)
/// с пиком 0.45 на темной строке меню и 0.25 на светлой при яркости по умолчанию, у раскрытой
/// панели и баннера втрое слабее. Размытие и высота эллипса растут с «Радиусом свечения».
/// Рисуется поверх строки меню само, вне текстур волн; когда его почти не видно (`isVisible` по
/// `brightness`), его не строят.
struct BeatGlowView: View {
    /// Размытие и высота эллипса при радиусе 1×.
    static let blur: CGFloat = 14
    static let widthFraction: CGFloat = 0.7
    static let height: CGFloat = 16
    /// На сколько центр свечения выше нижнего края острова.
    static let lift: CGFloat = 6
    /// Яркость свечения на полном ударе при яркости по умолчанию: на темной и светлой строке меню.
    static let peakDark = 0.45
    static let peakLight = 0.25
    /// У раскрытой панели свечение слабее.
    static let expandedFactor = 0.3
    /// Ниже этого произведения свечения доли и яркости из настроек свечения нет.
    static let threshold = 0.005

    let geometry: IslandGeometry
    let state: IslandState
    /// «Вздох»: нижний край острова опускается вместе с масштабом.
    let scale: CGFloat
    /// Свечение доли 0...1 на кадре.
    let glow: Float
    /// Мягкий пульс на кадре (`IslandVisuals.ambient`), 0 без него.
    var ambient: Float = 0
    /// Яркость свечения из настроек.
    let intensity: Double
    /// «Радиус свечения» из настроек, множитель.
    let radius: Double
    let color: PaletteColor
    /// Свернутый остров показывает баннер нового трека.
    var banner = false

    @Environment(\.colorScheme) private var colorScheme

    static func isVisible(glow: Float, intensity: Double) -> Bool {
        Double(glow) * intensity >= threshold
    }

    /// Яркость эллипса: мягкий пульс лежит под вспышками, видно большее из двух.
    static func brightness(glow: Float, ambient: Float) -> Float {
        max(glow, ambient)
    }

    var body: some View {
        let rect = geometry.island(for: state, banner: banner)
        let anchorY = geometry.notch.minY
        let peak = colorScheme == .dark ? Self.peakDark : Self.peakLight
        let relative = intensity / AppSettings.Default.glowIntensity
        let panelLike = state == .expanded || (banner && state == .collapsed)
        let expanded = panelLike ? Self.expandedFactor : 1
        let opacity = min(Double(Self.brightness(glow: glow, ambient: ambient)) * peak * relative * expanded, 1)
        let width = rect.width * Self.widthFraction
        let height = Self.height * CGFloat(radius)
        let bottom = anchorY + (rect.maxY - anchorY) * scale
        Ellipse()
            .fill(Color(palette: WavePaint.glowColor(color)))
            .frame(width: width, height: height)
            .blur(radius: Self.blur * CGFloat(radius))
            .opacity(opacity)
            .offset(x: rect.midX - width / 2, y: bottom - Self.lift - height / 2)
    }
}
