import CoreAudio
import Foundation
import Observation
import WaveCore

enum PipelineStatus: Equatable, Sendable {
    case stopped
    case demo
    /// Tap создается на очереди управления; анализ стоит до конца создания.
    case starting
    case capturing(TapStatus)
    case waitingForSource
    /// Пересборка сторожем нулей.
    case rebuilding(attempt: Int)
    /// Tap не создался, повтор номер `attempt` из `recoveryTiming.startRetryPauses.count` после паузы.
    case retrying(attempt: Int, message: String)
    /// Долгая тишина: IOProc и анализ остановлены, подписки работают, конвейер следит, не начал
    /// ли источник выводить звук.
    case suspended
    /// «Приостановить визуализацию»: IOProc, демо и анализ остановлены, подписки работают.
    case paused
}

/// Последняя ошибка создания или удаления tap: ее показывает диагностика, даже когда статус
/// уже другой (например, приостановка в тишине).
struct CaptureErrorNote: Equatable, Sendable {
    var message: String
    var date: Date
}

/// Выбор источника, сборка и пересборка захвата, сторож нулей.
///
/// Пересобирает tap при смене совпавших процессов, устройства вывода, его частоты, источника,
/// после перезапуска coreaudiod (через `OutputDeviceMonitor`) и по явному `rebuild(reason:)`.
/// Пересборки не чаще раза в 250 мс. Tap создается вне главного потока (`ProcessTapCapture`),
/// результат применяется здесь, если после него не было новой пересборки или остановки
/// (`startGeneration`). Повторы и сторож нулей идут по `CaptureRecovery`: если создать tap не
/// вышло, повторы через 1, 2 и 4 с, затем статус `failed` и повтор раз в 30 с; сторож нулей
/// после 5 быстрых пересборок пересобирает tap раз в 30 с, пока звук не вернется.
@MainActor
@Observable
final class AudioPipeline {
    static let ringCapacity = 131_072
    static let minRebuildInterval = 0.25

    private(set) var status: PipelineStatus = .stopped
    private(set) var matchedProcesses: [AudioProcessInfo] = []
    private(set) var sourceOutputting = false
    private(set) var lastCaptureError: CaptureErrorNote?

    /// Сколько быстрых пересборок подряд сделал сторож нулей; сбрасывается, когда пошел
    /// ненулевой звук.
    var watchdogRebuilds: Int { recovery.watchdogRebuilds }

    /// Быстрые попытки сторожа нулей или создания tap кончились, захват повторяется раз в
    /// `slowRetryInterval`.
    var recoveryExhausted: Bool { recovery.exhausted }

    /// Источник по Now Playing «играет». Выставляет `AppModel`.
    @ObservationIgnored var adapterSaysPlaying = false {
        didSet { if adapterSaysPlaying != oldValue { updateSourceOutputting() } }
    }

    /// Now Playing работает. Тогда «источник звучит» решает только он. Выставляет `AppModel`.
    @ObservationIgnored var adapterAvailable = false {
        didSet { if adapterAvailable != oldValue { updateSourceOutputting() } }
    }

    /// Остров скрыт: анализ просыпается 15 раз в секунду вместо 120. Выставляет `AppModel`.
    @ObservationIgnored var islandHidden = false {
        didSet { if islandHidden != oldValue { engine.setIdle(islandHidden) } }
    }

