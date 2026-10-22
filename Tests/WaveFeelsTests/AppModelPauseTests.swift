import AppKit
import Foundation
import Testing
@testable import WaveFeels

/// «Приостановить визуализацию» останавливает конвейер, «Возобновить» запускает снова. Демо без
/// адаптера (`--demo` и `--no-capture`): ни tap, ни Now Playing не нужны.
@MainActor
struct AppModelPauseTests {
    @Test func pauseStopsAndResumesDemo() throws {
        _ = NSApplication.shared
        try Self.withDefaults("pause") { defaults in
            let model = AppModel(defaults: defaults)
            model.start(arguments: Self.demoArguments)
            defer { model.stop() }
            #expect(model.pipeline.status == .demo)

            model.setPaused(true)
            #expect(model.settings.paused)
            #expect(model.pipeline.paused)
            #expect(model.pipeline.status == .paused)

            model.setPaused(false)
            #expect(!model.settings.paused)
            #expect(!model.pipeline.paused)
            #expect(model.pipeline.status == .demo)
        }
    }

    @Test func persistedPauseHoldsFromStart() throws {
        _ = NSApplication.shared
        try Self.withDefaults("persisted") { defaults in
            defaults.set(true, forKey: AppSettings.Key.paused)
            let model = AppModel(defaults: defaults)
            #expect(model.settings.paused)
            model.start(arguments: Self.demoArguments)
            defer { model.stop() }
            #expect(model.pipeline.status == .paused)

            model.setPaused(false)
            #expect(model.pipeline.status == .demo)
        }
    }

    private static var demoArguments: LaunchArguments {
        LaunchArguments(demoFile: demo, noCapture: true)
    }

    private static func withDefaults(_ name: String, _ body: (UserDefaults) throws -> Void) throws {
        let suite = "com.wfeels.wavefeels.tests.\(name)-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    /// `Resources/Demo/demo.wav` в корне репозитория.
    private static var demo: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Demo/demo.wav")
    }
}

/// Значок в строке меню: без доступа к звуку предупреждение видно и при закрытых окнах.
struct MenuBarIconTests {
    @Test func permissionProblemWinsOverPause() {
        #expect(AppModelHolder.iconName(paused: false, permissionHint: false) == "waveform")
        #expect(AppModelHolder.iconName(paused: true, permissionHint: false) == "waveform.slash")
        #expect(AppModelHolder.iconName(paused: false, permissionHint: true) == "waveform.badge.exclamationmark")
        #expect(AppModelHolder.iconName(paused: true, permissionHint: true) == "waveform.badge.exclamationmark")
    }
}
