import Foundation

/// WAV для записи ритма: RIFF/WAVE, PCM 16 бит, один канал, заголовок 44 байта. Читается
/// `WAVReader`.
public enum WAVWriter {
    public static func pcm16Mono(_ samples: [Int16], sampleRate: Int) -> Data {
        var bytes = header(sampleCount: samples.count, sampleRate: sampleRate)
        bytes.reserveCapacity(bytes.count + samples.count * 2)
        for sample in samples {
            append16(UInt16(bitPattern: sample), to: &bytes)
        }
        return Data(bytes)
    }

    /// Заголовок в 44 байта для `sampleCount` сэмплов.
    static func header(sampleCount: Int, sampleRate: Int) -> [UInt8] {
        let dataBytes = sampleCount * 2
        var bytes: [UInt8] = []
        bytes.reserveCapacity(44)
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
        return bytes
    }

    /// Пишет тот же файл, что `pcm16Mono`, но кусками по `chunkSamples` сэмплов: рядом с `samples`
    /// в памяти только один кусок, а не вторая копия всего звука (10 минут при 48 кГц это 58 МБ).
    /// Сначала временный файл рядом, затем он занимает место `url`; при ошибке временный файл
    /// удаляется.
    public static func write(_ samples: [Int16], sampleRate: Int, to url: URL, chunkSamples: Int = 65_536) throws {
        let manager = FileManager.default
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).part")
        guard manager.createFile(atPath: temporary.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            do {
                try handle.write(contentsOf: Data(header(sampleCount: samples.count, sampleRate: sampleRate)))
                let step = max(chunkSamples, 1)
                var start = 0
                while start < samples.count {
                    let end = min(start + step, samples.count)
                    var bytes: [UInt8] = []
                    bytes.reserveCapacity((end - start) * 2)
                    for index in start..<end {
                        append16(UInt16(bitPattern: samples[index]), to: &bytes)
                    }
                    try handle.write(contentsOf: Data(bytes))
                    start = end
                }
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
            try manager.moveItem(at: temporary, to: url)
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
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
