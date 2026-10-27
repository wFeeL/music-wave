import Foundation
import Synchronization

/// Запись ритма с устройства: что анализ услышал, что он предсказал и когда рендер на самом деле
/// вспыхнул. Пишется кнопкой «Записать …» в диагностике (длина от 10 с до 10 мин, по умолчанию
/// 2 мин) рядом с WAV того же звука (`rhythm-<yyyyMMdd-HHmmss>.json` и `.wav`), на Linux ее прогоняет `wave-eval --replay`
/// (`RhythmReplay`): так ошибки анализа отделяются от ошибок задержки и рендера.
///
/// Ось времени та же, что у `OfflineBeatChain`: секунды от первого сэмпла WAV, слышимая ось. Сэмпл
/// k файла слышен в `k / sampleRate + outputLatency`; вспышка, попавшая точно в звук, имеет это же
/// время, `syncOffset` сдвигает вспышку относительно звука и в ось не входит. На устройстве ноль оси
/// это время хоста первого сэмпла (`meta.startHostSeconds`), вспышка кадра это момент его показа
/// минус ноль. Онсеты (`kicks`, `onsets`) это момент в файле плюс `outputLatency`; доли расписаний
/// и вспышки содержат еще и `syncOffset`, как на устройстве. Исключение `Schedule.time`: момент
/// публикации расписания по часам хоста, без задержки вывода (как `OfflineBeatChain.State.time`).
///
/// Схемы: 1 (1.1 и 1.2); 2 (1.3) добавляет в расписания яркость предсказанных долей, гонку фаз и
/// отношение гребенки (`Schedule.amplitudes`, `race`, `combRatio`). Читаются обе; незнакомые поля
/// пропускаются, новые поля необязательны, поэтому поле, которое добавит более новая сборка без смены
/// схемы, старую не ломает. Так в 1.3 без смены схемы добавлены `meta.flashLength` и
/// `meta.presentationLead`: необязательные поля схему не меняют.
public struct RhythmLog: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 2
    /// Схемы, которые читает `decode`.
    public static let readableSchemaVersions = 1...2
    /// Мягкий пульс кадра от этого значения считается видимым (`Meta.ambientFrames`).
    public static let ambientVisible: Float = 0.05

    public var schemaVersion: Int
    public var meta: Meta
    /// Онсеты бочки, найденные анализом.
    public var kicks: [Double]
    /// Широкополосные онсеты (вход темпа и фазы).
    public var onsets: [Double]
    /// Опубликованные расписания свечения; новое пишется, только когда картина заметно сменилась.
    public var schedules: [Schedule]
    /// Вспышки рендера: кадр, где свечение выросло больше чем на `OfflineBeatChain.eventRise`.
    public var flashes: [Flash]

    public init(meta: Meta, kicks: [Double], onsets: [Double], schedules: [Schedule], flashes: [Flash]) {
        schemaVersion = Self.currentSchemaVersion
        self.meta = meta
        self.kicks = kicks
        self.onsets = onsets
        self.schedules = schedules
        self.flashes = flashes
    }

    /// Почему запись кончилась.
    public enum EndReason: String, Codable, Sendable, Equatable {
        /// Записаны все `duration` секунд.
        case complete
        /// Остановлена раньше (кнопка, выход, предел времени).
        case stopped
        /// Звук так и не пришел.
        case noAudio
        /// Остров скрылся: анализ перешел в простой.
        case islandHidden
        /// Захват остановлен или начат заново (пауза, смена источника или устройства, сон).
        case captureRestarted
        /// В потоке пропуск: анализ отстал или окно не скопировалось.
        case gap
        /// Сэмплы перестали приходить.
        case stalled
        /// Сменились задержка вывода или сдвиг синхронизации.
        case settingsChanged
    }

    public struct Meta: Codable, Sendable, Equatable {
        public var appVersion: String
        public var build: String
        /// Короткий хэш коммита сборки или `unknown`.
        public var commit: String
        public var swiftVersion: String
        public var deviceName: String
        public var deviceUID: String
        /// Режим «Задержки волн» словами.
        public var latencyMode: String
        /// Задержка вывода, с которой шел анализ, секунды.
        public var outputLatency: Double
        /// Сдвиг синхронизации, с которым шел анализ, секунды (плюс это позже).
        public var syncOffset: Double
        public var sampleRate: Double
        /// Период кадров острова в начале записи, секунды: R, на середину которого `BeatGlow` берет
        /// свечение (`PresentationTiming.framePeriod`).
        public var renderPeriod: Double
        /// Упреждение показа в начале записи, секунды: два периода экрана (`PresentationTiming.lead`,
        /// с 1.3). В журналах до 1.3 поля нет (`nil`): тогда упреждение было `2 × renderPeriod`. Поле
        /// необязательное, схема та же.
        public var presentationLead: Double?
        /// «Уменьшение движения» было включено в начале или на любом кадре записи: тогда свечения
        /// нет и вспышек устройства не бывает.
        public var reduceMotion: Bool
        /// «Яркость свечения» 0...1: на вспышки записи не влияет (правило роста смотрит на свечение
        /// до нее), но с нулем пользователь их не видит.
        public var glowIntensity: Double
        /// «Вздох» острова в такт доле включен.
        public var beatPulse: Bool
        /// «Длительность вспышки» (множитель спада показа, `BeatGlow.decay(period:scale:)`): только показ,
        /// вспышки записи и прогон журнала считаются со спадом 1×. В журналах до 1.3 поля нет (`nil`, то есть 1).
        public var flashLength: Double?
        /// «Мягкий пульс» включен; в журналах до 1.2 поля нет (`nil`).
        public var softPulse: Bool?
        /// Режим энергосбережения в начале записи (рендер до 30 кадров в секунду, облегченный вид).
        public var lowPower: Bool
        /// Сэмплов, обрезанных до ±1 при записи в 16 бит: прогон видит их не такими, как анализ.
        public var clippedSamples: Int
        /// Время хоста первого сэмпла (`CACurrentMediaTime()`), ноль оси.
        public var startHostSeconds: Double
        /// Сколько секунд просили записать.
        public var duration: Double
        /// Сколько секунд звука записано.
        public var audioSeconds: Double
        /// Кадров рендера с начала записи.
        public var renderedFrames: Int
        /// Время показа последнего кадра рендера, секунды оси; `nil`, если кадров не было. Вспышки
        /// позже него не могли попасть в запись.
        public var renderedUntil: Double?
        /// Кадров, на которых показанный мягкий пульс был от `RhythmLog.ambientVisible`, и его пик за
        /// запись; `nil`, если кадры пульс не передавали (журналы до 1.2).
        public var ambientFrames: Int?
        public var ambientPeak: Float?
        public var endReason: EndReason

        public init(
            appVersion: String = "",
            build: String = "",
            commit: String = "unknown",
            swiftVersion: String = "unknown",
            deviceName: String = "",
            deviceUID: String = "",
            latencyMode: String = "",
            outputLatency: Double = 0,
            syncOffset: Double = 0,
            sampleRate: Double = 0,
            renderPeriod: Double = 1.0 / 60,
            presentationLead: Double? = nil,
            reduceMotion: Bool = false,
            glowIntensity: Double = 1,
            beatPulse: Bool = true,
            flashLength: Double? = nil,
            softPulse: Bool? = nil,
            lowPower: Bool = false,
            clippedSamples: Int = 0,
            startHostSeconds: Double = 0,
            duration: Double = 0,
            audioSeconds: Double = 0,
            renderedFrames: Int = 0,
            renderedUntil: Double? = nil,
            ambientFrames: Int? = nil,
            ambientPeak: Float? = nil,
            endReason: EndReason = .stopped
        ) {
            self.appVersion = appVersion
            self.build = build
            self.commit = commit
            self.swiftVersion = swiftVersion
            self.deviceName = deviceName
            self.deviceUID = deviceUID
            self.latencyMode = latencyMode
            self.outputLatency = outputLatency
            self.syncOffset = syncOffset
            self.sampleRate = sampleRate
            self.renderPeriod = renderPeriod
            self.presentationLead = presentationLead
            self.reduceMotion = reduceMotion
            self.glowIntensity = glowIntensity
            self.beatPulse = beatPulse
            self.flashLength = flashLength
            self.softPulse = softPulse
            self.lowPower = lowPower
            self.clippedSamples = clippedSamples
            self.startHostSeconds = startHostSeconds
            self.duration = duration
            self.audioSeconds = audioSeconds
            self.renderedFrames = renderedFrames
            self.renderedUntil = renderedUntil
            self.ambientFrames = ambientFrames
            self.ambientPeak = ambientPeak
            self.endReason = endReason
        }
    }

    public struct Schedule: Codable, Sendable, Equatable {
        /// Момент публикации по часам хоста, секунды от нуля оси (без задержки вывода).
        public var time: Double
        public var bpm: Double?
        public var confidence: Double
        public var locked: Bool
        /// Предсказанные доли расписания, слышимая ось с `syncOffset`.
        public var beats: [Double]
        /// Почему захват потерян (`BeatSchedule.unlockReason`). В журналах 1.1 поля нет, они читаются
        /// с `nil`; без причины ключ не пишется.
        public var unlockReason: UnlockReason?
        /// Вес показа (`BeatSchedule.weight`); в журналах до 1.2 поля нет (`nil`).
        public var weight: Float?
        /// Опубликованная яркость каждой доли из `beats` (`GlowEvent.amplitude`: сила, ворот, вес, гонка,
        /// четность показа); в журналах схемы 1 поля нет (`nil`).
        public var amplitudes: [Float]?
        /// Гонка фаз, пока она идет: доля тени на оси записи (как `beats`) и множитель яркости сетки.
        /// `nil` без гонки и в журналах схемы 1.
        public var race: Race?
        /// Отношение гребенки последней проверки темпа (`BeatSchedule.combRatio`); `nil` до первой проверки
        /// и в журналах схемы 1.
        public var combRatio: Double?

        public struct Race: Codable, Sendable, Equatable {
            public var shadow: Double
            public var dim: Float

            public init(shadow: Double, dim: Float) {
                self.shadow = shadow
                self.dim = dim
            }
        }

        public init(
            time: Double, bpm: Double?, confidence: Double, locked: Bool, beats: [Double], unlockReason: UnlockReason? = nil,
            weight: Float? = nil, amplitudes: [Float]? = nil, race: Race? = nil, combRatio: Double? = nil
        ) {
            self.time = time
            self.bpm = bpm
            self.confidence = confidence
            self.locked = locked
            self.beats = beats
            self.unlockReason = unlockReason
            self.weight = weight
            self.amplitudes = amplitudes
            self.race = race
            self.combRatio = combRatio
        }
    }

    public struct Flash: Codable, Sendable, Equatable {
        /// Момент показа кадра, слышимая ось.
        public var time: Double
        /// Вспышку дала предсказанная доля (иначе онсет бочки); оценка, как у `OfflineBeatChain`.
        public var predicted: Bool
        /// Расписание на этом кадре было с захватом.
        public var locked: Bool

        public init(time: Double, predicted: Bool, locked: Bool) {
            self.time = time
            self.predicted = predicted
            self.locked = locked
        }
    }

    public enum DecodeError: Error, Equatable {
        case unsupportedSchema(Int)
    }

    /// JSON записи: с отступами и ключами по алфавиту, чтобы файл читался глазами.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Разбирает JSON записи; схема вне `readableSchemaVersions` это ошибка.
    public static func decode(_ data: Data) throws -> RhythmLog {
        struct Version: Decodable {
            var schemaVersion: Int
        }
        let version = try JSONDecoder().decode(Version.self, from: data).schemaVersion
        guard readableSchemaVersions.contains(version) else { throw DecodeError.unsupportedSchema(version) }
        return try JSONDecoder().decode(RhythmLog.self, from: data)
    }

    /// Имена файлов записи по метке начала `yyyyMMdd-HHmmss`.
    public static func fileNames(stamp: String) -> (json: String, wav: String) {
        ("rhythm-\(stamp).json", "rhythm-\(stamp).wav")
    }

    /// Путь WAV рядом с записью: то же имя с расширением `.wav`.
    public static func wavPath(forLogPath path: String) -> String {
        NSString(string: path).deletingPathExtension + ".wav"
    }
}

