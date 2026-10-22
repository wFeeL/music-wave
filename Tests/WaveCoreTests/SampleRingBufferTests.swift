import Synchronization
import Testing
@testable import WaveCore

@Test func roundsCapacityUpToPowerOfTwo() {
    #expect(SampleRingBuffer(capacity: 1000).capacity == 1024)
}

@Test func copyLatestReturnsMostRecentWindow() {
    let rb = SampleRingBuffer(capacity: 16)
    let input = (0..<20).map(Float.init)
    input.withUnsafeBufferPointer { rb.write($0) }
    var out = [Float](repeating: -1, count: 4)
    let ok = out.withUnsafeMutableBufferPointer { rb.copyLatest(into: $0, delay: 0) }
    #expect(ok && out == [16, 17, 18, 19])
}

@Test func copyLatestHonorsDelay() {
    let rb = SampleRingBuffer(capacity: 16)
    let input = (0..<20).map(Float.init)
    input.withUnsafeBufferPointer { rb.write($0) }
    var out = [Float](repeating: -1, count: 4)
    let ok = out.withUnsafeMutableBufferPointer { rb.copyLatest(into: $0, delay: 3) }
    #expect(ok && out == [13, 14, 15, 16])
}

@Test func copyLatestFailsWhenNotEnoughData() {
    let rb = SampleRingBuffer(capacity: 16)
    let input: [Float] = [1, 2, 3]
    input.withUnsafeBufferPointer { rb.write($0) }
    var out = [Float](repeating: -1, count: 4)
    let ok = out.withUnsafeMutableBufferPointer { rb.copyLatest(into: $0, delay: 0) }
    #expect(!ok)
}

@Test func copyLatestFailsWhenWindowOverwritten() {
    let rb = SampleRingBuffer(capacity: 16)
    let input = (0..<40).map(Float.init)
    input.withUnsafeBufferPointer { rb.write($0) }
    var out = [Float](repeating: -1, count: 4)
    let ok = out.withUnsafeMutableBufferPointer { rb.copyLatest(into: $0, delay: 14) }
    #expect(!ok)
}

@Test func writeLargerThanCapacityKeepsTail() {
    let rb = SampleRingBuffer(capacity: 16)
    let input = (0..<100).map(Float.init)
    input.withUnsafeBufferPointer { rb.write($0) }
    #expect(rb.totalWritten == 100)
    var out = [Float](repeating: -1, count: 16)
    let ok = out.withUnsafeMutableBufferPointer { rb.copyLatest(into: $0, delay: 0) }
    #expect(ok && out == (84..<100).map(Float.init))
}

@Test func resetClearsHistory() {
    let rb = SampleRingBuffer(capacity: 16)
    let input = (0..<8).map(Float.init)
    input.withUnsafeBufferPointer { rb.write($0) }
    rb.reset()
    #expect(rb.totalWritten == 0)
    var out = [Float](repeating: -1, count: 4)
    let ok = out.withUnsafeMutableBufferPointer { rb.copyLatest(into: $0, delay: 0) }
    #expect(!ok)
}

private final class DoneFlag: Sendable {
    let value = Atomic<Bool>(false)
}

@Test func concurrentWriterReaderNeverTearsMonotonicRamp() async {
    let rb = SampleRingBuffer(capacity: 4096)
    let done = DoneFlag()
    let blockSize = 512
    let blocks = 20_000

    let writer = Task.detached {
        var block = [Float](repeating: 0, count: blockSize)
        var next = 0
        for _ in 0..<blocks {
            for i in 0..<blockSize { block[i] = Float(next + i) }
            block.withUnsafeBufferPointer { rb.write($0) }
            next += blockSize
        }
        done.value.store(true, ordering: .releasing)
    }

    let reader = Task.detached { () -> (successes: Int, torn: Int) in
        var window = [Float](repeating: 0, count: 256)
        var successes = 0
        var torn = 0
        var finished = false
        while !finished {
            finished = done.value.load(ordering: .acquiring)
            let ok = window.withUnsafeMutableBufferPointer { rb.copyLatest(into: $0, delay: 0) }
            guard ok else { continue }
            successes += 1
            for i in 1..<window.count where window[i] != window[i - 1] + 1 {
                torn += 1
                break
            }
        }
        return (successes, torn)
    }

    await writer.value
    let result = await reader.value
    #expect(result.successes > 0)
    #expect(result.torn == 0)
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

/// Писатель перестал писать (tap или демо встали): через 250 мс без новых сэмплов кольцо
/// считается остановившимся, хотя `copyLatest` по-прежнему отдает последнее окно.
@Test func feedMonitorNoticesWriterThatStopped() {
    let rb = SampleRingBuffer(capacity: 4096)
    var monitor = SampleFeedMonitor()
    let block = [Float](repeating: 0.5, count: 480)
    var stalled: [Bool] = []
    // 10 мс на блок, как IOProc: кольцо пополняется, остановки нет.
    for step in 0..<20 {
        block.withUnsafeBufferPointer { rb.write($0) }
        stalled.append(monitor.update(totalWritten: rb.totalWritten, now: Double(step) * 0.01))
    }
    #expect(!stalled.contains(true))

    // Писатель встал на последнем блоке (0,19 с); окно все еще копируется.
    var window = [Float](repeating: 0, count: 1024)
    let copied = window.withUnsafeMutableBufferPointer { rb.copyLatest(into: $0, delay: 0) }
    #expect(copied && window.allSatisfy { $0 == 0.5 })
    let early = monitor.update(totalWritten: rb.totalWritten, now: 0.43)
    #expect(!early)
    let late = monitor.update(totalWritten: rb.totalWritten, now: 0.45)
    #expect(late)

    // Писатель снова пишет: остановки нет сразу.
    block.withUnsafeBufferPointer { rb.write($0) }
    let resumed = monitor.update(totalWritten: rb.totalWritten, now: 0.46)
    #expect(!resumed)
}

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
