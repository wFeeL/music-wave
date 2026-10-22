import Foundation
import Testing
@testable import WaveCore

struct WaveShapeTests {
    private static let wingWeights: [Double] = [1.6, 2.8, 4.4]
    private static let panelWeights: [Double] = [0.85, 1.6, 3.0]

    /// Фаза как в 0.9.0, где гармоника шла от `1.7 * phase`: старые проверки формы не меняются.
    private func legacyPhase(_ p: Double) -> WavePhase {
        WavePhase(carrier: p, harmonic: 1.7 * p)
    }

    @Test func waveIsZeroAtEdges() {
        for profile in WaveProfile.allCases {
            for layer in WaveLayer.allCases {
                for phase in stride(from: 0.0, to: 2 * Double.pi, by: 0.37) {
                    let y = WaveShape.samples(layer: layer, amplitude: 1, phase: legacyPhase(phase), count: 128, profile: profile)
                    #expect(y.count == 128)
                    // Крыло: ноль у выреза и у края; панель: ноль у обоих краев.
                    #expect(abs(y[0]) <= 1e-6)
                    #expect(abs(y[127]) <= 1e-6)
                    #expect(y.allSatisfy { $0.isFinite })
                }
            }
        }
    }

    @Test func waveStaysInRange() {
        for profile in WaveProfile.allCases {
            for layer in WaveLayer.allCases {
                for i in 0..<200 {
                    let phase = Double(i) / 200 * 2 * Double.pi
                    let y = WaveShape.samples(layer: layer, amplitude: 1, phase: legacyPhase(phase), count: 257, profile: profile)
                    #expect(y.allSatisfy { abs($0) <= 1 })
                }
            }
        }
    }

    @Test func zeroAmplitudeIsFlat() {
        for profile in WaveProfile.allCases {
            for layer in WaveLayer.allCases {
                let y = WaveShape.samples(layer: layer, amplitude: 0, phase: legacyPhase(1.3), count: 64, profile: profile)
                #expect(y.allSatisfy { $0 == 0 })
            }
        }
    }

    /// Положение максимума огибающей (по всем фазам) в долях от начала массива.
    private func envelopePeak(_ layer: WaveLayer, profile: WaveProfile, count: Int) -> [Float] {
        var peak = [Float](repeating: 0, count: count)
        for i in 0..<200 {
            let phase = Double(i) / 200 * 2 * Double.pi
            let y = WaveShape.samples(layer: layer, amplitude: 1, phase: legacyPhase(phase), count: count, profile: profile)
            for j in 0..<count { peak[j] = max(peak[j], abs(y[j])) }
        }
        return peak
    }

    @Test func envelopePeaksWhereSpecified() {
        let count = 401
        func argmax(_ layer: WaveLayer) -> Double {
            let peak = envelopePeak(layer, profile: .wing, count: count)
            let best = peak.indices.max { peak[$0] < peak[$1] }!
            return Double(best) / Double(count - 1)
        }
        let bass = argmax(.bass)
        let mid = argmax(.mid)
        let high = argmax(.high)
        // Бас у выреза, верх к краю: 0.2, 0.4, 0.6.
        #expect(abs(bass - 0.2) < 0.12, "bass \(bass)")
        #expect(abs(high - 0.6) < 0.12, "high \(high)")
        #expect(bass < mid && mid < high)
    }

    /// Сдвиг (в отсчетах) `later` относительно `earlier` на участке `range`: положительный, если
    /// волна ушла к большим индексам.
    private func bestShift(_ earlier: [Float], _ later: [Float], range: Range<Int>) -> Int {
        var best = 0
        var bestError = Float.infinity
        for shift in -30...30 {
            var error: Float = 0
            for i in range {
                let d = later[i] - earlier[i - shift]
                error += d * d
            }
            if error < bestError {
                bestError = error
                best = shift
            }
        }
        return best
    }