/// Накопитель записи ритма, ограниченный `duration` секундами звука. Не потокобезопасен: в
/// приложении живет в `RhythmSession`.
///
/// Звук и онсеты приходят шагами анализа (`appendHop`): первый шаг берет все окно, его первый
/// сэмпл становится нулем оси, следующие только новые сэмплы. Пропуск в потоке, другая частота,
/// задержка или сдвиг кончают запись. Когда звук набран (`EndReason.complete`) или запись
/// остановлена, анализ больше ничего не добавляет, а вспышки рендера (`appendFrame`) пишутся до
/// `finish()`: свечение по последнему звуку видно на задержку вывода позже.
public struct RhythmRecorder: Sendable {
    /// Допуск, с которым доли двух расписаний считаются одинаковыми, секунды.
    static let beatTolerance = 0.001
    /// Изменение уверенности, после которого расписание пишется заново.
    static let confidenceStep = 0.01
    /// Изменение веса показа или яркости доли, после которого расписание пишется заново.
    static let weightStep: Float = 0.02
    /// Изменение отношения гребенки, после которого расписание пишется заново.
    static let ratioStep = 0.01

    public let duration: Double
    public private(set) var samples: [Int16] = []
    public private(set) var endReason: RhythmLog.EndReason?
    private var meta: RhythmLog.Meta
    private var kicks: [Double] = []
    private var onsets: [Double] = []
    private var schedules: [RhythmLog.Schedule] = []
    private var flashes: [RhythmLog.Flash] = []
    /// Номер первого сэмпла записи в потоке анализа; `nil` до первого шага.
    private var startSample: Int?
    /// Следующий ожидаемый номер сэмпла потока.
    private var nextSample = 0
    private var capacity = 0

