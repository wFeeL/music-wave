import Observation
import QuartzCore
import SwiftUI
import WaveCore

/// Демо для предпросмотра, одно на запуск: читается один раз, все `PreviewPlayer` берут его
/// отсюда. Снимки кладут сюда готовое (`PreviewPlayer.seed`).
@MainActor
final class PreviewTimelineCache {
    static let shared = PreviewTimelineCache()

    var timeline: DemoTimeline?
    /// Идущее чтение: второй игрок ждет его, а не читает файл заново.
    private var loading: Task<DemoTimeline?, Never>?

    func load(from url: URL?) async -> DemoTimeline? {
        if let timeline { return timeline }
        guard let url else { return nil }
        let task = loading ?? Task { try? await DemoTimeline.load(url) }
        loading = task
        let loaded = await task.value
        if timeline == nil {
            timeline = loaded
        }
        if timeline == nil {
            // Не прочиталось: следующий показ вкладки попробует снова.
            loading = nil
        }
        return timeline
    }
}

/// Живой предпросмотр острова во вкладке «Вид»: демо по кругу, вне реального времени.
///
/// Свои часы, пружины уровней и фазы волн, как у острова (`AppModel.islandVisuals`), но
/// ничего из модели острова не трогает: кадры идут только из `DemoTimeline`. Играет отрезок
/// после `loopStart`, где ритм уже захвачен: он длится целое число тактов, и шов круга
/// приходится на ту же долю того же аккорда.
///
/// Калибровка (`CalibrationView`) дает игроку расписание свечения (`glowSchedule`): тогда демо не
/// играет, остров тихий, а свечение считается по этому расписанию так же, как у острова
/// (`calibrationVisuals`).
@MainActor
@Observable
final class PreviewPlayer {
    /// С этой секунды демо ритм захвачен (захват не дольше 8 с), дальше 4 такта по 2 с до конца.
    static let loopStart = 12.0

    static var demoURL: URL? {
        Bundle.main.url(forResource: "demo", withExtension: "wav", subdirectory: "Demo")
    }

    private(set) var timeline: DemoTimeline?

    private let cache: PreviewTimelineCache
    /// Калибровка: расписание свечения на момент показа кадра (секунды хоста).
    private let glowSchedule: (@MainActor (Double) -> BeatSchedule)?
    /// Калибровка: свечение с памятью о вспышках прошлых кадров, как `AppModel.glowState`.
    @ObservationIgnored private var glowState = BeatGlow()
    /// Время первого кадра и прошлого кадра, с.
    @ObservationIgnored private var startTime: Double?
    @ObservationIgnored private var lastTime: Double?
    @ObservationIgnored private var motion = WaveMotion()
    /// Переливание предпросмотра: свое, как у острова (`AppModel.paletteFlow`).
    @ObservationIgnored private var paletteFlow = PaletteFlow()
    @ObservationIgnored private var layerSprings = [LevelSpring](repeating: LevelSpring(), count: WaveLayer.allCases.count)
    @ObservationIgnored private var levelSpring = LevelSpring()

    init(cache: PreviewTimelineCache = .shared, glowSchedule: (@MainActor (Double) -> BeatSchedule)? = nil) {
        self.cache = cache
        self.glowSchedule = glowSchedule
        timeline = cache.timeline
    }

    /// Игрок калибровки: свечение по внешнему расписанию, без демо.
    var isCalibrating: Bool {
        glowSchedule != nil
    }

    /// Снимки: готовое демо вместо чтения файла, чтобы на снимке вкладки «Вид» шли волны.
    static func seed(_ timeline: DemoTimeline) {
        PreviewTimelineCache.shared.timeline = timeline
    }

    /// Предпросмотр идет только в открытом, видимом окне на вкладке «Вид». Иначе
    /// `TimelineView` стоит и не тратит процессор.
    static func isActive(windowOpen: Bool, windowVisible: Bool, tab: SettingsView.Tab) -> Bool {
        windowOpen && windowVisible && tab == .appearance
    }

    /// Демо из `url` (по умолчанию из ресурсов приложения), если его еще нет. Игроку калибровки
    /// демо не нужно.
    func load(from url: URL? = PreviewPlayer.demoURL) async {
        guard timeline == nil, !isCalibrating else { return }
        let loaded = await cache.load(from: url)
        if timeline == nil, let loaded {
            timeline = loaded
        }
    }

