import Foundation
import Testing
@testable import WaveCore

struct FrameStoreTests {
    /// Кадр, у которого все числа зависят от `value`: так видно, что интерполируется каждое поле.
    private func frame(layers: [Float], value: Float = 0) -> WaveFrame {
        WaveFrame(
            bands: [Float](repeating: value, count: BandMapper.bandCount),
            layers: layers,
            beat: value,
            level: layers.max() ?? 0,
            rawLevelDB: -60 + 40 * value,
            kickEnergy: 2 * value
        )
    }

    private func frame(_ value: Float) -> WaveFrame {
        frame(layers: [value, value, value], value: value)
    }

    @Test func interpolatesBetweenNeighbours() {
        let store = FrameStore()
        store.publish(frame(layers: [0, 0, 0]), at: 1.0)
        store.publish(frame(layers: [1, 1, 1]), at: 1.02)
        #expect(abs(store.frame(at: 1.005).layers[0] - 0.25) < 1e-6)
    }

    @Test func interpolatesEveryField() {
        let store = FrameStore()
        store.publish(frame(0), at: 1.0)
        store.publish(frame(1), at: 2.0)
        let middle = store.frame(at: 1.5)
        #expect(middle.bands.allSatisfy { abs($0 - 0.5) < 1e-6 })
        #expect(middle.layers.allSatisfy { abs($0 - 0.5) < 1e-6 })
        #expect(abs(middle.beat - 0.5) < 1e-6)
        #expect(abs(middle.level - 0.5) < 1e-6)
        #expect(abs(middle.rawLevelDB - -40) < 1e-4)
        #expect(abs(middle.kickEnergy - 1) < 1e-6)
        #expect(WaveFrame.silent.kickEnergy == 0)
    }

    @Test func interpolatedClampsFraction() {
        let from = frame(0.2)
        let to = frame(0.8)
        #expect(WaveFrame.interpolated(from: from, to: to, fraction: -1) == from)
        #expect(WaveFrame.interpolated(from: from, to: to, fraction: 0) == from)
        #expect(WaveFrame.interpolated(from: from, to: to, fraction: 1) == to)
        #expect(WaveFrame.interpolated(from: from, to: to, fraction: 7) == to)
        #expect(WaveFrame.interpolated(from: from, to: to, fraction: .nan) == to)
    }

    @Test func clampsOutsideHistory() {
        let store = FrameStore()
        let first = frame(0.1)
        let second = frame(0.5)
        let third = frame(0.9)
        store.publish(first, at: 1.0)
        store.publish(second, at: 1.5)
        store.publish(third, at: 2.0)
        #expect(store.frame(at: 0.5) == first)
        #expect(store.frame(at: 1.0) == first)
        #expect(store.frame(at: 1.5) == second)
        #expect(store.frame(at: 9) == third)
        #expect(store.frame(at: .nan) == third)
        #expect(store.latest == third)
        #expect(store.newestTime == 2.0)
    }

    @Test func sequenceCountsPublishes() {
        let store = FrameStore()
        #expect(store.sequence == 0)
        for i in 0..<3 {
            store.publish(frame(Float(i) / 3), at: Double(i))
        }
        #expect(store.sequence == 3)
        store.reset()
        #expect(store.sequence == 3)
        store.publish(frame(1), at: 0)
        #expect(store.sequence == 4)
    }

    @Test func olderTimeRestartsHistory() {
        let store = FrameStore()
        let first = frame(0.2)
        let second = frame(0.7)
        store.publish(first, at: 2.0)
        store.publish(second, at: 1.0)
        #expect(store.newestTime == 1.0)
        #expect(store.frame(at: 1.5) == second)
        #expect(store.frame(at: 0) == second)
        #expect(store.latest == second)
    }

    @Test func sameTimeReplacesNewest() {
        let store = FrameStore()
        let first = frame(0.2)
        let second = frame(0.7)
        store.publish(frame(0), at: 0.5)
        store.publish(first, at: 1.0)
        store.publish(second, at: 1.0)
        #expect(store.latest == second)
        #expect(store.frame(at: 1.0) == second)
        #expect(abs(store.frame(at: 0.75).layers[0] - 0.35) < 1e-6)
    }

    @Test func keepsLast128() {
        #expect(FrameStore.capacity == 128)
        let store = FrameStore()
        var published: [WaveFrame] = []
        for i in 0..<200 {
            let item = frame(Float(i) / 200)
            published.append(item)
            store.publish(item, at: Double(i) / 100)
        }
        #expect(store.frame(at: 0) == published[72])
        #expect(store.frame(at: 0.72) == published[72])
        #expect(store.frame(at: 1.99) == published[199])
        #expect(abs(store.frame(at: 1.005).layers[0] - 100.5 / 200) < 1e-6)
    }