    /// `meta`: то, что знает приложение (версия, устройство, режим задержки, период отрисовки);
    /// частоту, задержку, сдвиг, начало и итоги заполняет запись.
    public init(duration: Double, meta: RhythmLog.Meta) {
        self.duration = duration.isFinite ? max(duration, 0) : 0
        self.meta = meta
        self.meta.duration = self.duration
    }

    public var hasStarted: Bool { startSample != nil }

    /// Секунды записанного звука.
    public var audioSeconds: Double {
        meta.sampleRate > 0 ? Double(samples.count) / meta.sampleRate : 0
    }

    /// Время хоста, после которого записанный звук уже не может дать вспышку: ноль оси плюс звук,
    /// задержка вывода и положительный сдвиг. `nil` до начала.
    public var audibleEndHost: Double? {
        guard hasStarted else { return nil }
        return meta.startHostSeconds + audioSeconds + meta.outputLatency + max(meta.syncOffset, 0)
    }

    /// Шаг анализа: окно `window`, кончающееся на сэмпле потока `endSample`; `firstSampleHost`
    /// это время хоста первого сэмпла окна (нужно только на первом шаге). `kick` и `onset`: онсеты
    /// шага, секунды потока.
    public mutating func appendHop(
        window: UnsafeBufferPointer<Float>,
        endSample: Int,
        firstSampleHost: Double?,
        sampleRate: Double,
        outputLatency: Double,
        syncOffset: Double,
        kick: Double?,
        onset: Double?
    ) {
        guard endReason == nil else { return }
        let windowStart = endSample - window.count
        if startSample == nil {
            guard let firstSampleHost, firstSampleHost.isFinite, sampleRate.isFinite, sampleRate > 0,
                  outputLatency.isFinite, syncOffset.isFinite else { return }
            startSample = windowStart
            nextSample = windowStart
            meta.sampleRate = sampleRate
            meta.outputLatency = outputLatency
            meta.syncOffset = syncOffset
            meta.startHostSeconds = firstSampleHost
            capacity = Int((duration * sampleRate).rounded())
            samples.reserveCapacity(capacity)
        } else if sampleRate != meta.sampleRate {
            stop(.captureRestarted)
            return
        } else if outputLatency != meta.outputLatency || syncOffset != meta.syncOffset {
            stop(.settingsChanged)
            return
        }
        guard windowStart <= nextSample else {
            stop(.gap)
            return
        }
        if endSample > nextSample {
            let from = nextSample - windowStart
            let count = min(endSample - nextSample, capacity - samples.count)
            for index in from..<(from + max(count, 0)) {
                let sample = window[index]
                if sample > 1 || sample < -1 { meta.clippedSamples += 1 }
                samples.append(Self.pcm16(sample))
            }
            nextSample = endSample
        }
        if let kick, let time = audible(streamSeconds: kick) {
            kicks.append(time)
        }
        if let onset, let time = audible(streamSeconds: onset) {
            onsets.append(time)
        }
        if samples.count >= capacity {
            stop(.complete)
        }
    }

