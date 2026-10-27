import Foundation
import Testing
@testable import WaveCore

struct BeatEvaluationTests {
    /// Доли каждые 0.5 с в файле длиной 10 с.
    private static let beats = (0..<20).map { Double($0) * 0.5 }
    private static let duration = 10.0

    private static func flash(_ time: Double, locked: Bool = true) -> OfflineBeatChain.Flash {
        OfflineBeatChain.Flash(time: time, predicted: true, locked: locked)
    }

    private static func result(
        flashes: [OfflineBeatChain.Flash], states: [OfflineBeatChain.State] = [], latency: Double = 0.020
    ) -> OfflineBeatChain.Result {
        OfflineBeatChain.Result(
            flashes: flashes, states: states, kickOnsets: [], predictedTimes: [], peakGlow: 1, outputLatency: latency
        )
    }

    private static func score(
        _ result: OfflineBeatChain.Result, options: BeatEvaluation.Options = .init()
    ) -> BeatEvaluation.FileScore {
        BeatEvaluation.score(
            result: result, annotations: beats, duration: duration, options: options, path: "/x/a.wav", group: "g",
            heldout: false
        )
    }

    @Test func dedupeKeepsTheFirstOfCloseFlashes() {
        let merged = BeatEvaluation.dedupe([Self.flash(1.0), Self.flash(1.03), Self.flash(0.5), Self.flash(1.06)])
        #expect(merged.map(\.time) == [0.5, 1.0, 1.06])
        #expect(BeatEvaluation.dedupe([]).isEmpty)
        // Пара "без захвата, потом с захватом" оставляет вспышку с захватом, в другом порядке тоже.
        let unlockedFirst = BeatEvaluation.dedupe([Self.flash(1.0, locked: false), Self.flash(1.03, locked: true)])
        #expect(unlockedFirst.count == 1 && unlockedFirst[0].locked && unlockedFirst[0].time == 1.03)
        let lockedFirst = BeatEvaluation.dedupe([Self.flash(1.0, locked: true), Self.flash(1.03, locked: false)])
        #expect(lockedFirst.count == 1 && lockedFirst[0].locked && lockedFirst[0].time == 1.0)
    }

    /// Вспышка в звук имеет время "доля плюс задержка": на слышимой оси сдвиг нулевой.
    @Test func audibleAxisIsUsed() throws {
        let flashes = Self.beats.map { Self.flash($0 + 0.020) }
        let score = Self.score(Self.result(flashes: flashes))
        #expect(score.f == 1 && score.lockedPrecision == 1 && score.amlt == 1)
        #expect(try #require(score.meanOffsetMs).magnitude < 1e-6)
        // Без перевода осей осталась бы лишняя задержка.
        let shifted = Self.score(Self.result(flashes: flashes, latency: 0.2))
        #expect(shifted.f < 1)
    }

    @Test func leadShowsAsNegativeOffset() throws {
        let flashes = Self.beats.map { Self.flash($0 + 0.020 - 0.025) }
        let score = Self.score(Self.result(flashes: flashes))
        #expect(score.f == 1)
        #expect(abs(try #require(score.meanOffsetMs) + 25) < 1e-6)
    }

    /// Хвост рендера после конца файла не считается ошибкой.
    @Test func tailFlashesAreClipped() {
        var flashes = Self.beats.map { Self.flash($0 + 0.020) }
        flashes += [Self.flash(10.02 + 0.2), Self.flash(10.02 + 0.5)]
        let score = Self.score(Self.result(flashes: flashes))
        #expect(score.flashCount == 20)
        #expect(score.lockedPrecision == 1 && score.precision == 1)
    }

    /// Две вспышки у одной доли (онсет и предсказание) это одна вспышка.
    @Test func closePairsCountOnce() {
        var flashes: [OfflineBeatChain.Flash] = []
        for beat in Self.beats {
            flashes += [Self.flash(beat + 0.020), Self.flash(beat + 0.020 + 0.016)]
        }
        let score = Self.score(Self.result(flashes: flashes))
        #expect(score.flashCount == 20)
        #expect(score.f == 1 && score.lockedPrecision == 1 && score.cmlt == 1)
    }

