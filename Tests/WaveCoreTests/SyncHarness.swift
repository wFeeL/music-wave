import Foundation
@testable import WaveCore

/// Модель всей цепочки свечения с подставными часами (`beat-sync.md` 3.2) для синтетических сцен.
/// Сама цепочка живет в `OfflineBeatChain` (WaveCore); здесь она берет сэмплы сцены и приводит
/// результат к `SyncResult` с проверками тестов.
///
/// Все времена в `SyncResult` отсчитываются от первого сэмпла, а слышимое время момента сцены t это
/// `t + outputLatency`.
enum SyncHarness {
    typealias Config = OfflineBeatChain.Config

    static func run(scene: DrumScene, config: Config) -> SyncResult {
        SyncResult(OfflineBeatChain.run(samples: scene.samples, sampleRate: scene.sampleRate, config: config))
    }

    /// Один прогон анализа, показанный на `count` равномерно расставленных фазах рендера
    /// (`k / count` периода кадра): анализ от фазы рендера не зависит.
    static func run(scene: DrumScene, config: Config, renderPhases count: Int) -> [SyncResult] {
        OfflineBeatChain.run(samples: scene.samples, sampleRate: scene.sampleRate, config: config, renderPhases: count)
            .map(SyncResult.init)
    }
}

struct SyncResult: Sendable {
    typealias State = OfflineBeatChain.State

    init(_ chain: OfflineBeatChain.Result) {
        events = chain.flashes.map(\.time)
        lockTime = chain.lockTime
        tempoBPM = chain.tempoBPM
        states = chain.states
        outputLatency = chain.outputLatency
        predictedTimes = chain.predictedTimes
        peakGlow = chain.peakGlow
    }

    /// Моменты показа кадров со вспышкой, секунды от первого сэмпла.
    var events: [Double]
    /// Первая публикация с захватом.
    var lockTime: Double?
    /// Темп последней публикации.
    var tempoBPM: Double?
    var states: [State]
    var outputLatency: Double
    /// Предсказанные доли, как их видел рендер до начала вспышки (без квантования кадрами), секунды
    /// от первого сэмпла.
    var predictedTimes: [Double]
    /// Наибольшее свечение за прогон.
    var peakGlow: Float

    /// Слышимые моменты для моментов сцены.
    func audible(_ times: [Double]) -> [Double] {
        times.map { $0 + outputLatency }
    }

    /// F-мера вспышек против `reference` (слышимые моменты) при взаимно однозначном жадном
    /// сопоставлении: пары в пределах `tolerance` берутся от самой близкой. Учитываются вспышки и
    /// эталоны с момента `from`.
    func fMeasure(reference: [Double], tolerance: Double, from: Double) -> Double {
        let seen = events.filter { $0 >= from }
        let truth = reference.filter { $0 >= from }
        guard !seen.isEmpty || !truth.isEmpty else { return 1 }
        let pairs = Self.match(seen, truth, tolerance: tolerance)
        return 2 * Double(pairs.count) / Double(seen.count + truth.count)
    }

    /// Средний сдвиг и его стандартное отклонение по сопоставленным парам (вспышка минус слышимый
    /// момент), с момента `from`.
    func offsets(reference: [Double], from: Double, tolerance: Double = 0.1) -> (mean: Double, sd: Double) {
        Self.meanAndSD(offsetValues(reference: reference, from: from, tolerance: tolerance))
    }

    /// Сдвиги сопоставленных пар по отдельности (для объединения нескольких прогонов).
    func offsetValues(reference: [Double], from: Double, tolerance: Double = 0.1) -> [Double] {
        Self.pairOffsets(events, reference: reference, from: from, tolerance: tolerance)
    }

    /// Сдвиги предсказанных долей (без квантования кадрами) от `reference` с момента `from`.
    func predictedOffsets(reference: [Double], from: Double, tolerance: Double = 0.1) -> (mean: Double, sd: Double) {
        Self.meanAndSD(Self.pairOffsets(predictedTimes, reference: reference, from: from, tolerance: tolerance))
    }

    private static func pairOffsets(_ times: [Double], reference: [Double], from: Double, tolerance: Double) -> [Double] {
        match(times.filter { $0 >= from }, reference.filter { $0 >= from }, tolerance: tolerance).map { $0.seen - $0.truth }
    }

    static func meanAndSD(_ differences: [Double]) -> (mean: Double, sd: Double) {
        guard !differences.isEmpty else { return (.nan, .nan) }
        let mean = differences.reduce(0, +) / Double(differences.count)
        let variance = differences.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(differences.count)
        return (mean, variance.squareRoot())
    }

    /// Число вспышек в отрезке.
    func events(in range: ClosedRange<Double>) -> Int {
        events.count(where: { range.contains($0) })
    }

    /// Первый момент не раньше `after`, когда опубликован захват с темпом, удовлетворяющим `tempo`.
    func lockTime(after: Double, tempo: (Double) -> Bool = { _ in true }) -> Double? {
        states.first { $0.time >= after && $0.locked && ($0.bpm.map(tempo) ?? false) }?.time
    }

    private static func match(_ seen: [Double], _ truth: [Double], tolerance: Double) -> [(seen: Double, truth: Double)] {
        let sortedTruth = truth.sorted()
        var candidates: [(distance: Double, seen: Int, truth: Int)] = []
        for (i, time) in seen.enumerated() {
            var low = 0
            var high = sortedTruth.count
            while low < high {
                let mid = (low + high) / 2
                if sortedTruth[mid] < time - tolerance { low = mid + 1 } else { high = mid }
            }
            var j = low
            while j < sortedTruth.count, sortedTruth[j] <= time + tolerance {
                candidates.append((abs(sortedTruth[j] - time), i, j))
                j += 1
            }
        }
        candidates.sort { $0.distance < $1.distance }
        var usedSeen = Set<Int>()
        var usedTruth = Set<Int>()
        var pairs: [(seen: Double, truth: Double)] = []
        for candidate in candidates where !usedSeen.contains(candidate.seen) && !usedTruth.contains(candidate.truth) {
            usedSeen.insert(candidate.seen)
            usedTruth.insert(candidate.truth)
            pairs.append((seen[candidate.seen], sortedTruth[candidate.truth]))
        }
        return pairs
    }
}
