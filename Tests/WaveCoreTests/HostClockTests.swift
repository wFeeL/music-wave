import Foundation
import Testing
@testable import WaveCore

/// Метки времени IOProc: блок 512 сэмплов при 48 кГц, метка это время хоста первого сэмпла блока.
struct HostClockTests {
    private static let rate = 48_000.0
    private static let chunk = 512

    private static func standardDeviation(_ values: [Double]) -> Double {
        let mean = values.reduce(0, +) / Double(max(values.count, 1))
        return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(max(values.count, 1))).squareRoot()
    }

    @Test func filtersStampJitter() {
        var clock = HostClock(sampleRate: Self.rate)
        var rng = TestRNG(seed: 7)
        let hostStart = 1000.0
        var errors: [Double] = []
        var n = 0
        while Double(n) / Self.rate < 10 {
            let truth = hostStart + Double(n) / Self.rate
            let jitter = 0.0003 * Double(rng.nextUnit())
            clock.anchor(sampleIndex: n, hostSeconds: truth + jitter)
            let probe = n + Self.chunk / 2
            if Double(n) / Self.rate >= 5, let mapped = clock.hostTime(ofSample: probe) {
                errors.append(mapped - (hostStart + Double(probe) / Self.rate))
            }
            n += Self.chunk
        }
        #expect(errors.count > 400)
        #expect(Self.standardDeviation(errors) < 0.0001, "SD \(Self.standardDeviation(errors))")
        #expect(errors.allSatisfy { abs($0) < 0.0003 })
    }

    @Test func followsSlowDrift() {
        var clock = HostClock(sampleRate: Self.rate)
        let trueRate = Self.rate * 1.0001
        var n = 0
        var lastError = Double.infinity
        while Double(n) / trueRate < 30 {
            clock.anchor(sampleIndex: n, hostSeconds: 50 + Double(n) / trueRate)
            n += Self.chunk
            if let mapped = clock.hostTime(ofSample: n) {
                lastError = mapped - (50 + Double(n) / trueRate)
            }
        }
        #expect(abs(lastError) < 0.001, "error \(lastError)")
    }

    @Test func resyncsOnJump() {
        var clock = HostClock(sampleRate: Self.rate)
        var n = 0
        for _ in 0..<200 {
            clock.anchor(sampleIndex: n, hostSeconds: 10 + Double(n) / Self.rate)
            n += Self.chunk
        }
        // Часы хоста прыгают на 0.2 с вперед: следующая метка уже на новой линии.
        clock.anchor(sampleIndex: n, hostSeconds: 10.2 + Double(n) / Self.rate)
        let mapped = clock.hostTime(ofSample: n + 1)
        let error = mapped.map { $0 - (10.2 + Double(n + 1) / Self.rate) }
        #expect(error.map { abs($0) < 0.001 } == true, "error \(String(describing: error))")
    }

    @Test func noTimeBeforeTheFirstAnchor() {
        var clock = HostClock(sampleRate: Self.rate)
        #expect(clock.hostTime(ofSample: 0) == nil)
        clock.anchor(sampleIndex: 4800, hostSeconds: 3)
        #expect(clock.hostTime(ofSample: 9600).map { abs($0 - 3.1) < 1e-12 } == true)
        clock.reset(sampleRate: 96_000)
        #expect(clock.hostTime(ofSample: 0) == nil)
        clock.anchor(sampleIndex: 0, hostSeconds: 1)
        #expect(clock.hostTime(ofSample: 9600).map { abs($0 - 1.1) < 1e-12 } == true)
    }
}
