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
    private var trackers: [PeakTracker]

    public init(layerBands: [Range<Int>]) {
        self.layerBands = layerBands
        self.trackers = [PeakTracker](repeating: PeakTracker(), count: layerBands.count)
    }

    public mutating func normalize(_ levelsDB: [Float], dt: Double, settings: LevelSettings) -> [Float] {
        let dt = dt.isFinite ? max(dt, 0) : 0
        // Значения выше +6 dB ограничиваются, NaN и -inf становятся -120.
        let levels = levelsDB.map { $0.isNaN ? Self.floorDB : min(max($0, Self.floorDB), Self.ceilingDB) }

        var layerOfBand = [Int?](repeating: nil, count: levels.count)
        var globalPeak = Self.floorDB
        if settings.mode == .auto {
            for (layer, range) in layerBands.enumerated() {
                var layerMax = Self.floorDB
                for band in range where band >= 0 && band < levels.count {
                    layerOfBand[band] = layer
                    // +inf это испорченный вход: он ограничивается на выходе, но пик не двигает.
                    if levelsDB[band] != .infinity {
                        layerMax = max(layerMax, levels[band])
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

        return levels.enumerated().map { band, db in
            var x: Float
            switch settings.mode {
            case .auto:
                let layerPeak = layerOfBand[band].map { trackers[$0].peak } ?? Self.floorDB
                let effectivePeak = max(layerPeak, globalPeak - Self.layerPeakSpreadDB, Self.minPeakDB)
                let lo = max(effectivePeak - Self.autoRangeDB, Self.noiseFloorDB)
                x = (db - lo) / max(effectivePeak - lo, 1)
            case .absolute:
                x = (db + Self.absoluteRangeDB) / Self.absoluteRangeDB
            }
            x = db < Self.noiseFloorDB ? 0 : min(max(x, 0), 1)
            x = pow(x, Self.curveExponent) * sensitivity * volumeGain
            return min(max(x, 0), 1)
        }
    }
}
