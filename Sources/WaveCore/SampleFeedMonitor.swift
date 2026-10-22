/// Замечает, что в кольцо перестали поступать сэмплы (tap или демо встали). Новых шагов анализа
/// тогда нет, и без этого волны застыли бы на последнем кадре: анализ по сигналу монитора
/// публикует тихий кадр. Читатель передает `totalWritten` на каждом пробуждении; если счетчик
/// не менялся дольше `stallLimit`, звук считается тишиной.
public struct SampleFeedMonitor: Sendable {
    /// С запасом на большие буферы HAL: при буфере в несколько тысяч кадров блоки IOProc
    /// приходят примерно раз в 100 мс.
    public static let defaultStallLimit = 0.25

    public let stallLimit: Double
    private var lastTotal: Int?
    private var lastChange = 0.0

    public init(stallLimit: Double = SampleFeedMonitor.defaultStallLimit) {
        self.stallLimit = stallLimit
    }

    /// `true`, если новых сэмплов нет дольше `stallLimit` секунд. Первый вызов после создания
    /// или `reset()` только запоминает счетчик. Любое изменение счетчика, в том числе обнуление
    /// кольца при пересборке, считается новыми данными.
    public mutating func update(totalWritten: Int, now: Double) -> Bool {
        guard totalWritten == lastTotal else {
            lastTotal = totalWritten
            lastChange = now
            return false
        }
        return now - lastChange > stallLimit
    }

    public mutating func reset() {
        lastTotal = nil
    }
}
