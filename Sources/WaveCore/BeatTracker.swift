import Foundation

/// Фаза доли, уверенность и события свечения (`beat-sync.md` 2.5-2.6).
///
/// Все времена в секундах потока: «сейчас» трекера это `hop.endTime` последнего шага, онсеты на той
/// же оси. На каждом шаге:
/// 1. широкополосная функция онсетов и функция бочки идут в `TempoEstimator`, каждые
///    `TempoEstimator.updateInterval` секунд потока берется оценка темпа, ее период становится
///    периодом ФАПЧ. Смена темпа ставит фазу заново по гребенке и сбрасывает уверенность (см. п. 4);
/// 2. при каждой оценке гребенка ищет задержку последней доли
///    `d* = argmax_{d ∈ [0, T)} Σ_{k=0..5} 0.75^k · max(ODF[n − d − kT ± 1 шаг])`, кандидат
///    `now − d* − StreamAnalyzer.onsetLag` лежит на оси онсетов. Если он расходится с ФАПЧ (разность по
///    кругу в `(−T/2, T/2]`) больше чем на `phaseJump · T` на `phaseJumpChecks` проверках подряд, ФАПЧ
///    прыгает на него с теми же последствиями, что и смена темпа;
/// 3. широкополосный онсет у ближайшей доли (в пределах `matchWindow · T`) подстраивает фазу
///    (`alpha`) и период (`beta`) и засчитывает долю. Онсеты бочки ФАПЧ не трогают, они дают только
///    события свечения;
/// 4. когда окно доли закрылось, уверенность сдвигается к попаданию или промаху на `confidenceGain`.
///    Захват при уверенности от `lockConfidence` и `lockHits` попаданиях подряд, отпускание ниже
///    `unlockConfidence`. Смена темпа и скачок фазы делят уверенность пополам, обнуляют счет попаданий
///    и отпускают захват (`beat-sync.md` 2.6);
/// 5. энергетический ворот: пик уровня бочки держится и спадает на `gateFallPerBeatDB` за долю (без
///    темпа `gateFallNoTempoDB` за 0.25 с), сравнивается со следящим пиком за 10 с,
///    `g_E = smoothstep(−24, −12, разность)`. Между бочками ворот открыт, в брейке закрывается;
/// 6. смесь `blend` идет к 1 за `crossfadeBeats` долей при захвате и к 0 без него.
///
/// События: две следующие предсказанные доли с яркостью `strengthEMA × g_E × blend` и id из счетчика
/// долей. Яркость ближайшей доли фиксируется, когда время потока доходит до нее: бочка на самой доле
/// не меняет уже начатую вспышку. Онсет бочки ближе `dropWindow · T` к предсказанной доле при
/// `blend > 0.5` отбрасывается, остальные светятся с яркостью
/// `clamp(strength, onsetFloor, 1) × ((1 − blend) + offGridScale × blend) × подтверждение` (см.
/// `kickConfirmation`) и id из своего счетчика со старшим битом. Прошедшие события остаются в
/// расписании (до 8), чтобы рендер довел их спад. Оба счетчика id только растут, в том числе через
/// `reset()` и смену темпа: `BeatGlow` помнит id 2 с.
///
/// `process` не выделяет памяти, `schedule` собирает новый массив событий при каждом чтении.
public struct BeatTracker: Sendable {
    public struct Parameters: Sendable, Equatable {
        /// Коэффициент ФАПЧ по фазе.
        public var alpha: Double
        /// Коэффициент ФАПЧ по периоду.
        public var beta: Double
        /// Окно совпадения онсета с долей, доля периода.
        public var matchWindow: Double
        /// Шаг уверенности к попаданию или промаху.
        public var confidenceGain: Double
        public var lockConfidence: Double
        /// Попаданий подряд для захвата.
        public var lockHits: Int
        public var unlockConfidence: Double
        /// Расхождение гребенки и ФАПЧ (доля периода), после которого фаза прыгает.
        public var phaseJump: Double
        /// Сколько проверок подряд расхождение должно держаться.
        public var phaseJumpChecks: Int
        /// Онсет бочки ближе этой доли периода к предсказанной доле не светится отдельно.
        public var dropWindow: Double
        /// Яркость онсета бочки вне сетки при захвате.
        public var offGridScale: Float
        /// Нижняя граница яркости онсета бочки.
        public var onsetFloor: Float
        /// За сколько долей смесь переходит между онсетами и предсказанием.
        public var crossfadeBeats: Double
        /// Спад удержания уровня бочки за долю, дБ.
        public var gateFallPerBeatDB: Float
        /// Спад удержания без темпа за 0.25 с, дБ.
        public var gateFallNoTempoDB: Float

