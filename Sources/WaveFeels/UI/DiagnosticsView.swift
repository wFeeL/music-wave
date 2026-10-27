import SwiftUI
import WaveCore

/// Окно диагностики: живой уровень и бит, кнопки доступа и копирования, разделы из
/// `AppModel.diagnosticsSections()`. Разделы и статус доступа обновляются раз в секунду,
/// индикатор 30 раз в секунду, и то и другое только пока окно открыто и не свернуто. Под
/// разделом «Ритм» кнопка записи ритма (`RhythmRecording`).
struct DiagnosticsView: View {
    let model: AppModel
    let presence: WindowPresence

    @State private var sections: [DiagnosticsSection] = []
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LiveLevelView(store: model.store, isActive: presence.isOpen)
            buttons
            if model.permissionHint {
                Label(
                    "Нет доступа к звуку. Разрешите WaveFeels «Запись системного аудио» в разделе "
                        + "«Конфиденциальность и безопасность» Системных настроек.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            } else if model.captureStallHint {
                Label(AppModel.captureStallText, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            SectionView(section: section)
                            if section.title == AppModel.rhythmSectionTitle {
                                RhythmRecordButton(model: model)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 480)
        .task(id: presence.isOpen) {
            guard presence.isOpen else { return }
            while !Task.isCancelled {
                model.checkAudioPermission()
                let fresh = model.diagnosticsSections()
                if fresh != sections { sections = fresh }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Button("Запросить доступ к звуку") {
                model.requestAudioPermission()
            }
            Button("Открыть настройки конфиденциальности") {
                AppModel.openPrivacySettings()
            }
            Button("Скопировать диагностику") {
                model.copyDiagnostics()
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            }
            if copied {
                Text("Скопировано")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// «Записать 2 мин» (длина из выбора рядом), во время записи «Запись… N с», после нее
/// «Сохранено» и снова кнопка. Длина: «30 с», «1 мин», «2 мин», «5 мин» или «Своя» с полями минут и
/// секунд (10 с...10 мин, лишнее обрезается); выбор хранит `AppSettings.rhythmRecordingDuration`.
private struct RhythmRecordButton: View {
    /// Метка пункта «Своя» в выборе длины; быстрые значения помечены своими секундами.
    private static let customTag = -1

    let model: AppModel
    /// Выбрана «Своя» при длине, совпадающей с быстрым значением.
    @State private var customChosen = false
    /// Текст полей «мин» и «с» как набран. Длина обновляется на каждую правку (кнопка не отнимает
    /// фокус у поля, поэтому ждать Return нельзя); поля выравниваются по длине при показе.
    @State private var minutesText = ""
    @State private var secondsText = ""

    var body: some View {
        let recording = model.rhythmRecording
        let settings = model.settings
        let seconds = settings.rhythmRecordingDuration
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                switch recording.phase {
                case .idle, .saved, .failed:
                    Button(RhythmRecordingLength.buttonTitle(seconds: seconds)) {
                        model.startRhythmRecording()
                    }
                case .recording(let recorded):
                    Button(RhythmRecordingLength.progressTitle(seconds: recorded)) {}
                        .disabled(true)
                case .saving:
                    Button("Сохраняю…") {}
                        .disabled(true)
                }
                Picker("Длина записи", selection: lengthChoice) {
                    ForEach(RhythmRecordingLength.presets, id: \.self) { preset in
                        Text(RhythmRecordingLength.text(seconds: preset)).tag(preset)
                    }
                    Text("Своя").tag(Self.customTag)
                }
                .labelsHidden()
                .fixedSize()
                .disabled(recording.isBusy)
                switch recording.phase {
                case .saved:
                    Text("Сохранено")
                        .foregroundStyle(.secondary)
                case .failed(let message):
                    Text(message)
                        .foregroundStyle(.orange)
                case .idle, .recording, .saving:
                    EmptyView()
                }
            }
            if lengthChoice.wrappedValue == Self.customTag {
                HStack(spacing: 6) {
                    TextField("мин", text: minutesField)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 48)
                    Text("мин")
                    TextField("с", text: secondsField)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 48)
                    Text("с")
                    Text("от 10 с до 10 мин")
                        .foregroundStyle(.secondary)
                }
                .onAppear { syncFields() }
                .disabled(recording.isBusy)
            }
        }
        .font(.system(size: 12))
        .help("Звук и вспышки за выбранное время (от 10 с до 10 мин) в ~/Library/Logs/WaveFeels, остров должен оставаться на экране")
    }

    /// Выбранный пункт: быстрое значение, если длина равна ему и «Своя» не выбрана, иначе «Своя».
    private var lengthChoice: Binding<Int> {
        let settings = model.settings
        return Binding(
            get: {
                let seconds = settings.rhythmRecordingDuration
                return !customChosen && RhythmRecordingLength.presets.contains(seconds) ? seconds : Self.customTag
            },
            set: { choice in
                if choice == Self.customTag {
                    customChosen = true
                } else {
                    customChosen = false
                    settings.rhythmRecordingDuration = choice
                }
            }
        )
    }

    private var minutesField: Binding<String> {
        Binding(
            get: { minutesText },
            set: { text in
                minutesText = text
                applyFields()
            }
        )
    }

    private var secondsField: Binding<String> {
        Binding(
            get: { secondsText },
            set: { text in
                secondsText = text
                applyFields()
            }
        )
    }

    /// Длина из набранных полей (`RhythmRecordingLength.combine`, обрезается до 10 с...10 мин).
    /// «Своя» остается выбранной, даже если набранная длина совпала с быстрым значением: иначе
    /// поля исчезли бы посреди ввода.
    private func applyFields() {
        customChosen = true
        model.settings.rhythmRecordingDuration = RhythmRecordingLength.combine(
            minutes: RhythmRecordingLength.parse(minutesText), seconds: RhythmRecordingLength.parse(secondsText)
        )
    }

    /// Поля показывают сохраненную длину: 90 с это «1» и «30», 3 с это «0» и «10».
    private func syncFields() {
        let seconds = model.settings.rhythmRecordingDuration
        minutesText = String(seconds / 60)
        secondsText = String(seconds % 60)
    }
}

private struct SectionView: View {
    let section: DiagnosticsSection

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(section.title)
                .font(.headline)
            ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(row.label)
                        .foregroundStyle(.secondary)
                        .frame(width: 210, alignment: .leading)
                    Text(row.value)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 12))
            }
        }
    }
}

