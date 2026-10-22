import Foundation
import Testing
@testable import WaveCore

/// Шаг устойчивости и простые входы без сцен: идут на всех платформах.
struct TempoStickinessTests {
    @Test func ignoresSingleOutlier() {
        var tempo = TempoEstimator(framesPerSecond: 187.5)
        #expect(tempo.accept(period: 0.5) == TempoEstimate(period: 0.5, switched: true))
        #expect(tempo.accept(period: 0.5) == TempoEstimate(period: 0.5, switched: false))
        #expect(tempo.accept(period: 0.5) == TempoEstimate(period: 0.5, switched: false))
        #expect(tempo.accept(period: 0.7) == TempoEstimate(period: 0.5, switched: false))
        #expect(tempo.period == 0.5)
        #expect(tempo.accept(period: 0.7) == TempoEstimate(period: 0.7, switched: true))
        #expect(tempo.period == 0.7)
    }

    @Test func movesTwentyPercentTowardNearEstimates() {
        var tempo = TempoEstimator(framesPerSecond: 187.5)
        _ = tempo.accept(period: 0.5)
        let estimate = tempo.accept(period: 0.52)
        #expect(!estimate.switched)
        #expect(abs(estimate.period - 0.504) < 1e-12)
    }

    @Test func outliersThatDisagreeDoNotSwitch() {
        var tempo = TempoEstimator(framesPerSecond: 187.5)
        _ = tempo.accept(period: 0.5)
        // Два подряд далеких значения, но друг с другом расходятся больше чем на 3 %.
        #expect(tempo.accept(period: 0.7) == TempoEstimate(period: 0.5, switched: false))
        #expect(tempo.accept(period: 0.75) == TempoEstimate(period: 0.5, switched: false))
        // Близкое значение между ними сбрасывает кандидата.
        _ = tempo.accept(period: 0.5)
        #expect(tempo.accept(period: 0.75) == TempoEstimate(period: 0.5, switched: false))
    }

    @Test func ignoresInvalidPeriods() {
        var tempo = TempoEstimator(framesPerSecond: 187.5)
        for bad in [Double.nan, .infinity, -.infinity, 0, -0.5] {
            #expect(!tempo.accept(period: bad).switched)
            #expect(tempo.period == nil)
        }
        _ = tempo.accept(period: 0.5)
        for bad in [Double.nan, .infinity, 0, -0.5] {
            #expect(tempo.accept(period: bad) == TempoEstimate(period: 0.5, switched: false))
        }
        // Неверные значения не сбрасывают и не подтверждают кандидата.
        _ = tempo.accept(period: 0.7)
        _ = tempo.accept(period: .nan)
        #expect(tempo.accept(period: 0.7) == TempoEstimate(period: 0.7, switched: true))
    }

    /// Секунды потока для шага устойчивости без самой оценки.
    private static func advance(_ tempo: inout TempoEstimator, seconds: Double) {
        for _ in 0..<Int(seconds * 187.5) {
            tempo.append(0)
        }
    }

    @Test func relatedRatioNeedsLongAgreementOnceEstablished() {
        for ratio in [2.0, 0.5, 1.5, 2.0 / 3, 4.0 / 3, 0.75] {
            var tempo = TempoEstimator(framesPerSecond: 187.5)
            _ = tempo.accept(period: 0.5)
            Self.advance(&tempo, seconds: TempoEstimator.establishedAfter + 0.1)
            let related = 0.5 * ratio
            for update in 1..<TempoEstimator.relatedSwitchUpdates {
                #expect(tempo.accept(period: related) == TempoEstimate(period: 0.5, switched: false), "×\(ratio) #\(update)")
            }
            #expect(tempo.accept(period: related) == TempoEstimate(period: related, switched: true), "×\(ratio)")
        }
    }

    @Test func relatedRatioSwitchesQuicklyAtFirst() {
        var tempo = TempoEstimator(framesPerSecond: 187.5)
        _ = tempo.accept(period: 0.333)
        Self.advance(&tempo, seconds: TempoEstimator.establishedAfter - 0.5)
        #expect(!tempo.accept(period: 0.666).switched)
        #expect(tempo.accept(period: 0.666) == TempoEstimate(period: 0.666, switched: true))
    }

    @Test func unrelatedTempoSwitchesQuicklyLater() {
        var tempo = TempoEstimator(framesPerSecond: 187.5)
        _ = tempo.accept(period: 0.6)
        Self.advance(&tempo, seconds: 10)
        // 100 -> 140 BPM: отношение 1.4 не кратное.
        #expect(!tempo.accept(period: 60.0 / 140).switched)
        #expect(tempo.accept(period: 60.0 / 140) == TempoEstimate(period: 60.0 / 140, switched: true))
    }

