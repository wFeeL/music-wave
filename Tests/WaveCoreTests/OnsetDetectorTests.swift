import Foundation
import Testing
@testable import WaveCore

/// Онсеты на синтетических барабанах, 48 кГц, оценка после первой секунды. Только Linux: отличия
/// libm могут перевернуть пограничные случаи на маке, а там набор добавил бы десятки секунд.
@Suite(.enabled(if: TestPlatform.isLinux))
struct OnsetDetectorTests {
    private static let rate = 48_000.0
    private static let from = 1.0

    private struct Detection {
        var event: OnsetEvent
        /// Конец окна, на котором онсет сработал.
        var endTime: Double
    }

    private struct Analysis {
        var kicks: [Detection]
        var broadband: [Detection]
    }

    private static func analyze(_ samples: [Float], sampleRate: Double = rate) -> Analysis {
        let hops = StreamAnalyzer(sampleRate: sampleRate).processSignal(samples)
        return Analysis(
            kicks: hops.compactMap { hop in hop.kickOnset.map { Detection(event: $0, endTime: hop.endTime) } },
            broadband: hops.compactMap { hop in hop.broadbandOnset.map { Detection(event: $0, endTime: hop.endTime) } }
        )
    }

    private static func analyze(_ scene: DrumScene) -> Analysis {
        analyze(scene.samples, sampleRate: scene.sampleRate)
    }

    /// Сопоставление один к одному: каждой правде ближайшее свободное срабатывание в пределах
    /// `tolerance`. Правда берется с момента `from` и не позже чем за 0.1 с до конца сцены.
    private struct Score {
        var pairs: [(detection: Int, reference: Double)]
        var falsePositives: Int
        var references: Int

        var recall: Double {
            Double(pairs.count) / max(Double(references), 1)
        }

        var precision: Double {
            Double(pairs.count) / max(Double(pairs.count + falsePositives), 1)
        }

        var fMeasure: Double {
            let matched = Double(pairs.count)
            let precision = matched / max(matched + Double(falsePositives), 1)
            let recall = matched / max(Double(references), 1)
            return precision + recall > 0 ? 2 * precision * recall / (precision + recall) : 0
        }
    }

    private static func score(_ times: [Double], reference: [Double], until end: Double, tolerance: Double = 0.050) -> Score {
        let references = reference.filter { $0 >= from && $0 <= end - 0.1 }
        var used = [Bool](repeating: false, count: times.count)
        var pairs: [(detection: Int, reference: Double)] = []
        for truth in references {
            let candidate = times.indices
                .filter { !used[$0] && abs(times[$0] - truth) <= tolerance }
                .min { abs(times[$0] - truth) < abs(times[$1] - truth) }
            if let candidate {
                used[candidate] = true
                pairs.append((candidate, truth))
            }
        }
        let falsePositives = times.indices.filter { !used[$0] && times[$0] >= from && times[$0] <= end - 0.1 }.count
        return Score(pairs: pairs, falsePositives: falsePositives, references: references.count)
    }

    private static func mean(_ values: [Double]) -> Double {
        values.reduce(0, +) / Double(max(values.count, 1))
    }

    private static func standardDeviation(_ values: [Double]) -> Double {
        let m = mean(values)
        return (values.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(max(values.count, 1))).squareRoot()
    }

    /// Средняя задержка (конец окна на срабатывании минус настоящий онсет) и ее разброс.
    private static func lags(_ detections: [Detection], score: Score) -> (lag: [Double], timeError: [Double]) {
        (
            score.pairs.map { detections[$0.detection].endTime - $0.reference },
            score.pairs.map { detections[$0.detection].event.time - $0.reference }
        )
    }

