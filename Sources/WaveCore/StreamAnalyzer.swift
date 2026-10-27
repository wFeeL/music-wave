import Foundation

/// Размеры анализа для частоты дискретизации: шаг около 5.3 мс при любой частоте.
public struct AnalysisConfig: Sendable, Equatable {
    public let sampleRate: Double
    /// 1024 до 50 кГц включительно, иначе 2048.
    public let fftSize: Int
    /// `fftSize / 4`.
    public let hopSize: Int

    /// Длительность шага в секундах.
    public var hopDuration: Double { Double(hopSize) / sampleRate }
    /// Шагов в секунду.
    public var framesPerSecond: Double { sampleRate / Double(hopSize) }

    public init(sampleRate: Double) {
        precondition(sampleRate > 0, "sampleRate must be positive")
        self.sampleRate = sampleRate
        fftSize = sampleRate <= 50_000 ? 1024 : 2048
        hopSize = fftSize / 4
    }
}

/// Онсет на временной оси потока.
public struct OnsetEvent: Sendable, Equatable {
    /// `endSample / sampleRate - StreamAnalyzer.onsetLag`, секунды потока.
    public var time: Double
    /// `clamp(odf / P, 0, 1)`, P это следящий пик функции онсетов (спад 3 с).
    public var strength: Float
    /// Онсет длинной бочки (808 поверх уже громкой полосы бочки, `OnlinePeakPicker.lastOnsetSustained`):
    /// он есть в журнале ритма и в огибающей удара, но не светится (`BeatTracker`).
    public var sustained: Bool

    public init(time: Double, strength: Float, sustained: Bool = false) {
        self.time = time
        self.strength = strength
        self.sustained = sustained
    }
}

/// Результат одного шага анализа. Времена в секундах потока (номер сэмпла / частота).
public struct HopResult: Sendable {
    public var frame: WaveFrame
    /// `(endSample - fftSize / 2) / sampleRate`, центр окна.
    public var frameTime: Double
    /// `endSample / sampleRate`, конец окна (сэмпл, который завершил шаг).
    public var endTime: Double
    public var kickOnset: OnsetEvent?
    public var broadbandOnset: OnsetEvent?
    /// Широкополосная функция онсетов этого шага (вход оценки темпа и фазы).
    public var broadbandODF: Float
    /// Функция онсетов бочки этого шага (поток SuperFlux по бинам до 150 Гц), вход выбора октавы темпа.
    public var kickODF: Float
    /// `10 · log10` суммарной мощности бинов бочки (до 150 Гц, без бина 0), деленной на ENBW окна
    /// Ханна, как у полос `BandMapper`: синус амплитуды A дает A². Пол -120 dBFS.
    public var kickLevelDB: Float
    /// Первый шаг со звуком после тишины не короче `StreamAnalyzer.silenceGap`: потоки онсетов начались
    /// заново, трекер начинается заново (`BeatTracker.Parameters.silenceRestart`).
    public var soundReturned: Bool

    public init(
        frame: WaveFrame,
        frameTime: Double,
        endTime: Double,
        kickOnset: OnsetEvent?,
        broadbandOnset: OnsetEvent?,
        broadbandODF: Float,
        kickODF: Float = 0,
        kickLevelDB: Float,
        soundReturned: Bool = false
    ) {
        self.frame = frame
        self.frameTime = frameTime
        self.endTime = endTime
        self.kickOnset = kickOnset
        self.broadbandOnset = broadbandOnset
        self.broadbandODF = broadbandODF
        self.kickODF = kickODF
        self.kickLevelDB = kickLevelDB
        self.soundReturned = soundReturned
    }
}

/// Анализ потока по шагам `hopSize` сэмплов (`beat-sync.md` 2.2-2.3): одно окно Ханна дает уровни
/// волн, функцию онсетов бочки (свечение) и широкополосную функцию онсетов (темп и фаза).
///
/// Время берется из номера сэмпла, а не из часов вызова, поэтому фаза таймера в него не попадает.
/// Все буферы шага выделены в `init` и `reconfigure`; на шаг выделяются только массивы
/// возвращаемого `WaveFrame`. Не потокобезопасен, все вызовы с одной очереди.
public final class StreamAnalyzer {
    /// Задержка обнаружения d_odf: онсет находится на фронте, в среднем через столько после начала
    /// звука, и вычитается из времени каждого онсета.
    public static let onsetLag = 0.007
    public static let attack = 0.010
    public static let release = 0.25

