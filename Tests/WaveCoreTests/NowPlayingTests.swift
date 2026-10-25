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
        // Диффом: строка обложки остается в состоянии, пока title снят.
        #expect(try parser.consume(line: #"{"type":"data","diff":true,"payload":{"title":null}}"#) == nil)
        let restored = try #require(try parser.consume(
            line: #"{"type":"data","diff":true,"payload":{"title":"Кино 🎸"}}"#))
        #expect(restored.artworkData == Data([1, 2, 3, 4]))

        // Полным снимком: состояние сброшено, обложку помнит только lastArtwork.
        let track = #""bundleIdentifier":"com.apple.Music","artist":"Цой","album":"Группа крови""#
        #expect(try parser.consume(line:
            #"{"type":"data","diff":false,"payload":{"bundleIdentifier":"com.apple.Music","artist":"Цой"}}"#) == nil)
        let again = try #require(try parser.consume(line:
            #"{"type":"data","diff":false,"payload":{\#(track),"title":"Кино 🎸"}}"#))
        #expect(again.artworkData == Data([1, 2, 3, 4]))

        // Реальная смена трека сбрасывает обложку навсегда.
        let other = try #require(try parser.consume(line:
            #"{"type":"data","diff":false,"payload":{\#(track),"title":"Другая"}}"#))
        #expect(other.artworkData == nil)
        let back = try #require(try parser.consume(line:
            #"{"type":"data","diff":false,"payload":{\#(track),"title":"Кино 🎸"}}"#))
        #expect(back.artworkData == nil)
    }

    @Test func staleArtworkIsDroppedOnTrackChange() throws {
        var parser = NowPlayingStreamParser()
        _ = try parser.consume(line: Self.fullLine)
        let b = try #require(try parser.consume(line: #"{"type":"data","diff":true,"payload":{"title":"B"}}"#))
        #expect(b.title == "B")
        #expect(b.artworkData == nil)

        let newArtwork = Data([9, 8]).base64EncodedString()
        let withArt = try #require(try parser.consume(
            line: #"{"type":"data","diff":true,"payload":{"artworkData":"\#(newArtwork)"}}"#))
        #expect(withArt.title == "B")
        #expect(withArt.artworkData == Data([9, 8]))

        // Смена только альбома или исполнителя тоже новый трек.
        let album = try #require(try parser.consume(line: #"{"type":"data","diff":true,"payload":{"album":"X"}}"#))
        #expect(album.artworkData == nil)
    }

    @Test func artworkArrivingBeforeTitleBelongsToThatTrack() throws {
        var parser = NowPlayingStreamParser()
        #expect(try parser.consume(line:
            #"{"type":"data","diff":false,"payload":{"bundleIdentifier":"a","artworkData":"\#(Self.artworkBase64)"}}"#) == nil)
        let info = try #require(try parser.consume(line: #"{"type":"data","diff":true,"payload":{"title":"T"}}"#))
        #expect(info.artworkData == Data([1, 2, 3, 4]))
        let next = try #require(try parser.consume(line: #"{"type":"data","diff":true,"payload":{"title":"U"}}"#))
        #expect(next.artworkData == nil)
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

    /// Значок баннера у всего звука системы: сначала приложение-родитель, затем само.
    @Test func appBundleIDsPreferParent() {
        let helper = NowPlayingInfo(bundleIdentifier: "com.google.Chrome.helper", parentBundleIdentifier: "com.google.Chrome", title: "x")
        #expect(helper.appBundleIDs == ["com.google.Chrome", "com.google.Chrome.helper"])
        #expect(NowPlayingInfo(bundleIdentifier: "com.apple.Music", title: "x").appBundleIDs == ["com.apple.Music"])
        #expect(NowPlayingInfo(bundleIdentifier: "", parentBundleIdentifier: "", title: "x").appBundleIDs.isEmpty)
        let same = NowPlayingInfo(bundleIdentifier: "com.apple.Music", parentBundleIdentifier: "com.apple.Music", title: "x")
        #expect(same.appBundleIDs == ["com.apple.Music"])
    }

    // MARK: - Тайминг при смене трека

    private static let t0: Double = 1_700_000_000
    private static let t0Date = Date(timeIntervalSince1970: t0)

    private static func micros(_ seconds: Double) -> String {
        String(Int64((seconds * 1_000_000).rounded()))
    }

    /// Строка потока: `pairs` готовые фрагменты JSON (`"\"B\""`, `"true"`, число).
    private static func line(diff: Bool, _ pairs: KeyValuePairs<String, String>) -> String {
        let payload = pairs.map { "\"\($0.key)\":\($0.value)" }.joined(separator: ",")
        return #"{"type":"data","diff":\#(diff),"payload":{\#(payload)}}"#
    }

    /// Полный снимок трека A: 2:13, позиция 2:10 на метке T, играет.
    private static let snapshotA = line(diff: false, [
        "bundleIdentifier": #""ru.yandex.desktop.music""#,
        "title": #""A""#,
        "artist": #""a""#,
        "playing": "true",
        "durationMicros": micros(133),
        "elapsedTimeMicros": micros(130),
        "timestampEpochMicros": micros(t0),
    ])

    /// Яндекс Музыка присылает название нового трека раньше его позиции и длительности:
    /// тайминг прошлого трека не достается новому, прогресса нет до нового тайминга.
    @Test func trackChangeDropsStaleTiming() throws {
        var parser = NowPlayingStreamParser()
        _ = try parser.consume(line: Self.snapshotA, receivedAt: Self.t0Date)
        let b = try #require(try parser.consume(
            line: Self.line(diff: true, ["title": #""B""#, "artist": #""b""#]),
            receivedAt: Self.t0Date.addingTimeInterval(3)))
        #expect(b.title == "B")
        #expect(b.duration == nil)
        #expect(b.elapsedTime == nil)
        #expect(b.timestamp == nil)
        #expect(b.playbackPosition(at: Self.t0Date.addingTimeInterval(1)) == nil)

        let timed = try #require(try parser.consume(line: Self.line(diff: true, [
            "durationMicros": Self.micros(200),
            "elapsedTimeMicros": Self.micros(1),
            "timestampEpochMicros": Self.micros(Self.t0 + 5),
        ]), receivedAt: Self.t0Date.addingTimeInterval(5)))
        #expect(timed.title == "B")
        #expect(timed.isPlaying)
        #expect(timed.playbackPosition(at: Self.t0Date.addingTimeInterval(6))?.passedSeconds == 2)
    }

    @Test func trackChangeWithTimingKeepsIt() throws {
        var parser = NowPlayingStreamParser()
        _ = try parser.consume(line: Self.snapshotA)
        let b = try #require(try parser.consume(line: Self.line(diff: true, [
            "title": #""B""#,
            "durationMicros": Self.micros(200),
            "elapsedTimeMicros": Self.micros(0),
            "timestampEpochMicros": Self.micros(Self.t0 + 1),
        ])))
        #expect(b.duration == 200)
        #expect(b.elapsedTime == 0)
        #expect(b.timestamp == Self.t0Date.addingTimeInterval(1))
    }

    /// Каждый отсутствующий в диффе ключ тайминга удаляется отдельно: длительность без позиции
    /// прогресс не показывает.
    @Test func partialTimingHidesProgress() throws {
        var parser = NowPlayingStreamParser()
        _ = try parser.consume(line: Self.snapshotA, receivedAt: Self.t0Date)
        let b = try #require(try parser.consume(line: Self.line(diff: true, [
            "title": #""B""#,
            "durationMicros": Self.micros(200),
        ]), receivedAt: Self.t0Date.addingTimeInterval(3)))
        #expect(b.duration == 200)
        #expect(b.elapsedTime == nil)
        #expect(b.timestamp == nil)
        #expect(b.playbackPosition(at: Self.t0Date) == nil)
    }

    /// Сценарий A: адаптер шлет дифф только по изменившимся ключам. Тайминг нового трека
    /// пришел, пока название еще старое, а название следом: свежий тайминг остается, иначе
    /// адаптер его больше не пришлет и полосы не будет весь трек.
    @Test func timingBeforeTitleOfNextTrackIsKept() throws {
        for titleDelay in [0.5, 2.5] {
            var parser = NowPlayingStreamParser()
            _ = try parser.consume(line: Self.snapshotA, receivedAt: Self.t0Date)
            _ = try parser.consume(line: Self.line(diff: true, [
                "durationMicros": Self.micros(200),
                "elapsedTimeMicros": Self.micros(0),
                "timestampEpochMicros": Self.micros(Self.t0 + 3),
            ]), receivedAt: Self.t0Date.addingTimeInterval(3))
            let b = try #require(try parser.consume(
                line: Self.line(diff: true, ["title": #""B""#, "artist": #""b""#]),
                receivedAt: Self.t0Date.addingTimeInterval(3 + titleDelay)))
            #expect(b.title == "B")
            #expect(b.duration == 200)
            #expect(b.elapsedTime == 0)
            #expect(b.timestamp == Self.t0Date.addingTimeInterval(3))
            #expect(b.playbackPosition(at: Self.t0Date.addingTimeInterval(10))?.passedSeconds == 7)
        }
    }

    /// Сценарий B: у нового трека та же длительность, адаптер ее не повторяет. Позиция нового
    /// трека свежая (у начала), значит длительность остается.
    @Test func sameDurationOnNextTrackIsKept() throws {
        var parser = NowPlayingStreamParser()
        _ = try parser.consume(line: Self.snapshotA, receivedAt: Self.t0Date)
        let b = try #require(try parser.consume(line: Self.line(diff: true, [
            "title": #""B""#,
            "artist": #""b""#,
            "elapsedTimeMicros": Self.micros(0),
            "timestampEpochMicros": Self.micros(Self.t0 + 3),
        ]), receivedAt: Self.t0Date.addingTimeInterval(3)))
        #expect(b.duration == 133)
        #expect(b.elapsedTime == 0)
        #expect(b.playbackPosition(at: Self.t0Date.addingTimeInterval(4))?.passedSeconds == 1)
    }

    /// Строка с ключом тайминга не дольше секунды назад: тайминг тоже считается свежим, даже
    /// если позиция в состоянии далеко от начала.
    @Test func timingFromLastSecondIsKept() throws {
        var parser = NowPlayingStreamParser()
        _ = try parser.consume(line: Self.snapshotA, receivedAt: Self.t0Date)
        _ = try parser.consume(
            line: Self.line(diff: true, ["durationMicros": Self.micros(200)]),
            receivedAt: Self.t0Date.addingTimeInterval(3))
        let b = try #require(try parser.consume(
            line: Self.line(diff: true, ["title": #""B""#]), receivedAt: Self.t0Date.addingTimeInterval(3.8)))
        #expect(b.duration == 200)
        #expect(b.elapsedTime == 130)

        // Через 1,5 с после строки с таймингом и при позиции далеко от начала он уже чужой.
        var late = NowPlayingStreamParser()
        _ = try late.consume(line: Self.snapshotA, receivedAt: Self.t0Date)
        _ = try late.consume(
            line: Self.line(diff: true, ["durationMicros": Self.micros(200)]),
            receivedAt: Self.t0Date.addingTimeInterval(3))
        let stale = try #require(try late.consume(
            line: Self.line(diff: true, ["title": #""B""#]), receivedAt: Self.t0Date.addingTimeInterval(4.5)))
        #expect(stale.duration == nil)
        #expect(stale.elapsedTime == nil)
    }

    @Test func diffWithoutTitleKeepsTiming() throws {
        var parser = NowPlayingStreamParser()
        _ = try parser.consume(line: Self.snapshotA)
        let info = try #require(try parser.consume(line: Self.line(diff: true, [
            "elapsedTimeMicros": Self.micros(10),
            "timestampEpochMicros": Self.micros(Self.t0 + 3),
        ])))
        #expect(info.title == "A")
        #expect(info.duration == 133)
        #expect(info.elapsedTime == 10)
        #expect(info.timestamp == Self.t0Date.addingTimeInterval(3))
    }

    /// Тайминг, пришедший раньше названия, принадлежит первому названию, как обложка.
    @Test func ownerlessTimingIsAdopted() throws {
        var parser = NowPlayingStreamParser()
        #expect(try parser.consume(line: Self.line(diff: false, [
            "bundleIdentifier": #""ru.yandex.desktop.music""#,
            "durationMicros": Self.micros(200),
            "elapsedTimeMicros": Self.micros(10),
            "timestampEpochMicros": Self.micros(Self.t0),
            "playing": "true",
        ])) == nil)
        let b = try #require(try parser.consume(line: Self.line(diff: true, ["title": #""B""#])))
        #expect(b.duration == 200)
        #expect(b.elapsedTime == 10)
        #expect(b.timestamp == Self.t0Date)
    }

    /// Пауза и продолжение без новой метки: позиция переносится на момент получения строки,
    /// и время паузы в нее не попадает.
    @Test func resumeAfterPauseWithoutTimestampDoesNotJump() throws {
        var parser = NowPlayingStreamParser()
        _ = try parser.consume(line: Self.line(diff: false, [
            "bundleIdentifier": #""ru.yandex.desktop.music""#,
            "title": #""A""#,
            "playing": "true",
            "durationMicros": Self.micros(200),
            "elapsedTimeMicros": Self.micros(30),
            "timestampEpochMicros": Self.micros(Self.t0),
        ]))
        let paused = try #require(try parser.consume(
            line: Self.line(diff: true, ["playing": "false"]), receivedAt: Self.t0Date.addingTimeInterval(10)))
        #expect(!paused.isPlaying)
        #expect(abs((paused.elapsedTime ?? 0) - 40) < 1e-6)
        #expect(paused.timestamp == Self.t0Date.addingTimeInterval(10))

        let resumed = try #require(try parser.consume(
            line: Self.line(diff: true, ["playing": "true"]), receivedAt: Self.t0Date.addingTimeInterval(100)))
        #expect(resumed.isPlaying)
        #expect(resumed.timestamp == Self.t0Date.addingTimeInterval(100))
        #expect(abs((resumed.elapsed(at: Self.t0Date.addingTimeInterval(101)) ?? 0) - 41) < 1e-6)
    }

    /// Пауза, когда позиция уже ушла за длительность дальше допуска: такую позицию прогресс
    /// скрывает, и в полную полосу на паузе она не превращается. Состояние остается как было
    /// (так проходит и `elapsedAdvancesOnlyWhilePlaying` с меткой из прошлого).
    @Test func pauseDoesNotRebaseStalePosition() throws {
        var parser = NowPlayingStreamParser()
        _ = try parser.consume(line: Self.snapshotA)
        let paused = try #require(try parser.consume(
            line: Self.line(diff: true, ["playing": "false"]), receivedAt: Self.t0Date.addingTimeInterval(60)))
        #expect(!paused.isPlaying)
        #expect(paused.elapsedTime == 130)
        #expect(paused.timestamp == Self.t0Date)
        // В пределах допуска позиция переносится и ограничивается длительностью.
        var near = NowPlayingStreamParser()
        _ = try near.consume(line: Self.snapshotA)
        let end = try #require(try near.consume(
            line: Self.line(diff: true, ["playing": "false"]), receivedAt: Self.t0Date.addingTimeInterval(4)))
        #expect(end.elapsedTime == 133)
        #expect(end.timestamp == Self.t0Date.addingTimeInterval(4))
        #expect(end.playbackPosition(at: Self.t0Date.addingTimeInterval(100))?.remainingSeconds == 0)
    }

    @Test func elapsedWithoutTimestampIsStampedOnReceipt() throws {
        var parser = NowPlayingStreamParser()
        _ = try parser.consume(line: Self.snapshotA)
        let info = try #require(try parser.consume(
            line: Self.line(diff: true, ["elapsedTimeMicros": Self.micros(60)]),
            receivedAt: Self.t0Date.addingTimeInterval(50)))
        #expect(info.elapsedTime == 60)
        #expect(info.timestamp == Self.t0Date.addingTimeInterval(50))
        #expect(info.playbackPosition(at: Self.t0Date.addingTimeInterval(52))?.passedSeconds == 62)
    }

    /// Позиция дальше длительности больше чем на допуск: данные устарели, прогресс скрыт.
    @Test func positionBeyondDurationIsHidden() {
        let paused = NowPlayingInfo(
            bundleIdentifier: "a", title: "t", isPlaying: false,
            duration: 133, elapsedTime: 150, timestamp: Self.t0Date)
        #expect(paused.playbackPosition(at: Self.t0Date) == nil)
        let playing = NowPlayingInfo(
            bundleIdentifier: "a", title: "t", isPlaying: true,
            duration: 133, elapsedTime: 100, timestamp: Self.t0Date)
        #expect(playing.playbackPosition(at: Self.t0Date.addingTimeInterval(60)) == nil)
        #expect(playing.playbackPosition(at: Self.t0Date.addingTimeInterval(30))?.passedSeconds == 130)
        let noDuration = NowPlayingInfo(bundleIdentifier: "a", title: "t", elapsedTime: 10)
        #expect(noDuration.playbackPosition(at: Self.t0Date) == nil)
        let noElapsed = NowPlayingInfo(bundleIdentifier: "a", title: "t", duration: 100)
        #expect(noElapsed.playbackPosition(at: Self.t0Date) == nil)
    }

    /// В пределах допуска позиция за концом трека дает полную полосу.
    @Test func positionAtEndShowsFullBar() throws {
        let info = NowPlayingInfo(
            bundleIdentifier: "a", title: "t", isPlaying: false,
            duration: 133.9, elapsedTime: 134.5, timestamp: Self.t0Date)
        let position = try #require(info.playbackPosition(at: Self.t0Date))
        #expect(position.fraction == 1)
        #expect(position.remainingSeconds == 0)
        #expect(position.passedSeconds == 133)
        #expect(position.elapsed == 133.9)
    }

    @Test func clockAndRemainingAddUp() {
        let position = PlaybackPosition(elapsed: 63.7, duration: 214.2)
        #expect(position.passedText == "1:03")
        #expect(position.remainingText == "\u{2212}2:31")
        #expect(position.passedSeconds + position.remainingSeconds == 214)
        #expect(abs(position.fraction - 63.7 / 214.2) < 1e-12)
        #expect(PlaybackPosition.clock(3723) == "1:02:03")
        #expect(PlaybackPosition.clock(7) == "0:07")
        #expect(PlaybackPosition.clock(221) == "3:41")
        #expect(PlaybackPosition.overrunTolerance == 2.0)
    }

    // MARK: - NowPlayingTimingWatch

    private static func track(_ title: String, duration: Double? = nil, elapsed: Double? = nil, playing: Bool = true) -> NowPlayingInfo {
        NowPlayingInfo(
            bundleIdentifier: "ru.yandex.desktop.music", title: title, isPlaying: playing,
            duration: duration, elapsedTime: elapsed, timestamp: elapsed == nil ? nil : t0Date)
    }

    /// Смена трека без тайминга после трека с таймингом: одна строка, пустые снимки между
    /// треками ее не теряют и не повторяют.
    @Test func watchReportsTrackChangeWithoutTimingOnce() {
        var watch = NowPlayingTimingWatch()
        #expect(watch.observe(Self.track("A", duration: 133, elapsed: 10), at: Self.t0Date).isEmpty)
        #expect(watch.observe(nil, at: Self.t0Date).isEmpty)
        #expect(watch.observe(Self.track("B"), at: Self.t0Date) == [.trackChangedWithoutTiming])
        #expect(watch.observe(Self.track("B"), at: Self.t0Date).isEmpty)
        // Трек без тайминга после трека без тайминга: не о чем сообщать.
        #expect(watch.observe(Self.track("C"), at: Self.t0Date).isEmpty)
        // Длительность без позиции: своя строка, тоже один раз.
        #expect(watch.observe(Self.track("D", duration: 100, elapsed: 5), at: Self.t0Date).isEmpty)
        #expect(watch.observe(Self.track("E", duration: 100), at: Self.t0Date) == [.trackChangedWithoutPosition])
        #expect(watch.observe(Self.track("E", duration: 100), at: Self.t0Date).isEmpty)
    }

    /// Полоса пропала посреди трека без новой строки: срок проверки известен заранее,
    /// проверка в этот срок пишет строку один раз.
    @Test func watchFindsOverrunWithoutNewLine() throws {
        var watch = NowPlayingTimingWatch()
        let a = Self.track("A", duration: 133, elapsed: 100)
        #expect(watch.observe(a, at: Self.t0Date.addingTimeInterval(10)).isEmpty)
        let deadline = try #require(watch.overrunDeadline)
        #expect(abs(deadline.timeIntervalSince(Self.t0Date)
            - (35 + NowPlayingTimingWatch.checkMargin)) < 1e-6)
        #expect(a.playbackPosition(at: deadline) == nil)
        #expect(watch.check(at: deadline.addingTimeInterval(-1)).isEmpty)
        let events = watch.check(at: deadline)
        #expect(events.count == 1)
        if case let .positionBeyondDuration(elapsed, duration, stampAge)? = events.first {
            #expect(abs(elapsed - (135 + NowPlayingTimingWatch.checkMargin)) < 1e-6)
            #expect(duration == 133)
            #expect(abs((stampAge ?? 0) - (35 + NowPlayingTimingWatch.checkMargin)) < 1e-6)
        } else {
            Issue.record("нет строки о позиции: \(events)")
        }
        #expect(watch.check(at: deadline.addingTimeInterval(5)).isEmpty)
        #expect(watch.overrunDeadline == nil)

        // На паузе позиция стоит: проверять нечего. Пустой снимок проверку снимает.
        var paused = NowPlayingTimingWatch()
        #expect(paused.observe(Self.track("A", duration: 133, elapsed: 100, playing: false), at: Self.t0Date).isEmpty)
        #expect(paused.overrunDeadline == nil)
        var emptied = NowPlayingTimingWatch()
        _ = emptied.observe(a, at: Self.t0Date)
        #expect(emptied.overrunDeadline != nil)
        _ = emptied.observe(nil, at: Self.t0Date)
        #expect(emptied.overrunDeadline == nil)
        #expect(emptied.check(at: Self.t0Date.addingTimeInterval(100)).isEmpty)
    }

    @Test func watchReportsOverrunOncePerTrack() {
        var watch = NowPlayingTimingWatch()
        let a = Self.track("A", duration: 133, elapsed: 100)
        #expect(watch.observe(a, at: Self.t0Date.addingTimeInterval(30)).isEmpty)
        let late = Self.t0Date.addingTimeInterval(60)
        #expect(watch.observe(a, at: late) == [.positionBeyondDuration(elapsed: 160, duration: 133, stampAge: 60)])
        #expect(watch.observe(a, at: late.addingTimeInterval(1)).isEmpty)
        #expect(watch.observe(Self.track("B", duration: 100, elapsed: 150, playing: false), at: late)
            == [.positionBeyondDuration(elapsed: 150, duration: 100, stampAge: 60)])
    }

    @Test func watchEventMessages() {
        #expect(NowPlayingTimingWatch.Event.trackChangedWithoutTiming.logMessage
            == "адаптер: трек сменился без длительности и позиции")
        #expect(NowPlayingTimingWatch.Event.trackChangedWithoutPosition.logMessage
            == "адаптер: трек сменился с длительностью, но без позиции")
        #expect(NowPlayingTimingWatch.checkMargin == 0.1)
        #expect(NowPlayingTimingWatch.Event.positionBeyondDuration(elapsed: 160, duration: 133, stampAge: 60.24).logMessage
            == "адаптер: позиция вне длительности (позиция 160.0 с, длительность 133.0 с, метка 60.2 с назад)")
        #expect(NowPlayingTimingWatch.Event.positionBeyondDuration(elapsed: 150, duration: 133, stampAge: nil).logMessage
            == "адаптер: позиция вне длительности (позиция 150.0 с, длительность 133.0 с, без метки)")
    }

    // MARK: - NowPlayingHold

    private static let trackA = NowPlayingInfo(bundleIdentifier: "ru.yandex.desktop.music", title: "Первый", isPlaying: true)
    private static let trackB = NowPlayingInfo(bundleIdentifier: "ru.yandex.desktop.music", title: "Второй", isPlaying: true)

    /// Яндекс Музыка между треками присылает пустой снимок: прежний трек держится, пока не придет новый.
    @Test func emptyBetweenTracksIsHeld() {
        var hold = NowPlayingHold<NowPlayingInfo>()
        let first = hold.receive(Self.trackA, at: 0)
        #expect(first.published == Self.trackA)
        #expect(first.holdUntil == nil)
        let empty = hold.receive(nil, at: 1.0)
        #expect(empty.published == Self.trackA)
        #expect(empty.holdUntil == 2.5)
        let next = hold.receive(Self.trackB, at: 1.3)
        #expect(next.published == Self.trackB)
        #expect(next.holdUntil == nil)
        // Таймер прежнего удержания пришел поздно: новый трек остается.
        #expect(hold.expire(at: 2.5) == Self.trackB)
    }

    /// Пустое состояние дольше `grace`: трек правда кончился, данных больше нет.
    @Test func longEmptyClearsAfterGrace() {
        var hold = NowPlayingHold<NowPlayingInfo>()
        _ = hold.receive(Self.trackA, at: 0)
        #expect(hold.receive(nil, at: 1.0).holdUntil == 1.0 + NowPlayingHold<NowPlayingInfo>.grace)
        #expect(hold.expire(at: 2.5) == nil)
        // Следующие пустые снимки ничего не держат.
        let after = hold.receive(nil, at: 3.0)
        #expect(after.published == nil)
        #expect(after.holdUntil == nil)
        #expect(hold.receive(Self.trackB, at: 4.0).published == Self.trackB)
    }

    /// Тот же трек после пустого снимка: опубликованное значение не меняется ни на шаг,
    /// баннер смены трека не видит.
    @Test func sameTrackAfterEmptyStaysSame() {
        var hold = NowPlayingHold<NowPlayingInfo>()
        var published: [NowPlayingInfo?] = []
        published.append(hold.receive(Self.trackA, at: 0).published)
        published.append(hold.receive(nil, at: 1.0).published)
        let back = hold.receive(Self.trackA, at: 1.2)
        published.append(back.published)
        #expect(published == [Self.trackA, Self.trackA, Self.trackA])
        #expect(back.holdUntil == nil)
        #expect(hold.expire(at: 2.5) == Self.trackA)
    }

    @Test func emptyWithoutTrackPublishesNil() {
        var hold = NowPlayingHold<NowPlayingInfo>()
        let first = hold.receive(nil, at: 0)
        #expect(first.published == nil)
        #expect(first.holdUntil == nil)
        #expect(hold.expire(at: 10) == nil)
    }

    /// Повторные пустые снимки срок не продлевают; таймер раньше срока трек не снимает.
    @Test func repeatedEmptyKeepsFirstDeadline() {
        var hold = NowPlayingHold<NowPlayingInfo>()
        _ = hold.receive(Self.trackA, at: 0)
        #expect(hold.receive(nil, at: 1.0).holdUntil == 2.5)
        let again = hold.receive(nil, at: 2.0)
        #expect(again.published == Self.trackA)
        #expect(again.holdUntil == 2.5)
        #expect(hold.expire(at: 2.4) == Self.trackA)
        #expect(hold.expire(at: 2.5) == nil)
    }

    @Test func graceIsOneAndAHalfSeconds() {
        #expect(NowPlayingHold<NowPlayingInfo>.grace == 1.5)
    }
}
