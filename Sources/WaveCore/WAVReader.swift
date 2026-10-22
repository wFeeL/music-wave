import Foundation

/// Чтение WAV из памяти в моно `Float` для офлайн-прогонов (`OfflineBeatChain`, `wave-eval`).
///
/// Понимает RIFF/WAVE с PCM 16, 24 и 32 бита (целые) и 32 бита с плавающей точкой, один или два
/// канала; формат `WAVE_FORMAT_EXTENSIBLE` принимается, если его подформат PCM или float. Два канала
/// сводятся в моно средним. Целые нормируются к -1...1 делением на 2^(бит−1). Неизвестные куски
/// пропускаются (с учетом выравнивания на четный байт). Размер куска `data` 0xFFFFFFFF (поток без
/// известной длины) означает "до конца файла"; неполный последний кадр отбрасывается.
public enum WAVReader {
    public enum Error: Swift.Error, Equatable {
        /// Нет заголовка `RIFF` или `WAVE`.
        case notWAV
        /// Файл обрывается внутри заголовка или куска.
        case truncated
        /// Нет куска `fmt `.
        case missingFormat
        /// Нет куска `data`.
        case missingData
        /// Не PCM 16/24/32 и не float 32 (код формата и разрядность).
        case unsupportedFormat(tag: Int, bits: Int)
        /// Не один и не два канала.
        case unsupportedChannelCount(Int)
        /// Нулевая частота дискретизации.
        case invalidSampleRate
    }

    private static let pcm = 1
    private static let float = 3
    private static let extensible = 0xFFFE

    public static func read(_ data: Data) throws -> (samples: [Float], sampleRate: Double) {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, bytes[0..<4].elementsEqual("RIFF".utf8), bytes[8..<12].elementsEqual("WAVE".utf8) else {
            throw Error.notWAV
        }

        var format: (tag: Int, channels: Int, rate: Int, bits: Int)?
        var payload: ArraySlice<UInt8>?
        var offset = 12
        while offset < bytes.count {
            guard offset + 8 <= bytes.count else { throw Error.truncated }
            let id = bytes[offset..<offset + 4]
            let declared = Int(le32(bytes, offset + 4))
            let start = offset + 8
            let isData = id.elementsEqual("data".utf8)
            // Поток без известной длины: данные до конца файла.
            let size = isData && declared == 0xFFFF_FFFF ? bytes.count - start : declared
            guard start + size <= bytes.count else { throw Error.truncated }

            if id.elementsEqual("fmt ".utf8) {
                guard size >= 16 else { throw Error.truncated }
                var tag = Int(le16(bytes, start))
                if tag == extensible {
                    guard size >= 26 else { throw Error.truncated }
                    tag = Int(le16(bytes, start + 24))
                }
                format = (tag, Int(le16(bytes, start + 2)), Int(le32(bytes, start + 4)), Int(le16(bytes, start + 14)))
            } else if isData {
                payload = bytes[start..<start + size]
                if format != nil { break }
            }
            offset = start + size + (size & 1)
        }

        guard let format else { throw Error.missingFormat }
        guard let payload else { throw Error.missingData }
        guard format.channels == 1 || format.channels == 2 else { throw Error.unsupportedChannelCount(format.channels) }
        guard format.rate > 0 else { throw Error.invalidSampleRate }
        let supported = (format.tag == pcm && [16, 24, 32].contains(format.bits)) || (format.tag == float && format.bits == 32)
        guard supported else { throw Error.unsupportedFormat(tag: format.tag, bits: format.bits) }

        let width = format.bits / 8
        let frames = payload.count / (width * format.channels)
        var samples = [Float](repeating: 0, count: frames)
        let base = payload.startIndex
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<format.channels {
                sum += sample(bytes, at: base + (frame * format.channels + channel) * width, tag: format.tag, bits: format.bits)
            }
            samples[frame] = format.channels == 2 ? sum / 2 : sum
        }
        return (samples, Double(format.rate))
    }

    private static func sample(_ bytes: [UInt8], at index: Int, tag: Int, bits: Int) -> Float {
        switch (tag, bits) {
        case (pcm, 16):
            return Float(Int16(bitPattern: le16(bytes, index))) / 32_768
        case (pcm, 24):
            let raw = Int32(bytes[index]) | Int32(bytes[index + 1]) << 8 | Int32(bytes[index + 2]) << 16
            // Расширение знака с 24 до 32 бит.
            return Float((raw << 8) >> 8) / 8_388_608
        case (pcm, _):
            return Float(Int32(bitPattern: le32(bytes, index))) / 2_147_483_648
        default:
            return Float(bitPattern: le32(bytes, index))
        }
    }

    private static func le16(_ bytes: [UInt8], _ index: Int) -> UInt16 {
        UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
    }

    private static func le32(_ bytes: [UInt8], _ index: Int) -> UInt32 {
        UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2]) << 16 | UInt32(bytes[index + 3]) << 24
    }
}
