/// Замечает, что в кольцо перестали поступать сэмплы. `SampleRingBuffer.copyLatest` этого не
/// видит: он отдает последнее окно снова и снова, и волны застывают в движении. Читатель
/// передает `totalWritten` на каждом шаге; если счетчик не менялся дольше `stallLimit`, звук
/// считается тишиной.
public struct SampleFeedMonitor: Sendable {
    public static let defaultStallLimit = 0.1

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