    /// Расписание, опубликованное в момент хоста `host` (ось хоста, с задержкой и сдвигом). Пишется,
    /// если сменились захват, причина его потери, темп, предсказанные доли (больше чем на 1 мс) или их
    /// яркость (на 0.02 и больше), уверенность (на 0.01 и больше), вес показа (на 0.02 и больше), гонка
    /// фаз (началась, кончилась, доля тени сдвинулась больше чем на 1 мс) или отношение гребенки (на 0.01
    /// и больше).
    public mutating func appendSchedule(_ schedule: BeatSchedule, publishedAtHost host: Double) {
        guard hasStarted, endReason == nil, host.isFinite else { return }
        let zero = meta.startHostSeconds
        let bpm = schedule.bpm.flatMap { $0.isFinite ? $0 : nil }
        let confidence = schedule.confidence.isFinite ? schedule.confidence : 0
        let weight = schedule.weight.isFinite ? schedule.weight : 0
        let ratio = schedule.combRatio.flatMap { $0.isFinite ? $0 : nil }
        let race = schedule.race.flatMap { race in
            race.shadow.isFinite ? RhythmLog.Schedule.Race(shadow: Self.rounded(race.shadow - zero), dim: race.dim) : nil
        }
        if let last = schedules.last, last.locked == schedule.locked, last.unlockReason == schedule.unlockReason, last.bpm == bpm,
           abs(last.confidence - confidence) < Self.confidenceStep,
           let lastWeight = last.weight, abs(lastWeight - weight) < Self.weightStep,
           Self.sameRace(last.race, race), Self.sameRatio(last.combRatio, ratio),
           Self.sameBeats(last, schedule, zero: zero) {
            return
        }
        var beats: [Double] = []
        var amplitudes: [Float] = []
        for event in schedule.events where event.predicted && event.time.isFinite {
            beats.append(Self.rounded(event.time - zero))
            amplitudes.append(event.amplitude.isFinite ? event.amplitude : 0)
        }
        schedules.append(
            RhythmLog.Schedule(
                time: Self.rounded(host - zero), bpm: bpm, confidence: confidence, locked: schedule.locked, beats: beats,
                unlockReason: schedule.unlockReason, weight: weight, amplitudes: amplitudes, race: race, combRatio: ratio
            )
        )
    }

