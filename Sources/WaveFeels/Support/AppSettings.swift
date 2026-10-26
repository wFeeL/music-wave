import Foundation
import Observation
import WaveCore

/// Настройки пользователя в `UserDefaults`, ключи с префиксом `wf.`.
///
/// Перечисления хранятся как JSON. Сеттеры ограничивают диапазоны, бесконечность и NaN
/// заменяются значением по умолчанию. Значения из хранилища при чтении проходят те же проверки,
/// испорченный JSON дает значение по умолчанию. Каждое свойство отслеживается отдельно
/// (`access` и `withMutation`), присваивание того же значения ничего не меняет и не пишет.
@MainActor
@Observable
final class AppSettings {
    enum Key {
        static let source = "wf.source"
        static let sensitivity = "wf.sensitivity"
        static let levelMode = "wf.levelMode"
        static let followSystemVolume = "wf.followSystemVolume"
        static let latencyMode = "wf.latencyMode"
        /// Общий сдвиг до 1.1. Только читается: из него `syncOffsets` получает `fallbackMs`, пока
        /// своего ключа нет.
        static let syncOffset = "wf.syncOffset"
        static let syncOffsets = "wf.syncOffsets"
        static let wingWidth = "wf.wingWidth"
        static let glowIntensity = "wf.glowIntensity"
        static let beatPulse = "wf.beatPulse"
        static let softPulse = "wf.softPulse"
        static let hideDelay = "wf.hideDelay"
        static let hideInFullscreen = "wf.hideInFullscreen"
        static let showTrackBanner = "wf.showTrackBanner"
        static let paused = "wf.paused"
        static let colorMode = "wf.colorMode"
        static let glowSize = "wf.glowSize"
        /// Ключ 1.2 («Радиус свечения»): только читается, пока нет `wf.glowSize`.
        static let legacyGlowRadius = "wf.glowRadius"
        static let glowSharpness = "wf.glowSharpness"
        static let flashLength = "wf.flashLength"
        static let lineCount = "wf.lineCount"
        static let fill = "wf.fill"
        static let lineThickness = "wf.lineThickness"
        static let waveAmplitude = "wf.waveAmplitude"
        /// Стиль волн `WaveLook`. Ключ назван по смыслу настройки, свойство `look`.
        static let waveStyle = "wf.waveStyle"
        static let colorFlow = "wf.colorFlow"
        static let colorByBand = "wf.colorByBand"
        static let softStop = "wf.softStop"
        static let artworkGlow = "wf.artworkGlow"
        static let progressLine = "wf.progressLine"
        static let autoSource = "wf.autoSource"
        static let trackSwipe = "wf.trackSwipe"
        static let expandDelay = "wf.expandDelay"
        static let followDisplayOptions = "wf.followDisplayOptions"
    }

    enum Limits {
        static let sensitivity: ClosedRange<Float> = 0.25...3
        static let manualLatency: ClosedRange<Int> = 0...LatencyCalculator.maxMilliseconds
        static let syncOffset = SyncOffsets.range
        static let wingWidth = WaveAppearance.Limits.wingWidth
        static let glowIntensity: ClosedRange<Double> = 0...1
        static let hideDelay: ClosedRange<Double> = 1...30
        static let colorFlow = WaveAppearance.Limits.colorFlow
        static let flashLength = BeatGlow.decayScaleRange
        static let expandDelay = IslandStateMachine.expandDelayRange
    }

