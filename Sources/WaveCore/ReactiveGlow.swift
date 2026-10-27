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
/// Второй источник это ноты баса (`HopResult.bassLevelDB`, мощность басового слоя, среднее 4 шагов): 808 без
/// удара (трек T2 журналов владельца: скользящие ноты, широкополосных онсетов на 51 долю 6-21) дает подъем
/// уровня, а не перепад потока. Событие ноты на шаге, где:
/// - подъем над минимумом прошлых `bassRiseWindow` секунд не меньше `bassRise` дБ;
/// - уровень не ниже максимума за `bassPeakWindow` секунд минус `bassRange` дБ и выше `minLevelDB`;
/// - подъем не меньше `bassSalience` × (медиана подъемов за `window` секунд + `bassRiseEpsilon` дБ): ровный
///   бас и шум дают много подъемов, и порог растет с ними (без этого бас розового шума светил бы на 99.7 %
///   кадров, с ним событий почти нет);
/// - прошлое событие ноты дальше `refractory`, прогрев как у потока.
/// Время это центр окна шага (`HopResult.frameTime`), сила `0.5 + 0.5 × smoothstep(8, 16, подъем)`.
///
/// `process` не выделяет памяти: кольца выделены в `init`, медианы считаются только на шагах-кандидатах
/// выбором Хоара (`BeatTracker.select`), максимум уровня за 4 с тоже.
public struct ReactiveGlow: Sendable {
    /// События шага: нота баса и акцент потока (оба могут быть, нота раньше по времени).
    public struct Events: Sendable, Equatable {
        public var bass: Event?
        public var accent: Event?

        public init(bass: Event? = nil, accent: Event? = nil) {
            self.bass = bass
            self.accent = accent
        }
    }

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
    /// Ноты баса: подъем, его окно, диапазон от максимума и его окно, выраженность.
    public static let bassRise: Float = 8
    public static let bassRiseFull: Float = 16
    public static let bassRiseWindow = 0.08
    public static let bassRange: Float = 15
    public static let bassPeakWindow = 4.0
    public static let bassSalience: Float = 6
    public static let bassRiseEpsilon: Float = 0.5
    /// Уровень баса сглаживается средним стольких шагов (последний и прошлые). Среднее берется по
    /// децибелам, а не по мощности: так считал прототип разбора (`variants.py`, `uniform_filter1d` по
    /// уровню в дБ), и все его числа и пороги (подъем 8 дБ, сила `smoothstep(8, 16, подъем)`) получены с ним.
    static let bassMeanHops = 4
    /// События ближе этого (секунды) сливаются в одно (`BeatTracker`): раннее время, большая сила.
    public static let mergeWindow = 0.08
    /// Яркость слоя в «Ритм и звук» относительно полной.
    public static let hybridScale: Float = 0.6
    /// «Ритм и звук» и сетка трекера (вариант d разбора, `BeatTracker` `reactiveGridScale`): событие ближе
    /// `gridWindow` секунд к предсказанной доле, которая вспыхнет (яркость выше
    /// `OfflineBeatChain.eventRise`), отбрасывается, этот удар уже показан долей. Остальные: на доле сетки
    /// (не дальше `gridWindow`) в своей яркости, на «и» с множителем `1 − halfDim × q`, в других местах
    /// `1 − offGridDim × q`, где `q = smoothstep(dimConfidenceLow, dimConfidenceHigh, уверенность)`. Без
    /// темпа событие не меняется. «По звуку» сетку не смотрит. Журналы владельца 1.3 (34 записи, 211 мс):
    /// вспышек в долю 0.683 -> 0.771, темнота 0.253 -> 0.272, яркие вспышки ровно те же, что «По ритму»
    /// (точность 0.966, раньше лишние 0.960); GTZAN tune ровные жанры при 20 мс: в долю 0.662 -> 0.768.
    /// Одно отбрасывание без приглушения дает 0.684 и 0.648.
    public static let gridWindow = 0.07
    public static let halfDim: Float = 0.6
    public static let offGridDim: Float = 0.9
    public static let dimConfidenceLow: Float = 0.1
    public static let dimConfidenceHigh: Float = 0.5

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
    /// Ноты баса: сырые уровни для среднего, сглаженные уровни (кольцо на 4 с), подъемы (кольцо на
    /// `medianHops`), шаг прошлого события.
    private let riseHops: Int
    private var bassRaw: [Float]
    private var bassLevels: [Float]
    private var rises: [Float]
    private var lastBassHop = Int.min / 2

