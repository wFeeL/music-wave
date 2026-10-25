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
        #expect(parsed.settingsSuite == nil)
        #expect(parsed.island == nil)
        #expect(parsed.warnings.isEmpty)
    }

    @Test func parsesAllFlags() {
        let parsed = LaunchArguments.parse([
            "/Applications/WaveFeels.app/Contents/MacOS/WaveFeels",
            "--demo", "/tmp/demo.wav",
            "--render-snapshots", "/tmp/snapshots",
            "--fake-notch",
            "--no-capture",
            "--exit-after", "2.5",
            "--settings-suite", "com.wfeels.wavefeels.benchmark",
            "--island", "expanded",
        ])
        #expect(parsed.demoFile == URL(fileURLWithPath: "/tmp/demo.wav"))
        #expect(parsed.snapshotDirectory == URL(fileURLWithPath: "/tmp/snapshots", isDirectory: true))
        #expect(parsed.fakeNotch)
        #expect(parsed.noCapture)
        #expect(parsed.exitAfter == 2.5)
        #expect(parsed.settingsSuite == "com.wfeels.wavefeels.benchmark")
        #expect(parsed.island == .expanded)
        #expect(parsed.warnings.isEmpty)
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

    @Test func missingOrEmptySettingsSuiteGivesNil() {
        #expect(LaunchArguments.parse(["--settings-suite"]).settingsSuite == nil)
        #expect(LaunchArguments.parse(["--settings-suite", ""]).settingsSuite == nil)
        let parsed = LaunchArguments.parse(["--settings-suite", "--fake-notch"])
        #expect(parsed.settingsSuite == nil)
        #expect(parsed.fakeNotch)
    }

    @Test func parsesEveryIslandValue() {
        for island in ForcedIsland.allCases {
            #expect(LaunchArguments.parse(["--island", island.rawValue]) == LaunchArguments(island: island))
        }
        #expect(ForcedIsland.allCases.map(\.rawValue) == ["collapsed", "expanded", "banner"])
    }

    @Test func unknownOrMissingIslandIsIgnoredWithWarning() {
        let unknown = LaunchArguments.parse(["--island", "open", "--fake-notch"])
        #expect(unknown.island == nil)
        #expect(unknown.fakeNotch)
        #expect(unknown.warnings == [
            "аргумент --island пропущен (значение «open»): ожидается collapsed, expanded или banner",
        ])

        let missing = LaunchArguments.parse(["--island", "--no-capture"])
        #expect(missing.island == nil)
        #expect(missing.noCapture)
        #expect(missing.warnings == [
            "аргумент --island пропущен (значения нет): ожидается collapsed, expanded или banner",
        ])

        // Неизвестное значение не сбрасывает уже разобранное.
        let kept = LaunchArguments.parse(["--island", "banner", "--island", "Expanded"])
        #expect(kept.island == .banner)
        #expect(kept.warnings.count == 1)
    }

    @Test func integerExitAfterIsAccepted() {
        #expect(LaunchArguments.parse(["--exit-after", "3"]).exitAfter == 3)
    }
}