    /// Кадр рендера с моментом показа `presentedHost` (секунды хоста): `glowRise` это рост
    /// свечения против прошлого кадра, вспышка при росте больше `OfflineBeatChain.eventRise`.
    /// Источник вспышки оценивается по `schedule` так же, как в офлайн-цепочке. `ambient`: показанный
    /// на кадре мягкий пульс (в итог `meta.ambientFrames` и `ambientPeak`; нечисловой как 0); во
    /// вспышки не входит.
    public mutating func appendFrame(
        presentedHost: Double, glowRise: Float, schedule: BeatSchedule, refreshPeriod: Double, ambient: Float? = nil
    ) {
        guard hasStarted, presentedHost.isFinite else { return }
        let time = presentedHost - meta.startHostSeconds
        guard time >= 0 else { return }
        meta.renderedFrames += 1
        meta.renderedUntil = max(meta.renderedUntil ?? time, time)
        if let ambient {
            let shown = ambient.isFinite ? max(ambient, 0) : 0
            meta.ambientFrames = (meta.ambientFrames ?? 0) + (shown >= RhythmLog.ambientVisible ? 1 : 0)
            meta.ambientPeak = max(meta.ambientPeak ?? 0, shown)
        }
        guard glowRise > OfflineBeatChain.eventRise else { return }
        flashes.append(
            RhythmLog.Flash(
                time: Self.rounded(time),
                predicted: OfflineBeatChain.startedEvent(in: schedule, by: presentedHost, refreshPeriod: refreshPeriod)?.predicted ?? false,
                locked: schedule.locked
            )
        )
    }

