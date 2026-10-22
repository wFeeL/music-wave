import Foundation
import Testing
@testable import WaveCore

/// Критерии попадания в бит (`design-v1.md` §2, `beat-sync.md` 3.3) на синтетических барабанах через
/// всю цепочку `SyncHarness`: 48 кГц, 24 с, рендер 60 Гц, задержка вывода 20 мс, если не сказано иное.
/// F-мера, сдвиги и ложные вспышки считаются после первых 2 с. Только Linux, как остальные сцены.
@Suite(.enabled(if: TestPlatform.isLinux))
struct BeatSyncTests {
    private static let from = 2.0

    private static func run(
        _ scene: @escaping @Sendable () -> DrumScene, _ config: SyncHarness.Config = .init()
    ) async -> (scene: DrumScene, result: SyncResult) {
        await runOffCooperativePool {
            let scene = scene()
            return (scene, SyncHarness.run(scene: scene, config: config))
        }
    }

    private static func isNear(_ bpm: Double?, _ truth: Double, tolerance: Double = 0.04) -> Bool {
        bpm.map { abs($0 / truth - 1) < tolerance } ?? false
    }

    /// Сдвиги вспышек от слышимых долей после захвата и конца перехода смеси (`crossfadeBeats` долей).
    private static func lockedOffsets(_ result: SyncResult, beats: [Double], period: Double) -> (mean: Double, sd: Double)? {
        guard let lock = result.lockTime else { return nil }
        let crossfade = BeatTracker.Parameters().crossfadeBeats * period
        return result.offsets(reference: result.audible(beats), from: lock + crossfade)
    }

    private static func describe(_ result: SyncResult, f: Double, offsets: (mean: Double, sd: Double)?) -> String {
        let lock = result.lockTime.map { String(format: "%.2f", $0) } ?? "none"
        let tempo = result.tempoBPM.map { String(format: "%.1f", $0) } ?? "none"
        let offset = offsets.map { String(format: "%+.1f ± %.1f ms", $0.mean * 1000, $0.sd * 1000) } ?? "n/a"
        return String(format: "F %.3f, ", f) + "lock \(lock) s, tempo \(tempo), offset \(offset), events \(result.events.count)"
    }

    @Test(arguments: [90.0, 100, 120, 128, 140, 160])
    func steadyBeatLocksOnTime(bpm: Double) async {
        let (scene, result) = await Self.run {
            bpm == 120 ? SharedScenes.steady120 : Drums.fourOnFloor(bpm: bpm, hats: .eighths)
        }
        let f = result.fMeasure(reference: result.audible(scene.beats), tolerance: 0.05, from: Self.from)
        let offsets = Self.lockedOffsets(result, beats: scene.beats, period: 60 / bpm)
        let summary = Self.describe(result, f: f, offsets: offsets)
        #expect(f >= 0.9, "\(summary)")
        #expect(result.lockTime.map { $0 - scene.beats[0] <= 8 } == true, "\(summary)")
        #expect(offsets.map { (-0.030...0.010).contains($0.mean) && $0.sd <= 0.006 } == true, "\(summary)")
        #expect(Self.isNear(result.tempoBPM, bpm), "\(summary)")
    }

    /// Без захвата свечение идет от онсетов бочки. Бюджет: блок 5 + обнаружение 7 + пробуждение 4 +
    /// ожидание кадра 8 + показ 33 - задержка вывода 20 = +37 мс, в спецификации «примерно +35».
    @Test func onsetPathIsLateByAtMost45ms() async {
        var config = SyncHarness.Config()
        config.trackerParameters.lockHits = .max
        let (scene, result) = await Self.run({ SharedScenes.steady120 }, config)
        let offsets = result.offsets(reference: result.audible(scene.kicks), from: Self.from)
        let f = result.fMeasure(reference: result.audible(scene.kicks), tolerance: 0.05, from: Self.from)
        #expect(result.lockTime == nil)
        #expect((-0.010...0.045).contains(offsets.mean), "\(Self.describe(result, f: f, offsets: offsets))")
    }

    @Test func jitterSmallerAt120Hz() async {
        var config = SyncHarness.Config()
        config.renderRate = 120
        let (scene, result) = await Self.run({ SharedScenes.steady120 }, config)
        let offsets = Self.lockedOffsets(result, beats: scene.beats, period: 0.5)
        let f = result.fMeasure(reference: result.audible(scene.beats), tolerance: 0.05, from: Self.from)
        #expect(offsets.map { $0.sd <= 0.004 } == true, "\(Self.describe(result, f: f, offsets: offsets))")
    }

    @Test func breakdownHasAtMostOnePhantom() async {
        let (_, result) = await Self.run { SharedScenes.breakdown }
        let phantoms = result.events(in: 10.5.nextUp...18)
        #expect(phantoms <= 1, "events \(result.events.filter { $0 > 10 && $0 < 18.5 })")
    }

    /// Розовый шум дает редкие ложные онсеты бочки (около 0.17 в секунду), свечения от них нет.
    @Test(arguments: [UInt64(1), 2, 3])
    func noiseAloneNeverGlows(seed: UInt64) async {
        let (_, result) = await Self.run { Drums.noiseOnly(levelDB: -20, seconds: 12, seed: seed) }
        #expect(result.events.isEmpty, "events \(result.events)")
    }

