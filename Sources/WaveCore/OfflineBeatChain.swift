import Foundation

/// Цепочка свечения целиком, но офлайн и на готовых сэмплах: блоки IOProc с метками времени хоста,
/// `HostClock`, пробуждения анализа по шагам, `StreamAnalyzer` и `BeatTracker`, публикация расписания
/// на ось хоста, рендер с `BeatGlow` на момент показа кадра (`beat-sync.md` 3.2). Нужна, чтобы мерить
/// попадание вспышек в долю на записанной музыке без устройства и приложения.
///
/// Время хоста сэмпла n: `hostStart + n / rate`. Блок `[k·chunk, (k+1)·chunk)` приходит в момент
/// своего последнего сэмпла плюс дрожание и несет метку своего первого сэмпла плюс дрожание. Анализ
/// просыпается с частотой `wakeRate` (случайная фаза, дрожание), обрабатывает все полные шаги,
/// пришедшие к этому моменту, и публикует расписание, сдвинутое на
/// `hostClock(n) − n / rate + outputLatency + syncOffset`. Рендер с частотой `renderRate` (фаза
/// `renderPhase` или случайная) в момент `tEval` берет последнее расписание, опубликованное до него,
/// и считает свечение на момент показа `tP = tEval + presentationLead` (без него `2 / renderRate`: экран
/// с частотой рендера). Событие свечения это кадр, где
/// свечение выросло больше чем на `eventRise` против прошлого кадра; его время это `tP` кадра.
/// Мягкий пульс (`Config.softPulse`) считается отдельно, как у приложения: энергия атак каждого шага
/// (`BeatTracker.ambientEnergy`) публикуется кадром в `FrameStore` на момент центра окна плюс
/// `outputLatency + syncOffset` (как кадры волн у `AnalysisEngine`), рендер берет кадр на `tP` и
/// `BeatGlow.ambient(at:info:frame:)`. Во вспышки пульс не входит, только в итог пульса
/// (`Result.peakAmbient`, `ambientFrames`, `ambientTrace`).
///
/// Ось времени. Все времена результата отсчитываются от первого сэмпла (хост сдвинут на `hostStart`
/// и вычтен обратно). Вспышки и онсеты бочки даны на слышимой оси: момент звука t в файле слышен в
/// `t + outputLatency`, поэтому аннотации долей из файла сравниваются с ними после прибавления
/// `outputLatency` (`Result.audible(_:)`). Вспышка, попавшая точно в звук, имеет время
/// `t + outputLatency`; `syncOffset` сдвигает вспышку относительно звука и в ось не входит. Исключение
/// `State.time`: это момент публикации расписания по часам хоста, без задержки вывода.
///
/// Анализ от фазы рендера не зависит, поэтому `run(samples:sampleRate:config:renderPhases:)` прогоняет
/// его один раз и показывает на нескольких фазах.
public struct OfflineBeatChain: Sendable {
    private init() {}

