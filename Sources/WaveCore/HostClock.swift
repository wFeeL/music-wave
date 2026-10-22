import Foundation

/// Время хоста сэмпла потока (`beat-sync.md` 2.2, пункт 1): `H(n) = h_anchor + (n - n_anchor) / fs`.
///
/// Метки приходят из IOProc (номер первого сэмпла блока и `inInputTime.mHostTime` в секундах) и
/// дрожат. Первая метка задает линию, каждая следующая сдвигает ее на 0.05 ошибки предсказания, так
/// что дрожание почти не проходит, а медленный уход частоты отслеживается. Ошибка больше 50 мс
/// (сон, смена устройства, скачок часов) ставит линию заново по метке.
public struct HostClock: Sendable {
    /// Доля ошибки предсказания, на которую метка сдвигает линию.
    public static let correctionGain = 0.05
    /// Ошибка в секундах, выше которой линия ставится заново.
    public static let resyncThreshold = 0.05

    public private(set) var sampleRate: Double
    private var anchorSample: Int?
    private var anchorHost = 0.0

    public init(sampleRate: Double) {
        precondition(sampleRate > 0, "sampleRate must be positive")
        self.sampleRate = sampleRate
    }

    /// Метка: сэмпл `sampleIndex` был у хоста в момент `hostSeconds`.
    public mutating func anchor(sampleIndex: Int, hostSeconds: Double) {
        guard let predicted = hostTime(ofSample: sampleIndex) else {
            anchorSample = sampleIndex
            anchorHost = hostSeconds
            return
        }
        let error = hostSeconds - predicted
        // Якорь переносится на этот сэмпл, чтобы разность номеров не росла и не теряла точность.
        anchorSample = sampleIndex
        anchorHost = abs(error) > Self.resyncThreshold ? hostSeconds : predicted + Self.correctionGain * error
    }

    /// Время хоста в секундах для сэмпла `index`, `nil` до первой метки.
    public func hostTime(ofSample index: Int) -> Double? {
        guard let anchorSample else { return nil }
        return anchorHost + Double(index - anchorSample) / sampleRate
    }

    /// Новый поток (смена устройства или частоты): до следующей метки времени нет.
    public mutating func reset(sampleRate: Double) {
        precondition(sampleRate > 0, "sampleRate must be positive")
        self.sampleRate = sampleRate
        anchorSample = nil
        anchorHost = 0
    }
}
