/// Когда приостановить захват в тишине и когда вернуть его (design.md, «Сон, пробуждение и
/// энергия»).
///
/// Захват останавливается после `delay` секунд тишины, только если Now Playing работает и с
/// выбора источника хотя бы раз прислал его трек: тогда он сообщит и о начале воспроизведения.
/// Источники без Now Playing (Telegram, игры, весь звук без плеера) и источники, о которых
/// адаптер молчит, слышит только tap, поэтому для них захват не останавливается. Приостановленный
/// захват возвращается, когда появился звук или Now Playing сообщил об игре, и когда приостановка
/// перестала быть оправданной (адаптер перестал работать, источник сменился). После любого
/// возобновления, в том числе без участия политики (процесс начал выводить звук), тишина
/// считается заново.
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
        /// Захват сейчас приостановлен.
        public var suspended: Bool

        public init(
            audioActive: Bool,
            sourcePlaying: Bool,
            adapterAvailable: Bool,
            sourceReportsNowPlaying: Bool,
            suspended: Bool
        ) {
            self.audioActive = audioActive
            self.sourcePlaying = sourcePlaying
            self.adapterAvailable = adapterAvailable
            self.sourceReportsNowPlaying = sourceReportsNowPlaying
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
        if inputs.audioActive || inputs.sourcePlaying {
            silentSince = nil
            return inputs.suspended ? .resume : .none
        }
        if inputs.suspended {
            silentSince = nil
            return mayStayIdle ? .none : .resume
        }
        let since = silentSince ?? now
        silentSince = since
        return mayStayIdle && now - since >= delay - 1e-9 ? .suspend : .none
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
