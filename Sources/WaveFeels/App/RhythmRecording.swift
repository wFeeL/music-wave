import AppKit
import Observation
import QuartzCore
import WaveCore

/// Кнопка «Записать 30 с» в разделе «Ритм» диагностики: 30 с анализа, расписаний свечения и
/// вспышек рендера (`RhythmSession`) и звук, как его слышал анализ, в
/// `~/Library/Logs/WaveFeels/rhythm-<yyyyMMdd-HHmmss>.json` и `.wav`.
///
/// Кто пишет: звук, онсеты и расписания очередь анализа (`AnalysisEngine`, через
/// `AudioPipeline.recordRhythm`), вспышки кадр острова на главном акторе (`frame(...)` из
/// `AppModel.islandVisuals`, правило то же, что в `OfflineBeatChain`: рост свечения больше 0.2
/// между соседними кадрами `TimelineView`). Опрос раз в 0.25 с на главном акторе ждет, пока звук
/// набран и показан последний кадр, который мог по нему вспыхнуть, или пока запись не кончится
/// раньше (остров скрылся, захват остановлен или начат заново, пропуск в потоке, поток встал).
/// Тогда запись снимается с анализа, JSON и WAV пишутся вне главного потока, Finder показывает
/// файлы, кнопка 3 с пишет «Сохранено». Без звука за 3 с запись бросается без файлов.
@MainActor
@Observable
final class RhythmRecording {
    enum Phase: Equatable {
        case idle
        /// Секунд звука записано.
        case recording(seconds: Int)
        case saving
        case saved
        case failed(String)
    }

    static let duration = 30.0
    static let pollInterval: Duration = .milliseconds(250)
    /// Сколько ждать первого шага анализа, с.
    static let startTimeout = 3.0
    /// Запас после слышимого конца звука, с: кадры до него уже показаны.
    static let tail = 0.1
    /// Предел всей записи сверх `duration`, с (например, рендер стоит).
    static let overrun = 10.0
    /// Сколько показывать «Сохранено» или ошибку.
    static let messageDuration: Duration = .seconds(3)

    private(set) var phase: Phase = .idle

    private let pipeline: AudioPipeline
    @ObservationIgnored private var session: RhythmSession?
    /// Свечение прошлого кадра: рост считается и без записи, чтобы первый кадр записи не дал
    /// ложной вспышки. Читается тестами: это вход записи с последнего кадра острова.
    @ObservationIgnored private(set) var previousGlow: Float = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Запись файлов: `cancel()` ее не прерывает, но после нее ни Finder, ни «Сохранено».
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// «Уменьшение движения» уже отмечено в этой записи.
    @ObservationIgnored private var notedReduceMotion = false
    @ObservationIgnored private var startedAt = 0.0
    @ObservationIgnored private var stamp = ""

    init(pipeline: AudioPipeline) {
        self.pipeline = pipeline
    }

    /// Идет запись или сохранение: кнопка недоступна.
    var isBusy: Bool {
        switch phase {
        case .recording, .saving: true
        case .idle, .saved, .failed: false
        }
    }

