import Foundation
import Testing
@testable import WaveCore

/// Режимы свечения (`GlowMode`) через всю цепочку: «По ритму» это 1.3 без изменений, «По звуку» без сетки и
/// бочек, анализ от режима не зависит. Рендер как в журналах владельца: 30 кадров, упреждение 1/30 с.
@Suite(.enabled(if: TestPlatform.isLinux))
struct GlowModeTests {
    private static func run(
        _ scene: @escaping @Sendable () -> DrumScene, modes: [GlowMode], latency: Double = 0.020, sync: Double = 0
    ) async -> (scene: DrumScene, results: [OfflineBeatChain.Result]) {
        await runOffCooperativePool {
            let scene = scene()
            let results = modes.map { mode in
                var config = OfflineBeatChain.Config(seed: 1)
                config.outputLatency = latency
                config.syncOffset = sync
                config.renderRate = 30
                config.presentationLead = 1.0 / 30
                config.glowMode = mode
                return OfflineBeatChain.run(samples: scene.samples, sampleRate: scene.sampleRate, config: config)
            }
            return (scene, results)
        }
    }

    /// `rhythm` это цепочка по умолчанию: те же вспышки, состояния и пик; у вспышек есть пик, кадры с
    /// видимым свечением считаются только на слышимом отрезке.
    @Test func rhythmIsTheDefault() async {
        let (scene, results) = await Self.run({ SharedScenes.steady120 }, modes: [.rhythm])
        let plain = await runOffCooperativePool {
            var config = OfflineBeatChain.Config(seed: 1)
            config.renderRate = 30
            config.presentationLead = 1.0 / 30
            return OfflineBeatChain.run(samples: scene.samples, sampleRate: scene.sampleRate, config: config)
        }
        let rhythm = results[0]
        #expect(rhythm.flashes == plain.flashes && rhythm.states == plain.states && rhythm.peakGlow == plain.peakGlow)
        #expect(!rhythm.flashes.isEmpty && rhythm.flashes.allSatisfy { $0.peak > OfflineBeatChain.eventRise && !$0.reactive })
        #expect(rhythm.visibleFrames > 0 && rhythm.visibleFrames < rhythm.audibleFrames)
        // 24 с звука на 30 кадрах.
        #expect(abs(rhythm.audibleFrames - 24 * 30) <= 1)
    }

    /// `sound`: сетка и бочки не светятся (только реактивный слой), а анализ тот же: состояния публикаций
    /// совпадают с `rhythm`.
    @Test func soundModeHidesTheGridAndTheKicks() async {
        let (_, results) = await Self.run({ SharedScenes.steady120 }, modes: [.rhythm, .sound])
        let (rhythm, sound) = (results[0], results[1])
        #expect(sound.states == rhythm.states)
        #expect(sound.flashes.allSatisfy { $0.reactive }, "grid or kick flashes \(sound.flashes.filter { !$0.reactive }.count)")
    }

    /// Сдвиги вспышек от ближайшего удара `reference` (не дальше 70 мс), секунды.
    private static func offsets(_ flashes: [OfflineBeatChain.Flash], reference: [Double]) -> [Double] {
        flashes.compactMap { flash in
            let nearest = reference.min { abs($0 - flash.time) < abs($1 - flash.time) }
            return nearest.flatMap { abs(flash.time - $0) <= 0.07 ? flash.time - $0 : nil }
        }
    }

