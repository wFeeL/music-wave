import AppKit
import Foundation
import Testing
import WaveCore
@testable import WaveFeels

/// Кнопка источника в раскрытой панели: есть у приложения и нет у всего звука системы,
/// подсказка с именем приложения, название уступает ей место.
@MainActor
struct SourceButtonTests {
    private static func makeModel(source: AudioSource) throws -> (AppModel, () -> Void) {
        _ = NSApplication.shared
        let suite = "com.wfeels.wavefeels.tests.source-button-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let model = AppModel(defaults: defaults)
        model.settings.source = source
        return (model, { defaults.removePersistentDomain(forName: suite) })
    }

    @Test func noButtonForSystemWide() throws {
        let (model, cleanup) = try Self.makeModel(source: .systemWide)
        defer { cleanup() }
        #expect(model.sourceApp == nil)
    }

    @Test func buttonNamesTheSource() throws {
        let (model, cleanup) = try Self.makeModel(source: .application(
            bundleID: "ru.yandex.desktop.music",
            bundlePath: "/Applications/Яндекс Музыка.app",
            displayName: "Яндекс Музыка"
        ))
        defer { cleanup() }
        #expect(model.sourceApp?.name == "Яндекс Музыка")
    }

    @Test func tooltipText() {
        #expect(SourceAppButton.tooltip(for: "Safari") == "Открыть Safari")
    }

    @Test func titleMakesRoomForButton() {
        #expect(ExpandedPanelView.titleWidth(column: 200, hasSourceButton: true) == 172)
        #expect(ExpandedPanelView.titleWidth(column: 200, hasSourceButton: false) == 200)
    }
}
