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

    public init(time: Double, strength: Float) {
        self.time = time
        self.strength = strength
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

    public init(
        frame: WaveFrame,
        frameTime: Double,
        endTime: Double,
        kickOnset: OnsetEvent?,
        broadbandOnset: OnsetEvent?,
        broadbandODF: Float,
        kickODF: Float = 0,
        kickLevelDB: Float
    ) {
        self.frame = frame
        self.frameTime = frameTime
        self.endTime = endTime
        self.kickOnset = kickOnset
        self.broadbandOnset = broadbandOnset
        self.broadbandODF = broadbandODF
        self.kickODF = kickODF
        self.kickLevelDB = kickLevelDB
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
    static let kickPickerParameters = OnlinePeakPicker.Parameters(floor: 2.0, relativeFloor: 0.25, minRiseDB: 7.5)
    /// Выбор пиков широкополосной функции. Проверки подъема уровня нет: уровень здесь это
    /// максимум полос, его почти всегда держит бочка или бас, и хэт между ними его не поднимает
    /// (с проверкой 9 дБ хип-хоп дает F 0.6). Шум отсекает порог odf 10: у розового шума -20 dBFS
    /// пики около 8, у хэта от 30, у бочки и малого 70-90. При пороге 12 на GTZAN (полоса до 11 кГц)
    /// у половины долей не было онсета, и трекер редко набирал попадания для захвата.
    static let broadbandPickerParameters = OnlinePeakPicker.Parameters(floor: 10, minRiseDB: -.infinity)
    private static let hannENBW: Float = 1.5
    private static let floorDB: Float = -120

    public private(set) var config: AnalysisConfig

    private var fft: RealFFT
    private var mapper: BandMapper
    /// Полосы каждого слоя по `WaveLayer.rawValue`. `WaveLayer.allCases` на каждом шаге выделял бы массив.
    private var layerRanges: [Range<Int>]
    private var levelProcessor: LevelProcessor
    private var smoothers: [AttackRelease]
    private var envelope = BeatEnvelope(decay: StreamAnalyzer.envelopeDecay)
    private var kickBins: Range<Int>
    private var kickFlux: SuperFlux
    private var broadbandFlux: SuperFlux
    private var kickPicker: OnlinePeakPicker
    private var broadbandPicker: OnlinePeakPicker

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
    public func reset() {
        levelProcessor = Self.makeLevelProcessor(for: mapper)
        for index in smoothers.indices {
            smoothers[index].reset()
        }
        envelope = BeatEnvelope(decay: Self.envelopeDecay)
        kickFlux.reset()
        broadbandFlux.reset()
        kickPicker.reset()
        broadbandPicker.reset()
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
        var maxLevelDB = Self.floorDB
        for band in 0..<BandMapper.bandCount {
            let db = levelsDB[band].isNaN ? Self.floorDB : levelsDB[band]
            maxLevelDB = max(maxLevelDB, db)
            bandAmplitudes[band] = Float(pow(10, Double(db) / 20))
        }
        let broadbandODF = bandAmplitudes.withUnsafeBufferPointer { broadbandFlux.process($0) }

        let onsetTime = Double(endSample) / rate - Self.onsetLag
        let kickOnset = kickPicker.process(kickODF, levelDB: kickLevelDB)
            .map { OnsetEvent(time: onsetTime, strength: $0) }
        let broadbandOnset = broadbandPicker.process(broadbandODF, levelDB: maxLevelDB)
            .map { OnsetEvent(time: onsetTime, strength: $0) }

        // Уровни волн: нормировка, сглаживание, слой это половина пика и половина среднего его полос.
        levelsDB.withUnsafeBufferPointer { levelsDB in
            normalized.withUnsafeMutableBufferPointer {
                levelProcessor.normalize(levelsDB, dt: dt, settings: settings, into: $0)
            }
        }
        var bands = [Float](repeating: 0, count: BandMapper.bandCount)
        for band in 0..<BandMapper.bandCount {
            bands[band] = smoothers[band].step(toward: normalized[band], dt: dt)
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
            kickLevelDB: kickLevelDB
        )
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
        LevelProcessor(layerBands: makeLayerRanges(for: mapper))
    }

    private static func makeSmoothers() -> [AttackRelease] {
        [AttackRelease](repeating: AttackRelease(attack: attack, release: release), count: BandMapper.bandCount)
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
