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

    // MARK: - Задержка вывода в секундах

    @Test func outputLatencyBuiltInSpeakers() {
        let value = latency(device: 32, stream: 0, safety: 16, buffer: 512)
        let seconds = LatencyCalculator.outputLatency(value, mode: .auto)
        #expect(abs(seconds - 560.0 / 48_000) < 1e-9)
    }

    @Test func outputLatencyBluetoothAddsFortyMs() {
        let wired = latency(device: 9600, stream: 24, safety: 16, buffer: 512)
        var wireless = wired
        wireless.isBluetooth = true
        let base = LatencyCalculator.outputLatency(wired, mode: .auto)
        #expect(abs(base - 10_152.0 / 48_000) < 1e-9)
        #expect(abs(LatencyCalculator.outputLatency(wireless, mode: .auto) - (base + 0.040)) < 1e-9)
    }

    @Test func outputLatencyClampedToHalfSecond() {
        let value = latency(device: 200_000, bluetooth: true)
        #expect(LatencyCalculator.outputLatency(value, mode: .auto) == 0.5)
        let justBelow = latency(device: 21_600, buffer: 0, rate: 48_000, bluetooth: true)
        #expect(abs(LatencyCalculator.outputLatency(justBelow, mode: .auto) - 0.49) < 1e-9)
    }

    @Test func outputLatencyZeroRateIsZero() {
        let value = latency(device: 1000, buffer: 512, rate: 0, bluetooth: true)
        #expect(LatencyCalculator.outputLatency(value, mode: .auto) == 0)
    }

    @Test func outputLatencyManualIsMilliseconds() {
        let value = latency(device: 9600, buffer: 512, bluetooth: true)
        #expect(abs(LatencyCalculator.outputLatency(value, mode: .manual(milliseconds: 120)) - 0.12) < 1e-12)
        #expect(LatencyCalculator.outputLatency(value, mode: .manual(milliseconds: 900)) == 0.5)
        #expect(LatencyCalculator.outputLatency(value, mode: .manual(milliseconds: -5)) == 0)
        #expect(LatencyCalculator.outputLatency(value, mode: .manual(milliseconds: 0)) == 0)
    }

    @Test func presentationLeadIsTwoRefreshes() {
        #expect(abs(LatencyCalculator.presentationLead(refreshPeriod: 1.0 / 60) - 2.0 / 60) < 1e-12)
        #expect(abs(LatencyCalculator.presentationLead(refreshPeriod: 1.0 / 120) - 2.0 / 120) < 1e-12)
    }

    @Test func latencyModeCodableRoundTrip() throws {
        for mode in [LatencyMode.auto, .manual(milliseconds: 75)] {
            let data = try JSONEncoder().encode(mode)
            #expect(try JSONDecoder().decode(LatencyMode.self, from: data) == mode)
        }
    }
}
