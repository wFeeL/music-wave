import Foundation
import Synchronization
import Testing
@testable import WaveCore

@Test func roundsCapacityUpToPowerOfTwo() {
    #expect(SampleRingBuffer(capacity: 1000).capacity == 1024)
}

private final class DoneFlag: Sendable {
    let value = Atomic<Bool>(false)
}

@Test func writerCountTracksAttachAndPeak() {
    let rb = SampleRingBuffer(capacity: 16)
    #expect(rb.activeWriters == 0)
    rb.attachWriter()
    #expect(rb.activeWriters == 1)
    rb.detachWriter()
    rb.attachWriter()
    #expect(rb.activeWriters == 1)
    #expect(rb.peakWriters == 1)
    rb.attachWriter()
    #expect(rb.activeWriters == 2)
    #expect(rb.peakWriters == 2)
    rb.detachWriter()
    rb.detachWriter()
    #expect(rb.activeWriters == 0)
    #expect(rb.peakWriters == 2)
}

// MARK: - SampleFeedMonitor

/// Первый вызов (и вызов после `reset`) только запоминает счетчик, даже если кольцо пустое.
@Test func feedMonitorStartsFresh() {
    var monitor = SampleFeedMonitor()
    let first = monitor.update(totalWritten: 0, now: 5)
    #expect(!first)
    let early = monitor.update(totalWritten: 0, now: 5.2)
    #expect(!early)
    let stalled = monitor.update(totalWritten: 0, now: 5.3)
    #expect(stalled)
    monitor.reset()
    let afterReset = monitor.update(totalWritten: 0, now: 9)
    #expect(!afterReset)
    // Обнуленное кольцо (пересборка tap) тоже считается новыми данными.
    let grew = monitor.update(totalWritten: 100, now: 9.05)
    let shrank = monitor.update(totalWritten: 0, now: 9.1)
    #expect(!grew && !shrank)
}

// MARK: - Метки времени блоков

/// Писатель конкурентных тестов пишет ограниченное время на своей очереди, вне пула Swift
/// Concurrency. На общих `HeavyWorkLanes` он ждал бы в очереди за чужими тяжелыми расчетами,
/// пока читатель впустую крутится на пуле.
private func runOnOwnQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue(label: "com.wfeels.wavefeels.tests.ring-writer").async {
            continuation.resume(returning: work())
        }
    }
}

@Test func stampRoundTrips() {
    let rb = SampleRingBuffer(capacity: 4096)
    #expect(rb.latestStamp() == nil)
    let block = [Float](repeating: 0.25, count: 512)
    block.withUnsafeBufferPointer { rb.write($0, hostTicks: 1000) }
    #expect(rb.latestStamp() == RingStamp(sampleIndex: 0, hostTicks: 1000))
    block.withUnsafeBufferPointer { rb.write($0, hostTicks: 2000) }
    #expect(rb.latestStamp() == RingStamp(sampleIndex: 512, hostTicks: 2000))
    #expect(rb.totalWritten == 1024)
    // Запись без метки двигает счетчик, но метку не трогает.
    block.withUnsafeBufferPointer { rb.write($0) }
    #expect(rb.latestStamp() == RingStamp(sampleIndex: 512, hostTicks: 2000))
    block.withUnsafeBufferPointer { rb.write($0, hostTicks: 4000) }
    #expect(rb.latestStamp() == RingStamp(sampleIndex: 1536, hostTicks: 4000))
}

@Test func resetClearsStamp() {
    let rb = SampleRingBuffer(capacity: 1024)
    let block = [Float](repeating: 0.25, count: 256)
    block.withUnsafeBufferPointer { rb.write($0, hostTicks: 77) }
    #expect(rb.latestStamp() != nil)
    rb.reset()
    #expect(rb.latestStamp() == nil)
    block.withUnsafeBufferPointer { rb.write($0, hostTicks: 99) }
    #expect(rb.latestStamp() == RingStamp(sampleIndex: 0, hostTicks: 99))
}

