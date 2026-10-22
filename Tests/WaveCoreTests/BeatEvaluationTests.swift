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
                lockedFlashCount: locked == nil ? 0 : 10, lockedMatched: Int((locked ?? 0) * 10),
                lockedPrecision: locked, precision: f, recall: f, f: f, meanOffsetMs: offset, cmlt: f, amlt: f,
                lockedCoverage: f, lockTime: nil, tempoBPM: nil
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
        #expect(BeatEvaluation.filter(scores, split: .tune).count == 3)
        #expect(BeatEvaluation.filter(scores, split: .heldout).map(\.group) == ["a"])
        #expect(BeatEvaluation.filter(scores, split: .all).count == 4)
        #expect(BeatEvaluation.summarize(name: "empty", scores: []).files == 0)
    }

    @Test func tablesMentionEveryRow() {
        let rows = BeatEvaluation.summaries(scores: [], unions: [])
        let text = BeatEvaluation.table(title: "t", summaries: rows)
        #expect(text.contains("TOTAL") && text.contains("lockedPrec") && text.hasPrefix("t\n"))
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
}