    /// Верхняя граница центра бина бочки.
    static let kickMaxHz = 150.0
    /// Полосы с центром ниже сравниваются с шагом назад (μ = 1), выше с двумя (μ = 2): малый и хэт
    /// размазаны на два шага.
    static let broadbandLagSplitHz = 250.0
    /// Полосы с центром от этой частоты входят в широкополосную функцию с весом 2.
    static let broadbandHighHz = 4000.0
    static let broadbandHighWeight: Float = 2
    static let envelopeDecay = 0.06
    /// Выбор пиков бочки: порог odf max(2, 0.25 P), подъем 7.5 дБ против уровня 16 мс назад.
    /// Абсолютный порог 3 терял больше половины бочек на 160 BPM (хвост прошлой бочки громче, поток
    /// на фронте меньше), поэтому абсолютная часть ниже, а относительная растет с ударами. Совсем
    /// без ложных онсетов три бина бочки в шуме не обойтись: у розового шума -20 dBFS около 0.17 в
    /// секунду; редкие ложные удары гасят уверенность и захват ритма в трекере.
    ///
    /// Онсет длинной бочки (`sustained`): 808 легато поверх уже громкой полосы бочки (журнал 1 владельца
    /// 1.2.1: уровень полосы -9.5...-11.6 дБ все 30 с, на смене ноты провал, подъема на 7.5 дБ нет, 1
    /// онсет на 55 нот). Пик функции бочки выше `max(0.3, 6 T, 0.25 P)` и уровень на 3 дБ выше минимума
    /// за 150 мс, который сам выше ворота -60 dBFS. На журнале 1 онсетов бочки 1 -> 41, из них 35 на
    /// нотах 808 (нот около 55). У розового шума от -10 до -50 dBFS пик не выше 3.7 T, онсетов длинной
    /// бочки 0 за 720 с. Такие онсеты не светятся (`BeatTracker`): на GTZAN tune (steady) их 781, на
    /// доле только 47 %. Если бы они светились, без захвата прибавилось бы 20 вспышек на доле и 15
    /// мимо (точность всех вспышек 0.8677 -> 0.8671, без захвата 0.7460 -> 0.7450). Поэтому они есть
    /// только в журнале ритма и в огибающей удара, а вспышки и метрики `wave-eval` те же.
    static let kickPickerParameters = OnlinePeakPicker.Parameters(
        floor: 2.0, relativeFloor: 0.25, sustainedContrast: 6, sustainedFloor: 0.3, sustainedRiseDB: 3, minRiseDB: 7.5
    )
    /// Выбор пиков широкополосной функции. Проверки подъема уровня нет: уровень здесь это
    /// максимум полос, его почти всегда держит бочка или бас, и хэт между ними его не поднимает
    /// (с проверкой 9 дБ хип-хоп дает F 0.6). Шум отсекает порог odf 10: у розового шума пики до 8.7
    /// при любой громкости от -10 до -40 dBFS, у хэта от 30, у бочки и малого 70-90. При пороге 12 на
    /// GTZAN (полоса до 11 кГц) у половины долей не было онсета, и трекер редко набирал попадания.
    ///
    /// Порог 10 опускается до 4 по типичному пику T и уровню акцента A (`OnlinePeakPicker.Parameters`):
    /// `min(10, max(4, 3.2 T, 0.6 A))`. На тихих и редких аранжировках доли стоят под 10 (журналы
    /// владельца 1.2.1: медиана пика доли 4.5 во вступлении трека C, 6.9-8.4 у трека A), хотя доля ясна.
    /// Отрыв 3.2 держит шум: у розового шума от -10 до -50 dBFS пик не выше 2.5 T, онсетов 0 за 870 с.
    /// Уровень акцента с медленным шагом (около 14 акцентов после сброса, 7 с на 120 BPM) держит порог
    /// после громких долей и на слабых долях.
    ///
    /// GTZAN tune, steady, 60 Гц, против порога 10: prec 0.8674 -> 0.8677, recall 0.4215 -> 0.4244,
    /// lockedCov 0.3490 -> 0.3507, wrongLock 12 / 215 без изменений, вспышек мимо долей всего / с захватом
    /// 2081 / 555 -> 2088 / 555. Записи владельца (15 подряд): вспышек на долю 192 -> 210, это темное
    /// вступление трека C (0 -> 17). Отклонены: постоянный порог 8 / 6 (0.8650 / 0.8559, wrongLock
    /// 16 / 22, с захватом мимо 768 / 1048, шум дает онсеты); отрыв 2.6 без уровня акцента (0.8668,
    /// wrongLock 17, с захватом мимо 643: медленные треки 52-66 BPM на удвоенной сетке загораются через
    /// долю); отрыв 2.2 (на шуме 22 онсета); порог от следящего пика 0.45-0.6 P; быстрый разгон уровня
    /// акцента (0.8665, с захватом мимо 557-560).
    static let broadbandPickerParameters = OnlinePeakPicker.Parameters(
        floor: 10, peakContrast: 3.2, lowFloor: 4, accentFloor: 0.6, minRiseDB: -.infinity
    )
    /// Тишина, после которой звук начинает новый поток (`HopResult.soundReturned`): самая громкая полоса
    /// ниже `silenceLevelDB` не меньше `silenceGap` секунд. Порог уровня тот же, что у выбора пиков
    /// широкополосной функции: ниже него онсетов нет. Так звучат пауза плеера, во время которой захват
    /// отдает нули, и промежуток между треками у всего звука системы, где ключа трека нет. Потоки онсетов
    /// начинаются заново, пока окно не выйдет из тишины (`fftSize / hopSize` шагов), как у нового
    /// анализатора: переход от тишины к звуку иначе дает пик потока на любой фазе (в пробе пауз GTZAN
    /// 1442 вспышки бочки в первые 0.1 с после паузы, 1150 из них мимо доли). 0.5 с: на GTZAN tune
    /// тишина такой длины внутри файла есть в двух файлах, а промежутки между треками обычно длиннее.
    /// Уровень это уровень захвата: при тихой громкости самого плеера (она действует до захвата) ниже
    /// порога может уйти и тихое место трека. Тишина считается в шагах анализа (`silenceGap / hopDuration`),
    /// поэтому в простое острова (шаг на пробуждение) она набирается дольше; трекер там все равно стоит.
    static let silenceGap = 0.5
    static let silenceLevelDB = broadbandPickerParameters.minLevelDB
    private static let hannENBW: Float = 1.5
    private static let floorDB: Float = -120

