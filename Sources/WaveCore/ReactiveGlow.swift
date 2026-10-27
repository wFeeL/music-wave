import Foundation

/// Реактивный слой свечения (`GlowMode.hybrid`, `sound`; разбор `2026-10-27-wavefeels-1.3-glow/analysis.md`
/// §3-§4): события на сильных атаках звука, без сетки и темпа, как волны. Источник это широкополосная
/// функция онсетов трекера (`HopResult.broadbandODF`): бочка, малый, хлопок и хэты, отобранные по
/// выраженности. На журналах владельца такие пики попадают в долю в 0.69 случаев (на «и» 0.22), полоса
/// баса, которую показывает басовая волна, только в 0.36.
///
/// Событие на шаге, где функция онсетов `d`:
/// - не ниже трех прошлых шагов (локальный максимум без заглядывания вперед) и выше `broadbandFloor`;
/// - не меньше `salience` × (медиана прошлых `window` секунд + `medianEpsilon`): в розовом шуме пики
///   функции не выделяются над своей медианой (отношение 6 давало 8-16 вспышек в минуту, 8 дает 0-2), тот
///   же принцип, что у подтверждения бочки (`BeatTracker` `kickConfirmation`);
/// - не меньше `relativePeak` от следящего пика со спадом `peakRelease` (сила `s = d / пик`);
/// - ближе `refractory` к прошлому событию только если сильнее его;
/// - после сброса прошло `warmUp` (медиане нужна история), самая громкая полоса шага от `minLevelDB`.
///
/// Время события это время онсета шага (`endTime − StreamAnalyzer.onsetLag`), сила
/// `0.5 + 0.5 × smoothstep(0.5, 1, s)`: полная яркость «По звуку», для «Ритм и звук» трекер умножает ее на
/// `hybridScale` (мягкие вспышки 0.3-0.6). Показ (`BeatGlow`) тот же, что у сетки: опережение, правило
/// опоздания, спад по периоду. События ближе `mergeWindow` трекер сливает в одно.
///
/// `process` не выделяет памяти: кольца выделены в `init`, медиана считается только на шагах-кандидатах
/// выбором Хоара (`BeatTracker.select`).
public struct ReactiveGlow: Sendable {
    /// Событие слоя: время на оси онсетов (секунды потока) и сила 0.5...1.
    public struct Event: Sendable, Equatable {
        public var time: Double
        public var strength: Float

        public init(time: Double, strength: Float) {
            self.time = time
            self.strength = strength
        }
    }

    /// Порог функции онсетов (нижний край порога онсетов `StreamAnalyzer.broadbandPickerParameters`).
    public static let broadbandFloor: Float = 4
    /// Выраженность: отношение к медиане за `window` секунд.
    public static let salience: Float = 8
    public static let medianEpsilon: Float = 0.001
    /// Окно медианы и прогрев после сброса, секунды.
    public static let window = 1.5
    public static let warmUp = 1.5
    /// Доля следящего пика и его спад (постоянная времени), секунды.
    public static let relativePeak: Float = 0.5
    public static let peakRelease = 4.0
    /// Ближе этого к прошлому событию новое только сильнее него, секунды.
    public static let refractory = 0.45
    /// Тише этого (самая громкая полоса шага, dBFS) событий нет.
    public static let minLevelDB: Float = -60
    /// Сколько прошлых шагов должны быть не выше шага события.
    static let localMaxHops = 3
    /// События ближе этого (секунды) сливаются в одно (`BeatTracker`): раннее время, большая сила.
    public static let mergeWindow = 0.08
    /// Яркость слоя в «Ритм и звук» относительно полной.
    public static let hybridScale: Float = 0.6

    private let medianHops: Int
    private let warmUpHops: Int
    private let refractoryHops: Int
    private let peakFall: Float
    /// Прошлые значения функции онсетов (кольцо на `medianHops`) и место под медиану.
    private var history: [Float]
    private var write = 0
    private var count = 0
    private var scratch: [Float]
    private var peak: Float = 0
    /// Шагов с прошлого сброса и шаг и сила функции у прошлого события.
    private var hops = 0
    private var lastHop = Int.min / 2
    private var lastValue: Float = 0

    public init(framesPerSecond: Double) {
        precondition(framesPerSecond > 0, "framesPerSecond must be positive")
        let hop = 1 / framesPerSecond
        medianHops = max(Int(Self.window / hop), Self.localMaxHops)
        warmUpHops = Int(Self.warmUp / hop)
        refractoryHops = Int(Self.refractory / hop)
        peakFall = Float(exp(-hop / Self.peakRelease))
        history = [Float](repeating: 0, count: medianHops)
        scratch = [Float](repeating: 0, count: medianHops)
    }

    /// Сброс вместе с трекером: история, пик и прогрев начинаются заново.
    public mutating func reset() {
        for index in history.indices { history[index] = 0 }
        write = 0
        count = 0
        peak = 0
        hops = 0
        lastHop = Int.min / 2
        lastValue = 0
    }

    /// Шаг анализа: функция онсетов `odf` (не отрицательная) и шаг `hop` (время и уровень). Событие, если
    /// шаг его дал.
    public mutating func process(_ hop: HopResult, odf: Float) -> Event? {
        let value = odf.isFinite ? max(odf, 0) : 0
        defer {
            history[write] = value
            write = (write + 1) % history.count
            count = min(count + 1, history.count)
            hops += 1
        }
        peak = max(peak * peakFall, value)
        guard value > Self.broadbandFloor, hops >= warmUpHops, hop.frame.rawLevelDB >= Self.minLevelDB else { return nil }
        for age in 1...Self.localMaxHops where age <= count && value < past(age) { return nil }
        let strength = value / peak
        guard strength >= Self.relativePeak else { return nil }
        if hops - lastHop < refractoryHops, value <= lastValue { return nil }
        guard value >= Self.salience * (median() + Self.medianEpsilon) else { return nil }
        lastHop = hops
        lastValue = value
        let brightness = 0.5 + 0.5 * BeatTracker.smoothstep(Self.relativePeak, 1, strength)
        return Event(time: hop.endTime - StreamAnalyzer.onsetLag, strength: brightness)
    }

    /// Значение `age` шагов назад (1 это прошлый шаг).
    private func past(_ age: Int) -> Float {
        history[(write - age + history.count) % history.count]
    }

    /// Медиана прошлых значений (до `medianHops`).
    private mutating func median() -> Float {
        for age in 1...count {
            scratch[age - 1] = past(age)
        }
        let size = count
        return scratch.withUnsafeMutableBufferPointer { buffer in
            BeatTracker.select(UnsafeMutableBufferPointer(rebasing: buffer[0..<size]), rank: size / 2)
        }
    }
}
