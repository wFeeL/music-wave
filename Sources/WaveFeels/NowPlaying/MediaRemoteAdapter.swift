import Foundation
import Observation
import Synchronization
import WaveCore

/// Команды `send` mediaremote-adapter: ID из таблицы MRCommand в README адаптера.
enum MediaCommand: Int, Sendable {
    case play = 0
    case pause = 1
    case togglePlayPause = 2
    case nextTrack = 4
    case previousTrack = 5
}

enum AdapterAvailability: Equatable, Sendable {
    case unknown
    case checking
    case available
    case unavailable(exitCode: Int32, stderr: String)
}

/// Сроки адаптера. Значения по умолчанию рабочие; тесты подставляют короткие.
struct AdapterTiming: Sendable {
    /// Сколько ждать `test` до SIGTERM.
    var testTimeout: Duration = .seconds(10)
    /// Сколько ждать выхода `test` после SIGTERM до SIGKILL.
    var testKillGrace: Duration = .seconds(2)
    var sendTimeout: Duration = .seconds(5)
    var restartDelays: [Duration] = [.seconds(2), .seconds(4), .seconds(8)]
    /// Перезапусков подряд, после которых адаптер недоступен.
    var maxRestarts = 5
    /// Поток, проживший столько, умер не «подряд»: счетчик перезапусков обнуляется.
    var stableRun: Duration = .seconds(60)
    /// Сколько после перезапуска держать прежний трек, пока поток не выдал новый.
    var restartInfoHold: Duration = .seconds(3)

    static let standard = AdapterTiming()
}

/// «Сейчас играет» через ungive/mediaremote-adapter: `/usr/bin/perl` запускает скрипт адаптера,
/// тот загружает `MediaRemoteAdapter.framework` из бандла.
///
/// `start()` один раз на версию приложения (`CFBundleVersion`) запускает `test`: при тишине он
/// показывает в Пункте управления фиктивную запись, поэтому результат кэшируется. Завис `test`:
/// SIGTERM через 10 с, SIGKILL еще через 2 с, поток стартует в любом случае. Затем идет
/// `stream --micros --debounce=100`; первая строка с настоящим треком тоже считается
/// подтверждением, что адаптер работает. Умерший поток перезапускается через 2, 4, 8 с, не больше
/// 5 раз подряд (поток, проживший минуту, счетчик обнуляет); после перезапуска прежний трек
/// держится до первого настоящего трека, но не дольше 3 с. Дочерние процессы завершаются
/// (SIGTERM) только в `stop()`, очистки в `deinit` нет: владелец вызывает `stop()` перед выходом.
@MainActor
@Observable
final class MediaRemoteAdapter {
    static let perl = URL(fileURLWithPath: "/usr/bin/perl")
    static let streamArguments = ["stream", "--micros", "--debounce=100"]
    static let testedBuildKey = "wf.adapterTestedBuild"
    static let testExitCodeKey = "wf.adapterTestExitCode"
    static let missingFilesMessage = "нет файлов адаптера"
    static let testTimeoutMessage = "проверка адаптера не уложилась в срок"
    nonisolated static let maxDuration: Double = 24 * 3600
    static let maxStderrBytes = 4096

    private(set) var availability: AdapterAvailability = .unknown
    private(set) var info: NowPlayingInfo?
    private(set) var lastTestExitCode: Int32?
    private(set) var lastStderr = ""

    var isAvailable: Bool { availability == .available }

    private let paths: AdapterPaths?
    private let build: String?
    private let defaults: UserDefaults
    private let timing: AdapterTiming