    @Test func lockedPrecisionOnlyLooksAtLockedFlashes() throws {
        var flashes = Self.beats.prefix(10).map { Self.flash($0 + 0.020, locked: false) }
        flashes += Self.beats.suffix(10).map { Self.flash($0 + 0.020 + (Int($0 * 2) % 2 == 0 ? 0 : 0.25)) }
        let score = Self.score(Self.result(flashes: flashes))
        #expect(score.lockedFlashCount == 10)
        #expect(score.lockedMatched == 5)
        #expect(score.lockedPrecision == 0.5)
        let none = Self.score(Self.result(flashes: flashes.map { Self.flash($0.time, locked: false) }))
        #expect(none.lockedPrecision == nil && none.lockedMatched == 0)
    }

    /// Точности и сдвиги по видам вспышек: с захватом точно в долю (-10 мс), без захвата половина мимо (+30 мс).
    @Test func lockedAndUnlockedKindsAreScoredSeparately() throws {
        var flashes = Self.beats.prefix(10).map { Self.flash($0 + 0.020 - 0.010) }
        for (index, beat) in Self.beats.suffix(10).enumerated() {
            flashes.append(Self.flash(beat + 0.020 + (index % 2 == 0 ? 0.030 : 0.25), locked: false))
        }
        let score = Self.score(Self.result(flashes: flashes))
        #expect(score.flashCount == 20 && score.matched == 15)
        #expect(score.lockedFlashCount == 10 && score.lockedMatched == 10 && score.lockedPrecision == 1)
        #expect(score.unlockedFlashCount == 10 && score.unlockedMatched == 5 && score.unlockedPrecision == 0.5)
        #expect(score.offsetLockedCount == 10 && abs(score.offsetLockedSumMs + 100) < 1e-6)
        #expect(score.offsetUnlockedCount == 5 && abs(score.offsetUnlockedSumMs - 150) < 1e-6)
        let row = BeatEvaluation.summarize(name: "x", scores: [score])
        #expect(row.precisionPooled == 0.75 && row.unlockedPrecisionPooled == 0.5 && row.lockedPrecisionPooled == 1)
        #expect(abs(try #require(row.meanOffsetLockedMs) + 10) < 1e-9)
        #expect(abs(try #require(row.meanOffsetUnlockedMs) - 30) < 1e-9)
    }

    /// Захват, полученный до `skip`, считается с момента `skip`, а делится на оставшуюся длину.
    @Test func coverageWithSkipKeepsTheStateInForce() {
        let states = [
            OfflineBeatChain.State(time: 0, locked: false, bpm: nil, confidence: 0),
            OfflineBeatChain.State(time: 3, locked: true, bpm: 120, confidence: 1),
            OfflineBeatChain.State(time: 8, locked: false, bpm: 120, confidence: 0),
        ]
        // Окно 5...10: захват 5...8 это 3 из 5 секунд.
        #expect(abs(BeatEvaluation.coverage(states: states, from: 5, duration: 10) - 0.6) < 1e-12)
        #expect(abs(BeatEvaluation.coverage(states: states, from: 0, duration: 10) - 0.5) < 1e-12)
    }

    @Test func noFlashesScoreZero() {
        let score = Self.score(Self.result(flashes: []))
        #expect(score.f == 0 && score.cmlt == 0 && score.amlt == 0 && score.flashCount == 0)
        #expect(score.meanOffsetMs == nil && score.lockedPrecision == nil)
    }

    @Test func skipSecondsDropsTheStart() {
        let flashes = Self.beats.filter { $0 >= 5 }.map { Self.flash($0 + 0.020) }
        let skipped = Self.score(Self.result(flashes: flashes), options: .init(skipSeconds: 5))
        #expect(skipped.annotationCount == 10 && skipped.f == 1)
        let full = Self.score(Self.result(flashes: flashes))
        #expect(full.annotationCount == 20 && full.f < 0.7)
    }

