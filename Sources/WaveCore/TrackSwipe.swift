/// Распознает горизонтальный свайп двумя пальцами над островом: пальцы влево дают следующий
/// трек, вправо предыдущий.
///
/// Жест длится от `began` до `ended`. Команда срабатывает, когда горизонтальный путь жеста
/// набрал `threshold` точек и в `dominance` раз больше вертикального. За жест не больше одной
/// команды, после команды `cooldown` секунд новые жесты молчат. Инерция (`momentum`) и колесо
/// мыши без фазы (`none`) игнорируются целиком и в путь жеста не идут. `cancelGesture()`
/// отменяет текущий жест: до следующего `began` (или конца отмененного жеста) события молчат.
public struct TrackSwipeDetector: Sendable {
    /// Фаза события прокрутки, приведенная приложением из `phase` и `momentumPhase`.
    public enum Phase: Sendable, Equatable {
        case began, changed, ended, momentum, none
    }

    public enum Command: Sendable, Equatable {
        case previous, next
    }

    /// Горизонтальный путь жеста до команды, точки.
    public static let threshold = 60.0
    /// Во сколько раз горизонтальный путь должен превышать вертикальный.
    public static let dominance = 2.0
    /// Секунды после команды, в которые новые жесты не срабатывают.
    public static let cooldown = 0.6

    private var inGesture = false
    private var firedInGesture = false
    private var pathX = 0.0
    private var pathY = 0.0
    private var lastCommandTime: Double?
    /// Жест отменен (`cancelGesture`): его остаток без `began` в путь не идет.
    private var awaitingBegin = false

    public init() {}

    /// `fingerDX > 0`: пальцы ушли вправо, уже без учета «естественной прокрутки» (приводит
    /// приложение). `dy` любого знака. `time` в секундах, растет монотонно. События с
    /// нечисловым сдвигом или временем пропускаются.
    public mutating func feed(fingerDX: Double, dy: Double, phase: Phase, time: Double) -> Command? {
        guard fingerDX.isFinite, dy.isFinite, time.isFinite else { return nil }
        switch phase {
        case .momentum, .none:
            return nil
        case .began:
            awaitingBegin = false
            startGesture()
        case .changed, .ended:
            if awaitingBegin {
                // Остаток отмененного жеста; его конец снимает ожидание.
                if phase == .ended { awaitingBegin = false }
                return nil
            }
            // Начало жеста потерялось: жест считается с первого пришедшего события.
            if !inGesture { startGesture() }
        }
        pathX += fingerDX
        pathY += dy
        let command = firedInGesture ? nil : command(at: time)
        if phase == .ended {
            inGesture = false
        }
        return command
    }

    /// Отменяет текущий жест (остров сменил состояние, `ended` мог потеряться). События без
    /// `began` после этого молчат, пока не придет `began` или `ended`. Пауза после последней
    /// команды (`cooldown`) остается: смена трека, которая сама меняет остров, второй команды
    /// не дает.
    public mutating func cancelGesture() {
        inGesture = false
        firedInGesture = false
        pathX = 0
        pathY = 0
        awaitingBegin = true
    }

    private mutating func startGesture() {
        inGesture = true
        firedInGesture = false
        pathX = 0
        pathY = 0
    }

    private mutating func command(at time: Double) -> Command? {
        guard abs(pathX) >= Self.threshold, abs(pathX) >= Self.dominance * abs(pathY) else { return nil }
        if let last = lastCommandTime, time - last < Self.cooldown {
            return nil
        }
        firedInGesture = true
        lastCommandTime = time
        return pathX < 0 ? .next : .previous
    }
}