    @ObservationIgnored private var running = false
    /// Каждый запуск процесса получает свой номер; ответы старых процессов отбрасываются.
    @ObservationIgnored private var lastToken = 0
    @ObservationIgnored private var testToken = 0
    @ObservationIgnored private var test: AdapterProcess?
    @ObservationIgnored private var testStderr: [String] = []
    @ObservationIgnored private var testTimedOut = false
    @ObservationIgnored private var testTimer: Task<Void, Never>?
    @ObservationIgnored private var streamToken = 0
    @ObservationIgnored private var stream: AdapterProcess?
    @ObservationIgnored private var streamStartedAt: ContinuousClock.Instant?
    @ObservationIgnored private var parser = NowPlayingStreamParser()
    /// Последнее состояние текущего потока; во время удержания может отличаться от `info`.
    @ObservationIgnored private var streamInfo: NowPlayingInfo?
    /// После перезапуска: прежний `info` держится, пока поток не выдал трек или не вышел срок.
    @ObservationIgnored private var holdingInfo = false
    @ObservationIgnored private var holdTask: Task<Void, Never>?
    /// Смерти потока подряд; сбрасывается, когда поток выдал настоящий трек или прожил `stableRun`.
    @ObservationIgnored private var restarts = 0
    @ObservationIgnored private var restartTask: Task<Void, Never>?
    @ObservationIgnored private var commands: [Int: AdapterProcess] = [:]

    init(bundle: Bundle, defaults: UserDefaults = .standard, timing: AdapterTiming = .standard) {
        paths = AdapterPaths(bundle: bundle)
        build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        self.defaults = defaults
        self.timing = timing
    }

    func start() {
        guard !running else { return }
        running = true
        restarts = 0
        guard let paths else {
            lastStderr = Self.missingFilesMessage
            availability = .unavailable(exitCode: -1, stderr: Self.missingFilesMessage)
            log("адаптер недоступен: \(Self.missingFilesMessage)")
            return
        }
        if let build, defaults.string(forKey: Self.testedBuildKey) == build {
            let code = Int32(truncatingIfNeeded: defaults.integer(forKey: Self.testExitCodeKey))
            lastTestExitCode = code
            availability = code == 0 ? .available : .unavailable(exitCode: code, stderr: "")
            log("проверка адаптера из кэша (сборка \(build)): код \(code)")
            launchStream(restart: false)
        } else {
            availability = .checking
            runTest(paths)
        }
    }

    func stop() {
        running = false
        // Новые номера: ответы остановленных процессов больше никуда не попадут.
        testToken = nextToken()
        streamToken = nextToken()
        testTimer?.cancel()
        testTimer = nil
        restartTask?.cancel()
        restartTask = nil
        holdTask?.cancel()
        holdTask = nil
        holdingInfo = false
        test?.terminate()
        test = nil
        stream?.terminate()
        stream = nil
        for command in commands.values {
            command.terminate()
        }
        commands = [:]
        info = nil
        if availability == .checking {
            availability = .unknown
        }
    }

    func send(_ command: MediaCommand) {
        guard let paths else { return }
        let token = nextToken()
        let process = AdapterProcess(
            arguments: [paths.script, paths.framework, "send", String(command.rawValue)],
            onStdout: { _ in },
            onStderr: { [weak self] line in self?.noteStderr(line) },
            onFinish: { [weak self] status in self?.commandFinished(token: token, command: command, status: status) }
        )
        do {
            try process.run()
        } catch {
            log("send \(command.rawValue) не запустился: \(error.localizedDescription)")
            return
        }
        commands[token] = process
        Task { [weak self, timing = self.timing] in
            try? await Task.sleep(for: timing.sendTimeout)
            self?.commands[token]?.terminate()
        }
    }

    /// Защита от бессмысленной длительности: бесконечная, отрицательная или больше суток
    /// считается отсутствующей.
    nonisolated static func sanitized(_ info: NowPlayingInfo) -> NowPlayingInfo {
        var info = info
        if let duration = info.duration, !(duration.isFinite && duration > 0 && duration <= maxDuration) {
            info.duration = nil
        }
        return info
    }

    // MARK: - test

