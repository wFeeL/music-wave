/// Где во входе агрегатного устройства потоки tap. Агрегат отдает сначала входные потоки
/// подустройства (микрофон AirPods или гарнитуры), за ними потоки tap до конца списка.
public enum TapStreamLayout {
    /// Индекс первого потока tap или `nil`, если потоки tap нельзя надежно отделить от входов
    /// подустройства: тогда захват не запускается, чтобы не сводить микрофон.
    ///
    /// Сначала с конца списка набираются потоки, пока их каналы не дадут ровно `tapChannels`.
    /// Если так не выходит (формат tap неизвестен или каналы не сходятся), граница берется из
    /// `subDeviceInputStreams`, когда оно известно.
    ///
    /// - Parameters:
    ///   - channels: каналов в каждом входном потоке агрегата, по порядку.
    ///   - subDeviceInputStreams: входных потоков у подустройств; `nil`, если не прочиталось.
    ///   - tapChannels: каналов в формате tap; 0, если формат неизвестен.
    public static func firstTapStream(channels: [Int], subDeviceInputStreams: Int?, tapChannels: Int) -> Int? {
        guard !channels.isEmpty else { return nil }
        if tapChannels > 0 {
            var sum = 0
            for index in channels.indices.reversed() {
                sum += max(channels[index], 0)
                if sum == tapChannels {
                    // Потоки tap не могут начинаться среди входов подустройства.
                    if let subDevice = subDeviceInputStreams, index < subDevice { break }
                    return index
                }
                if sum > tapChannels { break }
            }
        }
        if let subDevice = subDeviceInputStreams, subDevice >= 0, subDevice < channels.count {
            return subDevice
        }
        return nil
    }
}
