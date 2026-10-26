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
            #expect(settings.softPulse == true)
            #expect(settings.hideDelay == 5)
            #expect(settings.hideInFullscreen == true)
            #expect(settings.showTrackBanner == true)
            #expect(settings.paused == false)
            #expect(settings.look == .waves)
            #expect(settings.glowSize == 1)
            #expect(settings.glowSharpness == 0.4)
            #expect(settings.flashLength == 1)
            #expect(settings.colorFlow == 0)
            #expect(settings.colorByBand == false)
            #expect(settings.softStop == true)
            #expect(settings.artworkGlow == true)
            #expect(settings.progressLine == true)
            #expect(settings.autoSource == false)
            #expect(settings.trackSwipe == true)
            #expect(settings.expandDelay == IslandStateMachine.defaultExpandDelay)
            #expect(settings.expandDelay == 0.15)
            #expect(settings.followDisplayOptions == true)
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
            written.softPulse = false
            written.hideDelay = 12
            written.hideInFullscreen = false
            written.showTrackBanner = false
            written.paused = true
            written.look = .spectrum
            written.colorFlow = 0.4
            written.colorByBand = true
            written.softStop = false
            written.artworkGlow = false
            written.progressLine = false
            written.autoSource = true
            written.trackSwipe = false
            written.expandDelay = 0.5
            written.followDisplayOptions = false

            let read = AppSettings(defaults: defaults)
            #expect(read.source == source)
            #expect(read.sensitivity == 2.5)
            #expect(read.levelMode == .absolute)
            #expect(read.followSystemVolume == false)
            #expect(read.latencyMode == .manual(milliseconds: 180))
            #expect(read.wingWidth == 96)
            #expect(read.glowIntensity == 0.25)
            #expect(read.beatPulse == false)
            #expect(read.softPulse == false)
            #expect(read.hideDelay == 12)
            #expect(read.hideInFullscreen == false)
            #expect(read.showTrackBanner == false)
            #expect(read.paused == true)
            #expect(read.look == .spectrum)
            #expect(read.colorFlow == 0.4)
            #expect(read.colorByBand == true)
            #expect(read.softStop == false)
            #expect(read.artworkGlow == false)
            #expect(read.progressLine == false)
            #expect(read.autoSource == true)
            #expect(read.trackSwipe == false)
            #expect(read.expandDelay == 0.5)
            #expect(read.followDisplayOptions == false)

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
            settings.softPulse = false
            settings.hideInFullscreen = false
            settings.showTrackBanner = false
            settings.paused = true
            settings.look = .spectrum
            settings.colorFlow = 0.7
            settings.colorByBand = true
            settings.softStop = false
            settings.artworkGlow = false
            settings.progressLine = false
            settings.autoSource = true
            settings.trackSwipe = false
            settings.expandDelay = 0.3
            settings.followDisplayOptions = false

            for key in [
                "wf.source", "wf.sensitivity", "wf.levelMode", "wf.followSystemVolume",
                "wf.latencyMode", "wf.wingWidth", "wf.glowIntensity", "wf.beatPulse", "wf.softPulse",
                "wf.hideDelay", "wf.hideInFullscreen", "wf.showTrackBanner", "wf.paused",
                "wf.waveStyle", "wf.colorFlow", "wf.colorByBand", "wf.softStop", "wf.artworkGlow",
                "wf.progressLine", "wf.autoSource", "wf.trackSwipe", "wf.expandDelay",
                "wf.followDisplayOptions",
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
            let look = try #require(defaults.data(forKey: "wf.waveStyle"))
            #expect(try decoder.decode(WaveLook.self, from: look) == .spectrum)
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
            settings.colorFlow = 3
            #expect(settings.colorFlow == 1)
            settings.colorFlow = -0.5
            #expect(settings.colorFlow == 0)
            settings.expandDelay = 5
            #expect(settings.expandDelay == IslandStateMachine.expandDelayRange.upperBound)
            settings.expandDelay = -1
            #expect(settings.expandDelay == IslandStateMachine.expandDelayRange.lowerBound)

            let read = AppSettings(defaults: defaults)
            #expect(read.sensitivity == 0.25)
            #expect(read.wingWidth == 40)
            #expect(read.latencyMode == .manual(milliseconds: 0))
            #expect(read.colorFlow == 0)
            #expect(read.expandDelay == 0)

            defaults.set(9.0, forKey: "wf.colorFlow")
            defaults.set(9.0, forKey: "wf.expandDelay")
            let stored = AppSettings(defaults: defaults)
            #expect(stored.colorFlow == 1)
            #expect(stored.expandDelay == 1)
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
            settings.colorFlow = 0.5
            settings.colorFlow = .nan
            #expect(settings.colorFlow == 0)
            settings.expandDelay = 0.6
            settings.expandDelay = .infinity
            #expect(settings.expandDelay == 0.15)

            defaults.set(Double.nan, forKey: "wf.colorFlow")
            defaults.set(Double.nan, forKey: "wf.expandDelay")
            let read = AppSettings(defaults: defaults)
            #expect(read.colorFlow == 0)
            #expect(read.expandDelay == 0.15)
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

    /// «Сдвиг синхронизации» по устройствам: пусто по умолчанию, JSON в `wf.syncOffsets`,
    /// переживает перезапуск, значения -100...100 мс с шагом 5 мс.
    @Test func syncOffsetsDefaultPersistAndClamp() {
        Self.withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            #expect(settings.syncOffsets == SyncOffsets())
            settings.syncOffsets.set(250, deviceUID: "airpods", name: "AirPods")
            settings.syncOffsets.set(-37, deviceUID: "", name: "")
            #expect(settings.syncOffsets.offset(forDeviceUID: "airpods") == 100)
            #expect(settings.syncOffsets.offset(forDeviceUID: "speakers") == -35)
            #expect(defaults.data(forKey: "wf.syncOffsets") != nil)
            #expect(defaults.object(forKey: "wf.syncOffset") == nil)

            let reloaded = AppSettings(defaults: defaults)
            #expect(reloaded.syncOffsets == settings.syncOffsets)
            #expect(reloaded.syncOffsets.byDevice["airpods"]?.name == "AirPods")

            settings.syncOffsets.reset(deviceUID: "airpods")
            #expect(AppSettings(defaults: defaults).syncOffsets.offset(forDeviceUID: "airpods") == -35)
        }
    }

    /// Старый общий сдвиг `wf.syncOffset` становится `fallbackMs`, пока нового ключа нет. Перенос
    /// ничего не пишет, старый ключ не меняется и после записи нового не читается. Мусор дает 0.
    @Test func legacySyncOffsetMigratesToFallback() {
        Self.withDefaults { defaults in
            defaults.set(42, forKey: "wf.syncOffset")
            let settings = AppSettings(defaults: defaults)
            #expect(settings.syncOffsets == SyncOffsets(fallbackMs: 40))
            #expect(settings.syncOffsets.offset(forDeviceUID: "airpods") == 40)
            #expect(defaults.object(forKey: "wf.syncOffsets") == nil)

            settings.syncOffsets.set(20, deviceUID: "airpods", name: "AirPods")
            #expect(defaults.data(forKey: "wf.syncOffsets") != nil)
            #expect(defaults.integer(forKey: "wf.syncOffset") == 42)

            defaults.set(-100, forKey: "wf.syncOffset")
            let reloaded = AppSettings(defaults: defaults)
            #expect(reloaded.syncOffsets.fallbackMs == 40)
            #expect(reloaded.syncOffsets.offset(forDeviceUID: "airpods") == 20)
        }
        Self.withDefaults { defaults in
            defaults.set(250, forKey: "wf.syncOffset")
            #expect(AppSettings(defaults: defaults).syncOffsets == SyncOffsets(fallbackMs: 100))
            defaults.set("не число", forKey: "wf.syncOffset")
            #expect(AppSettings(defaults: defaults).syncOffsets == SyncOffsets())
            defaults.set(Data([1, 2, 3]), forKey: "wf.syncOffset")
            #expect(AppSettings(defaults: defaults).syncOffsets == SyncOffsets())
            defaults.set(Double.nan, forKey: "wf.syncOffset")
            #expect(AppSettings(defaults: defaults).syncOffsets == SyncOffsets())

            // Испорченный JSON нового ключа считается отсутствием: снова перенос старого.
            defaults.set(-35, forKey: "wf.syncOffset")
            defaults.set(Data([1, 2, 3]), forKey: "wf.syncOffsets")
            #expect(AppSettings(defaults: defaults).syncOffsets == SyncOffsets(fallbackMs: -35))
        }
    }

    @Test func syncOffsetsObservedOnlyOnRealChanges() {
        Self.withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.syncOffsets.set(10, deviceUID: "airpods", name: "AirPods")
            let fired = ChangeFlag()
            withObservationTracking {
                _ = settings.syncOffsets
            } onChange: {
                fired.value = true
            }
            settings.syncOffsets.set(10, deviceUID: "airpods", name: "AirPods")
            settings.syncOffsets.reset(deviceUID: "speakers")
            #expect(!fired.value)
            settings.syncOffsets.set(15, deviceUID: "airpods", name: "AirPods")
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
            #expect(settings.syncOffsets == SyncOffsets())
            var expected = WaveAppearance.standard
            expected.wingWidth = 120
            #expect(settings.appearance == expected)

            let after = Set((defaults.persistentDomain(forName: suite) ?? [:]).keys)
            #expect(after == before)
        }
    }

    /// Обновление с 1.1: в домене ключи вида 1.1, новых ключей нет. Вид тот же, что был:
    /// стиль «Волны», без переливания и цвета по частотам, поля из домена. Функции 1.2 со
    /// значениями по умолчанию, ничего не дописывается.
    @Test func upgradeFrom11KeepsLook() throws {
        try Self.withSuite { defaults, suite in
            let encoder = JSONEncoder()
            defaults.set(150.0, forKey: "wf.wingWidth")
            defaults.set(try encoder.encode(WaveColorMode.preset(.ocean)), forKey: "wf.colorMode")
            defaults.set(2.0, forKey: "wf.glowRadius")
            defaults.set(4, forKey: "wf.lineCount")
            defaults.set(0.5, forKey: "wf.fill")
            defaults.set(1.5, forKey: "wf.lineThickness")
            defaults.set(0.75, forKey: "wf.waveAmplitude")
            defaults.set(0.8, forKey: "wf.glowIntensity")
            defaults.set(true, forKey: "wf.beatPulse")
            defaults.set(10.0, forKey: "wf.hideDelay")
            let before = Set((defaults.persistentDomain(forName: suite) ?? [:]).keys)
            #expect(before.count == 10)

            let settings = AppSettings(defaults: defaults)
            var expected = WaveAppearance.standard
            expected.wingWidth = 150
            expected.colorMode = .preset(.ocean)
            expected.glowSize = 2
            expected.lineCount = 4
            expected.fill = 0.5
            expected.thickness = 1.5
            expected.amplitude = 0.75
            #expect(settings.appearance == expected)
            #expect(settings.appearance.look == .waves)
            #expect(settings.appearance.colorFlow == 0)
            #expect(settings.appearance.colorByBand == false)
            #expect(settings.softStop == true)
            #expect(settings.artworkGlow == true)
            #expect(settings.progressLine == true)
            #expect(settings.autoSource == false)
            #expect(settings.trackSwipe == true)
            #expect(settings.expandDelay == IslandStateMachine.defaultExpandDelay)
            #expect(settings.followDisplayOptions == true)

            let after = Set((defaults.persistentDomain(forName: suite) ?? [:]).keys)
            #expect(after == before)
        }
    }

    /// Испорченный или неизвестный (из будущей версии) стиль дает «Волны».
    @Test func garbageLookFallsBackToWaves() {
        Self.withDefaults { defaults in
            defaults.set(Data("x".utf8), forKey: "wf.waveStyle")
            #expect(AppSettings(defaults: defaults).look == .waves)
            defaults.set(Data(#""hologram""#.utf8), forKey: "wf.waveStyle")
            #expect(AppSettings(defaults: defaults).look == .waves)
            defaults.set("spectrum", forKey: "wf.waveStyle")
            #expect(AppSettings(defaults: defaults).look == .waves)
        }
    }

    /// Стили «Минимал» и «Пульс» из 1.2 убраны: сохраненный выбор открывается как «Волны», вид из
    /// остальных настроек собирается без ошибок.
    @Test func removedLooksOpenAsWaves() {
        Self.withDefaults { defaults in
            for word in ["minimal", "pulse"] {
                defaults.set(Data("\"\(word)\"".utf8), forKey: "wf.waveStyle")
                let settings = AppSettings(defaults: defaults)
                #expect(settings.look == .waves)
                #expect(settings.appearance.look == .waves)
                #expect(!settings.appearance.lines.isEmpty)
            }
        }
    }

    /// Испорченный или неизвестный (палитра из будущей версии) режим цвета дает «Из обложки».
    @Test func garbageColorModeFallsBackToArtwork() {
        Self.withDefaults { defaults in
            defaults.set(Data("x".utf8), forKey: "wf.colorMode")
            #expect(AppSettings(defaults: defaults).colorMode == .artwork)
            defaults.set(Data(#"{"preset":{"_0":"plasma"}}"#.utf8), forKey: "wf.colorMode")
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
            written.glowSize = 2.5
            written.glowSharpness = 0.7
            written.flashLength = 1.5
            written.lineCount = 5
            written.fill = 0.4
            written.lineThickness = 1.5
            written.waveAmplitude = 0.75
            written.look = .spectrum
            written.colorFlow = 0.25
            written.colorByBand = true

            for key in [
                "wf.colorMode", "wf.glowSize", "wf.glowSharpness", "wf.flashLength", "wf.lineCount", "wf.fill", "wf.lineThickness", "wf.waveAmplitude",
            ] {
                #expect(defaults.object(forKey: key) != nil, "нет ключа \(key)")
            }
            let mode = try #require(defaults.data(forKey: "wf.colorMode"))
            #expect(try JSONDecoder().decode(WaveColorMode.self, from: mode) == .custom(PaletteColor(hex: 0x7A5CFF)))

            let read = AppSettings(defaults: defaults)
            #expect(read.wingWidth == 180)
            #expect(read.colorMode == .custom(PaletteColor(hex: 0x7A5CFF)))
            #expect(read.glowSize == 2.5)
            #expect(read.glowSharpness == 0.7)
            #expect(read.flashLength == 1.5)
            #expect(read.lineCount == 5)
            #expect(read.fill == 0.4)
            #expect(read.lineThickness == 1.5)
            #expect(read.waveAmplitude == 0.75)
            #expect(read.appearance == WaveAppearance(
                wingWidth: 180, colorMode: .custom(PaletteColor(hex: 0x7A5CFF)), glowSize: 2.5,
                lineCount: 5, fill: 0.4, thickness: 1.5, amplitude: 0.75,
                colorFlow: 0.25, colorByBand: true, look: .spectrum, glowSharpness: 0.7
            ))

            read.colorMode = .preset(.ocean)
            #expect(AppSettings(defaults: defaults).colorMode == .preset(.ocean))
        }
    }

    /// Сохраненный в 1.2 «Радиус свечения» становится «Размером свечения» с тем же значением и
    /// четкостью по умолчанию (размытие как в 1.2); читается без записи; свой ключ главнее старого.
    @Test(arguments: [0.5, 1.0, 2.0, 3.0])
    func glowRadiusFrom12BecomesSize(radius: Double) {
        Self.withSuite { defaults, suite in
            defaults.set(radius, forKey: "wf.glowRadius")
            let before = Set((defaults.persistentDomain(forName: suite) ?? [:]).keys)
            let settings = AppSettings(defaults: defaults)
            #expect(settings.glowSize == radius)
            #expect(settings.glowSharpness == 0.4)
            #expect(settings.appearance.glowSize == radius)
            #expect(settings.appearance.glowBlurScale == 1)
            #expect(Set((defaults.persistentDomain(forName: suite) ?? [:]).keys) == before)

            defaults.set(1.5, forKey: "wf.glowSize")
            #expect(AppSettings(defaults: defaults).glowSize == 1.5)
        }
    }

    /// Четкость и длительность вспышки держатся в диапазонах, не конечное значение заменяется стандартным.
    @Test func glowSharpnessAndFlashLengthClamp() {
        Self.withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.glowSharpness = 4
            #expect(settings.glowSharpness == 1)
            settings.glowSharpness = -1
            #expect(settings.glowSharpness == 0)
            settings.glowSharpness = .nan
            #expect(settings.glowSharpness == 0.4)
            settings.flashLength = 9
            #expect(settings.flashLength == 2)
            settings.flashLength = 0.1
            #expect(settings.flashLength == 0.5)
            settings.flashLength = .infinity
            #expect(settings.flashLength == 1)
        }
    }

    /// Новые значения держатся в диапазонах `WaveAppearance.Limits`, по умолчанию стандартные.
    /// Не конечный «Свой цвет» не ломает запись: JSON с NaN не кодируется, цвет заменяется.
    @Test func appearanceDefaultsAndClamps() {
        Self.withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            #expect(settings.appearance == .standard)
            settings.glowSize = 9
            #expect(settings.glowSize == 3)
            settings.glowSize = .nan
            #expect(settings.glowSize == 1)
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
