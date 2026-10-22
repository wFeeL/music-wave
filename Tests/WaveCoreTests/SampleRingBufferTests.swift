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