    @Test func interruptedAgreementStartsOver() {
        var tempo = TempoEstimator(framesPerSecond: 187.5)
        _ = tempo.accept(period: 0.5)
        Self.advance(&tempo, seconds: 4)
        for _ in 1..<TempoEstimator.relatedSwitchUpdates {
            _ = tempo.accept(period: 1.0)
        }
        // Оценка рядом с текущим периодом прерывает серию.
        _ = tempo.accept(period: 0.5)
        for _ in 1..<TempoEstimator.relatedSwitchUpdates {
            #expect(!tempo.accept(period: 1.0).switched)
        }
        #expect(tempo.accept(period: 1.0).switched)
    }

    /// Импульсы ровно на 120 BPM при 187.5 шагах в секунду (93.75 шага на долю).
    private static func impulses(seconds: Double, bpm: Double = 120) -> [Float] {
        let fps = 187.5
        let count = Int(seconds * fps)
        var odf = [Float](repeating: 0, count: count)
        var beat = 0.0
        while Int(beat.rounded()) < count {
            odf[Int(beat.rounded())] = 50
            beat += fps * 60 / bpm
        }
        return odf
    }

    @Test func waitsForMinimumHistory() {
        var tempo = TempoEstimator(framesPerSecond: 187.5)
        let odf = Self.impulses(seconds: 3)
        for (index, value) in odf.enumerated() {
            tempo.append(value)
            // Каждые 0.25 с (47 шагов), как у трекера.
            guard (index + 1) % 47 == 0 else { continue }
            let estimate = tempo.update()
            if Double(index + 1) < 2 * 187.5 {
                #expect(estimate == nil)
            } else {
                #expect(estimate.map { abs($0.period - 0.5) / 0.5 < 0.02 } == true)
            }
        }
    }

    @Test func silenceGivesNoTempo() {
        var tempo = TempoEstimator(framesPerSecond: 187.5)
        for _ in 0..<1200 {
            tempo.append(0)
        }
        #expect(tempo.update() == nil)
        #expect(tempo.period == nil)
    }

    @Test func resetForgetsEverything() {
        var tempo = TempoEstimator(framesPerSecond: 187.5)
        for value in Self.impulses(seconds: 4) {
            tempo.append(value)
        }
        #expect(tempo.update() != nil)
        tempo.reset()
        #expect(tempo.period == nil)
        #expect(tempo.update() == nil)
    }
}

/// Темп на синтетических барабанах, 48 кГц. Только Linux, как остальные сцены.
@Suite(.enabled(if: TestPlatform.isLinux))
struct TempoEstimatorTests {
    private struct Run: Sendable {
        /// Время потока каждой оценки и сама оценка.
        var estimates: [(time: Double, estimate: TempoEstimate)]
    }

    /// Функция онсетов сцены в оценку темпа, `update` каждые 0.25 с времени потока.
    private static func run(_ samples: [Float], sampleRate: Double = 48_000) -> Run {
        let analyzer = StreamAnalyzer(sampleRate: sampleRate)
        var tempo = TempoEstimator(framesPerSecond: analyzer.config.framesPerSecond)
        var estimates: [(time: Double, estimate: TempoEstimate)] = []
        var nextUpdate = TempoEstimator.updateInterval
        for hop in analyzer.processSignal(samples) {
            tempo.append(hop.broadbandODF)
            if hop.endTime >= nextUpdate {
                nextUpdate += TempoEstimator.updateInterval
                if let estimate = tempo.update() {
                    estimates.append((hop.endTime, estimate))
                }
            }
        }
        return Run(estimates: estimates)
    }

    /// Все оценки с `from` секунды в пределах `tolerance` от `period`, без переключений.
    private static func check(_ run: Run, period: Double, from: Double = 4, tolerance: Double = 0.04) {
        let late = run.estimates.filter { $0.time >= from }
        #expect(late.count >= 10)
        for (time, estimate) in late {
            let error = abs(estimate.period - period) / period
            #expect(error < tolerance, "t \(time): \(60 / estimate.period) BPM, want \(60 / period)")
            #expect(!estimate.switched, "switch at \(time) to \(60 / estimate.period) BPM")
        }
    }

    struct SweepCase: Sendable, CustomTestStringConvertible {
        var bpm: Double
        var humanize: Double
        var seed: UInt64

        var testDescription: String {
            "\(Int(bpm)) BPM, humanize \(Int(humanize * 1000)) ms, seed \(seed)"
        }

        /// 90...170 BPM через 5 ровно; 140...170 с разбросом бочки 8 мс на двух зернах.
        static let all: [SweepCase] = {
            var cases: [SweepCase] = []
            for step in 0...16 {
                cases.append(SweepCase(bpm: 90 + 5 * Double(step), humanize: 0, seed: 1))
            }
            for step in 0...6 {
                for seed: UInt64 in [1, 2] {
                    cases.append(SweepCase(bpm: 140 + 5 * Double(step), humanize: 0.008, seed: seed))
                }
            }
            return cases
        }()
    }

