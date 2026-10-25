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
            tempo.append(0, kick: 0)
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

    /// Оценки, которые еще идут за старым темпом, счет согласных не обнуляют: нужно 12 из 16.
    @Test func relatedAgreementCountsOverTheWindow() {
        var tempo = TempoEstimator(framesPerSecond: 187.5)
        _ = tempo.accept(period: 0.5)
        Self.advance(&tempo, seconds: 4)
        for _ in 1..<TempoEstimator.relatedSwitchUpdates {
            #expect(!tempo.accept(period: 1.0).switched)
        }
        #expect(!tempo.accept(period: 0.5).switched)
        #expect(tempo.accept(period: 1.0) == TempoEstimate(period: 1.0, switched: true))
    }

    @Test func relatedAgreementNeedsTwelveOfTheLastSixteen() {
        var tempo = TempoEstimator(framesPerSecond: 187.5)
        _ = tempo.accept(period: 0.5)
        Self.advance(&tempo, seconds: 4)
        // 8 кратных, 8 близких, затем снова кратные: 12 из последних 16 набирается на 12-й из них.
        for _ in 0..<8 {
            #expect(!tempo.accept(period: 1.0).switched)
        }
        for _ in 0..<8 {
            #expect(!tempo.accept(period: 0.5).switched)
        }
        for index in 1...12 {
            let estimate = tempo.accept(period: 1.0)
            #expect(estimate.switched == (index == 12), "#\(index)")
            if estimate.switched { break }
        }
        #expect(tempo.period == 1.0)
    }

    /// Сырые оценки журнала ритма 2 владельца, как их видел код 1.1 (BPM, каждые 0.25 с с 5.26 с
    /// потока; снято зондом по записи журнала): захват на 78.8 BPM,
    /// музыка замедляется к ~72, оценка уходит в удвоенный темп, который плывет вместе с музыкой
    /// (157.9, затем 149.0 и 150.7, то есть 5.5 % и 4.4 % от 2 × 78.8 при допуске 4 %), потом
    /// возвращается к основному темпу. На 1.1 оценка 149.0 считалась далекой некратной, и две такие
    /// оценки подряд переключали темп на 150.7 на 7.01 с; обратно к 72 он шел 12 оценок из 16.
    private static let ownerLog2: [Double] = [
        77.7, 78.6, 77.7, 79.1, 79.0, 157.9, 149.0, 150.7, 157.5, 151.9, 151.0, 151.0, 151.9, 150.5, 151.5, 150.5,
        145.1, 73.4, 145.1, 72.9, 72.9, 72.9, 72.9, 72.9, 72.6, 72.8, 72.6, 72.4, 72.4, 72.3, 71.8, 72.0, 71.8,
    ]

    /// Удвоенная оценка, которая плывет вместе с замедлением, остается кратной: темп не уходит на ~150,
    /// а переходит к основному ~72, как только оценки к нему вернулись.
    @Test func driftDoesNotFlipOctave() {
        var tempo = TempoEstimator(framesPerSecond: 187.5)
        _ = tempo.accept(period: 60 / 78.8)
        Self.advance(&tempo, seconds: TempoEstimator.establishedAfter + 1)
        var switches: [Double] = []
        for bpm in Self.ownerLog2 {
            let estimate = tempo.accept(period: 60 / bpm)
            #expect(60 / estimate.period < 100, "raw \(bpm) BPM gave \(60 / estimate.period) BPM")
            if estimate.switched { switches.append(60 / estimate.period) }
        }
        #expect(switches.count <= 1, "switches to \(switches) BPM")
        let final = 60 / (tempo.period ?? 0)
        #expect(abs(final / 72 - 1) < 0.04, "final \(final) BPM")
    }

    /// Верная удвоенная оценка, которая плывет (GTZAN metal.00052 с 12.01 с: 162.0 -> 155.0 при
    /// захвате на 81.0 BPM, разброс 4.5 %), все равно набирает 12 согласных из 16: согласие считается
    /// до 6 %, а не до 4 %. На 1.1 этот файл переключался по правилу двух далеких на 14.26 с.
    @Test func driftingOctaveStillSwitchesAfterTwelve() {
        var tempo = TempoEstimator(framesPerSecond: 187.5)
        _ = tempo.accept(period: 60 / 81.0)
        Self.advance(&tempo, seconds: TempoEstimator.establishedAfter + 1)
        let doubled: [Double] = [162.0, 162.1, 161.8, 160.8, 160.3, 160.1, 159.4, 159.7, 156.2, 155.0, 156.0, 155.2]
        #expect(doubled.count == TempoEstimator.relatedSwitchUpdates)
        for (index, bpm) in doubled.enumerated() {
            let estimate = tempo.accept(period: 60 / bpm)
            #expect(estimate.switched == (index == doubled.count - 1), "#\(index + 1): \(bpm) BPM")
        }
        #expect(abs(60 / (tempo.period ?? 0) - 155.2) < 0.01)
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
            tempo.append(value, kick: 0)
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
            tempo.append(0, kick: 0)
        }
        #expect(tempo.update() == nil)
        #expect(tempo.period == nil)
    }

    @Test func reconfigureStartsOverAtTheNewRate() {
        var tempo = TempoEstimator(framesPerSecond: 187.5)
        for value in Self.impulses(seconds: 4) {
            tempo.append(value, kick: 0)
        }
        #expect(tempo.update() != nil)
        let rate = 44_100.0 / 256
        tempo.reconfigure(framesPerSecond: rate)
        #expect(tempo.framesPerSecond == rate)
        #expect(tempo.period == nil)
        // Импульсы 120 BPM на новой частоте шагов: один шаг на каждую долю.
        for index in 0..<Int(4 * rate) {
            let phase = Double(index).truncatingRemainder(dividingBy: rate / 2)
            tempo.append(phase < 1 ? 50 : 0, kick: 0)
        }
        #expect(tempo.update().map { abs($0.period - 0.5) / 0.5 < 0.02 } == true)
    }

    @Test func resetForgetsEverything() {
        var tempo = TempoEstimator(framesPerSecond: 187.5)
        for value in Self.impulses(seconds: 4) {
            tempo.append(value, kick: 0)
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

    /// Функция онсетов сцены в оценку темпа, `update` каждые 0.25 с времени потока. С `kickSamples`
    /// функция бочки берется из этого сигнала, а не из сцены.
    private static func run(_ samples: [Float], kickSamples: [Float]? = nil, sampleRate: Double = 48_000) -> Run {
        let analyzer = StreamAnalyzer(sampleRate: sampleRate)
        var tempo = TempoEstimator(framesPerSecond: analyzer.config.framesPerSecond)
        var estimates: [(time: Double, estimate: TempoEstimate)] = []
        var nextUpdate = TempoEstimator.updateInterval
        let hops = analyzer.processSignal(samples)
        let kicks = kickSamples.map { StreamAnalyzer(sampleRate: sampleRate).processSignal($0).map(\.kickODF) }
        for (index, hop) in hops.enumerated() {
            let kick = kicks.map { index < $0.count ? $0[index] : 0 } ?? hop.kickODF
            tempo.append(hop.broadbandODF, kick: kick)
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
        var snare: Bool
        var seed: UInt64

        var testDescription: String {
            "\(Int(bpm)) BPM, humanize \(Int(humanize * 1000)) ms\(snare ? ", backbeat snare" : ""), seed \(seed)"
        }

        /// Ровно 90...170 BPM через 10 и 175; разброс бочки 8 мс на 140...175 через 5 и малый на слабых
        /// долях на 120, 140 и 160, оба на четырех зернах.
        static let all: [SweepCase] = {
            var cases: [SweepCase] = []
            for bpm in stride(from: 90.0, through: 170, by: 10) + [175] {
                cases.append(SweepCase(bpm: bpm, humanize: 0, snare: false, seed: 1))
            }
            for seed: UInt64 in 1...4 {
                for step in 0...7 {
                    cases.append(SweepCase(bpm: 140 + 5 * Double(step), humanize: 0.008, snare: false, seed: seed))
                }
                for bpm in [120.0, 140, 160] {
                    cases.append(SweepCase(bpm: bpm, humanize: 0, snare: true, seed: seed))
                }
            }
            return cases
        }()
    }

    /// Хэт восьмыми, 12 с, оценки с 4 с: каждая в пределах 4 % от темпа или его октавы (½× или 2×),
    /// не больше одного переключения и никаких 3:2, 2:3, 4:3, 3:4. Каждое переключение сбрасывает
    /// захват трекера, а кратные темпы ставят свечение не на доли.
    @Test(arguments: SweepCase.all)
    func tempoSweepIsStable(_ sweep: SweepCase) async {
        let run = await runOffCooperativePool {
            Self.run(
                Drums.fourOnFloor(
                    bpm: sweep.bpm, seconds: 12, hats: .eighths, humanizeSigma: sweep.humanize,
                    snareOnBackbeat: sweep.snare, seed: sweep.seed
                ).samples
            )
        }
        Self.checkStable(run, bpm: sweep.bpm)
    }

    /// Смена темпа на кратный принимается не позже чем через `limit` секунд, а до нее темп держится.
    @Test(arguments: [(120.0, 160.0, 5.0), (120, 90, 5.5)])
    func relatedTempoChangeIsAcceptedInTime(from: Double, to: Double, limit: Double) async {
        let run = await runOffCooperativePool {
            Self.run(Drums.tempoJump(from: from, to: to, at: 12, seconds: 18).samples)
        }
        let switches = run.estimates.filter { $0.time >= 4 && $0.estimate.switched }
        #expect(switches.count == 1)
        let target = 60 / to
        let change = switches.first { abs($0.estimate.period - target) / target < 0.04 }
        #expect(change.map { $0.time > 12 && $0.time - 12 <= limit } == true, "switches \(switches.map(\.time))")
        for (time, estimate) in run.estimates where time >= 4 && time < 12 {
            #expect(abs(estimate.period * from / 60 - 1) < 0.04, "t \(time): \(60 / estimate.period) BPM")
        }
    }

    /// Настоящий скачок темпа на некратный (или почти кратный) принимается не позже, чем в 1.1: допуск
    /// дрейфа для октавы не должен задерживать его правилом кратных. `limit` в секундах после скачка
    /// снят с кода 1.1 на этой же сцене (2.0, 2.0 и 1.504 с). 100 -> 140 и 90 -> 128 лежат между 4/3
    /// и 3/2 (1.40 и 1.42), 80 -> 150 в 6 % от удвоения.
    @Test(arguments: [(100.0, 140.0, 2.001), (90, 128, 2.001), (80, 150, 1.505)])
    func realJumpStillSwitches(from: Double, to: Double, limit: Double) async {
        let run = await runOffCooperativePool {
            Self.run(Drums.tempoJump(from: from, to: to, at: 12, seconds: 18).samples)
        }
        let switches = run.estimates.filter { $0.time >= 4 && $0.estimate.switched }
        let target = 60 / to
        let change = switches.first { $0.time > 12 && abs($0.estimate.period - target) / target < 0.04 }
        #expect(change.map { $0.time - 12 <= limit } == true, "switches \(switches.map { ($0.time, 60 / $0.estimate.period) })")
    }

    /// Функция бочки из розового шума (без долей) рядом с широкополосной функцией барабанов 160 BPM:
    /// бочка ничего не поддерживает, и спор 3:2 не должен уходить к лагу ближе к 120 BPM (107).
    @Test func noisyKickDoesNotPickARelatedRival() async {
        let run = await runOffCooperativePool {
            Self.run(
                Drums.fourOnFloor(bpm: 160, seconds: 12, hats: .eighths).samples,
                kickSamples: Drums.noiseOnly(levelDB: -20, seconds: 12).samples
            )
        }
        Self.checkStable(run, bpm: 160)
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
        #expect(late.count >= 30)
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
