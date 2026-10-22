import Foundation
import Testing
@testable import WaveCore

struct ProcessMatcherTests {
    private static let yandexPath = "/Applications/Яндекс Музыка.app"
    private static let yandex = AudioSource.application(
        bundleID: "ru.yandex.desktop.music",
        bundlePath: yandexPath,
        displayName: "Яндекс Музыка"
    )

    private func process(
        _ objectID: UInt32,
        bundleID: String? = nil,
        path: String? = nil
    ) -> AudioProcessInfo {
        AudioProcessInfo(
            objectID: objectID, pid: Int32(objectID) + 1000,
            bundleID: bundleID, executablePath: path, isRunningOutput: true
        )
    }

    @Test func matchesElectronHelperInsideBundle() {
        let helperPath = "/Applications/Яндекс Музыка.app/Contents/Frameworks/Яндекс Музыка Helper.app/Contents/MacOS/Яндекс Музыка Helper"
        let processes = [
            process(7, path: helperPath),
            process(8, path: "/Applications/Other.app/Contents/MacOS/Other"),
        ]
        #expect(ProcessMatcher.matches(Self.yandex, in: processes) == [7])
    }

    @Test func matchesPathWithDifferentUnicodeNormalization() {
        let decomposed = "/Applications/Яндекс Музыка.app/Contents/MacOS/Яндекс Музыка".decomposedStringWithCanonicalMapping
        #expect(ProcessMatcher.matches(Self.yandex, in: [process(3, path: decomposed)]) == [3])
    }

    @Test func matchesChromiumHelperByBundlePrefix() {
        let chrome = AudioSource.application(
            bundleID: "com.google.Chrome", bundlePath: "/Applications/Google Chrome.app", displayName: "Google Chrome"
        )
        let processes = [
            process(1, bundleID: "com.google.Chrome"),
            process(2, bundleID: "com.google.Chrome.helper"),
            process(3, bundleID: "com.google.Chromium"),
        ]
        #expect(ProcessMatcher.matches(chrome, in: processes) == [1, 2])
    }

    @Test func matchesFirefoxPluginContainer() {
        let firefox = AudioSource.application(
            bundleID: "org.mozilla.firefox", bundlePath: "/Applications/Firefox.app", displayName: "Firefox"
        )
        let path = "/Applications/Firefox.app/Contents/MacOS/plugin-container.app/Contents/MacOS/plugin-container"
        #expect(ProcessMatcher.matches(firefox, in: [process(5, path: path)]) == [5])
    }

    @Test func doesNotMatchSimilarPrefix() {
        let processes = [
            process(1, bundleID: "ru.yandex.desktop.musicplayer"),
            process(2, path: "/Applications/Яндекс Музыка.app2/Contents/MacOS/X"),
            process(3, path: "/Applications/Яндекс Музыка.app"),
        ]
        #expect(ProcessMatcher.matches(Self.yandex, in: processes).isEmpty)
    }

    @Test func trailingSlashInBundlePathIsNormalized() {
        let source = AudioSource.application(bundleID: "x.y", bundlePath: "/Applications/Foo.app/", displayName: "Foo")
        #expect(ProcessMatcher.matches(source, in: [process(1, path: "/Applications/Foo.app/Contents/MacOS/Foo")]) == [1])
    }

    @Test func emptyBundlePathAndBundleIDMatchNothing() {
        let source = AudioSource.application(bundleID: "", bundlePath: "", displayName: "?")
        let processes = [process(1, bundleID: "", path: "/usr/bin/x"), process(2, bundleID: "a.b")]
        #expect(ProcessMatcher.matches(source, in: processes).isEmpty)
    }

    @Test func safariIncludesWebKitGPU() {
        let safari = AudioSource.application(
            bundleID: ProcessMatcher.safariBundleID, bundlePath: "/Applications/Safari.app", displayName: "Safari"
        )
        let processes = [
            process(9, bundleID: ProcessMatcher.webKitGPUBundleID),
            process(4, bundleID: "com.apple.Safari"),
            process(6, bundleID: "com.apple.WebKit.Networking"),
        ]
        #expect(ProcessMatcher.matches(safari, in: processes) == [4, 9])
        // Для других приложений WebKit GPU не подходит.
        #expect(ProcessMatcher.matches(Self.yandex, in: processes).isEmpty)
    }