    public struct Config: Sendable {
        /// Размер блока IOProc в сэмплах.
        public var chunk = 512
        /// Дрожание прихода и метки блока, секунды.
        public var chunkJitter = 0.0003
        /// Частота пробуждений анализа, Гц.
        public var wakeRate = 120.0
        public var wakeJitter = 0.002
        /// Частота кадров рендера, Гц.
        public var renderRate = 60.0
        /// Упреждение показа, секунды: `tP = tEval + presentationLead`. `nil` (и не конечное или
        /// отрицательное) дает `2 / renderRate`, как у экрана с частотой рендера. Прогон журнала берет его
        /// из `RhythmLog.Meta.presentationLead`: с 1.3 упреждение идет от периода экрана, а не кадров.
        public var presentationLead: Double?
        /// Фаза рендера в долях периода кадра, 0..<1; `nil` берет случайную по `seed`.
        public var renderPhase: Double?
        /// Задержка вывода, секунды: на столько слышимый момент позже момента в файле.
        public var outputLatency = 0.020
        /// Ручной сдвиг вспышек, секунды (плюс это позже).
        public var syncOffset = 0.0
        public var trackerParameters = BeatTracker.Parameters()
        /// Считать мягкий пульс на кадрах рендера (итог в `Result`); на вспышки не влияет.
        public var softPulse = false
        /// С `softPulse`: писать пульс каждого кадра в `Result.ambientTrace` (проверки времени энергии).
        public var recordAmbientTrace = false
        /// Сброс с памятью темпа каждые столько секунд потока, как у приложения после паузы, скрытия острова
        /// или пересборки tap в том же треке: `StreamAnalyzer.reset(keepOnsetFloor: true)` и
        /// `BeatTracker.reset(keepTempo: true)` после шага, на котором время потока дошло до срока. Звук идет
        /// без разрыва. `nil` без сбросов (оценка возобновления, `wave-eval --reset-every`).
        public var resetInterval: Double?
        /// Со сбросом по `resetInterval` начинать заново и анализ (`StreamAnalyzer.reset()`: функции онсетов,
        /// выбор пиков, уровни), как приложение на паузе, после простоя и пересборки tap. `false` сбрасывает
        /// только трекер, как пробный прогон разбора 1.2.1 (`evalreset.py`).
        public var resetAnalyzer = true
        /// Звук после тишины тот же трек (`BeatTracker.keepsTempoAfterSilence`): как пауза плеера в
        /// известном треке у приложения. По умолчанию false, как у всего звука системы.
        public var keepTempoAfterSilence = false
        /// Режим свечения трекера (`BeatTracker.glowMode`).
        public var glowMode = GlowMode.rhythm
        public var seed: UInt64

        public init(seed: UInt64 = 1) {
            self.seed = seed
        }
    }

    /// Вспышка: кадр, на котором свечение выросло больше чем на `eventRise`.
    public struct Flash: Sendable, Equatable {
        /// Момент показа кадра, слышимые секунды от первого сэмпла.
        public var time: Double
        /// Вспышку дала предсказанная доля (иначе онсет бочки или реактивное событие).
        public var predicted: Bool
        /// Расписание на этом кадре было с захватом.
        public var locked: Bool
        /// Вспышку дало реактивное событие (`GlowEvent.reactive`); оценка, как `predicted`.
        public var reactive: Bool
        /// Наибольшее свечение на кадре вспышки и следующем (яркая или мягкая вспышка).
        public var peak: Float

        public init(time: Double, predicted: Bool, locked: Bool, reactive: Bool = false, peak: Float = 0) {
            self.time = time
            self.predicted = predicted
            self.locked = locked
            self.reactive = reactive
            self.peak = peak
        }
    }

    /// Опубликованное состояние трекера.
    public struct State: Sendable, Equatable {
        /// Время публикации по часам хоста, секунды от первого сэмпла (без задержки вывода).
        public var time: Double
        public var locked: Bool
        public var bpm: Double?
        public var confidence: Double
        /// Почему захват потерян (`BeatSchedule.unlockReason`); `nil` с захватом и до первого захвата.
        public var unlockReason: UnlockReason?
        /// Вес показа (`BeatSchedule.weight`).
        public var weight: Float
        /// Шла гонка фаз (`BeatSchedule.race`).
        public var racing: Bool
        /// Отношение гребенки (`BeatSchedule.combRatio`).
        public var combRatio: Double?

        public init(
            time: Double, locked: Bool, bpm: Double?, confidence: Double, unlockReason: UnlockReason? = nil, weight: Float = 0,
            racing: Bool = false, combRatio: Double? = nil
        ) {
            self.time = time
            self.locked = locked
            self.bpm = bpm
            self.confidence = confidence
            self.unlockReason = unlockReason
            self.weight = weight
            self.racing = racing
            self.combRatio = combRatio
        }
    }

    /// Принудительный сброс (`Config.resetInterval`).
    public struct Reset: Sendable, Equatable {
        /// Конец шага, после которого был сброс, секунды потока от первого сэмпла (ось файла, без задержки
        /// вывода).
        public var time: Double
        /// Трекер держал захват перед сбросом.
        public var locked: Bool