    @Test func coverageUsesStates() {
        let states = [
            OfflineBeatChain.State(time: 0, locked: false, bpm: nil, confidence: 0),
            OfflineBeatChain.State(time: 5, locked: true, bpm: 120, confidence: 1),
        ]
        let score = Self.score(Self.result(flashes: [], states: states))
        #expect(abs(score.lockedCoverage - 0.5) < 1e-12)
        #expect(score.lockTime == 5 && score.tempoBPM == 120)
    }

    @Test func summariesAverageOverFiles() throws {
        func file(_ group: String, heldout: Bool, locked: Double?, f: Double, offset: Double?) -> BeatEvaluation.FileScore {
            BeatEvaluation.FileScore(
                path: group, group: group, heldout: heldout, duration: 30, annotationCount: 10, flashCount: 10,
                matched: Int(f * 10), lockedFlashCount: locked == nil ? 0 : 10, lockedMatched: Int((locked ?? 0) * 10),
                unlockedFlashCount: locked == nil ? 10 : 0, unlockedMatched: locked == nil ? Int(f * 10) : 0,
                lockedPrecision: locked, unlockedPrecision: locked == nil ? f : nil, precision: f, recall: f, f: f,
                meanOffsetMs: offset, offsetLockedSumMs: 0, offsetLockedCount: 0, offsetUnlockedSumMs: 0,
                offsetUnlockedCount: 0, cmlt: f, amlt: f, lockedCoverage: f, lockTime: nil, tempoBPM: nil
            )
        }
        let scores = [
            file("a", heldout: false, locked: 1.0, f: 1.0, offset: -10),
            file("a", heldout: true, locked: nil, f: 0.0, offset: nil),
            file("b", heldout: false, locked: 0.5, f: 0.5, offset: -30),
            file("c", heldout: false, locked: 0.0, f: 0.0, offset: 10),
        ]
        let rows = BeatEvaluation.summaries(scores: scores, unions: [.init(name: "ab", groups: ["a", "b", "z"]), .init(name: "none", groups: ["z"])])
        #expect(rows.map(\.name) == ["a", "b", "c", "ab", "TOTAL"])
        let a = rows[0]
        #expect(a.files == 2 && a.lockedPrecision == 1 && a.lockedFiles == 1 && a.f == 0.5 && a.meanOffsetMs == -10)
        let ab = rows[3]
        #expect(ab.files == 3)
        #expect(abs(try #require(ab.lockedPrecision) - 0.75) < 1e-12)
        #expect(abs(try #require(ab.meanOffsetMs) + 20) < 1e-12)
        let total = rows[4]
        #expect(total.files == 4 && total.lockedFiles == 3)
        // 10 + 5 + 0 совпадений из 30 вспышек.
        #expect(abs(try #require(total.lockedPrecisionPooled) - 0.5) < 1e-12)
        // Захват мимо долей: только c (10 вспышек при захвате, ни одной в долю); у b точность ровно 0.5.
        #expect(total.wrongLockFiles == 1 && total.wrongLockFlashes == 10)
        #expect(rows[1].wrongLockFiles == 0)
        #expect(BeatEvaluation.filter(scores, split: .tune).count == 3)
        #expect(BeatEvaluation.filter(scores, split: .heldout).map(\.group) == ["a"])
        #expect(BeatEvaluation.filter(scores, split: .all).count == 4)
        #expect(BeatEvaluation.summarize(name: "empty", scores: []).files == 0)
    }

    @Test func tablesMentionEveryRow() {
        let rows = BeatEvaluation.summaries(scores: [], unions: [])
        let text = BeatEvaluation.table(title: "t", summaries: rows)
        #expect(text.contains("TOTAL") && text.contains("lockedFiles") && text.contains("unlockedPrec"))
        #expect(text.contains("offLocked") && text.contains("wrongLock") && text.hasPrefix("t\n"))
        #expect(text.contains("recall") && text.contains("dark50") && text.contains("dark90"))
        #expect(text.contains("flips/min") && text.contains("unlocks t/p/m"))
        #expect(text.contains("darkL50") && text.contains("darkL90"))
    }

