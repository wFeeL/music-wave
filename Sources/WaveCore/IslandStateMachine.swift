import Foundation

/// Видимость острова под вырезом.
public enum IslandState: Sendable, Equatable {
    case hidden
    case collapsed
    case expanded
}

/// Входы машины состояний острова, снимаются при каждом обновлении.
public struct IslandInputs: Sendable, Equatable {
    /// Системный звук звучит выше порога активности.
    public var audioActive: Bool
    /// Источник сообщает, что воспроизведение идет.
    public var sourcePlaying: Bool
    /// Приложение-источник запущено.
    public var sourceRunning: Bool
    /// У источника есть последний известный трек.
    public var hasLastTrack: Bool
    /// Курсор в зоне наведения у выреза.
    public var pointerInHoverZone: Bool
    /// Остров подавлен полноэкранным окном.
    public var fullscreenSuppressed: Bool
    /// Пользователь поставил остров на паузу.
    public var userPaused: Bool

    public init(
        audioActive: Bool = false,
        sourcePlaying: Bool = false,
        sourceRunning: Bool = false,
        hasLastTrack: Bool = false,
        pointerInHoverZone: Bool = false,
        fullscreenSuppressed: Bool = false,
        userPaused: Bool = false
    ) {
        self.audioActive = audioActive
        self.sourcePlaying = sourcePlaying
        self.sourceRunning = sourceRunning
        self.hasLastTrack = hasLastTrack
        self.pointerInHoverZone = pointerInHoverZone
        self.fullscreenSuppressed = fullscreenSuppressed
        self.userPaused = userPaused
    }
}

/// Решает, скрыт остров, свернут или развернут.
///
/// Все задержки считаются от момента, когда условие стало истинным и держится непрерывно;
/// при смене условия отсчет сбрасывается. `now` растет монотонно, в секундах.
public struct IslandStateMachine: Sendable {
    public var hideDelay: Double
    public let expandDelay: Double
    public let collapseDelay: Double
    public private(set) var state: IslandState = .hidden

    private var contentFalseSince: Double?
    private var pointerInSince: Double?
    private var pointerOutSince: Double?

    public init(hideDelay: Double = 5, expandDelay: Double = 0.15, collapseDelay: Double = 0.3) {
        self.hideDelay = hideDelay
        self.expandDelay = expandDelay
        self.collapseDelay = collapseDelay
    }

    /// Когда состояние сменится по курсору, если входы не изменятся: раскрытие через
    /// `expandDelay` после входа в зону, сворачивание через `collapseDelay` после ухода.
    /// `nil`, если такого отсчета нет. По нему владелец вызывает `update` точно в срок, не
    /// дожидаясь своего тика.
    public var pointerDeadline: Double? {
        switch state {
        case .hidden, .collapsed:
            return pointerInSince.map { $0 + expandDelay }
        case .expanded:
            return pointerOutSince.map { $0 + collapseDelay }
        }
    }

    /// Возвращает новое состояние.
    @discardableResult
    public mutating func update(_ inputs: IslandInputs, now: Double) -> IslandState {
        if inputs.userPaused || inputs.fullscreenSuppressed {
            state = .hidden
            contentFalseSince = nil
            pointerInSince = nil
            pointerOutSince = nil
            return state
        }

        let content = inputs.audioActive || inputs.sourcePlaying
        let canExpand = content || (inputs.sourceRunning && inputs.hasLastTrack)

        contentFalseSince = content ? nil : (contentFalseSince ?? now)
        // Курсор, оставленный в вырезе, пока раскрывать было нечего, не копит время: с началом
        // музыки остров сначала выходит свернутым и раскрывается только через `expandDelay`.
        pointerInSince = inputs.pointerInHoverZone && canExpand ? (pointerInSince ?? now) : nil
        pointerOutSince = inputs.pointerInHoverZone ? nil : (pointerOutSince ?? now)

        if state == .hidden, content {
            state = .collapsed
        }

        switch state {
        case .hidden, .collapsed:
            if canExpand, let since = pointerInSince, elapsed(now, since, expandDelay) {
                state = .expanded
                pointerOutSince = nil
            } else if state == .collapsed, let since = contentFalseSince, elapsed(now, since, hideDelay) {
                state = .hidden
            }
        case .expanded:
            if let since = pointerOutSince, elapsed(now, since, collapseDelay) {
                state = content ? .collapsed : .hidden
                pointerInSince = nil
            }
        }
        return state
    }

    private func elapsed(_ now: Double, _ since: Double, _ delay: Double) -> Bool {
        now - since >= delay - 1e-9
    }
}
