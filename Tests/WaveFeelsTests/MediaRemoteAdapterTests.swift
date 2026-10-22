import Foundation
import Testing
import WaveCore
@testable import WaveFeels

/// Без запуска адаптера: на CI MediaRemote может не работать, а `test` создает фиктивную запись.
struct MediaRemoteAdapterTests {
    @Test @MainActor func emptyBundleIsUnavailable() throws {
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent("wf-empty-\(UUID().uuidString).app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app) }
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.wfeels.wavefeels.empty-test",
            "CFBundleVersion": "1",
            "CFBundlePackageType": "APPL",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try #require(Bundle(url: app))

        let adapter = MediaRemoteAdapter(bundle: bundle)
        #expect(adapter.availability == .unknown)
        adapter.start()
        #expect(adapter.availability == .unavailable(exitCode: -1, stderr: "нет файлов адаптера"))
        #expect(!adapter.isAvailable)
        #expect(adapter.info == nil)
        #expect(adapter.lastTestExitCode == nil)
        adapter.send(.togglePlayPause)
        adapter.stop()
        #expect(adapter.availability == .unavailable(exitCode: -1, stderr: "нет файлов адаптера"))
    }

    @Test func commandIDsMatchAdapterReadme() {
        #expect(MediaCommand.play.rawValue == 0)
        #expect(MediaCommand.pause.rawValue == 1)
        #expect(MediaCommand.togglePlayPause.rawValue == 2)
        #expect(MediaCommand.nextTrack.rawValue == 4)
        #expect(MediaCommand.previousTrack.rawValue == 5)
    }

    @Test func lineSplitterKeepsOrderAcrossChunks() {
        let splitter = LineSplitter()
        #expect(splitter.append(Data("{\"a\":".utf8)).isEmpty)
        #expect(splitter.append(Data("1}\n{\"b\":2}\n{\"c\"".utf8)) == ["{\"a\":1}", "{\"b\":2}"])
        #expect(splitter.append(Data(":3}\n\n".utf8)) == ["{\"c\":3}", ""])
        #expect(splitter.finish() == nil)
        #expect(splitter.append(Data("tail".utf8)).isEmpty)
        #expect(splitter.finish() == "tail")
    }

    @Test func absurdDurationIsDropped() {
        let track = NowPlayingInfo(bundleIdentifier: "com.apple.Music", title: "Песня", duration: 200)
        #expect(MediaRemoteAdapter.sanitized(track).duration == 200)
        var long = track
        long.duration = 2 * 24 * 3600
        #expect(MediaRemoteAdapter.sanitized(long).duration == nil)
        var infinite = track
        infinite.duration = .infinity
        #expect(MediaRemoteAdapter.sanitized(infinite).duration == nil)
    }
}