    public private(set) var config: AnalysisConfig

    private var fft: RealFFT
    private var mapper: BandMapper
    /// Полосы каждого слоя по `WaveLayer.rawValue`. `WaveLayer.allCases` на каждом шаге выделял бы массив.
    private var layerRanges: [Range<Int>]
    private var levelProcessor: LevelProcessor
    private var smoothers: [AttackRelease]
    /// Гравитация басовых полос `layerRanges[WaveLayer.bass.rawValue]`, индекс это номер полосы
    /// минус начало диапазона.
    private var bassSmoothers: [GravityRelease]
    private var envelope = BeatEnvelope(decay: StreamAnalyzer.envelopeDecay)
    private var kickBins: Range<Int>
    private var kickFlux: SuperFlux
    private var broadbandFlux: SuperFlux
    private var kickPicker: OnlinePeakPicker
    private var broadbandPicker: OnlinePeakPicker
    /// Шагов подряд, где самая громкая полоса ниже `silenceLevelDB`.
    private var silentHops = 0
    /// Сколько еще шагов после возврата звука потоки онсетов начинаются заново.
    private var refillHops = 0

    private var spectrum: [Float]
    private var levelsDB: [Float]
    private var normalized: [Float]
    private var bandAmplitudes: [Float]

    public init(sampleRate: Double) {
        let config = AnalysisConfig(sampleRate: sampleRate)
        self.config = config
        let mapper = BandMapper(fftSize: config.fftSize, sampleRate: sampleRate)
        fft = RealFFT(size: config.fftSize)
        self.mapper = mapper
        layerRanges = Self.makeLayerRanges(for: mapper)
        levelProcessor = Self.makeLevelProcessor(for: mapper)
        smoothers = Self.makeSmoothers()
        bassSmoothers = Self.makeBassSmoothers(layerRanges)
        kickBins = Self.makeKickBins(for: config)
        kickFlux = Self.makeKickFlux(bins: kickBins)
        broadbandFlux = Self.makeBroadbandFlux(for: mapper)
        kickPicker = OnlinePeakPicker(hopDuration: config.hopDuration, parameters: Self.kickPickerParameters)
        broadbandPicker = OnlinePeakPicker(hopDuration: config.hopDuration, parameters: Self.broadbandPickerParameters)
        spectrum = [Float](repeating: 0, count: config.fftSize / 2)
        levelsDB = [Float](repeating: Self.floorDB, count: BandMapper.bandCount)
        normalized = [Float](repeating: 0, count: BandMapper.bandCount)
        bandAmplitudes = [Float](repeating: 0, count: BandMapper.bandCount)
    }

