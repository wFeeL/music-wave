import Foundation
import Testing
@testable import WaveCore

struct SourceChoicesTests {
    private static func app(_ name: String, id: String, path: String? = nil) -> AudioSource {
        .application(bundleID: id, bundlePath: path ?? "/Applications/\(name).app", displayName: name)
    }

    private static let yandex = app("Яндекс Музыка", id: "ru.yandex.desktop.music")
    private static let chrome = app("Google Chrome", id: "com.google.Chrome")
    private static let safari = app("Safari", id: "com.apple.Safari")
    private static let telegram = app("Telegram", id: "ru.keepcoder.Telegram")

    @Test func keepsOrderAndDropsRepeats() {
        let choices = SourceChoices.make(
            selected: nil,
            yandexMusic: Self.yandex,
            playing: [Self.yandex, Self.chrome, Self.telegram],
            browsers: [Self.chrome, Self.safari]
        )
        #expect(choices.yandexMusic == Self.yandex)
        #expect(choices.playing == [Self.chrome, Self.telegram])
        #expect(choices.browsers == [Self.safari])
        #expect(choices.other == nil)
    }

    @Test func selectedReplacesSameAppWithOtherName() {
        // Список приложений со звуком называет приложение по-своему: пункт меню должен
        // совпасть с сохраненным источником, иначе меню не покажет выбранное.
        let stored = Self.app("Telegram Desktop", id: "ru.keepcoder.Telegram", path: "/Applications/Telegram.app")
        let choices = SourceChoices.make(
            selected: stored,
            yandexMusic: nil,
            playing: [Self.telegram],
            browsers: [Self.safari]
        )
        #expect(choices.playing == [stored])
        #expect(choices.other == nil)
        #expect(choices.contains(stored))
    }

    @Test func selectedOutsideListsGoesToOther() {
        let picked = Self.app("VLC", id: "org.videolan.vlc")
        let choices = SourceChoices.make(
            selected: picked,
            yandexMusic: Self.yandex,
            playing: [],
            browsers: [Self.safari]
        )
        #expect(choices.other == picked)
        #expect(choices.contains(picked))
    }

    @Test func systemWideNeverListedAsApp() {
        let choices = SourceChoices.make(
            selected: .systemWide,
            yandexMusic: nil,
            playing: [.systemWide, Self.chrome],
            browsers: []
        )
        #expect(choices.playing == [Self.chrome])
        #expect(choices.other == nil)
        #expect(choices.contains(.systemWide))
    }

    @Test func comparesPathsInCanonicalForm() {
        // Путь из файловой системы может прийти в разложенной форме Unicode (NFD).
        let decomposed = "/Applications/Яндекс Музыка.app".decomposedStringWithCanonicalMapping
        let fromDisk = Self.app("Яндекс Музыка", id: "ru.yandex.desktop.music", path: decomposed)
        let choices = SourceChoices.make(
            selected: nil,
            yandexMusic: Self.yandex,
            playing: [fromDisk],
            browsers: []
        )
        #expect(choices.yandexMusic == Self.yandex)
        #expect(choices.playing.isEmpty)
    }

    @Test func appWithoutPathKeyedByBundleID() {
        let noPath = Self.app("Chrome", id: "com.google.Chrome", path: "")
        let choices = SourceChoices.make(
            selected: nil,
            yandexMusic: nil,
            playing: [noPath, noPath],
            browsers: []
        )
        #expect(choices.playing == [noPath])
    }

    @Test func outputtingAppsComeFirstInStableOrder() {
        let vlc = Self.app("VLC", id: "org.videolan.vlc")
        let ordered = SourceChoices.outputtingFirst([
            (Self.chrome, false),
            (Self.safari, true),
            (Self.telegram, false),
            (vlc, true),
        ])
        #expect(ordered == [Self.safari, vlc, Self.chrome, Self.telegram])
        #expect(SourceChoices.outputtingFirst([]).isEmpty)
    }

    @Test func browserListIsFixed() {
        #expect(SourceChoices.browserBundleIDs == [
            "ru.yandex.desktop.yandex-browser",
            "com.google.Chrome",
            "org.mozilla.firefox",
            "com.apple.Safari",
        ])
    }
}