        public init(
            alpha: Double = 0.25,
            beta: Double = 0.04,
            matchWindow: Double = 0.15,
            confidenceGain: Double = 0.25,
            lockConfidence: Double = 0.6,
            lockHits: Int = 4,
            unlockConfidence: Double = 0.35,
            phaseJump: Double = 0.12,
            phaseJumpChecks: Int = 2,
            dropWindow: Double = 0.2,
            offGridScale: Float = 0.6,
            onsetFloor: Float = 0.4,
            crossfadeBeats: Double = 2.0,
            gateFallPerBeatDB: Float = 14,
            gateFallNoTempoDB: Float = 6
        ) {
            self.alpha = alpha
            self.beta = beta
            self.matchWindow = matchWindow
            self.confidenceGain = confidenceGain
            self.lockConfidence = lockConfidence
            self.lockHits = lockHits
            self.unlockConfidence = unlockConfidence
            self.phaseJump = phaseJump
            self.phaseJumpChecks = phaseJumpChecks
            self.dropWindow = dropWindow
            self.offGridScale = offGridScale
            self.onsetFloor = onsetFloor
            self.crossfadeBeats = crossfadeBeats
            self.gateFallPerBeatDB = gateFallPerBeatDB
            self.gateFallNoTempoDB = gateFallNoTempoDB
        }
    }

    /// Старший бит id онсетов бочки.
    public static let onsetIDFlag: UInt64 = 1 << 63
    /// Сколько прошедших событий остается в расписании.
    static let pastCapacity = 8
    /// Зубцов гребенки фазы и вес каждого следующего (более старого).
    static let phaseTeeth = 5
    static let phaseToothWeight = 0.75
    /// Период до первой оценки темпа (для смеси).
    static let defaultPeriod = 0.5
    /// Шаг среднего силы совпавших онсетов.
    static let strengthGain: Float = 0.25
    /// Время спада следящего пика уровня бочки P_long.
    static let longRelease = 10.0
    /// Границы smoothstep ворота: удержание минус P_long, дБ.
    static let gateLowDB: Float = -24
    static let gateHighDB: Float = -12
    /// Подтверждение онсета бочки широкополосной функцией: отношение ее значения на шаге онсета (или
    /// шаге до него) к медиане за `confirmWindow` секунд плюс `confirmEpsilon` проходит через
    /// smoothstep от `confirmLow` до `confirmHigh`.
    static let confirmWindow = 1.5
    static let confirmEpsilon: Float = 0.5
    static let confirmLow: Float = 7
    static let confirmHigh: Float = 10
    private static let floorDB: Float = -120

    public let framesPerSecond: Double
    public let parameters: Parameters

    private var tempo: TempoEstimator
    private let hopDuration: Double
    /// Время потока следующей оценки темпа, `nil` до первого шага.
    private var nextUpdate: Double?
    /// «Сейчас», `endTime` последнего шага.
    private var now = 0.0

    /// Кольцо широкополосной функции онсетов для гребенки фазы.
    private var odfRing: [Float]
    private var odfWrite = 0
    private var odfCount = 0

    /// Период доли, секунды; `nil` до первой оценки темпа.
    private(set) var period: Double?
    /// Следующая предсказанная доля, окно совпадения которой еще открыто.
    private(set) var nextBeat: Double?
    private var nextMatched = false
    /// Яркость `nextBeat`, зафиксированная, когда время потока дошло до доли. Бочка на самой доле
    /// открывает ворот уже после того, как рендер начал вспышку; без фиксации яркость того же id
    /// выросла бы посреди вспышки и дала вторую.
    private var committedAmplitude: Float?
    private(set) var confidence = 0.0
    private(set) var hits = 0
    private(set) var locked = false
    private var disagreements = 0
    private var strengthEMA: Float = 0
    /// Id доли `nextBeat`, у `nextBeat + T` на 1 больше.
    private var beatCounter: UInt64 = 0
    private var onsetCounter: UInt64 = 0

    private var kickGateDB = BeatTracker.floorDB
    private var longPeakDB = BeatTracker.floorDB
    private let longFallPerHopDB: Float
    /// Энергетический ворот g_E последнего шага, 0...1.
    public private(set) var energyGate: Float = 0
    /// Смесь онсетов (0) и предсказанных долей (1).
    private(set) var blend: Float = 0