    @ObservationIgnored var source: AudioSource = .systemWide {
        didSet {
            guard source != oldValue else { return }
            recovery.reset()
            if mode == .suspended {
                // Приостановка держалась на Now Playing прежнего источника.
                resume(reason: "смена источника")
                return
            }
            // Ждущий повтор или пауза сторожа относились к прежнему источнику: новый собирается
            // сразу, а не после них (до 4 с).
            cancelRebuildTasks()
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

    /// «Сдвиг синхронизации» в миллисекундах: плюс ставит кадры и свечение позже.
    @ObservationIgnored var syncOffsetMs = 0 {
        didSet { if syncOffsetMs != oldValue { pushSettings() } }
    }

    /// «Приостановить визуализацию»: захват или демо и анализ стоят, подписки работают,
    /// пересборок нет. Выставляет `AppModel`. Снятие паузы возвращает прежний режим, из
    /// приостановки в тишине сразу в захват. Действует и до `start()`.
    @ObservationIgnored var paused = false {
        didSet {
            guard paused != oldValue else { return }
            if paused { enterPause() } else { leavePause() }
        }
    }

    private enum Mode {
        case stopped, live, suspended, demo
    }

    private let processes: AudioProcessList
    private let output: OutputDeviceMonitor
    private let ring: SampleRingBuffer
    private let capture: any TapCapturing
    private let engine: AnalysisEngine
    let recoveryTiming: CaptureRecovery.Timing
    @ObservationIgnored private var recovery: CaptureRecovery

    @ObservationIgnored private var demo: DemoAudioSource?
    /// Файл последнего демо: после сна демо запускается с него же.
    @ObservationIgnored private var demoFile: URL?
    /// Режим до `stopForSleep()`; `nil`, если сна не было или пробуждение уже обработано.
    @ObservationIgnored private var modeBeforeSleep: Mode?
    @ObservationIgnored private var mode = Mode.stopped
    @ObservationIgnored private var appliedProcessIDs: [AudioObjectID] = []
    @ObservationIgnored private var lastRebuildAt = -Double.infinity
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    /// Медленный повтор создания tap после быстрых. Отдельно от `rebuildTask`: пока он ждет,
    /// пересборки по событиям (`rebuild(reason:)`) идут как обычно.
    @ObservationIgnored private var slowRetryTask: Task<Void, Never>?
    @ObservationIgnored private var watchdogTask: Task<Void, Never>?
    /// Растет при каждом запуске и остановке tap: результат устаревшего запуска не применяется.
    @ObservationIgnored private var startGeneration = 0
    /// В приостановке: подписки на `kAudioProcessPropertyIsRunningOutput` процессов источника.
    @ObservationIgnored private var outputWatchTokens: [CAListenerToken] = []
    /// Процессы, на которые сейчас подписан `outputWatchTokens`.
    @ObservationIgnored private var outputWatchIDs: [AudioObjectID] = []
    /// Сколько раз ставились подписки на вывод (для тестов).
    @ObservationIgnored private var outputWatchSubscriptions = 0
    @ObservationIgnored private var outputStart = OutputStartDetector(outputting: [])
    /// В приостановке: выводит ли звук хотя бы один процесс источника. Ставится при входе в
    /// приостановку, обновляют подписки на `kAudioProcessPropertyIsRunningOutput` и смена
    /// списка процессов, а не опрос HAL на тике. Вне приостановки не используется.
    @ObservationIgnored private var suspendedOutputting = false

    /// `timing` и `makeCapture` подставляют тесты: короткие сроки и свой захват вместо
    /// `ProcessTapCapture`.
    init(
        store: FrameStore,
        processes: AudioProcessList,
        output: OutputDeviceMonitor,
        timing: CaptureRecovery.Timing = .standard,
        makeCapture: ((SampleRingBuffer) -> any TapCapturing)? = nil
    ) {
        self.processes = processes
        self.output = output
        let ring = SampleRingBuffer(capacity: Self.ringCapacity)
        self.ring = ring
        if let makeCapture {
            capture = makeCapture(ring)
        } else {
            capture = ProcessTapCapture(ring: ring)
        }
        self.engine = AnalysisEngine(ring: ring, store: store)
        recoveryTiming = timing
        recovery = CaptureRecovery(timing: timing)

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
        output.onServiceRestart = { [weak self] in
            self?.serviceRestarted()
        }
    }

    // MARK: - Управление

    /// Обычный захват выбранного источника.
    func start() {
        if mode == .live || mode == .suspended { return }
        stopDemo()
        mode = .live
        recovery.reset()
        processes.start()
        output.start()
        volumeChanged()
        performRebuild(reason: "запуск")
    }

    /// Останавливает захват, демо, анализ и подписки. Главный поток не ждет удаления tap: оно
    /// встает в очередь управления раньше любого следующего запуска. Дождаться его можно через
    /// `waitForCaptureTeardown(timeout:)`.
    func stop() {
        mode = .stopped
        modeBeforeSleep = nil
        cancelTasks()
        stopOutputWatch()
        stopCaptureInBackground()
        stopDemo()
        engine.stop()
        processes.stop()
        output.stop()
        appliedProcessIDs = []
        if !matchedProcesses.isEmpty { matchedProcesses = [] }
        updateSourceOutputting()
        setStatus(.stopped)
    }

    /// Звук из файла вместо tap.
    func startDemo(file: URL) throws {
        let newDemo = try DemoAudioSource(ring: ring, file: file)
        stop()
        // Перед обнулением кольца tap должен быть удален, иначе у кольца будет два писателя.
        // В режиме демо tap не создается, так что очередь управления пуста и ожидания нет.
        stopCapture()
        // Оба писателя и читатель остановлены, кольцо можно обнулить.
        ring.reset()
        demo = newDemo
        demoFile = file
        mode = .demo
        log("демо: \(file.lastPathComponent), \(Int(newDemo.sampleRate)) Гц")
        guard !paused else {
            setStatus(.paused)
            return
        }
        newDemo.start()
        engine.start(sampleRate: newDemo.sampleRate)
        pushSettings()
        setStatus(.demo)
    }

    /// Ждет не дольше `timeout` секунд удаления tap и агрегата, уже поставленного `stop()`.
    /// Нужно при выходе: агрегатное устройство не должно пережить приложение.
    @discardableResult
    func waitForCaptureTeardown(timeout: Double) -> Bool {
        let finished = capture.waitUntilIdle(timeout: timeout)
        if !finished {
            log("удаление tap не закончилось за \(timeout) с")
        }
        return finished
    }

    // MARK: - Сон

    /// Сон: запоминает режим (захват, демо или остановка) и останавливает все, не дожидаясь
    /// удаления tap. Повторный вызов до пробуждения ничего не меняет.
    func stopForSleep() {
        guard modeBeforeSleep == nil else { return }
        let before = mode
        stop()
        modeBeforeSleep = before
    }

    /// Пробуждение: возвращает режим до сна, захват собирается заново, демо запускается с тем же
    /// файлом, остановленный конвейер остается остановленным. Пауза сохраняется (`paused`).
    /// Без замеченного сна текущий режим перезапускается с нуля.
    func restartAfterSleep() {
        let previous = modeBeforeSleep ?? mode
        modeBeforeSleep = nil
        switch previous {
        case .stopped:
            return
        case .live, .suspended:
            stop()
            start()
        case .demo:
            guard let file = demoFile else {
                stop()
                return
            }
            do {
                try startDemo(file: file)
            } catch {
                log("демо после пробуждения не запустилось: \(error)")
            }
        }
    }

    /// Долгая тишина: IOProc и анализ останавливаются, подписки остаются. Только для
    /// приложения: весь звук системы не приостанавливается (`IdleCapturePolicy`). Пока захват
    /// стоит, конвейер подписан на `kAudioProcessPropertyIsRunningOutput` процессов источника;
    /// как только процесс начал выводить звук, захват возобновляется сам, не дожидаясь Now Playing.
    func suspendIdle() {
        guard mode == .live, !paused, source != .systemWide else { return }
        mode = .suspended
        cancelRebuildTasks()
        stopCaptureInBackground()
        engine.stop()
        setStatus(.suspended)
        startOutputWatch()
        log("захват приостановлен в тишине, жду вывода звука")
    }

    func resume(reason: String = "возобновление") {
        guard mode == .suspended, !paused else { return }
        stopOutputWatch()
        mode = .live
        performRebuild(reason: reason)
    }

    /// Сторож нулей и повторы создания tap снова получают все быстрые попытки (например,
    /// после выдачи доступа к звуку).
    func resetWatchdog() {
        recovery.reset()
    }

    /// Пересборка не чаще раза в 250 мс; запросы во время ожидания объединяются.
    func rebuild(reason: String) {
        guard mode == .live, !paused, rebuildTask == nil else { return }
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

    // MARK: - Пауза

    private func enterPause() {
        switch mode {
        case .stopped:
            return
        case .live, .suspended:
            cancelRebuildTasks()
            stopOutputWatch()
            stopCaptureInBackground()
            engine.stop()
            // После паузы сразу захват: тишину AppModel отсчитает заново.
            mode = .live
        case .demo:
            demo?.stop()
            engine.stop()
        }
        setStatus(.paused)
        log("визуализация на паузе: захват и анализ остановлены")
    }

    private func leavePause() {
        switch mode {
        case .stopped, .suspended:
            return
        case .live:
            performRebuild(reason: "визуализация возобновлена")
        case .demo:
            guard let demo else { return }
            demo.start()
            engine.start(sampleRate: demo.sampleRate)
            pushSettings()
            setStatus(.demo)
            log("визуализация возобновлена: демо")
        }
    }

    // MARK: - Пересборка

    /// `attempt`: номер повтора после неудачного создания tap, 0 для обычной пересборки.
    private func performRebuild(reason: String, attempt: Int = 0) {
        guard mode == .live else { return }
        guard !paused else {
            setStatus(.paused)
            return
        }
        cancelRebuildTasks()
        lastRebuildAt = Self.now()

        // Читатель кольца стоит, пока tap пересоздается: кольцо обнуляется на очереди управления.
        engine.stop()

        let snapshot = processes.snapshot()
        let ids = ProcessMatcher.matches(source, in: snapshot)
        setMatched(snapshot.filter { ids.contains($0.objectID) })
        appliedProcessIDs = ids

        let systemWide = source == .systemWide
        guard systemWide || !ids.isEmpty else {
            // Источник закрылся: исчерпанные попытки относились к нему, подсказка о захвате
            // без звука снимается, а новый запуск источника снова получит быстрые попытки.
            recovery.reset()
            stopCaptureInBackground()
            setStatus(.waitingForSource)
            log("пересборка (\(reason)): источник \(source.displayName) не найден, жду")
            return
        }

        startGeneration += 1
        let generation = startGeneration
        let summary = "\(source.displayName), процессов \(ids.count), вывод \(output.deviceName)"
        setStatus(.starting)
        // Прежний tap удаляется в той же очереди до создания нового.
        capture.start(
            processObjectIDs: ids,
            systemWide: systemWide,
            outputDeviceUID: output.deviceUID
        ) { @Sendable result, teardownError in
            Task { @MainActor in
                if let teardownError {
                    self.noteCaptureError("остановка прошлого tap: \(teardownError)")
                }
                self.finishStart(result, generation: generation, reason: reason, attempt: attempt, summary: summary)
            }
        }
    }

    private func finishStart(
        _ result: Result<Double, TapError>,
        generation: Int,
        reason: String,
        attempt: Int,
        summary: String
    ) {
        // После этого запуска была новая пересборка или остановка: tap удалит следующая
        // операция в очереди управления.
        guard generation == startGeneration, mode == .live, !paused else { return }
        switch result {
        case .success(let rate):
            recovery.startSucceeded()
            engine.start(sampleRate: rate)
            pushSettings()
            setStatus(.capturing(capture.status))
            log("пересборка (\(reason)): \(summary)")
        case .failure(let error):
            noteCaptureError(error.message)
            let retries = recoveryTiming.startRetryPauses.count
            switch recovery.startFailed(attempt: attempt) {
            case .retry(let next, let pause):
                setStatus(.retrying(attempt: next, message: error.message))
                log("пересборка (\(reason)) не удалась: \(error.message); повтор \(next) из \(retries) через \(Self.seconds(pause)) с")
                rebuildTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(pause))
                    guard !Task.isCancelled, let self else { return }
                    self.rebuildTask = nil
                    self.performRebuild(reason: "повтор создания tap \(next)", attempt: next)
                }
            case .slowRetry(let pause):
                setStatus(.capturing(.failed(error.message)))
                log("пересборка (\(reason)) не удалась: \(error.message); быстрых повторов было \(retries), следующий через \(Self.seconds(pause)) с")
                let slowAttempt = recovery.slowRetryAttempt
                slowRetryTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(pause))
                    guard !Task.isCancelled, let self else { return }
                    self.slowRetryTask = nil
                    self.performRebuild(reason: "медленный повтор создания tap", attempt: slowAttempt)
                }
            }
        }
    }

    /// coreaudiod перезапущен: подписка на список процессов ставится заново (подписки
    /// `OutputDeviceMonitor` он уже пересоздал), tap пересобирается.
    private func serviceRestarted() {
        guard mode == .live || mode == .suspended else { return }
        log("coreaudiod перезапущен: подписки и tap пересоздаются")
        processes.stop()
        processes.start()
        pushSettings()
        processesChanged(resubscribe: true)
        rebuild(reason: "перезапуск coreaudiod")
    }

    /// В приостановке вывод звука процессами источника перечитывается на каждой смене списка,
    /// даже если номера процессов те же. `resubscribe`: подписки на вывод ставятся заново и при
    /// тех же номерах (после перезапуска coreaudiod прежние подписки не действуют).
    private func processesChanged(resubscribe: Bool = false) {
        guard mode == .live || mode == .suspended else { return }
        let snapshot = processes.snapshot()
        let ids = ProcessMatcher.matches(source, in: snapshot)
        setMatched(snapshot.filter { ids.contains($0.objectID) })
        if mode == .live,
           ProcessMatcher.needsRebuild(source: source, current: appliedProcessIDs, processes: snapshot) {
            rebuild(reason: "список процессов")
        }
        if mode == .suspended {
            // Новый помощник источника тоже может начать выводить звук.
            if resubscribe || matchedProcesses.map(\.objectID) != outputWatchIDs {
                watchOutput()
            }
            checkOutputStart()
        }
    }

    // MARK: - Вывод звука в приостановке

    /// Запоминает, какие процессы выводят звук сейчас (они не будят), и начинает следить.
    private func startOutputWatch() {
        let outputting = outputtingProcessIDs()
        suspendedOutputting = !outputting.isEmpty
        outputStart = OutputStartDetector(outputting: outputting)
        watchOutput()
    }

    /// Подписки на процессы источника, заново.
    private func watchOutput() {
        stopOutputWatch()
        outputWatchSubscriptions += 1
        outputWatchIDs = matchedProcesses.map(\.objectID)
        outputWatchTokens = matchedProcesses.map { process in
            CAProperty.listen(process.objectID, kAudioProcessPropertyIsRunningOutput, queue: .main) { [weak self] in
                MainActor.assumeIsolated {
                    self?.checkOutputStart()
                }
            }
        }
    }

    private func stopOutputWatch() {
        for token in outputWatchTokens {
            token.cancel()
        }
        outputWatchTokens = []
        outputWatchIDs = []
    }

    private func checkOutputStart() {
        guard mode == .suspended, !paused else { return }
        let outputting = outputtingProcessIDs()
        suspendedOutputting = !outputting.isEmpty
        guard outputStart.update(outputting: outputting) else { return }
        log("в приостановке процесс начал выводить звук")
        resume(reason: "источник начал выводить звук")
    }

    /// Хотя бы один процесс источника сейчас сообщает `kAudioProcessPropertyIsRunningOutput`.
    /// Значение читается заново, а не берется из снимка списка процессов. В приостановке оно
    /// берется из подписок (`suspendedOutputting`): HAL не опрашивается на каждом тике модели.
    /// Для всего звука системы `false`: процессы не отбираются.
    func sourceProcessOutputting() -> Bool {
        if mode == .suspended { return suspendedOutputting }
        return !outputtingProcessIDs().isEmpty
    }

    /// Совпавшие процессы источника, которые сейчас выводят звук.
    private func outputtingProcessIDs() -> Set<AudioObjectID> {
        var result = Set<AudioObjectID>()
        for process in matchedProcesses where processes.isRunningOutput(process.objectID) {
            result.insert(process.objectID)
        }
        return result
    }

    private func volumeChanged() {
        let volume = output.effectiveVolume
        if settings.systemVolume != volume {
            settings.systemVolume = volume
        } else {
            pushSettings()
        }
    }

    /// Уровни, задержка вывода и сдвиг синхронизации в анализ. Демо идет с задержкой вывода 0,
    /// как в 0.9.0: файл не проходит через устройство вывода. Поэтому в демо свечение без
    /// захвата ритма приходит примерно на 52 мс позже звука, а не на 33 (принято).
    private func pushSettings() {
        var effective = settings
        effective.systemVolume = output.effectiveVolume
        let latency = mode == .demo ? 0 : LatencyCalculator.outputLatency(output.latency, mode: latencyMode)
        engine.update(settings: effective, outputLatency: latency, syncOffset: Double(syncOffsetMs) / 1000)
    }

    /// Задержка вывода, с которой сейчас идут кадры и свечение, секунды (0 в демо).
    var outputLatency: Double {
        mode == .demo ? 0 : LatencyCalculator.outputLatency(output.latency, mode: latencyMode)
    }

    // MARK: - Сторож нулей

    /// Новый статус. Сторож нулей проверяет только работающий tap, поэтому его цикл идет
    /// только в `.capturing(.running)`: в приостановке, паузе, ожидании источника и между
    /// пересборками он не будит приложение.
    private func setStatus(_ new: PipelineStatus) {
        if status != new { status = new }
        if mode == .live, case .capturing(.running) = status {
            startWatchdog()
        } else {
            watchdogTask?.cancel()
            watchdogTask = nil
        }
    }

    private func startWatchdog() {
        guard watchdogTask == nil else { return }
        let interval = recoveryTiming.watchdogInterval
        watchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                self.watchdogTick()
            }
        }
    }

    private func watchdogTick() {
        guard mode == .live, case .capturing(.running) = status else { return }
        let zeroRun = engine.zeroRunDuration
        refreshOutputting()

        let action = recovery.watchdog(
            zeroRun: zeroRun,
            sourceOutputting: sourceOutputting,
            sinceRebuild: Self.now() - lastRebuildAt,
            rebuildPending: rebuildTask != nil || slowRetryTask != nil
        )
        let zeros = String(format: "%.1f", zeroRun)
        switch action {
        case .none:
            return
        case .rebuild(let attempt, let pause):
            log("сторож нулей: \(zeros) с нулей при звучащем источнике, попытка \(attempt), пауза \(Self.seconds(pause)) с")
            engine.stop()
            stopCaptureInBackground()
            setStatus(.rebuilding(attempt: attempt))
            rebuildTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(pause))
                guard !Task.isCancelled, let self else { return }
                self.rebuildTask = nil
                self.performRebuild(reason: "сторож нулей, попытка \(attempt)")
            }
        case .slowRetry:
            log("сторож нулей: \(zeros) с нулей при звучащем источнике, быстрые попытки кончились, "
                + "пересборка раз в \(Self.seconds(recoveryTiming.slowRetryInterval)) с")
            performRebuild(reason: "сторож нулей, медленный повтор")
        }
    }

    /// Перечитывает `isRunningOutput` совпавших процессов, когда «звучит» решают они
    /// (Now Playing недоступен и источник это приложение).
    private func refreshOutputting() {
        if !adapterAvailable, source != .systemWide {
            let refreshed = matchedProcesses.map { process -> AudioProcessInfo in
                var copy = process
                copy.isRunningOutput = self.processes.isRunningOutput(process.objectID)
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

    /// Удаляет tap и ждет этого: после возврата писателя в кольце нет.
    private func stopCapture() {
        startGeneration += 1
        if let error = capture.stop() {
            noteCaptureError("остановка tap: \(error)")
        }
    }

    /// Удаляет tap без ожидания: удаление встает в очередь управления после уже поставленных
    /// запусков, ошибка попадает в диагностику.
    private func stopCaptureInBackground() {
        startGeneration += 1
        capture.stopInBackground { @Sendable error in
            guard let error else { return }
            Task { @MainActor in
                self.noteCaptureError("остановка tap: \(error)")
            }
        }
    }

    private func noteCaptureError(_ message: String) {
        lastCaptureError = CaptureErrorNote(message: message, date: Date())
    }

    private func cancelTasks() {
        cancelRebuildTasks()
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    /// Отменяет ждущие пересборки: повтор, паузу сторожа и медленный повтор.
    private func cancelRebuildTasks() {
        rebuildTask?.cancel()
        rebuildTask = nil
        slowRetryTask?.cancel()
        slowRetryTask = nil
    }

    /// «4», «0.5»: секунды для лога.
    private static func seconds(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.2g", value)
    }

    private func log(_ message: String) {
        Log.audio.info("\(message, privacy: .public)")
        Log.file(message)
    }

    private static func now() -> Double {
        ProcessInfo.processInfo.systemUptime
    }
}

// MARK: - Для тестов

extension AudioPipeline {
    var analysisEngineForTesting: AnalysisEngine { engine }
    var demoForTesting: DemoAudioSource? { demo }
    var ringForTesting: SampleRingBuffer { ring }
    var outputWatchSubscriptionsForTesting: Int { outputWatchSubscriptions }
}