    /// Кадр предпросмотра на `now` секунд. Первый кадр встает на `loopStart` с пружинами на его
    /// уровнях; дальше шаг не длиннее `AppModel.maxVisualStep`, на тот же шаг идет переливание со
    /// скоростью `flowSpeed` («Скорость переливания», 0 без него). Без демо: тихий остров.
    /// «Уменьшение движения»: ни свечения, ни «вздоха», ни мягкого пульса, ни переливания, волны
    /// вдвое медленнее. `softPulse`: «Мягкий пульс» из настроек, без него пульса нет. Акцент баса,
    /// как у острова, от большего из свечения и пульса.
    func visuals(
        now: Double, palette: [PaletteColor], flowSpeed: Double = 0, reduceMotion: Bool, softPulse: Bool = true
    ) -> IslandVisuals {
        guard let timeline, now.isFinite else {
            return IslandVisuals(
                frame: .silent, sampled: .silent, motion: motion, palette: palette, glow: 0, pulse: 0, time: 0,
                flowPhase: paletteFlow.phase
            )
        }
        let start = startTime ?? now
        startTime = start
        // Демо короче `loopStart` (снимки могли положить свое) играет по кругу целиком.
        let loopStart = timeline.duration > Self.loopStart + DemoTimeline.step ? Self.loopStart : 0
        let loop = max(timeline.duration - loopStart, DemoTimeline.step)
        let moment = timeline.moment(at: loopStart + (now - start).truncatingRemainder(dividingBy: loop))
        let sampled = moment.frame

        if let lastTime {
            let dt = min(max(now - lastTime, 0), AppModel.maxVisualStep)
            for index in layerSprings.indices {
                layerSprings[index].step(toward: index < sampled.layers.count ? sampled.layers[index] : 0, dt: dt)
            }
            levelSpring.step(toward: sampled.level, dt: dt)
            motion.advance(layers: layerSprings.map(\.value), dt: reduceMotion ? dt / 2 : dt)
            paletteFlow.advance(dt: dt, speed: reduceMotion ? 0 : flowSpeed)
        } else {
            for index in layerSprings.indices {
                layerSprings[index].reset(to: index < sampled.layers.count ? sampled.layers[index] : 0)
            }
            levelSpring.reset(to: sampled.level)
            motion = moment.motion
        }
        lastTime = now

        let glow = reduceMotion ? 0 : moment.glow
        let ambient = reduceMotion || !softPulse ? 0 : moment.ambient
        var frame = sampled
        frame.layers = BeatGlow.accented(layerSprings.map(\.value), glow: max(glow, ambient))
        frame.level = levelSpring.value
        return IslandVisuals(
            frame: frame, sampled: sampled, motion: motion, palette: palette,
            glow: glow, pulse: reduceMotion ? 0 : moment.pulse, ambient: ambient,
            time: now, flowPhase: paletteFlow.phase
        )
    }
}

extension PreviewPlayer {
    /// Кадр калибровки на `now` секунд хоста (`CACurrentMediaTime()`), по тем же правилам, что
    /// у острова (`AppModel.islandVisuals`): кадр будет на экране в `now + presentationLead(R)`,
    /// на этот момент свечение по расписанию `glowSchedule` через `BeatGlow` с памятью, `R` это
    /// `refreshPeriod`. Волны тихие, к басу прибавляется акцент доли. «Вздоха» нет: он опережает
    /// свечение и мешал бы сравнивать вспышку со щелчком. «Уменьшение движения» свечение здесь не
    /// гасит: без вспышки калибровать нечего.
    func calibrationVisuals(now: Double, refreshPeriod: Double, palette: [PaletteColor]) -> IslandVisuals {
        var glow: Float = 0
        if let glowSchedule, now.isFinite {
            let presented = now + LatencyCalculator.presentationLead(refreshPeriod: refreshPeriod)
            glow = glowState.value(at: presented, schedule: glowSchedule(presented), refreshPeriod: refreshPeriod)
        }
        var frame = WaveFrame.silent
        frame.layers = BeatGlow.accented(frame.layers, glow: glow)
        return IslandVisuals(
            frame: frame, sampled: .silent, motion: WaveMotion(), palette: palette, glow: glow, pulse: 0,
            time: now.isFinite ? now : 0
        )
    }
}

/// Свернутый остров на фоне строки меню, как на снимках (`SnapshotBackdrop`): условный вырез
/// 185×32 pt посреди полосы 640 × 150 pt, полоса уменьшена до ширины формы. Вид волн (под
/// системные опции экрана модели, `AppModel.displayOptions`, как на острове), яркость свечения,
/// «вздох» (`IslandView.breathing`), мягкий пульс и скорость переливания из настроек, крыло не
/// шире, чем позволит экран острова (`wingLimit`). Кадры только из демо (`PreviewPlayer`), никогда из `AppModel.islandVisuals`, с
/// частотой экрана острова (`RenderPacing.timelineInterval`), а не чаще. Пока предпросмотр не активен
/// (`PreviewPlayer.isActive`, у калибровки окно настроек не видно), `TimelineView` стоит.
///
/// С игроком калибровки (`PreviewPlayer.isCalibrating`) часы кадров это часы хоста, как у острова,
/// период обновления берется у экрана острова (`AppModel.refreshPeriod`), а яркость свечения не
/// ниже яркости по умолчанию, чтобы вспышку было видно и при слабом свечении в настройках.
struct IslandPreview: View {
    static let stripSize = CGSize(width: 640, height: 150)
    static let notchSize = SnapshotRenderer.notchSize
    static let cornerRadius: CGFloat = 8