    /// Новые размеры и таблицы под частоту, все состояние начинается заново.
    public func reconfigure(sampleRate: Double) {
        let config = AnalysisConfig(sampleRate: sampleRate)
        self.config = config
        let mapper = BandMapper(fftSize: config.fftSize, sampleRate: sampleRate)
        fft = RealFFT(size: config.fftSize)
        self.mapper = mapper
        layerRanges = Self.makeLayerRanges(for: mapper)
        bassSmoothers = Self.makeBassSmoothers(layerRanges)
        kickBins = Self.makeKickBins(for: config)
        kickFlux = Self.makeKickFlux(bins: kickBins)
        broadbandFlux = Self.makeBroadbandFlux(for: mapper)
        kickPicker = OnlinePeakPicker(hopDuration: config.hopDuration, parameters: Self.kickPickerParameters)
        broadbandPicker = OnlinePeakPicker(hopDuration: config.hopDuration, parameters: Self.broadbandPickerParameters)
        spectrum = [Float](repeating: 0, count: config.fftSize / 2)
        reset()
    }

    /// Пауза, перемотка или смена источника: уровни, пики автоуровня, сглаживание, огибающая,
    /// история функций онсетов и выбор пиков начинаются заново.
    ///
    /// `keepOnsetFloor` (пауза в том же треке, как `BeatTracker.reset(keepTempo:)`): типичный пик и уровень
    /// акцента выбора пиков остаются (`OnlinePeakPicker.reset(keepTypical:)`), и порог широкополосной
    /// функции, опущенный на тихой аранжировке, не возвращается к 10 на 7 с после каждой паузы.
    public func reset(keepOnsetFloor: Bool = false) {
        levelProcessor = Self.makeLevelProcessor(for: mapper)
        for index in smoothers.indices {
            smoothers[index].reset()
        }
        for index in bassSmoothers.indices {
            bassSmoothers[index].reset()
        }
        envelope = BeatEnvelope(decay: Self.envelopeDecay)
        kickFlux.reset()
        broadbandFlux.reset()
        kickPicker.reset(keepTypical: keepOnsetFloor)
        broadbandPicker.reset(keepTypical: keepOnsetFloor)
        silentHops = 0
        refillHops = 0
    }

    /// Смена трека: типичный пик и уровень акцента выбора пиков начинаются заново (порог широкополосной
    /// функции снова 10), остальное остается. Новый трек не наследует порог прежнего, в том числе
    /// сохраненный сбросом `reset(keepOnsetFloor: true)` на паузе прежнего трека перед сменой.
    public func resetOnsetFloor() {
        kickPicker.resetTypicalPeak()
        broadbandPicker.resetTypicalPeak()
    }

    /// Остров снова виден после простоя: история функций онсетов и выбор пиков вместе со следящими
    /// пиками начинаются заново, уровни, автоуровень, сглаживание и огибающая удара остаются. В
    /// простое шаги идут по одному на пробуждение, следящий пик спадает за шаг, а не за 5.3 мс, и
    /// без сброса держал бы порог онсетов высоким еще секунды.
    public func resetOnsets() {
        kickFlux.reset()
        broadbandFlux.reset()
        kickPicker.reset()
        broadbandPicker.reset()
    }

    /// Спектр окна в `spectrum`. БПФ приходит по ссылке (`inout`), а не чтением свойства: метод
    /// структуры на свойстве класса или внутри замыкания вызывался с копией `RealFFT` (удержание и
    /// освобождение всех ее массивов) на каждом шаге. `fft` и `spectrum` разные свойства, доступ к
    /// ним одновременно разрешен.
    private static func amplitudeSpectrum(_ window: UnsafeBufferPointer<Float>, fft: inout RealFFT, into spectrum: inout [Float]) {
        fft.amplitudeSpectrum(window, into: &spectrum)
    }

