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

    /// Тихая бочка под пэдом (пики на долях 5.4-9, фон до 1.7): порог широкополосной функции
    /// опускается по типичному пику. Пока разгоняется уровень акцента и спадает типичный пик, онсеты
    /// есть на трех бочках из четырех (самые слабые, 5.4-5.8, стоят у границы 3.2 T), с 16 с на
    /// каждой. С постоянным порогом 10 здесь не было ни одного онсета.
    @Test func softKicksUnderAPadGiveBroadbandOnsets() async {
        let (settling, settled) = await runOffCooperativePool { () -> (Score, Score) in
            let scene = Drums.softKicksUnderPad(seconds: 24)
            let broadband = Self.analyze(scene).broadband.map(\.event.time)
            func score(from start: Double, to end: Double) -> Score {
                Self.score(
                    broadband.filter { $0 >= start - 0.05 && $0 < end - 0.05 },
                    reference: scene.kicks.filter { $0 >= start && $0 < end - 0.05 }, until: 24
                )
            }
            return (score(from: 8, to: 16), score(from: 16, to: 24))
        }
        #expect(settling.references == 16 && settled.references >= 15)
        #expect(settling.recall >= 0.75, "8-16 s: recall \(settling.recall)")
        #expect(settled.recall == 1, "16-24 s: recall \(settled.recall)")
        #expect(settling.falsePositives + settled.falsePositives == 0, "false onsets")
    }

    /// Пауза в том же треке (`StreamAnalyzer.reset(keepOnsetFloor: true)`): типичный пик и уровень акцента
    /// остаются, и тихие доли снова дают онсеты сразу после сброса. Обычный сброс возвращает порог к 10, и
    /// онсетов нет, пока средние снова не опустят его (около 7 с на каждой паузе).
    @Test(arguments: [true, false])
    func softKicksAfterAResetInTheSameTrack(keepFloor: Bool) async {
        let (score, references) = await runOffCooperativePool { () -> (Score, Int) in
            let scene = Drums.softKicksUnderPad(seconds: 24)
            let cut = Int(16 * Self.rate)
            let analyzer = StreamAnalyzer(sampleRate: Self.rate)
            _ = analyzer.processSignal(Array(scene.samples[..<cut]))
            analyzer.reset(keepOnsetFloor: keepFloor)
            let hops = analyzer.processSignal(Array(scene.samples[cut...]), firstSample: cut)
            let onsets = hops.compactMap(\.broadbandOnset?.time).filter { $0 < 20 - 0.05 }
            let kicks = scene.kicks.filter { $0 >= 16.1 && $0 < 20 - 0.05 }
            return (Self.score(onsets, reference: kicks, until: 24), kicks.count)
        }
        #expect(references == 7)
        if keepFloor {
            #expect(score.recall >= 0.85 && score.falsePositives == 0, "recall \(score.recall), false \(score.falsePositives)")
        } else {
            #expect(score.recall <= 0.25, "recall \(score.recall)")
        }
    }

    /// Звук под воротом уровня (-80 dBFS, хвост затухания, шипение между треками) не опускает
    /// порог: после него шум -45 dBFS не дает широкополосных онсетов, кроме самого скачка уровня
    /// на 10 с (он был и с постоянным порогом). Пока типичный пик шел и по звуку под воротом, здесь
    /// был онсет шума на 11.17 с.
    @Test func noiseUnderTheLevelGateDoesNotOpenTheFloor() async {
        let onsets = await runOffCooperativePool {
            let count = Int(Self.rate * 10)
            let samples = Drums.pinkNoise(levelDB: -80, count: count, seed: 3) + Drums.pinkNoise(levelDB: -45, count: count, seed: 3)
            return Self.analyze(samples).broadband.map(\.event.time).filter { $0 >= 10.2 }
        }
        #expect(onsets.isEmpty, "broadband onsets at \(onsets)")
    }

    /// Длинная 808 легато (журнал 1 владельца): полоса бочки уже громкая, подъема на 7.5 дБ за 16 мс
    /// нет, и прежний выбор пиков видел 1 бочку из 55. Пик функции бочки на смене ноты стоит над
    /// типичным пиком полосы во много раз выше, чем у шума, а уровень поднимается из провала между
    /// нотами: после разгона типичного пика (2 с) онсет на каждой ноте, все с признаком `sustained`.
    @Test func sustained808GivesKickOnsets() async {
        let (score, kicks) = await runOffCooperativePool { () -> (Score, [OnsetEvent]) in
            let scene = Drums.sustained808()
            let kicks = Self.analyze(scene).kicks.map(\.event).filter { $0.time >= 2 }
            let notes = scene.kicks.filter { $0 >= 2 }
            return (Self.score(kicks.map(\.time), reference: notes, until: 20), kicks)
        }
        #expect(score.recall >= 0.95, "recall \(score.recall) of \(score.references)")
        #expect(score.falsePositives <= 1, "false onsets \(score.falsePositives)")
        #expect(kicks.allSatisfy { $0.sustained }, "classic onsets \(kicks.filter { !$0.sustained }.map(\.time))")
    }

    /// Онсеты длинной бочки не открываются шумом ни на каком уровне: в трех бинах бочки розовый шум
    /// дает пики не выше 3.7 типичного пика (`sustainedContrast` 6), сколько бы ни прыгал уровень.
    @Test(arguments: [Float(-10), -20, -35, -50])
    func pinkNoiseGivesNoSustainedKicks(levelDB: Float) async {
        let onsets = await runOffCooperativePool {
            (UInt64(1)...3).flatMap { seed in
                Self.analyze(Drums.pinkNoise(levelDB: levelDB, count: Int(Self.rate * 10), seed: seed)).kicks
                    .map(\.event).filter(\.sustained).map(\.time)
            }
        }
        #expect(onsets.isEmpty, "sustained kick onsets at \(onsets)")
    }

    /// Порог, опущенный по типичному пику, не открывает шум ни на каком уровне: у розового шума пики
    /// не выше 2.5 типичного пика (`peakContrast` 3.2), а его уровень от громкости почти не зависит.
    @Test(arguments: [Float(-10), -35, -50])
    func pinkNoiseAtAnyLevelGivesNoBroadbandOnsets(levelDB: Float) async {
        let onsets = await runOffCooperativePool {
            (UInt64(1)...3).flatMap { seed in
                Self.analyze(Drums.pinkNoise(levelDB: levelDB, count: Int(Self.rate * 10), seed: seed)).broadband
                    .map(\.event.time).filter { $0 >= Self.from }
            }
        }
        #expect(onsets.isEmpty, "broadband onsets at \(onsets)")
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

    /// Порог широкополосной функции 10: пик 11 (тихая доля в музыке без верхних октав) дает онсет,
    /// пик 9 (выше пиков розового шума -20 dBFS, около 8) нет.
    @Test func broadbandFloorIsTen() {
        for (peak, fires) in [(Float(11), true), (Float(9), false)] {
            var picker = OnlinePeakPicker(hopDuration: Self.hop, parameters: StreamAnalyzer.broadbandPickerParameters)
            var fired = false
            for n in 0..<100 {
                fired = picker.process(n == 80 ? peak : 0, levelDB: -20) != nil || fired
            }
            #expect(fired == fires, "peak \(peak)")
        }
    }

    /// Номера шагов с онсетом на последовательности odf (уровень -20 dBFS на каждом шаге).
    private static func fired(_ odf: [Float], parameters: OnlinePeakPicker.Parameters) -> [Int] {
        var picker = OnlinePeakPicker(hopDuration: hop, parameters: parameters)
        return odf.indices.filter { picker.process(odf[$0], levelDB: -20) != nil }
    }

    /// Пики `beat(k)` каждые `beatHops` шагов (k это номер доли) и бугры фона высотой `bump` через
    /// каждые 11 шагов между ними.
    private static func pulses(count: Int, beatHops: Int, bump: Float, beat: (Int) -> Float) -> [Float] {
        var odf = [Float](repeating: 0, count: count)
        for n in odf.indices {
            if n % beatHops == 0 {
                odf[n] = beat(n / beatHops)
            } else if n % beatHops % 11 == 0, beatHops - n % beatHops > 6 {
                odf[n] = bump
            }
        }
        return odf
    }

    /// Доли 6 на фоне бугров 1 (120 BPM, 16 с): типичный пик около 1.2, порог опускается до 4, и
    /// после разгона каждая доля дает онсет, а фон ни разу. С постоянным порогом 10 онсетов нет.
    @Test func quietBeatsAboveTheTypicalPeakFire() {
        let beatHops = 94
        let odf = Self.pulses(count: 3_000, beatHops: beatHops, bump: 1) { _ in 6 }
        let onsets = Self.fired(odf, parameters: StreamAnalyzer.broadbandPickerParameters)
        let late = onsets.filter { $0 >= 1_500 }
        #expect(late.allSatisfy { $0 % beatHops == 0 }, "onsets off the beats \(late.filter { $0 % beatHops != 0 })")
        #expect(late.count == (1_500..<3_000).count(where: { $0 % beatHops == 0 }), "onsets \(late.count)")
        #expect(onsets.allSatisfy { $0 % beatHops == 0 }, "onsets on bumps \(onsets)")
    }

    /// Пики 8 среди бугров 3.5 (каждый пятый пик): отрыв от типичного пика около 2, как у шума, и
    /// порог остается 10.
    @Test func noiseLikeContrastKeepsTheFloor() {
        let odf = Self.pulses(count: 3_000, beatHops: 55, bump: 3.5) { _ in 8 }
        #expect(Self.fired(odf, parameters: StreamAnalyzer.broadbandPickerParameters).isEmpty)
    }

    /// Уровень акцента держит порог после громких долей: доли 9.5 первые 12 с, затем 4.5. Первые 2 с
    /// тихих долей порог не ниже 0.6 × 9.5 = 5.7, онсетов нет; за несколько секунд уровень акцента
    /// спадает, и последние 4 с онсет на каждой доле.
    @Test func accentLevelHoldsTheFloorAfterLouderBeats() {
        let beatHops = 94
        let switchBeat = 24
        let odf = Self.pulses(count: 4_500, beatHops: beatHops, bump: 1) { $0 < switchBeat ? 9.5 : 4.5 }
        let onsets = Self.fired(odf, parameters: StreamAnalyzer.broadbandPickerParameters)
        let switchHop = switchBeat * beatHops
        let twoSeconds = 375
        #expect(onsets.filter { $0 >= switchHop - 4 * beatHops && $0 < switchHop }.count == 4, "loud beats \(onsets)")
        #expect(onsets.filter { $0 >= switchHop && $0 < switchHop + twoSeconds }.isEmpty, "onsets \(onsets)")
        let tailStart = 4_500 - 2 * twoSeconds
        let tail = onsets.filter { $0 >= tailStart }
        #expect(tail.count == (tailStart..<4_500).count(where: { $0 % beatHops == 0 }), "tail onsets \(tail)")
    }

    /// Доли 6 на буграх 1 под воротом уровня (-80 dBFS при `minLevelDB` -60) не трогают типичный пик
    /// и уровень акцента: потом одиночный пик 7 на -20 dBFS не дает онсета, порог остается 10. Та же
    /// история над воротом опускает порог до 4.
    @Test func peaksUnderTheLevelGateKeepTheFloor() {
        var picker = OnlinePeakPicker(hopDuration: Self.hop, parameters: StreamAnalyzer.broadbandPickerParameters)
        let quiet = Self.pulses(count: 3_000, beatHops: 94, bump: 1) { _ in 6 }
        for odf in quiet {
            _ = picker.process(odf, levelDB: -80)
        }
        var fired = false
        for n in 0..<200 {
            fired = picker.process(n == 100 ? 7 : 0, levelDB: -20) != nil || fired
        }
        #expect(!fired)
    }

    /// `reset()` возвращает типичный пик и уровень акцента к началу: после истории, где порог
    /// опустился до 4, одиночный пик 9 в нулях не дает онсета, как у нового выбора пиков.
    @Test func resetRestoresTheFloor() {
        var picker = OnlinePeakPicker(hopDuration: Self.hop, parameters: StreamAnalyzer.broadbandPickerParameters)
        let opened = Self.pulses(count: 3_000, beatHops: 94, bump: 1) { _ in 6 }
        let before = opened.indices.filter { picker.process(opened[$0], levelDB: -20) != nil }
        #expect(before.contains { $0 >= 1_500 }, "the floor never opened")
        picker.reset()
        var fired = false
        for n in 0..<100 {
            fired = picker.process(n == 80 ? 9 : 0, levelDB: -20) != nil || fired
        }
        #expect(!fired)
    }

    /// Функция бочки на длинной 808: бугры 0.05 через каждые 11 шагов, на нотах (каждые 94 шага) пик
    /// 0.8 при уровне -10 dBFS, за 5-8 шагов до пика провал до -25 dBFS, за 1-3 шага -12. Подъем за
    /// 16 мс 2 дБ, пик ниже порога 2: обычный онсет не проходит. Пик стоит над типичным пиком (около
    /// 0.1) больше чем в 6 раз, а уровень над минимумом за 150 мс на 15 дБ: после разгона онсет на
    /// каждой ноте с `lastOnsetSustained` (выходит через `lastOnsetDelay` шагов), на буграх нет.
    /// Обычный удар после этого остается обычным и без задержки.
    @Test func sustainedPeaksOverAQuietTypicalPeakFire() {
        var picker = OnlinePeakPicker(hopDuration: Self.hop, parameters: StreamAnalyzer.kickPickerParameters)
        let noteHops = 94
        var sustained: [Int] = []
        var classic: [Int] = []
        for n in 0..<3_000 {
            let phase = n % noteHops
            let odf: Float = phase == 0 ? 0.8 : (phase % 11 == 0 && noteHops - phase > 8 ? 0.05 : 0)
            let level: Float = switch noteHops - phase {
            case 5...8: -25
            case 1...3: -12
            default: -10
            }
            if picker.process(odf, levelDB: level) != nil {
                let hop = n - picker.lastOnsetDelay
                if picker.lastOnsetSustained { sustained.append(hop) } else { classic.append(hop) }
            }
        }
        let late = sustained.filter { $0 >= 1_500 }
        #expect(sustained.allSatisfy { $0 % noteHops == 0 }, "onsets off the notes \(sustained.filter { $0 % noteHops != 0 })")
        #expect(late.count == (1_500..<3_000).count(where: { $0 % noteHops == 0 }), "late onsets \(late.count)")
        #expect(classic.isEmpty, "classic onsets \(classic)")
        for n in 0..<100 {
            if picker.process(n == 50 ? 3 : 0, levelDB: n >= 50 ? -2 : -30) != nil {
                #expect(n == 50 && !picker.lastOnsetSustained && picker.lastOnsetDelay == 0)
            }
        }
    }

    /// Пики 3.5 над буграми 1 (как у шума в трех бинах бочки, отрыв около 3) с тем же провалом уровня
    /// перед пиком: когда типичный пик разогнался (после 2 с), ни обычных онсетов (подъема за 16 мс
    /// нет), ни онсетов длинной бочки. В первую секунду порог длинной бочки начинается с порога 2
    /// обычного онсета, и пики 3.5 там еще проходят.
    @Test func noiseLikeKickPeaksStayQuiet() {
        var picker = OnlinePeakPicker(hopDuration: Self.hop, parameters: StreamAnalyzer.kickPickerParameters)
        var fired: [Int] = []
        for n in 0..<3_000 {
            let phase = n % 55
            let odf: Float = phase == 0 ? 3.5 : (phase % 11 == 0 ? 1 : 0)
            let level: Float = (55 - phase >= 5 && 55 - phase <= 8) ? -25 : -10
            if picker.process(odf, levelDB: level) != nil, n >= 375 { fired.append(n) }
        }
        #expect(fired.isEmpty, "onsets \(fired)")
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