    /// «Уменьшение движения» включено на кадре записи.
    public mutating func noteReduceMotion() {
        meta.reduceMotion = true
    }

    /// Кончает запись с причиной `reason`; первая причина остается.
    public mutating func stop(_ reason: RhythmLog.EndReason) {
        if endReason == nil { endReason = reason }
    }

    /// Запись как есть, в том числе неполная: без звука причина `noAudio`, не кончившаяся
    /// запись получает `stopped`.
    public func finish() -> RhythmLog {
        var meta = meta
        meta.audioSeconds = audioSeconds
        meta.endReason = hasStarted ? endReason ?? .stopped : .noAudio
        return RhythmLog(meta: meta, kicks: kicks, onsets: onsets, schedules: schedules, flashes: flashes)
    }

    /// Сэмпл -1...1 в 16 бит; за пределами обрезается (счет в `meta.clippedSamples`: горячий мастер
    /// или громкость выше единицы дают сэмплы больше 1, прогон видит их обрезанными), не число дает 0.
    public static func pcm16(_ sample: Float) -> Int16 {
        guard sample.isFinite else { return 0 }
        return Int16((min(max(sample, -1), 1) * 32_767).rounded())
    }

    /// Время онсета на слышимой оси записи; `nil`, если он раньше начала.
    private func audible(streamSeconds: Double) -> Double? {
        guard let startSample, streamSeconds.isFinite else { return nil }
        let time = streamSeconds - Double(startSample) / meta.sampleRate + meta.outputLatency
        return time >= 0 ? Self.rounded(time) : nil
    }

    /// До микросекунды: короче файл, точность с запасом.
    private static func rounded(_ seconds: Double) -> Double {
        (seconds * 1_000_000).rounded() / 1_000_000
    }

    /// Те же ли предсказанные доли в `schedule` (ось хоста), что в записанном `last` (ось записи): время с
    /// допуском `beatTolerance`, яркость с допуском `weightStep` (у строки без яркостей не сравнивается).
    /// Без выделения памяти.
    private static func sameBeats(_ last: RhythmLog.Schedule, _ schedule: BeatSchedule, zero: Double) -> Bool {
        var index = 0
        for event in schedule.events where event.predicted && event.time.isFinite {
            guard index < last.beats.count, abs(last.beats[index] - (event.time - zero)) <= beatTolerance else { return false }
            if let amplitudes = last.amplitudes, index < amplitudes.count {
                let amplitude = event.amplitude.isFinite ? event.amplitude : 0
                guard abs(amplitudes[index] - amplitude) < weightStep else { return false }
            }
            index += 1
        }
        return index == last.beats.count
    }