    /// Анализирует окно, которое заканчивается сэмплом потока `endSample` (не включая его).
    /// `dt`: на сколько секунд сдвигаются автоуровень, сглаживание полос и огибающая удара; по
    /// умолчанию длина шага. Простой острова берет один шаг на пробуждение и передает время с
    /// прошлого пробуждения, чтобы уровни не отставали. Выбор пиков онсетов всегда идет по шагам.
    /// - Precondition: `window.count == config.fftSize`.
    public func processHop(
        window: UnsafeBufferPointer<Float>,
        endSample: Int,
        settings: LevelSettings,
        dt: Double? = nil
    ) -> HopResult {
        precondition(window.count == config.fftSize, "window.count must equal config.fftSize")
        let rate = config.sampleRate
        let dt = dt.map { $0.isFinite ? max($0, 0) : 0 } ?? config.hopDuration

        Self.amplitudeSpectrum(window, fft: &fft, into: &spectrum)
        spectrum.withUnsafeBufferPointer { spectrum in
            levelsDB.withUnsafeMutableBufferPointer { mapper.bandLevels(spectrum, into: $0) }
        }

        // Самая громкая полоса до нормализации; по ней же тишина перед потоками онсетов.
        var maxLevelDB = Self.floorDB
        for band in 0..<BandMapper.bandCount {
            let db = levelsDB[band].isNaN ? Self.floorDB : levelsDB[band]
            maxLevelDB = max(maxLevelDB, db)
        }
        let soundReturned = trackSilence(maxLevelDB)

        // Бочка: поток по бинам до 150 Гц и их мощность.
        var kickPower: Float = 0
        let kickODF = spectrum.withUnsafeBufferPointer { spectrum in
            let bins = UnsafeBufferPointer(rebasing: spectrum[kickBins])
            for a in bins {
                kickPower += a * a
            }
            return kickFlux.process(bins)
        }
        // Мощность делится на ENBW окна Ханна один раз, как у полос `BandMapper`: сумма A_k² по
        // бинам синуса амплитуды A уже равна 1.5 A², поэтому синус дает A² (0.5 → -6.02 dBFS).
        let kickPowerDB = 10 * log10(kickPower / Self.hannENBW)
        let kickLevelDB = kickPowerDB.isNaN ? Self.floorDB : max(kickPowerDB, Self.floorDB)

        // Широкополосный поток по амплитудам 24 полос (корень мощности полосы).
        for band in 0..<BandMapper.bandCount {
            let db = levelsDB[band].isNaN ? Self.floorDB : levelsDB[band]
            bandAmplitudes[band] = Float(pow(10, Double(db) / 20))
        }
        let broadbandODF = bandAmplitudes.withUnsafeBufferPointer { broadbandFlux.process($0) }

        let onsetTime = Double(endSample) / rate - Self.onsetLag
        let kickOnset = kickPicker.process(kickODF, levelDB: kickLevelDB).map { strength in
            OnsetEvent(
                time: onsetTime - Double(kickPicker.lastOnsetDelay) * config.hopDuration,
                strength: strength, sustained: kickPicker.lastOnsetSustained
            )
        }
        let broadbandOnset = broadbandPicker.process(broadbandODF, levelDB: maxLevelDB)
            .map { OnsetEvent(time: onsetTime, strength: $0) }

        // Уровни волн: нормировка, сглаживание, слой это половина пика и половина среднего его полос.
        levelsDB.withUnsafeBufferPointer { levelsDB in
            normalized.withUnsafeMutableBufferPointer {
                levelProcessor.normalize(levelsDB, dt: dt, settings: settings, into: $0)
            }
        }
        var bands = [Float](repeating: 0, count: BandMapper.bandCount)
        let bassRange = layerRanges[WaveLayer.bass.rawValue]
        for band in 0..<BandMapper.bandCount {
            if bassRange.contains(band) {
                bands[band] = bassSmoothers[band - bassRange.lowerBound].step(toward: normalized[band], dt: dt)
            } else {
                bands[band] = smoothers[band].step(toward: normalized[band], dt: dt)
            }
        }
        var layers = [Float](repeating: 0, count: layerRanges.count)
        for layer in 0..<layerRanges.count {
            let range = layerRanges[layer]
            guard !range.isEmpty else { continue }
            var peak: Float = 0
            var sum: Float = 0
            for band in range {
                peak = max(peak, bands[band])
                sum += bands[band]
            }
            layers[layer] = 0.5 * peak + 0.5 * sum / Float(range.count)
        }

        envelope.step(dt: dt)
        if kickOnset != nil { envelope.trigger() }

        let frame = WaveFrame(
            bands: bands,
            layers: layers,
            beat: envelope.value,
            level: layers.max() ?? 0,
            rawLevelDB: maxLevelDB
        )
        return HopResult(
            frame: frame,
            frameTime: Double(endSample - config.fftSize / 2) / rate,
            endTime: Double(endSample) / rate,
            kickOnset: kickOnset,
            broadbandOnset: broadbandOnset,
            broadbandODF: broadbandODF,
            kickODF: kickODF,
            kickLevelDB: kickLevelDB,
            soundReturned: soundReturned
        )
    }

