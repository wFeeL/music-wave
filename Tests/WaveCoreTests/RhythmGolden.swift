import Foundation
@testable import WaveCore

/// Отпечаток расписаний и вспышек «По ритму» (FNV-1a по битам значений). Эталон снят этим же кодом на
/// коммите 8935e53 (1.3 до режимов свечения, `GlowModeTests.rhythmMatchesTheGoldenOf13`).
enum RhythmGolden {
    struct Print: Equatable, CustomStringConvertible {
        var hops = 0
        var events = 0
        var scheduleHash: UInt64 = 0xCBF2_9CE4_8422_2325
        var flashes = 0
        var flashHash: UInt64 = 0xCBF2_9CE4_8422_2325
        /// Метки вспышек: P доля, K бочка; заглавная с захватом.
        var labels = ""
        var description: String {
            "RhythmGolden.Print(hops: \(hops), events: \(events), scheduleHash: 0x\(String(scheduleHash, radix: 16)), flashes: \(flashes), flashHash: 0x\(String(flashHash, radix: 16)), labels: \"\(labels)\")"
        }
    }

    static func mix(_ hash: inout UInt64, _ value: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) {
            hash = (hash ^ ((value >> UInt64(shift)) & 0xFF)) &* 0x100_0000_01B3
        }
    }

    /// Трекер по шагам анализа (после каждого шага расписание целиком) и цепочка с рендером 30 кадров.
    static func fingerprint(_ scene: DrumScene, configure: (inout BeatTracker) -> Void = { _ in }, check: (BeatSchedule) -> Void = { _ in }) -> Print {
        var print = Print()
        let analyzer = StreamAnalyzer(sampleRate: scene.sampleRate)
        var tracker = BeatTracker(framesPerSecond: analyzer.config.framesPerSecond)
        configure(&tracker)
        for hop in analyzer.processSignal(scene.samples) {
            tracker.process(hop)
            let schedule = tracker.schedule
            check(schedule)
            print.hops += 1
            mix(&print.scheduleHash, schedule.locked ? 1 : 0)
            mix(&print.scheduleHash, UInt64(schedule.weight.bitPattern))
            mix(&print.scheduleHash, schedule.confidence.bitPattern)
            for event in schedule.events {
                print.events += 1
                mix(&print.scheduleHash, event.id)
                mix(&print.scheduleHash, event.time.bitPattern)
                mix(&print.scheduleHash, UInt64(event.amplitude.bitPattern))
                mix(&print.scheduleHash, event.predicted ? 1 : 0)
            }
        }
        var config = OfflineBeatChain.Config(seed: 1)
        config.renderRate = 30
        config.presentationLead = 1.0 / 30
        config.outputLatency = 0.2107
        config.syncOffset = -0.02
        let result = OfflineBeatChain.run(samples: scene.samples, sampleRate: scene.sampleRate, config: config)
        for flash in result.flashes {
            print.flashes += 1
            mix(&print.flashHash, flash.time.bitPattern)
            let label = flash.predicted ? "p" : "k"
            print.labels += flash.locked ? label.uppercased() : label
        }
        return print
    }

    static let scenes: [(String, @Sendable () -> DrumScene)] = [
        ("fourOnFloor120", { Drums.fourOnFloor(bpm: 120, seconds: 12, hats: .eighths) }),
        ("fourOnFloor150", { Drums.fourOnFloor(bpm: 150, seconds: 12, hats: .eighths, snareOnBackbeat: true) }),
        ("hipHop90", { Drums.hipHop90(seconds: 12) }),
    ]
}
