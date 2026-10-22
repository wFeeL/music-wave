import Foundation
@testable import WaveCore

/// Синтетическая сцена и правда о ней: моменты в секундах от первого сэмпла.
struct DrumScene: Sendable {
    var samples: [Float]
    var sampleRate: Double
    /// Сетка долей (четверти).
    var beats: [Double]
    var kicks: [Double]
    var snares: [Double]
    var hats: [Double]
}

/// Синтетические барабаны для проверки онсетов, темпа и фазы (`beat-sync.md` 3.1). Шум берется из
/// `TestRNG`, поэтому одна и та же сцена с тем же `seed` всегда одинакова.
///
/// Уровни: бочка 0.8 в пике, малый 0.4 шум + 0.3 тон, хэт 0.12 от разности соседних сэмплов шума,
/// бас 0.35, пэд 3 × 0.05. `levelDB` сцены умножает все сразу.
enum Drums {
    enum HatPattern: Sendable {
        case none, quarters, eighths
    }

    // MARK: Инструменты

    /// Бочка 808: синус 120 → 50 Гц (τ высоты 30 мс), амплитуда спадает с τ 180 мс.
    static func kick808(into samples: inout [Float], at time: Double, gain: Float = 1, sampleRate: Double) {
        add(into: &samples, at: time, length: 1.2, sampleRate: sampleRate) { t in
            let phase = 2 * Double.pi * (50 * t + 70 * 0.030 * (1 - exp(-t / 0.030)))
            return 0.8 * gain * Float(exp(-t / 0.180) * sin(phase))
        }
    }

    /// Акустическая бочка: та же развертка высоты, амплитуда спадает с τ 60 мс, плюс щелчок 2 кГц.
    static func acousticKick(into samples: inout [Float], at time: Double, gain: Float = 1, sampleRate: Double) {
        add(into: &samples, at: time, length: 0.4, sampleRate: sampleRate) { t in
            let phase = 2 * Double.pi * (50 * t + 70 * 0.030 * (1 - exp(-t / 0.030)))
            let body = 0.8 * exp(-t / 0.060) * sin(phase)
            let click = 0.25 * exp(-t / 0.004) * sin(2 * Double.pi * 2000 * t)
            return gain * Float(body + click)
        }
    }

    /// Малый барабан: всплеск белого шума с τ 60 мс и тон 180 Гц.
    static func snare(
        into samples: inout [Float], at time: Double, gain: Float = 1, sampleRate: Double, rng: inout TestRNG
    ) {
        add(into: &samples, at: time, length: 0.4, sampleRate: sampleRate) { t in
            let envelope = Float(exp(-t / 0.060))
            let tone = Float(0.3 * sin(2 * Double.pi * 180 * t))
            return gain * envelope * (0.4 * rng.nextUnit() + tone)
        }
    }

    /// Закрытый хэт: шум, пропущенный через первую разность (простой фильтр верхних частот), τ 12 мс.
    static func closedHat(
        into samples: inout [Float], at time: Double, gain: Float = 1, sampleRate: Double, rng: inout TestRNG
    ) {
        var previous = rng.nextUnit()
        add(into: &samples, at: time, length: 0.1, sampleRate: sampleRate) { t in
            let current = rng.nextUnit()
            defer { previous = current }
            return gain * 0.12 * Float(exp(-t / 0.012)) * (current - previous)
        }
    }

    /// Нота баса 55 Гц: атака 20 мс, держится `duration` секунд, затем спадает с τ 15 мс.
    static func bassNote(
        into samples: inout [Float], at time: Double, duration: Double, gain: Float = 1, sampleRate: Double
    ) {
        add(into: &samples, at: time, length: duration + 0.1, sampleRate: sampleRate) { t in
            let envelope = t < duration ? min(t / 0.020, 1) : exp(-(t - duration) / 0.015)
            return 0.35 * gain * Float(envelope * sin(2 * Double.pi * 55 * t))
        }
    }

    /// Пэд: аккорд 220, 277.18 и 329.63 Гц по 0.05, нарастает и затухает за 0.2 с по краям отрезка.
    static func pad(into samples: inout [Float], from start: Double, to end: Double, gain: Float = 1, sampleRate: Double) {
        let length = end - start
        guard length > 0 else { return }
        add(into: &samples, at: start, length: length, sampleRate: sampleRate) { t in
            let fade = min(t / 0.2, (length - t) / 0.2, 1)
            var sum = 0.0
            for frequency in [220.0, 277.18, 329.63] {
                sum += sin(2 * Double.pi * frequency * t)
            }
            return gain * Float(0.05 * fade * sum)
        }
    }

