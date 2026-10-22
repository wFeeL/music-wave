import Foundation
import Observation
import Testing
import WaveCore
@testable import WaveFeels

/// Каждый тест работает на своем пустом `UserDefaults(suiteName:)` и удаляет его после себя.
@MainActor
struct AppSettingsTests {
    private static func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "wf-settings-test-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("UserDefaults(suiteName:) вернул nil")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    /// Источники, о которых Now Playing сообщал, переживают перезапуск; пустой bundle ID не пишется.
    @Test func nowPlayingSourceHistoryPersists() {
        Self.withDefaults { defaults in
            let history = NowPlayingSourceHistory(defaults: defaults)
            #expect(history.bundleIDs.isEmpty)
            history.insert("ru.yandex.desktop.music")
            history.insert("ru.yandex.desktop.music")
            history.insert("")
            #expect(history.bundleIDs == ["ru.yandex.desktop.music"])
            let reloaded = NowPlayingSourceHistory(defaults: defaults)
            #expect(reloaded.bundleIDs == ["ru.yandex.desktop.music"])
            #expect(defaults.stringArray(forKey: NowPlayingSourceHistory.key) == ["ru.yandex.desktop.music"])
        }
    }

    @Test func defaultsOnEmptyStore() {
        Self.withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            #expect(settings.source == nil)
            #expect(settings.sensitivity == 1.0)
            #expect(settings.levelMode == .auto)
            #expect(settings.followSystemVolume == true)
            #expect(settings.latencyMode == .auto)
            #expect(settings.wingWidth == 64)
            #expect(settings.glowIntensity == 0.6)
            #expect(settings.beatPulse == true)
            #expect(settings.hideDelay == 5)
            #expect(settings.hideInFullscreen == true)
            #expect(settings.paused == false)
        }
    }

    @Test func everyFieldSurvivesReload() {
        Self.withDefaults { defaults in
            let source = AudioSource.application(
                bundleID: "ru.yandex.desktop.music",
                bundlePath: "/Applications/Яндекс Музыка.app",
                displayName: "Яндекс Музыка"
            )
            let written = AppSettings(defaults: defaults)
            written.source = source
            written.sensitivity = 2.5
            written.levelMode = .absolute
            written.followSystemVolume = false
            written.latencyMode = .manual(milliseconds: 180)
            written.wingWidth = 96
            written.glowIntensity = 0.25
            written.beatPulse = false
            written.hideDelay = 12
            written.hideInFullscreen = false
            written.paused = true

            let read = AppSettings(defaults: defaults)
            #expect(read.source == source)
            #expect(read.sensitivity == 2.5)
            #expect(read.levelMode == .absolute)
            #expect(read.followSystemVolume == false)
            #expect(read.latencyMode == .manual(milliseconds: 180))
            #expect(read.wingWidth == 96)
            #expect(read.glowIntensity == 0.25)
            #expect(read.beatPulse == false)
            #expect(read.hideDelay == 12)
            #expect(read.hideInFullscreen == false)
            #expect(read.paused == true)

            read.source = .systemWide
            read.source = .systemWide
            #expect(AppSettings(defaults: defaults).source == .systemWide)
            read.source = nil
            #expect(AppSettings(defaults: defaults).source == nil)
        }
    }

    @Test func keysUsePrefixAndEnumsAreJSON() throws {
        try Self.withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.sensitivity = 2
            settings.levelMode = .absolute
            settings.latencyMode = .manual(milliseconds: 40)
            settings.source = .systemWide
            settings.wingWidth = 80
            settings.glowIntensity = 0.5
            settings.hideDelay = 7
            settings.followSystemVolume = false
            settings.beatPulse = false
            settings.hideInFullscreen = false
            settings.paused = true

            for key in [
                "wf.source", "wf.sensitivity", "wf.levelMode", "wf.followSystemVolume",
                "wf.latencyMode", "wf.wingWidth", "wf.glowIntensity", "wf.beatPulse",
                "wf.hideDelay", "wf.hideInFullscreen", "wf.paused",
            ] {
                #expect(defaults.object(forKey: key) != nil, "нет ключа \(key)")
            }
            let decoder = JSONDecoder()
            let mode = try #require(defaults.data(forKey: "wf.levelMode"))
            #expect(try decoder.decode(LevelMode.self, from: mode) == .absolute)
            let latency = try #require(defaults.data(forKey: "wf.latencyMode"))
            #expect(try decoder.decode(LatencyMode.self, from: latency) == .manual(milliseconds: 40))
            let source = try #require(defaults.data(forKey: "wf.source"))
            #expect(try decoder.decode(AudioSource.self, from: source) == .systemWide)
        }
    }

    @Test func settersClampRanges() {
        Self.withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.sensitivity = 10
            #expect(settings.sensitivity == 3)
            settings.sensitivity = 0
            #expect(settings.sensitivity == 0.25)
            settings.wingWidth = 500
            #expect(settings.wingWidth == 120)
            settings.wingWidth = 10
            #expect(settings.wingWidth == 40)
            settings.glowIntensity = 2
            #expect(settings.glowIntensity == 1)
            settings.glowIntensity = -1
            #expect(settings.glowIntensity == 0)
            settings.hideDelay = 100
            #expect(settings.hideDelay == 30)
            settings.hideDelay = 0
            #expect(settings.hideDelay == 1)
            settings.latencyMode = .manual(milliseconds: 900)
            #expect(settings.latencyMode == .manual(milliseconds: 500))
            settings.latencyMode = .manual(milliseconds: -20)
            #expect(settings.latencyMode == .manual(milliseconds: 0))

            let read = AppSettings(defaults: defaults)
            #expect(read.sensitivity == 0.25)
            #expect(read.wingWidth == 40)
            #expect(read.latencyMode == .manual(milliseconds: 0))
        }
    }

    @Test func nonFiniteValuesFallBackToDefaults() {
        Self.withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.sensitivity = .nan
            #expect(settings.sensitivity == 1)
            settings.wingWidth = .infinity
            #expect(settings.wingWidth == 64)
            settings.glowIntensity = -.infinity
            #expect(settings.glowIntensity == 0.6)
            settings.hideDelay = .nan
            #expect(settings.hideDelay == 5)
        }
    }

    @Test func observationFiresOnlyForRealChanges() {
        Self.withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            let fired = ChangeFlag()
            withObservationTracking {
                _ = settings.sensitivity
            } onChange: {
                fired.value = true
            }
            settings.sensitivity = 1
            settings.wingWidth = 100
            #expect(!fired.value)
            settings.sensitivity = 2
            #expect(fired.value)
        }
    }

    @Test func storedGarbageIsClampedOrIgnored() {
        Self.withDefaults { defaults in
            defaults.set(10.0, forKey: "wf.sensitivity")
            defaults.set(1.0, forKey: "wf.wingWidth")
            defaults.set(Data("не json".utf8), forKey: "wf.levelMode")
            defaults.set(Data("{}".utf8), forKey: "wf.source")
            if let latency = try? JSONEncoder().encode(LatencyMode.manual(milliseconds: 9000)) {
                defaults.set(latency, forKey: "wf.latencyMode")
            }

            let settings = AppSettings(defaults: defaults)
            #expect(settings.sensitivity == 3)
            #expect(settings.wingWidth == 40)
            #expect(settings.levelMode == .auto)
            #expect(settings.source == nil)
            #expect(settings.latencyMode == .manual(milliseconds: 500))
        }
    }
}

/// Флаг для `onChange`: замыкание `@Sendable`, а вызывается синхронно на том же потоке.
private final class ChangeFlag: @unchecked Sendable {
    var value = false
}
