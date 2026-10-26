import Foundation
import Testing
@testable import WaveCore

/// Перенос real-time PLP без сцен: сверка с прямыми формулами исходника (`realtimeplp.py`), идет на
/// всех платформах.
struct PLPTrackerPartsTests {
    /// Активации со случайными всплесками, как у функции онсетов: в основном нули.
    private static func spikes(count: Int, seed: UInt64, density: Float = 0.1) -> [Float] {
        var rng = TestRNG(seed: seed)
        return (0..<count).map { _ in
            let u = rng.nextUnit()
            return u > 1 - 2 * density ? abs(rng.nextUnit()) * 10 : 0
        }
    }

    /// Окно Ханна `np.hanning(n)`.
    private static func hanning(_ n: Int) -> [Double] {
        (0..<n).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n - 1)) }
    }

    /// Скользящая темпограмма равна прямой сумме `Tempogram.process` по прошлой половине окна
    /// (будущая половина нули) после тысяч шагов.
    @Test func tempogramMatchesTheDirectSum() throws {
        var plp = PLPTracker(framesPerSecond: 50, minBPM: 60, maxBPM: 180, window: 4)
        let odf = Self.spikes(count: 3000, seed: 3)
        for value in odf {
            plp.process(odf: value)
        }
        let history = plp.recentActivations()
        let n = plp.windowLength
        #expect(history.count == n / 2)
        let window = Self.hanning(n)
        for index in [0, 17, 60, 120] {
            let omega = (60 + Double(index)) / 60 / 50
            var re = 0.0
            var im = 0.0
            for (m, value) in history.enumerated() {
                let angle = -2 * Double.pi * omega * Double(m)
                re += value * window[m] * cos(angle)
                im += value * window[m] * sin(angle)
            }
            let sliding = plp.tempogram(index)
            let scale = max(abs(re) + abs(im), 1)
            #expect(abs(sliding.re - re) / scale < 1e-9, "tempo \(60 + index): re \(sliding.re) vs \(re)")
            #expect(abs(sliding.im - im) / scale < 1e-9, "tempo \(60 + index): im \(sliding.im) vs \(im)")
        }
    }

    /// Буфер пульса: действительная часть комплексного буфера равна буферу исходника, где на каждом
    /// шаге буфер сдвигается и к нему прибавляется ядро `w(t) cos(2π(ωt − φ))` лучшего темпа
    /// (`PredominantLocalPulse.process`). Исходник читает в `N / 2` (следующий кадр), здесь читается
    /// последний кадр `N / 2 − 1`; уверенность это модуль, деленный на сумму окна от этого места.
    @Test func pulseMatchesTheReferenceOverlapAdd() {
        let fps = 40.0
        var plp = PLPTracker(framesPerSecond: fps, minBPM: 60, maxBPM: 180, window: 3)
        let n = plp.windowLength
        let half = n / 2
        let window = Self.hanning(n)
        let tempi = (60...180).map(Double.init)
        let localAverage = PLPTracker.localAverageFrames(framesPerSecond: fps)
        var raw = [Double](repeating: 0, count: localAverage)
        var tempoBuffer = [Double](repeating: 0, count: n)
        var pulse = [Double](repeating: 0, count: n)
        let odf = Self.spikes(count: 600, seed: 11, density: 0.3)
        var worst = 0.0
        var worstConfidence = 0.0
        var frameIndex = 0
        var compared = 0
        for value in odf {
            plp.process(odf: value)
            // BeatActivation.local_average и normalization.
            raw.removeFirst()
            raw.append(Double(value))
            let activation = max(Double(value) - raw.reduce(0, +) / Double(localAverage), 0)
            // Tempogram.half_window_method и process.
            var past = Array(tempoBuffer[0..<half])
            past.removeFirst()
            past.append(activation)
            tempoBuffer.replaceSubrange(0..<half, with: past)
            var best = -1.0
            var bestCoefficient = (re: 0.0, im: 0.0)
            var bestOmega = 0.0
            for tempo in tempi {
                let omega = tempo / 60 / fps
                var re = 0.0
                var im = 0.0
                for m in 0..<n {
                    let angle = -2 * Double.pi * omega * Double(m)
                    re += tempoBuffer[m] * window[m] * cos(angle)
                    im += tempoBuffer[m] * window[m] * sin(angle)
                }
                let magnitude = (re * re + im * im).squareRoot()
                if magnitude > best {
                    best = magnitude
                    bestCoefficient = (re, im)
                    bestOmega = omega
                }
            }
            // PredominantLocalPulse.process: сдвиг буфера и ядро.
            pulse.removeFirst()
            pulse.append(0)
            if best > 0 {
                let phase = -atan2(bestCoefficient.im, bestCoefficient.re) / (2 * Double.pi)
                for t in 0..<n {
                    pulse[t] += window[t] * cos(2 * Double.pi * (Double(t) * bestOmega - phase))
                }
            }
            let reference = pulse[half - 1]
            frameIndex += 1
            // Пока в окне один всплеск, все темпы равны и argmax решает округление: такие ядра
            // уходят из буфера через `N / 2 + 1` кадров.
            guard frameIndex > 2 * half else { continue }
            worst = max(worst, abs(plp.pulseValue.re - reference))
            // Уверенность не меньше нормированной действительной части (модуль против проекции).
            let normalization = window[(half - 1)...].reduce(0, +)
            compared += 1
            worstConfidence = max(worstConfidence, abs(reference) / normalization - Double(plp.confidence))
        }
        #expect(compared > 400)
        #expect(worst < 1e-6, "largest difference from the reference pulse \(worst)")
        #expect(worstConfidence < 1e-5, "confidence below the normalized reference \(worstConfidence)")
    }

    @Test func silenceGivesNoPulse() {
        var plp = PLPTracker(framesPerSecond: 187.5)
        for _ in 0..<2000 {
            plp.process(odf: 0)
        }
        #expect(plp.period == nil)
        #expect(plp.confidence == 0)
        #expect(plp.phase == 0)
    }

    @Test func nonFiniteInputCountsAsZero() {
        var plp = PLPTracker(framesPerSecond: 187.5)
        for value in [Float.nan, .infinity, -.infinity, -5] {
            plp.process(odf: value)
        }
        #expect(plp.period == nil)
        #expect(plp.confidence == 0)
    }

    /// Сброс возвращает начальное состояние: тот же вход дает тот же выход.
    @Test func resetStartsOver() {
        let odf = Self.spikes(count: 1500, seed: 5)
        var fresh = PLPTracker(framesPerSecond: 100)
        var reused = PLPTracker(framesPerSecond: 100)
        for value in Self.spikes(count: 700, seed: 9) {
            reused.process(odf: value)
        }
        reused.reset()
        for value in odf {
            fresh.process(odf: value)
            reused.process(odf: value)
            #expect(fresh.phase == reused.phase)
            #expect(fresh.confidence == reused.confidence)
            #expect(fresh.period == reused.period)
        }
    }
}