    private func runTest(_ paths: AdapterPaths) {
        let token = nextToken()
        testToken = token
        testStderr = []
        testTimedOut = false
        let process = AdapterProcess(
            arguments: [paths.script, paths.framework, paths.testClient, "test"],
            onStdout: { _ in },
            onStderr: { [weak self] line in self?.testStderrLine(line, token: token) },
            onFinish: { [weak self] status in self?.testFinished(status: status, token: token) }
        )
        do {
            try process.run()
        } catch {
            let message = "проверка адаптера не запустилась: \(error.localizedDescription)"
            noteStderr(message)
            availability = .unavailable(exitCode: -1, stderr: message)
            log(message)
            return
        }
        test = process
        log("проверка адаптера запущена")
        testTimer = Task { [weak self, timing = self.timing] in
            try? await Task.sleep(for: timing.testTimeout)
            guard !Task.isCancelled, self?.testTimeoutFired(token: token) == true else { return }
            try? await Task.sleep(for: timing.testKillGrace)
            guard !Task.isCancelled else { return }
            self?.testKillFired(token: token)
        }
    }

    private func testStderrLine(_ line: String, token: Int) {
        guard token == testToken else { return }
        testStderr.append(line)
        noteStderr(line)
    }

    /// SIGTERM зависшему `test`. `true`, если процесс еще ждали.
    private func testTimeoutFired(token: Int) -> Bool {
        guard token == testToken, let test else { return false }
        testTimedOut = true
        log(Self.testTimeoutMessage)
        test.terminate()
        return true
    }

    /// `test` не вышел после SIGTERM: SIGKILL и дальше без него, чтобы не застрять в `.checking`.
    private func testKillFired(token: Int) {
        guard token == testToken, let test else { return }
        log("проверка адаптера не вышла после SIGTERM, SIGKILL")
        test.forceKill()
        testFinished(status: SIGKILL, token: token)
    }

    private func testFinished(status: Int32, token: Int) {
        guard token == testToken, running else { return }
        // Поздний ответ того же процесса (после SIGKILL) уже не нужен.
        testToken = nextToken()
        test = nil
        testTimer?.cancel()
        testTimer = nil
        lastTestExitCode = status
        if let build {
            defaults.set(Int(status), forKey: Self.testExitCodeKey)
            defaults.set(build, forKey: Self.testedBuildKey)
        }
        if status == 0 {
            availability = .available
        } else {
            let stderr = testTimedOut ? Self.testTimeoutMessage : testStderr.joined(separator: "\n")
            availability = .unavailable(exitCode: status, stderr: stderr)
        }
        log("проверка адаптера завершилась: код \(status)")
        launchStream(restart: false)
    }

    // MARK: - stream

    private func launchStream(restart: Bool) {
        guard running, let paths else { return }
        let token = nextToken()
        streamToken = token
        streamStartedAt = nil
        parser = NowPlayingStreamParser()
        streamInfo = nil
        holdTask?.cancel()
        holdTask = nil
        holdingInfo = restart && info != nil
        if holdingInfo {
            holdTask = Task { [weak self, timing = self.timing] in
                try? await Task.sleep(for: timing.restartInfoHold)
                guard !Task.isCancelled else { return }
                self?.holdExpired(token: token)
            }
        }
        let process = AdapterProcess(
            arguments: [paths.script, paths.framework] + Self.streamArguments,
            onStdout: { [weak self] line in self?.streamLine(line, token: token) },
            onStderr: { [weak self] line in self?.streamStderrLine(line, token: token) },
            onFinish: { [weak self] status in self?.streamEnded(status: status, token: token) }
        )
        do {
            try process.run()
        } catch {
            noteStderr("поток адаптера не запустился: \(error.localizedDescription)")
            streamEnded(status: -1, token: token)
            return
        }
        stream = process
        streamStartedAt = .now
        log("поток адаптера запущен")
    }

    private func holdExpired(token: Int) {
        guard token == streamToken, holdingInfo else { return }
        holdingInfo = false
        holdTask = nil
        if streamInfo != info {
            info = streamInfo
        }
    }