    @Test func kickOnsetsHaveConstantLag() async {
        let result = await runOffCooperativePool { () -> (f: Double, lag: [Double], error: [Double]) in
            let scene = Drums.fourOnFloor(bpm: 120, seconds: 12)
            let kicks = Self.analyze(scene).kicks
            let score = Self.score(kicks.map(\.event.time), reference: scene.kicks, until: 12)
            let (lag, error) = Self.lags(kicks, score: score)
            return (score.fMeasure, lag, error)
        }
        let lag = Self.mean(result.lag)
        #expect(result.f >= 0.98)
        #expect(lag >= 0.004 && lag <= 0.010, "mean lag \(lag)")
        #expect(Self.standardDeviation(result.lag) <= 0.003, "lag SD \(Self.standardDeviation(result.lag))")
        #expect(abs(Self.mean(result.error)) <= 0.003, "mean time error \(Self.mean(result.error))")
    }

    /// Темпы сдвинуты от целого числа шагов на долю (90 BPM при 48 кГц это ровно 125 шагов, и все
    /// бочки попадали бы на одну фазу шага).
    @Test func lagIsStableAcrossLevelAndTempo() async {
        let results = await runOffCooperativePool { () -> [(mean: Double, recall: Double)] in
            var results: [(mean: Double, recall: Double)] = []
            for levelDB: Float in [0, -20] {
                for bpm in [91.0, 159] {
                    let scene = Drums.fourOnFloor(bpm: bpm, seconds: 12, levelDB: levelDB)
                    let kicks = Self.analyze(scene).kicks
                    let score = Self.score(kicks.map(\.event.time), reference: scene.kicks, until: 12)
                    results.append((Self.mean(Self.lags(kicks, score: score).lag), score.recall))
                }
            }
            return results
        }
        let means = results.map(\.mean)
        #expect(results.count == 4)
        #expect(results.allSatisfy { $0.recall >= 0.9 }, "recall \(results.map(\.recall))")
        #expect((means.max() ?? 0) - (means.min() ?? 0) <= 0.004, "mean lags \(means)")
    }

    /// Бочки с хэтами восьмыми на темпах, где доля не равна целому числу шагов, ровно и с разбросом
    /// 4 мс, по два зерна; плюс сцены, где должны найтись все бочки.
    @Test func kickRecallAcrossTempos() async {
        let results = await runOffCooperativePool { () -> [(name: String, score: Score)] in
            var results: [(name: String, score: Score)] = []
            for bpm in [91.0, 121, 141, 159] {
                for humanize in [0.0, 0.004] {
                    for seed: UInt64 in [1, 2] {
                        let scene = Drums.fourOnFloor(
                            bpm: bpm, seconds: 12, hats: .eighths, humanizeSigma: humanize, seed: seed
                        )
                        let kicks = Self.analyze(scene).kicks
                        results.append(("\(bpm) BPM σ \(humanize) seed \(seed)", Self.score(kicks.map(\.event.time), reference: scene.kicks, until: 12)))
                    }
                }
            }
            return results
        }
        for (name, score) in results {
            #expect(score.recall >= 0.9, "\(name): recall \(score.recall)")
            #expect(score.precision >= 0.95, "\(name): precision \(score.precision)")
        }
        let full = await runOffCooperativePool { () -> [(name: String, score: Score)] in
            let scenes: [(String, DrumScene)] = [
                ("dnb174", Drums.dnb174(seconds: 12)),
                ("hipHop90", Drums.hipHop90(seconds: 12)),
                ("44.1 kHz", Drums.fourOnFloor(bpm: 120, seconds: 12, sampleRate: 44_100, hats: .eighths, offbeatBass: true)),
                ("96 kHz", Drums.fourOnFloor(bpm: 120, seconds: 12, sampleRate: 96_000, hats: .eighths, offbeatBass: true)),
            ]
            return scenes.map { name, scene in
                (name, Self.score(Self.analyze(scene).kicks.map(\.event.time), reference: scene.kicks, until: 12))
            }
        }
        for (name, score) in full {
            #expect(score.references > 0 && score.recall == 1, "\(name): recall \(score.recall)")
        }
    }