    /// Прошедшие события по времени, не больше `pastCapacity`.
    private var past: [GlowEvent]
    /// Шагов в окне медианы подтверждения и место под ее расчет.
    private let confirmHops: Int
    private var confirmScratch: [Float]

    public init(framesPerSecond: Double, parameters: Parameters = .init()) {
        precondition(framesPerSecond > 0, "framesPerSecond must be positive")
        self.framesPerSecond = framesPerSecond
        self.parameters = parameters
        hopDuration = 1 / framesPerSecond
        tempo = TempoEstimator(framesPerSecond: framesPerSecond)
        // Гребенке нужно (зубцов + 1) самых длинных периодов и шаг запаса; ФАПЧ может чуть вытянуть период.
        let longest = 1.1 * 60 / TempoEstimator.minBPM
        odfRing = [Float](repeating: 0, count: Int((Double(Self.phaseTeeth + 1) * longest * framesPerSecond).rounded(.up)) + 4)
        // Спад огибающей exp(−t / 10 с) в децибелах: 20 / ln 10 дБ на постоянную времени.
        longFallPerHopDB = Float(20 / log(10.0) / (Self.longRelease * framesPerSecond))
        past = []
        past.reserveCapacity(Self.pastCapacity + 1)
        confirmHops = max(Int((Self.confirmWindow * framesPerSecond).rounded()), 1)
        confirmScratch = [Float](repeating: 0, count: confirmHops)
    }

    /// Расписание в секундах потока: до 8 прошедших событий и две следующие предсказанные доли.
    public var schedule: BeatSchedule {
        var events = past
        if let nextBeat, let period {
            events.append(GlowEvent(id: beatCounter, time: nextBeat, amplitude: nextAmplitude, predicted: true))
            events.append(GlowEvent(id: beatCounter + 1, time: nextBeat + period, amplitude: predictedAmplitude, predicted: true))
        }
        events.sort { $0.time < $1.time }
        return BeatSchedule(
            events: events,
            bpm: period.map { 60 / $0 },
            period: period,
            confidence: confidence,
            locked: locked
        )
    }

    public mutating func process(_ hop: HopResult) {
        now = hop.endTime
        // Ворот и смесь здесь еще от прошлого шага, до звука самой доли.
        if committedAmplitude == nil, let nextBeat, now >= nextBeat {
            committedAmplitude = predictedAmplitude
        }
        let odf = hop.broadbandODF.isFinite ? max(hop.broadbandODF, 0) : 0
        tempo.append(odf, kick: hop.kickODF)
        odfRing[odfWrite] = odf
        odfWrite = (odfWrite + 1) % odfRing.count
        odfCount = min(odfCount + 1, odfRing.count)

        let interval = TempoEstimator.updateInterval
        if let due = nextUpdate, now >= due {
            // После долгого разрыва в потоке следующая оценка считается от «сейчас».
            nextUpdate = due + interval > now ? due + interval : now + interval
            if let estimate = tempo.update() {
                updateTempo(estimate)
            }
        } else if nextUpdate == nil {
            nextUpdate = now + interval
        }

        if let onset = hop.broadbandOnset {
            correct(with: onset)
        }
        closeWindows()
        updateGate(hop.kickLevelDB)
        updateBlend()
        if let onset = hop.kickOnset {
            addKickOnset(onset)
        }
    }

    /// Пауза, перемотка или смена источника: темп, фаза, уверенность и ворот начинаются заново.
    /// Счетчики id не сбрасываются, новые доли получают новые id.
    public mutating func reset() {
        tempo.reset()
        nextUpdate = nil
        now = 0
        for index in odfRing.indices {
            odfRing[index] = 0
        }
        odfWrite = 0
        odfCount = 0
        period = nil
        nextBeat = nil
        nextMatched = false
        committedAmplitude = nil
        confidence = 0
        hits = 0
        locked = false
        disagreements = 0
        strengthEMA = 0
        beatCounter += 2
        kickGateDB = Self.floorDB
        longPeakDB = Self.floorDB
        energyGate = 0
        blend = 0
        past.removeAll(keepingCapacity: true)
    }

    // MARK: Темп и фаза