    /// «По звуку» на бочке 120 BPM с хэтами: реактивные вспышки идут на бочках (одна на удар, мимо не больше
    /// одной), не раньше 1.5 с прогрева, в полную яркость. С задержкой вывода Bluetooth (211 мс, сдвиг -20 мс)
    /// у анализа есть запас, и вспышка встает туда же, куда вспышка сетки «По ритму» (опережение
    /// `BeatGlow.lead`); на 20 мс она опаздывает на обнаружение и доставку, как волны (на 30-80 мс позже
    /// сетки).
    @Test(arguments: [0.211, 0.020])
    func soundModeFlashesOnTheKicks(latency: Double) async {
        let sync = latency > 0.1 ? -0.02 : 0
        let (scene, results) = await Self.run({ SharedScenes.steady120 }, modes: [.sound, .rhythm], latency: latency, sync: sync)
        let kicks = scene.kicks.map { $0 + latency }
        let expected = kicks.filter { $0 >= 2.05 && $0 <= 22.95 }.count
        let flashes = results[0].flashes.filter { $0.time >= 2 && $0.time <= 23 }
        let offsets = Self.offsets(flashes, reference: kicks)
        // Прогрев: события с 1.5 с потока (центр окна ноты баса чуть раньше конца шага), вспышка на сдвиг и
        // опережение раньше слышимого момента.
        let firstAllowed = ReactiveGlow.warmUp - 0.011 + latency + sync - BeatGlow.lead - 1.0 / 30
        #expect(results[0].flashes.allSatisfy { $0.time >= firstAllowed }, "\(results[0].flashes.prefix(3))")
        #expect(Double(offsets.count) >= 0.9 * Double(expected), "on kicks \(offsets.count) of \(expected)")
        #expect(flashes.count - offsets.count <= 1, "off the kicks \(flashes.count - offsets.count)")
        // Одна вспышка на удар: подъем функции онсетов на двух шагах сливается в одно событие.
        #expect(offsets.count <= expected + 1, "double flashes: \(offsets.count) on \(expected) kicks")
        #expect(flashes.allSatisfy { $0.peak >= 0.5 }, "full brightness \(flashes.map(\.peak).min() ?? 0)")
        // Сетка после захвата (с 8 с) против реактивных вспышек тех же ударов.
        func mean(_ values: [Double]) -> Double { values.reduce(0, +) / Double(max(values.count, 1)) }
        let late = { (flash: OfflineBeatChain.Flash) in flash.time >= 8 && flash.time <= 23 }
        let reactive = mean(Self.offsets(results[0].flashes.filter(late), reference: kicks))
        let grid = mean(Self.offsets(results[1].flashes.filter(late), reference: kicks))
        if latency > 0.1 {
            #expect(abs(reactive - grid) <= 0.008, "reactive \(reactive), grid \(grid)")
        } else {
            #expect((0.030...0.080).contains(reactive - grid), "reactive \(reactive), grid \(grid)")
        }
    }

    /// «Ритм и звук» на захваченной бочке: все вспышки сетки на месте (у каждой вспышки «По ритму» есть
    /// вспышка в пределах кадра), реактивный слой мягкий (не ярче 0.6).
    @Test func hybridKeepsTheGridFlashes() async {
        let (_, results) = await Self.run({ SharedScenes.steady120 }, modes: [.rhythm, .hybrid])
        let (rhythm, hybrid) = (results[0], results[1])
        for flash in rhythm.flashes {
            #expect(hybrid.flashes.contains { abs($0.time - flash.time) <= 1.0 / 60 + 1e-9 }, "grid flash at \(flash.time) lost")
        }
        #expect(hybrid.flashes.filter(\.reactive).allSatisfy { $0.peak <= ReactiveGlow.hybridScale + 1e-6 })
    }

