import AVFoundation
import Foundation
import WaveCore

enum DemoAudioError: Error, CustomStringConvertible {
    case emptyFile(URL)
    case unsupportedFormat(URL)

    var description: String {
        switch self {
        case .emptyFile(let url): "пустой файл \(url.lastPathComponent)"
        case .unsupportedFormat(let url): "неподдерживаемый формат \(url.lastPathComponent)"
        }
    }
}

/// Звук из файла вместо tap: файл целиком в памяти (моно), таймер раз в 10 мс пишет в кольцо
/// столько сэмплов, сколько прошло по часам, по кругу. Никогда не работает одновременно с tap.
nonisolated final class DemoAudioSource: @unchecked Sendable {
    let sampleRate: Double

    private let ring: SampleRingBuffer
    private let samples: [Float]
    private let queue = DispatchQueue(label: "com.wfeels.wavefeels.demo", qos: .userInteractive)

    // Только на queue.
    private var timer: DispatchSourceTimer?
    private var startNanos: UInt64 = 0
    private var framesWritten = 0
    private var position = 0

    init(ring: SampleRingBuffer, file: URL) throws {
        let (samples, sampleRate) = try Self.loadMono(file)
        self.ring = ring
        self.samples = samples
        self.sampleRate = sampleRate
    }

    /// Файл целиком в память, моно (среднее каналов), и его частота дискретизации.
    static func loadMono(_ file: URL) throws -> (samples: [Float], sampleRate: Double) {
        let audioFile = try AVAudioFile(forReading: file)
        let format = audioFile.processingFormat
        let length = AVAudioFrameCount(clamping: audioFile.length)
        guard length > 0 else { throw DemoAudioError.emptyFile(file) }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: length) else {
            throw DemoAudioError.unsupportedFormat(file)
        }
        try audioFile.read(into: buffer)
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0, format.channelCount > 0 else {
            throw DemoAudioError.unsupportedFormat(file)
        }

        let frames = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        let stride = buffer.stride
        var mono = [Float](repeating: 0, count: frames)
        for channel in 0..<channels {
            let data = channelData[channel]
            for frame in 0..<frames {
                mono[frame] += data[frame * stride]
            }
        }
        let scale = 1 / Float(channels)
        for frame in 0..<frames {
            mono[frame] *= scale
        }
        return (mono, format.sampleRate)
    }

    func start() {
        queue.sync {
            guard self.timer == nil else { return }
            self.startNanos = DispatchTime.now().uptimeNanoseconds
            self.framesWritten = 0
            let timer = DispatchSource.makeTimerSource(flags: [], queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in
                self?.tick()
            }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.sync {
            self.timer?.cancel()
            self.timer = nil
        }
    }

    /// На queue.
    private func tick() {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startNanos) / 1_000_000_000
        let target = Int(elapsed * sampleRate)
        var pending = target - framesWritten
        guard pending > 0 else { return }
        // После долгой задержки таймера не догонять больше секунды.
        let maxBurst = max(Int(sampleRate), 1)
        if pending > maxBurst {
            framesWritten = target - maxBurst
            pending = maxBurst
        }
        samples.withUnsafeBufferPointer { all in
            while pending > 0 {
                let chunk = min(pending, all.count - position)
                ring.write(UnsafeBufferPointer(rebasing: all[position..<(position + chunk)]))
                position = (position + chunk) % all.count
                pending -= chunk
                framesWritten += chunk
            }
        }
    }
}