    @Test func steadyTonesDoNotTrigger() async {
        let analysis = await runOffCooperativePool {
            let count = Int(Self.rate * 10)
            let low = TestSignals.sine(frequency: 60, amplitude: 0.4, sampleRate: Self.rate, count: count)
            let high = TestSignals.sine(frequency: 1000, amplitude: 0.4, sampleRate: Self.rate, count: count)
            return Self.analyze(zip(low, high).map { $0 + $1 })
        }
        #expect(analysis.kicks.filter { $0.event.time >= Self.from }.isEmpty)
        #expect(analysis.broadband.filter { $0.event.time >= Self.from }.isEmpty)
    }

    @Test func quietNoiseDoesNotTrigger() async {
        let analysis = await runOffCooperativePool {
            Self.analyze(Drums.pinkNoise(levelDB: -40, count: Int(Self.rate * 10), seed: 7))
        }
        #expect(analysis.kicks.filter { $0.event.time >= Self.from }.isEmpty)
    }

    /// В трех бинах бочки шум иногда дает подъем, похожий на удар; редкие ложные удары гасят
    /// уверенность и захват ритма в трекере. Поэтому для бочки граница это частота по нескольким
    /// прогонам, а широкополосная функция в шуме молчит совсем.
    @Test func pinkNoiseRarelyTriggersKicks() async {
        let runs = await runOffCooperativePool { () -> [(kicks: [Double], broadband: [Double])] in
            (UInt64(1)...6).map { seed in
                let analysis = Self.analyze(Drums.pinkNoise(levelDB: -20, count: Int(Self.rate * 10), seed: seed))
                return (
                    analysis.kicks.map(\.event.time).filter { $0 >= Self.from },
                    analysis.broadband.map(\.event.time).filter { $0 >= Self.from }
                )
            }
        }
        let seconds = Double(runs.count) * (10 - Self.from)
        let falseKicks = runs.map(\.kicks.count)
        // Граница 0.2 в секунду, не 0: три бина бочки в шуме изредка дают подъем, похожий на удар
        // (около 0.17 в секунду при пороге 2.0). Эти ложные удары должен гасить трекер (уверенность
        // и захват ритма): от этого зависит noiseAloneNeverGlows из задачи 5.
        #expect(Double(falseKicks.reduce(0, +)) / seconds <= 0.2, "false kicks per run \(falseKicks)")
        #expect(falseKicks.allSatisfy { $0 <= 2 }, "false kicks per run \(falseKicks)")
        for run in runs {
            #expect(run.broadband.isEmpty, "broadband onsets at \(run.broadband)")
        }
    }

    @Test func offbeatBassDoesNotTriggerKicks() async {
        let score = await runOffCooperativePool {
            let scene = Drums.fourOnFloor(bpm: 128, seconds: 12, offbeatBass: true)
            let kicks = Self.analyze(scene).kicks
            return Self.score(kicks.map(\.event.time), reference: scene.kicks, until: 12)
        }
        #expect(score.recall >= 0.93, "recall \(score.recall)")
        #expect(score.falsePositives == 0, "false onsets \(score.falsePositives)")
    }

    @Test func onsetsAreAtLeast150msApart() async {
        let (analysis, pairs) = await runOffCooperativePool { () -> (Analysis, Int) in
            // Флэм: пары бочек через 50 мс, пара каждые 0.5 с.
            var samples = [Float](repeating: 0, count: Int(Self.rate * 10))
            var pairs = 0
            var t = 0.25
            while t < 9.5 {
                Drums.kick808(into: &samples, at: t, sampleRate: Self.rate)
                Drums.kick808(into: &samples, at: t + 0.050, sampleRate: Self.rate)
                pairs += t >= Self.from ? 1 : 0
                t += 0.5
            }
            return (Self.analyze(samples), pairs)
        }
        for onsets in [analysis.kicks, analysis.broadband] {
            let times = onsets.map(\.event.time)
            for (a, b) in zip(times, times.dropFirst()) {
                #expect(b - a >= 0.150 - 1e-9, "onsets at \(a) and \(b)")
            }
        }
        #expect(analysis.kicks.filter { $0.event.time >= Self.from }.count >= pairs - 1)
    }

