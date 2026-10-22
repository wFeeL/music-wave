import AppKit
import Foundation
import Testing
import WaveCore
@testable import WaveFeels

/// Источник по умолчанию определяется и тогда, когда пользователь выбрал свой: его показывает
/// пункт «По умолчанию (...)» в настройках.
@MainActor
struct AppModelDefaultSourceTests {
    private static let yandex = AudioSource.application(
        bundleID: "ru.yandex.desktop.music",
        bundlePath: "/Applications/Яндекс Музыка.app",
        displayName: "Яндекс Музыка"
    )
    private static let safari = AudioSource.application(
        bundleID: "com.apple.Safari",
        bundlePath: "/Applications/Safari.app",
        displayName: "Safari"
    )

    @Test func resolvesDefaultWhileExplicitSourceIsSet() throws {
        _ = NSApplication.shared
        let suite = "com.wfeels.wavefeels.tests.default-source-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let model = AppModel(defaults: defaults)
        model.settings.source = Self.safari
        model.defaultSourceResolver = { Self.yandex }
        #expect(model.defaultSource == .systemWide)

        model.start(arguments: LaunchArguments(noCapture: true))
        defer { model.stop() }
        #expect(model.defaultSource == Self.yandex)
        #expect(model.effectiveSource == Self.safari)

        // Снятый выбор сразу дает уже найденный источник по умолчанию.
        model.settings.source = nil
        #expect(model.effectiveSource == Self.yandex)
    }
}
