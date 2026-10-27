import Foundation
import Testing
@testable import WaveCore

/// Режимы свечения (`GlowMode`) через всю цепочку: «По ритму» это 1.3 без изменений, «По звуку» без сетки и
/// бочек, анализ от режима не зависит.
@Suite(.enabled(if: TestPlatform.isLinux))
struct GlowModeTests {
    private static func run(
        _ scene: @escaping @Sendable () -> DrumScene, modes: [GlowMode], latency: Double = 0.020
    ) async -> (scene: DrumScene, results: [OfflineBeatChain.Result]) {
        await runOffCooperativePool {
            let scene = scene()
            let results = modes.map { mode in
                var config = OfflineBeatChain.Config(seed: 1)
                config.outputLatency = latency
                config.glowMode = mode
                return OfflineBeatChain.run(samples: scene.samples, sampleRate: scene.sampleRate, config: config)
            }
            return (scene, results)
        }
    }

    /// `rhythm` это цепочка по умолчанию: те же вспышки, состояния и пик; у вспышек есть пик, кадры с
    /// видимым свечением считаются только на слышимом отрезке.
    @Test func rhythmIsTheDefault() async {
        let (scene, results) = await Self.run({ SharedScenes.steady120 }, modes: [.rhythm])
        let plain = await runOffCooperativePool {
            OfflineBeatChain.run(samples: scene.samples, sampleRate: scene.sampleRate, config: OfflineBeatChain.Config(seed: 1))
        }
        let rhythm = results[0]
        #expect(rhythm.flashes == plain.flashes && rhythm.states == plain.states && rhythm.peakGlow == plain.peakGlow)
        #expect(!rhythm.flashes.isEmpty && rhythm.flashes.allSatisfy { $0.peak > OfflineBeatChain.eventRise && !$0.reactive })
        #expect(rhythm.visibleFrames > 0 && rhythm.visibleFrames < rhythm.audibleFrames)
        // 24 с звука на 60 Гц.
        #expect(abs(rhythm.audibleFrames - 24 * 60) <= 1)
    }

    /// `sound`: сетка и бочки не светятся (только реактивный слой), а анализ тот же: состояния публикаций
    /// совпадают с `rhythm`.
    @Test func soundModeHidesTheGridAndTheKicks() async {
        let (_, results) = await Self.run({ SharedScenes.steady120 }, modes: [.rhythm, .sound])
        let (rhythm, sound) = (results[0], results[1])
        #expect(sound.states == rhythm.states)
        #expect(sound.flashes.allSatisfy { $0.reactive }, "grid or kick flashes \(sound.flashes.filter { !$0.reactive }.count)")
    }
}
