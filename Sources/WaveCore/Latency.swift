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

/// Задержка вывода и показа: по ним кадры и свечение ставятся на время, когда звук слышен.
public enum LatencyCalculator {
    /// Наибольшая ручная задержка вывода, миллисекунды.
    public static let maxMilliseconds = 500

    /// Прибавка Bluetooth к задержке вывода, секунды.
    public static let bluetoothExtra = 0.040
    /// Наибольшая задержка вывода, секунды.
    public static let maxOutputLatency = 0.5

    /// Задержка вывода `L_out` в секундах (`beat-sync.md` 2.7): через сколько звук блока доходит
    /// до слушателя. Авто: `(device + stream + safetyOffset + buffer) / sampleRate` плюс 0.040 для
    /// Bluetooth, 0 без частоты. Вручную: миллисекунды / 1000. Итог в пределах `0...0.5`.
    public static func outputLatency(_ latency: OutputLatency, mode: LatencyMode) -> Double {
        let seconds: Double
        switch mode {
        case .manual(let milliseconds):
            seconds = Double(milliseconds) / 1000
        case .auto:
            guard latency.sampleRate > 0, latency.sampleRate.isFinite else { return 0 }
            let frames = Double(latency.deviceFrames) + Double(latency.streamFrames)
                + Double(latency.safetyOffsetFrames) + Double(latency.bufferFrames)
            seconds = frames / latency.sampleRate + (latency.isBluetooth ? bluetoothExtra : 0)
        }
        return min(max(seconds, 0), maxOutputLatency)
    }

    /// Насколько кадр показывается позже момента отрисовки: два периода обновления экрана
    /// (задержка компоновщика).
    public static func presentationLead(refreshPeriod: Double) -> Double {
        2 * refreshPeriod
    }
}