    @Test func crestsTravelOutward() {
        let count = 801
        for layer in WaveLayer.allCases {
            for phase in [0.4, 1.9, 3.3, 5.1] {
                // Крыло: от выреза (индекс 0) к краю.
                let wingNow = WaveShape.samples(layer: layer, amplitude: 1, phase: legacyPhase(phase), count: count, profile: .wing)
                let wingLater = WaveShape.samples(layer: layer, amplitude: 1, phase: legacyPhase(phase + 0.15), count: count, profile: .wing)
                #expect(bestShift(wingNow, wingLater, range: 160..<640) > 0, "wing \(layer) phase \(phase)")
                // Панель: правая половина вправо, левая влево.
                let panelNow = WaveShape.samples(layer: layer, amplitude: 1, phase: legacyPhase(phase), count: count, profile: .panel)
                let panelLater = WaveShape.samples(layer: layer, amplitude: 1, phase: legacyPhase(phase + 0.15), count: count, profile: .panel)
                #expect(bestShift(panelNow, panelLater, range: 480..<720) > 0, "panel right \(layer) phase \(phase)")
                #expect(bestShift(panelNow, panelLater, range: 80..<320) < 0, "panel left \(layer) phase \(phase)")
            }
        }
    }

    @Test func panelIsSymmetricWithoutCenterSeam() {
        let count = 401
        let center = count / 2
        for layer in WaveLayer.allCases {
            var centerPeak: Float = 0
            var centerSteps: Float = 0
            var nearbySteps: Float = 0
            for i in 0..<64 {
                let phase = Double(i) / 64 * 2 * Double.pi
                let y = WaveShape.samples(layer: layer, amplitude: 1, phase: legacyPhase(phase), count: count, profile: .panel)
                for j in 0..<count {
                    #expect(abs(y[j] - y[count - 1 - j]) < 1e-6)
                }
                centerPeak = max(centerPeak, abs(y[center]))
                // Шаг 0.0005 ширины: у середины линия почти не меняется (касательная
                // горизонтальна), на 0.02 от середины уже идет наклонно. У излома |x| эти шаги
                // были бы одного порядка.
                let fine = WaveShape.samples(layer: layer, amplitude: 1, phase: legacyPhase(phase), count: 4001, profile: .panel)
                centerSteps += abs(fine[2001] - fine[2000])
                nearbySteps += abs(fine[2041] - fine[2040])
            }
            #expect(centerSteps < 0.2 * nearbySteps, "\(layer): \(centerSteps) vs \(nearbySteps)")
            // В середине амплитуда не пропадает.
            #expect(centerPeak > 0.4, "\(layer): \(centerPeak)")
        }
    }

    private func circularDistance(_ a: Double, _ b: Double) -> Double {
        let twoPi = 2 * Double.pi
        let d = abs(a - b).truncatingRemainder(dividingBy: twoPi)
        return min(d, twoPi - d)
    }

    /// Шаг фазы по кругу, -π..<π.
    private func circularStep(from a: Double, to b: Double) -> Double {
        let twoPi = 2 * Double.pi
        var d = (b - a).truncatingRemainder(dividingBy: twoPi)
        if d >= Double.pi { d -= twoPi }
        if d < -Double.pi { d += twoPi }
        return d
    }

    private func isWrapped(_ phase: WavePhase) -> Bool {
        phase.carrier.isFinite && phase.harmonic.isFinite
            && phase.carrier >= 0 && phase.carrier < 2 * Double.pi
            && phase.harmonic >= 0 && phase.harmonic < 2 * Double.pi
    }

    @Test func motionDependsOnLoudness() {
        var quiet = WaveMotion()
        var loud = WaveMotion()
        let dt = 1.0 / 60
        for _ in 0..<120 {
            quiet.advance(layers: [0, 0, 0], dt: dt)
            loud.advance(layers: [1, 1, 1], dt: dt)
        }
        // Громкость сглажена за 0.4 с: на n-м кадре slow = 1 - (1 - a)^n.
        let a = 1 - exp(-dt / 0.4)
        var loudTurn = 0.0
        var slow = 0.0
        for _ in 0..<120 {
            slow += a * (1 - slow)
            loudTurn += (0.3 + 1.7 * slow) * dt
        }
        for profile in WaveProfile.allCases {
            let weights = profile == .wing ? Self.wingWeights : Self.panelWeights
            for layer in WaveLayer.allCases {
                let w = weights[layer.rawValue]
                let quietPhase = quiet.phase(layer, profile: profile)
                let loudPhase = loud.phase(layer, profile: profile)
                #expect(circularDistance(quietPhase.carrier, 0.3 * w * 2) < 1e-9)
                #expect(circularDistance(quietPhase.harmonic, 1.7 * 0.3 * w * 2) < 1e-9)
                #expect(circularDistance(loudPhase.carrier, w * loudTurn) < 1e-9)
                #expect(circularDistance(loudPhase.harmonic, 1.7 * w * loudTurn) < 1e-9)
            }
        }
    }

