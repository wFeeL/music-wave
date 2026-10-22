import Foundation

public enum LevelMode: String, Codable, Sendable, CaseIterable {
    case auto, absolute
}

public struct LevelSettings: Sendable, Equatable {
    public var mode: LevelMode
    public var sensitivity: Float
    public var followSystemVolume: Bool
    public var systemVolume: Float

    public init(
        mode: LevelMode = .auto,
        sensitivity: Float = 1,
        followSystemVolume: Bool = true,
        systemVolume: Float = 1
    ) {
        self.mode = mode
        self.sensitivity = sensitivity
        self.followSystemVolume = followSystemVolume
        self.systemVolume = systemVolume
    }
}

/// Переводит уровни полос в dBFS в значения 0...1 для рисования волны.
///
/// В режиме `auto` у каждого слоя свой трекер пика: он мгновенно растет, держится `peakHold`
/// секунд и затем падает на `peakReleaseDBPerSecond` дБ в секунду. Слой не опускается
/// ниже глобального пика минус `layerPeakSpreadDB`, поэтому тихий слой не раздувается до
/// полной высоты рядом с громким.
public struct LevelProcessor: Sendable {
    public static let noiseFloorDB: Float = -70
    public static let autoRangeDB: Float = 33
    public static let minPeakDB: Float = -40
    public static let layerPeakSpreadDB: Float = 30
    public static let peakHold: Double = 1.0
    public static let peakReleaseDBPerSecond: Float = 6

    private static let floorDB: Float = -120
    private static let ceilingDB: Float = 6
    private static let absoluteRangeDB: Float = 60
    private static let curveExponent: Float = 1.4

    private struct PeakTracker: Sendable {
        var peak: Float = LevelProcessor.floorDB
        var holdTimer: Double = 0

        mutating func update(with current: Float, dt: Double) {
            if current >= peak {
                peak = current
                holdTimer = 0
            } else {
                holdTimer += dt
                if holdTimer > LevelProcessor.peakHold {
                    peak = max(current, peak - LevelProcessor.peakReleaseDBPerSecond * Float(dt))
                }
            }
        }
    }

    private let layerBands: [Range<Int>]
    /// Слой каждой полосы по `layerBands` (при пересечении побеждает последний), -1 без слоя.
    private let bandLayers: [Int]
    private var trackers: [PeakTracker]

    public init(layerBands: [Range<Int>]) {
        self.layerBands = layerBands
        self.trackers = [PeakTracker](repeating: PeakTracker(), count: layerBands.count)
        var bandLayers = [Int](repeating: -1, count: layerBands.map(\.upperBound).max().map { max($0, 0) } ?? 0)
        for (layer, range) in layerBands.enumerated() {
            for band in range where band >= 0 {
                bandLayers[band] = layer
            }
        }
        self.bandLayers = bandLayers
    }

    public mutating func normalize(_ levelsDB: [Float], dt: Double, settings: LevelSettings) -> [Float] {
        var output = [Float](repeating: 0, count: levelsDB.count)
        levelsDB.withUnsafeBufferPointer { levelsDB in
            output.withUnsafeMutableBufferPointer { normalize(levelsDB, dt: dt, settings: settings, into: $0) }
        }
        return output
    }

    /// То же, что `normalize(_:dt:settings:)`, но в готовый буфер и без выделения памяти.
    /// - Precondition: `output.count == levelsDB.count`.
    public mutating func normalize(
        _ levelsDB: UnsafeBufferPointer<Float>,
        dt: Double,
        settings: LevelSettings,
        into output: UnsafeMutableBufferPointer<Float>
    ) {
        precondition(output.count == levelsDB.count, "output.count must equal levelsDB.count")
        let dt = dt.isFinite ? max(dt, 0) : 0
        let count = levelsDB.count

        var globalPeak = Self.floorDB
        if settings.mode == .auto {
            for layer in layerBands.indices {
                var layerMax = Self.floorDB
                for band in layerBands[layer] where band >= 0 && band < count {
                    // +inf это испорченный вход: он ограничивается на выходе, но пик не двигает.
                    if levelsDB[band] != .infinity {
                        layerMax = max(layerMax, Self.clamped(levelsDB[band]))
                    }
                }
                trackers[layer].update(with: layerMax, dt: dt)
                globalPeak = max(globalPeak, trackers[layer].peak)
            }
        }

        let sensitivity = settings.sensitivity.isFinite ? max(settings.sensitivity, 0) : 1
        let volumeGain = settings.followSystemVolume
            ? (settings.systemVolume.isFinite ? max(settings.systemVolume, 0) : 1).squareRoot()
            : 1

        for band in 0..<count {
            let db = Self.clamped(levelsDB[band])
            var x: Float
            switch settings.mode {
            case .auto:
                let layer = band < bandLayers.count ? bandLayers[band] : -1
                let layerPeak = layer >= 0 ? trackers[layer].peak : Self.floorDB
                let effectivePeak = max(layerPeak, globalPeak - Self.layerPeakSpreadDB, Self.minPeakDB)
                let lo = max(effectivePeak - Self.autoRangeDB, Self.noiseFloorDB)
                x = (db - lo) / max(effectivePeak - lo, 1)
            case .absolute:
                x = (db + Self.absoluteRangeDB) / Self.absoluteRangeDB
            }
            x = db < Self.noiseFloorDB ? 0 : min(max(x, 0), 1)
            x = pow(x, Self.curveExponent) * sensitivity * volumeGain
            output[band] = min(max(x, 0), 1)
        }
    }

    /// Значения выше +6 dB ограничиваются, NaN и -inf становятся -120.
    private static func clamped(_ db: Float) -> Float {
        db.isNaN ? floorDB : min(max(db, floorDB), ceilingDB)
    }
}
