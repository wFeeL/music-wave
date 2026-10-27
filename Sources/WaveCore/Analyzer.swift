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
    /// Энергия атак для мягкого пульса (`BeatTracker.ambientEnergy`, `AmbientInfo.energy`) на момент
    /// кадра: анализ кладет ее в кадр, чтобы она шла по слышимой оси вместе с уровнями
    /// (`BeatGlow.ambient(at:info:frame:)`). 0 без трекера.
    public var kickEnergy: Float

    public static let silent = WaveFrame(
        bands: [Float](repeating: 0, count: BandMapper.bandCount),
        layers: [Float](repeating: 0, count: WaveLayer.allCases.count),
        beat: 0,
        level: 0,
        rawLevelDB: -120
    )

    public init(bands: [Float], layers: [Float], beat: Float, level: Float, rawLevelDB: Float, kickEnergy: Float = 0) {
        self.bands = bands
        self.layers = layers
        self.beat = beat
        self.level = level
        self.rawLevelDB = rawLevelDB
        self.kickEnergy = kickEnergy
    }

    /// Линейное смешение всех чисел кадра: `fraction` 0 дает `from`, 1 дает `to`, значения вне
    /// 0...1 прижимаются к краям, NaN считается 1. Массивы разной длины не смешиваются, берутся
    /// из `to`.
    public static func interpolated(from: WaveFrame, to: WaveFrame, fraction: Float) -> WaveFrame {
        let t = fraction.isNaN ? 1 : min(max(fraction, 0), 1)
        if t == 0 { return from }
        if t == 1 { return to }
        func mix(_ a: Float, _ b: Float) -> Float {
            a + (b - a) * t
        }
        func mix(_ a: [Float], _ b: [Float]) -> [Float] {
            guard a.count == b.count else { return b }
            return zip(a, b).map { mix($0, $1) }
        }
        return WaveFrame(
            bands: mix(from.bands, to.bands),
            layers: mix(from.layers, to.layers),
            beat: mix(from.beat, to.beat),
            level: mix(from.level, to.level),
            rawLevelDB: mix(from.rawLevelDB, to.rawLevelDB),
            kickEnergy: mix(from.kickEnergy, to.kickEnergy)
        )
    }
}

/// История кадров анализа с метками времени хоста, безопасно читается с любого потока.
///
/// Анализ публикует кадр с моментом, к которому он относится (секунды хоста, те же часы, что
/// `CACurrentMediaTime()` и `DispatchTime.now().uptimeNanoseconds`). Отрисовка берет кадр на
/// свой момент (`frame(at:)`): между соседними кадрами значения смешиваются линейно, поэтому
/// уровни меняются на каждом кадре экрана, даже когда часы анализа и экрана расходятся по фазе.
/// Хранятся последние `capacity` кадров и последнее расписание свечения (`publishSchedule`).
public final class FrameStore: Sendable {
    public static let capacity = 128

    private struct Entry: Sendable {
        var time: Double
        var frame: WaveFrame
    }

    /// Кольцо кадров по возрастанию времени: самый старый в `entries[start]`. Пустое кольцо
    /// значит, что после `reset(to:)` ничего не публиковалось и действует `held`.
    private struct History: Sendable {
        var entries: [Entry] = []
        var start = 0
        var held = WaveFrame.silent
        var sequence: UInt64 = 0
        var schedule = BeatSchedule.empty

        var count: Int { entries.count }

        func entry(_ index: Int) -> Entry {
            entries[(start + index) % entries.count]
        }

        var newest: Entry? {
            entries.isEmpty ? nil : entry(entries.count - 1)
        }

        mutating func clear(holding frame: WaveFrame) {
            entries.removeAll(keepingCapacity: true)
            start = 0
            held = frame
        }

        mutating func append(_ item: Entry) {
            if entries.count < FrameStore.capacity {
                entries.append(item)
            } else {
                entries[start] = item
                start = (start + 1) % entries.count
            }
        }

        mutating func replaceNewest(with item: Entry) {
            entries[(start + entries.count - 1) % entries.count] = item
        }

        /// Два соседних кадра вокруг `time` и доля второго. Смешение идет вне блокировки, под
        /// ней только копии кадров (счетчики ссылок массивов).
        func neighbours(at time: Double) -> (before: WaveFrame, after: WaveFrame, fraction: Float) {
            guard let newest else { return (held, held, 0) }
            guard time.isFinite, time < newest.time else { return (newest.frame, newest.frame, 0) }
            let oldest = entry(0)
            guard time > oldest.time else { return (oldest.frame, oldest.frame, 0) }
            // Первый кадр не раньше `time`: он есть, потому что `time < newest.time`.
            var low = 1
            var high = count - 1
            while low < high {
                let middle = (low + high) / 2
                if entry(middle).time < time {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            let after = entry(low)
            let before = entry(low - 1)
            let span = after.time - before.time
            guard span > 0 else { return (after.frame, after.frame, 0) }
            return (before.frame, after.frame, Float((time - before.time) / span))
        }
    }

    private let state = Mutex(History())

    public init() {}

    /// Кадр, который относится к моменту `time` (секунды хоста). Момент раньше самого нового
    /// означает, что часы начались заново: история сначала очищается. Кадр с тем же моментом,
    /// что у самого нового, заменяет его. Без конечного момента история состоит из одного этого
    /// кадра, как после `reset(to:)`.
    public func publish(_ frame: WaveFrame, at time: Double) {
        state.withLock { history in
            history.sequence &+= 1
            guard time.isFinite else {
                history.clear(holding: frame)
                return
            }
            let item = Entry(time: time, frame: frame)
            if let newest = history.newest {
                if time < newest.time {
                    history.clear(holding: frame)
                } else if time == newest.time {
                    history.replaceNewest(with: item)
                    return
                }
            }
            history.append(item)
        }
    }

    /// История становится одним кадром `frame`, который действует в любой момент, расписание
    /// свечения пустым. Номер публикации (`sequence`) не меняется.
    public func reset(to frame: WaveFrame = .silent) {
        state.withLock { history in
            history.clear(holding: frame)
            history.schedule = .empty
        }
    }

    /// Новое расписание свечения (времена событий в слышимых секундах хоста) заменяет прежнее.
    /// История кадров и `sequence` не меняются.
    public func publishSchedule(_ schedule: BeatSchedule) {
        state.withLock { $0.schedule = schedule }
    }

    /// Последнее расписание свечения; пустое до первой публикации и после `reset(to:)`.
    public var schedule: BeatSchedule {
        state.withLock { $0.schedule }
    }

    /// Последний опубликованный кадр (или кадр `reset(to:)`).
    public var latest: WaveFrame {
        state.withLock { $0.newest?.frame ?? $0.held }
    }

    /// Момент самого нового кадра; `nil` после `reset(to:)`, пока ничего не опубликовано.
    public var newestTime: Double? {
        state.withLock { $0.newest?.time }
    }

    /// Сколько раз вызывался `publish`: отрисовка по разнице видит, сколько новых кадров
    /// анализа пришло между ее кадрами.
    public var sequence: UInt64 {
        state.withLock { $0.sequence }
    }

    /// Кадр на момент `time`: линейно между двумя соседними кадрами истории, до самого старого
    /// кадра это самый старый, после самого нового самый новый.
    public func frame(at time: Double) -> WaveFrame {
        let (before, after, fraction) = state.withLock { $0.neighbours(at: time) }
        return fraction == 0 ? before : WaveFrame.interpolated(from: before, to: after, fraction: fraction)
    }
}
