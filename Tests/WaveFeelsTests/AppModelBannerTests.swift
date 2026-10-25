import AppKit
import Foundation
import Testing
import WaveCore
@testable import WaveFeels

/// Баннер нового трека в модели: правила `TrackBanner` с входами модели (настройка «Показывать
/// новый трек», раскрытый остров, подавление острова, сон). Записи Now Playing подставляются:
/// напрямую в `updateBanner` или через `nowPlayingStub`, когда модель запущена (демо без
/// захвата и адаптера).
@Suite(.serialized)
@MainActor
struct AppModelBannerTests {
    static let a = NowPlayingInfo(bundleIdentifier: "com.apple.Music", title: "Первый", artist: "Исполнитель", isPlaying: true)
    static let b = NowPlayingInfo(bundleIdentifier: "com.apple.Music", title: "Второй", artist: "Исполнитель", isPlaying: true)
    static let c = NowPlayingInfo(bundleIdentifier: "com.apple.Music", title: "Третий", artist: "Исполнитель", isPlaying: true)

    @Test func showsAfterTrackChange() throws {
        try Self.withModel { model in
            model.updateBanner(now: 10, sourceInfo: Self.a)
            #expect(model.bannerPhase == .hidden)
            model.updateBanner(now: 20, sourceInfo: Self.b)
            #expect(model.bannerPhase == .hidden)
            model.updateBanner(now: 20.29, sourceInfo: Self.b)
            #expect(!model.bannerShown)
            model.updateBanner(now: 20.31, sourceInfo: Self.b)
            #expect(model.bannerPhase == .showing(AppModel.bannerKey(Self.b), textVisible: true))
            #expect(model.bannerShown)
            #expect(model.bannerTrack == Self.b)
            // Остров не запущен и скрыт: баннер в модели есть, но на экране его нет.
            #expect(!model.bannerVisible)
            model.updateBanner(now: 24, sourceInfo: Self.b)
            #expect(!model.bannerShown)
        }
    }

    @Test func disabledSettingHidesBanner() throws {
        try Self.withModel { model in
            model.settings.showTrackBanner = false
            model.updateBanner(now: 10, sourceInfo: Self.a)
            var now = 20.0
            for track in [Self.b, Self.c] {
                for _ in 0..<20 {
                    model.updateBanner(now: now, sourceInfo: track)
                    #expect(!model.bannerShown, "t \(now)")
                    now += 0.25
                }
            }
            // Включили: текущий трек уже базовый, баннера для него нет.
            model.settings.showTrackBanner = true
            for _ in 0..<20 {
                model.updateBanner(now: now, sourceInfo: Self.c)
                #expect(!model.bannerShown, "t \(now)")
                now += 0.25
            }
            // Видимый баннер выключение настройки скрывает сразу.
            model.updateBanner(now: now, sourceInfo: Self.a)
            model.updateBanner(now: now + 0.31, sourceInfo: Self.a)
            #expect(model.bannerShown)
            model.settings.showTrackBanner = false
            model.updateBanner(now: now + 0.5, sourceInfo: Self.a)
            #expect(!model.bannerShown)
        }
    }

    @Test func expandingCancelsBanner() async throws {
        try await Self.withRunningModel { model in
            model.nowPlayingStub = Self.b
            #expect(await waitUntil(.seconds(5)) { model.bannerVisible })
            #expect(model.bannerTrack == Self.b)

            model.setPointerInHoverZone(true)
            #expect(await waitUntil(.seconds(5)) { model.islandState == .expanded })
            #expect(model.bannerPhase == .hidden)
            #expect(!model.bannerVisible)

            model.setPointerInHoverZone(false)
            #expect(await waitUntil(.seconds(5)) { model.islandState == .collapsed })
            // B стал базовым, пока панель была открыта: после сворачивания баннера нет.
            try await Task.sleep(for: .milliseconds(1500))
            #expect(model.bannerPhase == .hidden)
        }
    }

