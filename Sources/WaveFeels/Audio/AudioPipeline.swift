import CoreAudio
import Foundation
import Observation
import WaveCore

enum PipelineStatus: Equatable, Sendable {
    case stopped
    case demo
    case capturing(TapStatus)
    case waitingForSource
    case rebuilding(attempt: Int)
    /// Долгая тишина: IOProc и анализ остановлены, подписки работают.
    case suspended
}

/// Выбор источника, сборка и пересборка захвата, сторож нулей.
///
/// Пересобирает tap при смене совпавших процессов, устройства вывода, его частоты, источника,
/// после перезапуска coreaudiod (через `OutputDeviceMonitor`) и по явному `rebuild(reason:)`.
/// Пересборки не чаще раза в 250 мс.
@MainActor
@Observable
final class AudioPipeline {
    static let ringCapacity = 131_072
    static let minRebuildInterval = 0.25
    static let zeroRunLimit = 2.5
    static let maxWatchdogRebuilds = 5
    static let watchdogPauses: [Double] = [1, 2, 4]

    private(set) var status: PipelineStatus = .stopped
    private(set) var matchedProcesses: [AudioProcessInfo] = []
    private(set) var sourceOutputting = false
    /// Сколько пересборок подряд сделал сторож нулей; сбрасывается, когда пошел ненулевой звук.
    private(set) var watchdogRebuilds = 0

    /// Источник по Now Playing «играет». Выставляет `AppModel`.
    @ObservationIgnored var adapterSaysPlaying = false {
        didSet { if adapterSaysPlaying != oldValue { updateSourceOutputting() } }
    }

    /// Now Playing работает. Тогда «источник звучит» решает только он. Выставляет `AppModel`.
    @ObservationIgnored var adapterAvailable = false {
        didSet { if adapterAvailable != oldValue { updateSourceOutputting() } }
    }

    @ObservationIgnored var source: AudioSource = .systemWide {
        didSet {
            guard source != oldValue else { return }
            watchdogRebuilds = 0
            processesChanged()
            rebuild(reason: "смена источника")
        }
    }

    /// `systemVolume` всегда берется из `OutputDeviceMonitor` (0 без звука).
    @ObservationIgnored var settings = LevelSettings() {
        didSet {
            let volume = output.effectiveVolume
            if settings.systemVolume != volume { settings.systemVolume = volume }
            pushSettings()
        }
    }

    @ObservationIgnored var latencyMode: LatencyMode = .auto {
        didSet { if latencyMode != oldValue { pushSettings() } }
    }

    private enum Mode {
        case stopped, live, suspended, demo
    }

    private let processes: AudioProcessList
    private let output: OutputDeviceMonitor
    private let ring: SampleRingBuffer
    private let capture: ProcessTapCapture
    private let engine: AnalysisEngine

    @ObservationIgnored private var demo: DemoAudioSource?
    @ObservationIgnored private var mode = Mode.stopped
    @ObservationIgnored private var appliedProcessIDs: [AudioObjectID] = []
    @ObservationIgnored private var lastRebuildAt = -Double.infinity
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var watchdogTask: Task<Void, Never>?

    init(store: FrameStore, processes: AudioProcessList, output: OutputDeviceMonitor) {
        self.processes = processes
        self.output = output
        let ring = SampleRingBuffer(capacity: Self.ringCapacity)
        self.ring = ring
        self.capture = ProcessTapCapture(ring: ring)
        self.engine = AnalysisEngine(ring: ring, store: store)

        processes.onChange = { [weak self] in
            self?.processesChanged()
        }
        output.onDeviceChange = { [weak self] in
            self?.pushSettings()
            self?.rebuild(reason: "устройство вывода")
        }
        output.onVolumeChange = { [weak self] in
            self?.volumeChanged()
        }
    }

    // MARK: - Управление