    /// «Ритм и звук» на захваченной бочке 120 BPM (хэты восьмыми), с задержкой Bluetooth и встроенных
    /// динамиков: у каждой вспышки «По ритму» в пределах 70 мс ровно одна вспышка, вспышка доли в захвате на
    /// том же кадре, ярких вспышек (пик от `strongPeak`) столько же. Реактивное событие у доли, которая
    /// вспыхивает, отбрасывается: иначе мягкая вспышка за кадр до доли забирала ее вспышку (211 мс) или шла
    /// второй сразу после нее (20 мс). Вспышка бочки до захвата может прийти кадром раньше: реактивное
    /// событие того же удара у бочки не отбрасывается (правило только для долей сетки), но вспышка одна.
    /// Метка `predicted` до захвата у вспышки бочки тоже бывает (правило 1.3 `startedEvent`: доля с
    /// яркостью 0 начинается позже бочки), поэтому кадр проверяется только у вспышек в захвате.
    @Test(arguments: [0.211, 0.020])
    func lockedKickTrackKeepsItsFlashesInHybrid(latency: Double) async {
        let sync = latency > 0.1 ? -0.02 : 0
        let (_, results) = await Self.run({ SharedScenes.steady120 }, modes: [.rhythm, .hybrid], latency: latency, sync: sync)
        let (rhythm, hybrid) = (results[0], results[1])
        let strong = { (flash: OfflineBeatChain.Flash) in flash.peak >= BeatEvaluation.strongPeak }
        #expect(rhythm.flashes.filter(\.locked).count >= 20, "locked rhythm flashes \(rhythm.flashes.filter(\.locked).count)")
        for flash in rhythm.flashes {
            let near = hybrid.flashes.filter { abs($0.time - flash.time) <= 0.07 }
            #expect(near.count == 1, "flash at \(flash.time): \(near.count) hybrid flashes within 70 ms")
            if flash.predicted, flash.locked {
                #expect(near.contains { abs($0.time - flash.time) <= 1.0 / 60 + 1e-9 }, "grid flash at \(flash.time) lost")
            }
        }
        #expect(
            hybrid.flashes.filter(strong).count == rhythm.flashes.filter(strong).count,
            "strong \(hybrid.flashes.filter(strong).count) vs \(rhythm.flashes.filter(strong).count)"
        )
    }

    /// Множитель реактивного события по сетке (вариант d) у захваченного трекера: у вспыхивающей доли и в
    /// 70 мс от нее 0 (событие отбрасывается), на «и» `1 − 0.6 q`, в других местах `1 − 0.9 q`,
    /// `q = smoothstep(0.1, 0.5, уверенность)`. На 150 BPM с показом через долю скрытая доля (яркость 0) не
    /// вспыхивает, событие на ней остается в полную яркость: это доля сетки ФАПЧ.
    @Test func hybridScalesReactiveEventsByTheGrid() async {
        let probes = await runOffCooperativePool { () -> [(bpm: Double, tracker: BeatTracker)] in
            [120.0, 150].map { (bpm: Double) in
                let scene = Drums.fourOnFloor(bpm: bpm, seconds: 12, hats: .eighths)
                let analyzer = StreamAnalyzer(sampleRate: scene.sampleRate)
                analyzer.measuresBassLevel = true
                var tracker = BeatTracker(framesPerSecond: analyzer.config.framesPerSecond)
                tracker.glowMode = .hybrid
                // На 150 BPM последнее состояние с захватом и показом через долю.
                var probe = tracker
                for hop in analyzer.processSignal(scene.samples) {
                    tracker.process(hop)
                    if tracker.locked, bpm < 140 || tracker.shownParity != nil { probe = tracker }
                }
                return (bpm, probe)
            }
        }
        for (bpm, tracker) in probes {
            let schedule = tracker.schedule
            let beats = schedule.events.filter(\.predicted)
            guard let period = tracker.period, tracker.locked, let shown = beats.first(where: { $0.amplitude > OfflineBeatChain.eventRise }) else {
                Issue.record("\(bpm) BPM: no locked flashing beat, \(beats)")
                continue
            }
            let q = BeatTracker.smoothstep(0.1, 0.5, Float(tracker.gridConfidence))
            #expect(q > 0.5, "\(bpm) BPM: q \(q)")
            #expect(tracker.reactiveGridScale(at: shown.time) == 0)
            #expect(tracker.reactiveGridScale(at: shown.time - 0.06) == 0 && tracker.reactiveGridScale(at: shown.time + 0.06) == 0)
            #expect(abs(tracker.reactiveGridScale(at: shown.time + period / 2) - (1 - 0.6 * q)) < 1e-6)
            #expect(abs(tracker.reactiveGridScale(at: shown.time + period / 4) - (1 - 0.9 * q)) < 1e-6)
            if bpm > 140 {
                #expect(tracker.shownParity != nil, "every-other display at \(bpm) BPM")
                let hidden = beats.first { $0.amplitude == 0 }
                #expect(hidden.map { tracker.reactiveGridScale(at: $0.time + 0.03) } == 1, "\(beats)")
            }
        }
    }

    /// 808 без удара (трек T2 владельца, `Drums.glide808`): «Ритм и звук» и «По звуку» не темные (темнота
    /// после прогрева не больше 0.35), вспышки идут на нотах (не дальше 70 мс от начала ноты не меньше 0.8
    /// всех) и в «Ритм и звук» мягкие. Это заслуга нот баса: на одних акцентах потока здесь 3 вспышки за
    /// 22 с (темнота 0.93), «По ритму» темно все время, как у T2 в 1.3.
    @Test func gliding808IsNotDark() async {
        let latency = 0.211
        let (scene, results) = await Self.run({ Drums.glide808() }, modes: [.hybrid, .sound], latency: latency)
        let notes = scene.kicks.map { $0 + latency }
        for (mode, result) in zip([GlowMode.hybrid, .sound], results) {
            let flashes = result.flashes.filter { $0.time >= 2 + latency && $0.time <= 24 + latency }
            let dark = BeatMetrics.darkSpans(detections: flashes.map(\.time), from: 2 + latency, to: 24 + latency, gap: 1.5).total / 22
            let onNotes = Self.offsets(flashes, reference: notes).count
            #expect(dark <= 0.35, "\(mode) dark \(dark), flashes \(flashes.count)")
            #expect(Double(onNotes) >= 0.8 * Double(flashes.count), "\(mode) on notes \(onNotes) of \(flashes.count)")
            if mode == .hybrid {
                #expect(flashes.filter(\.reactive).allSatisfy { $0.peak <= ReactiveGlow.hybridScale + 1e-6 })
            }
        }
    }

    /// Розовый шум от -10 до -50 dBFS по 60 с в каждом режиме. «По ритму» не вспыхивает и не светит выше
    /// порога вспышки 0.2 (цель плана). Реактивный слой почти молчит: не больше одной вспышки на уровень и
    /// двух за 300 с (цель плана 0.5 в минуту); в «Ритм и звук» она мягкая (не ярче 0.6), в «По звуку» та
    /// же вспышка в полную яркость (у шумовой вспышки в этом режиме предела 0.2 нет, есть предел числа).
    @Test(arguments: GlowMode.allCases)
    func pinkNoiseStaysAlmostDark(mode: GlowMode) async {
        let runs = await runOffCooperativePool { () -> [(level: Int, flashes: Int, peak: Float)] in
            [-10, -20, -30, -40, -50].map { (level: Int) in
                let noise = Drums.pinkNoise(levelDB: Float(level), count: 60 * 48_000, seed: UInt64(-level))
                var config = OfflineBeatChain.Config(seed: 1)
                config.glowMode = mode
                config.renderRate = 30
                config.presentationLead = 1.0 / 30
                let result = OfflineBeatChain.run(samples: noise, sampleRate: 48_000, config: config)
                return (level, result.flashes.count, result.peakGlow)
            }
        }
        for run in runs {
            switch mode {
            case .rhythm:
                #expect(run.flashes == 0 && run.peak < OfflineBeatChain.eventRise, "\(run.level) dB: \(run.flashes), peak \(run.peak)")
            case .hybrid:
                #expect(run.flashes <= 1 && run.peak <= ReactiveGlow.hybridScale + 1e-6, "\(run.level) dB: \(run.flashes), peak \(run.peak)")
            case .sound:
                #expect(run.flashes <= 1, "\(run.level) dB: \(run.flashes), peak \(run.peak)")
            }
        }
        #expect(runs.reduce(0) { $0 + $1.flashes } <= 2, "\(runs)")
    }

    /// «По ритму» это 1.3: расписание трекера после каждого шага (id, время, яркость, вид каждого события,
    /// захват, вес, уверенность) и вспышки цепочки (времена и метки доля/бочка, `startedEvent`) совпадают по
    /// битам с эталоном, снятым тем же кодом (`RhythmGolden`) на 8935e53. В расписаниях нет реактивных
    /// событий. Три сцены: захват на 120 BPM, показ через долю на 150 BPM (доли с яркостью 0), хип-хоп.
    @Test(arguments: [GlowMode.rhythm, nil])
    func rhythmMatchesTheGoldenOf13(mode: GlowMode?) async {
        let golden: [String: RhythmGolden.Print] = [
            "fourOnFloor120": .init(
                hops: 2247, events: 18711, scheduleHash: 0x1fbe7a452ac1430e, flashes: 24, flashHash: 0x10a2956d1712ab2d,
                labels: "kkkkkkkPPPPPPPPPPPPPPPPP"
            ),
            "fourOnFloor150": .init(
                hops: 2247, events: 19093, scheduleHash: 0x7313f5fc87f68cf2, flashes: 22, flashHash: 0xe2ad6aa318439666,
                labels: "kkkkkkkkkkkkpPPPPPPPPP"
            ),
            "hipHop90": .init(
                hops: 2247, events: 17874, scheduleHash: 0x3d5b869a5201e383, flashes: 14, flashHash: 0x88649df8a7d0627a,
                labels: "kkkkPPPPPPPPPP"
            ),
        ]
        let prints = await runOffCooperativePool { () -> [(String, RhythmGolden.Print, Int)] in
            RhythmGolden.scenes.map { name, scene in
                var reactive = 0
                let print = RhythmGolden.fingerprint(
                    scene(), configure: { tracker in if let mode { tracker.glowMode = mode } },
                    check: { schedule in
                        reactive += schedule.events.filter { $0.reactive || $0.id & ~BeatTracker.onsetIDFlag & BeatTracker.reactiveIDFlag != 0 }.count
                    }
                )
                return (name, print, reactive)
            }
        }
        for (name, print, reactive) in prints {
            #expect(print == golden[name], "\(name): \(print)")
            #expect(reactive == 0, "\(name): \(reactive) reactive events in rhythm schedules")
        }
    }

    /// Смена режима посреди трека: в «По ритму» реактивных событий в расписании нет; после возврата в
    /// «По звуку» слой начинается заново (первое событие не раньше `ReactiveGlow.warmUp` после смены), и
    /// события до смены не возвращаются. Сброс слоя при смене один для «Ритм и звук» и «По звуку»
    /// (`BeatTracker.glowMode`); проверка идет в «По звуку», потому что в «Ритм и звук» на захваченной бочке
    /// события ударов отбрасываются (их показывают доли сетки) и первое видное событие не про прогрев.
    @Test func modeSwitchRestartsTheReactiveLayer() async {
        let checks = await runOffCooperativePool { () -> (rhythmReactive: Int, firstAfter: Double?, switchBack: Double, stale: Int) in
            let scene = SharedScenes.steady120
            let analyzer = StreamAnalyzer(sampleRate: scene.sampleRate)
            analyzer.measuresBassLevel = true
            var tracker = BeatTracker(framesPerSecond: analyzer.config.framesPerSecond)
            tracker.glowMode = .sound
            var rhythmReactive = 0
            var firstAfter: Double?
            var before: Set<UInt64> = []
            var stale = 0
            let switchBack = 12.0
            for hop in analyzer.processSignal(scene.samples) {
                if hop.endTime >= 8, hop.endTime < switchBack { tracker.glowMode = .rhythm }
                if hop.endTime >= switchBack { tracker.glowMode = .sound }
                tracker.process(hop)
                let reactive = tracker.schedule.events.filter(\.reactive)
                if hop.endTime < 8 {
                    before.formUnion(reactive.map(\.id))
                } else if hop.endTime < switchBack {
                    rhythmReactive += reactive.count
                } else {
                    stale += reactive.filter { before.contains($0.id) }.count
                    if firstAfter == nil, let first = reactive.first { firstAfter = first.time }
                }
            }
            return (rhythmReactive, firstAfter, switchBack, stale)
        }
        #expect(checks.rhythmReactive == 0)
        #expect(checks.stale == 0)
        let first = checks.firstAfter ?? 0
        #expect(first >= checks.switchBack + ReactiveGlow.warmUp - 0.02 && first <= checks.switchBack + ReactiveGlow.warmUp + 1, "first \(first)")
    }
}