    /// Тишина перед потоками онсетов шага: `true` на первом шаге со звуком после `silenceGap` тишины. С
    /// этого шага потоки онсетов начинаются заново, пока окно не выйдет из тишины.
    private func trackSilence(_ levelDB: Float) -> Bool {
        var returned = false
        if levelDB < Self.silenceLevelDB {
            silentHops = min(silentHops + 1, Int.max - 1)
        } else {
            if Double(silentHops) * config.hopDuration >= Self.silenceGap {
                returned = true
                refillHops = config.fftSize / config.hopSize
            }
            silentHops = 0
        }
        if refillHops > 0 {
            refillHops -= 1
            kickFlux.reset()
            broadbandFlux.reset()
        }
        return returned
    }

    /// Рабочие буферы шага (БПФ, спектр, уровни, нормировка, амплитуды полос) для теста: шаги
    /// не пересоздают и не растят их.
    var workBuffers: [WorkBuffer] {
        [fft.workBuffer, WorkBuffer(spectrum), WorkBuffer(levelsDB), WorkBuffer(normalized), WorkBuffer(bandAmplitudes)]
    }

    private static func makeLayerRanges(for mapper: BandMapper) -> [Range<Int>] {
        WaveLayer.allCases.map { mapper.bands(for: $0) }
    }

    private static func makeLevelProcessor(for mapper: BandMapper) -> LevelProcessor {
        LevelProcessor(layerBands: makeLayerRanges(for: mapper), tiltDB: mapper.tiltDB())
    }

    private static func makeSmoothers() -> [AttackRelease] {
        [AttackRelease](repeating: AttackRelease(attack: attack, release: release), count: BandMapper.bandCount)
    }

    private static func makeBassSmoothers(_ layerRanges: [Range<Int>]) -> [GravityRelease] {
        [GravityRelease](repeating: GravityRelease(), count: layerRanges[WaveLayer.bass.rawValue].count)
    }

    /// Бины с центром до 150 Гц, бин 0 не входит (1-3 при 1024 и 48 кГц).
    private static func makeKickBins(for config: AnalysisConfig) -> Range<Int> {
        let binWidth = config.sampleRate / Double(config.fftSize)
        let last = min(Int((kickMaxHz / binWidth).rounded(.down)), config.fftSize / 2 - 1)
        return 1..<max(last + 1, 2)
    }

    private static func makeKickFlux(bins: Range<Int>) -> SuperFlux {
        SuperFlux(lags: [Int](repeating: 1, count: bins.count), weights: [Float](repeating: 1, count: bins.count))
    }

    private static func makeBroadbandFlux(for mapper: BandMapper) -> SuperFlux {
        SuperFlux(
            lags: mapper.centers.map { $0 < broadbandLagSplitHz ? 1 : 2 },
            weights: mapper.centers.map { $0 >= broadbandHighHz ? broadbandHighWeight : 1 }
        )
    }
}

/// Огибающая удара: 1 в момент удара, затем экспоненциальный спад.
/// Порядок в каждом кадре: сначала `step`, потом `trigger`.
public struct BeatEnvelope: Sendable {
    public let decay: Double
    public private(set) var value: Float = 0

    public init(decay: Double = 0.06) {
        self.decay = decay
    }

    public mutating func trigger() {
        value = 1
    }

    public mutating func step(dt: Double) {
        value *= Float(exp(-dt / decay))
    }
}
