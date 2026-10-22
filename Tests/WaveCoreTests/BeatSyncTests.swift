import Foundation
import Testing
@testable import WaveCore

/// Критерии попадания в бит (`design-v1.md` §2, `beat-sync.md` 3.3) на синтетических барабанах через
/// всю цепочку `SyncHarness`: 48 кГц, 24 с, рендер 60 Гц, задержка вывода 20 мс, если не сказано иное.
/// F-мера, сдвиги и ложные вспышки считаются после первых 2 с. Только Linux, как остальные сцены.
///
/// Разброс сдвига на 60 Гц зависит от фазы рендера: при темпе, кратном кадрам (90, 100, 120 BPM),
/// квантование одинаково для каждой доли, и один прогон дает либо почти 0, либо переброс между двумя
/// кадрами (до 8.3 мс). Поэтому захваченные сцены на 60 Гц показываются на `renderPhases` равномерных
/// фазах: средний сдвиг проверяется на каждой с захвата, разброс по всем вместе, а дрожание самих
/// предсказаний отдельно по расписанию без квантования. Разброс меряется в установившемся режиме
/// (через `settle` после захвата и перехода смеси), сходимость до него проверяется отдельно.
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

    private static let renderPhases = 8
    /// Сколько секунд после захвата (и перехода смеси) ФАПЧ сходится; разброс меряется после.
    private static let settle = 4.0

    /// Сцена через цепочку, показанная на `renderPhases` фазах рендера.
    private static func runPhases(
        _ scene: @escaping @Sendable () -> DrumScene, _ config: SyncHarness.Config = .init()
    ) async -> (scene: DrumScene, results: [SyncResult]) {
        await runOffCooperativePool {
            let scene = scene()
            return (scene, SyncHarness.run(scene: scene, config: config, renderPhases: renderPhases))
        }
    }

    /// Захват на всех фазах: средний сдвиг каждой в -30...+10 мс; возвращает сдвиги всех фаз вместе.
    private static func checkLockedPhases(
        _ results: [SyncResult], beats: [Double], period: Double, label: String = ""
    ) -> [Double] {
        var pooled: [Double] = []
        for (k, result) in results.enumerated() {
            guard let from = lockedFrom(result, period: period) else {
                Issue.record("\(label) phase \(k): no lock")
                continue
            }
            let values = result.offsetValues(reference: result.audible(beats), from: from)
            let offsets = SyncResult.meanAndSD(values)
            #expect((-0.030...0.010).contains(offsets.mean), "\(label) phase \(k): \(describe(result, f: nil, offsets: offsets))")
            pooled += values
        }
        return pooled
    }

    /// Начало проверки захваченных сдвигов: захват плюс переход смеси (`crossfadeBeats` долей).
    private static func lockedFrom(_ result: SyncResult, period: Double) -> Double? {
        result.lockTime.map { $0 + BeatTracker.Parameters().crossfadeBeats * period }
    }

    private static func isNear(_ bpm: Double?, _ truth: Double, tolerance: Double = 0.04) -> Bool {
        bpm.map { abs($0 / truth - 1) < tolerance } ?? false
    }

    /// Сдвиги вспышек от слышимых долей после захвата и конца перехода смеси (`crossfadeBeats` долей).
    private static func describe(_ result: SyncResult, f: Double?, offsets: (mean: Double, sd: Double)?) -> String {
        let lock = result.lockTime.map { String(format: "%.2f", $0) } ?? "none"
        let tempo = result.tempoBPM.map { String(format: "%.1f", $0) } ?? "none"
        let offset = offsets.map { String(format: "%+.1f ± %.1f ms", $0.mean * 1000, $0.sd * 1000) } ?? "n/a"
        return (f.map { String(format: "F %.3f, ", $0) } ?? "") + "lock \(lock) s, tempo \(tempo), offset \(offset), events \(result.events.count)"
    }

    @Test(arguments: [90.0, 100, 120, 128, 140, 160])
    func steadyBeatLocksOnTime(bpm: Double) async {
        let (scene, results) = await Self.runPhases {
            bpm == 120 ? SharedScenes.steady120 : Drums.fourOnFloor(bpm: bpm, hats: .eighths)
        }
        let period = 60 / bpm
        let beats = results[0].audible(scene.beats)
        for (k, result) in results.enumerated() {
            let f = result.fMeasure(reference: beats, tolerance: 0.05, from: Self.from)
            #expect(f >= 0.9, "phase \(k): \(Self.describe(result, f: f, offsets: nil))")
        }
        // Анализ от фазы рендера не зависит: захват, темп и предсказания одни на все фазы.
        let result = results[0]
        let summary = Self.describe(result, f: nil, offsets: nil)
        #expect(result.lockTime.map { $0 - scene.beats[0] <= 8 } == true, "\(summary)")
        #expect(Self.isNear(result.tempoBPM, bpm), "\(summary)")
        // Средние по фазам с захвата, разброс в установившемся режиме (`settle` после захвата):
        // сразу после захвата ФАПЧ еще сходится, это проверяет `postLockConvergence`.
        _ = Self.checkLockedPhases(results, beats: scene.beats, period: period)
        guard let from = Self.lockedFrom(result, period: period) else { return }
        var pooled: [Double] = []
        for phased in results {
            pooled += phased.offsetValues(reference: beats, from: from + Self.settle)
        }
        let steady = SyncResult.meanAndSD(pooled)
        #expect(steady.sd <= 0.006, "pooled offset \(steady.mean * 1000) ± \(steady.sd * 1000) ms")
        let predicted = result.predictedOffsets(reference: beats, from: from + Self.settle)
        #expect(predicted.sd <= 0.002, "predicted beats \(predicted.mean * 1000) ± \(predicted.sd * 1000) ms")
        if [90.0, 100, 120, 160].contains(bpm) {
            Self.checkConvergence(result, beats: beats, label: "seed 1")
        }
    }

    /// Сходимость после захвата на темпах между проверенными в `steadyBeatLocksOnTime` (90, 100, 120,
    /// 160). Захват и окно `settle` кончаются до 9 с, поэтому сцены по 12 с.
    @Test(arguments: [95.0, 110])
    func postLockConvergence(bpm: Double) async {
        let (scene, result) = await Self.run { Drums.fourOnFloor(bpm: bpm, seconds: 12, hats: .eighths) }
        Self.checkConvergence(result, beats: result.audible(scene.beats), label: "\(Int(bpm)) BPM")
    }

    /// После захвата ФАПЧ еще сходится к доле (первая оценка темпа бывает неточна на 2-3 %, а
    /// `alpha` 0.25 снимает ошибку примерно на четверть за долю): каждая предсказанная доля в первые
    /// `settle` секунд после захвата лежит в пределах -35...+20 мс от слышимой.
    private static func checkConvergence(_ result: SyncResult, beats: [Double], label: String) {
        guard let lock = result.lockTime else {
            Issue.record("\(label): no lock")
            return
        }
        let window = result.predictedTimes.filter { $0 >= lock && $0 <= lock + settle }
        #expect(!window.isEmpty, "\(label)")
        for time in window {
            guard let beat = beats.min(by: { abs($0 - time) < abs($1 - time) }) else { continue }
            #expect((-0.035...0.020).contains(time - beat), "\(label): beat \(beat) predicted \((time - beat) * 1000) ms")
        }
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

    /// Разброс в установившемся режиме, через `settle` после захвата и перехода смеси, как в
    /// `steadyBeatLocksOnTime`: с 1.1 захват наступает раньше, пока ФАПЧ еще сходится.
    @Test func jitterSmallerAt120Hz() async {
        var config = SyncHarness.Config()
        config.renderRate = 120
        let (scene, result) = await Self.run({ SharedScenes.steady120 }, config)
        let offsets = Self.lockedFrom(result, period: 0.5).map {
            result.offsets(reference: result.audible(scene.beats), from: $0 + Self.settle)
        }
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
        #expect(result.peakGlow < 0.2, "peak glow \(result.peakGlow)")
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

    /// Драм-н-бейс с розовым шумом уровня `noiseDB` (зерно шума `seed`): F-мера по бочкам, был ли
    /// захват, описание прогона.
    private static func noisyDnB(noiseDB: Float, seed: UInt64) async -> (f: Double, locked: Bool, summary: String) {
        let (scene, result) = await run {
            let drums = Drums.dnb174()
            let noise = Drums.pinkNoise(levelDB: noiseDB, count: drums.samples.count, seed: seed)
            var mixed = drums
            mixed.samples = zip(drums.samples, noise).map { $0 + $1 }
            return mixed
        }
        let f = result.fMeasure(reference: result.audible(scene.kicks), tolerance: 0.05, from: from)
        return (f, result.lockTime != nil, "seed \(seed): " + describe(result, f: f, offsets: nil))
    }

    /// Шум под барабанами без захвата: онсеты бочки должны оставаться подтвержденными широкополосно.
    @Test func dnbInQuietNoiseStillGlowsOnKicks() async {
        let run = await Self.noisyDnB(noiseDB: -40, seed: 2)
        #expect(!run.locked, "\(run.summary)")
        #expect(run.f >= 0.95, "\(run.summary)")
    }

    /// На -30 dBFS F-мера зависит от зерна шума (у зерна 1 около 0.9), поэтому проверяется средняя
    /// по зернам 1-4.
    @Test func dnbInLouderNoiseGlowsOnKicksOnAverage() async {
        let runs = await withTaskGroup(of: (f: Double, locked: Bool, summary: String).self) { group in
            for seed in UInt64(1)...4 {
                group.addTask { await Self.noisyDnB(noiseDB: -30, seed: seed) }
            }
            var all: [(f: Double, locked: Bool, summary: String)] = []
            for await run in group {
                all.append(run)
            }
            return all
        }
        let summaries = runs.map(\.summary).sorted().joined(separator: "; ")
        let mean = runs.map(\.f).reduce(0, +) / Double(runs.count)
        #expect(runs.count == 4)
        #expect(runs.allSatisfy { !$0.locked }, "\(summaries)")
        #expect(mean >= 0.9, "mean F \(mean): \(summaries)")
    }

    /// Синкопы хип-хопа: после захвата доли вспыхивают, бочка вне сетки только слабо отсвечивает
    /// (`offGridScale` не выше порога вспышки). До 1.1 эталоном были доли вместе с бочками: на реальной
    /// музыке такие вспышки при захвате попадали в долю в 21 % случаев и читались как вспышки мимо такта.
    @Test func syncopationFlashesOnBeats() async {
        let (scene, result) = await Self.run { Drums.hipHop90() }
        guard let from = Self.lockedFrom(result, period: 60.0 / 90) else {
            Issue.record("no lock: \(Self.describe(result, f: nil, offsets: nil))")
            return
        }
        // До захвата светятся сами бочки, и на «и» тоже, поэтому F считается с захвата.
        #expect(from <= 8, "\(Self.describe(result, f: nil, offsets: nil))")
        let f = result.fMeasure(reference: result.audible(scene.beats), tolerance: 0.05, from: from)
        #expect(f >= 0.9, "\(Self.describe(result, f: f, offsets: nil))")
        let offGrid = scene.kicks.filter { kick in
            kick >= from && !scene.beats.contains { abs($0 - kick) < 0.030 }
        }
        let flashed = result.audible(offGrid).filter { kick in result.events.contains { abs($0 - kick) < 0.05 } }
        #expect(offGrid.count >= 10)
        #expect(flashed.isEmpty, "flashes at off-grid kicks \(flashed)")
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
        let (scene, results) = await Self.runPhases { Drums.fourOnFloor(bpm: 120, sampleRate: rate, hats: .eighths) }
        for (k, result) in results.enumerated() {
            let f = result.fMeasure(reference: result.audible(scene.beats), tolerance: 0.05, from: Self.from)
            #expect(f >= 0.9, "phase \(k): \(Self.describe(result, f: f, offsets: nil))")
        }
        _ = Self.checkLockedPhases(results, beats: scene.beats, period: 0.5, label: "\(Int(rate)) Hz")
    }

    @Test func bluetoothLatencyIsPredicted() async {
        var config = SyncHarness.Config()
        config.outputLatency = 0.180
        let (scene, results) = await Self.runPhases({ SharedScenes.steady120 }, config)
        _ = Self.checkLockedPhases(results, beats: scene.beats, period: 0.5)
    }

    /// Сдвиг синхронизации +40 мс сдвигает вспышки на 40 ± 3 мс (средние по всем фазам рендера).
    @Test func syncOffsetShiftsTheGlow() async {
        var shifted = SyncHarness.Config()
        shifted.syncOffset = 0.040
        let (scene, base) = await Self.runPhases { SharedScenes.steady120 }
        let (_, moved) = await Self.runPhases({ SharedScenes.steady120 }, shifted)
        let before = SyncResult.meanAndSD(Self.checkLockedPhases(base, beats: scene.beats, period: 0.5)).mean
        var after: [Double] = []
        for result in moved {
            guard let from = Self.lockedFrom(result, period: 0.5) else { continue }
            after += result.offsetValues(reference: result.audible(scene.beats), from: from, tolerance: 0.15)
        }
        let delta = SyncResult.meanAndSD(after).mean - before
        #expect(abs(delta - 0.040) <= 0.003, "shift \(delta * 1000) ms")
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
