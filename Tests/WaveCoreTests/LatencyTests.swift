import Testing
import Foundation
@testable import WaveCore

struct LatencyTests {
    private func latency(
        device: UInt32 = 0, stream: UInt32 = 0, safety: UInt32 = 0, buffer: UInt32 = 0,
        rate: Double = 48_000, bluetooth: Bool = false
    ) -> OutputLatency {
        OutputLatency(
            deviceFrames: device, streamFrames: stream, safetyOffsetFrames: safety,
            bufferFrames: buffer, sampleRate: rate, isBluetooth: bluetooth
        )
    }

    @Test func autoLatencyBuiltInSpeakers() {
        // 1040 кадров = 21.67 мс, минус 21.33 и 16.7 уходит в минус, итог 0.
        let value = latency(device: 512, safety: 16, buffer: 512)
        #expect(LatencyCalculator.delayMilliseconds(value, mode: .auto) == 0)
    }

    @Test func autoLatencyLargeBuffer() {
        let value = latency(device: 4096, safety: 16, buffer: 4096)
        #expect(LatencyCalculator.delayMilliseconds(value, mode: .auto) == 133)
    }

    @Test func autoLatencyBluetoothAddsExtra() {
        let value = latency(device: 9600, buffer: 512, bluetooth: true)
        #expect(LatencyCalculator.delayMilliseconds(value, mode: .auto) == 213)
        let wired = latency(device: 9600, buffer: 512)
        #expect(LatencyCalculator.delayMilliseconds(wired, mode: .auto) == 173)
    }

    @Test func autoLatencyIsClampedToMaximum() {
        let value = latency(device: 200_000, bluetooth: true)
        #expect(LatencyCalculator.delayMilliseconds(value, mode: .auto) == 500)
    }

    @Test func autoLatencyWithZeroSampleRateIsZero() {
        let value = latency(device: 1000, rate: 0)
        #expect(LatencyCalculator.delayMilliseconds(value, mode: .auto) == 0)
    }

    @Test func manualIsClamped() {
        let value = latency()
        #expect(LatencyCalculator.delayMilliseconds(value, mode: .manual(milliseconds: 900)) == 500)
        #expect(LatencyCalculator.delayMilliseconds(value, mode: .manual(milliseconds: -5)) == 0)
        #expect(LatencyCalculator.delayMilliseconds(value, mode: .manual(milliseconds: 120)) == 120)
    }

    @Test func framesFromMilliseconds() {
        #expect(LatencyCalculator.delayFrames(milliseconds: 100, sampleRate: 48_000) == 4800)
        #expect(LatencyCalculator.delayFrames(milliseconds: 0, sampleRate: 44_100) == 0)
        #expect(LatencyCalculator.delayFrames(milliseconds: 133, sampleRate: 44_100) == 5865)
    }

    @Test func latencyModeCodableRoundTrip() throws {
        for mode in [LatencyMode.auto, .manual(milliseconds: 75)] {
            let data = try JSONEncoder().encode(mode)
            #expect(try JSONDecoder().decode(LatencyMode.self, from: data) == mode)
        }
    }
}
