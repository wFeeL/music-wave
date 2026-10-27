import Foundation
import Testing
@testable import WaveCore

/// Режимы свечения (`GlowMode`) через всю цепочку: «По ритму» это 1.3 без изменений, «По звуку» без сетки и
/// бочек, анализ от режима не зависит. Рендер как в журналах владельца: 30 кадров, упреждение 1/30 с.
@Suite(.enabled(if: TestPlatform.isLinux))
struct GlowModeTests {
    private static func run(
        _ scene: @escaping @Sendable () -> DrumScene, modes: [GlowMode], latency: Double = 0.020, sync: Double = 0
    ) async -> (scene: DrumScene, results: [OfflineBeatChain.Result]) {
        await runOffCooperativePool {
            let scene = scene()
            let results = modes.map { mode in
                var config = OfflineBeatChain.Config(seed: 1)
                config.outputLatency = latency
                config.syncOffset = sync
                config.renderRate = 30
                config.presentationLead = 1.0 / 30
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
            var config = OfflineBeatChain.Config(seed: 1)
            config.renderRate = 30
            config.presentationLead = 1.0 / 30
            return OfflineBeatChain.run(samples: scene.samples, sampleRate: scene.sampleRate, config: config)
        }
        let rhythm = results[0]
        #expect(rhythm.flashes == plain.flashes && rhythm.states == plain.states && rhythm.peakGlow == plain.peakGlow)
        #expect(!rhythm.flashes.isEmpty && rhythm.flashes.allSatisfy { $0.peak > OfflineBeatChain.eventRise && !$0.reactive })
        #expect(rhythm.visibleFrames > 0 && rhythm.visibleFrames < rhythm.audibleFrames)
        // 24 с звука на 30 кадрах.
        #expect(abs(rhythm.audibleFrames - 24 * 30) <= 1)
    }

    /// `sound`: сетка и бочки не светятся (только реактивный слой), а анализ тот же: состояния публикаций
    /// совпадают с `rhythm`.
    @Test func soundModeHidesTheGridAndTheKicks() async {
        let (_, results) = await Self.run({ SharedScenes.steady120 }, modes: [.rhythm, .sound])
        let (rhythm, sound) = (results[0], results[1])
        #expect(sound.states == rhythm.states)
        #expect(sound.flashes.allSatisfy { $0.reactive }, "grid or kick flashes \(sound.flashes.filter { !$0.reactive }.count)")
    }

    /// Сдвиги вспышек от ближайшего удара `reference` (не дальше 70 мс), секунды.
    private static func offsets(_ flashes: [OfflineBeatChain.Flash], reference: [Double]) -> [Double] {
        flashes.compactMap { flash in
            let nearest = reference.min { abs($0 - flash.time) < abs($1 - flash.time) }
            return nearest.flatMap { abs(flash.time - $0) <= 0.07 ? flash.time - $0 : nil }
        }
    }

    /// «По звуку» на бочке 120 BPM с хэтами: реактивные вспышки идут на бочках (одна на удар, мимо не больше
    /// одной), не раньше 1.5 с прогрева, в полную яркость. С задержкой вывода Bluetooth (211 мс, сдвиг -20 мс)
    /// у анализа есть запас, и вспышка встает туда же, куда вспышка сетки «По ритму» (опережение
    /// `BeatGlow.lead`); на 20 мс она опаздывает на обнаружение и доставку, как волны (на 30-80 мс позже
    /// сетки).
    @Test(arguments: [0.211, 0.020])
    func soundModeFlashesOnTheKicks(latency: Double) async {
        let (scene, results) = await Self.run(
            { SharedScenes.steady120 }, modes: [.sound, .rhythm], latency: latency, sync: latency > 0.1 ? -0.02 : 0
        )
        let kicks = scene.kicks.map { $0 + latency }
        let expected = kicks.filter { $0 >= 2.05 && $0 <= 22.95 }.count
        let flashes = results[0].flashes.filter { $0.time >= 2 && $0.time <= 23 }
        let offsets = Self.offsets(flashes, reference: kicks)
        #expect(results[0].flashes.allSatisfy { $0.time >= ReactiveGlow.warmUp + latency }, "\(results[0].flashes.prefix(3))")
        #expect(Double(offsets.count) >= 0.9 * Double(expected), "on kicks \(offsets.count) of \(expected)")
        #expect(flashes.count - offsets.count <= 1, "off the kicks \(flashes.count - offsets.count)")
        // Одна вспышка на удар: подъем функции онсетов на двух шагах сливается в одно событие.
        #expect(offsets.count <= expected + 1, "double flashes: \(offsets.count) on \(expected) kicks")
        #expect(flashes.allSatisfy { $0.peak >= 0.5 }, "full brightness \(flashes.map(\.peak).min() ?? 0)")
        // Сетка после захвата (с 8 с) против реактивных вспышек тех же ударов.
        func mean(_ values: [Double]) -> Double { values.reduce(0, +) / Double(max(values.count, 1)) }
        let late = { (flash: OfflineBeatChain.Flash) in flash.time >= 8 && flash.time <= 23 }
        let reactive = mean(Self.offsets(results[0].flashes.filter(late), reference: kicks))
        let grid = mean(Self.offsets(results[1].flashes.filter(late), reference: kicks))
        if latency > 0.1 {
            #expect(abs(reactive - grid) <= 0.008, "reactive \(reactive), grid \(grid)")
        } else {
            #expect((0.030...0.080).contains(reactive - grid), "reactive \(reactive), grid \(grid)")
        }
    }

    /// «Ритм и звук» на захваченной бочке: все вспышки сетки на месте (у каждой вспышки «По ритму» есть
    /// вспышка в пределах кадра), реактивный слой мягкий (не ярче 0.6).
    @Test func hybridKeepsTheGridFlashes() async {
        let (_, results) = await Self.run({ SharedScenes.steady120 }, modes: [.rhythm, .hybrid])
        let (rhythm, hybrid) = (results[0], results[1])
        for flash in rhythm.flashes {
            #expect(hybrid.flashes.contains { abs($0.time - flash.time) <= 1.0 / 60 + 1e-9 }, "grid flash at \(flash.time) lost")
        }
        #expect(hybrid.flashes.filter(\.reactive).allSatisfy { $0.peak <= ReactiveGlow.hybridScale + 1e-6 })
    }
}

