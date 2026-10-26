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

/// Автоуровень слоя с мертвой зоной (как в cava и WLED): опора нормировки, которая сразу встает на
/// громкий пик, а на спаде идет за ним медленно, пока пик в зоне, и быстро, когда пик ушел ниже нее.
///
/// Доля `p = (peak - (ref - range)) / range` показывает, где удержанный пик слоя стоит в диапазоне
/// под опорой. Порядок правил в `update`:
/// 1. Уровень слоя в этом кадре ниже `LevelProcessor.noiseFloorDB`: опора и `isFast` стоят на месте.
///    Удержанный пик для этого не годится: после конца музыки он еще 1 с держится, потом падает
///    на 6 дБ/с, и опора около 9 с уходила бы за ним к полу.
/// 2. Пик не ниже опоры: опора сразу встает на пик, быстрый путь снимается.
/// 3. Иначе разрыв `gap = ref - peak`. Если `gap <= fastExitDB`, быстрый путь снимается, иначе при
///    `p` ниже `zone` он включается (защелка). Опора идет к пику экспонентой
///    `ref = peak + gap * exp(-dt / tau)`, `tau` это `fastTau` на быстром пути и `slowTau` иначе.
///    Защелка держит быстрый путь, пока опора не подойдет к пику на `fastExitDB`, даже когда `p`
///    уже вернулась в зону.
/// 4. Верх зоны (`p > 0.85`) быстрый путь не включает. Иначе на спаде удержанного пика (6 дБ/с)
///    опора отставала бы от него всего на 6 × 0.15 = 0.9 дБ, и куплет на 6 дБ тише через 2 с
///    вставал бы на уровень припева.
public struct DeadBandAGC: Sendable {
    /// Мертвая зона по доле `p`: внутри и выше нее опора идет медленно.
    public static let zone: ClosedRange<Float> = 0.4...0.85
    /// Постоянная времени медленного пути, с.
    public static let slowTau = 8.0
    /// Постоянная времени быстрого пути, с.
    public static let fastTau = 0.15
    /// Быстрый путь снимается, когда опора подошла к пику на столько дБ.
    public static let fastExitDB: Float = 0.5

    /// Опора нормировки слоя, dB.
    public private(set) var referenceDB: Float
    /// Включен ли быстрый путь (защелка).
    public private(set) var isFast = false

    public init(referenceDB: Float = -120) {
        self.referenceDB = referenceDB
    }

    /// Сдвигает опору на `dt` секунд. `heldPeakDB` это пик трекера слоя, `currentDB` максимум полос
    /// слоя в этом кадре без наклона спектра (по нему решается правило 1: шипение верхов с
    /// наклоном не считается звуком). `rangeDB` меньше 1 дБ считается за 1 дБ.
    public mutating func update(heldPeakDB: Float, currentDB: Float, rangeDB: Float = LevelProcessor.autoRangeDB, dt: Double) {
        guard currentDB >= LevelProcessor.noiseFloorDB, !heldPeakDB.isNaN else { return }
        if heldPeakDB >= referenceDB {
            referenceDB = heldPeakDB
            isFast = false
            return
        }
        let dt = dt.isFinite ? max(dt, 0) : 0
        let range = rangeDB.isFinite ? max(rangeDB, 1) : LevelProcessor.autoRangeDB
        let gap = referenceDB - heldPeakDB
        let share = (heldPeakDB - (referenceDB - range)) / range
        if gap <= Self.fastExitDB {
            isFast = false
        } else if share < Self.zone.lowerBound {
            isFast = true
        }
        let tau = isFast ? Self.fastTau : Self.slowTau
        referenceDB = heldPeakDB + gap * Float(exp(-dt / tau))
    }
}

/// Переводит уровни полос в dBFS в значения 0...1 для рисования волны.
///
/// В режиме `auto` у каждого слоя свой трекер пика: он мгновенно растет, держится `peakHold`
/// секунд и затем падает на `peakReleaseDBPerSecond` дБ в секунду. Нормирует слой не сам пик, а
/// опора `DeadBandAGC`, которая идет за пиком с мертвой зоной, поэтому тихий куплет остается
/// ниже громкого припева. Слой не опускается ниже наибольшей опоры минус `layerPeakSpreadDB`,
/// поэтому тихий слой не раздувается до полной высоты рядом с громким.
///
/// Наклон спектра `tiltDB` (дБ на полосу, `BandMapper.tiltDB()`) прибавляется к уровням только в
/// режиме `auto`, до трекеров пика, чтобы верхи двигались на хэтах. Порог шума `noiseFloorDB`
/// и заморозка опоры в тишине проверяются по уровню без наклона: шипение не поднимается и не
/// считается звуком.
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
    private var agcs: [DeadBandAGC]
    /// Наклон по полосам, дБ; полосы за концом массива без наклона.
    private let tiltDB: [Float]

    /// Опоры автоуровня по слоям, dB (для тестов).
    var layerReferencesDB: [Float] { agcs.map(\.referenceDB) }

    /// - Parameter tiltDB: наклон спектра по полосам в дБ для режима `auto`, пустой массив без наклона.
    public init(layerBands: [Range<Int>], tiltDB: [Float] = []) {
        self.layerBands = layerBands
        self.tiltDB = tiltDB.map { $0.isFinite ? $0 : 0 }
        self.trackers = [PeakTracker](repeating: PeakTracker(), count: layerBands.count)
        self.agcs = [DeadBandAGC](repeating: DeadBandAGC(), count: layerBands.count)
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

        var globalReference = Self.floorDB
        if settings.mode == .auto {
            for layer in layerBands.indices {
                // Максимум слоя с наклоном идет в трекер, без наклона решает, тишина ли это.
                var layerMax = Self.floorDB
                var untiltedMax = Self.floorDB
                for band in layerBands[layer] where band >= 0 && band < count {
                    // +inf это испорченный вход: он ограничивается на выходе, но пик не двигает.
                    if levelsDB[band] != .infinity {
                        let db = Self.clamped(levelsDB[band])
                        layerMax = max(layerMax, db + tilt(band))
                        untiltedMax = max(untiltedMax, db)
                    }
                }
                trackers[layer].update(with: layerMax, dt: dt)
                agcs[layer].update(heldPeakDB: trackers[layer].peak, currentDB: untiltedMax, dt: dt)
                globalReference = max(globalReference, agcs[layer].referenceDB)
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
                let layerReference = layer >= 0 ? agcs[layer].referenceDB : Self.floorDB
                let effectivePeak = max(layerReference, globalReference - Self.layerPeakSpreadDB, Self.minPeakDB)
                let lo = max(effectivePeak - Self.autoRangeDB, Self.noiseFloorDB)
                x = (db + tilt(band) - lo) / max(effectivePeak - lo, 1)
            case .absolute:
                x = (db + Self.absoluteRangeDB) / Self.absoluteRangeDB
            }
            x = db < Self.noiseFloorDB ? 0 : min(max(x, 0), 1)
            x = pow(x, Self.curveExponent) * sensitivity * volumeGain
            output[band] = min(max(x, 0), 1)
        }
    }

    private func tilt(_ band: Int) -> Float {
        band < tiltDB.count ? tiltDB[band] : 0
    }

    /// Значения выше +6 dB ограничиваются, NaN и -inf становятся -120.
    private static func clamped(_ db: Float) -> Float {
        db.isNaN ? floorDB : min(max(db, floorDB), ceilingDB)
    }
}