        public init(time: Double, locked: Bool) {
            self.time = time
            self.locked = locked
        }
    }

    /// Мягкий пульс на кадре рендера (`Result.ambientTrace`).
    public struct AmbientPoint: Sendable, Equatable {
        /// Момент показа кадра, слышимые секунды от первого сэмпла.
        public var time: Double
        /// Энергия атак из кадра на этот момент (`WaveFrame.kickEnergy`).
        public var energy: Float
        /// Мягкий пульс кадра.
        public var value: Float

        public init(time: Double, energy: Float, value: Float) {
            self.time = time
            self.energy = energy
            self.value = value
        }
    }

    public struct Result: Sendable {
        /// Вспышки по времени, слышимые секунды от первого сэмпла.
        public var flashes: [Flash]
        /// Состояние на каждой публикации расписания.
        public var states: [State]
        /// Онсеты бочки, найденные анализом, слышимые секунды от первого сэмпла (момент в файле плюс
        /// `outputLatency`).
        public var kickOnsets: [Double]
        /// Широкополосные онсеты анализа, слышимые секунды от первого сэмпла (как `kickOnsets`).
        public var onsets: [Double] = []
        /// Предсказанные доли, как их видел рендер до начала вспышки (в последнем расписании,
        /// опубликованном раньше `time − BeatGlow.lead`), без квантования кадрами; слышимые секунды
        /// от первого сэмпла, по возрастанию.
        public var predictedTimes: [Double]
        /// Наибольшее свечение за прогон.
        public var peakGlow: Float
        /// Задержка вывода прогона.
        public var outputLatency: Double
        /// Мягкий пульс (`Config.softPulse`): наибольший за прогон, сколько кадров с пульсом от
        /// `RhythmLog.ambientVisible` и сколько кадров рендера всего. Без пульса нули.
        public var peakAmbient: Float = 0
        public var ambientFrames = 0
        public var renderedFrames = 0
        /// С `softPulse`: кадров рендера под расписанием без захвата и сколько из них с пульсом от
        /// `RhythmLog.ambientVisible`.
        public var unlockedFrames = 0
        public var ambientUnlockedFrames = 0
        /// С `softPulse`: моменты показа кадров, на которых пульс от `RhythmLog.ambientVisible` и выше
        /// соседних (вершины пульса), слышимые секунды от первого сэмпла.
        public var ambientPeaks: [Double] = []
        /// Мягкий пульс на каждом кадре рендера (`Config.softPulse` и `recordAmbientTrace`), иначе пусто.
        public var ambientTrace: [AmbientPoint] = []
        /// Принудительные сбросы по времени (`Config.resetInterval`), иначе пусто.
        public var resets: [Reset] = []
        /// Кадров рендера, показанных, пока звук слышен (момент показа от `outputLatency` до конца звука
        /// плюс `outputLatency`), и сколько из них со свечением от `RhythmLog.ambientVisible` (без пульса).
        public var audibleFrames = 0
        public var visibleFrames = 0

        /// Первая публикация с захватом, секунды от первого сэмпла.
        public var lockTime: Double? {
            states.first(where: \.locked)?.time
        }

        /// Темп последней публикации.
        public var tempoBPM: Double? {
            states.last?.bpm
        }

        /// Слышимые моменты для моментов в файле.
        public func audible(_ times: [Double]) -> [Double] {
            times.map { $0 + outputLatency }
        }
    }

    /// Начало оси хоста: не ноль, чтобы смешение осей потока и хоста было видно.
    public static let hostStart = 7_345.25
    /// Сколько рендерить после конца звука, секунды.
    public static let renderTail = 0.5
    /// Рост свечения за кадр, который считается вспышкой.
    public static let eventRise: Float = 0.2

    /// Один прогон: анализ и рендер.
    public static func run(samples: [Float], sampleRate: Double, config: Config) -> Result {
        render(analyze(samples: samples, sampleRate: sampleRate, config: config), config: config)
    }

