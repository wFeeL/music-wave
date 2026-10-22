import Testing
@testable import WaveCore

struct OrphanedAdapterProcessesTests {
    private let script = "/Applications/WaveFeels.app/Contents/Resources/Adapter/mediaremote-adapter.pl"

    @Test func picksOnlyOrphansRunningThisBundlesScript() {
        let output = """
                1     0 /sbin/launchd
              501     1 /Applications/WaveFeels.app/Contents/MacOS/WaveFeels
              612     1 /usr/bin/perl \(script) /Applications/WaveFeels.app/Contents/Frameworks/MediaRemoteAdapter.framework stream --micros --debounce=100
              613   501 /usr/bin/perl \(script) /Applications/WaveFeels.app/Contents/Frameworks/MediaRemoteAdapter.framework stream --micros --debounce=100
              700     1 /usr/bin/perl /Users/me/Downloads/WaveFeels.app/Contents/Resources/Adapter/mediaremote-adapter.pl x stream
              701     1 /usr/bin/perl \(script).bak x stream
              702     1 /usr/bin/perl \(script)
            not a process line
            """
        #expect(OrphanedAdapterProcesses.pids(psOutput: output, scriptPath: script, excluding: 501) == [612, 702])
    }

    @Test func neverPicksItself() {
        let output = "  42     1 /usr/bin/perl \(script) x stream\n"
        #expect(OrphanedAdapterProcesses.pids(psOutput: output, scriptPath: script, excluding: 42).isEmpty)
        #expect(OrphanedAdapterProcesses.pids(psOutput: output, scriptPath: "", excluding: 0).isEmpty)
    }

    @Test func recheckAcceptsTheSameOrphan() {
        let line = "    1 /usr/bin/perl \(script) /Applications/WaveFeels.app/Contents/Frameworks/MediaRemoteAdapter.framework stream --micros\n"
        #expect(OrphanedAdapterProcesses.stillOrphan(psLine: line, scriptPath: script))
        #expect(OrphanedAdapterProcesses.stillOrphan(psLine: "1 /usr/bin/perl \(script)", scriptPath: script))
    }

    /// pid уже занят другим процессом: другая командная строка или процесса нет вовсе.
    @Test func recheckRejectsReusedPid() {
        #expect(!OrphanedAdapterProcesses.stillOrphan(psLine: "    1 /usr/libexec/someone-else --flag\n", scriptPath: script))
        #expect(!OrphanedAdapterProcesses.stillOrphan(psLine: "    1 /usr/bin/perl \(script).bak x stream", scriptPath: script))
        #expect(!OrphanedAdapterProcesses.stillOrphan(psLine: "", scriptPath: script))
        #expect(!OrphanedAdapterProcesses.stillOrphan(psLine: "    1 /usr/bin/perl \(script)", scriptPath: ""))
    }

    /// Родитель уже не launchd: процесс принадлежит работающему приложению.
    @Test func recheckRejectsLiveParent() {
        #expect(!OrphanedAdapterProcesses.stillOrphan(psLine: "  501 /usr/bin/perl \(script) x stream", scriptPath: script))
    }
}
