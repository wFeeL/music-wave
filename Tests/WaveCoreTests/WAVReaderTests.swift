import Foundation
import Testing
@testable import WaveCore

struct WAVReaderTests {
    private static func le16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }
    private static func le32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }

    private static func chunk(_ id: String, _ body: [UInt8]) -> [UInt8] {
        Array(id.utf8) + le32(UInt32(body.count)) + body + (body.count % 2 == 1 ? [0] : [])
    }

    private static func fmt(tag: UInt16, channels: UInt16, rate: UInt32, bits: UInt16) -> [UInt8] {
        let align = channels * bits / 8
        return chunk("fmt ", le16(tag) + le16(channels) + le32(rate) + le32(rate * UInt32(align)) + le16(align) + le16(bits))
    }

    private static func wav(_ chunks: [UInt8]...) -> Data {
        let body = Array("WAVE".utf8) + chunks.flatMap { $0 }
        return Data(Array("RIFF".utf8) + le32(UInt32(body.count)) + body)
    }

    private static func int16(_ values: [Int16]) -> [UInt8] {
        values.flatMap { le16(UInt16(bitPattern: $0)) }
    }

    @Test func pcm16Mono() throws {
        let data = Self.wav(Self.fmt(tag: 1, channels: 1, rate: 44_100, bits: 16), Self.chunk("data", Self.int16([0, 16_384, -32_768, 32_767])))
        let (samples, rate) = try WAVReader.read(data)
        #expect(rate == 44_100)
        #expect(samples == [0, 0.5, -1, 32_767.0 / 32_768])
    }

    @Test func pcm16StereoIsAveraged() throws {
        let data = Self.wav(Self.fmt(tag: 1, channels: 2, rate: 48_000, bits: 16), Self.chunk("data", Self.int16([16_384, 0, -16_384, -16_384, 8_192, 24_576])))
        let (samples, rate) = try WAVReader.read(data)
        #expect(rate == 48_000)
        #expect(samples == [0.25, -0.5, 0.5])
    }

    @Test func pcm24SignExtends() throws {
        // 0x400000 = 0.5, 0xC00000 = -0.5, 0x800000 = -1.
        let body: [UInt8] = [0x00, 0x00, 0x40, 0x00, 0x00, 0xC0, 0x00, 0x00, 0x80]
        let (samples, _) = try WAVReader.read(Self.wav(Self.fmt(tag: 1, channels: 1, rate: 22_050, bits: 24), Self.chunk("data", body)))
        #expect(samples == [0.5, -0.5, -1])
    }

    @Test func pcm32() throws {
        let values: [Int32] = [0, 1 << 30, Int32.min]
        let body = values.flatMap { Self.le32(UInt32(bitPattern: $0)) }
        let (samples, _) = try WAVReader.read(Self.wav(Self.fmt(tag: 1, channels: 1, rate: 8_000, bits: 32), Self.chunk("data", body)))
        #expect(samples == [0, 0.5, -1])
    }

    @Test func float32() throws {
        let values: [Float] = [0.25, -0.75, 1]
        let body = values.flatMap { Self.le32($0.bitPattern) }
        let (samples, rate) = try WAVReader.read(Self.wav(Self.fmt(tag: 3, channels: 1, rate: 96_000, bits: 32), Self.chunk("data", body)))
        #expect(samples == values)
        #expect(rate == 96_000)
    }

    @Test func extensibleFloat() throws {
        // fmt на 40 байт: 16 обычных, cbSize 22, допустимые биты, маска каналов, GUID с кодом 3.
        let guid = Self.le16(3) + [UInt8](repeating: 0, count: 14)
        let body = Self.le16(0xFFFE) + Self.le16(1) + Self.le32(48_000) + Self.le32(192_000) + Self.le16(4) + Self.le16(32)
            + Self.le16(22) + Self.le16(32) + Self.le32(4) + guid
        let data = Self.wav(Self.chunk("fmt ", body), Self.chunk("data", Self.le32(Float(0.5).bitPattern)))
        let (samples, _) = try WAVReader.read(data)
        #expect(samples == [0.5])
    }

    @Test func skipsUnknownChunksIncludingOddPadded() throws {
        let data = Self.wav(
            Self.chunk("LIST", [1, 2, 3]), Self.fmt(tag: 1, channels: 1, rate: 44_100, bits: 16),
            Self.chunk("junk", [9]), Self.chunk("data", Self.int16([16_384])), Self.chunk("id3 ", [1, 2, 3, 4])
        )
        let (samples, _) = try WAVReader.read(data)
        #expect(samples == [0.5])
    }

    @Test func dataSizeOfStreamMeansUntilEnd() throws {
        var bytes = Array(Self.wav(Self.fmt(tag: 1, channels: 1, rate: 44_100, bits: 16), Self.chunk("data", Self.int16([16_384, -16_384]))))
        // Размер куска data в последних 4 байтах перед данными.
        let sizeIndex = bytes.count - 4 - 4
        bytes.replaceSubrange(sizeIndex..<sizeIndex + 4, with: Self.le32(0xFFFF_FFFF))
        let (samples, _) = try WAVReader.read(Data(bytes))
        #expect(samples == [0.5, -0.5])
    }

    @Test func partialTrailingFrameIsDropped() throws {
        let data = Self.wav(Self.fmt(tag: 1, channels: 2, rate: 44_100, bits: 16), Self.chunk("data", Self.int16([100, 100]) + [1, 2]))
        #expect(try WAVReader.read(data).samples.count == 1)
    }

    @Test func truncatedFileThrows() {
        let full = Array(Self.wav(Self.fmt(tag: 1, channels: 1, rate: 44_100, bits: 16), Self.chunk("data", Self.int16([1, 2, 3, 4]))))
        // Обрыв внутри данных, внутри fmt и внутри заголовка куска.
        for length in [full.count - 3, 30, 40, 13] {
            #expect(throws: WAVReader.Error.truncated, "length \(length)") {
                try WAVReader.read(Data(full[0..<length]))
            }
        }
    }

    @Test func rejectsWhatItDoesNotUnderstand() {
        #expect(throws: WAVReader.Error.notWAV) { try WAVReader.read(Data("RIFX0000WAVE".utf8)) }
        #expect(throws: WAVReader.Error.notWAV) { try WAVReader.read(Data()) }
        #expect(throws: WAVReader.Error.missingFormat) {
            try WAVReader.read(Self.wav(Self.chunk("data", [0, 0])))
        }
        #expect(throws: WAVReader.Error.missingData) {
            try WAVReader.read(Self.wav(Self.fmt(tag: 1, channels: 1, rate: 44_100, bits: 16)))
        }
        #expect(throws: WAVReader.Error.unsupportedFormat(tag: 1, bits: 8)) {
            try WAVReader.read(Self.wav(Self.fmt(tag: 1, channels: 1, rate: 44_100, bits: 8), Self.chunk("data", [0])))
        }
        #expect(throws: WAVReader.Error.unsupportedFormat(tag: 3, bits: 64)) {
            try WAVReader.read(Self.wav(Self.fmt(tag: 3, channels: 1, rate: 44_100, bits: 64), Self.chunk("data", [0])))
        }
        #expect(throws: WAVReader.Error.unsupportedFormat(tag: 2, bits: 16)) {
            try WAVReader.read(Self.wav(Self.fmt(tag: 2, channels: 1, rate: 44_100, bits: 16), Self.chunk("data", [0, 0])))
        }
        #expect(throws: WAVReader.Error.unsupportedChannelCount(6)) {
            try WAVReader.read(Self.wav(Self.fmt(tag: 1, channels: 6, rate: 44_100, bits: 16), Self.chunk("data", [0, 0])))
        }
        #expect(throws: WAVReader.Error.invalidSampleRate) {
            try WAVReader.read(Self.wav(Self.fmt(tag: 1, channels: 1, rate: 0, bits: 16), Self.chunk("data", [0, 0])))
        }
    }
}
