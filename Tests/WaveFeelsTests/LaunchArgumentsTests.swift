import Testing
import Foundation
@testable import WaveFeels

struct LaunchArgumentsTests {
    @Test func emptyArgumentsGiveDefaults() {
        let parsed = LaunchArguments.parse([])
        #expect(parsed == LaunchArguments())
        #expect(parsed.demoFile == nil)
        #expect(parsed.snapshotDirectory == nil)
        #expect(parsed.fakeNotch == false)
        #expect(parsed.noCapture == false)
        #expect(parsed.exitAfter == nil)
    }

    @Test func parsesAllFlags() {
        let parsed = LaunchArguments.parse([
            "/Applications/WaveFeels.app/Contents/MacOS/WaveFeels",
            "--demo", "/tmp/demo.wav",
            "--render-snapshots", "/tmp/snapshots",
            "--fake-notch",
            "--no-capture",
            "--exit-after", "2.5",
        ])
        #expect(parsed.demoFile == URL(fileURLWithPath: "/tmp/demo.wav"))
        #expect(parsed.snapshotDirectory == URL(fileURLWithPath: "/tmp/snapshots", isDirectory: true))
        #expect(parsed.fakeNotch)
        #expect(parsed.noCapture)
        #expect(parsed.exitAfter == 2.5)
    }

    @Test func ignoresUnknownArguments() {
        let parsed = LaunchArguments.parse([
            "WaveFeels",
            "-NSDocumentRevisionsDebugMode", "YES",
            "--unknown",
            "--fake-notch",
            "-ApplePersistenceIgnoreState", "YES",
        ])
        #expect(parsed == LaunchArguments(fakeNotch: true))
    }

    @Test func missingDemoValueGivesNil() {
        #expect(LaunchArguments.parse(["--demo"]).demoFile == nil)
    }

    @Test func flagAfterDemoIsNotTakenAsValue() {
        let parsed = LaunchArguments.parse(["--demo", "--no-capture"])
        #expect(parsed.demoFile == nil)
        #expect(parsed.noCapture)
    }

    @Test func invalidExitAfterGivesNil() {
        #expect(LaunchArguments.parse(["--exit-after"]).exitAfter == nil)
        #expect(LaunchArguments.parse(["--exit-after", "soon"]).exitAfter == nil)
        #expect(LaunchArguments.parse(["--exit-after", "-1"]).exitAfter == nil)
        #expect(LaunchArguments.parse(["--exit-after", "0"]).exitAfter == nil)
        #expect(LaunchArguments.parse(["--exit-after", "inf"]).exitAfter == nil)
    }

    @Test func integerExitAfterIsAccepted() {
        #expect(LaunchArguments.parse(["--exit-after", "3"]).exitAfter == 3)
    }
}