    /// Начинает запись; `meta`: версия, сборка, устройство, режим задержки и период отрисовки.
    func start(meta: RhythmLog.Meta) {
        guard !isBusy else { return }
        task?.cancel()
        let session = RhythmSession(RhythmRecorder(duration: Self.duration, meta: meta))
        self.session = session
        notedReduceMotion = meta.reduceMotion
        startedAt = CACurrentMediaTime()
        stamp = Self.stamp(Date())
        pipeline.recordRhythm(session)
        phase = .recording(seconds: 0)
        Log.file("запись ритма начата")
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: RhythmRecording.pollInterval)
                guard let self, !Task.isCancelled else { return }
                if self.poll(now: CACurrentMediaTime()) { return }
            }
        }
    }

    /// Кадр острова с моментом показа `presented` (секунды хоста), свечением доли `glow` и мягким
    /// пульсом `ambient` на него (пульс идет только в итог пульса записи, вспышки считаются по
    /// `glow`). Зовется один раз на кадр `TimelineView`; без записи только запоминает свечение и
    /// ничего не выделяет. `reduceMotion`: «Уменьшение движения» на этом кадре (свечения нет), один
    /// раз за запись отмечается в ней.
    func frame(
        presented: Double, glow: Float, ambient: Float, schedule: BeatSchedule?, refreshPeriod: Double, reduceMotion: Bool
    ) {
        let rise = glow - previousGlow
        previousGlow = glow
        guard let session else { return }
        if reduceMotion, !notedReduceMotion {
            notedReduceMotion = true
            session.noteReduceMotion()
        }
        session.appendFrame(
            presentedHost: presented, glowRise: rise, schedule: schedule ?? .empty, refreshPeriod: refreshPeriod, ambient: ambient
        )
    }

    /// Остановка модели: запись бросается без файлов.
    func cancel() {
        task?.cancel()
        task = nil
        saveTask?.cancel()
        saveTask = nil
        if let session {
            session.stop(.stopped)
            pipeline.recordRhythm(nil)
        }
        session = nil
        phase = .idle
    }

    /// `true`: запись кончилась и сохраняется (или брошена).
    private func poll(now: Double) -> Bool {
        guard let session else { return true }
        let status = session.status
        let elapsed = now - startedAt
        var done = elapsed > Self.duration + Self.overrun
        if !status.started {
            done = done || status.endReason != nil || elapsed > Self.startTimeout
        } else if let reason = status.endReason {
            if reason == .complete, let end = status.audibleEndHost {
                done = done || now >= end + Self.tail
            } else {
                done = true
            }
        }
        if done {
            finish(session)
            return true
        }
        let seconds = Int(status.audioSeconds)
        if phase != .recording(seconds: seconds) {
            phase = .recording(seconds: seconds)
        }
        return false
    }

    private func finish(_ session: RhythmSession) {
        self.session = nil
        task = nil
        pipeline.recordRhythm(nil)
        session.stop(.stopped)
        let (log, samples) = session.finish()
        Log.file(
            "запись ритма кончилась: \(log.meta.endReason.rawValue), звука \(String(format: "%.1f", log.meta.audioSeconds)) с, "
                + "вспышек \(log.flashes.count)"
        )
        guard !samples.isEmpty else {
            // Анализ не дал ни шага: нет звука, остров скрыт (анализ в простое) или захват на паузе.
            show(.failed("Нет звука или остров скрыт"))
            return
        }
        phase = .saving
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/WaveFeels", isDirectory: true)
        let names = RhythmLog.fileNames(stamp: stamp)
        saveTask = Task { @MainActor [weak self] in
            do {
                let urls = try await Task.detached(priority: .utility) {
                    try RhythmRecording.write(log: log, samples: samples, directory: directory, json: names.json, wav: names.wav)
                }.value
                guard !Task.isCancelled else { return }
                NSWorkspace.shared.activateFileViewerSelecting(urls)
                Log.file("запись ритма сохранена: \(names.json), \(names.wav)")
                self?.show(.saved)
            } catch {
                Log.file("запись ритма не сохранилась: \(error.localizedDescription)")
                guard !Task.isCancelled else { return }
                self?.show(.failed("Не удалось сохранить"))
            }
        }
    }

    /// Показывает итог `result` на `messageDuration`, затем снова кнопку.
    private func show(_ result: Phase) {
        phase = result
        task?.cancel()
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: RhythmRecording.messageDuration)
            guard let self, !Task.isCancelled, self.phase == result else { return }
            self.phase = .idle
        }
    }

    /// Пишет WAV и JSON в `directory`; возвращает пути JSON и WAV. Вне главного потока.
    nonisolated static func write(log: RhythmLog, samples: [Int16], directory: URL, json: String, wav: String) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let jsonURL = directory.appendingPathComponent(json)
        let wavURL = directory.appendingPathComponent(wav)
        let rate = Int(log.meta.sampleRate.rounded())
        try WAVWriter.pcm16Mono(samples, sampleRate: rate).write(to: wavURL, options: .atomic)
        try log.encoded().write(to: jsonURL, options: .atomic)
        return [jsonURL, wavURL]
    }

    /// «20261022-153012» по местному времени.
    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