/// Сырой уровень в dBFS полоской от -80 до 0 и вспышка бита.
private struct LiveLevelView: View {
    static let floorDB: Float = -80

    let store: FrameStore
    let isActive: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isActive)) { _ in
            let frame = store.latest
            HStack(spacing: 10) {
                Text("Уровень")
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.quaternary)
                        Capsule()
                            .fill(.green)
                            .frame(width: proxy.size.width * Self.fraction(frame.rawLevelDB))
                    }
                }
                .frame(height: 8)
                Text(Self.decibels(frame.rawLevelDB))
                    .monospacedDigit()
                    .frame(width: 72, alignment: .trailing)
                Circle()
                    .fill(.orange.opacity(0.15 + 0.85 * Self.unit(frame.beat)))
                    .frame(width: 14, height: 14)
                Text("Бит")
            }
            .font(.system(size: 12))
        }
        .frame(height: 20)
    }

    private static func fraction(_ levelDB: Float) -> CGFloat {
        guard levelDB.isFinite else { return 0 }
        return CGFloat(min(max((levelDB - floorDB) / -floorDB, 0), 1))
    }

    private static func unit(_ value: Float) -> Double {
        value.isFinite ? Double(min(max(value, 0), 1)) : 0
    }

    private static func decibels(_ levelDB: Float) -> String {
        guard levelDB.isFinite, levelDB > floorDB else { return "тишина" }
        return "\(Int(levelDB.rounded())) дБ"
    }
}
