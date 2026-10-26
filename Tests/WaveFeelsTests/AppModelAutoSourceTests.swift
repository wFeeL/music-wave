import AppKit
import Foundation
import Testing
import WaveCore
@testable import WaveFeels

/// «Автовыбор источника» в модели: `updateAutoSource(now:)` с заданным временем, без запуска
/// модели (иначе тик подмешал бы настоящее время). Now Playing из `nowPlayingStub`, источник
/// кандидата из `autoSourceResolver`, процессы и вывод звука из `AudioProcessList`.
@MainActor
struct AppModelAutoSourceTests {
    private static let yandex = AutoSourceData.yandex
    private static let telegram = AutoSourceData.telegram
    private static let yandexProcess = AutoSourceData.yandexProcess
    private static let telegramProcess = AutoSourceData.telegramProcess

    private static let telegramPlaying = NowPlayingInfo(
        bundleIdentifier: AutoSourceData.telegramID, title: "Голосовое", isPlaying: true
    )
    private static let yandexPlaying = NowPlayingInfo(
        bundleIdentifier: AutoSourceData.yandexID, title: "Трек", isPlaying: true
    )
    private static let yandexPaused = NowPlayingInfo(
        bundleIdentifier: AutoSourceData.yandexID, title: "Трек", isPlaying: false
    )

    /// Telegram играет и выводит звук: через `AutoSourceSwitcher.confirm` источник Telegram, в
    /// настройках по-прежнему выбор пользователя. Снимок процессов читается не чаще раза в 0.5 с.
    /// Затем Telegram молчит, а Яндекс Музыка играет: через `AutoSourceSwitcher.release` возврат.
    @Test func autoSourceSwitchesAndReturns() throws {
        let fixture = try AutoSourceFixture()
        defer { fixture.tearDown() }
        let model = fixture.model
        model.settings.autoSource = true
        model.nowPlayingStub = Self.telegramPlaying
        fixture.world.outputting = [Self.telegramProcess]

        Self.run(model, tenths: 0...9)
        #expect(model.autoSource == nil)
        #expect(model.effectiveSource == Self.yandex)
        // Снимки на 0 и на 0.5 с, между ними кэш.
        #expect(fixture.world.snapshots == 2)
        #expect(model.autoSourceDescription == "ждет")

        model.updateAutoSource(now: AutoSourceSwitcher.confirm)
        #expect(model.autoSource == Self.telegram)
        #expect(model.effectiveSource == Self.telegram)
        #expect(model.settings.source == Self.yandex)
        #expect(model.autoSourceDescription == "сейчас Telegram")

        // Пока Telegram играет, источник держится.
        Self.run(model, tenths: 11...19)
        #expect(model.effectiveSource == Self.telegram)

        model.nowPlayingStub = Self.yandexPlaying
        fixture.world.outputting = [Self.yandexProcess]
        Self.run(model, tenths: 20...39)
        #expect(model.effectiveSource == Self.telegram)
        model.updateAutoSource(now: 2.0 + AutoSourceSwitcher.release)
        #expect(model.autoSource == nil)
        #expect(model.effectiveSource == Self.yandex)
        #expect(model.settings.source == Self.yandex)
    }

    /// Автовыбор выключен: источник пользователя, процессы не читаются. Выключение во время
    /// автоматического выбора сразу возвращает выбор пользователя.
    @Test func autoSourceOffKeepsUserSource() throws {
        let fixture = try AutoSourceFixture()
        defer { fixture.tearDown() }
        let model = fixture.model
        model.nowPlayingStub = Self.telegramPlaying
        fixture.world.outputting = [Self.telegramProcess]

        Self.run(model, tenths: 0...50)
        #expect(model.autoSource == nil)
        #expect(model.effectiveSource == Self.yandex)
        #expect(fixture.world.snapshots == 0)
        #expect(fixture.world.resolved == 0)
        #expect(model.autoSourceDescription == "выкл")

        model.settings.autoSource = true
        Self.run(model, tenths: 51...61)
        #expect(model.effectiveSource == Self.telegram)

        model.settings.autoSource = false
        model.updateAutoSource(now: 6.2)
        #expect(model.autoSource == nil)
        #expect(model.effectiveSource == Self.yandex)
        #expect(model.settings.source == Self.yandex)
    }