/// Писатель публикует пары с `hostTicks = 7 × sampleIndex`; разорванная пара (номер от одного
/// блока, время от другого) нарушила бы это равенство.
@Test func stampIsNeverTorn() async {
    let rb = SampleRingBuffer(capacity: 4096)
    let done = DoneFlag()
    let blockSize = 64

    let writer = Task {
        await runOnOwnQueue { () -> Int in
            let block = [Float](repeating: 0.5, count: blockSize)
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(1))
            var blocks = 0
            while blocks % 256 != 0 || clock.now < deadline {
                let index = rb.totalWritten
                block.withUnsafeBufferPointer { rb.write($0, hostTicks: UInt64(index) * 7) }
                blocks += 1
            }
            done.value.store(true, ordering: .releasing)
            return blocks
        }
    }

    var reads = 0
    var torn = 0
    var early = 0
    var backwards = 0
    var previous = -1
    var finished = false
    while !finished {
        finished = done.value.load(ordering: .acquiring)
        for _ in 0..<1000 {
            guard let stamp = rb.latestStamp() else { continue }
            reads += 1
            if stamp.hostTicks != UInt64(stamp.sampleIndex) * 7 { torn += 1 }
            // Метка публикуется после сэмплов своего блока.
            if rb.totalWritten < stamp.sampleIndex + blockSize { early += 1 }
            if stamp.sampleIndex < previous { backwards += 1 }
            previous = stamp.sampleIndex
        }
        await Task.yield()
    }
    let blocks = await writer.value
    #expect(blocks > 0)
    #expect(reads > 0)
    #expect(torn == 0)
    #expect(early == 0)
    #expect(backwards == 0)
    #expect(rb.latestStamp() == RingStamp(sampleIndex: (blocks - 1) * blockSize, hostTicks: UInt64((blocks - 1) * blockSize) * 7))
}

// MARK: - copyWindow

private func ramp(_ range: Range<Int>) -> [Float] {
    range.map(Float.init)
}

@Test func copyWindowEndingAtIndex() {
    let rb = SampleRingBuffer(capacity: 4096)
    let input = ramp(0..<4000)
    for start in stride(from: 0, to: input.count, by: 512) {
        input[start..<min(start + 512, input.count)].withUnsafeBufferPointer { rb.write($0) }
    }
    var window = [Float](repeating: -1, count: 1024)
    let ok = window.withUnsafeMutableBufferPointer { rb.copyWindow(endingAt: 3000, into: $0) }
    #expect(ok)
    #expect(window.first == 1976)
    #expect(window.last == 2999)
    #expect(window == ramp(1976..<3000))
}

@Test func copyWindowRejectsOverwrittenOrFuture() {
    let rb = SampleRingBuffer(capacity: 16)
    var window = [Float](repeating: -1, count: 4)
    // Ничего не записано.
    #expect(!window.withUnsafeMutableBufferPointer { rb.copyWindow(endingAt: 4, into: $0) })

    let input = ramp(0..<40)
    input.withUnsafeBufferPointer { rb.write($0) }
    // Окно из будущего.
    #expect(!window.withUnsafeMutableBufferPointer { rb.copyWindow(endingAt: 41, into: $0) })
    // Окно до нулевого сэмпла.
    #expect(!window.withUnsafeMutableBufferPointer { rb.copyWindow(endingAt: 3, into: $0) })
    // Окно уже перезаписано: в кольце сэмплы 24..<40.
    #expect(!window.withUnsafeMutableBufferPointer { rb.copyWindow(endingAt: 27, into: $0) })
    // Самое старое окно, которое еще цело.
    #expect(window.withUnsafeMutableBufferPointer { rb.copyWindow(endingAt: 28, into: $0) })
    #expect(window == ramp(24..<28))
    // Окно длиннее кольца.
    var long = [Float](repeating: -1, count: 17)
    #expect(!long.withUnsafeMutableBufferPointer { rb.copyWindow(endingAt: 40, into: $0) })
    // Пустое окно годится в пределах записанного.
    var empty: [Float] = []
    #expect(empty.withUnsafeMutableBufferPointer { rb.copyWindow(endingAt: 40, into: $0) })
    #expect(!empty.withUnsafeMutableBufferPointer { rb.copyWindow(endingAt: 41, into: $0) })
}

/// Самое новое окно, окно раньше, мало данных, перезапись, блок больше емкости и `reset`.
@Test func copyWindowCoversBasicCases() {
    // Самое новое окно.
    let rb = SampleRingBuffer(capacity: 16)
    ramp(0..<20).withUnsafeBufferPointer { rb.write($0) }
    var out = [Float](repeating: -1, count: 4)
    var ok = out.withUnsafeMutableBufferPointer { rb.copyWindow(endingAt: rb.totalWritten, into: $0) }
    #expect(ok && out == [16, 17, 18, 19])

    // Окно на 3 сэмпла раньше.
    ok = out.withUnsafeMutableBufferPointer { rb.copyWindow(endingAt: rb.totalWritten - 3, into: $0) }
    #expect(ok && out == [13, 14, 15, 16])

    // Данных меньше окна.
    let short = SampleRingBuffer(capacity: 16)
    [Float](arrayLiteral: 1, 2, 3).withUnsafeBufferPointer { short.write($0) }
    ok = out.withUnsafeMutableBufferPointer { short.copyWindow(endingAt: short.totalWritten, into: $0) }
    #expect(!ok)

    // Окно перезаписано.
    let wrapped = SampleRingBuffer(capacity: 16)
    ramp(0..<40).withUnsafeBufferPointer { wrapped.write($0) }
    ok = out.withUnsafeMutableBufferPointer { wrapped.copyWindow(endingAt: wrapped.totalWritten - 14, into: $0) }
    #expect(!ok)

    // Блок больше емкости: остается хвост.
    let large = SampleRingBuffer(capacity: 16)
    ramp(0..<100).withUnsafeBufferPointer { large.write($0) }
    #expect(large.totalWritten == 100)
    var full = [Float](repeating: -1, count: 16)
    ok = full.withUnsafeMutableBufferPointer { large.copyWindow(endingAt: 100, into: $0) }
    #expect(ok && full == ramp(84..<100))

    // После reset истории нет.
    let cleared = SampleRingBuffer(capacity: 16)
    ramp(0..<8).withUnsafeBufferPointer { cleared.write($0) }
    cleared.reset()
    #expect(cleared.totalWritten == 0)
    ok = out.withUnsafeMutableBufferPointer { cleared.copyWindow(endingAt: 4, into: $0) }
    #expect(!ok)
}

