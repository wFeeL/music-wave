import AppKit
import Foundation
import Testing
import WaveCore
@testable import WaveFeels

/// Настоящий адаптер не запускается: на CI MediaRemote может не работать, а `test` создает
/// фиктивную запись. Процессы проверяются на поддельном скрипте под тем же `/usr/bin/perl`.
struct MediaRemoteAdapterTests {
    @Test @MainActor func emptyBundleIsUnavailable() throws {
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent("wf-empty-\(UUID().uuidString).app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app) }
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.wfeels.wavefeels.empty-test",
            "CFBundleVersion": "1",
            "CFBundlePackageType": "APPL",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try #require(Bundle(url: app))

        let adapter = MediaRemoteAdapter(bundle: bundle)
        #expect(adapter.availability == .unknown)
        adapter.start()
        #expect(adapter.availability == .unavailable(exitCode: -1, stderr: "нет файлов адаптера"))
        #expect(!adapter.isAvailable)
        #expect(adapter.info == nil)
        #expect(adapter.lastTestExitCode == nil)
        adapter.send(.togglePlayPause)
        adapter.stop()
        #expect(adapter.availability == .unavailable(exitCode: -1, stderr: "нет файлов адаптера"))
    }

    @Test func commandIDsMatchAdapterReadme() {
        #expect(MediaCommand.play.rawValue == 0)
        #expect(MediaCommand.pause.rawValue == 1)
        #expect(MediaCommand.togglePlayPause.rawValue == 2)
        #expect(MediaCommand.nextTrack.rawValue == 4)
        #expect(MediaCommand.previousTrack.rawValue == 5)
    }

    @Test func lineSplitterKeepsOrderAcrossChunks() {
        let splitter = LineSplitter()
        #expect(splitter.append(Data("{\"a\":".utf8)).isEmpty)
        #expect(splitter.append(Data("1}\n{\"b\":2}\n{\"c\"".utf8)) == ["{\"a\":1}", "{\"b\":2}"])
        #expect(splitter.append(Data(":3}\n\n".utf8)) == ["{\"c\":3}", ""])
        #expect(splitter.finish() == nil)
        #expect(splitter.append(Data("tail".utf8)).isEmpty)
        #expect(splitter.finish() == "tail")
    }

    /// Строки потока разбираются вне главного потока (`NowPlayingLineDecoder`): состояние
    /// копится между строками, длительность проверяется, плохая строка отдается началом.
    @Test func lineDecoderParsesStreamOffMain() async {
        let decoded = await Task.detached { () -> [AdapterOutput] in
            let decoder = NowPlayingLineDecoder()
            let snapshot = #"{"type":"data","diff":false,"payload":{"bundleIdentifier":"com.apple.Music","title":"One","playing":true,"durationMicros":1e18}}"#
            let diff = #"{"type":"data","diff":true,"payload":{"playing":false}}"#
            let broken = "{" + String(repeating: "x", count: 500)
            return [snapshot, diff, broken].map { decoder.decode($0) }
        }.value
        #expect(decoded.count == 3)
        guard case .nowPlaying(let first?) = decoded[0], case .nowPlaying(let second?) = decoded[1] else {
            Issue.record("строки потока не разобраны: \(decoded)")
            return
        }
        #expect(first.title == "One")
        #expect(first.isPlaying)
        #expect(first.duration == nil)
        #expect(second.title == "One")
        #expect(!second.isPlaying)
        #expect(decoded[2] == .unparsed("{" + String(repeating: "x", count: NowPlayingLineDecoder.unparsedPrefix - 1)))
    }

    @Test func absurdDurationIsDropped() {
        let track = NowPlayingInfo(bundleIdentifier: "com.apple.Music", title: "Песня", duration: 200)
        #expect(MediaRemoteAdapter.sanitized(track).duration == 200)
        var long = track
        long.duration = 2 * 24 * 3600
        #expect(MediaRemoteAdapter.sanitized(long).duration == nil)
        var infinite = track
        infinite.duration = .infinity
        #expect(MediaRemoteAdapter.sanitized(infinite).duration == nil)
    }

    @Test @MainActor func hungTestIsKilledAndStreamStillStarts() async throws {
        let fake = try FakeAdapter(body: #"""
            if ($cmd eq 'test') { $SIG{TERM} = 'IGNORE'; sleep 30; exit 0; }
            if ($cmd eq 'stream') { print track('One'); sleep 30; }
            """#)
        defer { fake.remove() }
        var timing = AdapterTiming()
        timing.testTimeout = .milliseconds(300)
        timing.testKillGrace = .milliseconds(300)
        let adapter = MediaRemoteAdapter(bundle: fake.bundle, defaults: fake.defaults, timing: timing)
        adapter.start()
        defer { adapter.stop() }
        #expect(adapter.availability == .checking)

        let started = await waitUntil(.seconds(30)) { adapter.info?.title == "One" }
        #expect(started)
        #expect(adapter.lastTestExitCode == SIGKILL)
        #expect(adapter.availability == .available)
        #expect(fake.defaults.integer(forKey: MediaRemoteAdapter.testExitCodeKey) == Int(SIGKILL))
        let key = MediaRemoteAdapter.testCacheKey(build: "1", system: ProcessInfo.processInfo.operatingSystemVersionString)
        #expect(fake.defaults.string(forKey: MediaRemoteAdapter.testedBuildKey) == key)
    }

    /// Результат `test` хранится для пары «сборка приложения и сборка macOS»: после обновления
    /// системы проверка идет заново, при той же паре берется из кэша.
    @Test @MainActor func testCacheIsKeyedByOSBuild() async throws {
        let fake = try FakeAdapter(body: #"""
            if ($cmd eq 'test') { exit 7; }
            if ($cmd eq 'stream') { print $empty; sleep 30; }
            """#)
        defer { fake.remove() }
        fake.defaults.set(0, forKey: MediaRemoteAdapter.testExitCodeKey)
        fake.defaults.set(MediaRemoteAdapter.testCacheKey(build: "1", system: "macOS old"), forKey: MediaRemoteAdapter.testedBuildKey)

        let updated = MediaRemoteAdapter(bundle: fake.bundle, defaults: fake.defaults, system: "macOS new")
        updated.start()
        #expect(updated.availability == .checking)
        let tested = await waitUntil(.seconds(30)) { updated.lastTestExitCode == 7 }
        updated.stop()
        #expect(tested)
        #expect(updated.availability == .unavailable(exitCode: 7, stderr: ""))
        #expect(fake.calls("test") == 1)
        let key = MediaRemoteAdapter.testCacheKey(build: "1", system: "macOS new")
        #expect(fake.defaults.string(forKey: MediaRemoteAdapter.testedBuildKey) == key)

        let again = MediaRemoteAdapter(bundle: fake.bundle, defaults: fake.defaults, system: "macOS new")
        again.start()
        defer { again.stop() }
        #expect(again.availability == .unavailable(exitCode: 7, stderr: ""))
        #expect(again.lastTestExitCode == 7)
        #expect(fake.calls("test") == 1)
    }

    /// «Тишина адаптера»: работающий адаптер уходит в запасной режим, треки других приложений
    /// его не возвращают, трек источника (`clearSilence`) и новый запуск возвращают.
    @Test @MainActor func silentAdapterStaysInFallbackUntilSourceTrackOrRestart() async throws {
        let fake = try FakeAdapter(body: #"""
            if ($cmd eq 'stream' && $launch == 1) { print track('One'); wait_for('go1'); print track('Two'); sleep 30; }
            if ($cmd eq 'stream') { print track('Three'); sleep 30; }
            """#)
        defer { fake.remove() }
        let adapter = MediaRemoteAdapter(bundle: fake.bundle, defaults: fake.defaults)
        adapter.start()
        defer { adapter.stop() }
        #expect(await waitUntil(.seconds(30)) { adapter.info?.title == "One" })
        #expect(adapter.isAvailable)

        adapter.markSilent()
        #expect(adapter.availability == .silent)
        #expect(!adapter.isAvailable)
        fake.touch("go1")
        #expect(await waitUntil(.seconds(30)) { adapter.info?.title == "Two" })
        #expect(adapter.availability == .silent)

        adapter.clearSilence()
        #expect(adapter.availability == .available)

        adapter.markSilent()
        adapter.stop()
        adapter.start()
        #expect(adapter.availability == .available)
        #expect(await waitUntil(.seconds(30)) { adapter.info?.title == "Three" })
        #expect(adapter.availability == .available)
    }

    /// «Тишина адаптера» снимает смена источника; треки других приложений на тиках модели ее
    /// не снимают.
    @Test @MainActor func silentAdapterClearsOnSourceChange() async throws {
        _ = NSApplication.shared
        let fake = try FakeAdapter(body: #"""
            if ($cmd eq 'stream') { print track('One'); sleep 30; }
            """#)
        defer { fake.remove() }
        let model = AppModel(defaults: fake.defaults, bundle: fake.bundle)
        model.defaultSourceResolver = { .systemWide }
        model.settings.source = AudioSource.application(
            bundleID: "com.example.player",
            bundlePath: "/nonexistent/Player.app",
            displayName: "Плеер"
        )
        // Без захвата модель адаптер не запускает: он запускается здесь.
        model.start(arguments: LaunchArguments(noCapture: true))
        defer { model.stop() }
        model.adapter.start()
        #expect(await waitUntil(.seconds(30)) { model.adapter.info?.title == "One" })
        #expect(model.adapter.isAvailable)

        model.adapter.markSilent()
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.adapter.availability == .silent)

        model.settings.source = AudioSource.application(
            bundleID: "com.example.other",
            bundlePath: "/nonexistent/Other.app",
            displayName: "Другой"
        )
        #expect(await waitUntil(.seconds(5)) { model.adapter.availability == .available })
    }

    /// Поток адаптера, переживший прошлый запуск (родитель launchd), первый `start()`
    /// завершает; свои процессы адаптер не трогает.
    @Test @MainActor func orphanedStreamFromPreviousRunIsTerminated() async throws {
        let fake = try FakeAdapter(body: #"""
            if ($cmd eq 'stream') { print track('Own'); sleep 30; }
            """#)
        defer { fake.remove() }
        let paths = try #require(AdapterPaths(bundle: fake.bundle))

        // Оболочка запускает поток в фоне и выходит: родителем потока становится launchd.
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = [
            "-c", #"/usr/bin/perl "$0" "$1" stream --micros </dev/null >/dev/null 2>&1 & echo $!"#,
            paths.script, paths.framework,
        ]
        let pipe = Pipe()
        shell.standardOutput = pipe
        try shell.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        shell.waitUntilExit()
        let orphan = try #require(Int32(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        defer {
            // Если тест упал, поток не должен пережить его.
            if kill(orphan, 0) == 0 { kill(orphan, SIGKILL) }
        }
        #expect(kill(orphan, 0) == 0)

        let adapter = MediaRemoteAdapter(bundle: fake.bundle, defaults: fake.defaults)
        adapter.start()
        defer { adapter.stop() }
        #expect(await waitUntil(.seconds(30)) { kill(orphan, 0) != 0 })
        // Свой поток адаптера при этом жив и выдает трек.
        #expect(await waitUntil(.seconds(30)) { adapter.info?.title == "Own" })
    }

    /// Пометить молчащим можно только работающий адаптер.
    @Test @MainActor func onlyAvailableAdapterCanBeMarkedSilent() throws {
        let fake = try FakeAdapter(body: #"""
            if ($cmd eq 'test') { sleep 30; }
            """#)
        defer { fake.remove() }
        let adapter = MediaRemoteAdapter(bundle: fake.bundle, defaults: fake.defaults)
        adapter.start()
        defer { adapter.stop() }
        #expect(adapter.availability == .checking)
        adapter.markSilent()
        #expect(adapter.availability == .checking)
        adapter.clearSilence()
        #expect(adapter.availability == .checking)
    }

    @Test @MainActor func longLivedStreamDeathsDoNotAccumulate() async throws {
        let fake = try FakeAdapter(body: #"""
            if ($cmd eq 'stream') { print $empty; pause_s(0.4); exit 3; }
            """#)
        defer { fake.remove() }
        var timing = AdapterTiming()
        timing.restartDelays = [.milliseconds(50)]
        timing.maxRestarts = 1
        timing.stableRun = .milliseconds(200)
        let adapter = MediaRemoteAdapter(bundle: fake.bundle, defaults: fake.defaults, timing: timing)
        adapter.start()
        defer { adapter.stop() }

        let launched = await waitUntil(.seconds(30)) { fake.streamLaunches() >= 4 }
        #expect(launched)
        #expect(adapter.availability == .available)
    }

    @Test @MainActor func quickStreamDeathsMakeAdapterUnavailable() async throws {
        let fake = try FakeAdapter(body: #"""
            if ($cmd eq 'stream') { print $empty; pause_s(0.1); print STDERR "boom\n"; exit 3; }
            """#)
        defer { fake.remove() }
        var timing = AdapterTiming()
        timing.restartDelays = [.milliseconds(50)]
        timing.maxRestarts = 1
        let adapter = MediaRemoteAdapter(bundle: fake.bundle, defaults: fake.defaults, timing: timing)
        adapter.start()
        defer { adapter.stop() }

        let gaveUp = await waitUntil(.seconds(30)) { !adapter.isAvailable && adapter.availability != .checking }
        #expect(gaveUp)
        #expect(adapter.availability == .unavailable(exitCode: 3, stderr: "boom\nboom"))
        #expect(fake.streamLaunches() == 2)
    }

    @Test @MainActor func restartKeepsTrackUntilNewPayload() async throws {
        let fake = try FakeAdapter(body: Self.restartBody)
        defer { fake.remove() }
        var timing = AdapterTiming()
        timing.restartDelays = [.milliseconds(50)]
        // Шаги идут по команде теста, так что длинное удержание тест не замедляет, а остановка
        // главного актора на CI (около 10 с) не успевает его исчерпать.
        timing.restartInfoHold = .seconds(60)
        let adapter = MediaRemoteAdapter(bundle: fake.bundle, defaults: fake.defaults, timing: timing)
        adapter.start()
        defer { adapter.stop() }

        #expect(await waitUntil(.seconds(30)) { adapter.info?.title == "One" })
        var titles: [String?] = ["One"]
        func record() {
            let current: String? = adapter.info?.title
            if titles.last != .some(current) { titles.append(current) }
        }
        fake.touch("go1")
        // Второй поток выдал пустой снимок и ждет go2: прежний трек должен держаться.
        #expect(await waitUntil(.seconds(30)) { record(); return fake.exists("empty2") })
        _ = await waitUntil(.milliseconds(300)) { record(); return false }
        fake.touch("go2")
        let reachedTwo = await waitUntil(.seconds(30)) { record(); return adapter.info?.title == "Two" }
        #expect(reachedTwo)
        #expect(titles == ["One", "Two"])
        #expect(fake.streamLaunches() == 2)
    }

    @Test @MainActor func restartHoldExpires() async throws {
        let fake = try FakeAdapter(body: Self.restartBody)
        defer { fake.remove() }
        var timing = AdapterTiming()
        timing.restartDelays = [.milliseconds(50)]
        timing.restartInfoHold = .milliseconds(200)
        let adapter = MediaRemoteAdapter(bundle: fake.bundle, defaults: fake.defaults, timing: timing)
        adapter.start()
        defer { adapter.stop() }

        #expect(await waitUntil(.seconds(30)) { adapter.info?.title == "One" })
        fake.touch("go1")
        #expect(await waitUntil(.seconds(30)) { fake.exists("empty2") })
        // Второй поток молчит, пока нет go2: удержание (0,2 с) кончается и трек пропадает.
        #expect(await waitUntil(.seconds(30)) { adapter.info == nil })
        fake.touch("go2")
        #expect(await waitUntil(.seconds(30)) { adapter.info?.title == "Two" })
    }

    /// Первый поток: трек One, ждет go1 и умирает. Второй: пустой снимок, метка empty2,
    /// ждет go2, трек Two. Шаги идут по команде теста, поэтому задержки главного актора
    /// на CI (другие тесты держат его секундами) не прячут промежуточные состояния.
    private static let restartBody = #"""
        if ($cmd eq 'stream' && $launch == 1) { print $empty; print track('One'); wait_for('go1'); exit 1; }
        if ($cmd eq 'stream') { print $empty; touch('empty2'); wait_for('go2'); print track('Two'); sleep 30; }
        """#
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

/// Временный `.app` с поддельным `mediaremote-adapter.pl`. Тело скрипта видит `$cmd`
/// (`test`, `stream`, `send`), `$launch` (номер запуска `stream`), `$empty`, `track(title)`,
/// `pause_s(seconds)`, `touch(name)` и `wait_for(name)` (файлы-метки в каталоге `.app`, их же
/// видят `touch(_:)` и `exists(_:)` теста). По умолчанию `test` выходит с 0.
private struct FakeAdapter {
    let app: URL
    let bundle: Bundle
    let defaults: UserDefaults
    let suiteName: String

    init(body: String) throws {
        let manager = FileManager.default
        app = manager.temporaryDirectory
            .appendingPathComponent("wf-fake-\(UUID().uuidString).app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let adapterDir = contents.appendingPathComponent("Resources/Adapter", isDirectory: true)
        try manager.createDirectory(at: adapterDir, withIntermediateDirectories: true)
        try manager.createDirectory(
            at: contents.appendingPathComponent("Frameworks/MediaRemoteAdapter.framework", isDirectory: true),
            withIntermediateDirectories: true
        )
        let helpers = contents.appendingPathComponent("Helpers", isDirectory: true)
        try manager.createDirectory(at: helpers, withIntermediateDirectories: true)
        let client = helpers.appendingPathComponent("MediaRemoteAdapterTestClient")
        try Data("#!/bin/sh\n".utf8).write(to: client)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: client.path(percentEncoded: false))

        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.wfeels.wavefeels.fake-adapter-test",
            "CFBundleVersion": "1",
            "CFBundlePackageType": "APPL",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))

        let dir = app.path(percentEncoded: false)
        let log = app.appendingPathComponent("calls.log").path(percentEncoded: false)
        let script = #"""
            #!/usr/bin/perl
            use strict; use warnings;
            $| = 1;
            shift @ARGV;
            shift @ARGV if (($ARGV[0] // '') =~ m{/});
            my $cmd = shift @ARGV // '';
            my $dir = '\#(dir)';
            my $log = '\#(log)';
            open(my $out, '>>', $log) or die; print $out "$cmd\n"; close $out;
            open(my $in, '<', $log) or die; my $launch = grep { /^stream$/ } <$in>; close $in;
            my $empty = qq({"type":"data","diff":false,"payload":{}}\n);
            sub track { my ($title) = @_; return qq({"type":"data","diff":false,"payload":{"bundleIdentifier":"com.apple.Music","title":"$title","playing":true}}\n); }
            sub pause_s { select(undef, undef, undef, $_[0]); }
            sub touch { open(my $f, '>', "$dir/$_[0]") or die; close $f; }
            sub wait_for { my $n = 0; until (-e "$dir/$_[0]") { pause_s(0.02); exit 4 if ++$n > 3000; } }

            """# + body + "\nexit 0;\n"
        try Data(script.utf8).write(to: adapterDir.appendingPathComponent("mediaremote-adapter.pl"))

        bundle = try #require(Bundle(url: app))
        suiteName = "wf-adapter-tests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    func touch(_ name: String) {
        _ = FileManager.default.createFile(atPath: app.appendingPathComponent(name).path(percentEncoded: false), contents: nil)
    }

    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: app.appendingPathComponent(name).path(percentEncoded: false))
    }

    /// Сколько раз запускался `stream`.
    func streamLaunches() -> Int {
        calls("stream")
    }

    /// Сколько раз скрипт запускался с командой `command`.
    func calls(_ command: String) -> Int {
        let text = (try? String(contentsOf: app.appendingPathComponent("calls.log"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").filter { $0 == command }.count
    }

    func remove() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: app)
    }
}