    /// Один прогон анализа, показанный на `count` равномерно расставленных фазах рендера
    /// (`k / count` периода кадра): анализ от фазы рендера не зависит.
    public static func run(samples: [Float], sampleRate: Double, config: Config, renderPhases count: Int) -> [Result] {
        let analysis = analyze(samples: samples, sampleRate: sampleRate, config: config)
        return (0..<count).map { k in
            var phased = config
            phased.renderPhase = Double(k) / Double(count)
            return render(analysis, config: phased)
        }
    }

    /// Опубликованные расписания по времени хоста и то, что о них нужно рендеру и результату.
    private struct Analysis {
        var publications: [(time: Double, schedule: BeatSchedule)] = []
        var states: [State] = []
        var kickOnsets: [Double] = []
        var onsets: [Double] = []
        /// Время хоста каждой предсказанной доли в последнем расписании, опубликованном до начала ее
        /// вспышки (`time - BeatGlow.lead`), по id.
        var predicted: [UInt64: Double] = [:]
        /// `Config.softPulse`: энергия атак каждого шага, время пробуждения, после которого она видна
        /// рендеру, и момент ее кадра на оси хоста (центр окна плюс задержка вывода и сдвиг).
        var energies: [(wake: Double, time: Double, energy: Float)] = []
        var resets: [Reset] = []
        var end = 0.0
        /// Слышимый отрезок звука на оси хоста: от первого сэмпла плюс задержка вывода до последнего.
        var audible: ClosedRange<Double> = 0...0
    }

    /// Генератор шума цепочки (SplitMix64): одно и то же `seed` дает один и тот же прогон.
    private struct Noise {
        private var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        /// Равномерное значение в [-1, 1).
        mutating func nextUnit() -> Float {
            let v = Double(next() >> 11) / Double(1 << 53)
            return Float(v * 2 - 1)
        }
    }

    private static func analyze(samples: [Float], sampleRate rate: Double, config: Config) -> Analysis {
        var rng = Noise(seed: config.seed)
        let analyzer = StreamAnalyzer(sampleRate: rate)
        analyzer.measuresBassLevel = config.glowMode.measuresBassLevel
        let fftSize = analyzer.config.fftSize
        let hopSize = analyzer.config.hopSize
        var tracker = BeatTracker(framesPerSecond: analyzer.config.framesPerSecond, parameters: config.trackerParameters)
        tracker.keepsTempoAfterSilence = config.keepTempoAfterSilence
        tracker.glowMode = config.glowMode
        var clock = HostClock(sampleRate: rate)
        let settings = LevelSettings()
        var analysis = Analysis()
        analysis.end = hostStart + Double(samples.count) / rate + config.outputLatency + renderTail
        analysis.audible = (hostStart + config.outputLatency)...(hostStart + Double(samples.count) / rate + config.outputLatency)

        // Блоки IOProc: момент прихода и метка первого сэмпла.
        let chunkCount = samples.count / config.chunk
        var arrivals: [Double] = []
        var stamps: [Double] = []
        arrivals.reserveCapacity(chunkCount)
        stamps.reserveCapacity(chunkCount)
        for k in 0..<chunkCount {
            let last = hostStart + Double((k + 1) * config.chunk - 1) / rate
            let arrival = last + config.chunkJitter * Double(rng.nextUnit())
            arrivals.append(max(arrival, arrivals.last ?? arrival))
            stamps.append(hostStart + Double(k * config.chunk) / rate + config.chunkJitter * Double(rng.nextUnit()))
        }

        var delivered = 0
        var nextHopEnd = fftSize
        let wakePeriod = 1 / config.wakeRate
        let wakePhase = wakePeriod * Double(rng.nextUnit() * 0.5 + 0.5)
        var lastWake = -Double.infinity
        var wakeIndex = 0
        let resetInterval = config.resetInterval.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        var nextReset = resetInterval ?? .infinity
        while true {
            let jittered = hostStart + wakePhase + Double(wakeIndex) * wakePeriod + config.wakeJitter * Double(rng.nextUnit())
            let wake = max(jittered, lastWake)
            guard wake < analysis.end else { break }
            lastWake = wake
            wakeIndex += 1

            while delivered < chunkCount, arrivals[delivered] <= wake {
                clock.anchor(sampleIndex: delivered * config.chunk, hostSeconds: stamps[delivered])
                delivered += 1
            }
            let available = delivered * config.chunk
            var processed: Int?
            samples.withUnsafeBufferPointer { all in
                while nextHopEnd <= available {
                    let window = UnsafeBufferPointer(rebasing: all[(nextHopEnd - fftSize)..<nextHopEnd])
                    let hop = analyzer.processHop(window: window, endSample: nextHopEnd, settings: settings)
                    if let kick = hop.kickOnset {
                        analysis.kickOnsets.append(kick.time + config.outputLatency)
                    }
                    if let onset = hop.broadbandOnset {
                        analysis.onsets.append(onset.time + config.outputLatency)
                    }
                    tracker.process(hop)
                    if let resetInterval, hop.endTime >= nextReset {
                        analysis.resets.append(Reset(time: hop.endTime, locked: tracker.locked))
                        if config.resetAnalyzer { analyzer.reset(keepOnsetFloor: true) }
                        tracker.reset(keepTempo: true)
                        while nextReset <= hop.endTime { nextReset += resetInterval }
                    }
                    if config.softPulse, let centre = clock.hostTime(ofSample: nextHopEnd - fftSize / 2) {
                        analysis.energies.append(
                            (wake, centre + config.outputLatency + config.syncOffset, tracker.ambientEnergy)
                        )
                    }
                    processed = nextHopEnd
                    nextHopEnd += hopSize
                }
            }
            guard let end = processed, let host = clock.hostTime(ofSample: end) else { continue }
            let shift = host - Double(end) / rate + config.outputLatency + config.syncOffset
            let published = tracker.schedule.shifted(by: shift)
            analysis.publications.append((wake, published))
            analysis.states.append(
                State(
                    time: wake - hostStart, locked: published.locked, bpm: published.bpm, confidence: published.confidence,
                    unlockReason: published.unlockReason, weight: published.weight, racing: published.race != nil,
                    combRatio: published.combRatio
                )
            )
            for event in published.events where event.predicted && wake <= event.time - BeatGlow.lead {
                analysis.predicted[event.id] = event.time
            }
        }
        return analysis
    }