    /// Обычный захват выбранного источника.
    func start() {
        if mode == .live || mode == .suspended { return }
        stopDemo()
        mode = .live
        watchdogRebuilds = 0
        processes.start()
        output.start()
        volumeChanged()
        performRebuild(reason: "запуск")
        startWatchdog()
    }

    /// Останавливает захват, демо, анализ и подписки.
    func stop() {
        mode = .stopped
        cancelTasks()
        capture.stop()
        stopDemo()
        engine.stop()
        processes.stop()
        output.stop()
        appliedProcessIDs = []
        if !matchedProcesses.isEmpty { matchedProcesses = [] }
        updateSourceOutputting()
        status = .stopped
    }

    /// Звук из файла вместо tap.
    func startDemo(file: URL) throws {
        let newDemo = try DemoAudioSource(ring: ring, file: file)
        stop()
        // Оба писателя и читатель остановлены, кольцо можно обнулить.
        ring.reset()
        demo = newDemo
        mode = .demo
        newDemo.start()
        engine.start(sampleRate: newDemo.sampleRate)
        pushSettings()
        status = .demo
        log("демо: \(file.lastPathComponent), \(Int(newDemo.sampleRate)) Гц")
    }

    /// Долгая тишина: IOProc и анализ останавливаются, подписки остаются.
    func suspendIdle() {
        guard mode == .live else { return }
        mode = .suspended
        rebuildTask?.cancel()
        rebuildTask = nil
        capture.stop()
        engine.stop()
        status = .suspended
        log("захват приостановлен в тишине")
    }

    func resume() {
        guard mode == .suspended else { return }
        mode = .live
        performRebuild(reason: "возобновление")
    }

    /// Сторож нулей снова получает все попытки (например, после выдачи доступа к звуку).
    func resetWatchdog() {
        if watchdogRebuilds != 0 { watchdogRebuilds = 0 }
    }

    /// Пересборка не чаще раза в 250 мс; запросы во время ожидания объединяются.
    func rebuild(reason: String) {
        guard mode == .live, rebuildTask == nil else { return }
        let wait = max(0, lastRebuildAt + Self.minRebuildInterval - Self.now())
        rebuildTask = Task { @MainActor [weak self] in
            if wait > 0 {
                try? await Task.sleep(for: .seconds(wait))
            }
            guard !Task.isCancelled, let self else { return }
            self.rebuildTask = nil
            self.performRebuild(reason: reason)
        }
    }

    // MARK: - Пересборка

    private func performRebuild(reason: String) {
        guard mode == .live else { return }
        rebuildTask?.cancel()
        rebuildTask = nil
        lastRebuildAt = Self.now()

        engine.stop()
        capture.stop()

        let snapshot = processes.snapshot()
        let ids = ProcessMatcher.matches(source, in: snapshot)
        setMatched(snapshot.filter { ids.contains($0.objectID) })
        appliedProcessIDs = ids

        let systemWide = source == .systemWide
        guard systemWide || !ids.isEmpty else {
            status = .waitingForSource
            log("пересборка (\(reason)): источник \(source.displayName) не найден, жду")
            return
        }

        // Писатель и читатель остановлены.
        ring.reset()
        do {
            try capture.start(
                processObjectIDs: ids,
                systemWide: systemWide,
                outputDeviceUID: output.deviceUID
            )
            engine.start(sampleRate: capture.sampleRate)
            pushSettings()
            log("пересборка (\(reason)): \(source.displayName), процессов \(ids.count), вывод \(output.deviceName)")
        } catch {
            log("пересборка (\(reason)) не удалась: \(error)")
        }
        status = .capturing(capture.status)
    }

    private func processesChanged() {
        guard mode == .live || mode == .suspended else { return }
        let snapshot = processes.snapshot()
        let ids = ProcessMatcher.matches(source, in: snapshot)
        setMatched(snapshot.filter { ids.contains($0.objectID) })
        if mode == .live,
           ProcessMatcher.needsRebuild(source: source, current: appliedProcessIDs, processes: snapshot) {
            rebuild(reason: "список процессов")
        }
    }

