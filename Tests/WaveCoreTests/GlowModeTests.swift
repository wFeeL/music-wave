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
        let sync = latency > 0.1 ? -0.02 : 0
        let (scene, results) = await Self.run({ SharedScenes.steady120 }, modes: [.sound, .rhythm], latency: latency, sync: sync)
        let kicks = scene.kicks.map { $0 + latency }
        let expected = kicks.filter { $0 >= 2.05 && $0 <= 22.95 }.count
        let flashes = results[0].flashes.filter { $0.time >= 2 && $0.time <= 23 }
        let offsets = Self.offsets(flashes, reference: kicks)
        // Прогрев: события с 1.5 с потока (центр окна ноты баса чуть раньше конца шага), вспышка на сдвиг и
        // опережение раньше слышимого момента.
        let firstAllowed = ReactiveGlow.warmUp - 0.011 + latency + sync - BeatGlow.lead - 1.0 / 30
        #expect(results[0].flashes.allSatisfy { $0.time >= firstAllowed }, "\(results[0].flashes.prefix(3))")
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

    /// 808 без удара (трек T2 владельца, `Drums.glide808`): «Ритм и звук» и «По звуку» не темные (темнота
    /// после прогрева не больше 0.35), вспышки идут на нотах (не дальше 70 мс от начала ноты не меньше 0.8
    /// всех) и в «Ритм и звук» мягкие. Это заслуга нот баса: на одних акцентах потока здесь 3 вспышки за
    /// 22 с (темнота 0.93), «По ритму» темно все время, как у T2 в 1.3.
    @Test func gliding808IsNotDark() async {
        let latency = 0.211
        let (scene, results) = await Self.run({ Drums.glide808() }, modes: [.hybrid, .sound], latency: latency)
        let notes = scene.kicks.map { $0 + latency }
        for (mode, result) in zip([GlowMode.hybrid, .sound], results) {
            let flashes = result.flashes.filter { $0.time >= 2 + latency && $0.time <= 24 + latency }
            let dark = BeatMetrics.darkSpans(detections: flashes.map(\.time), from: 2 + latency, to: 24 + latency, gap: 1.5).total / 22
            let onNotes = Self.offsets(flashes, reference: notes).count
            #expect(dark <= 0.35, "\(mode) dark \(dark), flashes \(flashes.count)")
            #expect(Double(onNotes) >= 0.8 * Double(flashes.count), "\(mode) on notes \(onNotes) of \(flashes.count)")
            if mode == .hybrid {
                #expect(flashes.filter(\.reactive).allSatisfy { $0.peak <= ReactiveGlow.hybridScale + 1e-6 })
            }
        }
    }

    /// Розовый шум от -10 до -50 dBFS по 60 с: реактивный слой почти молчит, не больше одной мягкой
    /// вспышки на уровень и двух за 300 с (цель плана 0.5 в минуту), ярких нет. «По звуку» берет те же
    /// события, «По ритму» в шуме не светится (`BeatSyncTests.noiseAloneNeverGlows`).
    @Test func pinkNoiseStaysAlmostDark() async {
        let runs = await runOffCooperativePool { () -> [(level: Int, flashes: Int, peak: Float)] in
            [-10, -20, -30, -40, -50].map { (level: Int) in
                let noise = Drums.pinkNoise(levelDB: Float(level), count: 60 * 48_000, seed: UInt64(-level))
                var config = OfflineBeatChain.Config(seed: 1)
                config.glowMode = .hybrid
                config.renderRate = 30
                config.presentationLead = 1.0 / 30
                let result = OfflineBeatChain.run(samples: noise, sampleRate: 48_000, config: config)
                return (level, result.flashes.count, result.peakGlow)
            }
        }
        for run in runs {
            #expect(run.flashes <= 1 && run.peak <= ReactiveGlow.hybridScale + 1e-6, "\(run.level) dB: \(run.flashes), peak \(run.peak)")
        }
        #expect(runs.reduce(0) { $0 + $1.flashes } <= 2, "\(runs)")
    }
}
