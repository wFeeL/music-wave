import Testing
@testable import WaveCore

/// Счет свечения по режимам (`BeatEvaluation.glow`): место каждой вспышки, яркие и реактивные отдельно,
/// темнота и видимые кадры.
struct GlowEvaluationTests {
    private static let beats = (0..<20).map { 1.0 + Double($0) * 0.5 }

    private static func flash(_ time: Double, peak: Float, reactive: Bool = false) -> OfflineBeatChain.Flash {
        OfflineBeatChain.Flash(time: time, predicted: !reactive, locked: false, reactive: reactive, peak: peak)
    }

    @Test func placesStrongAndReactiveFlashes() {
        let flashes = [
            Self.flash(0.99, peak: 0.9), // на доле, яркая, -10 мс
            Self.flash(1.25, peak: 0.5, reactive: true), // на «и»
            Self.flash(1.62, peak: 0.4, reactive: true), // мимо
            Self.flash(2.02, peak: 0.45, reactive: true), // на доле, +20 мс
            Self.flash(2.75, peak: 0.7), // на «и», яркая
            Self.flash(8.0, peak: 1), // на доле, яркая
            Self.flash(30, peak: 1), // вне отрезка
        ]
        let score = BeatEvaluation.glow(
            flashes: flashes, beats: Self.beats, from: 0.7, to: 10.8, window: 0.07, frames: 100, visibleFrames: 40
        )
        #expect(score.flashes == 6 && score.on == 3 && score.half == 2 && score.other == 1)
        #expect(score.strong == 3 && score.strongOn == 2 && score.strongHalf == 1)
        #expect(score.reactive == 3 && score.reactiveOn == 1 && score.reactiveHalf == 1)
        #expect(abs((score.onOffsetMs ?? 0) - (-10 + 20 + 0) / 3) < 1e-6)
        #expect(abs((score.reactiveOnOffsetMs ?? 0) - 20) < 1e-6)
        // Темнота: 2.75 -> 8.0 (5.25 с) и 8.0 -> 10.8 (2.8 с).
        #expect(abs(score.darkSeconds - 8.05) < 1e-9)
        #expect(abs((score.darkShare ?? 0) - 8.05 / 10.1) < 1e-9)
        #expect(score.visibleShare == 0.4)
        #expect(score.onShare == 0.5 && score.beatOrHalfShare == 5.0 / 6 && score.strongPrecision == 2.0 / 3)

        var sum = score
        sum.add(score)
        #expect(sum.flashes == 12 && sum.darkSeconds == 2 * score.darkSeconds && sum.onOffsetMs == score.onOffsetMs)
    }

    /// GTZAN: счет свечения идет по отрезку размеченных долей, без слияния вспышек.
    @Test func fileScoreCarriesTheGlowScore() {
        let flashes = [Self.flash(1.02, peak: 0.9), Self.flash(1.04, peak: 0.5, reactive: true)]
        let result = OfflineBeatChain.Result(
            flashes: flashes, states: [], kickOnsets: [], predictedTimes: [], peakGlow: 1, outputLatency: 0.02,
            audibleFrames: 10, visibleFrames: 3
        )
        let file = BeatEvaluation.score(
            result: result, annotations: Self.beats, duration: 12, options: .init(), path: "a.wav", group: "g", heldout: false
        )
        #expect(file.flashCount == 1)
        #expect(file.glow.flashes == 2 && file.glow.on == 2 && file.glow.reactive == 1)
        #expect(abs(file.glow.seconds - (Self.beats.last! - Self.beats.first! + 0.6)) < 1e-9)
        let summary = BeatEvaluation.summarize(name: "g", scores: [file, file])
        #expect(summary.glow.flashes == 4 && summary.glow.visibleFrames == 6)
    }

    /// Источник вспышки (`OfflineBeatChain.startedEvent`): для долей и бочек правило 1.3 (самое позднее
    /// начавшееся событие, в том числе доля с яркостью 0), так что метки «По ритму» в журналах те же.
    /// Реактивное событие берется, если оно началось позже или если позднее событие сетки с яркостью 0.
    @Test func startedEventKeepsThe13RuleForGridAndKicks() {
        let kick = GlowEvent(id: BeatTracker.onsetIDFlag, time: 1.00, amplitude: 0.4, predicted: false)
        let silentBeat = GlowEvent(id: 7, time: 1.02, amplitude: 0, predicted: true)
        let beat = GlowEvent(id: 8, time: 1.02, amplitude: 0.8, predicted: true)
        let reactive = GlowEvent(id: BeatTracker.reactiveIDFlag, time: 1.01, amplitude: 0.3, predicted: false, reactive: true)
        func started(_ events: [GlowEvent]) -> GlowEvent? {
            let schedule = BeatSchedule(events: events, bpm: nil, period: nil, confidence: 0, locked: false)
            return OfflineBeatChain.startedEvent(in: schedule, by: 1.1, refreshPeriod: 1.0 / 30)
        }
        #expect(started([kick, silentBeat]) == silentBeat)
        #expect(started([kick, beat]) == beat)
        #expect(started([kick, silentBeat, reactive]) == reactive)
        #expect(started([kick, beat, reactive]) == beat)
        #expect(started([kick, reactive]) == reactive)
        #expect(started([GlowEvent(id: 9, time: 1.2, amplitude: 1, predicted: true)]) == nil)
    }
}