    @Test func phaseStaysWrapped() async {
        // 100 000 кадров это почти полчаса музыки: каждая фаза сворачивается тысячи раз.
        // Цикл идет вне общего пула, чтобы не задерживать тесты, ждущие главный поток.
        let motion = await runOffCooperativePool { () -> WaveMotion in
            var motion = WaveMotion()
            for i in 0..<100_000 {
                let level = Float(i % 7) / 6
                motion.advance(layers: [level, 1 - level, 1], dt: 1.0 / 60)
            }
            return motion
        }
        for profile in WaveProfile.allCases {
            for layer in WaveLayer.allCases {
                #expect(isWrapped(motion.phase(layer, profile: profile)))
            }
        }
    }

    @Test func motionIgnoresNonFiniteInput() {
        var motion = WaveMotion()
        motion.advance(layers: [.nan, .infinity, -.infinity], dt: .nan)
        motion.advance(layers: [.nan, .infinity, 0.5], dt: .infinity)
        motion.advance(layers: [.nan, .infinity, 0.5], dt: -1)
        motion.advance(layers: [], dt: 1)
        for profile in WaveProfile.allCases {
            for layer in WaveLayer.allCases {
                #expect(isWrapped(motion.phase(layer, profile: profile)))
                #expect(motion.slowLevel(layer).isFinite)
            }
        }
        // NaN-уровень считается тишиной, бесконечный dt шагом 0, отрицательный тоже.
        var reference = WaveMotion()
        reference.advance(layers: [0, 0, 0], dt: 1)
        motion = WaveMotion()
        motion.advance(layers: [.nan, .nan, .nan], dt: 1)
        for profile in WaveProfile.allCases {
            for layer in WaveLayer.allCases {
                #expect(motion.phase(layer, profile: profile) == reference.phase(layer, profile: profile))
            }
        }
    }

    @Test func samplesRepeatEveryFullTurn() {
        for profile in WaveProfile.allCases {
            for layer in WaveLayer.allCases {
                for (c, h) in [(0.3, 5.1), (6.28, 0.01), (3.0, 6.2)] {
                    let a = WaveShape.samples(
                        layer: layer, amplitude: 1, phase: WavePhase(carrier: c, harmonic: h), count: 128, profile: profile
                    )
                    let b = WaveShape.samples(
                        layer: layer, amplitude: 1, phase: WavePhase(carrier: c + 2 * .pi, harmonic: h + 2 * .pi),
                        count: 128, profile: profile
                    )
                    #expect(zip(a, b).allSatisfy { abs($0 - $1) < 1e-5 }, "\(profile) \(layer) \(c) \(h)")
                }
            }
        }
    }

    /// 60 Гц на полном уровне, пока каждый накопитель несущей и гармоники не перейдет через 2π
    /// трижды. Кадр сравнивается с предыдущим, сдвинутым непрерывно: несущая на свой шаг,
    /// гармоника на 1.7 этого шага. В 0.9.0 на переходе гармоника прыгала на 0.7 периода,
    /// около 0.4 в единицах панели.
    @Test func advanceAcrossWrapIsContinuous() {
        let dt = 1.0 / 60
        let count = 128
        var motion = WaveMotion()
        var wraps = [String: (carrier: Int, harmonic: Int)]()
        var worst: Float = 0
        var frames = 0
        func key(_ profile: WaveProfile, _ layer: WaveLayer) -> String { "\(profile) \(layer)" }
        while frames < 60 * 60 {
            let before = motion
            motion.advance(layers: [1, 1, 1], dt: dt)
            frames += 1
            for profile in WaveProfile.allCases {
                for layer in WaveLayer.allCases {
                    let old = before.phase(layer, profile: profile)
                    let new = motion.phase(layer, profile: profile)
                    var counted = wraps[key(profile, layer)] ?? (0, 0)
                    if new.carrier < old.carrier { counted.carrier += 1 }
                    if new.harmonic < old.harmonic { counted.harmonic += 1 }
                    wraps[key(profile, layer)] = counted
                    let step = circularStep(from: old.carrier, to: new.carrier)
                    let expected = WavePhase(carrier: old.carrier + step, harmonic: old.harmonic + 1.7 * step)
                    let a = WaveShape.samples(layer: layer, amplitude: 1, phase: expected, count: count, profile: profile)
                    let b = WaveShape.samples(layer: layer, amplitude: 1, phase: new, count: count, profile: profile)
                    for (x, y) in zip(a, b) { worst = max(worst, abs(x - y)) }
                }
            }
            if wraps.count == 6, wraps.values.allSatisfy({ $0.carrier >= 3 && $0.harmonic >= 3 }) { break }
        }
        #expect(wraps.count == 6 && wraps.values.allSatisfy { $0.carrier >= 3 && $0.harmonic >= 3 }, "\(wraps)")
        #expect(worst < 0.01, "worst jump \(worst) after \(frames) frames")
    }