    /// Идет автоматический выбор Telegram. Now Playing переключился на Яндекс Музыку на паузе,
    /// а ее процесс выводит звук: выбранное считается молчащим по Now Playing, возврата нет.
    @Test func chosenPlayingPrefersNowPlaying() throws {
        let fixture = try AutoSourceFixture()
        defer { fixture.tearDown() }
        let model = fixture.model
        model.settings.autoSource = true
        model.nowPlayingStub = Self.telegramPlaying
        fixture.world.outputting = [Self.telegramProcess]
        Self.run(model, tenths: 0...10)
        #expect(model.effectiveSource == Self.telegram)

        model.nowPlayingStub = Self.yandexPaused
        fixture.world.outputting = [Self.yandexProcess]
        // Возврат по выводу звука был бы на 2.0 + `release` с.
        Self.run(model, tenths: 20...60)
        #expect(model.autoSource == Self.telegram)
        #expect(model.effectiveSource == Self.telegram)
    }

    /// `updateAutoSource` на каждой десятой доле секунды из `tenths`.
    private static func run(_ model: AppModel, tenths: ClosedRange<Int>) {
        for tenth in tenths {
            model.updateAutoSource(now: Double(tenth) / 10)
        }
    }
}

/// Мир теста: какие процессы выводят звук, сколько раз читались снимок процессов и источник
/// кандидата.
@MainActor
private final class AutoSourceWorld {
    var outputting: Set<UInt32> = []
    var snapshots = 0
    var resolved = 0
}

/// Источники, процессы Яндекс Музыки и Telegram и их bundle ID. Вне главного актора: значения
/// `Sendable`, их читают и тесты, и хуки модели.
private enum AutoSourceData {
    static let yandexID = "ru.yandex.desktop.music"
    static let telegramID = "ru.keepcoder.Telegram"
    static let yandex = AudioSource.application(
        bundleID: yandexID,
        bundlePath: "/nonexistent/Яндекс Музыка.app",
        displayName: "Яндекс Музыка"
    )
    static let telegram = AudioSource.application(
        bundleID: telegramID,
        bundlePath: "/nonexistent/Telegram.app",
        displayName: "Telegram"
    )
    static let yandexProcess: UInt32 = 10
    static let telegramProcess: UInt32 = 20
    static let processes = [
        AudioProcessInfo(
            objectID: yandexProcess, pid: 101, bundleID: yandexID,
            executablePath: "/nonexistent/Яндекс Музыка.app/Contents/MacOS/Яндекс Музыка", isRunningOutput: false
        ),
        AudioProcessInfo(
            objectID: telegramProcess, pid: 102, bundleID: telegramID,
            executablePath: "/nonexistent/Telegram.app/Contents/MacOS/Telegram", isRunningOutput: false
        ),
    ]
}

/// Модель с выбранной Яндекс Музыкой и подставленными хуками: процессы из `AutoSourceData`,
/// вывод звука по `world.outputting`, источник находится только у Telegram. Домен настроек
/// удаляется в `tearDown()`.
@MainActor
private struct AutoSourceFixture {
    let model: AppModel
    let world: AutoSourceWorld
    private let defaults: UserDefaults
    private let suite: String

    init() throws {
        _ = NSApplication.shared
        let suite = "com.wfeels.wavefeels.tests.auto-source-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let world = AutoSourceWorld()
        let model = AppModel(defaults: defaults)
        model.settings.source = AutoSourceData.yandex
        model.processList.snapshotOverride = {
            world.snapshots += 1
            return AutoSourceData.processes
        }
        model.processList.runningOutputOverride = { world.outputting.contains($0) }
        model.autoSourceResolver = { bundleID in
            world.resolved += 1
            return bundleID == AutoSourceData.telegramID ? AutoSourceData.telegram : nil
        }
        self.suite = suite
        self.defaults = defaults
        self.world = world
        self.model = model
    }

    func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }
}
