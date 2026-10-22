import AVFoundation
import CoreAudio
import Foundation
import Observation
import QuartzCore
import WaveCore

/// Метроном калибровки «Сдвига синхронизации»: щелчки 100 BPM на устройстве вывода по умолчанию.
///
/// `AVAudioEngine` и `AVAudioPlayerNode` живут, пока открыт лист калибровки (`start()` и `stop()`).
/// Щелчок 10 мс: затухающий синус 1.5 кГц, на первой доле такта 2 кГц. Каждый щелчок ставится в
/// очередь плеера на свое время хоста (`AVAudioTime(hostTime:)`) по сетке `MetronomeSchedule`:
/// таймер раз в 100 мс добавляет щелчки, которые начнутся в ближайшие 1.5 с, так что впереди всегда
/// 2-3 щелчка. Колбэков завершения нет: все вызовы идут на главном акторе.
///
/// Остановившийся сам движок (сменилась частота устройства) собирается заново на той же сетке;
/// не собрался: метроном молчит, свечения тоже нет, а `failed` сообщает об этом листу.
@MainActor
@Observable
final class Metronome {
    /// Длина щелчка, с.
    static let clickDuration = 0.010
    /// Постоянная спада щелчка, с: к концу щелчка синус гаснет до 2 %.
    static let clickDecay = 0.0025
    /// Последняя миллисекунда щелчка сводится к нулю, чтобы конец не щелкал сам.
    static let fadeOut = 0.001
    static let clickFrequency = 1500.0
    static let accentFrequency = 2000.0
    static let clickVolume: Float = 0.5
    static let accentVolume: Float = 0.6
    /// Как часто очередь плеера пополняется.
    static let refillInterval: Duration = .milliseconds(100)

    /// Движок не запустился или не собрался заново: щелчков нет. Единственное наблюдаемое свойство.
    private(set) var failed = false
    /// Сетка щелчков; `nil`, пока метроном не идет.
    @ObservationIgnored private(set) var schedule: MetronomeSchedule?
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var player: AVAudioPlayerNode?
    @ObservationIgnored private var click: AVAudioPCMBuffer?
    @ObservationIgnored private var accent: AVAudioPCMBuffer?
    /// Первый щелчок, еще не поставленный в очередь плеера.
    @ObservationIgnored private var nextClick = 0
    @ObservationIgnored private var refillTask: Task<Void, Never>?

    /// Запускает движок и щелчки: первый через `MetronomeSchedule.startDelay`.
    func start() {
        guard schedule == nil else { return }
        guard startEngine() else {
            failed = true
            return
        }
        failed = false
        schedule = MetronomeSchedule(start: CACurrentMediaTime() + MetronomeSchedule.startDelay)
        nextClick = 0
        refill()
        refillTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Metronome.refillInterval)
                guard let self else { return }
                self.refill()
            }
        }
    }

    /// Останавливает щелчки и разбирает движок.
    func stop() {
        refillTask?.cancel()
        refillTask = nil
        schedule = nil
        tearDownEngine()
    }

    /// Расписание свечения на кадр, показанный в момент `time` (секунды хоста): щелчки плюс задержка
    /// вывода и сдвиг синхронизации. Пустое, пока метроном не идет.
    func glowSchedule(at time: Double, outputLatency: Double, offsetMs: Int) -> BeatSchedule {
        schedule?.beatSchedule(at: time, outputLatency: outputLatency, offsetMs: offsetMs) ?? .empty
    }

    // MARK: - Движок

    /// Собирает плеер на смесителе движка в формате устройства вывода и запускает движок.
    private func startEngine() -> Bool {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard rate > 0, rate.isFinite,
              let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let click = Self.clickBuffer(format: format, frequency: Self.clickFrequency, volume: Self.clickVolume),
              let accent = Self.clickBuffer(format: format, frequency: Self.accentFrequency, volume: Self.accentVolume)
        else {
            Self.log("метроном: нет формата устройства вывода")
            return false
        }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            Self.log("метроном: движок не запустился: \(error.localizedDescription)")
            return false
        }
        player.play()
        self.engine = engine
        self.player = player
        self.click = click
        self.accent = accent
        return true
    }

    private func tearDownEngine() {
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        click = nil
        accent = nil
    }

    /// Ставит в очередь щелчки до горизонта. Движок, остановившийся сам, собирается заново: старая
    /// очередь пропала вместе с ним, поэтому щелчки ставятся с ближайшего, до которого еще успеть.
    private func refill() {
        guard let schedule else { return }
        if let engine, !engine.isRunning {
            tearDownEngine()
            guard startEngine() else {
                stop()
                failed = true
                return
            }
            nextClick = 0
        }
        guard let player, let click, let accent else { return }
        let due = schedule.clicksToQueue(from: nextClick, now: CACurrentMediaTime())
        for index in due {
            let nanoseconds = UInt64((schedule.clickTime(index) * 1_000_000_000).rounded())
            let time = AVAudioTime(hostTime: AudioConvertNanosToHostTime(nanoseconds))
            let buffer = MetronomeSchedule.isAccent(index) ? accent : click
            player.scheduleBuffer(buffer, at: time, options: [], completionHandler: nil)
        }
        nextClick = due.upperBound
    }

    private static func log(_ message: String) {
        Log.audio.error("\(message, privacy: .public)")
        Log.file(message)
    }

    // MARK: - Звук

    /// Щелчок `clickDuration`: синус `frequency` с экспоненциальным спадом и сведением к нулю в конце.
    private static func clickBuffer(format: AVAudioFormat, frequency: Double, volume: Float) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        let frames = Int((rate * clickDuration).rounded())
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        let fadeFrames = max(rate * fadeOut, 1)
        for frame in 0..<frames {
            let t = Double(frame) / rate
            let fade = min(Double(frames - frame) / fadeFrames, 1)
            let sample = Float(sin(2 * Double.pi * frequency * t) * exp(-t / clickDecay) * fade) * volume
            for channel in 0..<Int(format.channelCount) {
                channels[channel][frame] = sample
            }
        }
        return buffer
    }
}