    @Test func quietIntroNeverGlows() async {
        let (_, result) = await Self.run { Drums.quietIntro() }
        #expect(result.events(in: 0...8) == 0, "events \(result.events.filter { $0 <= 8 })")
        let lock = result.lockTime(after: 8)
        #expect(lock.map { $0 - 8 <= 8 } == true, "lock \(String(describing: lock))")
    }

    @Test func dnbFallsBackToKicks() async {
        let (scene, result) = await Self.run { Drums.dnb174() }
        let f = result.fMeasure(reference: result.audible(scene.kicks), tolerance: 0.05, from: Self.from)
        #expect(f >= 0.9, "\(Self.describe(result, f: f, offsets: nil))")
    }

    @Test func syncopationGlowsOnBeatsAndKicks() async {
        let (scene, result) = await Self.run { Drums.hipHop90() }
        var reference: [Double] = []
        for time in (scene.beats + scene.kicks).sorted() where reference.last.map({ time - $0 > 0.030 }) ?? true {
            reference.append(time)
        }
        let f = result.fMeasure(reference: result.audible(reference), tolerance: 0.05, from: Self.from)
        #expect(f >= 0.9, "\(Self.describe(result, f: f, offsets: nil))")
    }

    @Test func swingAndHumanizedKick() async {
        let (swung, swingResult) = await Self.run { Drums.fourOnFloor(bpm: 100, hats: .eighths, swing: 0.66) }
        let swingF = swingResult.fMeasure(reference: swingResult.audible(swung.beats), tolerance: 0.05, from: Self.from)
        #expect(swingF >= 0.9, "swing: \(Self.describe(swingResult, f: swingF, offsets: nil))")

        let (human, humanResult) = await Self.run {
            Drums.fourOnFloor(bpm: 100, hats: .eighths, humanizeSigma: 0.008)
        }
        let humanF = humanResult.fMeasure(reference: humanResult.audible(human.beats), tolerance: 0.07, from: Self.from)
        #expect(humanF >= 0.9, "humanized: \(Self.describe(humanResult, f: humanF, offsets: nil))")
    }

    @Test func tempoRampIsFollowed() async {
        let (scene, result) = await Self.run { Drums.tempoRamp(from: 120, to: 130, seconds: 20) }
        let f = result.fMeasure(reference: result.audible(scene.beats), tolerance: 0.05, from: Self.from)
        #expect(f >= 0.9, "\(Self.describe(result, f: f, offsets: nil))")
    }

    @Test func tempoJumpRelocks() async {
        let (scene, result) = await Self.run { Drums.tempoJump(from: 100, to: 140, at: 12) }
        let relock = result.lockTime(after: 12) { Self.isNear($0, 140) || Self.isNear($0, 70) }
        #expect(relock.map { $0 - 12 <= 8 } == true, "relock \(String(describing: relock))")
        guard let relock else { return }
        let f = result.fMeasure(reference: result.audible(scene.beats), tolerance: 0.05, from: relock)
        #expect(f >= 0.9, "\(Self.describe(result, f: f, offsets: nil)), relock \(relock)")
    }

    @Test(arguments: [44_100.0, 96_000])
    func otherSampleRates(rate: Double) async {
        let (scene, result) = await Self.run { Drums.fourOnFloor(bpm: 120, sampleRate: rate, hats: .eighths) }
        let f = result.fMeasure(reference: result.audible(scene.beats), tolerance: 0.05, from: Self.from)
        let offsets = Self.lockedOffsets(result, beats: scene.beats, period: 0.5)
        let summary = Self.describe(result, f: f, offsets: offsets)
        #expect(f >= 0.9, "\(summary)")
        #expect(offsets.map { (-0.030...0.010).contains($0.mean) } == true, "\(summary)")
    }

    @Test func bluetoothLatencyIsPredicted() async {
        var config = SyncHarness.Config()
        config.outputLatency = 0.180
        let (scene, result) = await Self.run({ SharedScenes.steady120 }, config)
        let offsets = Self.lockedOffsets(result, beats: scene.beats, period: 0.5)
        let f = result.fMeasure(reference: result.audible(scene.beats), tolerance: 0.05, from: Self.from)
        #expect(offsets.map { (-0.030...0.010).contains($0.mean) } == true, "\(Self.describe(result, f: f, offsets: offsets))")
    }

    /// Энергия между долями (бас на слабых восьмых, малый на слабых долях) не сдвигает свечение с долей.
    @Test(arguments: [(128.0, true, false), (140, false, true)])
    func offBeatEnergyDoesNotMoveTheGlow(bpm: Double, offbeatBass: Bool, snare: Bool) async {
        let (scene, result) = await Self.run {
            Drums.fourOnFloor(bpm: bpm, hats: .eighths, offbeatBass: offbeatBass, snareOnBackbeat: snare)
        }
        #expect(Self.isNear(result.tempoBPM, bpm), "tempo \(String(describing: result.tempoBPM))")
        guard let lock = result.lockTime else {
            Issue.record("no lock")
            return
        }
        let beats = result.audible(scene.beats)
        let afterLock = result.events.filter { $0 >= lock }
        var offBeat = 0
        for event in afterLock {
            guard let index = beats.lastIndex(where: { $0 <= event }), index + 1 < beats.count else { continue }
            let phase = (event - beats[index]) / (beats[index + 1] - beats[index])
            if (0.3...0.7).contains(phase) { offBeat += 1 }
        }
        #expect(!afterLock.isEmpty)
        #expect(Double(offBeat) <= 0.05 * Double(afterLock.count), "\(offBeat) of \(afterLock.count) events off the beat")
    }
}
