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

/// «Записать 30 с», во время записи «Запись… N с», после нее «Сохранено» и снова кнопка.
private struct RhythmRecordButton: View {
    let model: AppModel

    var body: some View {
        let recording = model.rhythmRecording
        HStack(spacing: 8) {
            switch recording.phase {
            case .idle, .saved, .failed:
                Button("Записать 30 с") {
                    model.startRhythmRecording()
                }
            case .recording(let seconds):
                Button("Запись… \(seconds) с") {}
                    .disabled(true)
            case .saving:
                Button("Сохраняю…") {}
                    .disabled(true)
            }
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
        .font(.system(size: 12))
        .help("Звук и вспышки за 30 с в ~/Library/Logs/WaveFeels, остров должен оставаться на экране")
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