    /// Хэт восьмыми, 16 с, оценки с 4 с: каждая в пределах 4 % от темпа или его октавы (½× или 2×),
    /// не больше одного переключения и никаких 3:2, 2:3, 4:3, 3:4. Каждое переключение сбрасывает
    /// захват трекера, а кратные темпы ставят свечение не на доли.
    @Test(arguments: SweepCase.all)
    func tempoSweepIsStable(_ sweep: SweepCase) async {
        let run = await runOffCooperativePool {
            Self.run(
                Drums.fourOnFloor(
                    bpm: sweep.bpm, seconds: 16, hats: .eighths, humanizeSigma: sweep.humanize, seed: sweep.seed
                ).samples
            )
        }
        Self.checkStable(run, bpm: sweep.bpm)
    }

    /// Шум -20 dBFS под сценой -6 dB на 150 и 160 BPM: хэтов почти не видно, и у одной бочки октаву
    /// выбирает приоритет. Октава допустима, переброс туда и обратно нет.
    @Test(arguments: [150.0, 160])
    func noisyTempoDoesNotFlip(bpm: Double) async {
        let runs = await runOffCooperativePool { () -> [Run] in
            [UInt64(3), 4, 5].map { seed in
                let scene = Drums.fourOnFloor(bpm: bpm, seconds: 16, hats: .eighths, levelDB: -6)
                let noise = Drums.pinkNoise(levelDB: -20, count: scene.samples.count, seed: seed)
                return Self.run(zip(scene.samples, noise).map { $0 + $1 })
            }
        }
        for run in runs {
            Self.checkStable(run, bpm: bpm)
        }
    }

    /// Оценки с 4 с: каждая в пределах 4 % от темпа или его октавы, не больше одного переключения.
    private static func checkStable(_ run: Run, bpm: Double) {
        let late = run.estimates.filter { $0.time >= 4 }
        #expect(late.count >= 40)
        let switches = late.filter(\.estimate.switched).map(\.time)
        #expect(switches.count <= 1, "switches at \(switches)")
        let octaves: [Double] = [1, 2, 0.5]
        let related: [Double] = [1.5, 2.0 / 3, 4.0 / 3, 0.75]
        for (time, estimate) in late {
            let ratio: Double = 60 / estimate.period / bpm
            let isOctave = octaves.contains { (multiple: Double) -> Bool in abs(ratio / multiple - 1) < 0.04 }
            let isRelated = related.contains { (multiple: Double) -> Bool in abs(ratio / multiple - 1) < 0.04 }
            #expect(isOctave && !isRelated, "t \(time): \(60 / estimate.period) BPM")
        }
    }

    @Test(arguments: [90.0, 100, 120, 128, 140, 160])
    func findsSteadyTempo(bpm: Double) async {
        let run = await runOffCooperativePool {
            Self.run(Drums.fourOnFloor(bpm: bpm, seconds: 12, hats: .eighths).samples)
        }
        Self.check(run, period: 60 / bpm)
    }

    @Test func foldsFastTempoIntoRange() async {
        let run = await runOffCooperativePool {
            Self.run(Drums.dnb174(seconds: 12).samples)
        }
        Self.check(run, period: 60 / 87)
    }

    /// Розовый шум -20 dBFS под сценой -6 dB (ложные онсеты бочки около 0.17 в секунду) не сбивает
    /// темп и его октаву. 160 BPM здесь не проверяется: в таком шуме хэтов почти не видно, у одной
    /// бочки 160 и 80 BPM различает только приоритет (0.90 против 0.81), и оценка уходит на 80.
    @Test(arguments: [90.0, 120])
    func holdsTempoInNoise(bpm: Double) async {
        let run = await runOffCooperativePool { () -> Run in
            let scene = Drums.fourOnFloor(bpm: bpm, seconds: 12, hats: .eighths, levelDB: -6)
            let noise = Drums.pinkNoise(levelDB: -20, count: scene.samples.count, seed: 3)
            return Self.run(zip(scene.samples, noise).map { $0 + $1 })
        }
        Self.check(run, period: 60 / bpm)
    }

    @Test func swungHatsKeepTheBeat() async {
        let run = await runOffCooperativePool {
            Self.run(Drums.fourOnFloor(bpm: 100, seconds: 12, hats: .eighths, swing: 0.66).samples)
        }
        Self.check(run, period: 0.6)
    }

    @Test func syncopationKeepsTheBeat() async {
        let run = await runOffCooperativePool {
            Self.run(Drums.hipHop90(seconds: 12).samples)
        }
        Self.check(run, period: 60 / 90.0)
    }
}