    @Test func resetHoldsOneFrameEverywhere() {
        let store = FrameStore()
        store.publish(frame(0.1), at: 1)
        store.publish(frame(0.3), at: 2)
        let held = frame(0.6)
        store.reset(to: held)
        #expect(store.frame(at: -1) == held)
        #expect(store.frame(at: 1.5) == held)
        #expect(store.frame(at: 1e9) == held)
        #expect(store.latest == held)
        #expect(store.newestTime == nil)

        store.reset()
        #expect(store.latest == .silent)
        #expect(store.frame(at: 0) == .silent)
    }

    @Test func publishAfterResetStartsNewHistory() {
        let store = FrameStore()
        store.publish(frame(0.1), at: 5)
        store.reset(to: frame(0.6))
        let fresh = frame(0.9)
        store.publish(fresh, at: 1)
        #expect(store.newestTime == 1)
        #expect(store.frame(at: 0) == fresh)
        #expect(store.frame(at: 6) == fresh)
    }

    /// Анализ и отрисовка идут по своим часам 60 Гц с разной фазой и дрожанием ±2 мс. Отрисовка
    /// берет кадр на 1/60 с раньше своего момента, поэтому каждый ее кадр видит новое значение
    /// растущей рампы, без повторов (картины «0, потом 2 кадра анализа»). Фаза 0.02 периода
    /// ставит отрисовку почти на кадр анализа: последний опубликованный кадр там повторялся бы.
    @Test(arguments: [0.37, 0.02])
    func noDuplicateRenderFrames(phase: Double) {
        let store = FrameStore()
        let period = 1.0 / 60
        var rng = TestRNG(seed: 7)
        var published = 0
        func publish(through time: Double) {
            while Double(published) * period <= time {
                store.publish(frame(Float(published) / 1000), at: Double(published) * period)
                published += 1
            }
        }
        var previous: Float?
        var repeats = 0
        for k in 2..<600 {
            let jitter = 0.002 * Double(rng.nextUnit())
            let render = (Double(k) + phase) * period + jitter
            publish(through: render)
            let value = store.frame(at: render - period).layers[0]
            if let previous, value <= previous {
                repeats += 1
            }
            previous = value
        }
        #expect(repeats == 0)
    }

    @Test func scheduleRoundTripsAndResets() {
        let store = FrameStore()
        #expect(store.schedule == .empty)
        let schedule = BeatSchedule(
            events: [
                GlowEvent(id: 1, time: 10.0, amplitude: 1, predicted: true),
                GlowEvent(id: 2, time: 10.5, amplitude: 0.8, predicted: true),
            ],
            bpm: 120, period: 0.5, confidence: 0.7, locked: true
        )
        store.publish(frame(0.4), at: 1)
        let sequence = store.sequence
        store.publishSchedule(schedule)
        #expect(store.schedule == schedule)
        // Расписание не кадр: номер публикации и история кадров не меняются.
        #expect(store.sequence == sequence)
        #expect(store.latest == frame(0.4))

        // Время кадров пошло назад: история очищается, расписание остается до следующей публикации.
        store.publish(frame(0.2), at: 0.5)
        #expect(store.schedule == schedule)

        let next = schedule.shifted(by: 0.5)
        store.publishSchedule(next)
        #expect(store.schedule == next)

        store.reset(to: frame(0.6))
        #expect(store.schedule == .empty)
        store.publishSchedule(schedule)
        store.reset()
        #expect(store.schedule == .empty)
    }

    @Test func frameStoreReturnsLastPublished() {
        let store = FrameStore()
        #expect(store.latest == .silent)
        let first = WaveFrame(bands: [Float](repeating: 0.1, count: 24), layers: [0.1, 0.2, 0.3], beat: 0.4, level: 0.3, rawLevelDB: -20)
        let second = WaveFrame(bands: [Float](repeating: 0.5, count: 24), layers: [0.5, 0.6, 0.7], beat: 0.8, level: 0.7, rawLevelDB: -10)
        store.publish(first, at: 1)
        store.publish(second, at: 2)
        #expect(store.latest == second)
    }

    @Test func silentFrameShape() {
        let frame = WaveFrame.silent
        #expect(frame.bands == [Float](repeating: 0, count: 24))
        #expect(frame.layers == [0, 0, 0])
        #expect(frame.beat == 0 && frame.level == 0 && frame.rawLevelDB == -120)
    }
}