    /// Та же гонка: обеих нет, или доля тени в пределах `beatTolerance` и тот же множитель.
    private static func sameRace(_ last: RhythmLog.Schedule.Race?, _ race: RhythmLog.Schedule.Race?) -> Bool {
        switch (last, race) {
        case (nil, nil): true
        case let (last?, race?): abs(last.shadow - race.shadow) <= beatTolerance && last.dim == race.dim
        default: false
        }
    }

    /// То же отношение гребенки: обоих нет или разница меньше `ratioStep`.
    private static func sameRatio(_ last: Double?, _ ratio: Double?) -> Bool {
        switch (last, ratio) {
        case (nil, nil): true
        case let (last?, ratio?): abs(last - ratio) < ratioStep
        default: false
        }
    }
}

/// Запись ритма, общая для очереди анализа (звук, онсеты, расписания) и главного актора (кадры
/// рендера, остановка, итог). Все вызовы под одним замком; пока записи нет, приложение держит
/// `nil` и сюда не ходит.
public final class RhythmSession: Sendable {
    public struct Status: Sendable, Equatable {
        public var started: Bool
        public var audioSeconds: Double
        public var endReason: RhythmLog.EndReason?
        public var audibleEndHost: Double?

        public init(started: Bool, audioSeconds: Double, endReason: RhythmLog.EndReason?, audibleEndHost: Double?) {
            self.started = started
            self.audioSeconds = audioSeconds
            self.endReason = endReason
            self.audibleEndHost = audibleEndHost
        }
    }

    private let recorder: Mutex<RhythmRecorder>

    public init(_ recorder: RhythmRecorder) {
        self.recorder = Mutex(recorder)
    }

    public var status: Status {
        recorder.withLock {
            Status(started: $0.hasStarted, audioSeconds: $0.audioSeconds, endReason: $0.endReason, audibleEndHost: $0.audibleEndHost)
        }
    }

    /// См. `RhythmRecorder.appendHop`.
    public func appendHop(
        window: UnsafeBufferPointer<Float>,
        endSample: Int,
        firstSampleHost: Double?,
        sampleRate: Double,
        outputLatency: Double,
        syncOffset: Double,
        kick: Double?,
        onset: Double?
    ) {
        recorder.withLock {
            $0.appendHop(
                window: window, endSample: endSample, firstSampleHost: firstSampleHost, sampleRate: sampleRate,
                outputLatency: outputLatency, syncOffset: syncOffset, kick: kick, onset: onset
            )
        }
    }

    public func appendSchedule(_ schedule: BeatSchedule, publishedAtHost host: Double) {
        recorder.withLock { $0.appendSchedule(schedule, publishedAtHost: host) }
    }

    public func appendFrame(
        presentedHost: Double, glowRise: Float, schedule: BeatSchedule, refreshPeriod: Double, ambient: Float? = nil
    ) {
        recorder.withLock {
            $0.appendFrame(
                presentedHost: presentedHost, glowRise: glowRise, schedule: schedule, refreshPeriod: refreshPeriod, ambient: ambient
            )
        }
    }

    public func stop(_ reason: RhythmLog.EndReason) {
        recorder.withLock { $0.stop(reason) }
    }

    public func noteReduceMotion() {
        recorder.withLock { $0.noteReduceMotion() }
    }

    /// Запись и ее звук в 16 бит.
    public func finish() -> (log: RhythmLog, samples: [Int16]) {
        recorder.withLock { ($0.finish(), $0.samples) }
    }
}
