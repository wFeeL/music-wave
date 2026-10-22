/// Восстановление захвата: сторож нулей и повторы создания tap.
///
/// Сторож нулей: если источник звучит, а tap отдает точные нули дольше `zeroRunLimit`, tap
/// пересобирается быстро, после пауз `watchdogPauses` (последняя повторяется), до
/// `maxWatchdogRebuilds` раз подряд. Дальше пересборка идет медленно, не чаще раза в
/// `slowRetryInterval`, пока звук не вернется. Счетчик быстрых попыток сбрасывает только
/// вернувшийся ненулевой звук (не раньше `audioReturnGrace` после пересборки: сразу после нее
/// счет нулей еще пуст), смена источника и `reset()`.
///
/// Создание tap: после неудачи повторы через `startRetryPauses`, затем медленные повторы раз
/// в `slowRetryInterval`, пока tap не создастся.
///
/// Когда быстрые попытки кончились (`exhausted`), приложение показывает подсказку
/// (`CaptureHints`).
public struct CaptureRecovery: Sendable {
    public struct Timing: Sendable, Equatable {
        /// Сколько секунд нулей при звучащем источнике запускают пересборку.
        public var zeroRunLimit: Double
        /// Быстрых пересборок сторожа подряд.
        public var maxWatchdogRebuilds: Int
        /// Паузы перед быстрыми пересборками сторожа; последняя повторяется.
        public var watchdogPauses: [Double]
        /// Паузы перед повторами, если tap не создался.
        public var startRetryPauses: [Double]
        /// Медленные повторы после быстрых, с.
        public var slowRetryInterval: Double
        /// Как часто проверяет сторож, с.
        public var watchdogInterval: Double
        /// Ноль в счете нулей раньше этого срока после пересборки еще не значит, что звук вернулся.
        public var audioReturnGrace: Double

        public init(
            zeroRunLimit: Double = 2.5,
            maxWatchdogRebuilds: Int = 5,
            watchdogPauses: [Double] = [1, 2, 4],
            startRetryPauses: [Double] = [1, 2, 4],
            slowRetryInterval: Double = 30,
            watchdogInterval: Double = 0.5,
            audioReturnGrace: Double = 1
        ) {
            self.zeroRunLimit = zeroRunLimit
            self.maxWatchdogRebuilds = maxWatchdogRebuilds
            self.watchdogPauses = watchdogPauses
            self.startRetryPauses = startRetryPauses
            self.slowRetryInterval = slowRetryInterval
            self.watchdogInterval = watchdogInterval
            self.audioReturnGrace = audioReturnGrace
        }

        public static let standard = Timing()
    }

    public enum WatchdogAction: Sendable, Equatable {
        case none
        /// Быстрая пересборка номер `attempt` после паузы `pause`.
        case rebuild(attempt: Int, pause: Double)
        /// Быстрые попытки кончились: пересобрать сейчас, следующий раз не раньше чем через
        /// `slowRetryInterval`.
        case slowRetry
    }

    public enum StartFailureAction: Sendable, Equatable {
        /// Повтор номер `attempt` после паузы `pause`.
        case retry(attempt: Int, pause: Double)
        /// Быстрые повторы кончились: следующий через `pause`, с номером `slowRetryAttempt`.
        case slowRetry(pause: Double)
    }

    public let timing: Timing
    /// Быстрых пересборок сторожа подряд.
    public private(set) var watchdogRebuilds = 0
    /// Быстрые повторы создания tap кончились, идут медленные.
    public private(set) var startRetriesExhausted = false

    public init(timing: Timing = .standard) {
        self.timing = timing
    }

    /// Быстрые попытки сторожа или создания tap кончились, захват повторяется медленно.
    public var exhausted: Bool {
        watchdogRebuilds >= timing.maxWatchdogRebuilds || startRetriesExhausted
    }

    /// Номер попытки для медленного повтора создания tap: если он не удастся, следующий снова
    /// будет медленным.
    public var slowRetryAttempt: Int {
        timing.startRetryPauses.count
    }

    /// Проверка сторожа, пока tap работает. `zeroRun`: сколько секунд подряд одни нули;
    /// `sinceRebuild`: сколько секунд с прошлой пересборки; `rebuildPending`: пересборка уже
    /// ждет своей паузы.
    public mutating func watchdog(
        zeroRun: Double,
        sourceOutputting: Bool,
        sinceRebuild: Double,
        rebuildPending: Bool
    ) -> WatchdogAction {
        if zeroRun == 0, sinceRebuild > timing.audioReturnGrace {
            watchdogRebuilds = 0
            return .none
        }
        guard sourceOutputting, zeroRun > timing.zeroRunLimit, !rebuildPending else { return .none }
        if watchdogRebuilds < timing.maxWatchdogRebuilds {
            watchdogRebuilds += 1
            let pauses = timing.watchdogPauses
            let pause = pauses.isEmpty ? 0 : pauses[min(watchdogRebuilds - 1, pauses.count - 1)]
            return .rebuild(attempt: watchdogRebuilds, pause: pause)
        }
        return sinceRebuild >= timing.slowRetryInterval - 1e-9 ? .slowRetry : .none
    }

    /// Tap не создался. `attempt`: номер этого повтора, 0 для обычной пересборки.
    public mutating func startFailed(attempt: Int) -> StartFailureAction {
        let pauses = timing.startRetryPauses
        if attempt < pauses.count {
            return .retry(attempt: attempt + 1, pause: pauses[attempt])
        }
        startRetriesExhausted = true
        return .slowRetry(pause: timing.slowRetryInterval)
    }

    /// Tap создался: повторы создания больше не нужны. Счетчик сторожа остается, пока не
    /// вернется звук.
    public mutating func startSucceeded() {
        startRetriesExhausted = false
    }

    /// Все попытки заново: смена источника, выданный доступ, новый запуск.
    public mutating func reset() {
        watchdogRebuilds = 0
        startRetriesExhausted = false
    }
}

/// Доступ к записи системного звука по TCC.
public enum CaptureAccess: Sendable, Equatable {
    case authorized
    case denied
    case unknown
}

/// Подсказки о захвате в строке меню и в диагностике.
public struct CaptureHints: Sendable, Equatable {
    /// «Нет доступа к звуку»: доступ запрещен, или он неизвестен, а быстрые попытки
    /// восстановить захват не помогли.
    public var permission: Bool
    /// «Звук не приходит, хотя доступ разрешен»: доступ разрешен, быстрые попытки не помогли,
    /// захват повторяется медленно.
    public var stalled: Bool

    public init(permission: Bool, stalled: Bool) {
        self.permission = permission
        self.stalled = stalled
    }

    public init(access: CaptureAccess, recoveryExhausted: Bool) {
        permission = access == .denied || (access == .unknown && recoveryExhausted)
        stalled = access == .authorized && recoveryExhausted
    }
}