/// Читатель берет окна с разным отставанием от писателя, чаще всего у самой границы перезаписи.
/// Каждое окно, которое `copyWindow` признал целым, обязано совпасть с рампой. Рампа идет по
/// модулю 2^20, чтобы значения оставались точными во Float сколько бы ни писал писатель.
@Test func copyWindowNeverTearsMonotonicRamp() async {
    let rb = SampleRingBuffer(capacity: 4096)
    let done = DoneFlag()
    let blockSize = 512
    let period = 1 << 20

    let writer = Task {
        await runOnOwnQueue { () -> Int in
            // Рампа готова заранее: писатель почти все время копирует в кольцо, и окна у границы
            // чаще перезаписываются прямо во время чтения.
            let source = (0..<period).map(Float.init)
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(1))
            var next = 0
            var blocks = 0
            source.withUnsafeBufferPointer { ramp in
                while blocks % 64 != 0 || clock.now < deadline {
                    let offset = next % period
                    rb.write(UnsafeBufferPointer(rebasing: ramp[offset..<offset + blockSize]), hostTicks: UInt64(next))
                    next += blockSize
                    blocks += 1
                }
            }
            done.value.store(true, ordering: .releasing)
            return blocks
        }
    }

    let count = 1024
    var window = [Float](repeating: 0, count: count)
    var successes = 0
    var torn = 0
    var step = 0
    var finished = false
    while !finished {
        finished = done.value.load(ordering: .acquiring)
        for _ in 0..<64 {
            // Отставание от 0 до емкости с запасом; три из четырех попыток у границы перезаписи.
            step &+= 1
            let lag = step % 4 == 0
                ? (step / 4 * 97) % (rb.capacity + 256)
                : rb.capacity - count - (step * 31) % (blockSize + 64)
            let end = rb.totalWritten - lag
            let ok = window.withUnsafeMutableBufferPointer { rb.copyWindow(endingAt: end, into: $0) }
            guard ok else { continue }
            successes += 1
            let start = end - count
            for i in 0..<count where window[i] != Float((start + i) % period) {
                torn += 1
                break
            }
        }
        await Task.yield()
    }
    let blocks = await writer.value
    #expect(blocks > 0)
    #expect(successes > 0)
    #expect(torn == 0)
}

/// Писатель перестал писать (tap или демо встали): через 250 мс без новых сэмплов кольцо
/// считается остановившимся, хотя `copyWindow` по-прежнему отдает последнее окно.
@Test func feedMonitorNoticesWriterThatStoppedWithCopyWindow() {
    let rb = SampleRingBuffer(capacity: 4096)
    var monitor = SampleFeedMonitor()
    let block = [Float](repeating: 0.5, count: 480)
    var stalled: [Bool] = []
    for step in 0..<20 {
        block.withUnsafeBufferPointer { rb.write($0, hostTicks: UInt64(step) * 10_000) }
        stalled.append(monitor.update(totalWritten: rb.totalWritten, now: Double(step) * 0.01))
    }
    #expect(!stalled.contains(true))

    // Писатель встал на последнем блоке (0,19 с); окно все еще копируется.
    var window = [Float](repeating: 0, count: 1024)
    let copied = window.withUnsafeMutableBufferPointer { rb.copyWindow(endingAt: rb.totalWritten, into: $0) }
    #expect(copied && window.allSatisfy { $0 == 0.5 })
    let early = monitor.update(totalWritten: rb.totalWritten, now: 0.43)
    #expect(!early)
    let late = monitor.update(totalWritten: rb.totalWritten, now: 0.45)
    #expect(late)

    block.withUnsafeBufferPointer { rb.write($0, hostTicks: 200_000) }
    let resumed = monitor.update(totalWritten: rb.totalWritten, now: 0.46)
    #expect(!resumed)
}