    /// Розовый шум (фильтр Пола Келлета) со среднеквадратичным уровнем `levelDB` dBFS.
    static func pinkNoise(levelDB: Float, count: Int, seed: UInt64) -> [Float] {
        var rng = TestRNG(seed: seed)
        var b = [Double](repeating: 0, count: 7)
        var samples = [Float](repeating: 0, count: count)
        var sumSquares = 0.0
        for i in 0..<count {
            let white = Double(rng.nextUnit())
            b[0] = 0.99886 * b[0] + white * 0.0555179
            b[1] = 0.99332 * b[1] + white * 0.0750759
            b[2] = 0.96900 * b[2] + white * 0.1538520
            b[3] = 0.86650 * b[3] + white * 0.3104856
            b[4] = 0.55000 * b[4] + white * 0.5329522
            b[5] = -0.7616 * b[5] - white * 0.0168980
            let value = b[0] + b[1] + b[2] + b[3] + b[4] + b[5] + b[6] + white * 0.5362
            b[6] = white * 0.115926
            samples[i] = Float(value)
            sumSquares += value * value
        }
        let rms = count > 0 ? (sumSquares / Double(count)).squareRoot() : 0
        guard rms > 0 else { return samples }
        let scale = Float(pow(10, Double(levelDB) / 20) / rms)
        return samples.map { $0 * scale }
    }

    // MARK: Сцены

    /// Бочка на каждую долю. `swing` это место второй восьмой хэта в доле (0.5 ровно, 0.66 свинг).
    /// `humanizeSigma` сдвигает каждую бочку на нормальную случайную величину с этим σ.
    /// `offbeatBass` ставит ноту баса на каждую слабую восьмую длиной 0.4 доли.
    static func fourOnFloor(
        bpm: Double = 120,
        seconds: Double = 24,
        sampleRate: Double = 48_000,
        hats: HatPattern = .none,
        swing: Double = 0.5,
        humanizeSigma: Double = 0,
        offbeatBass: Bool = false,
        snareOnBackbeat: Bool = false,
        levelDB: Float = 0,
        seed: UInt64 = 1
    ) -> DrumScene {
        var spec = Spec(seconds: seconds, sampleRate: sampleRate, bpm: { _ in bpm }, seed: seed)
        spec.gain = gain(levelDB)
        spec.humanizeSigma = humanizeSigma
        spec.pattern = { beat in
            var events: [Event] = [.kick(0)]
            switch hats {
            case .none: break
            case .quarters: events.append(.hat(0))
            case .eighths: events += [.hat(0), .hat(swing)]
            }
            if snareOnBackbeat, beat % 2 == 1 { events.append(.snare(0)) }
            if offbeatBass { events.append(.bass(0.5, length: 0.4)) }
            return events
        }
        return render(spec)
    }

    /// Хип-хоп 90: бочка на 1, 1.75 и 3.5 (счет с 1), малый на 2 и 4, хэт восьмыми.
    static func hipHop90(seconds: Double = 24, sampleRate: Double = 48_000, seed: UInt64 = 1) -> DrumScene {
        var spec = Spec(seconds: seconds, sampleRate: sampleRate, bpm: { _ in 90 }, seed: seed)
        spec.pattern = { beat in
            var events: [Event] = [.hat(0), .hat(0.5)]
            switch beat % 4 {
            case 0: events += [.kick(0), .kick(0.75)]
            case 1, 3: events.append(.snare(0))
            default: events.append(.kick(0.5))
            }
            return events
        }
        return render(spec)
    }

    /// Драм-н-бейс 174: только акустическая бочка на 1 и на «и» третьей доли, без хэтов и малого
    /// (как в прототипе, `beat-sync.md` 2.9).
    static func dnb174(seconds: Double = 24, sampleRate: Double = 48_000, seed: UInt64 = 1) -> DrumScene {
        var spec = Spec(seconds: seconds, sampleRate: sampleRate, bpm: { _ in 174 }, seed: seed)
        spec.acousticKick = true
        spec.pattern = { beat in
            switch beat % 4 {
            case 0: [.kick(0)]
            case 2: [.kick(0.5)]
            default: []
            }
        }
        return render(spec)
    }