    @Test func harmonicHasOwnAccumulator() {
        let dt = 1.0 / 60
        var motion = WaveMotion()
        var unwrapped = [String: Double]()
        for _ in 0..<600 {
            let before = motion
            motion.advance(layers: [1, 1, 1], dt: dt)
            for profile in WaveProfile.allCases {
                for layer in WaveLayer.allCases {
                    let step = circularStep(
                        from: before.phase(layer, profile: profile).carrier, to: motion.phase(layer, profile: profile).carrier
                    )
                    unwrapped["\(profile) \(layer)", default: 0] += step
                }
            }
        }
        for profile in WaveProfile.allCases {
            for layer in WaveLayer.allCases {
                let u = unwrapped["\(profile) \(layer)"] ?? 0
                #expect(u > 2 * Double.pi, "\(profile) \(layer) turned \(u)")
                let expected = (1.7 * u).truncatingRemainder(dividingBy: 2 * .pi)
                let harmonic = motion.phase(layer, profile: profile).harmonic
                #expect(circularDistance(harmonic, expected) < 1e-6, "\(profile) \(layer)")
            }
        }
    }

    @Test func shiftedWrapsBoth() {
        let shifted = WavePhase(carrier: 6.0, harmonic: 6.0).shifted(by: 0.6)
        #expect(abs(shifted.carrier - (0.6 + 6.0 - 2 * .pi)) < 1e-9)
        #expect(abs(shifted.harmonic - (6.0 + 1.02 - 2 * .pi)) < 1e-9)
        let back = WavePhase(carrier: 0.1, harmonic: 0.1).shifted(by: -0.6)
        #expect(isWrapped(back))
        #expect(abs(back.carrier - (0.1 - 0.6 + 2 * .pi)) < 1e-9)
        #expect(abs(back.harmonic - (0.1 - 1.02 + 2 * .pi)) < 1e-9)
    }

    @Test func panelCrestsMoveAtWingSpeedInPoints() {
        // Скорость гребня в pt/с = ω / (2π c) × длина единицы: крыло 54 pt, панель 218 pt.
        for i in 0..<3 {
            let wing = WaveMotion.wingSpeeds[i] / (2 * .pi * WaveShape.wingCarriers[i]) * 54
            let panel = WaveMotion.panelSpeeds[i] / (2 * .pi * WaveShape.panelCarriers[i]) * 218
            #expect(panel / wing > 0.9 && panel / wing < 1.1, "layer \(i): \(panel / wing)")
        }
        #expect(WaveShape.panelHarmonics == [0.15, 0.15, 0.15])
    }

    @Test func crestSpeedFollowsSlowLoudness() {
        var motion = WaveMotion()
        motion.advance(layers: [1, 1, 1], dt: 1.0 / 60)
        #expect(abs(motion.slowLevel(.bass) - 0.0408) < 0.002)
        for _ in 1..<24 { motion.advance(layers: [1, 1, 1], dt: 1.0 / 60) }
        #expect(abs(motion.slowLevel(.bass) - 0.632) < 0.01)
    }