    /// Темная доля: размеченная доля без вспышки в окне ±70 мс. Доли 0.5...10.0 через 0.5, вспышек нет
    /// на 4.0-6.0: самая длинная темная серия 5 долей.
    @Test func longestDarkRunCountsConsecutiveMissedBeats() {
        let beats = (1...20).map { Double($0) * 0.5 }
        let lit = beats.filter { $0 < 4.0 || $0 > 6.0 }.map { Self.flash($0 + 0.020) }
        func longest(_ flashes: [OfflineBeatChain.Flash]) -> Int {
            BeatEvaluation.score(
                result: Self.result(flashes: flashes), annotations: beats, duration: 10, options: .init(), path: "a",
                group: "g", heldout: false
            ).longestDarkBeats
        }
        #expect(longest(lit) == 5)
        // Вспышка на 60 мс позже доли 5.0 в окне: серия рвется на две по 2 доли.
        #expect(longest(lit + [Self.flash(5.0 + 0.020 + 0.060)]) == 2)
        // На 80 мс позже уже мимо окна, и вспышка без захвата считается так же, как с захватом.
        #expect(longest(lit + [Self.flash(5.0 + 0.020 + 0.080, locked: false)]) == 5)
        #expect(longest([]) == 20)
        #expect(longest(beats.map { Self.flash($0 + 0.020, locked: false) }) == 0)
    }

    /// Темная серия после первого захвата не видит холодный старт: доли 0.5...10.0, захват опубликован
    /// на 3.0 с, вспышки с 3.5 с, кроме 6.0-7.0. Вся серия 6 долей (0.5-3.0), после захвата 3 (доля 3.0
    /// слышна на 3.02, уже после захвата, и темна, но ее серия 1). Без захвата значения нет.
    @Test func darkRunAfterFirstLockSkipsTheColdStart() {
        let beats = (1...20).map { Double($0) * 0.5 }
        let flashes = beats.filter { $0 >= 3.5 && !(6.0...7.0).contains($0) }.map { Self.flash($0 + 0.020) }
        let states = [
            OfflineBeatChain.State(time: 0, locked: false, bpm: nil, confidence: 0),
            OfflineBeatChain.State(time: 3.0, locked: true, bpm: 120, confidence: 0.8),
        ]
        func score(_ states: [OfflineBeatChain.State]) -> BeatEvaluation.FileScore {
            BeatEvaluation.score(
                result: Self.result(flashes: flashes, states: states), annotations: beats, duration: 10, options: .init(),
                path: "a", group: "g", heldout: false
            )
        }
        let locked = score(states)
        #expect(locked.longestDarkBeats == 6)
        #expect(locked.longestDarkBeatsAfterLock == 3)
        let never = score([states[0]])
        #expect(never.longestDarkBeats == 6 && never.longestDarkBeatsAfterLock == nil)
    }

    /// Смены захвата в минуту и потери захвата по причинам: состояния до конца файла, начальное
    /// состояние без захвата сменой не считается.
    @Test func lockFlipsAndUnlockReasonsComeFromStates() {
        let states = [
            OfflineBeatChain.State(time: 0, locked: false, bpm: nil, confidence: 0),
            OfflineBeatChain.State(time: 3, locked: true, bpm: 120, confidence: 0.8),
            OfflineBeatChain.State(time: 5, locked: false, bpm: 120, confidence: 0.2, unlockReason: .misses),
            OfflineBeatChain.State(time: 6, locked: true, bpm: 120, confidence: 0.8),
            OfflineBeatChain.State(time: 8, locked: false, bpm: 140, confidence: 0.4, unlockReason: .tempoSwitch),
            // Хвост рендера после конца файла не считается.
            OfflineBeatChain.State(time: 10.3, locked: true, bpm: 140, confidence: 0.8),
        ]
        let score = Self.score(Self.result(flashes: [], states: states))
        #expect(abs(score.lockFlipsPerMinute - 4 * 6) < 1e-9)
        #expect(score.unlocks == [.misses: 1, .tempoSwitch: 1])
        // Пропущенное начало не считается: от 5.5 с остаются две смены за 4.5 с.
        let skipped = Self.score(Self.result(flashes: [], states: states), options: .init(skipSeconds: 5.5))
        #expect(abs(skipped.lockFlipsPerMinute - 2 * 60 / 4.5) < 1e-9)
        #expect(skipped.unlocks == [.tempoSwitch: 1])
    }