    @Test func broadbandSeesDrums() async {
        let result = await runOffCooperativePool { () -> (f: Double, references: Int) in
            let scene = Drums.hipHop90(seconds: 12)
            var merged: [Double] = []
            for time in (scene.kicks + scene.snares + scene.hats).sorted() {
                if let last = merged.last, time - last < 0.030 { continue }
                merged.append(time)
            }
            let broadband = Self.analyze(scene).broadband
            let score = Self.score(broadband.map(\.event.time), reference: merged, until: 12)
            return (score.fMeasure, score.references)
        }
        #expect(result.references > 30)
        #expect(result.f >= 0.9)
    }
}

/// Отдельные проверки потока SuperFlux и выбора пиков на коротких последовательностях.
struct SuperFluxTests {
    private static func run(_ flux: inout SuperFlux, _ frames: [[Float]]) -> [Float] {
        frames.map { frame in frame.withUnsafeBufferPointer { flux.process($0) } }
    }

    @Test func steadyInputGivesNoFlux() {
        var flux = SuperFlux(lags: [1, 1, 1], weights: [1, 1, 1])
        let values = Self.run(&flux, [[Float]](repeating: [0.1, 0.5, 0.2], count: 5))
        #expect(values == [0, 0, 0, 0, 0])
    }

    /// γ = e - 1 дает L = log1p((e - 1) A), то есть 1 при A = 1.
    @Test func maxFilterIgnoresMovesToANeighbour() {
        var flux = SuperFlux(lags: [1, 1, 1], weights: [1, 1, 1], gamma: Float(M_E - 1))
        let values = Self.run(&flux, [[0, 0, 0], [0, 1, 0], [1, 0, 0], [0, 0, 0], [0, 0, 1]])
        #expect(values[0] == 0)
        #expect(abs(values[1] - 1) < 1e-6)
        #expect(values[2] == 0)
        #expect(values[3] == 0)
        #expect(abs(values[4] - 1) < 1e-6)
    }

    @Test func lagAndWeightPerElement() {
        var flux = SuperFlux(lags: [2], weights: [2], gamma: Float(M_E - 1))
        // Сравнение идет с кадром на два шага назад; пока в истории меньше двух кадров, поток равен 0.
        let values = Self.run(&flux, [[0], [1], [1], [1]])
        #expect(values[0] == 0 && values[1] == 0)
        #expect(abs(values[2] - 2) < 1e-6)
        #expect(values[3] == 0)
        flux.reset()
        #expect(Self.run(&flux, [[1]]) == [0])
    }
}

struct OnlinePeakPickerTests {
    private static let hop = 256.0 / 48_000

    @Test func firesOnceOnARiseAndHoldsTheCombineWindow() {
        var picker = OnlinePeakPicker(hopDuration: Self.hop)
        var fired: [Int] = []
        for n in 0..<200 {
            // Онсет на 50, второй через 10 шагов (53 мс, внутри 150 мс), третий на 120.
            let spike = n == 50 || n == 60 || n == 120
            let strength = picker.process(spike ? 2 : 0, levelDB: spike ? -10 : -50)
            if let strength {
                fired.append(n)
                #expect(strength > 0 && strength <= 1)
            }
        }
        #expect(fired == [50, 120])
    }

    @Test func needsARealLevelRise() {
        var picker = OnlinePeakPicker(hopDuration: Self.hop)
        var fired = 0
        for n in 0..<200 {
            // Уровень поднимается только на 6 дБ, меньше minRiseDB.
            let spike = n % 40 == 39
            if picker.process(spike ? 2 : 0, levelDB: spike ? -24 : -30) != nil { fired += 1 }
        }
        #expect(fired == 0)
        picker.reset()
        #expect(picker.process(2, levelDB: -10) != nil)
    }
}
