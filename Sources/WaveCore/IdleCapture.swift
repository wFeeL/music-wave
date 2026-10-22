/// Когда приостановить захват в тишине и когда вернуть его.
///
/// Захват останавливается после `delay` секунд тишины, только если источник это приложение,
/// Now Playing работает и с выбора источника хотя бы раз прислал его трек (тогда он сообщит и
/// о начале воспроизведения), и ни один процесс источника не выводит звук. Весь звук системы не
/// останавливается никогда: звук может начать любое приложение без Now Playing. Источники без
/// Now Playing (Telegram, игры) и источники, о которых адаптер молчит, слышит только tap, поэтому
/// для них захват тоже не останавливается. Открытый, но тихий поток вывода (`IsRunningOutput`
/// без звука) держит захват: это стоит энергии, зато звук в таком потоке не пропадет.
///
/// Остающийся предел: после приостановки о звуке без Now Playing сообщает только подписка на
/// `IsRunningOutput` процессов источника (`AudioPipeline`). Звук, который приложение выводит
/// через процесс, не отнесенный к источнику (например, системную службу), захват не вернет,
/// пока Now Playing не сообщит об игре.
///
/// Приостановленный захват возвращается, когда появился звук, Now Playing сообщил об игре или
/// приостановка перестала быть оправданной (адаптер перестал работать, источник сменился,
/// процесс начал выводить звук). Тишина считается с момента, когда остановка стала допустимой,
/// и заново после приостановки и после любого возобновления, в том числе без участия политики.
public struct IdleCapturePolicy: Sendable {
    public static let defaultDelay = 10.0

    public enum Action: Sendable, Equatable {
        case none
        case suspend
        case resume
    }

    public struct Inputs: Sendable, Equatable {
        /// Уровень tap выше порога (`ActivityGate`).
        public var audioActive: Bool
        /// Now Playing источника сообщает, что он играет.
        public var sourcePlaying: Bool
        /// Now Playing работает.
        public var adapterAvailable: Bool
        /// С выбора источника Now Playing хотя бы раз прислал его трек.
        public var sourceReportsNowPlaying: Bool
        /// Источник это весь звук системы.
        public var systemWide: Bool
        /// Хотя бы один процесс источника сейчас сообщает `kAudioProcessPropertyIsRunningOutput`.
        public var sourceOutputting: Bool
        /// Захват сейчас приостановлен.
        public var suspended: Bool

        public init(
            audioActive: Bool,
            sourcePlaying: Bool,
            adapterAvailable: Bool,
            sourceReportsNowPlaying: Bool,
            systemWide: Bool,
            sourceOutputting: Bool,
            suspended: Bool
        ) {
            self.audioActive = audioActive
            self.sourcePlaying = sourcePlaying
            self.adapterAvailable = adapterAvailable
            self.sourceReportsNowPlaying = sourceReportsNowPlaying
            self.systemWide = systemWide
            self.sourceOutputting = sourceOutputting
            self.suspended = suspended
        }
    }

    public let delay: Double
    private var silentSince: Double?

    public init(delay: Double = IdleCapturePolicy.defaultDelay) {
        self.delay = delay
    }

    public mutating func update(_ inputs: Inputs, now: Double) -> Action {
        let mayStayIdle = inputs.adapterAvailable && inputs.sourceReportsNowPlaying
            && !inputs.systemWide && !inputs.sourceOutputting
        if inputs.audioActive || inputs.sourcePlaying {
            silentSince = nil
            return inputs.suspended ? .resume : .none
        }
        if inputs.suspended {
            silentSince = nil
            return mayStayIdle ? .none : .resume
        }
        guard mayStayIdle else {
            // Тишина считается с момента, когда остановка стала допустимой.
            silentSince = nil
            return .none
        }
        let since = silentSince ?? now
        silentSince = since
        guard now - since >= delay - 1e-9 else { return .none }
        // Конвейер может сам возобновить захват до следующего вызова; тогда тишина считается
        // заново, а не с прежней отметки, и захват не останавливается тут же снова.
        silentSince = nil
        return .suspend
    }

    /// Тишина считается заново (пауза, сон, остановка).
    public mutating func reset() {
        silentSince = nil
    }
}

/// Замечает, что процесс начал выводить звук, пока захват приостановлен: в наборе процессов
/// с `kAudioProcessPropertyIsRunningOutput` появился тот, которого не было при прошлой проверке.
/// Процессы, которые выводили звук уже в момент приостановки (открытый, но тихий поток), не
/// будят, пока не остановятся и не начнут снова.
public struct OutputStartDetector: Sendable {
    private var outputting: Set<UInt32>

    public init(outputting: Set<UInt32>) {
        self.outputting = outputting
    }

    /// `true`, если в `current` есть процесс, которого не было при прошлой проверке.
    public mutating func update(outputting current: Set<UInt32>) -> Bool {
        let started = !current.isSubset(of: outputting)
        outputting = current
        return started
    }
}