    /// Бочка на каждую долю и хэт восьмыми, темп линейно меняется от `from` до `to` за всю сцену.
    static func tempoRamp(
        from: Double = 120, to: Double = 130, seconds: Double = 20, sampleRate: Double = 48_000, seed: UInt64 = 1
    ) -> DrumScene {
        var spec = Spec(
            seconds: seconds, sampleRate: sampleRate, bpm: { from + (to - from) * min(max($0 / seconds, 0), 1) }, seed: seed
        )
        spec.pattern = { _ in [.kick(0), .hat(0), .hat(0.5)] }
        return render(spec)
    }

    /// Бочка на каждую долю и хэт восьмыми, темп скачком меняется с `from` на `to` в момент `at`.
    static func tempoJump(
        from: Double = 100, to: Double = 140, at: Double = 12, seconds: Double = 24, sampleRate: Double = 48_000,
        seed: UInt64 = 1
    ) -> DrumScene {
        var spec = Spec(seconds: seconds, sampleRate: sampleRate, bpm: { $0 < at ? from : to }, seed: seed)
        spec.pattern = { _ in [.kick(0), .hat(0), .hat(0.5)] }
        return render(spec)
    }

    /// Тихое вступление: `introSeconds` только пэд на `introDB`, затем полный микс (бочка на каждую
    /// долю, хэт восьмыми, бас на слабых восьмых, пэд). Сетка долей начинается со вступления барабанов.
    static func quietIntro(
        introSeconds: Double = 8, introDB: Float = -40, bpm: Double = 120, seconds: Double = 24,
        sampleRate: Double = 48_000, seed: UInt64 = 1
    ) -> DrumScene {
        var spec = Spec(seconds: seconds, sampleRate: sampleRate, bpm: { _ in bpm }, seed: seed)
        spec.gridStart = introSeconds
        spec.pads = [(0, introSeconds, gain(introDB)), (introSeconds, seconds, 1)]
        spec.pattern = { _ in [.kick(0), .hat(0), .hat(0.5), .bass(0.5, length: 0.4)] }
        return render(spec)
    }

    /// Брейкдаун: бочка на каждую долю, хэт восьмыми и бас на слабых восьмых, которые молчат с `at`
    /// в течение `length` секунд. Пэд звучит всю сцену. Сетка долей идет без перерыва.
    static func breakdown(
        at: Double = 10, length: Double = 8, bpm: Double = 120, seconds: Double = 24, sampleRate: Double = 48_000,
        seed: UInt64 = 1
    ) -> DrumScene {
        var spec = Spec(seconds: seconds, sampleRate: sampleRate, bpm: { _ in bpm }, seed: seed)
        spec.silent = at..<(at + length)
        spec.pads = [(0, seconds, 1)]
        spec.pattern = { _ in [.kick(0), .hat(0), .hat(0.5), .bass(0.5, length: 0.4)] }
        return render(spec)
    }

    /// Только розовый шум на `levelDB` dBFS, без долей.
    static func noiseOnly(
        levelDB: Float = -20, seconds: Double = 12, sampleRate: Double = 48_000, seed: UInt64 = 1
    ) -> DrumScene {
        DrumScene(
            samples: pinkNoise(levelDB: levelDB, count: Int(seconds * sampleRate), seed: seed),
            sampleRate: sampleRate, beats: [], kicks: [], snares: [], hats: []
        )
    }

    // MARK: Сборка

    private enum Event {
        /// Смещения в долях от начала доли.
        case kick(Double), snare(Double), hat(Double), bass(Double, length: Double)
    }

    private struct Spec {
        var seconds: Double
        var sampleRate: Double
        /// Темп в момент `t` секунд.
        var bpm: (Double) -> Double
        var seed: UInt64
        var gain: Float = 1
        var humanizeSigma = 0.0
        var acousticKick = false
        var gridStart = 0.0
        /// Отрезок, где барабаны и бас молчат.
        var silent: Range<Double>?
        var pads: [(start: Double, end: Double, gain: Float)] = []
        /// События доли по ее номеру от начала сетки.
        var pattern: (Int) -> [Event] = { _ in [] }
    }

    private static func gain(_ db: Float) -> Float {
        Float(pow(10, Double(db) / 20))
    }

