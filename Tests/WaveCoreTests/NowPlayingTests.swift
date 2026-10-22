import Foundation
import Testing
@testable import WaveCore

struct NowPlayingTests {
    private static let artworkBase64 = Data([1, 2, 3, 4]).base64EncodedString()

    private static let fullLine = """
    {"type":"data","diff":false,"payload":{"bundleIdentifier":"com.apple.Music",\
    "parentApplicationBundleIdentifier":"com.apple.Music.parent","title":"Кино 🎸","artist":"Цой",\
    "album":"Группа крови","playing":true,"durationMicros":215000000,"elapsedTimeMicros":30500000,\
    "timestampEpochMicros":1700000000000000,"artworkData":"\(artworkBase64)","volume":0.5}}
    """

    @Test func fullPayloadParses() throws {
        var parser = NowPlayingStreamParser()
        let info = try #require(try parser.consume(line: Self.fullLine))
        #expect(info.bundleIdentifier == "com.apple.Music")
        #expect(info.parentBundleIdentifier == "com.apple.Music.parent")
        #expect(info.title == "Кино 🎸")
        #expect(info.artist == "Цой")
        #expect(info.album == "Группа крови")
        #expect(info.isPlaying)
        #expect(info.duration == 215)
        #expect(info.elapsedTime == 30.5)
        #expect(info.timestamp == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(info.artworkData == Data([1, 2, 3, 4]))
    }

    @Test func diffMergesAndNullDeletes() throws {
        var parser = NowPlayingStreamParser()
        _ = try parser.consume(line: Self.fullLine)
        let info = try #require(try parser.consume(
            line: #"{"type":"data","diff":true,"payload":{"album":null,"playing":false}}"#))
        #expect(info.album == nil)
        #expect(!info.isPlaying)
        #expect(info.title == "Кино 🎸")
        #expect(info.artist == "Цой")
        #expect(info.duration == 215)
    }