    private func streamLine(_ line: String, token: Int) {
        guard token == streamToken else { return }
        let parsed: NowPlayingInfo?
        do {
            parsed = try parser.consume(line: line)
        } catch {
            log("адаптер: строка не разобрана: \(line.prefix(200))")
            return
        }
        let next = parsed.map(Self.sanitized)
        streamInfo = next
        // Перезапущенный поток начинает с пустого снимка: прежний трек пока остается.
        if holdingInfo {
            guard parsed != nil else { return }
            holdingInfo = false
            holdTask?.cancel()
            holdTask = nil
        }
        if next != info {
            info = next
        }
        guard parsed != nil else { return }
        restarts = 0
        if availability != .available {
            availability = .available
            log("адаптер доступен: поток выдал трек")
        }
    }

    private func streamStderrLine(_ line: String, token: Int) {
        guard token == streamToken else { return }
        noteStderr(line)
    }

    private func streamEnded(status: Int32, token: Int) {
        guard token == streamToken, running else { return }
        stream = nil
        if let started = streamStartedAt, ContinuousClock.now - started >= timing.stableRun {
            // Редкие смерти с большими промежутками не копятся до «недоступен».
            restarts = 0
        }
        streamStartedAt = nil
        restarts += 1
        if restarts > timing.maxRestarts {
            holdTask?.cancel()
            holdTask = nil
            holdingInfo = false
            info = nil
            availability = .unavailable(exitCode: status, stderr: lastStderr)
            log("поток адаптера умер \(restarts) раз подряд (код \(status)), адаптер недоступен")
            return
        }
        let delays = timing.restartDelays
        let delay = delays.isEmpty ? .zero : delays[min(restarts, delays.count) - 1]
        log("поток адаптера завершился с кодом \(status), перезапуск \(restarts) через \(delay)")
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.streamToken == token else { return }
            self.restartTask = nil
            self.launchStream(restart: true)
        }
    }

    // MARK: - helpers

    private func commandFinished(token: Int, command: MediaCommand, status: Int32) {
        commands[token] = nil
        if status != 0 {
            log("send \(command.rawValue) завершился с кодом \(status)")
        }
    }

    private func noteStderr(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var text = lastStderr.isEmpty ? trimmed : lastStderr + "\n" + trimmed
        if text.utf8.count > Self.maxStderrBytes {
            text = String(decoding: text.utf8.suffix(Self.maxStderrBytes), as: UTF8.self)
        }
        lastStderr = text
        log("адаптер stderr: \(trimmed)")
    }

    private func nextToken() -> Int {
        lastToken += 1
        return lastToken
    }

    private func log(_ message: String) {
        Log.nowPlaying.info("\(message, privacy: .public)")
        Log.file(message)
    }
}

/// Абсолютные пути частей адаптера внутри бандла. `nil`, если чего-то нет.
struct AdapterPaths: Sendable, Equatable {
    var script: String
    var framework: String
    var testClient: String

    init?(bundle: Bundle) {
        let contents = bundle.bundleURL.standardizedFileURL.appendingPathComponent("Contents", isDirectory: true)
        script = contents.appendingPathComponent("Resources/Adapter/mediaremote-adapter.pl").path(percentEncoded: false)
        framework = contents.appendingPathComponent("Frameworks/MediaRemoteAdapter.framework").path(percentEncoded: false)
        testClient = contents.appendingPathComponent("Helpers/MediaRemoteAdapterTestClient").path(percentEncoded: false)

        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.isReadableFile(atPath: script),
              manager.fileExists(atPath: framework, isDirectory: &isDirectory), isDirectory.boolValue,
              manager.isExecutableFile(atPath: testClient)
        else { return nil }
    }
}

/// Дочерний `/usr/bin/perl` с построчным чтением stdout и stderr. `onFinish` приходит один раз,
/// когда процесс вышел и оба потока дочитаны, то есть после всех строк. Если конец потока не
/// пришел через секунду после выхода (пайп держит внук процесса), `onFinish` приходит без него.
/// Колбэки держат объект, пока процесс не завершится, даже если владелец его уже отпустил.
@MainActor
private final class AdapterProcess {
    private static let endGrace: Duration = .seconds(1)

    private let process = Process()
    private let onStdout: @MainActor (String) -> Void
    private let onStderr: @MainActor (String) -> Void
    private let onFinish: @MainActor (Int32) -> Void
    private var readers: [FileHandle] = []
    private var pendingEnds = 3
    private var status: Int32 = 0
    private var finished = false

