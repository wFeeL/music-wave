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

    /// То же с именем домена: по нему видно, какие ключи записаны.
    private static func withSuite(_ body: (UserDefaults, String) throws -> Void) rethrows {
        let suite = "wf-settings-test-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("UserDefaults(suiteName:) вернул nil")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults, suite)
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
            #expect(settings.showTrackBanner == true)
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
            written.showTrackBanner = false
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
            #expect(read.showTrackBanner == false)
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
            settings.showTrackBanner = false
            settings.paused = true

            for key in [
                "wf.source", "wf.sensitivity", "wf.levelMode", "wf.followSystemVolume",
                "wf.latencyMode", "wf.wingWidth", "wf.glowIntensity", "wf.beatPulse",
                "wf.hideDelay", "wf.hideInFullscreen", "wf.showTrackBanner", "wf.paused",
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
            #expect(settings.wingWidth == 200)
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

    /// «Сдвиг синхронизации»: 0 по умолчанию, -100...100 мс, шаг 5 мс, мусор в хранилище дает 0.
    @Test func syncOffsetDefaultsAndClamps() {
        Self.withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            #expect(settings.syncOffsetMs == 0)
            settings.syncOffsetMs = 250
            #expect(settings.syncOffsetMs == 100)
            settings.syncOffsetMs = -37
            #expect(settings.syncOffsetMs == -35)
            #expect(defaults.object(forKey: "wf.syncOffset") != nil)
            #expect(AppSettings(defaults: defaults).syncOffsetMs == -35)
            settings.syncOffsetMs = -500
            #expect(settings.syncOffsetMs == -100)
        }
        Self.withDefaults { defaults in
            defaults.set("не число", forKey: "wf.syncOffset")
            #expect(AppSettings(defaults: defaults).syncOffsetMs == 0)
            defaults.set(Data([1, 2, 3]), forKey: "wf.syncOffset")
            #expect(AppSettings(defaults: defaults).syncOffsetMs == 0)
            defaults.set(Double.nan, forKey: "wf.syncOffset")
            #expect(AppSettings(defaults: defaults).syncOffsetMs == 0)
            defaults.set(42, forKey: "wf.syncOffset")
            #expect(AppSettings(defaults: defaults).syncOffsetMs == 40)
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

extension AppSettingsTests {
    /// Обновление с 0.9.0: в домене только старые ключи. Значения не меняются, вид волн
    /// стандартный с шириной крыла из настроек, ничего не дописывается.
    @Test func upgradeFrom090KeepsValuesAndWritesNothing() throws {
        try Self.withSuite { defaults, suite in
            let source = AudioSource.application(
                bundleID: "ru.yandex.desktop.music",
                bundlePath: "/Applications/Яндекс Музыка.app",
                displayName: "Яндекс Музыка"
            )
            let encoder = JSONEncoder()
            defaults.set(120.0, forKey: "wf.wingWidth")
            defaults.set(0.3, forKey: "wf.glowIntensity")
            defaults.set(false, forKey: "wf.beatPulse")
            defaults.set(try encoder.encode(LatencyMode.manual(milliseconds: 80)), forKey: "wf.latencyMode")
            defaults.set(try encoder.encode(source), forKey: "wf.source")
            let before = Set((defaults.persistentDomain(forName: suite) ?? [:]).keys)
            #expect(before.count == 5)

            let settings = AppSettings(defaults: defaults)
            #expect(settings.wingWidth == 120)
            #expect(settings.glowIntensity == 0.3)
            #expect(settings.beatPulse == false)
            #expect(settings.latencyMode == .manual(milliseconds: 80))
            #expect(settings.source == source)
            #expect(settings.syncOffsetMs == 0)
            var expected = WaveAppearance.standard
            expected.wingWidth = 120
            #expect(settings.appearance == expected)

            let after = Set((defaults.persistentDomain(forName: suite) ?? [:]).keys)
            #expect(after == before)
        }
    }

    /// Испорченный или неизвестный (палитра из будущей версии) режим цвета дает «Из обложки».
    @Test func garbageColorModeFallsBackToArtwork() {
        Self.withDefaults { defaults in
            defaults.set(Data("x".utf8), forKey: "wf.colorMode")
            #expect(AppSettings(defaults: defaults).colorMode == .artwork)
            defaults.set(Data(#"{"preset":{"_0":"rainbow"}}"#.utf8), forKey: "wf.colorMode")
            #expect(AppSettings(defaults: defaults).colorMode == .artwork)
            defaults.set("не данные", forKey: "wf.colorMode")
            #expect(AppSettings(defaults: defaults).colorMode == .artwork)
        }
    }

    @Test func appearanceKeysPersist() throws {
        try Self.withDefaults { defaults in
            let written = AppSettings(defaults: defaults)
            written.wingWidth = 180
            written.colorMode = .custom(PaletteColor(hex: 0x7A5CFF))
            written.glowRadius = 2.5
            written.lineCount = 5
            written.fill = 0.4
            written.lineThickness = 1.5
            written.waveAmplitude = 0.75

            for key in [
                "wf.colorMode", "wf.glowRadius", "wf.lineCount", "wf.fill", "wf.lineThickness", "wf.waveAmplitude",
            ] {
                #expect(defaults.object(forKey: key) != nil, "нет ключа \(key)")
            }
            let mode = try #require(defaults.data(forKey: "wf.colorMode"))
            #expect(try JSONDecoder().decode(WaveColorMode.self, from: mode) == .custom(PaletteColor(hex: 0x7A5CFF)))

            let read = AppSettings(defaults: defaults)
            #expect(read.wingWidth == 180)
            #expect(read.colorMode == .custom(PaletteColor(hex: 0x7A5CFF)))
            #expect(read.glowRadius == 2.5)
            #expect(read.lineCount == 5)
            #expect(read.fill == 0.4)
            #expect(read.lineThickness == 1.5)
            #expect(read.waveAmplitude == 0.75)
            #expect(read.appearance == WaveAppearance(
                wingWidth: 180, colorMode: .custom(PaletteColor(hex: 0x7A5CFF)), glowRadius: 2.5,
                lineCount: 5, fill: 0.4, thickness: 1.5, amplitude: 0.75
            ))

            read.colorMode = .preset(.ocean)
            #expect(AppSettings(defaults: defaults).colorMode == .preset(.ocean))
        }
    }

    /// Новые значения держатся в диапазонах `WaveAppearance.Limits`, по умолчанию стандартные.
    /// Не конечный «Свой цвет» не ломает запись: JSON с NaN не кодируется, цвет заменяется.
    @Test func appearanceDefaultsAndClamps() {
        Self.withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            #expect(settings.appearance == .standard)
            settings.glowRadius = 9
            #expect(settings.glowRadius == 3)
            settings.glowRadius = .nan
            #expect(settings.glowRadius == 1)
            settings.lineCount = 0
            #expect(settings.lineCount == 1)
            settings.lineCount = 40
            #expect(settings.lineCount == 6)
            settings.fill = 2
            #expect(settings.fill == 1)
            settings.lineThickness = 0.1
            #expect(settings.lineThickness == 0.5)
            settings.waveAmplitude = .infinity
            #expect(settings.waveAmplitude == 1)

            settings.colorMode = .custom(PaletteColor(r: .nan, g: 0.5, b: 2))
            guard case .custom(let color) = settings.colorMode else {
                Issue.record("режим не «Свой цвет»: \(settings.colorMode)")
                return
            }
            #expect(color.r.isFinite && color.g.isFinite && color.b.isFinite)
            #expect(defaults.data(forKey: "wf.colorMode") != nil)
            #expect(AppSettings(defaults: defaults).colorMode == settings.colorMode)

            defaults.set(1000.0, forKey: "wf.wingWidth")
            defaults.set(7.5, forKey: "wf.lineCount")
            #expect(AppSettings(defaults: defaults).wingWidth == 200)
            #expect(AppSettings(defaults: defaults).lineCount == 6)
        }
    }
}

/// Флаг для `onChange`: замыкание `@Sendable`, а вызывается синхронно на том же потоке.
private final class ChangeFlag: @unchecked Sendable {
    var value = false
}