    /// Сводка: медиана и 90-й процентиль самой длинной темной серии по файлам (ближайший ранг), среднее
    /// смен захвата в минуту, сумма потерь захвата по причинам.
    @Test func summaryReportsDarkRunsFlipsAndUnlocks() throws {
        let base = BeatEvaluation.score(
            result: Self.result(flashes: []), annotations: Self.beats, duration: Self.duration, options: .init(),
            path: "a", group: "g", heldout: false
        )
        let scores = (1...10).map { index -> BeatEvaluation.FileScore in
            var score = base
            score.longestDarkBeats = 11 - index
            score.lockFlipsPerMinute = Double(index)
            score.unlocks = index % 2 == 0 ? [.misses: 2] : [.phaseJump: 1, .tempoSwitch: 1]
            // Файлы 1...4 без захвата: в серию после захвата не входят.
            score.longestDarkBeatsAfterLock = index <= 4 ? nil : index
            return score
        }
        let summary = BeatEvaluation.summarize(name: "g", scores: scores)
        #expect(summary.darkRunMedian == 5 && summary.darkRunP90 == 9)
        #expect(abs(summary.lockFlipsPerMinute - 5.5) < 1e-12)
        // Серии после захвата 5...10: ранг ceil(0.5 * 6) = 3 это 7, ранг ceil(0.9 * 6) = 6 это 10.
        #expect(summary.darkAfterLockFiles == 6)
        #expect(summary.darkRunAfterLockMedian == 7 && summary.darkRunAfterLockP90 == 10)
        #expect(summary.unlocks == [.misses: 10, .phaseJump: 5, .tempoSwitch: 5])
        let empty = BeatEvaluation.summarize(name: "none", scores: [])
        #expect(empty.darkRunMedian == 0 && empty.darkRunP90 == 0 && empty.unlocks.isEmpty)
        #expect(empty.darkAfterLockFiles == 0 && empty.darkRunAfterLockMedian == 0 && empty.darkRunAfterLockP90 == 0)
        let row = BeatEvaluation.table(title: "t", summaries: [summary])
        // t/p/m: смена темпа, скачок фазы, промахи.
        #expect(row.contains("5/5/10"))
    }

    /// Четыре на пол 120 BPM через настоящую цепочку: вспышки лежат на долях, чуть раньше.
    @Test(.enabled(if: TestPlatform.isLinux))
    func steadyKicksScoreWell() async throws {
        let (result, scene) = await runOffCooperativePool {
            let scene = Drums.fourOnFloor(bpm: 120, seconds: 24, hats: .eighths)
            var config = OfflineBeatChain.Config(seed: 5)
            config.outputLatency = 0.020
            return (OfflineBeatChain.run(samples: scene.samples, sampleRate: scene.sampleRate, config: config), scene)
        }
        let score = BeatEvaluation.score(
            result: result, annotations: scene.beats.filter { $0 <= 24 }, duration: 24, options: .init(), path: "a",
            group: "g", heldout: false
        )
        #expect(try #require(score.lockedPrecision) > 0.9, "locked precision \(String(describing: score.lockedPrecision))")
        #expect(score.f > 0.8, "F \(score.f)")
        #expect(score.amlt > 0.8 && score.lockedCoverage > 0.7)
        let offset = try #require(score.meanOffsetMs)
        #expect(offset < 5 && offset > -45, "offset \(offset)")
    }

    // MARK: Возобновление, пары, записи владельца