    private mutating func updateTempo(_ estimate: TempoEstimate) {
        period = estimate.period
        let candidate = phaseCandidate(period: estimate.period)
        guard let nextBeat, !estimate.switched else {
            if nextBeat != nil { resetConfidence() }
            if let candidate { rephase(to: candidate) }
            return
        }
        guard let candidate else { return }
        let diff = Self.circularDifference(candidate - nextBeat, period: estimate.period)
        if abs(diff) > parameters.phaseJump * estimate.period {
            disagreements += 1
            if disagreements >= parameters.phaseJumpChecks {
                resetConfidence()
                rephase(to: candidate)
            }
        } else {
            disagreements = 0
        }
    }

    /// Смена темпа или скачок фазы: уверенность вдвое, счет попаданий заново, захват отпущен
    /// (`beat-sync.md` 2.6), новый захват снова требует `lockHits` попаданий подряд.
    private mutating func resetConfidence() {
        confidence *= 0.5
        hits = 0
        locked = false
    }

    /// Новая фаза: первая доля сетки `candidate` после «сейчас», новые id. Доля, которая уже началась,
    /// уходит в прошедшие события, чтобы рендер довел ее спад.
    private mutating func rephase(to candidate: Double) {
        guard let period else { return }
        if let nextBeat, nextBeat <= now {
            archive(GlowEvent(id: beatCounter, time: nextBeat, amplitude: nextAmplitude, predicted: true))
        }
        let steps = ((now - candidate) / period).rounded(.down) + 1
        nextBeat = candidate + max(steps, 0) * period
        nextMatched = false
        committedAmplitude = nil
        disagreements = 0
        beatCounter += 2
    }

    /// Время последней доли по гребенке на оси онсетов, `nil` без энергии в истории.
    private func phaseCandidate(period: Double) -> Double? {
        let periodHops = period * framesPerSecond
        let delays = max(Int(periodHops.rounded()), 1)
        var best = -1.0
        var bestDelay = 0
        for delay in 0..<delays {
            var score = 0.0
            var weight = 1.0
            for tooth in 0...Self.phaseTeeth {
                let center = delay + Int((Double(tooth) * periodHops).rounded())
                var peak: Float = 0
                for age in max(center - 1, 0)...(center + 1) {
                    peak = max(peak, odf(age: age))
                }
                score += weight * Double(peak)
                weight *= Self.phaseToothWeight
            }
            if score > best {
                best = score
                bestDelay = delay
            }
        }
        guard best > 0 else { return nil }
        return now - Double(bestDelay) * hopDuration - StreamAnalyzer.onsetLag
    }

    /// Широкополосная функция онсетов `age` шагов назад (0 это последний шаг), 0 вне истории.
    private func odf(age: Int) -> Float {
        guard age < odfCount else { return 0 }
        return odfRing[(odfWrite - 1 - age + 2 * odfRing.count) % odfRing.count]
    }

    /// Разность по кругу периода в `(−T/2, T/2]`.
    static func circularDifference(_ difference: Double, period: Double) -> Double {
        var wrapped = difference - (difference / period).rounded() * period
        if wrapped <= -period / 2 { wrapped += period }
        if wrapped > period / 2 { wrapped -= period }
        return wrapped
    }

    // MARK: ФАПЧ и уверенность

    private mutating func correct(with onset: OnsetEvent) {
        guard let nextBeat, let period else { return }
        let previous = nextBeat - period
        let isNext = abs(onset.time - nextBeat) <= abs(onset.time - previous)
        let error = onset.time - (isNext ? nextBeat : previous)
        guard abs(error) < parameters.matchWindow * period else { return }
        self.nextBeat = nextBeat + parameters.alpha * error
        self.period = period + parameters.beta * error
        if isNext { nextMatched = true }
        let strength = onset.strength.isFinite ? min(max(onset.strength, 0), 1) : 0
        strengthEMA += Self.strengthGain * (strength - strengthEMA)
    }

    private mutating func closeWindows() {
        while let nextBeat, let period, now > nextBeat + parameters.matchWindow * period {
            let hit = nextMatched ? 1.0 : 0.0
            confidence += parameters.confidenceGain * (hit - confidence)
            hits = nextMatched ? hits + 1 : 0
            if locked {
                locked = confidence >= parameters.unlockConfidence
            } else {
                locked = confidence >= parameters.lockConfidence && hits >= parameters.lockHits
            }
            archive(GlowEvent(id: beatCounter, time: nextBeat, amplitude: nextAmplitude, predicted: true))
            self.nextBeat = nextBeat + period
            nextMatched = false
            committedAmplitude = nil
            beatCounter += 1
        }
    }

    // MARK: Ворот, смесь и события

