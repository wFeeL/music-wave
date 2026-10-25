import Foundation

/// Почему трекер потерял захват: смена темпа, скачок фазы по гребенке, уверенность упала ниже
/// `unlockConfidence` от промахов или трекер сброшен посреди захвата (`reset()` на паузе, перемотке,
/// смене источника, `reconfigure` на смене частоты) (`BeatTracker.lastUnlockReason`). Пишется в
/// расписание, журнал ритма и сводку `wave-eval`; офлайн-цепочка трекер не сбрасывает.
public enum UnlockReason: String, Sendable, Codable, CodingKeyRepresentable {
    case tempoSwitch, phaseJump, misses, reset
}

/// Фаза доли, уверенность и события свечения (`beat-sync.md` 2.5-2.6).
///
/// Все времена в секундах потока: «сейчас» трекера это `hop.endTime` последнего шага, онсеты на той
/// же оси. На каждом шаге:
/// 1. широкополосная функция онсетов и функция бочки идут в `TempoEstimator`, каждые
///    `TempoEstimator.updateInterval` секунд потока берется оценка темпа, ее период становится
///    периодом ФАПЧ. Смена темпа ставит фазу заново по гребенке и сбрасывает уверенность (см. п. 4),
///    кроме смены на близкий, удвоенный или половинный период с долями на прежних местах (`carry`);
/// 2. при каждой оценке гребенка ищет задержку последней доли
///    `d* = argmax_{d ∈ [0, T)} Σ_{k=0..5} 0.75^k · max(ODF[n − d − kT ± 1 шаг])`, кандидат
///    `now − d* − StreamAnalyzer.onsetLag` лежит на оси онсетов. Если он расходится с ФАПЧ (разность по
///    кругу в `(−T/2, T/2]`) больше чем на `phaseJump · T`, а его оценка выше оценки гребенки у фазы
///    ФАПЧ больше чем на `phaseJumpMargin`, на `phaseJumpChecks` проверках подряд, ФАПЧ прыгает на него
///    с теми же последствиями, что и смена темпа;
/// 3. широкополосный онсет у ближайшей доли (в пределах `matchWindow · T`) подстраивает фазу
///    (`alpha`) и период (`beta`) и засчитывает долю. Онсеты бочки ФАПЧ не трогают, они дают только
///    события свечения;
/// 4. когда окно доли закрылось, уверенность сдвигается к попаданию или промаху на `confidenceGain`.
///    Захват при уверенности от `lockConfidence` и `lockHits` попаданиях подряд, отпускание ниже
///    `unlockConfidence`. Смена темпа на другую сетку и скачок фазы делят уверенность пополам, обнуляют
///    счет попаданий и отпускают захват (`beat-sync.md` 2.6). Причина последней потери захвата в
///    `lastUnlockReason`;
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
        /// Захват при уверенности от `lockConfidence` и `lockHits` попаданиях подряд. Серия попаданий
        /// отсекает неверную фазу лучше уровня уверенности: на неверной фазе широкополосный онсет есть
        /// примерно у 25-40 % долей, на верной у 55-75 %, поэтому пять подряд на неверной редки. На GTZAN
        /// файлов с захватом в основном мимо долей при 2 попаданиях было 33, при 4 20, при 5 16; доля
        /// времени с захватом при этом 0.50, 0.38 и 0.33 (`wave-eval`, столбцы wrongLock и lockedCov).
        public var lockConfidence: Double
        /// Попаданий подряд для захвата.
        public var lockHits: Int
        public var unlockConfidence: Double
        /// Расхождение гребенки и ФАПЧ (доля периода), после которого фаза прыгает.
        public var phaseJump: Double
        /// Сколько проверок подряд расхождение должно держаться.
        public var phaseJumpChecks: Int
        /// Расхождение засчитывается, только когда оценка гребенки у кандидата выше оценки у фазы ФАПЧ
        /// больше чем на эту долю: почти равные фазы (доля и «и» с громким хэтом) не перебрасывают ФАПЧ.
        /// Без запаса на GTZAN скачки чаще уводили верную фазу, чем исправляли неверную.
        public var phaseJumpMargin: Double
        /// Онсет бочки ближе этой доли периода к предсказанной доле не светится отдельно.
        public var dropWindow: Double
        /// Яркость онсета бочки вне сетки при захвате. Не выше порога вспышки `OfflineBeatChain.eventRise`
        /// (0.2): при захвате бочка между долями дает слабый отблеск, а не вспышку мимо доли. На GTZAN
        /// такие вспышки при 0.6 попадали в долю в 21 % случаев и тянули точность захвата с 0.93 до 0.82.
        public var offGridScale: Float
        /// Нижняя граница яркости онсета бочки.
        public var onsetFloor: Float
        /// За сколько долей смесь переходит между онсетами и предсказанием. Одна доля: после отпускания
        /// предсказанные доли с неверной фазой гаснут быстрее (на GTZAN такие вспышки попадали в долю в
        /// 65 % случаев против 90 % у захваченных).
        public var crossfadeBeats: Double
        /// Переключение темпа в оценке не сбрасывает уверенность, когда новый период отличается от
        /// прежнего, его удвоенного или половинного меньше чем на эту долю, а гребенка на новом
        /// периоде видит доли на прежних местах (`carry`). 0 выключает перенос. 10 % как окно дрейфа
        /// октавы в `TempoEstimator`; далекая смена близкого темпа начинается от 6 %
        /// (`followTolerance`), в журнале 2 владельца это 6.1 %. На GTZAN tune от 6 до 10 % числа одни.
        public var carryTolerance: Double
        /// При близкой смене темпа (не октава) гребенка может стоять дальше `phaseJump` от доли ФАПЧ:
        /// пока период был неверен, ФАПЧ отставала (журнал 2: 0.18 периода). До этой доли периода
        /// уверенность переносится и фаза берется у гребенки; четверть периода никогда не «и».
        public var carryPhase: Double
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
            lockHits: Int = 5,
            unlockConfidence: Double = 0.25,
            phaseJump: Double = 0.12,
            phaseJumpChecks: Int = 2,
            phaseJumpMargin: Double = 0.35,
            dropWindow: Double = 0.2,
            offGridScale: Float = 0.2,
            onsetFloor: Float = 0.4,
            crossfadeBeats: Double = 1.0,
            carryTolerance: Double = 0.10,
            carryPhase: Double = 0.25,
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
            self.phaseJumpMargin = phaseJumpMargin
            self.dropWindow = dropWindow
            self.offGridScale = offGridScale
            self.onsetFloor = onsetFloor
            self.crossfadeBeats = crossfadeBeats
            self.carryTolerance = carryTolerance
            self.carryPhase = carryPhase
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
    /// smoothstep от `confirmLow` до `confirmHigh`. Границы 7 и 11 (в 1.0 6 и 9): в плотной музыке
    /// онсет бочки с отношением ниже около 9 чаще бас или том между долями; на GTZAN точность вспышек
    /// без захвата 0.594 -> 0.602, всех вспышек 0.822 -> 0.839. Строже (9 и 14, 12 и 18) драм-н-бейс в
    /// розовом шуме теряет вспышки на бочках (`dnbInLouderNoiseGlowsOnKicksOnAverage`).
    static let confirmWindow = 1.5
    static let confirmEpsilon: Float = 0.5
    static let confirmLow: Float = 7
    static let confirmHigh: Float = 11
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
    /// Почему захват потерян в последний раз; `nil`, если захвата еще не было (и после `reset()` без
    /// захвата). Меняется только при потере захвата: смена темпа без захвата причину не трогает,
    /// `reset()` и `reconfigure` посреди захвата дают `.reset`.
    public internal(set) var lastUnlockReason: UnlockReason?
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
            locked: locked,
            unlockReason: locked ? nil : lastUnlockReason
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
        lastUnlockReason = locked ? .reset : nil
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

    /// Новая частота шагов (смена частоты дискретизации): все состояние начинается заново, как после
    /// `reset()`, а счетчики id продолжают расти, чтобы `BeatGlow` не принял новые события за старые.
    /// Захват, который был, теряется с причиной `.reset`.
    public mutating func reconfigure(framesPerSecond: Double) {
        precondition(framesPerSecond > 0, "framesPerSecond must be positive")
        let beats = beatCounter
        let onsets = onsetCounter
        let wasLocked = locked
        self = BeatTracker(framesPerSecond: framesPerSecond, parameters: parameters)
        beatCounter = beats + 2
        onsetCounter = onsets
        if wasLocked { lastUnlockReason = .reset }
    }

    // MARK: Темп и фаза

    /// Новая оценка темпа (внутренняя, чтобы тесты подавали смену темпа напрямую).
    mutating func updateTempo(_ estimate: TempoEstimate) {
        // Период ФАПЧ каждые 0.25 с заменяется оценкой темпа, поэтому поправки `beta` между оценками
        // не накапливаются и петля ведет себя как петля первого порядка: ошибка оценки периода δ за
        // долю оставляет постоянный сдвиг фазы около δ / alpha (на 120 BPM оценка 0.4989 с вместо
        // 0.5 с, доли предсказываются примерно на 5 мс раньше онсетов). Это укладывается в допуск
        // среднего сдвига; если понадобится убрать смещение, оценка должна подтягивать T, а не
        // заменять его (`beat-sync.md` 2.5).
        let previous = period
        period = estimate.period
        let comb = phaseCandidate(period: estimate.period, current: estimate.switched ? nil : nextBeat)
        guard let nextBeat, !estimate.switched else {
            if let nextBeat, let previous, let comb, carry(from: previous, next: nextBeat, comb: comb.time) { return }
            if nextBeat != nil { resetConfidence(.tempoSwitch) }
            if let comb { rephase(to: comb.time) }
            return
        }
        guard let comb else { return }
        let diff = Self.circularDifference(comb.time - nextBeat, period: estimate.period)
        let stronger = comb.score > (1 + parameters.phaseJumpMargin) * comb.currentScore
        if abs(diff) > parameters.phaseJump * estimate.period, stronger {
            disagreements += 1
            if disagreements >= parameters.phaseJumpChecks {
                resetConfidence(.phaseJump)
                rephase(to: comb.time)
            }
        } else {
            disagreements = 0
        }
    }

    /// Смена темпа на близкий (до `carryTolerance`), удвоенный или половинный период, при которой
    /// гребенка на новом периоде видит доли там же, где ФАПЧ (до `phaseJump` меньшего периода):
    /// сетка та же, поэтому уверенность, счет попаданий и захват остаются, а следующая доля не
    /// двигается. При половинном темпе гребенка выбирает, какая из двух долей остается; если не
    /// `nextBeat`, сетка начинается со следующей. При близком темпе гребенка дальше `phaseJump`, но
    /// не дальше `carryPhase` периода, дает новую фазу с той же уверенностью. `true`, если смена
    /// перенесена.
    private mutating func carry(from previous: Double, next: Double, comb: Double) -> Bool {
        guard let period else { return false }
        let ratio = period / previous
        let tolerance = parameters.carryTolerance
        let near = abs(ratio - 1) < tolerance
        let faster = abs(2 * ratio - 1) < tolerance
        let slower = abs(ratio / 2 - 1) < tolerance
        guard near || faster || slower else { return false }
        let modulus = min(period, previous)
        let offset = Self.circularDifference(comb - next, period: modulus)
        if near, abs(offset) > parameters.phaseJump * modulus, abs(offset) <= parameters.carryPhase * modulus {
            rephase(to: comb)
            disagreements = 0
            return true
        }
        guard abs(offset) <= parameters.phaseJump * modulus else { return false }
        if slower, abs(Self.circularDifference(comb - next, period: period)) > parameters.phaseJump * period {
            rephase(to: next + previous)
        }
        disagreements = 0
        return true
    }

    /// Смена темпа или скачок фазы: уверенность вдвое, счет попаданий заново, захват отпущен
    /// (`beat-sync.md` 2.6), новый захват снова требует `lockHits` попаданий подряд. `reason`
    /// запоминается, только если захват был.
    private mutating func resetConfidence(_ reason: UnlockReason) {
        confidence *= 0.5
        hits = 0
        if locked { lastUnlockReason = reason }
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

    /// Время последней доли по гребенке на оси онсетов и ее оценка, `nil` без энергии в истории.
    /// `currentScore` это оценка гребенки у фазы доли `current` (0 без нее).
    private func phaseCandidate(period: Double, current: Double?) -> (time: Double, score: Double, currentScore: Double)? {
        let periodHops = period * framesPerSecond
        let delays = max(Int(periodHops.rounded()), 1)
        var best = -1.0
        var bestDelay = 0
        for delay in 0..<delays {
            let score = combScore(delay: delay, periodHops: periodHops)
            if score > best {
                best = score
                bestDelay = delay
            }
        }
        guard best > 0 else { return nil }
        var currentScore = 0.0
        if let current {
            // Задержка доли ФАПЧ от «сейчас» на оси онсетов, по кругу периода. Шаг онсета лежит от доли
            // ФАПЧ до шага в любую сторону, поэтому берется лучшая из трех соседних задержек.
            let age = (now - StreamAnalyzer.onsetLag - current) / hopDuration
            let wrapped = Int((age - (age / periodHops).rounded(.down) * periodHops).rounded())
            for delay in (wrapped - 1)...(wrapped + 1) {
                currentScore = max(currentScore, combScore(delay: (delay + delays) % delays, periodHops: periodHops))
            }
        }
        return (now - Double(bestDelay) * hopDuration - StreamAnalyzer.onsetLag, best, currentScore)
    }

    /// Оценка гребенки фазы для задержки `delay` шагов: зубцы через `periodHops`, у каждого максимум
    /// функции онсетов в ±1 шаге, вес каждого следующего зубца `phaseToothWeight` от предыдущего.
    private func combScore(delay: Int, periodHops: Double) -> Double {
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
        return score
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
                if !locked { lastUnlockReason = .misses }
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
        // Бесконечность и NaN считаются полом, иначе удержание и P_long застряли бы на бесконечности.
        let level = levelDB.isFinite ? max(levelDB, Self.floorDB) : Self.floorDB
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
    /// выделяется: отношение не выше примерно 5.5 при любом уровне шума. Без подтверждения такие
    /// онсеты светились бы без захвата, когда трекер еще не знает, что ритма нет.
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
