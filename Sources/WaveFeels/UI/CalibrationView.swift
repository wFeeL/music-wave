import SwiftUI
import WaveCore

/// Лист «Калибровать…» у «Сдвига синхронизации»: метроном щелкает на устройстве вывода, а
/// предпросмотр острова вспыхивает на те же доли по правилам острова, и ползунок двигает вспышку,
/// пока она не совпадет со щелчком.
///
/// Свечение предпросмотра идет только от метронома (`Metronome.glowSchedule`): событие на
/// `щелчок + задержка вывода + сдвиг`, задержка вывода считается так же, как у анализа, по
/// устройству и режиму «Задержки волн». Захват и анализ музыки тем временем могут идти, на лист они
/// не влияют.
///
/// Ползунок правит сдвиг устройства, для которого лист открыт (`deviceUID`; пустой UID правит
/// общий сдвиг), и меняет его сразу, вместе с островом. «Готово» оставляет значение, «Отмена»,
/// Esc и любое другое закрытие возвращают все сдвиги, какими они были при открытии. Сменилось
/// устройство вывода: правка относилась к прежнему, поэтому лист закрывается как по «Отмене».
struct CalibrationView: View {
    static let width: CGFloat = 460

    let model: AppModel
    /// UID устройства вывода при открытии; пустой: устройство неизвестно, правится общий сдвиг.
    let deviceUID: String
    /// Имя устройства для подписи и записи в `SyncOffsets` (без имени там UID).
    let deviceName: String

    @Environment(\.dismiss) private var dismiss
    @State private var metronome: Metronome
    @State private var player: PreviewPlayer
    /// Сдвиги на момент открытия: к ним возвращает «Отмена».
    @State private var original: SyncOffsets? = nil
    /// Нажато «Готово»: при закрытии значение остается.
    @State private var confirmed = false

    init(model: AppModel, deviceUID: String, deviceName: String) {
        self.model = model
        self.deviceUID = deviceUID
        self.deviceName = deviceName
        let metronome = Metronome()
        _metronome = State(initialValue: metronome)
        _player = State(initialValue: PreviewPlayer(glowSchedule: { [model, deviceUID] presented in
            let settings = model.settings
            return metronome.glowSchedule(
                at: presented,
                outputLatency: LatencyCalculator.outputLatency(model.output.latency, mode: settings.latencyMode),
                offsetMs: settings.syncOffsets.offset(forDeviceUID: deviceUID)
            )
        }))
    }

    var body: some View {
        let settings = model.settings
        let offset = settings.syncOffsets.offset(forDeviceUID: deviceUID)
        VStack(alignment: .leading, spacing: 16) {
            Text("Поставьте музыку на паузу. Двигайте ползунок, пока вспышка не совпадет со щелчком.")
                .fixedSize(horizontal: false, vertical: true)
            IslandPreview(model: model, player: player, active: true, wingLimit: nil)
            SettingsSliderRow(
                "Сдвиг синхронизации",
                subtitle: deviceUID.isEmpty ? nil : "Для устройства: \(deviceName)",
                value: Binding(
                    get: { Double(offset) },
                    set: { settings.syncOffsets.set(Int($0.rounded()), deviceUID: deviceUID, name: deviceName) }
                ),
                in: Double(AppSettings.Limits.syncOffset.lowerBound)...Double(AppSettings.Limits.syncOffset.upperBound),
                text: AppModel.syncOffsetText(offset)
            )
            HStack {
                Spacer()
                Button("Отмена") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Готово") {
                    confirmed = true
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: Self.width)
        .onAppear {
            if original == nil {
                original = model.settings.syncOffsets
            }
            metronome.start()
        }
        .onDisappear {
            metronome.stop()
            if !confirmed, let original {
                model.settings.syncOffsets = original
            }
        }
        .onChange(of: model.pipeline.outputDeviceUID) { _, uid in
            guard uid != deviceUID else { return }
            dismiss()
        }
    }
}
