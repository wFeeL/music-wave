import SwiftUI
import WaveCore

/// Вкладка «Функции»: выключатели функций острова, свайп, автовыбор источника и учет системных
/// настроек экрана. Изменения применяются сразу; значения проходят через `AppSettings`, который
/// держит их в пределах. Предпросмотра здесь нет, на этой вкладке он стоит
/// (`PreviewPlayer.isActive`).
struct FeaturesSettingsView: View {
    let model: AppModel

    var body: some View {
        Form {
            Section("Остров") {
                islandRows
            }
            Section("Управление") {
                swipeRow
            }
            Section("Источник") {
                autoSourceRow
            }
            Section("Доступность") {
                displayOptionsRow
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Остров

    @ViewBuilder
    private var islandRows: some View {
        let settings = model.settings
        SettingsSliderRow(
            "Задержка раскрытия",
            value: Binding(get: { settings.expandDelay }, set: { settings.expandDelay = ($0 * 20).rounded() / 20 }),
            in: AppSettings.Limits.expandDelay,
            text: SettingsText.seconds(settings.expandDelay)
        )
        Toggle(isOn: Binding(get: { settings.progressLine }, set: { settings.progressLine = $0 })) {
            Text("Полоса прогресса")
            Text("Тонкая линия внизу острова: сколько трека прошло")
        }
        Toggle(isOn: Binding(get: { settings.artworkGlow }, set: { settings.artworkGlow = $0 })) {
            Text("Свечение обложки")
            Text("Сияние цвета обложки за раскрытой панелью")
        }
        Toggle(isOn: Binding(get: { settings.softStop }, set: { settings.softStop = $0 })) {
            Text("Мягкая остановка")
            Text("На паузе волны плавно затихают")
        }
        Toggle(isOn: Binding(get: { settings.softPulse }, set: { settings.softPulse = $0 })) {
            Text("Мягкий пульс")
            Text("Слабое свечение в такт, когда ритм не ясен")
        }
    }

    // MARK: - Управление

    private var swipeRow: some View {
        let settings = model.settings
        return Toggle(isOn: Binding(get: { settings.trackSwipe }, set: { settings.trackSwipe = $0 })) {
            Text("Свайп по острову")
            Text("Двумя пальцами: влево следующий трек, вправо предыдущий")
        }
    }

    // MARK: - Источник

    /// Включенный автовыбор показывает источник, от которого волны идут сейчас
    /// (`AppModel.effectiveSource`): выбранный автоматически или выбранный пользователем.
    private var autoSourceRow: some View {
        let settings = model.settings
        let caption = SettingsText.autoSource(
            enabled: settings.autoSource,
            current: settings.autoSource ? model.effectiveSource.displayName : ""
        )
        return Toggle(isOn: Binding(get: { settings.autoSource }, set: { settings.autoSource = $0 })) {
            Text("Автовыбор источника")
            Text(caption)
        }
    }

    // MARK: - Доступность

    private var displayOptionsRow: some View {
        let settings = model.settings
        return Toggle(
            isOn: Binding(get: { settings.followDisplayOptions }, set: { settings.followDisplayOptions = $0 })
        ) {
            Text("Учитывать контраст и прозрачность")
            Text("Как в Универсальном доступе: толще линии, без размытия")
        }
    }
}