    /// Сбросы на 2 и 5 с (задержка 20 мс, доли каждые 0.5 с). После первого (с захватом) вспышки на «и»:
    /// возобновление на «и», точность 2 с после сброса 0. После второго (без захвата) первая вспышка на
    /// доле, потом одна на «и»: возобновление частично на «и». Сброс за 1 с до конца не считается.
    @Test func resumeScoresTheFirstFlashesAfterEachReset() throws {
        var flashes: [OfflineBeatChain.Flash] = []
        // После сброса на 2 с: «и» на 2.75, 3.25, 3.75, 4.25 (с захватом с 3.25).
        for (index, time) in [2.75, 3.25, 3.75, 4.25].enumerated() { flashes.append(Self.flash(time + 0.020, locked: index > 0)) }
        // После сброса на 5 с: доля 5.5, «и» 5.75, доли 6.5, 7.0.
        for time in [5.5, 5.75, 6.5, 7.0] { flashes.append(Self.flash(time + 0.020, locked: false)) }
        var result = Self.result(flashes: flashes)
        result.resets = [
            OfflineBeatChain.Reset(time: 2, locked: true), OfflineBeatChain.Reset(time: 5, locked: false),
            OfflineBeatChain.Reset(time: 9, locked: true),
        ]
        let resume = BeatEvaluation.resume(result: result, annotations: Self.beats, duration: Self.duration, window: 0.07)
        #expect(resume.resets == 2 && resume.lockedAtReset == 1 && resume.withFlash == 2)
        #expect(resume.offBeat == 1 && resume.partlyOffBeat == 1 && resume.firstOn == 1)
        #expect(resume.delays.count == 2 && abs(resume.delays[0] - 0.75) < 1e-9 && abs(resume.delays[1] - 0.5) < 1e-9)
        // 2 с после сброса: 2.75, 3.25, 3.75 (все мимо) и 5.5, 5.75, 6.5 (две в долю).
        #expect(resume.flashes == 6 && resume.matched == 2)
        #expect(resume.lockedResetFlashes == 3 && resume.lockedResetMatched == 0)
        #expect(resume.relockedFlashes == 2 && resume.relockedMatched == 0)
        // Счет файла несет возобновления, сводка их складывает; без сбросов их нет.
        let score = Self.score(result)
        #expect(score.resume == resume)
        let summary = BeatEvaluation.summarize(name: "g", scores: [score, score, Self.score(Self.result(flashes: flashes))])
        #expect(summary.resume?.resets == 4 && summary.resume?.offBeat == 2)
        #expect(Self.score(Self.result(flashes: flashes)).resume == nil)
        let table = try #require(BeatEvaluation.resumeTable(title: "t", summaries: [summary]))
        #expect(table.contains("offBeat") && table.contains("relockLP"))
        #expect(BeatEvaluation.resumeTable(title: "t", summaries: [BeatEvaluation.summarize(name: "g", scores: [])]) == nil)
    }

    /// Пары: в каждой группе по порядку (0, 1), (2, 3), не больше заданного числа; группа с нечетным
    /// числом файлов теряет последний.
    @Test func pairsTakeConsecutiveFilesPerGroup() {
        func entry(_ name: String, _ group: String) -> EvalList.Entry {
            EvalList.Entry(wavPath: "/d/\(name).wav", annotationPath: "/a/\(name)", group: group, heldout: false)
        }
        let entries = [
            entry("pop.0", "pop"), entry("rock.0", "rock"), entry("pop.1", "pop"), entry("pop.2", "pop"), entry("rock.1", "rock"),
            entry("pop.3", "pop"), entry("pop.4", "pop"), entry("rock.2", "rock"),
        ]
        let pairs = EvalPairs.make(entries, perGroup: 4)
        #expect(pairs.map(\.name) == ["pop.0+pop.1", "pop.2+pop.3", "rock.0+rock.1"])
        #expect(EvalPairs.make(entries, perGroup: 1).map(\.name) == ["pop.0+pop.1", "rock.0+rock.1"])
        #expect(EvalPairs.make(entries, perGroup: 0).isEmpty)
        #expect(EvalPairs.clip([Float](repeating: 0, count: 100_000), sampleRate: 1_000).count == 29_500)
    }