    init(
        arguments: [String],
        onStdout: @escaping @MainActor (String) -> Void,
        onStderr: @escaping @MainActor (String) -> Void,
        onFinish: @escaping @MainActor (Int32) -> Void
    ) {
        process.executableURL = MediaRemoteAdapter.perl
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        self.onStdout = onStdout
        self.onStderr = onStderr
        self.onFinish = onFinish
    }

    func run() throws {
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        readers = [stdout.fileHandleForReading, stderr.fileHandleForReading]
        PipeIO.readLines(
            from: stdout.fileHandleForReading,
            onLine: { line in self.onStdout(line) },
            onEnd: { self.endReached() }
        )
        PipeIO.readLines(
            from: stderr.fileHandleForReading,
            onLine: { line in self.onStderr(line) },
            onEnd: { self.endReached() }
        )
        PipeIO.observeExit(of: process) { status in self.exited(status: status) }
        do {
            try process.run()
        } catch {
            finished = true
            detach()
            throw error
        }
    }

    /// SIGTERM, если процесс еще жив.
    func terminate() {
        if process.isRunning {
            process.terminate()
        }
    }

    /// SIGKILL, если процесс еще жив.
    func forceKill() {
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private func exited(status: Int32) {
        self.status = status
        endReached()
        guard !finished else { return }
        Task {
            try? await Task.sleep(for: Self.endGrace)
            self.finish()
        }
    }

    private func endReached() {
        pendingEnds -= 1
        if pendingEnds == 0 {
            finish()
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        detach()
        onFinish(status)
    }

    /// Снимает обработчики: они держат этот объект, и без снятия он бы не освободился.
    private func detach() {
        for reader in readers {
            reader.readabilityHandler = nil
        }
        process.terminationHandler = nil
    }
}

/// Обработчики `FileHandle` и `Process`, которые Foundation вызывает на фоновых очередях.
/// Замыкания создаются здесь, вне главного актора, и передают результат на главный поток
/// через `DispatchQueue.main.async`, сохраняя порядок.
nonisolated enum PipeIO {
    static func readLines(
        from handle: FileHandle,
        onLine: @escaping @MainActor @Sendable (String) -> Void,
        onEnd: @escaping @MainActor @Sendable () -> Void
    ) {
        let splitter = LineSplitter()
        handle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                let rest = splitter.finish()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if let rest {
                            onLine(rest)
                        }
                        onEnd()
                    }
                }
                return
            }
            let lines = splitter.append(chunk)
            guard !lines.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for line in lines {
                        onLine(line)
                    }
                }
            }
        }
    }

    static func observeExit(of process: Process, onExit: @escaping @MainActor @Sendable (Int32) -> Void) {
        process.terminationHandler = { process in
            let status = process.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    onExit(status)
                }
            }
        }
    }
}

/// Режет байты из пайпа на строки по `\n`. Хвост без перевода строки ждет следующего куска.
nonisolated final class LineSplitter: Sendable {
    private static let newline = UInt8(ascii: "\n")
    private let buffer = Mutex(Data())

    /// Добавляет кусок и возвращает строки, которые он завершил, по порядку.
    func append(_ chunk: Data) -> [String] {
        buffer.withLock { data in
            data.append(chunk)
            guard chunk.contains(Self.newline) else { return [] }
            var lines: [String] = []
            var start = data.startIndex
            while let end = data[start...].firstIndex(of: Self.newline) {
                lines.append(String(decoding: data[start..<end], as: UTF8.self))
                start = data.index(after: end)
            }
            data.removeSubrange(data.startIndex..<start)
            return lines
        }
    }

    /// Конец потока: возвращает недописанную последнюю строку, если она есть.
    func finish() -> String? {
        buffer.withLock { data in
            guard !data.isEmpty else { return nil }
            let rest = String(decoding: data, as: UTF8.self)
            data.removeAll()
            return rest
        }
    }
}