    /// Review Focus 3: остров скрыт полноэкранным окном при «Скрывать в полноэкранном
    /// режиме», смена трека в это время баннера не дает ни сейчас, ни после.
    @Test func bannerSuppressedWhileIslandHiddenByFullscreen() throws {
        try Self.withModel { model in
            #expect(model.settings.hideInFullscreen)
            model.updateBanner(now: 10, sourceInfo: Self.a)
            model.fullscreenSuppressed = true
            #expect(model.islandSuppressed)
            var now = 20.0
            while now <= 25 {
                model.updateBanner(now: now, sourceInfo: Self.b)
                #expect(!model.bannerShown, "t \(now)")
                now += 0.25
            }
            model.fullscreenSuppressed = false
            while now <= 30 {
                model.updateBanner(now: now, sourceInfo: Self.b)
                #expect(!model.bannerShown, "t \(now)")
                now += 0.25
            }
            // Видимый баннер полноэкранное окно скрывает сразу.
            model.updateBanner(now: 40, sourceInfo: Self.c)
            model.updateBanner(now: 40.31, sourceInfo: Self.c)
            #expect(model.bannerShown)
            model.fullscreenSuppressed = true
            model.updateBanner(now: 40.5, sourceInfo: Self.c)
            #expect(!model.bannerShown)
        }
    }

    @Test func wakeResetsBaseline() async throws {
        try await Self.withRunningModel { model in
            model.systemWillSleep()
            // Во сне адаптер стоит: записи Now Playing нет.
            model.nowPlayingStub = nil
            model.systemDidWake()
            let wake = try #require(model.pendingWakeForTesting)
            await wake.value
            // Первый трек после пробуждения становится базовым без баннера.
            model.nowPlayingStub = Self.b
            try await Task.sleep(for: .milliseconds(1500))
            #expect(model.bannerPhase == .hidden)
            // Следующая смена показывается.
            model.nowPlayingStub = Self.c
            #expect(await waitUntil(.seconds(5)) { model.bannerShown })
        }
    }

    @Test func settingDefaultsToOn() throws {
        let suite = "com.wfeels.wavefeels.tests.banner-setting-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.showTrackBanner == true)
        settings.showTrackBanner = false
        #expect(defaults.object(forKey: "wf.showTrackBanner") as? Bool == false)
        #expect(AppSettings(defaults: defaults).showTrackBanner == false)
    }

    @Test func probeTrackBelongsToSourceAndChangesKey() {
        let music = AudioSource.application(
            bundleID: "ru.yandex.desktop.music", bundlePath: "/Applications/Yandex Music.app", displayName: "Яндекс Музыка"
        )
        for source in [music, AudioSource.systemWide] {
            let first = AppModel.probeTrack(index: 1, source: source)
            let second = AppModel.probeTrack(index: 2, source: source)
            #expect(first.belongs(to: source))
            #expect(first.isPlaying)
            #expect(AppModel.bannerKey(first) != AppModel.bannerKey(second))
        }
        #expect(AppModel.probeTrack(index: 1, source: music).bundleIdentifier == "ru.yandex.desktop.music")
    }

    // MARK: - Помощники

    /// Модель на чистых настройках, не запущенная: время баннера задают сами тесты.
    private static func withModel(_ body: (AppModel) throws -> Void) throws {
        let suite = "com.wfeels.wavefeels.tests.banner-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(AppModel(defaults: defaults))
    }

    /// Запущенная модель в демо без захвата, источник весь звук системы, играет трек A: остров
    /// свернут, A уже базовый.
    private static func withRunningModel(_ body: @MainActor (AppModel) async throws -> Void) async throws {
        _ = NSApplication.shared
        let suite = "com.wfeels.wavefeels.tests.banner-run-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        model.defaultSourceResolver = { .systemWide }
        model.nowPlayingStub = a
        model.start(arguments: LaunchArguments(demoFile: AppModelIslandTests.demo, noCapture: true))
        defer { model.stop() }
        #expect(await waitUntil(.seconds(30)) { model.islandState == .collapsed })
        // Несколько тиков с A: он базовый.
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.bannerPhase == .hidden)
        try await body(model)
    }
}

/// Ждет условия, отпуская главный актор между проверками.
@MainActor
private func waitUntil(_ timeout: Duration, _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