    enum Default {
        static let sensitivity: Float = 1.0
        static let levelMode = LevelMode.auto
        static let followSystemVolume = true
        static let latencyMode = LatencyMode.auto
        static let wingWidth = 64.0
        static let glowIntensity = 0.6
        static let beatPulse = true
        static let softPulse = true
        static let hideDelay = 5.0
        static let hideInFullscreen = true
        static let showTrackBanner = true
        static let paused = false
        static let colorMode = WaveAppearance.standard.colorMode
        static let glowSize = WaveAppearance.standard.glowSize
        static let glowSharpness = WaveAppearance.standard.glowSharpness
        static let flashLength = 1.0
        static let lineCount = WaveAppearance.standard.lineCount
        static let fill = WaveAppearance.standard.fill
        static let lineThickness = WaveAppearance.standard.thickness
        static let waveAmplitude = WaveAppearance.standard.amplitude
        static let look = WaveAppearance.standard.look
        static let colorFlow = WaveAppearance.standard.colorFlow
        static let colorByBand = WaveAppearance.standard.colorByBand
        static let softStop = true
        static let artworkGlow = true
        static let progressLine = false
        static let autoSource = false
        static let trackSwipe = true
        static let expandDelay = IslandStateMachine.defaultExpandDelay
        static let followDisplayOptions = true
    }

    @ObservationIgnored private let defaults: UserDefaults