    private static func render(_ spec: Spec) -> DrumScene {
        let rate = spec.sampleRate
        let count = Int(spec.seconds * rate)
        var samples = [Float](repeating: 0, count: count)
        var rng = TestRNG(seed: spec.seed)

        // Сетка с запасом в две доли за концом сцены, чтобы смещения внутри последней доли считались.
        var grid = [spec.gridStart]
        while let last = grid.last, last <= spec.seconds + 1 {
            grid.append(last + 60 / spec.bpm(last))
        }
        func time(beat: Int, offset: Double) -> Double {
            grid[beat] + offset * (grid[beat + 1] - grid[beat])
        }
        // Моменты округляются до сэмпла, правда совпадает с началом звука точно.
        func snapped(_ t: Double) -> Double {
            (t * rate).rounded() / rate
        }
        func audible(_ t: Double) -> Bool {
            t >= 0 && t < spec.seconds && !(spec.silent?.contains(t) ?? false)
        }

        var kicks: [Double] = []
        var snares: [Double] = []
        var hats: [Double] = []
        for beat in 0..<(grid.count - 1) where grid[beat] < spec.seconds {
            for event in spec.pattern(beat) {
                switch event {
                case .kick(let offset):
                    var t = time(beat: beat, offset: offset)
                    if spec.humanizeSigma > 0 { t += spec.humanizeSigma * rng.nextGaussian() }
                    t = snapped(t)
                    guard audible(t) else { continue }
                    kicks.append(t)
                    if spec.acousticKick {
                        acousticKick(into: &samples, at: t, gain: spec.gain, sampleRate: rate)
                    } else {
                        kick808(into: &samples, at: t, gain: spec.gain, sampleRate: rate)
                    }
                case .snare(let offset):
                    let t = snapped(time(beat: beat, offset: offset))
                    guard audible(t) else { continue }
                    snares.append(t)
                    snare(into: &samples, at: t, gain: spec.gain, sampleRate: rate, rng: &rng)
                case .hat(let offset):
                    let t = snapped(time(beat: beat, offset: offset))
                    guard audible(t) else { continue }
                    hats.append(t)
                    closedHat(into: &samples, at: t, gain: spec.gain, sampleRate: rate, rng: &rng)
                case .bass(let offset, let length):
                    let t = snapped(time(beat: beat, offset: offset))
                    guard audible(t) else { continue }
                    let duration = length * (grid[beat + 1] - grid[beat])
                    bassNote(into: &samples, at: t, duration: duration, gain: spec.gain, sampleRate: rate)
                }
            }
        }
        for pad in spec.pads {
            Self.pad(into: &samples, from: pad.start, to: min(pad.end, spec.seconds), gain: spec.gain * pad.gain, sampleRate: rate)
        }

        return DrumScene(
            samples: samples,
            sampleRate: rate,
            beats: grid.filter { $0 < spec.seconds },
            kicks: kicks.sorted(),
            snares: snares.sorted(),
            hats: hats.sorted()
        )
    }

    /// Прибавляет голос `voice(t)` (t в секундах от начала звука) к сэмплам с момента `time`.
    private static func add(
        into samples: inout [Float], at time: Double, length: Double, sampleRate: Double, _ voice: (Double) -> Float
    ) {
        let start = Int((time * sampleRate).rounded())
        let end = min(samples.count, start + Int(length * sampleRate))
        guard start < end else { return }
        for index in max(start, 0)..<end {
            samples[index] += voice(Double(index - start) / sampleRate)
        }
    }
}

extension TestRNG {
    /// Нормальная случайная величина (Бокс-Мюллер).
    mutating func nextGaussian() -> Double {
        let u1 = (Double(next() >> 11) + 0.5) / Double(1 << 53)
        let u2 = (Double(next() >> 11) + 0.5) / Double(1 << 53)
        return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
    }
}

extension StreamAnalyzer {
    /// Прогоняет сигнал шаг за шагом: окно `fftSize` сэмплов, конец окна сдвигается на `hopSize`.
    /// `samples[0]` это сэмпл потока номер `firstSample`.
    func processSignal(
        _ samples: [Float], firstSample: Int = 0, settings: LevelSettings = LevelSettings()
    ) -> [HopResult] {
        let size = config.fftSize
        let hop = config.hopSize
        var results: [HopResult] = []
        results.reserveCapacity(max(samples.count - size, 0) / hop + 1)
        samples.withUnsafeBufferPointer { all in
            var end = size
            while end <= all.count {
                let window = UnsafeBufferPointer(rebasing: all[(end - size)..<end])
                results.append(processHop(window: window, endSample: firstSample + end, settings: settings))
                end += hop
            }
        }
        return results
    }
}