/// PLP на синтетических сценах через `StreamAnalyzer` (только Linux, как остальные сцены).
@Suite(.enabled(if: TestPlatform.isLinux))
struct PLPTrackerTests {
    private static let fps = AnalysisConfig(sampleRate: 48_000).framesPerSecond

    /// Широкополосная функция онсетов сигнала и ось онсетов шагов (`endTime − onsetLag`).
    private static func odf(_ samples: [Float]) -> [(time: Double, odf: Float)] {
        StreamAnalyzer(sampleRate: 48_000).processSignal(samples).map { ($0.endTime - StreamAnalyzer.onsetLag, $0.broadbandODF) }
    }

    /// Расстояние от доли PLP (фаза 0 на оси онсетов) до ближайшей доли сетки, секунды.
    private static func phaseError(time: Double, plp: PLPTracker, beats: [Double]) -> Double? {
        guard let period = plp.period else { return nil }
        let beat = time - plp.phase * period
        return beats.map { abs(BeatTracker.circularDifference(beat - $0, period: period)) }.min()
    }

    @Test func plpLocksOnSteadyClick() async {
        let click = TestSignals.clickTrack(bpm: 120, sampleRate: 48_000, seconds: 10)
        let frames = await runOffCooperativePool { Self.odf(click.samples) }
        var plp = PLPTracker(framesPerSecond: Self.fps)
        var worstPhase = 0.0
        var worstPeriod = 0.0
        var lowestConfidence: Float = 1
        for frame in frames {
            plp.process(odf: frame.odf)
            guard frame.time >= 6 else { continue }
            let period = plp.period ?? 0
            worstPeriod = max(worstPeriod, abs(period - 0.5) / 0.5)
            worstPhase = max(worstPhase, Self.phaseError(time: frame.time, plp: plp, beats: click.beatTimes) ?? 1)
            lowestConfidence = min(lowestConfidence, plp.confidence)
        }
        #expect(worstPeriod <= 0.01, "period off by \(worstPeriod)")
        #expect(worstPhase <= 0.030, "beat phase off by \(worstPhase) s")
        #expect(lowestConfidence > 0.7, "confidence fell to \(lowestConfidence)")
    }

