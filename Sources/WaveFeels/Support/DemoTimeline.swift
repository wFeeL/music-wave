import Foundation
import Synchronization
import WaveCore

/// Состояние острова на момент `time` прогона демо.
nonisolated struct DemoMoment: Sendable {
    let time: Double
    let frame: WaveFrame
    let motion: WaveMotion
    /// Свечение доли 0...1.
    let glow: Float
    /// «Вздох» 0...1.
    let pulse: Float
    /// Мягкий пульс 0...`BeatGlow.ambientCeiling` (`BeatGlow.ambient`).
    var ambient: Float = 0
}

/// Прогон демо по шагам через `StreamAnalyzer` и `BeatTracker` вне реального времени, момент
/// каждые 1/60 с: последний кадр анализа, свечение доли по расписанию трекера на этот момент
/// (ось потока, без задержек вывода и показа), «вздох» как у острова (по весу показа между
/// пружиной со свечением на 50 мс раньше и самим свечением, `BeatPulse.breath`) и мягкий пульс
/// (`BeatGlow.ambient`). После `mutedFrom` секунд звук обнуляется. Из него берут кадры снимки
/// (`SnapshotRenderer`) и живой предпросмотр во вкладке «Вид» (`PreviewPlayer`).
nonisolated struct DemoTimeline: Sendable {
    static let step = 1.0 / 60

    /// Сколько раз вызывался `load`: предпросмотр читает демо один раз за запуск.
    private static let loadCounter = Atomic<Int>(0)
    static var loadCountForTesting: Int { loadCounter.load(ordering: .relaxed) }

    /// Моменты через `step`, первый на `step`, последний на `duration`.
    let moments: [DemoMoment]

    /// Длина прогона, с: столько моментов, сколько в нем есть, по `step`.
    var duration: Double { Double(moments.count) * Self.step }

    init(samples: [Float], sampleRate: Double, duration: Double, mutedFrom: Double?) {
        let analyzer = StreamAnalyzer(sampleRate: sampleRate)
        var tracker = BeatTracker(framesPerSecond: analyzer.config.framesPerSecond)
        let size = analyzer.config.fftSize
        let hop = analyzer.config.hopSize
        let mutedIndex = mutedFrom.map { Int($0 * sampleRate) } ?? Int.max
        var motion = WaveMotion()
        var pulse = BeatPulse()
        var frame = WaveFrame.silent
        var window = [Float](repeating: 0, count: size)
        var nextEnd = size
        var moments: [DemoMoment] = []
        let count = duration.isFinite ? max(Int((duration / Self.step).rounded()), 1) : 1
        moments.reserveCapacity(count)

        for step in 1...count {
            let time = Double(step) * Self.step
            let end = Int(time * sampleRate)
            while nextEnd <= end {
                for offset in 0..<size {
                    let index = nextEnd - size + offset
                    window[offset] = index >= 0 && index < samples.count && index < mutedIndex ? samples[index] : 0
                }
                let result = window.withUnsafeBufferPointer {
                    analyzer.processHop(window: $0, endSample: nextEnd, settings: LevelSettings())
                }
                tracker.process(result)
                frame = result.frame
                frame.kickEnergy = tracker.ambientEnergy
                nextEnd += hop
            }
            let schedule = tracker.schedule
            let glow = BeatGlow.value(at: time, schedule: schedule, refreshPeriod: Self.step)
            let early = BeatGlow.value(at: time + AppModel.breathLead, schedule: schedule, refreshPeriod: Self.step)
            let spring = pulse.step(beat: early, dt: Self.step)
            motion.advance(layers: frame.layers, dt: Self.step)
            moments.append(DemoMoment(
                time: time, frame: frame, motion: motion, glow: glow,
                pulse: BeatPulse.breath(spring: spring, glow: glow, weight: schedule.weight),
                ambient: BeatGlow.ambient(at: time, info: schedule.ambient, frame: frame)
            ))
        }
        self.moments = moments
    }

    /// Готовые моменты, первый на `step`, через `step`; пустой список дает один тихий момент.
    /// Нужно тестам предпросмотра.
    init(moments: [DemoMoment]) {
        self.moments = moments.isEmpty
            ? [DemoMoment(time: Self.step, frame: .silent, motion: WaveMotion(), glow: 0, pulse: 0)]
            : moments
    }

    /// Момент на `time` секунд, по кругу: время за `duration` (и отрицательное) сворачивается
    /// в прогон. Берется последний момент не позже свернутого времени; до первого момента
    /// стоит последний, как будто прогон уже прошел круг.
    func moment(at time: Double) -> DemoMoment {
        let count = moments.count
        guard time.isFinite else { return moments[count - 1] }
        // Счет в шагах: миллионная доля шага гасит ошибку деления на 1/60, а остаток от целого
        // числа шагов не зависит от того, сколько кругов прошло.
        let ticks = (time / Self.step + 1e-6).rounded(.down).truncatingRemainder(dividingBy: Double(count))
        let index = Int(ticks) - 1
        return moments[(index % count + count) % count]
    }

    var last: DemoMoment { moments[moments.count - 1] }

    /// Пик свечения доли в промежутке: вспышка на сильной доле.
    func strongestBeat(in range: ClosedRange<Double>) -> DemoMoment {
        moments.filter { range.contains($0.time) }.max { $0.glow < $1.glow } ?? last
    }

    /// Самое слабое свечение в промежутке: музыка играет, вспышки нет.
    func calmest(in range: ClosedRange<Double>) -> DemoMoment {
        moments.filter { range.contains($0.time) }.min { $0.glow < $1.glow } ?? last
    }

    /// Файл `url` целиком (моно) одним прогоном во всю длину, вне главного актора.
    static func load(_ url: URL) async throws -> DemoTimeline {
        loadCounter.wrappingAdd(1, ordering: .relaxed)
        return try await Task.detached(priority: .utility) {
            let audio = try DemoAudioSource.loadMono(url)
            return DemoTimeline(
                samples: audio.samples, sampleRate: audio.sampleRate,
                duration: Double(audio.samples.count) / audio.sampleRate, mutedFrom: nil
            )
        }.value
    }
}