    @ObservationIgnored private var storedSource: AudioSource?
    @ObservationIgnored private var storedSensitivity: Float
    @ObservationIgnored private var storedLevelMode: LevelMode
    @ObservationIgnored private var storedFollowSystemVolume: Bool
    @ObservationIgnored private var storedLatencyMode: LatencyMode
    @ObservationIgnored private var storedSyncOffsets: SyncOffsets
    @ObservationIgnored private var storedWingWidth: Double
    @ObservationIgnored private var storedGlowIntensity: Double
    @ObservationIgnored private var storedBeatPulse: Bool
    @ObservationIgnored private var storedSoftPulse: Bool
    @ObservationIgnored private var storedHideDelay: Double
    @ObservationIgnored private var storedHideInFullscreen: Bool
    @ObservationIgnored private var storedShowTrackBanner: Bool
    @ObservationIgnored private var storedPaused: Bool
    @ObservationIgnored private var storedColorMode: WaveColorMode
    @ObservationIgnored private var storedGlowSize: Double
    @ObservationIgnored private var storedGlowSharpness: Double
    @ObservationIgnored private var storedFlashLength: Double
    @ObservationIgnored private var storedLineCount: Int
    @ObservationIgnored private var storedFill: Double
    @ObservationIgnored private var storedLineThickness: Double
    @ObservationIgnored private var storedWaveAmplitude: Double
    @ObservationIgnored private var storedLook: WaveLook
    @ObservationIgnored private var storedColorFlow: Double
    @ObservationIgnored private var storedColorByBand: Bool
    @ObservationIgnored private var storedSoftStop: Bool
    @ObservationIgnored private var storedArtworkGlow: Bool
    @ObservationIgnored private var storedProgressLine: Bool
    @ObservationIgnored private var storedAutoSource: Bool
    @ObservationIgnored private var storedTrackSwipe: Bool
    @ObservationIgnored private var storedExpandDelay: Double
    @ObservationIgnored private var storedFollowDisplayOptions: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        storedSource = Self.readJSON(AudioSource.self, defaults, Key.source)
        storedSensitivity = Self.clampSensitivity(
            Self.readDouble(defaults, Key.sensitivity).map { Float($0) } ?? Default.sensitivity
        )
        storedLevelMode = Self.readJSON(LevelMode.self, defaults, Key.levelMode) ?? Default.levelMode
        storedFollowSystemVolume = Self.readBool(defaults, Key.followSystemVolume) ?? Default.followSystemVolume
        storedLatencyMode = Self.clampLatency(
            Self.readJSON(LatencyMode.self, defaults, Key.latencyMode) ?? Default.latencyMode
        )
        storedSyncOffsets = Self.readJSON(SyncOffsets.self, defaults, Key.syncOffsets)
            ?? SyncOffsets.migrated(legacyMs: Self.readInt(defaults, Key.syncOffset))
        storedWingWidth = Self.clamp(
            Self.readDouble(defaults, Key.wingWidth) ?? Default.wingWidth,
            Limits.wingWidth,
            fallback: Default.wingWidth
        )
        storedGlowIntensity = Self.clamp(
            Self.readDouble(defaults, Key.glowIntensity) ?? Default.glowIntensity,
            Limits.glowIntensity,
            fallback: Default.glowIntensity
        )
        storedBeatPulse = Self.readBool(defaults, Key.beatPulse) ?? Default.beatPulse
        storedSoftPulse = Self.readBool(defaults, Key.softPulse) ?? Default.softPulse
        storedHideDelay = Self.clamp(
            Self.readDouble(defaults, Key.hideDelay) ?? Default.hideDelay,
            Limits.hideDelay,
            fallback: Default.hideDelay
        )
        storedHideInFullscreen = Self.readBool(defaults, Key.hideInFullscreen) ?? Default.hideInFullscreen
        storedShowTrackBanner = Self.readBool(defaults, Key.showTrackBanner) ?? Default.showTrackBanner
        storedPaused = Self.readBool(defaults, Key.paused) ?? Default.paused
        storedColorMode = Self.sanitized(
            Self.readJSON(WaveColorMode.self, defaults, Key.colorMode) ?? Default.colorMode
        )
        // Размер берет сохраненный в 1.2 «Радиус свечения», пока своего значения нет.
        storedGlowSize = Self.clamp(
            Self.readDouble(defaults, Key.glowSize) ?? Self.readDouble(defaults, Key.legacyGlowRadius) ?? Default.glowSize,
            WaveAppearance.Limits.glowSize,
            fallback: Default.glowSize
        )
        storedGlowSharpness = Self.clamp(
            Self.readDouble(defaults, Key.glowSharpness) ?? Default.glowSharpness,
            WaveAppearance.Limits.glowSharpness,
            fallback: Default.glowSharpness
        )
        storedFlashLength = Self.clamp(
            Self.readDouble(defaults, Key.flashLength) ?? Default.flashLength,
            Limits.flashLength,
            fallback: Default.flashLength
        )
        storedLineCount = Self.clampLineCount(Self.readInt(defaults, Key.lineCount) ?? Default.lineCount)
        storedFill = Self.clamp(
            Self.readDouble(defaults, Key.fill) ?? Default.fill,
            WaveAppearance.Limits.fill,
            fallback: Default.fill
        )
        storedLineThickness = Self.clamp(
            Self.readDouble(defaults, Key.lineThickness) ?? Default.lineThickness,
            WaveAppearance.Limits.thickness,
            fallback: Default.lineThickness
        )
        storedWaveAmplitude = Self.clamp(
            Self.readDouble(defaults, Key.waveAmplitude) ?? Default.waveAmplitude,
            WaveAppearance.Limits.amplitude,
            fallback: Default.waveAmplitude
        )
        storedLook = Self.readJSON(WaveLook.self, defaults, Key.waveStyle) ?? Default.look
        storedColorFlow = Self.clamp(
            Self.readDouble(defaults, Key.colorFlow) ?? Default.colorFlow,
            Limits.colorFlow,
            fallback: Default.colorFlow
        )
        storedColorByBand = Self.readBool(defaults, Key.colorByBand) ?? Default.colorByBand
        storedSoftStop = Self.readBool(defaults, Key.softStop) ?? Default.softStop
        storedArtworkGlow = Self.readBool(defaults, Key.artworkGlow) ?? Default.artworkGlow
        storedProgressLine = Self.readBool(defaults, Key.progressLine) ?? Default.progressLine
        storedAutoSource = Self.readBool(defaults, Key.autoSource) ?? Default.autoSource
        storedTrackSwipe = Self.readBool(defaults, Key.trackSwipe) ?? Default.trackSwipe
        storedExpandDelay = Self.clamp(
            Self.readDouble(defaults, Key.expandDelay) ?? Default.expandDelay,
            Limits.expandDelay,
            fallback: Default.expandDelay
        )
        storedFollowDisplayOptions = Self.readBool(defaults, Key.followDisplayOptions)
            ?? Default.followDisplayOptions
    }

    // MARK: - Свойства

    /// Источник звука; `nil`, пока `AppModel` не выбрал его при первом запуске.
    var source: AudioSource? {
        get {
            access(keyPath: \.source)
            return storedSource
        }
        set {
            guard newValue != storedSource else { return }
            withMutation(keyPath: \.source) { storedSource = newValue }
            if let newValue {
                writeJSON(newValue, Key.source)
            } else {
                defaults.removeObject(forKey: Key.source)
            }
        }
    }

    /// Чувствительность (усиление), 0.25...3.
    var sensitivity: Float {
        get {
            access(keyPath: \.sensitivity)
            return storedSensitivity
        }
        set {
            let value = Self.clampSensitivity(newValue)
            guard value != storedSensitivity else { return }
            withMutation(keyPath: \.sensitivity) { storedSensitivity = value }
            defaults.set(Double(value), forKey: Key.sensitivity)
        }
    }

    var levelMode: LevelMode {
        get {
            access(keyPath: \.levelMode)
            return storedLevelMode
        }
        set {
            guard newValue != storedLevelMode else { return }
            withMutation(keyPath: \.levelMode) { storedLevelMode = newValue }
            writeJSON(newValue, Key.levelMode)
        }
    }

    var followSystemVolume: Bool {
        get {
            access(keyPath: \.followSystemVolume)
            return storedFollowSystemVolume
        }
        set {
            guard newValue != storedFollowSystemVolume else { return }
            withMutation(keyPath: \.followSystemVolume) { storedFollowSystemVolume = newValue }
            defaults.set(newValue, forKey: Key.followSystemVolume)
        }
    }

    /// Задержка волн: авто или вручную 0...500 мс.
    var latencyMode: LatencyMode {
        get {
            access(keyPath: \.latencyMode)
            return storedLatencyMode
        }
        set {
            let value = Self.clampLatency(newValue)
            guard value != storedLatencyMode else { return }
            withMutation(keyPath: \.latencyMode) { storedLatencyMode = value }
            writeJSON(value, Key.latencyMode)
        }
    }

    /// «Сдвиг синхронизации» по устройствам вывода, мс: -100...100 с шагом 5 (`SyncOffsets`).
    /// Хранится как JSON в `wf.syncOffsets`. Пока ключа нет (или JSON испорчен), общий сдвиг
    /// берется из старого `wf.syncOffset`; старый ключ не пишется и не удаляется.
    var syncOffsets: SyncOffsets {
        get {
            access(keyPath: \.syncOffsets)
            return storedSyncOffsets
        }
        set {
            guard newValue != storedSyncOffsets else { return }
            withMutation(keyPath: \.syncOffsets) { storedSyncOffsets = newValue }
            writeJSON(newValue, Key.syncOffsets)
        }
    }

    /// Ширина каждого крыла в pt, 40...200. На экране с вырезом остров еще ограничивает ее
    /// свободной областью строки меню (`NotchLayout.wingLimit`), настройка при этом не меняется.
    var wingWidth: Double {
        get {
            access(keyPath: \.wingWidth)
            return storedWingWidth
        }
        set {
            let value = Self.clamp(newValue, Limits.wingWidth, fallback: Default.wingWidth)
            guard value != storedWingWidth else { return }
            withMutation(keyPath: \.wingWidth) { storedWingWidth = value }
            defaults.set(value, forKey: Key.wingWidth)
        }
    }

    /// Яркость свечения, 0...1.
    var glowIntensity: Double {
        get {
            access(keyPath: \.glowIntensity)
            return storedGlowIntensity
        }
        set {
            let value = Self.clamp(newValue, Limits.glowIntensity, fallback: Default.glowIntensity)
            guard value != storedGlowIntensity else { return }
            withMutation(keyPath: \.glowIntensity) { storedGlowIntensity = value }
            defaults.set(value, forKey: Key.glowIntensity)
        }
    }

    /// «Вздох» острова на сильных долях.
    var beatPulse: Bool {
        get {
            access(keyPath: \.beatPulse)
            return storedBeatPulse
        }
        set {
            guard newValue != storedBeatPulse else { return }
            withMutation(keyPath: \.beatPulse) { storedBeatPulse = newValue }
            defaults.set(newValue, forKey: Key.beatPulse)
        }
    }

    /// Мягкий пульс: слабое свечение под вспышками в такт бочке и сетке доли
    /// (`BeatGlow.ambient`), всегда ниже порога вспышки.
    var softPulse: Bool {
        get {
            access(keyPath: \.softPulse)
            return storedSoftPulse
        }
        set {
            guard newValue != storedSoftPulse else { return }
            withMutation(keyPath: \.softPulse) { storedSoftPulse = newValue }
            defaults.set(newValue, forKey: Key.softPulse)
        }
    }

    /// Через сколько секунд тишины остров прячется, 1...30.
    var hideDelay: Double {
        get {
            access(keyPath: \.hideDelay)
            return storedHideDelay
        }
        set {
            let value = Self.clamp(newValue, Limits.hideDelay, fallback: Default.hideDelay)
            guard value != storedHideDelay else { return }
            withMutation(keyPath: \.hideDelay) { storedHideDelay = value }
            defaults.set(value, forKey: Key.hideDelay)
        }
    }

    var hideInFullscreen: Bool {
        get {
            access(keyPath: \.hideInFullscreen)
            return storedHideInFullscreen
        }
        set {
            guard newValue != storedHideInFullscreen else { return }
            withMutation(keyPath: \.hideInFullscreen) { storedHideInFullscreen = newValue }
            defaults.set(newValue, forKey: Key.hideInFullscreen)
        }
    }

    /// «Показывать новый трек»: при смене трека остров ненадолго раскрывается в баннер.
    var showTrackBanner: Bool {
        get {
            access(keyPath: \.showTrackBanner)
            return storedShowTrackBanner
        }
        set {
            guard newValue != storedShowTrackBanner else { return }
            withMutation(keyPath: \.showTrackBanner) { storedShowTrackBanner = newValue }
            defaults.set(newValue, forKey: Key.showTrackBanner)
        }
    }

    /// «Приостановить визуализацию».
    var paused: Bool {
        get {
            access(keyPath: \.paused)
            return storedPaused
        }
        set {
            guard newValue != storedPaused else { return }
            withMutation(keyPath: \.paused) { storedPaused = newValue }
            defaults.set(newValue, forKey: Key.paused)
        }
    }

    // MARK: - Остров и панель

    /// Мягкая остановка: на паузе волны затихают и выпрямляются, свечение гаснет плавно (`SoftStop`).
    var softStop: Bool {
        get {
            access(keyPath: \.softStop)
            return storedSoftStop
        }
        set {
            guard newValue != storedSoftStop else { return }
            withMutation(keyPath: \.softStop) { storedSoftStop = newValue }
            defaults.set(newValue, forKey: Key.softStop)
        }
    }

    /// Свечение цвета обложки за раскрытой панелью (`ArtworkGlow`).
    var artworkGlow: Bool {
        get {
            access(keyPath: \.artworkGlow)
            return storedArtworkGlow
        }
        set {
            guard newValue != storedArtworkGlow else { return }
            withMutation(keyPath: \.artworkGlow) { storedArtworkGlow = newValue }
            defaults.set(newValue, forKey: Key.artworkGlow)
        }
    }

    /// Полоса прогресса по нижней кромке свернутого острова: доля проигранного трека из
    /// Now Playing, без Now Playing не видна.
    var progressLine: Bool {
        get {
            access(keyPath: \.progressLine)
            return storedProgressLine
        }
        set {
            guard newValue != storedProgressLine else { return }
            withMutation(keyPath: \.progressLine) { storedProgressLine = newValue }
            defaults.set(newValue, forKey: Key.progressLine)
        }
    }

    /// Автовыбор источника: волны переходят на другое заигравшее приложение и возвращаются,
    /// когда оно замолчало (`AutoSourceSwitcher`). По умолчанию выключен.
    var autoSource: Bool {
        get {
            access(keyPath: \.autoSource)
            return storedAutoSource
        }
        set {
            guard newValue != storedAutoSource else { return }
            withMutation(keyPath: \.autoSource) { storedAutoSource = newValue }
            defaults.set(newValue, forKey: Key.autoSource)
        }
    }

    /// Горизонтальный свайп двумя пальцами над островом: предыдущий или следующий трек
    /// (`TrackSwipeDetector`).
    var trackSwipe: Bool {
        get {
            access(keyPath: \.trackSwipe)
            return storedTrackSwipe
        }
        set {
            guard newValue != storedTrackSwipe else { return }
            withMutation(keyPath: \.trackSwipe) { storedTrackSwipe = newValue }
            defaults.set(newValue, forKey: Key.trackSwipe)
        }
    }

    /// Сколько курсор держится у выреза до раскрытия, секунды:
    /// `IslandStateMachine.expandDelayRange`, по умолчанию `defaultExpandDelay`.
    var expandDelay: Double {
        get {
            access(keyPath: \.expandDelay)
            return storedExpandDelay
        }
        set {
            let value = Self.clamp(newValue, Limits.expandDelay, fallback: Default.expandDelay)
            guard value != storedExpandDelay else { return }
            withMutation(keyPath: \.expandDelay) { storedExpandDelay = value }
            defaults.set(value, forKey: Key.expandDelay)
        }
    }

    /// Подстраивать вид под системные «Увеличить контраст» и «Уменьшить прозрачность»
    /// (`WaveAppearance.adapted(to:)`).
    var followDisplayOptions: Bool {
        get {
            access(keyPath: \.followDisplayOptions)
            return storedFollowDisplayOptions
        }
        set {
            guard newValue != storedFollowDisplayOptions else { return }
            withMutation(keyPath: \.followDisplayOptions) { storedFollowDisplayOptions = newValue }
            defaults.set(newValue, forKey: Key.followDisplayOptions)
        }
    }

    // MARK: - Вид волн

    /// Вид волн целиком из сохраненных значений (вкладка «Вид»). Только читает.
    var appearance: WaveAppearance {
        WaveAppearance(
            wingWidth: wingWidth, colorMode: colorMode, glowSize: glowSize, lineCount: lineCount,
            fill: fill, thickness: lineThickness, amplitude: waveAmplitude,
            colorFlow: colorFlow, colorByBand: colorByBand, look: look,
            glowSharpness: glowSharpness
        )
    }

    /// «Цвет волн»: из обложки, готовая палитра или «Свой цвет». Красит и свечение, и волну
    /// панели. Хранится как JSON; нечитаемое значение (в том числе палитра из будущей версии)
    /// дает «Из обложки».
    var colorMode: WaveColorMode {
        get {
            access(keyPath: \.colorMode)
            return storedColorMode
        }
        set {
            let value = Self.sanitized(newValue)
            guard value != storedColorMode else { return }
            withMutation(keyPath: \.colorMode) { storedColorMode = value }
            writeJSON(value, Key.colorMode)
        }
    }

    /// «Размер свечения», множитель 0.5...3 (в 1.2 «Радиус свечения»: его сохраненное значение читается как размер).
    var glowSize: Double {
        get {
            access(keyPath: \.glowSize)
            return storedGlowSize
        }
        set {
            let value = Self.clamp(newValue, WaveAppearance.Limits.glowSize, fallback: Default.glowSize)
            guard value != storedGlowSize else { return }
            withMutation(keyPath: \.glowSize) { storedGlowSize = value }
            defaults.set(value, forKey: Key.glowSize)
        }
    }

    /// «Четкость свечения», доля 0...1 (размытие `WaveAppearance.glowBlurScale`).
    var glowSharpness: Double {
        get {
            access(keyPath: \.glowSharpness)
            return storedGlowSharpness
        }
        set {
            let value = Self.clamp(newValue, WaveAppearance.Limits.glowSharpness, fallback: Default.glowSharpness)
            guard value != storedGlowSharpness else { return }
            withMutation(keyPath: \.glowSharpness) { storedGlowSharpness = value }
            defaults.set(value, forKey: Key.glowSharpness)
        }
    }

    /// «Длительность вспышки», множитель спада свечения 0.5...2 (`BeatGlow.decay(period:scale:)`).
    /// Только показ: ритм и его журнал считаются со спадом 1×.
    var flashLength: Double {
        get {
            access(keyPath: \.flashLength)
            return storedFlashLength
        }
        set {
            let value = Self.clamp(newValue, Limits.flashLength, fallback: Default.flashLength)
            guard value != storedFlashLength else { return }
            withMutation(keyPath: \.flashLength) { storedFlashLength = value }
            defaults.set(value, forKey: Key.flashLength)
        }
    }

    /// «Количество волн», 1...6.
    var lineCount: Int {
        get {
            access(keyPath: \.lineCount)
            return storedLineCount
        }
        set {
            let value = Self.clampLineCount(newValue)
            guard value != storedLineCount else { return }
            withMutation(keyPath: \.lineCount) { storedLineCount = value }
            defaults.set(value, forKey: Key.lineCount)
        }
    }

    /// «Заливка», доля 0...1.
    var fill: Double {
        get {
            access(keyPath: \.fill)
            return storedFill
        }
        set {
            let value = Self.clamp(newValue, WaveAppearance.Limits.fill, fallback: Default.fill)
            guard value != storedFill else { return }
            withMutation(keyPath: \.fill) { storedFill = value }
            defaults.set(value, forKey: Key.fill)
        }
    }

    /// «Толщина линий», множитель 0.5...2.
    var lineThickness: Double {
        get {
            access(keyPath: \.lineThickness)
            return storedLineThickness
        }
        set {
            let value = Self.clamp(newValue, WaveAppearance.Limits.thickness, fallback: Default.lineThickness)
            guard value != storedLineThickness else { return }
            withMutation(keyPath: \.lineThickness) { storedLineThickness = value }
            defaults.set(value, forKey: Key.lineThickness)
        }
    }

    /// «Размах», множитель 0.5...2: только геометрия волн, чувствительность отдельно.
    var waveAmplitude: Double {
        get {
            access(keyPath: \.waveAmplitude)
            return storedWaveAmplitude
        }
        set {
            let value = Self.clamp(newValue, WaveAppearance.Limits.amplitude, fallback: Default.waveAmplitude)
            guard value != storedWaveAmplitude else { return }
            withMutation(keyPath: \.waveAmplitude) { storedWaveAmplitude = value }
            defaults.set(value, forKey: Key.waveAmplitude)
        }
    }

    /// Стиль волн, по умолчанию «Волны». Хранится как JSON в `wf.waveStyle`; нечитаемое
    /// значение (в том числе стиль из будущей версии) дает «Волны».
    var look: WaveLook {
        get {
            access(keyPath: \.look)
            return storedLook
        }
        set {
            guard newValue != storedLook else { return }
            withMutation(keyPath: \.look) { storedLook = newValue }
            writeJSON(newValue, Key.waveStyle)
        }
    }

    /// «Скорость переливания», 0...1; 0 выключает. По умолчанию 0: вид после обновления сам
    /// не меняется.
    var colorFlow: Double {
        get {
            access(keyPath: \.colorFlow)
            return storedColorFlow
        }
        set {
            let value = Self.clamp(newValue, Limits.colorFlow, fallback: Default.colorFlow)
            guard value != storedColorFlow else { return }
            withMutation(keyPath: \.colorFlow) { storedColorFlow = value }
            defaults.set(value, forKey: Key.colorFlow)
        }
    }

    /// «Цвет по частотам»: бас, середина и верх каждый своим цветом палитры. По умолчанию
    /// выключен.
    var colorByBand: Bool {
        get {
            access(keyPath: \.colorByBand)
            return storedColorByBand
        }
        set {
            guard newValue != storedColorByBand else { return }
            withMutation(keyPath: \.colorByBand) { storedColorByBand = newValue }
            defaults.set(newValue, forKey: Key.colorByBand)
        }
    }

    // MARK: - Ограничения

    private static func clampSensitivity(_ value: Float) -> Float {
        guard value.isFinite else { return Default.sensitivity }
        return min(max(value, Limits.sensitivity.lowerBound), Limits.sensitivity.upperBound)
    }

    private static func clampLatency(_ mode: LatencyMode) -> LatencyMode {
        switch mode {
        case .auto:
            return .auto
        case .manual(let milliseconds):
            let range = Limits.manualLatency
            return .manual(milliseconds: min(max(milliseconds, range.lowerBound), range.upperBound))
        }
    }

    private static func clampLineCount(_ count: Int) -> Int {
        let range = WaveAppearance.Limits.lineCount
        return min(max(count, range.lowerBound), range.upperBound)
    }

    /// «Свой цвет» с каналами в 0...1; цвет с NaN или бесконечностью заменяется первым цветом
    /// стандартной палитры. Иначе `JSONEncoder` не запишет его, а волна станет черной.
    private static func sanitized(_ mode: WaveColorMode) -> WaveColorMode {
        guard case .custom(let color) = mode else { return mode }
        guard color.r.isFinite, color.g.isFinite, color.b.isFinite else {
            return .custom(PaletteExtractor.fallback[0])
        }
        func unit(_ channel: Float) -> Float { min(max(channel, 0), 1) }
        return .custom(PaletteColor(r: unit(color.r), g: unit(color.g), b: unit(color.b)))
    }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    // MARK: - Хранилище

    private static func readDouble(_ defaults: UserDefaults, _ key: String) -> Double? {
        defaults.object(forKey: key) == nil ? nil : defaults.double(forKey: key)
    }

    /// Целое из числа в хранилище; не число (строка, данные) и нечисловое значение дают `nil`.
    private static func readInt(_ defaults: UserDefaults, _ key: String) -> Int? {
        guard let number = defaults.object(forKey: key) as? NSNumber else { return nil }
        let value = number.doubleValue
        guard value.isFinite, abs(value) < 1e9 else { return nil }
        return Int(value.rounded())
    }

    private static func readBool(_ defaults: UserDefaults, _ key: String) -> Bool? {
        defaults.object(forKey: key) == nil ? nil : defaults.bool(forKey: key)
    }

    private static func readJSON<T: Decodable>(_ type: T.Type, _ defaults: UserDefaults, _ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func writeJSON<T: Encodable>(_ value: T, _ key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}

/// Bundle ID приложений-источников, о которых Now Playing хоть раз сообщал, за все запуски
/// (`UserDefaults`, ключ `wf.nowPlayingSources`). По нему «тишина адаптера» считается только
/// для источников, которые Now Playing вообще публикуют (`AdapterSilenceMonitor.applies`).
@MainActor
final class NowPlayingSourceHistory {
    static let key = "wf.nowPlayingSources"

    private let defaults: UserDefaults
    private(set) var bundleIDs: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        bundleIDs = Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    /// Запоминает bundle ID; пишет в `UserDefaults`, только если его еще не было.
    func insert(_ bundleID: String) {
        guard !bundleID.isEmpty, bundleIDs.insert(bundleID).inserted else { return }
        defaults.set(bundleIDs.sorted(), forKey: Self.key)
    }
}