    private static func render(_ analysis: Analysis, config: Config) -> Result {
        let renderPeriod = 1 / config.renderRate
        let lead = config.presentationLead.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? 2 * renderPeriod
        var phaseRNG = Noise(seed: config.seed &+ 0x5EED)
        let phase = config.renderPhase ?? Double(phaseRNG.nextUnit() * 0.5 + 0.5)
        var glow = BeatGlow()
        var published = BeatSchedule.empty
        var publication = 0
        var previous: Float = 0
        var peak: Float = 0
        var flashes: [Flash] = []
        var peakAmbient: Float = 0
        var ambientFrames = 0
        var unlockedFrames = 0
        var ambientUnlockedFrames = 0
        var ambientPeaks: [Double] = []
        // Пульс двух прошлых кадров для вершин.
        var ambientBefore: (value: Float, time: Double)?
        var ambientLast: (value: Float, time: Double)?
        var ambientTrace: [AmbientPoint] = []
        var audibleFrames = 0
        var visibleFrames = 0
        var flashFrame: Int?
        // Кадры энергии, как их видит рендер приложения: опубликованные до `tEval`, на слышимой оси.
        let energyStore = FrameStore()
        var energy = 0
        var frame = 0
        while true {
            let tEval = hostStart + renderPeriod * (phase + Double(frame))
            guard tEval < analysis.end else { break }
            while publication < analysis.publications.count, analysis.publications[publication].time < tEval {
                published = analysis.publications[publication].schedule
                publication += 1
            }
            let tP = tEval + lead
            let value = glow.value(at: tP, schedule: published, refreshPeriod: renderPeriod)
            // Пик вспышки прошлого кадра: свечение этого кадра, если оно выше.
            if flashFrame == frame - 1, let last = flashes.indices.last {
                flashes[last].peak = max(flashes[last].peak, value)
            }
            if value - previous > eventRise {
                flashFrame = frame
                let started = startedEvent(in: published, by: tP, refreshPeriod: renderPeriod)
                flashes.append(
                    Flash(
                        time: tP - hostStart, predicted: started?.predicted ?? false, locked: published.locked,
                        reactive: started?.reactive ?? false, peak: value
                    )
                )
            }
            if analysis.audible.contains(tP) {
                audibleFrames += 1
                if value >= RhythmLog.ambientVisible { visibleFrames += 1 }
            }
            peak = max(peak, value)
            previous = value
            if config.softPulse {
                while energy < analysis.energies.count, analysis.energies[energy].wake < tEval {
                    var energyFrame = WaveFrame.silent
                    energyFrame.kickEnergy = analysis.energies[energy].energy
                    energyStore.publish(energyFrame, at: analysis.energies[energy].time)
                    energy += 1
                }
                let shown = energyStore.frame(at: tP)
                let ambient = BeatGlow.ambient(at: tP, info: published.ambient, frame: shown)
                peakAmbient = max(peakAmbient, ambient)
                let visible = ambient >= RhythmLog.ambientVisible
                if visible { ambientFrames += 1 }
                if !published.locked {
                    unlockedFrames += 1
                    if visible { ambientUnlockedFrames += 1 }
                }
                if let last = ambientLast, last.value >= RhythmLog.ambientVisible, last.value > (ambientBefore?.value ?? 0),
                   last.value >= ambient {
                    ambientPeaks.append(last.time - hostStart)
                }
                ambientBefore = ambientLast
                ambientLast = (ambient, tP)
                if config.recordAmbientTrace {
                    ambientTrace.append(AmbientPoint(time: tP - hostStart, energy: shown.kickEnergy, value: ambient))
                }
            }
            frame += 1
        }

        return Result(
            flashes: flashes,
            states: analysis.states,
            kickOnsets: analysis.kickOnsets,
            onsets: analysis.onsets,
            predictedTimes: analysis.predicted.values.map { $0 - hostStart }.sorted(),
            peakGlow: peak,
            outputLatency: config.outputLatency,
            peakAmbient: peakAmbient,
            ambientFrames: ambientFrames,
            renderedFrames: frame,
            unlockedFrames: unlockedFrames,
            ambientUnlockedFrames: ambientUnlockedFrames,
            ambientPeaks: ambientPeaks,
            ambientTrace: ambientTrace,
            resets: analysis.resets,
            audibleFrames: audibleFrames,
            visibleFrames: visibleFrames
        )
    }

