import AppKit
import Foundation
import Testing
@testable import WaveFeels

/// Остров в модели: курсор у выреза пересчитывает остров сразу и в срок задержек, о смене
/// состояния узнает окно у выреза. Демо без адаптера (`--demo` и `--no-capture`).
@Suite(.serialized)
@MainActor
struct AppModelIslandTests {
    @Test func pointerExpandsAndCollapsesIslandAndReportsStateChanges() async throws {
        _ = NSApplication.shared
        let suite = "com.wfeels.wavefeels.tests.island-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let model = AppModel(defaults: defaults)
        var changes: [IslandState] = []
        model.onIslandStateChange = { [weak model] in
            if let model { changes.append(model.islandState) }
        }
        model.start(arguments: LaunchArguments(demoFile: Self.demo, noCapture: true))
        defer { model.stop() }

        #expect(await waitUntil(.seconds(10)) { model.islandState == .collapsed })
        model.setPointerInHoverZone(true)
        #expect(model.pointerInHoverZone)
        #expect(await waitUntil(.seconds(5)) { model.islandState == .expanded })
        model.setPointerInHoverZone(false)
        #expect(await waitUntil(.seconds(5)) { model.islandState == .collapsed })
        #expect(changes == [.collapsed, .expanded, .collapsed])
    }

    /// `Resources/Demo/demo.wav` в корне репозитория.
    static var demo: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Demo/demo.wav")
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