    private func volumeChanged() {
        let volume = output.effectiveVolume
        if settings.systemVolume != volume {
            settings.systemVolume = volume
        } else {
            pushSettings()
        }
    }

    private func pushSettings() {
        var effective = settings
        effective.systemVolume = output.effectiveVolume
        var delayFrames = 0
        if mode != .demo {
            let rate = capture.sampleRate
            let milliseconds = LatencyCalculator.delayMilliseconds(output.latency, mode: latencyMode)
            if rate > 0 {
                delayFrames = LatencyCalculator.delayFrames(milliseconds: milliseconds, sampleRate: rate)
            }
        }
        engine.update(settings: effective, delayFrames: delayFrames)
    }

    // MARK: - Сторож нулей

    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                self.watchdogTick()
            }
        }
    }

    private func watchdogTick() {
        guard mode == .live, case .capturing(.running) = status else { return }
        let zeroRun = engine.zeroRunDuration
        refreshOutputting()

        // Ненулевой звук после пересборки: счетчик попыток сбрасывается.
        if zeroRun == 0, Self.now() - lastRebuildAt > 1 {
            watchdogRebuilds = 0
            return
        }
        guard sourceOutputting, zeroRun > Self.zeroRunLimit,
              watchdogRebuilds < Self.maxWatchdogRebuilds, rebuildTask == nil else { return }

        watchdogRebuilds += 1
        let attempt = watchdogRebuilds
        let pause = Self.watchdogPauses[min(attempt - 1, Self.watchdogPauses.count - 1)]
        log("сторож нулей: \(String(format: "%.1f", zeroRun)) с нулей при звучащем источнике, попытка \(attempt), пауза \(Int(pause)) с")
        engine.stop()
        capture.stop()
        status = .rebuilding(attempt: attempt)
        rebuildTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(pause))
            guard !Task.isCancelled, let self else { return }
            self.rebuildTask = nil
            self.performRebuild(reason: "сторож нулей, попытка \(attempt)")
        }
    }

    /// Перечитывает `isRunningOutput` совпавших процессов, когда «звучит» решают они
    /// (Now Playing недоступен и источник это приложение).
    private func refreshOutputting() {
        if !adapterAvailable, source != .systemWide {
            let refreshed = matchedProcesses.map { process -> AudioProcessInfo in
                var copy = process
                let running: UInt32 = CAProperty.read(process.objectID, kAudioProcessPropertyIsRunningOutput, default: 0)
                copy.isRunningOutput = running != 0
                return copy
            }
            setMatched(refreshed)
        }
        updateSourceOutputting()
    }

    private func setMatched(_ processes: [AudioProcessInfo]) {
        if processes != matchedProcesses { matchedProcesses = processes }
        updateSourceOutputting()
    }

    /// Сигнал для сторожа нулей. Если Now Playing работает, решает только он; без него для
    /// приложения решает `IsRunningOutput` совпавших процессов, а для всего звука системы
    /// сигнала нет (любой процесс со звуком дал бы ложные пересборки на каждой паузе).
    private func updateSourceOutputting() {
        let value: Bool
        if adapterAvailable || source == .systemWide {
            value = adapterSaysPlaying
        } else {
            value = matchedProcesses.contains { $0.isRunningOutput }
        }
        if value != sourceOutputting { sourceOutputting = value }
    }

    // MARK: - Вспомогательное

    private func stopDemo() {
        demo?.stop()
        demo = nil
    }

    private func cancelTasks() {
        rebuildTask?.cancel()
        rebuildTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    private func log(_ message: String) {
        Log.audio.info("\(message, privacy: .public)")
        Log.file(message)
    }

    private static func now() -> Double {
        ProcessInfo.processInfo.systemUptime
    }
}