    @Test func resultIsSortedAndUnique() {
        let processes = [
            process(30, bundleID: "ru.yandex.desktop.music", path: "/Applications/Яндекс Музыка.app/Contents/MacOS/A"),
            process(12, bundleID: "ru.yandex.desktop.music.helper"),
        ]
        #expect(ProcessMatcher.matches(Self.yandex, in: processes) == [12, 30])
    }

    @Test func systemWideMatchesNothing() {
        let processes = [process(1, bundleID: "com.apple.Safari", path: "/Applications/Safari.app/x")]
        #expect(ProcessMatcher.matches(.systemWide, in: processes).isEmpty)
    }

    @Test func rebuildWhenHelperRespawns() {
        let path = "/Applications/Яндекс Музыка.app/Contents/MacOS/"
        let before = [process(10, path: path + "a"), process(11, path: path + "b")]
        let after = [process(10, path: path + "a"), process(42, path: path + "b")]
        #expect(!ProcessMatcher.needsRebuild(source: Self.yandex, current: [10, 11], processes: before))
        #expect(ProcessMatcher.needsRebuild(source: Self.yandex, current: [10, 11], processes: after))
        #expect(!ProcessMatcher.needsRebuild(source: Self.yandex, current: [11, 10], processes: before))
        #expect(ProcessMatcher.needsRebuild(source: Self.yandex, current: [10], processes: before))
    }

    @Test func bundleIDBelongsByEqualityOrDottedPrefix() {
        #expect(ProcessMatcher.bundleIDBelongs("com.google.Chrome", to: "com.google.Chrome"))
        #expect(ProcessMatcher.bundleIDBelongs("com.google.Chrome.helper", to: "com.google.Chrome"))
        #expect(!ProcessMatcher.bundleIDBelongs("com.google.Chromium", to: "com.google.Chrome"))
        #expect(!ProcessMatcher.bundleIDBelongs("com.google", to: "com.google.Chrome"))
        #expect(!ProcessMatcher.bundleIDBelongs("", to: ""))
        #expect(!ProcessMatcher.bundleIDBelongs("a.b", to: ""))
    }

    /// Now Playing узнается по тем же правилам bundle ID, что и процессы: помощник приложения
    /// (`ru.yandex.desktop.music.helper`) тоже относится к нему, похожий префикс нет.
    @Test func nowPlayingBelongsBySameBundleRules() {
        func info(_ bundleID: String, parent: String? = nil) -> NowPlayingInfo {
            NowPlayingInfo(bundleIdentifier: bundleID, parentBundleIdentifier: parent, title: "Песня")
        }
        #expect(info("ru.yandex.desktop.music").belongs(to: Self.yandex))
        #expect(info("ru.yandex.desktop.music.helper").belongs(to: Self.yandex))
        #expect(info("com.apple.WebKit.GPU", parent: "ru.yandex.desktop.music").belongs(to: Self.yandex))
        #expect(info("x.y", parent: "ru.yandex.desktop.music.renderer").belongs(to: Self.yandex))
        #expect(!info("ru.yandex.desktop.musicplayer").belongs(to: Self.yandex))
        #expect(!info("com.apple.Music").belongs(to: Self.yandex))
        #expect(info("com.apple.Music").belongs(to: .systemWide))
        let noID = AudioSource.application(bundleID: "", bundlePath: "/Applications/X.app", displayName: "X")
        #expect(!info("").belongs(to: noID))
    }

    @Test func yandexCandidates() {
        #expect(ProcessMatcher.yandexMusicCandidates == ["ru.yandex.desktop.music", "ru.yandex.music"])
    }

    @Test func audioSourceCodableRoundTrip() throws {
        for source in [Self.yandex, AudioSource.systemWide] {
            let data = try JSONEncoder().encode(source)
            #expect(try JSONDecoder().decode(AudioSource.self, from: data) == source)
        }
        #expect(AudioSource.systemWide.displayName == "Весь звук системы")
        #expect(Self.yandex.displayName == "Яндекс Музыка")
    }
}