    /// 120 BPM при 60 Гц: два кадра уровень 1, 28 кадров тишина. Шаг баса за кадр почти не
    /// качается (расчет 1.37; в 0.9.0 больше 3).
    @Test func kicksDoNotPumpCrestSpeed() {
        let dt = 1.0 / 60
        var motion = WaveMotion()
        var steps: [Double] = []
        for frame in 0..<360 {
            let level: Float = frame % 30 < 2 ? 1 : 0
            let before = motion.phase(.bass).carrier
            motion.advance(layers: [level, level, level], dt: dt)
            if frame >= 240 { steps.append(circularStep(from: before, to: motion.phase(.bass).carrier)) }
        }
        let largest = steps.max()!
        let smallest = steps.min()!
        #expect(smallest > 0)
        #expect(largest < 1.5 * smallest, "\(largest / smallest)")
    }

    @Test func hugeStepStaysFinite() {
        var motion = WaveMotion()
        motion.advance(layers: [1, 0.5, 1], dt: 1e300)
        for profile in WaveProfile.allCases {
            for layer in WaveLayer.allCases {
                #expect(isWrapped(motion.phase(layer, profile: profile)))
            }
        }
    }

    // MARK: - BeatPulse

    /// Удар как у `StreamAnalyzer`: огибающая взводится на кадре `triggerFrame` и спадает.
    private func pulseResponse(fps: Double, seconds: Double, triggerFrame: Int = 1) -> [Float] {
        let dt = 1 / fps
        var envelope = BeatEnvelope()
        var pulse = BeatPulse()
        var values: [Float] = []
        for frame in 0..<Int(seconds * fps) {
            envelope.step(dt: dt)
            if frame == triggerFrame { envelope.trigger() }
            values.append(pulse.step(beat: envelope.value, dt: dt))
        }
        return values
    }

    @Test func pulseStaysAtRestInSilence() {
        var pulse = BeatPulse()
        for _ in 0..<240 {
            #expect(pulse.step(beat: 0, dt: 1.0 / 120) == 0)
        }
        #expect(pulse.value == 0)
    }

    @Test func pulseInhalesQuicklyAndExhalesSlowly() {
        let fps = 120.0
        let values = pulseResponse(fps: fps, seconds: 2)
        let peakIndex = values.indices.max { values[$0] < values[$1] }!
        let peakTime = Double(peakIndex - 1) / fps
        #expect(values[peakIndex] >= 0.7 && values[peakIndex] <= 0.95, "peak \(values[peakIndex])")
        #expect(peakTime >= 0.03 && peakTime <= 0.1, "peak at \(peakTime) s")
        // Без скачков между соседними кадрами.
        let largestStep = zip(values, values.dropFirst()).map { abs($1 - $0) }.max()!
        #expect(largestStep < 0.25, "step \(largestStep)")
        // Выдох длиннее вдоха, через 1.5 с остров снова в покое.
        #expect(values[Int(0.25 * fps)] > 0.15)
        #expect(values[Int(1.5 * fps)] < 0.01)
        #expect(values.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test func pulseDoesNotDependOnFrameRate() {
        let at60 = pulseResponse(fps: 60, seconds: 1, triggerFrame: 1)
        let at120 = pulseResponse(fps: 120, seconds: 1, triggerFrame: 2)
        for time in [0.05, 0.1, 0.2, 0.4] {
            let a = at60[Int(time * 60) + 1], b = at120[Int(time * 120) + 2]
            #expect(abs(a - b) < 0.12, "t \(time): \(a) vs \(b)")
        }
    }

    @Test func pulseIgnoresInvalidInput() {
        var pulse = BeatPulse()
        pulse.step(beat: .nan, dt: 1.0 / 60)
        pulse.step(beat: .infinity, dt: .nan)
        pulse.step(beat: 1, dt: -1)
        pulse.step(beat: 1, dt: 0)
        #expect(pulse.value == 0)
        // Длинный кадр и удар на каждом кадре: значение остается в 0...1.
        for _ in 0..<50 {
            let value = pulse.step(beat: 1, dt: 0.1)
            #expect(value >= 0 && value <= 1)
        }
        pulse.step(beat: 1, dt: .infinity)
        #expect(pulse.value.isFinite && pulse.value >= 0 && pulse.value <= 1)
    }

    // MARK: - WavePaint

    private static let warm = [RGBColor(hex: 0xFF8A3D), RGBColor(hex: 0xFFC857), RGBColor(hex: 0xF2545B)]