    private mutating func updateGate(_ levelDB: Float) {
        let level = levelDB.isNaN ? Self.floorDB : max(levelDB, Self.floorDB)
        let fall: Float
        if let period {
            fall = parameters.gateFallPerBeatDB * Float(hopDuration / period)
        } else {
            fall = parameters.gateFallNoTempoDB * Float(hopDuration / TempoEstimator.updateInterval)
        }
        kickGateDB = max(level, kickGateDB - fall)
        longPeakDB = max(level, longPeakDB - longFallPerHopDB)
        energyGate = Self.smoothstep(Self.gateLowDB, Self.gateHighDB, kickGateDB - longPeakDB)
    }

    private mutating func updateBlend() {
        let step = Float(hopDuration / (parameters.crossfadeBeats * (period ?? Self.defaultPeriod)))
        blend = locked ? min(blend + step, 1) : max(blend - step, 0)
    }

    private var predictedAmplitude: Float {
        strengthEMA * energyGate * blend
    }

    /// Яркость `nextBeat`: зафиксированная или текущая.
    private var nextAmplitude: Float {
        committedAmplitude ?? predictedAmplitude
    }

    private mutating func addKickOnset(_ onset: OnsetEvent) {
        if blend > 0.5, let nextBeat, let period {
            let distance = min(abs(onset.time - nextBeat), abs(onset.time - (nextBeat - period)))
            if distance < parameters.dropWindow * period { return }
        }
        let strength = onset.strength.isFinite ? min(max(onset.strength, parameters.onsetFloor), 1) : parameters.onsetFloor
        let amplitude = strength * ((1 - blend) + parameters.offGridScale * blend) * kickConfirmation()
        guard amplitude > 0 else { return }
        archive(GlowEvent(id: Self.onsetIDFlag | onsetCounter, time: onset.time, amplitude: amplitude, predicted: false))
        onsetCounter += 1
    }

    /// Насколько онсет бочки похож на удар, а не на всплеск шума в трех бинах бочки, 0...1.
    ///
    /// У настоящей бочки (и в тихой музыке на -30 dBFS) широкополосная функция на шаге онсета в десятки
    /// раз выше своей медианы: между ударами лог-поток почти нулевой. Ложный онсет в розовом шуме
    /// (около 0.17 в секунду на -20 dBFS, `OnlinePeakPicker` бочки их пропускает) широкополосно не
    /// выделяется: отношение 3-7 при любом уровне шума. Без подтверждения такие онсеты светились бы
    /// без захвата, когда трекер еще не знает, что ритма нет.
    private mutating func kickConfirmation() -> Float {
        let count = min(confirmHops, odfCount - 1)
        guard count > 0 else { return 1 }
        // Возраст 0 это шаг онсета; медиана по шагам до него.
        for age in 1...count {
            confirmScratch[age - 1] = odf(age: age)
        }
        let median = confirmScratch.withUnsafeMutableBufferPointer { buffer in
            Self.select(UnsafeMutableBufferPointer(rebasing: buffer[0..<count]), rank: count / 2)
        }
        let ratio = max(odf(age: 0), odf(age: 1)) / (median + Self.confirmEpsilon)
        return Self.smoothstep(Self.confirmLow, Self.confirmHigh, ratio)
    }

    private mutating func archive(_ event: GlowEvent) {
        let index = past.lastIndex { $0.time <= event.time }.map { $0 + 1 } ?? 0
        past.insert(event, at: index)
        if past.count > Self.pastCapacity {
            past.removeFirst()
        }
    }

    /// Элемент ранга `rank` (с нуля, по возрастанию), выбор Хоара на месте без выделения памяти.
    /// Порядок элементов буфера меняется.
    static func select(_ buffer: UnsafeMutableBufferPointer<Float>, rank: Int) -> Float {
        var low = 0
        var high = buffer.count - 1
        while low < high {
            let pivot = buffer[(low + high) / 2]
            var i = low
            var j = high
            while i <= j {
                while buffer[i] < pivot { i += 1 }
                while buffer[j] > pivot { j -= 1 }
                if i <= j {
                    buffer.swapAt(i, j)
                    i += 1
                    j -= 1
                }
            }
            if rank <= j {
                high = j
            } else if rank >= i {
                low = i
            } else {
                break
            }
        }
        return buffer[rank]
    }

    static func smoothstep(_ low: Float, _ high: Float, _ x: Float) -> Float {
        let t = min(max((x - low) / (high - low), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
