import Foundation
import Synchronization

/// Один кадр анализа: то, что нужно рисовать.
public struct WaveFrame: Sendable, Equatable {
    /// 24 значения 0...1.
    public var bands: [Float]
    /// 3 значения 0...1 по `WaveLayer.rawValue`.
    public var layers: [Float]
    /// Огибающая удара 0...1.
    public var beat: Float
    /// Максимум `layers`.
    public var level: Float
    /// Максимальный уровень полосы в dBFS до нормализации.
    public var rawLevelDB: Float

    public static let silent = WaveFrame(
        bands: [Float](repeating: 0, count: BandMapper.bandCount),
        layers: [Float](repeating: 0, count: WaveLayer.allCases.count),
        beat: 0,
        level: 0,
        rawLevelDB: -120
    )

    public init(bands: [Float], layers: [Float], beat: Float, level: Float, rawLevelDB: Float) {
        self.bands = bands
        self.layers = layers
        self.beat = beat
        self.level = level
        self.rawLevelDB = rawLevelDB
    }
}

/// Конвейер анализа: БПФ, полосы, детектор ударов, нормировка, сглаживание, слои.
///
/// Вызывается с очереди анализа 60 Гц, не из аудио-колбэка: на каждый вызов выделяется память.
/// Не потокобезопасен, все вызовы с одной очереди.
public final class Analyzer {
    public static let fftSize = 2048

    /// Пауза между вызовами, после которой история считается устаревшей.
    private static let staleGap = 0.5
    /// Верхняя граница центра полосы, которая идет в детектор ударов.
    private static let beatMaxHz = 150.0

    public private(set) var sampleRate: Double

    private let fft = RealFFT(size: Analyzer.fftSize)
    private var mapper: BandMapper
    private var levelProcessor: LevelProcessor
    private var lowBands: [Int]
    private var smoothers: [AttackRelease]
    private var detector = BeatDetector()
    private var envelope = BeatEnvelope()
    private var lastTime: Double?

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        let mapper = BandMapper(fftSize: Self.fftSize, sampleRate: sampleRate)
        self.mapper = mapper
        self.levelProcessor = Self.makeLevelProcessor(for: mapper)
        self.lowBands = Self.makeLowBands(for: mapper)
        self.smoothers = Self.makeSmoothers()
    }

    /// Пересоздает таблицы полос под новую частоту и сбрасывает детектор и сглаживание.
    public func reconfigure(sampleRate: Double) {
        self.sampleRate = sampleRate
        let mapper = BandMapper(fftSize: Self.fftSize, sampleRate: sampleRate)
        self.mapper = mapper
        lowBands = Self.makeLowBands(for: mapper)
        resetDynamics()
    }

    /// - Parameters:
    ///   - samples: последнее окно, ровно `fftSize` сэмплов.
    ///   - time: время конца окна в секундах.
    ///   - dt: время с прошлого кадра в секундах.
    public func process(samples: [Float], time: Double, dt: Double, settings: LevelSettings) -> WaveFrame {
        precondition(samples.count == Self.fftSize, "samples.count must equal fftSize")

        // Пауза или перемотка времени: история детектора, сглаживание и пики автоуровня устарели.
        if let lastTime, time - lastTime > Self.staleGap || time < lastTime {
            resetDynamics()
        }
        lastTime = time

        let spectrum = fft.amplitudeSpectrum(samples)
        let levelsDB = mapper.bandLevels(spectrum).map { $0.isNaN ? -120 : $0 }

        let lowAmplitudes = lowBands.map { Float(pow(10.0, Double(levelsDB[$0]) / 20)) }
        let isBeat = detector.process(lowBandAmplitudes: lowAmplitudes, time: time)

        let normalized = levelProcessor.normalize(levelsDB, dt: dt, settings: settings)
        let bands = normalized.indices.map { smoothers[$0].step(toward: normalized[$0], dt: dt) }

        let layers = WaveLayer.allCases.map { layer -> Float in
            let range = mapper.bands(for: layer)
            guard !range.isEmpty else { return 0 }
            let values = bands[range]
            let mean = values.reduce(0, +) / Float(values.count)
            return 0.5 * (values.max() ?? 0) + 0.5 * mean
        }

        envelope.step(dt: dt)
        if isBeat { envelope.trigger() }

        return WaveFrame(
            bands: bands,
            layers: layers,
            beat: envelope.value,
            level: layers.max() ?? 0,
            rawLevelDB: levelsDB.max() ?? -120
        )
    }

    /// Пауза, перемотка или смена частоты: детектор, сглаживание и пики автоуровня начинают
    /// заново, иначе пик громкого припева до паузы держал бы волны тихого трека маленькими.
    private func resetDynamics() {
        detector.reset()
        levelProcessor = Self.makeLevelProcessor(for: mapper)
        envelope = BeatEnvelope()
        smoothers = Self.makeSmoothers()
        lastTime = nil
    }

    private static func makeLevelProcessor(for mapper: BandMapper) -> LevelProcessor {
        LevelProcessor(layerBands: WaveLayer.allCases.map { mapper.bands(for: $0) })
    }

    private static func makeLowBands(for mapper: BandMapper) -> [Int] {
        mapper.centers.indices.filter { mapper.centers[$0] <= beatMaxHz }
    }

    private static func makeSmoothers() -> [AttackRelease] {
        [AttackRelease](repeating: AttackRelease(), count: BandMapper.bandCount)
    }
}

/// Последний опубликованный кадр, безопасно читается с любого потока.
public final class FrameStore: Sendable {
    private let state = Mutex(WaveFrame.silent)

    public init() {}

    public func publish(_ frame: WaveFrame) {
        state.withLock { $0 = frame }
    }

    public var latest: WaveFrame {
        state.withLock { $0 }
    }
}