    private func colorDistance(_ a: RGBColor, _ b: RGBColor) -> Float {
        max(abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b))
    }

    @Test func paintStopsSpanTheWave() {
        for profile in WaveProfile.allCases {
            let stops = WavePaint.stops(palette: Self.warm, layer: .mid, level: 0.6, time: 3, count: 9, profile: profile)
            #expect(stops.count == 9)
            for (index, stop) in stops.enumerated() {
                #expect(abs(stop.location - Double(index) / 8) < 1e-12)
                #expect(stop.opacity >= 0 && stop.opacity <= 1)
            }
            #expect(WavePaint.stops(palette: Self.warm, layer: .mid, level: 0.6, time: 3, count: 1, profile: profile).isEmpty)
        }
    }

    @Test func loudWaveBlendsTwoPaletteColors() {
        // Середина без сдвига светлоты: у выреза свой цвет, посередине следующий.
        let stops = WavePaint.stops(palette: Self.warm, layer: .mid, level: 1, time: 0, count: 9)
        #expect(colorDistance(stops[0].color, Self.warm[1]) < 0.01)
        #expect(colorDistance(stops[4].color, Self.warm[2]) < 0.01)
        #expect(abs(stops[4].opacity - WavePaint.fullOpacity) < 1e-6)
        // Бас темнее и прозрачнее, верх светлее.
        let bass = WavePaint.stops(palette: Self.warm, layer: .bass, level: 1, time: 0, count: 9)
        let high = WavePaint.stops(palette: Self.warm, layer: .high, level: 1, time: 0, count: 9)
        #expect(abs(bass[0].color.oklab.l - (Self.warm[0].oklab.l - 0.06)) < 0.01)
        #expect(abs(high[0].color.oklab.l - (Self.warm[2].oklab.l + 0.06)) < 0.02)
        #expect(abs(bass[4].opacity - 0.8 * WavePaint.fullOpacity) < 1e-6)
    }

    @Test func lightnessIsCapped() {
        let pale = [RGBColor(hex: 0xFFF3C4), RGBColor(hex: 0xFFE9A8), RGBColor(hex: 0xFFFFFF)]
        for layer in WaveLayer.allCases {
            for stop in WavePaint.stops(palette: pale, layer: layer, level: 1, time: 1.7, count: 9) {
                #expect(stop.color.oklab.l <= WavePaint.maxLightness + 0.01)
            }
        }
    }

    @Test func silentWaveIsDimButKeepsTint() {
        for layer in WaveLayer.allCases {
            let silent = WavePaint.stops(palette: Self.warm, layer: layer, level: 0, time: 0, count: 9)
            let loud = WavePaint.stops(palette: Self.warm, layer: layer, level: 1, time: 0, count: 9)
            for stop in silent {
                #expect(stop.opacity <= WavePaint.restOpacity + 1e-6)
            }
            // В тишине оттенок обложки остается, около 60 % насыщенности.
            let ratio = silent[0].color.oklab.chroma / loud[0].color.oklab.chroma
            #expect(ratio > 0.5 && ratio < 0.7, "\(layer): \(ratio)")
        }
        let quiet = WavePaint.stops(palette: Self.warm, layer: .bass, level: 0.1, time: 0, count: 9)[4]
        let loud = WavePaint.stops(palette: Self.warm, layer: .bass, level: 0.6, time: 0, count: 9)[4]
        #expect(quiet.opacity < loud.opacity)
        #expect(quiet.color.oklab.chroma < loud.color.oklab.chroma)
    }

    @Test func wingStartsBrightAtNotchAndDissolvesOutside() {
        let stops = WavePaint.stops(palette: Self.warm, layer: .high, level: 1, time: 0, count: 9)
        let full = stops[4].opacity
        #expect(stops[0].opacity >= 0.8 * full)
        #expect(stops[1].opacity == full)
        #expect(stops[6].opacity == full)
        #expect(stops[7].opacity < full && stops[7].opacity > 0)
        #expect(stops[8].opacity == 0)
    }

    @Test func panelRunsThroughCenterSymmetrically() {
        let stops = WavePaint.stops(palette: Self.warm, layer: .mid, level: 1, time: 3.7, count: 17, profile: .panel)
        #expect(stops[8].opacity == WavePaint.fullOpacity)
        #expect(stops[0].opacity == 0 && stops[16].opacity == 0)
        for i in 0..<17 {
            #expect(abs(stops[i].opacity - stops[16 - i].opacity) < 1e-6)
            #expect(colorDistance(stops[i].color, stops[16 - i].color) < 1e-4)
        }
    }

    @Test func gradientFlowsOutwardAndLoops() {
        // За 2.5 с градиент сдвигается на 0.125 ширины от выреза наружу, за 20 с на всю ширину.
        let now = WavePaint.stops(palette: Self.warm, layer: .bass, level: 1, time: 4, count: 9)
        let later = WavePaint.stops(palette: Self.warm, layer: .bass, level: 1, time: 6.5, count: 9)
        for index in 1..<9 {
            #expect(colorDistance(later[index].color, now[index - 1].color) < 0.005)
        }
        let loop = WavePaint.stops(palette: Self.warm, layer: .bass, level: 1, time: 24, count: 9)
        for index in 0..<9 {
            #expect(colorDistance(loop[index].color, now[index].color) < 0.005)
        }
        // Панель: за 2.5 с на 0.125 полуширины от середины, то есть на одну точку из 17 в каждую сторону.
        let panelNow = WavePaint.stops(palette: Self.warm, layer: .bass, level: 1, time: 4, count: 17, profile: .panel)
        let panelLater = WavePaint.stops(palette: Self.warm, layer: .bass, level: 1, time: 6.5, count: 17, profile: .panel)
        for index in 9..<17 {
            #expect(colorDistance(panelLater[index].color, panelNow[index - 1].color) < 0.005)
        }
        for index in 0..<8 {
            #expect(colorDistance(panelLater[index].color, panelNow[index + 1].color) < 0.005)
        }
    }

    @Test func closePaletteColorsAreSeparated() {
        let red = RGBColor(hex: 0xE11D48)
        let labs = WavePaint.distinct([red, red, RGBColor(hex: 0xE21E49)])
        #expect(labs[0] == red.oklab)
        #expect(labs[0].distance(to: labs[1]) >= 0.08)
        #expect(labs[0].distance(to: labs[2]) >= 0.08)
        #expect(labs[1].distance(to: labs[2]) >= 0.08)
        // Различимые цвета не трогаются.
        let fallback = WavePaint.distinct(PaletteExtractor.fallback)
        #expect(fallback == PaletteExtractor.fallback.map(\.oklab))
    }

    @Test func glowColorIsLightAndSoftlyTinted() {
        for hex: UInt32 in [0x3A3246, 0x22D3EE, 0xFF8A3D, 0x8B5CF6, 0x7A3B12] {
            let source = RGBColor(hex: hex).oklab
            let glow = WavePaint.glowColor(RGBColor(hex: hex)).oklab
            #expect(glow.l >= 0.77, "\(hex): L \(glow.l)")
            // 35 % к белому: насыщенность 0.65 от исходной (бледная сначала доводится до 0.12).
            let expected = 0.65 * max(source.chroma, 0.12)
            #expect(abs(glow.chroma - expected) < 0.03, "\(hex): C \(glow.chroma) vs \(expected)")
            // Оттенок не меняется: теплый остается теплым.
            let turn = abs(atan2(glow.b, glow.a) - atan2(source.b, source.a))
            #expect(min(turn, 2 * .pi - turn) < 0.12, "\(hex): hue turn \(turn)")
        }
        let gray = WavePaint.glowColor(RGBColor(hex: 0x404040)).oklab
        #expect(gray.chroma < 0.01 && gray.l >= 0.77)
    }

    @Test func gradientLocationsResolveBothFades() {
        let wing = WavePaint.locations(for: .wing)
        #expect(wing.first == 0 && wing.last == 1)
        #expect(zip(wing, wing.dropFirst()).allSatisfy { $0 < $1 })
        #expect(wing.filter { $0 > 0 && $0 <= WavePaint.fadeInWidth }.count >= 3)
        #expect(wing.filter { $0 >= WavePaint.fadeOutStart && $0 < 1 }.count >= 4)
        #expect(wing.contains(WavePaint.fadeOutStart))
        // Шаг течения цвета не больше 1/8.
        #expect(zip(wing, wing.dropFirst()).allSatisfy { $1 - $0 <= 0.125 + 1e-12 })

        let panel = WavePaint.locations(for: .panel)
        #expect(panel.first == 0 && panel.last == 1 && panel.contains(0.5))
        #expect(zip(panel, panel.dropFirst()).allSatisfy { $0 < $1 })
        for (a, b) in zip(panel, panel.reversed()) {
            #expect(abs(a + b - 1) < 1e-12)
        }

        // На этих точках у выреза видно проявление, у края плавное растворение.
        let stops = WavePaint.stops(palette: Self.warm, layer: .mid, level: 1, time: 0, locations: wing, profile: .wing)
        let notch = stops.filter { $0.location <= WavePaint.fadeInWidth }.map(\.opacity)
        #expect(zip(notch, notch.dropFirst()).allSatisfy { $0 < $1 })
        let outer = stops.filter { $0.location >= WavePaint.fadeOutStart }.map(\.opacity)
        #expect(outer.first == WavePaint.fullOpacity && outer.last == 0)
        #expect(zip(outer, outer.dropFirst()).allSatisfy { $0 > $1 })
    }

    @Test func wingSwingIsBoostedWithSoftCap() {
        #expect(WaveShape.softLimit(0.5) == 0.5)
        #expect(WaveShape.softLimit(-0.8) == -0.8)
        var previous = -10.0
        for i in 0...400 {
            let v = -2 + Double(i) / 100
            let y = WaveShape.softLimit(v)
            #expect(y > previous && abs(y) < 1)
            #expect(abs(WaveShape.softLimit(-v) + y) < 1e-12)
            previous = y
        }
        // Касательная на изломе непрерывна.
        let left = (WaveShape.softLimit(0.8) - WaveShape.softLimit(0.799)) / 0.001
        let right = (WaveShape.softLimit(0.801) - WaveShape.softLimit(0.8)) / 0.001
        #expect(abs(left - right) < 0.01)
        // Тихая волна в крыле в 1.3 раза выше той же волны без усиления.
        for layer in WaveLayer.allCases {
            var wingPeak: Float = 0
            for i in 0..<64 {
                let phase = Double(i) / 64 * 2 * Double.pi
                let y = WaveShape.samples(layer: layer, amplitude: 0.4, phase: legacyPhase(phase), count: 201, profile: .wing)
                wingPeak = max(wingPeak, y.map { abs($0) }.max()!)
            }
            #expect(wingPeak > 0.45 && wingPeak <= 0.53, "\(layer): \(wingPeak)")
        }
    }

    @Test func gainScalesAndStaysInRange() {
        for profile in WaveProfile.allCases {
            for layer in WaveLayer.allCases {
                for phase in stride(from: 0.0, to: 2 * Double.pi, by: 0.9) {
                    let p = legacyPhase(phase)
                    let unit = WaveShape.samples(layer: layer, amplitude: 1, phase: p, count: 129, profile: profile)
                    #expect(unit == WaveShape.samples(layer: layer, amplitude: 1, phase: p, count: 129, profile: profile, gain: 1))
                    let loud = WaveShape.samples(layer: layer, amplitude: 1, phase: p, count: 129, profile: profile, gain: 2)
                    #expect(loud.allSatisfy { abs($0) <= 1 })
                    let quiet = WaveShape.samples(layer: layer, amplitude: 1, phase: p, count: 129, profile: profile, gain: 0.5)
                    for (y, y1) in zip(quiet, unit) where abs(y1) < 0.8 {
                        #expect(abs(y - 0.5 * y1) <= 1e-6, "\(profile) \(layer): \(y) vs \(y1)")
                    }
                }
            }
        }
        let bad = WaveShape.samples(layer: .mid, amplitude: 1, phase: legacyPhase(1), count: 33, gain: .nan)
        #expect(bad.allSatisfy { $0.isFinite && abs($0) <= 1 })
        #expect(WavePaint.fillTopOpacity == 0.55)
    }

    @Test func paintSurvivesBadInput() {
        for profile in WaveProfile.allCases {
            for stop in WavePaint.stops(palette: [], layer: .high, level: .nan, time: .infinity, count: 5, profile: profile) {
                #expect(stop.color.r.isFinite && stop.color.g.isFinite && stop.color.b.isFinite)
                #expect(stop.opacity.isFinite && stop.opacity >= 0 && stop.opacity <= 1)
            }
        }
        let short = WavePaint.stops(palette: [RGBColor(hex: 0x22D3EE)], layer: .high, level: 1, time: 0, count: 3)
        #expect(short.count == 3)
    }
}
