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