    public init(framesPerSecond: Double) {
        precondition(framesPerSecond > 0, "framesPerSecond must be positive")
        let hop = 1 / framesPerSecond
        medianHops = max(Int(Self.window / hop), Self.localMaxHops)
        warmUpHops = Int(Self.warmUp / hop)
        refractoryHops = Int(Self.refractory / hop)
        peakFall = Float(exp(-hop / Self.peakRelease))
        history = [Float](repeating: 0, count: medianHops)
        scratch = [Float](repeating: 0, count: medianHops)
        riseHops = max(Int(Self.bassRiseWindow / hop), 1)
        bassRaw = [Float](repeating: 0, count: Self.bassMeanHops)
        bassLevels = [Float](repeating: 0, count: max(Int(Self.bassPeakWindow / hop), riseHops) + 1)
        rises = [Float](repeating: 0, count: medianHops)
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
        lastBassHop = Int.min / 2
    }

    /// Шаг анализа: функция онсетов `odf` (не отрицательная) и шаг `hop` (время, уровни). События, если
    /// шаг их дал.
    public mutating func process(_ hop: HopResult, odf: Float) -> Events {
        let value = odf.isFinite ? max(odf, 0) : 0
        defer {
            history[write] = value
            write = (write + 1) % history.count
            count = min(count + 1, history.count)
            hops += 1
        }
        let bass = bassNote(hop)
        return Events(bass: bass, accent: accent(hop, value: value))
    }

    /// Акцент широкополосной функции онсетов.
    private mutating func accent(_ hop: HopResult, value: Float) -> Event? {
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

    /// Нота баса. Кольца уровней и подъемов пишутся на каждом шаге (`hops` еще номер этого шага).
    private mutating func bassNote(_ hop: HopResult) -> Event? {
        let raw = hop.bassLevelDB.isFinite ? hop.bassLevelDB : -120
        bassRaw[hops % bassRaw.count] = raw
        let available = min(hops + 1, bassRaw.count)
        var sum: Float = 0
        for age in 0..<available {
            sum += bassRaw[(hops - age + bassRaw.count) % bassRaw.count]
        }
        let level = sum / Float(available)
        bassLevels[hops % bassLevels.count] = level
        var rise: Float = 0
        if hops >= riseHops {
            var low = Float.infinity
            for age in 1...riseHops {
                low = min(low, bassLevel(age: age))
            }
            rise = level - low
        }
        // Медиане нужны подъемы прошлых шагов: кольцо пишется после нее.
        defer { rises[hops % rises.count] = rise }
        guard hops >= warmUpHops, rise >= Self.bassRise, level > Self.minLevelDB, hops - lastBassHop >= refractoryHops else { return nil }
        var top = level
        for age in 1..<bassLevels.count where age <= hops {
            top = max(top, bassLevel(age: age))
        }
        guard level >= top - Self.bassRange else { return nil }
        let size = min(hops, rises.count)
        guard size > 0 else { return nil }
        for age in 1...size {
            scratch[age - 1] = rises[(hops - age + rises.count) % rises.count]
        }
        let median = scratch.withUnsafeMutableBufferPointer { buffer in
            BeatTracker.select(UnsafeMutableBufferPointer(rebasing: buffer[0..<size]), rank: size / 2)
        }
        guard rise >= Self.bassSalience * (median + Self.bassRiseEpsilon) else { return nil }
        lastBassHop = hops
        let strength = 0.5 + 0.5 * BeatTracker.smoothstep(Self.bassRise, Self.bassRiseFull, rise)
        return Event(time: hop.frameTime, strength: strength)
    }

    /// Сглаженный уровень баса `age` шагов назад (0 это этот шаг).
    private func bassLevel(age: Int) -> Float {
        bassLevels[(hops - age + bassLevels.count) % bassLevels.count]
    }

    /// Значение `age` шагов назад (1 это прошлый шаг).
    private func past(_ age: Int) -> Float {
        history[(write - age + history.count) % history.count]
    }

    /// Медиана прошлых значений (до `medianHops`).
    private mutating func median() -> Float {
        guard count > 0 else { return 0 }
        for age in 1...count {
            scratch[age - 1] = past(age)
        }
        let size = count
        return scratch.withUnsafeMutableBufferPointer { buffer in
            BeatTracker.select(UnsafeMutableBufferPointer(rebasing: buffer[0..<size]), rank: size / 2)
        }
    }
}
