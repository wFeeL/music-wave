import Foundation
import Testing
@testable import WaveCore

/// Цепочка `OfflineBeatChain` на синтетических барабанах. Только Linux, как остальные сцены.
@Suite(.enabled(if: TestPlatform.isLinux))
struct OfflineBeatChainTests {
    private static func scene() -> DrumScene {
        Drums.fourOnFloor(bpm: 120, seconds: 12, hats: .eighths)
    }

    /// Прогон, записанный со старым `SyncHarness` до переноса цепочки в WaveCore (четыре на пол
    /// 120 BPM, 12 с, `seed` 3, фаза рендера 0.3): перенос не должен менять ни одной вспышки. Записан
    /// заново при настройке 1.1 (`beatDelay` 12 мс и захват после трех попаданий): захват на 0.5 с
    /// раньше, вспышки с 4.5 по 7 с сдвинулись на кадр-два.
    @Test func matchesRecordedHarnessRun() async {
        let result = await runOffCooperativePool {
            let scene = Self.scene()
            var config = OfflineBeatChain.Config(seed: 3)
            config.renderPhase = 0.3
            return OfflineBeatChain.run(samples: scene.samples, sampleRate: scene.sampleRate, config: config)
        }
        let recorded = [
            0.555000000000291, 1.055000000000291, 1.555000000000291, 2.055000000000291, 2.555000000000291,
            3.055000000000291, 3.555000000000291, 4.055000000000291, 4.521666666667443, 5.021666666667443,
            5.521666666667443, 6.021666666667443, 6.521666666667443, 7.021666666667443, 7.505000000000109,
            8.00500000000011, 8.50500000000011, 9.00500000000011, 9.50500000000011, 10.00500000000011,
            10.50500000000011, 11.00500000000011, 11.50500000000011, 12.00500000000011, 12.50500000000011,
        ]
        #expect(result.flashes.count == recorded.count)
        for (flash, time) in zip(result.flashes, recorded) {
            #expect(abs(flash.time - time) < 1e-9, "flash \(flash.time) vs recorded \(time)")
        }
        #expect(abs((result.lockTime ?? -1) - 3.5849171615436717) < 1e-9)
        #expect(abs((result.tempoBPM ?? -1) - 120.26392951876916) < 1e-9)
        #expect(result.states.count == 1120)
        #expect(result.predictedTimes.count == 21)
        #expect(result.peakGlow == 1)
    }

    /// Вспышки и онсеты бочки лежат на слышимой оси: доли сцены плюс задержка вывода. С захватом
    /// вспышки идут от предсказанных долей.
    @Test func flashesLiveOnTheAudibleAxis() async {
        let (scene, result) = await runOffCooperativePool {
            let scene = Self.scene()
            return (scene, OfflineBeatChain.run(samples: scene.samples, sampleRate: scene.sampleRate, config: .init()))
        }
        let beats = result.audible(scene.beats)
        func distance(_ time: Double) -> Double {
            beats.map { abs($0 - time) }.min() ?? .infinity
        }
        #expect(result.kickOnsets.count >= 10)
        for onset in result.kickOnsets {
            // Онсет после начала бочки на задержку обнаружения, не раньше самой бочки.
            #expect(distance(onset) < 0.030, "kick onset \(onset)")
        }
        // Хвост рендера после конца звука не проверяется: расписание еще предсказывает доли.
        let flashes = result.flashes.filter { $0.time < 11.5 }
        let locked = flashes.filter(\.locked)
        #expect(locked.count >= 8)
        for flash in locked {
            #expect(distance(flash.time) < 0.050, "locked flash \(flash.time)")
            #expect(flash.predicted, "locked flash \(flash.time) is not predicted")
        }
        let beforeLock = flashes.filter { !$0.locked }
        #expect(!beforeLock.isEmpty)
        // Первая вспышка идет от онсета; предсказанные доли бывают и до захвата (смесь с онсетами).
        #expect(beforeLock.first?.predicted == false, "\(beforeLock)")
        #expect(result.lockTime.map { $0 > 0 && $0 < 8 } == true)
    }

    /// Те же сэмплы и `seed` дают тот же результат, а фазы рендера меняют только вспышки: состояния
    /// и онсеты у них общие.
    @Test func analysisIsDeterministicAndShared() async {
        let (single, phases) = await runOffCooperativePool {
            let scene = Drums.fourOnFloor(bpm: 120, seconds: 8, hats: .eighths)
            var config = OfflineBeatChain.Config(seed: 5)
            config.renderPhase = 0.5
            let single = OfflineBeatChain.run(samples: scene.samples, sampleRate: scene.sampleRate, config: config)
            let phases = OfflineBeatChain.run(samples: scene.samples, sampleRate: scene.sampleRate, config: config, renderPhases: 4)
            return (single, phases)
        }
        #expect(phases.count == 4)
        for phased in phases {
            #expect(phased.states == single.states)
            #expect(phased.kickOnsets == single.kickOnsets)
            #expect(phased.predictedTimes == single.predictedTimes)
        }
    }

    @Test func silenceNeverFlashesOrLocks() {
        let result = OfflineBeatChain.run(samples: [Float](repeating: 0, count: 48_000 * 3), sampleRate: 48_000, config: .init())
        #expect(result.flashes.isEmpty)
        #expect(result.kickOnsets.isEmpty)
        #expect(result.lockTime == nil)
        #expect(!result.states.isEmpty)
    }
}