    /// Событие расписания, давшее вспышку на кадре `t`: из начавшихся к этому кадру берется самое
    /// позднее (начало по `BeatGlow`: `time − lead − R / 2`). Это оценка: `BeatGlow` не говорит, какое
    /// событие дало рост, а событие, которое он счел слишком старым, здесь не отличается от обычного.
    /// При равных временах остается первое. Для долей и бочек правило 1.3 как есть (в «По ритму» других
    /// событий нет, и метки вспышек те же). Реактивное событие с яркостью выше 0 (`GlowMode.hybrid`,
    /// `sound`) берется, если оно началось позже, или если позднее событие сетки с яркостью 0 (в «По звуку»
    /// у всех долей 0, они вспышки не дают). Без выделения памяти: то же правило зовет запись ритма на
    /// кадре рендера (`RhythmRecorder.appendFrame`).
    static func startedEvent(in schedule: BeatSchedule, by t: Double, refreshPeriod: Double) -> GlowEvent? {
        var best: GlowEvent?
        var reactive: GlowEvent?
        for event in schedule.events where event.time.isFinite && event.time - BeatGlow.lead - refreshPeriod / 2 <= t {
            if event.reactive {
                guard event.amplitude > 0 else { continue }
                if let current = reactive, current.time >= event.time { continue }
                reactive = event
            } else {
                if let current = best, current.time >= event.time { continue }
                best = event
            }
        }
        guard let reactive else { return best }
        guard let grid = best, grid.amplitude > 0, grid.time >= reactive.time else { return reactive }
        return grid
    }
}