    /// Розовый шум без долей: средняя уверенность после 3 с ниже 0.3 (в среднем 0.24-0.27), и она ни
    /// разу не доходит до уровня, с которого PLP предлагает фазу трекеру (`plpShadow`; пики 0.51-0.67).
    @Test(arguments: [UInt64(1), 2, 3])
    func plpConfidenceDropsOnNoise(seed: UInt64) async {
        let scene = Drums.noiseOnly(seed: seed)
        let frames = await runOffCooperativePool { Self.odf(scene.samples) }
        var plp = PLPTracker(framesPerSecond: Self.fps)
        var highest: Float = 0
        var sum = 0.0
        var count = 0
        for frame in frames {
            plp.process(odf: frame.odf)
            guard frame.time >= 3 else { continue }
            highest = max(highest, plp.confidence)
            sum += Double(plp.confidence)
            count += 1
        }
        let mean = sum / Double(max(count, 1))
        #expect(mean < 0.3, "mean confidence in noise \(mean)")
        #expect(Double(highest) < BeatTracker.Parameters().plpShadow, "confidence in noise rose to \(highest)")
    }

    /// Скачок 100 -> 110 BPM на 12 с (бочка и хэт на каждой доле): через 3 с период уже новый и дальше
    /// не уходит. С хэтом восьмыми частота хэта (200 BPM) выше диапазона, и ее утечка ставит максимум
    /// темпограммы на край 180 BPM; это свойство алгоритма (так же в исходнике), поэтому сцена без «и».
    @Test func plpFollowsTempoChange() async {
        let scene = Drums.tempoJump(from: 100, to: 110, at: 12, seconds: 20, hats: .quarters)
        let frames = await runOffCooperativePool { Self.odf(scene.samples) }
        var plp = PLPTracker(framesPerSecond: Self.fps)
        var worstBefore = 0.0
        var worstAfter = 0.0
        for frame in frames {
            plp.process(odf: frame.odf)
            let period = plp.period ?? 0
            if frame.time >= 8, frame.time < 12 { worstBefore = max(worstBefore, abs(period - 0.6) / 0.6) }
            if frame.time >= 15 { worstAfter = max(worstAfter, abs(period - 60.0 / 110) / (60.0 / 110)) }
        }
        #expect(worstBefore <= 0.01, "period before the jump off by \(worstBefore)")
        #expect(worstAfter <= 0.01, "period 3 s after the jump off by \(worstAfter)")
    }
}
