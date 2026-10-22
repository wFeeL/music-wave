import Foundation

/// Задержка вывода устройства в кадрах, как ее сообщает Core Audio.
public struct OutputLatency: Sendable, Equatable {
    public var deviceFrames: UInt32
    public var streamFrames: UInt32
    public var safetyOffsetFrames: UInt32
    public var bufferFrames: UInt32
    public var sampleRate: Double
    public var isBluetooth: Bool

    public init(
        deviceFrames: UInt32,
        streamFrames: UInt32,
        safetyOffsetFrames: UInt32,
        bufferFrames: UInt32,
        sampleRate: Double,
        isBluetooth: Bool
    ) {
        self.deviceFrames = deviceFrames
        self.streamFrames = streamFrames
        self.safetyOffsetFrames = safetyOffsetFrames
        self.bufferFrames = bufferFrames
        self.sampleRate = sampleRate
        self.isBluetooth = isBluetooth
    }
}

public enum LatencyMode: Codable, Sendable, Equatable {
    case auto
    case manual(milliseconds: Int)
}

/// Задержка показа визуализации, чтобы картинка совпадала со звуком из динамиков.
public enum LatencyCalculator {
    public static let bluetoothExtraMs = 40
    public static let maxMilliseconds = 500

    /// Размер окна анализа, половина которого уже запаздывает относительно звука.
    private static let analysisWindowFrames = 1024.0
    /// Один кадр отрисовки при 60 Гц.
    private static let renderFrameMs = 16.7

    public static func delayMilliseconds(_ latency: OutputLatency, mode: LatencyMode) -> Int {
        switch mode {
        case .manual(let milliseconds):
            return clamp(milliseconds)
        case .auto:
            guard latency.sampleRate > 0 else { return 0 }
            let frames = Double(latency.deviceFrames) + Double(latency.streamFrames)
                + Double(latency.safetyOffsetFrames) + Double(latency.bufferFrames)
            var ms = frames / latency.sampleRate * 1000
            if latency.isBluetooth { ms += Double(bluetoothExtraMs) }
            ms -= analysisWindowFrames / latency.sampleRate * 1000 + renderFrameMs
            return clamp(Int(ms.rounded()))
        }
    }

    public static func delayFrames(milliseconds: Int, sampleRate: Double) -> Int {
        Int((Double(milliseconds) * sampleRate / 1000).rounded())
    }

    private static func clamp(_ milliseconds: Int) -> Int {
        min(max(milliseconds, 0), maxMilliseconds)
    }
}
