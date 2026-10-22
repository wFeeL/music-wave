import Foundation

/// WAV для записи ритма: RIFF/WAVE, PCM 16 бит, один канал, заголовок 44 байта. Читается
/// `WAVReader`.
public enum WAVWriter {
    public static func pcm16Mono(_ samples: [Int16], sampleRate: Int) -> Data {
        let dataBytes = samples.count * 2
        var bytes: [UInt8] = []
        bytes.reserveCapacity(44 + dataBytes)
        bytes += Array("RIFF".utf8)
        append32(UInt32(truncatingIfNeeded: 36 + dataBytes), to: &bytes)
        bytes += Array("WAVE".utf8)
        bytes += Array("fmt ".utf8)
        append32(16, to: &bytes)
        append16(1, to: &bytes)
        append16(1, to: &bytes)
        append32(UInt32(truncatingIfNeeded: sampleRate), to: &bytes)
        append32(UInt32(truncatingIfNeeded: sampleRate * 2), to: &bytes)
        append16(2, to: &bytes)
        append16(16, to: &bytes)
        bytes += Array("data".utf8)
        append32(UInt32(truncatingIfNeeded: dataBytes), to: &bytes)
        for sample in samples {
            append16(UInt16(bitPattern: sample), to: &bytes)
        }
        return Data(bytes)
    }

    private static func append16(_ value: UInt16, to bytes: inout [UInt8]) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private static func append32(_ value: UInt32, to bytes: inout [UInt8]) {
        for shift in stride(from: 0, to: 32, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }
}