    @Test func emptyDiffKeepsState() throws {
        var parser = NowPlayingStreamParser()
        let before = try parser.consume(line: Self.fullLine)
        #expect(before != nil)
        #expect(try parser.consume(line: #"{"type":"data","diff":true,"payload":{}}"#) == before)
        let next = try parser.consume(line: #"{"type":"data","diff":true,"payload":{"playing":false}}"#)
        #expect(next?.title == "Кино 🎸")
        #expect(next?.isPlaying == false)
    }

    @Test func artworkSurvivesTemporaryNilState() throws {
        var parser = NowPlayingStreamParser()
        _ = try parser.consume(line: Self.fullLine)
        #expect(try parser.consume(line: #"{"type":"data","diff":true,"payload":{"title":null}}"#) == nil)
        let restored = try #require(try parser.consume(
            line: #"{"type":"data","diff":true,"payload":{"title":"Кино 🎸"}}"#))
        #expect(restored.artworkData == Data([1, 2, 3, 4]))

        #expect(try parser.consume(line: #"{"type":"data","diff":true,"payload":{"title":null}}"#) == nil)
        let other = try #require(try parser.consume(
            line: #"{"type":"data","diff":true,"payload":{"title":"Другая","artworkData":null}}"#))
        #expect(other.artworkData == nil)
        // Старая обложка не возвращается после смены трека.
        let back = try #require(try parser.consume(
            line: #"{"type":"data","diff":true,"payload":{"title":"Кино 🎸"}}"#))
        #expect(back.artworkData == nil)
    }

    @Test func nonDiffReplacesState() throws {
        var parser = NowPlayingStreamParser()
        _ = try parser.consume(line: Self.fullLine)
        let info = try #require(try parser.consume(line:
            #"{"type":"data","diff":false,"payload":{"bundleIdentifier":"com.spotify.client","title":"Other"}}"#))
        #expect(info.bundleIdentifier == "com.spotify.client")
        #expect(info.artist == nil)
        #expect(info.album == nil)
        #expect(info.duration == nil)
        #expect(info.elapsedTime == nil)
        #expect(info.timestamp == nil)
        #expect(!info.isPlaying)
    }

    @Test func emptyPayloadGivesNil() throws {
        var parser = NowPlayingStreamParser()
        #expect(try parser.consume(line: #"{"type":"data","diff":false,"payload":{}}"#) == nil)
        _ = try parser.consume(line: Self.fullLine)
        #expect(try parser.consume(line: #"{"type":"data","diff":false,"payload":{}}"#) == nil)
        // После пустого сброса старое состояние не воскресает.
        #expect(try parser.consume(line: #"{"type":"data","diff":true,"payload":{"playing":true}}"#) == nil)
    }

    @Test func missingTitleGivesNil() throws {
        var parser = NowPlayingStreamParser()
        #expect(try parser.consume(line:
            #"{"type":"data","diff":false,"payload":{"bundleIdentifier":"com.apple.Music","artist":"A"}}"#) == nil)
        #expect(try parser.consume(line:
            #"{"type":"data","diff":false,"payload":{"title":"T"}}"#) == nil)
    }

    @Test func artworkSurvivesBriefDisappearance() throws {
        var parser = NowPlayingStreamParser()
        _ = try parser.consume(line: Self.fullLine)
        let kept = try #require(try parser.consume(
            line: #"{"type":"data","diff":true,"payload":{"artworkData":null}}"#))
        #expect(kept.artworkData == Data([1, 2, 3, 4]))

        let keptByReplace = try #require(try parser.consume(line:
            #"{"type":"data","diff":false,"payload":{"bundleIdentifier":"com.apple.Music","title":"Кино 🎸","artist":"Цой","album":"Группа крови"}}"#))
        #expect(keptByReplace.artworkData == Data([1, 2, 3, 4]))

        let changed = try #require(try parser.consume(
            line: #"{"type":"data","diff":true,"payload":{"title":"Другая","artworkData":null}}"#))
        #expect(changed.artworkData == nil)
    }

    @Test func artworkDroppedWhenArtistChanges() throws {
        var parser = NowPlayingStreamParser()
        _ = try parser.consume(line: Self.fullLine)
        let info = try #require(try parser.consume(
            line: #"{"type":"data","diff":true,"payload":{"artist":"Другой","artworkData":null}}"#))
        #expect(info.artworkData == nil)
    }

    @Test func invalidBase64GivesNilArtwork() throws {
        var parser = NowPlayingStreamParser()
        let info = try #require(try parser.consume(line:
            #"{"type":"data","diff":false,"payload":{"bundleIdentifier":"a","title":"t","artworkData":"%%%not base64"}}"#))
        #expect(info.artworkData == nil)
    }

    @Test func invalidJSONThrowsAndKeepsState() throws {
        var parser = NowPlayingStreamParser()
        let before = try parser.consume(line: Self.fullLine)
        #expect(throws: (any Error).self) { try parser.consume(line: #"{"type":"data","diff":true,"payl"#) }
        #expect(throws: (any Error).self) { try parser.consume(line: "[1,2,3]") }
        #expect(throws: (any Error).self) {
            try parser.consume(line: #"{"type":"data","diff":true,"payload":{"durationMicros":Infinity}}"#)
        }
        let after = try parser.consume(line: #"{"type":"data","diff":true,"payload":{"unrelated":1}}"#)
        #expect(after == before)
    }

    @Test func otherTypesAndBlankLinesAreIgnored() throws {
        var parser = NowPlayingStreamParser()
        #expect(try parser.consume(line: "") == nil)
        #expect(try parser.consume(line: "  \n") == nil)
        let first = try parser.consume(line: Self.fullLine)
        #expect(first != nil)
        #expect(try parser.consume(line: #"{"type":"error","message":"x"}"#) == first)
        #expect(try parser.consume(line: "") == first)
    }

    @Test func numbersAndBooleansAcceptAlternateForms() throws {
        var parser = NowPlayingStreamParser()
        let info = try #require(try parser.consume(line:
            #"{"type":"data","diff":false,"payload":{"bundleIdentifier":"a","title":"t","playing":1,"durationMicros":215000000.0,"elapsedTimeMicros":5}}"#))
        #expect(info.isPlaying)
        #expect(info.duration == 215)
        #expect(info.elapsedTime == 0.000005)
        let paused = try #require(try parser.consume(
            line: #"{"type":"data","diff":true,"payload":{"playing":0}}"#))
        #expect(!paused.isPlaying)
    }

    @Test(arguments: ["0", "-5", "1e300", "86400000001"])
    func absurdDurationIsNil(micros: String) throws {
        var parser = NowPlayingStreamParser()
        let info = try #require(try parser.consume(line:
            #"{"type":"data","diff":false,"payload":{"bundleIdentifier":"a","title":"t","durationMicros":\#(micros)}}"#))
        #expect(info.duration == nil)
    }

    @Test func dayLongDurationIsKept() throws {
        var parser = NowPlayingStreamParser()
        let info = try #require(try parser.consume(line:
            #"{"type":"data","diff":false,"payload":{"bundleIdentifier":"a","title":"t","durationMicros":86400000000}}"#))
        #expect(info.duration == 86_400)
    }

    @Test func elapsedAdvancesOnlyWhilePlaying() throws {
        var parser = NowPlayingStreamParser()
        let playing = try #require(try parser.consume(line: Self.fullLine))
        let stamp = try #require(playing.timestamp)
        #expect(playing.elapsed(at: stamp) == 30.5)
        #expect(playing.elapsed(at: stamp.addingTimeInterval(10)) == 40.5)
        #expect(playing.elapsed(at: stamp.addingTimeInterval(10_000)) == 215)
        #expect(playing.elapsed(at: stamp.addingTimeInterval(-10)) == 30.5)

        let paused = try #require(try parser.consume(
            line: #"{"type":"data","diff":true,"payload":{"playing":false}}"#))
        #expect(paused.elapsed(at: stamp.addingTimeInterval(10)) == 30.5)
    }

    @Test func elapsedWithoutTimestampOrElapsed() throws {
        var parser = NowPlayingStreamParser()
        let noStamp = try #require(try parser.consume(line:
            #"{"type":"data","diff":false,"payload":{"bundleIdentifier":"a","title":"t","playing":true,"durationMicros":10000000,"elapsedTimeMicros":12000000}}"#))
        #expect(noStamp.elapsed(at: Date()) == 10)
        let noElapsed = try #require(try parser.consume(line:
            #"{"type":"data","diff":false,"payload":{"bundleIdentifier":"a","title":"t","playing":true}}"#))
        #expect(noElapsed.elapsed(at: Date()) == nil)
    }
}