    /// Счет B в склейке A + B: аннотации B сдвинуты на длину A, вспышки и захват A не в счете.
    @Test func secondTrackOfAPairIsScoredAlone() {
        // A: 10 с с вспышками мимо долей B; B: 10 с, вспышки на всех долях B.
        let offBeats = Self.beats.map { Self.flash($0 + 0.25 + 0.020) }
        let onBeats = Self.beats.map { Self.flash($0 + 10 + 0.020) }
        let states = [
            OfflineBeatChain.State(time: 0, locked: true, bpm: 120, confidence: 1),
            OfflineBeatChain.State(time: 15, locked: false, bpm: 120, confidence: 0),
        ]
        let warm = EvalPairs.scoreSecond(
            result: Self.result(flashes: offBeats + onBeats, states: states), firstDuration: 10, secondAnnotations: Self.beats,
            secondDuration: 10, options: .init(), path: "a+b", group: "g", heldout: false
        )
        #expect(warm.flashCount == 20 && warm.matched == 20 && warm.precision == 1)
        #expect(abs(warm.lockedCoverage - 0.5) < 1e-9)
        #expect(warm.annotationCount == 20)
    }

    /// Паузы с тишиной (`wave-eval --pause`): нули после каждых `every` секунд звука, кроме конца;
    /// моменты звука сдвигаются на все паузы до них, возобновления стоят в конце каждой паузы с захватом,
    /// который был перед ее началом.
    @Test func pausesInsertSilenceAndShiftBeats() {
        let samples = [Float](repeating: 1, count: 1_000)
        let paused = EvalPauses.insert(samples, sampleRate: 100, every: 3, length: 0.5)
        #expect(paused.cuts == [3, 6, 9])
        #expect(paused.samples.count == 1_150)
        #expect(paused.samples[299] == 1 && paused.samples[300] == 0 && paused.samples[349] == 0 && paused.samples[350] == 1)
        #expect(paused.samples[699] == 0 && paused.samples[700] == 1)
        #expect(EvalPauses.insert(samples, sampleRate: 100, every: 10, length: 0.5).cuts.isEmpty)

        #expect(EvalPauses.shift([1, 3, 5, 9.5], cuts: paused.cuts, length: 0.5) == [1, 3.5, 5.5, 11])

        let states = [
            OfflineBeatChain.State(time: 0, locked: false, bpm: nil, confidence: 0),
            OfflineBeatChain.State(time: 2.9, locked: true, bpm: 120, confidence: 0.9),
            OfflineBeatChain.State(time: 3.6, locked: false, bpm: 120, confidence: 0.4),
        ]
        let resets = EvalPauses.resets(cuts: paused.cuts, length: 0.5, states: states)
        #expect(resets == [
            OfflineBeatChain.Reset(time: 3.5, locked: true),
            OfflineBeatChain.Reset(time: 7, locked: false),
            OfflineBeatChain.Reset(time: 10.5, locked: false),
        ])
    }

    /// Записи владельца: вспышки на доле, на «и» и мимо, темнота с краями, без слияния и до слышимого
    /// конца звука; итоги по группам, объединениям и всем.
    @Test func ownerRecordingsCountOnHalfAndOther() throws {
        // Сетка на оси файла 1, 1.5, ..., 9.5; задержка 0.1 с, сдвиг -0.03 с.
        let grid = (2..<20).map { Double($0) * 0.5 }
        let flashes = [
            Self.flash(1.1 - 0.03), Self.flash(1.12),           // доля и вторая вспышка у той же доли
            Self.flash(1.35, locked: false),                    // «и»
            Self.flash(1.5),                                    // мимо (0.1 с до доли и середины)
            Self.flash(5.6),                                    // доля после 4.1 с темноты
            Self.flash(10.3),                                   // после слышимого конца 10.1 с
        ]
        let result = Self.result(
            flashes: flashes, states: [OfflineBeatChain.State(time: 0, locked: false, bpm: nil, confidence: 0),
                                       OfflineBeatChain.State(time: 5, locked: true, bpm: 120, confidence: 1)], latency: 0.1
        )
        let score = OwnerEvaluation.score(
            result: result, grid: grid, audioSeconds: 10, syncOffset: -0.03, window: 0.07, name: "r", group: "a"
        )
        #expect(score.flashes == 5 && score.on == 3 && score.half == 1 && score.other == 1)
        #expect(score.lockedFlashes == 4 && score.lockedOn == 3 && score.lockedHalf == 0)
        #expect(abs(try #require(score.precision) - 0.6) < 1e-12)
        #expect(abs(try #require(score.gridBPM) - 120) < 1e-9)
        #expect(abs(score.end - 10.1) < 1e-12)
        // Темнота 1.5-5.6 (4.1 с) и 5.6-10.1 (4.5 с).
        #expect(abs(score.darkSeconds - 8.6) < 1e-9 && abs(score.longestDark - 4.5) < 1e-9)
        #expect(abs(score.lockedShare - 5.1 / 10.1) < 1e-9)
        #expect(score.firstLock == 5 && score.resume == nil)

        var other = score
        other.name = "s"
        other.group = "b"
        let totals = OwnerEvaluation.totals([score, other, score], unions: [.init(name: "ab", groups: ["a", "b"])])
        #expect(totals.map(\.name) == ["a", "b", "ab", "TOTAL"])
        #expect(totals[0].flashes == 10 && totals[2].flashes == 15 && totals[3].on == 9)
        let table = OwnerEvaluation.table(recordings: [score, other], totals: totals)
        #expect(table.contains("half") && table.contains("TOTAL") && table.contains("0.600"))
    }

    /// Мягкий пульс записи: доля кадров с пульсом, всех и без захвата, и доля вершин пульса у онсетов
    /// анализа (широкополосных и бочки) в пределах окна; итоги складывают счетчики, а не доли.
    @Test func ownerSoftPulseShares() throws {
        var result = Self.result(flashes: [], latency: 0.1)
        result.renderedFrames = 100
        result.ambientFrames = 30
        result.unlockedFrames = 40
        result.ambientUnlockedFrames = 20
        result.onsets = [1.0, 2.0]
        result.kickOnsets = [3.0]
        // У онсета 1.05 и 2.95 (бочка), мимо 2.2 и 4.0.
        result.ambientPeaks = [1.05, 2.2, 2.95, 4.0]
        let grid = (2..<20).map { Double($0) * 0.5 }
        let score = OwnerEvaluation.score(
            result: result, grid: grid, audioSeconds: 10, syncOffset: 0, window: 0.07, name: "r", group: "a"
        )
        #expect(score.pulseShare == 0.3 && score.unlockedPulseShare == 0.5 && score.pulsePeaksOnOnsets == 0.5)
        var other = score
        other.pulseFrames = 300
        other.pulseVisible = 0
        other.unlockedFrames = 0
        other.unlockedPulseVisible = 0
        other.pulsePeaks = 0
        other.pulsePeaksNearOnset = 0
        let total = OwnerEvaluation.total(name: "t", scores: [score, other])
        #expect(total.pulseShare == 0.075 && total.unlockedPulseShare == 0.5 && total.pulsePeaksOnOnsets == 0.5)
        let empty = OwnerEvaluation.score(
            result: Self.result(flashes: []), grid: grid, audioSeconds: 10, syncOffset: 0, window: 0.07, name: "e", group: "a"
        )
        #expect(empty.pulseShare == nil && empty.unlockedPulseShare == nil && empty.pulsePeaksOnOnsets == nil)
        let table = OwnerEvaluation.table(recordings: [score], totals: [total])
        #expect(table.contains("pulse U") && table.contains("pk@on") && table.contains("0.075"))
    }

    /// Петля записи: звук подряд, сетка каждого повтора со сдвигом на длину звука.
    @Test func ownerLoopRepeatsAudioAndGrid() {
        #expect(OwnerEvaluation.looped([1, 2, 3], count: 3) == [1, 2, 3, 1, 2, 3, 1, 2, 3])
        #expect(OwnerEvaluation.looped([1, 2], count: 1) == [1, 2])
        #expect(OwnerEvaluation.loopedGrid([0.5, 1.5], duration: 2, count: 3) == [0.5, 1.5, 2.5, 3.5, 4.5, 5.5])
    }
}