    let model: AppModel
    let player: PreviewPlayer
    let active: Bool
    /// Самое широкое крыло на экране острова; `nil`: экран неизвестен.
    let wingLimit: CGFloat?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Полоса с условным вырезом посередине, крыло и запас под свечение по `appearance`.
    static func layout(appearance: WaveAppearance, wingLimit: CGFloat?) -> NotchLayout {
        let notch = CGRect(
            x: (stripSize.width - notchSize.width) / 2, y: stripSize.height - notchSize.height,
            width: notchSize.width, height: notchSize.height
        )
        let free = notch.minX - NotchGeometry.wingAuxMargin
        return NotchLayout(
            screenID: 0, screenFrame: CGRect(origin: .zero, size: stripSize), hasNotch: true, notch: notch,
            wingLimit: min(free, wingLimit ?? NotchGeometry.maxWingWidth, NotchGeometry.maxWingWidth),
            wingWidth: CGFloat(appearance.wingWidth), glowSize: appearance.glowSize
        )
    }

    var body: some View {
        // Настройки читаются здесь, а не на каждом кадре: тело пересчитывается при их смене.
        let settings = model.settings
        // Только для рисования, как на острове: в настройки не пишется.
        let appearance = settings.appearance.adapted(to: model.displayOptions)
        let palette = appearance.palette(artwork: model.palette)
        let calibrating = player.isCalibrating
        let glow = calibrating
            ? max(settings.glowIntensity, AppSettings.Default.glowIntensity)
            : reduceMotion ? 0 : settings.glowIntensity
        let canBreathe = !reduceMotion && !calibrating
        let beatPulse = settings.beatPulse
        let softPulse = settings.softPulse
        let flowSpeed = settings.colorFlow
        let layout = Self.layout(appearance: appearance, wingLimit: wingLimit)
        let geometry = IslandGeometry(layout: layout, wingWidth: layout.wingWidth)
        let size = Self.stripSize

        Color.clear
            .aspectRatio(size.width / size.height, contentMode: .fit)
            .overlay(alignment: .topLeading) {
                GeometryReader { proxy in
                    SnapshotBackdrop(
                        layout: layout, screenSize: size, menuBarHeight: Self.notchSize.height,
                        appearance: colorScheme == .dark ? .dark : .light
                    ) {
                        TimelineView(.animation(
                            minimumInterval: RenderPacing.timelineInterval(
                                refreshPeriod: model.refreshPeriod, lowPower: false
                            ),
                            paused: !active
                        )) { context in
                            let visuals = calibrating
                                ? player.calibrationVisuals(
                                    now: CACurrentMediaTime(), refreshPeriod: model.refreshPeriod, palette: palette
                                )
                                : player.visuals(
                                    now: context.date.timeIntervalSinceReferenceDate, palette: palette,
                                    flowSpeed: flowSpeed, reduceMotion: reduceMotion, softPulse: softPulse
                                )
                            // Предпросмотр показывает свернутый остров без баннера.
                            let breath = IslandView.breathing(
                                visuals: visuals, canBreathe: canBreathe, beatPulse: beatPulse
                            )
                            PreviewScene(
                                visuals: visuals, geometry: geometry, glow: glow, appearance: appearance,
                                scale: breath.scale, beatGlow: breath.glow
                            )
                        }
                    }
                    .scaleEffect(proxy.size.width / size.width, anchor: .topLeading)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel("Предпросмотр острова")
            .task(id: active) {
                guard active else { return }
                await player.load()
            }
    }
}

/// Свернутый остров на один кадр: свечение под ним, тело и волны крыльев, как в `IslandView`.
/// `scale` и `beatGlow`: «вздох» и свечение под островом кадра (`IslandView.breathing`). Цвета
/// волн и свечения с переливанием кадра (`IslandVisuals.flowPhase`).
private struct PreviewScene: View {
    let visuals: IslandVisuals
    let geometry: IslandGeometry
    let glow: Double
    let appearance: WaveAppearance
    let scale: CGFloat
    let beatGlow: Float

    var body: some View {
        let state = IslandState.collapsed
        let anchor = geometry.anchor
        ZStack(alignment: .topLeading) {
            if BeatGlowView.isVisible(
                glow: BeatGlowView.brightness(glow: beatGlow, ambient: visuals.ambient), intensity: glow
            ) {
                BeatGlowView(
                    geometry: geometry, state: state, scale: scale, glow: beatGlow, ambient: visuals.ambient,
                    intensity: glow, size: appearance.glowSize, blurScale: appearance.glowBlurScale,
                    color: visuals.glowSourceColor
                )
            }
            ZStack(alignment: .topLeading) {
                IslandBodyView(geometry: geometry, state: state)
                    .equatable()
                IslandWavesView(
                    visuals: visuals, geometry: geometry, state: state, layers: (wing: true, panel: false),
                    glow: glow, appearance: appearance, paused: false
                )
            }
            .scaleEffect(scale, anchor: UnitPoint(x: anchor.x / geometry.size.width, y: anchor.y / geometry.size.height))
        }
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
    }
}
