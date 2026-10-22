# WaveFeels mac CI: full

- result: failure
- ref: full-check-5
- sha: 3da899b52032914f60d3e68d7a14c14c69a6551f
- run: 25 attempt 1
- app version: 0.0.25 (build 25)
- duration: 225 s

## Steps

| step | outcome | seconds | note |
|---|---|---|---|
| toolchain | success | 4 |  |
| adapter | success | 30 |  |
| build-release | success | 56 |  |
| build-tests | success | 57 |  |
| test | failure | 67 | exit 1 |
| bundle | success | 1 |  |
| sign | success | 1 |  |
| snapshots | success | 6 |  |
| smoke | success | 3 |  |
| cpu | skipped | - | scripts/cpu-probe.sh not present |
| zip | success | 0 |  |

## Toolchain

```
swift-driver version: 1.148.6 Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)
Target: arm64-apple-macosx26.0
Xcode 26.6
Build version 17F113
```

## Errors and warnings (first 40, full list in errors.txt)

```
✘ Test hungTestIsKilledAndStreamStillStarts() recorded an issue at MediaRemoteAdapterTests.swift:80:9: Expectation failed: started
✘ Test hungTestIsKilledAndStreamStillStarts() recorded an issue at MediaRemoteAdapterTests.swift:81:9: Expectation failed: (adapter.lastTestExitCode → nil) == (SIGKILL → 9)
✘ Test hungTestIsKilledAndStreamStillStarts() recorded an issue at MediaRemoteAdapterTests.swift:82:9: Expectation failed: (adapter.availability → .checking) == .available
✘ Test hungTestIsKilledAndStreamStillStarts() recorded an issue at MediaRemoteAdapterTests.swift:83:9: Expectation failed: (fake.defaults.integer(forKey: MediaRemoteAdapter.testExitCodeKey) → 0) == (Int(SIGKILL) → 9)
✘ Test hungTestIsKilledAndStreamStillStarts() recorded an issue at MediaRemoteAdapterTests.swift:84:9: Expectation failed: (fake.defaults.string(forKey: MediaRemoteAdapter.testedBuildKey) → nil) == "1"
✘ Test hungTestIsKilledAndStreamStillStarts() failed after 39.593 seconds with 5 issues.
✘ Test sleepStopsDemoAndWakeRestartsIt() recorded an issue at PipelineLifecycleTests.swift:77:9: Expectation failed: (model.pipeline.status → .stopped) == .demo
✘ Test sleepStopsDemoAndWakeRestartsIt() recorded an issue at PipelineLifecycleTests.swift:78:9: Expectation failed: (model.pipeline.ringForTesting.activeWriters → 0) == 1
✘ Test sleepStopsDemoAndWakeRestartsIt() failed after 39.579 seconds with 2 issues.
✘ Suite PipelineLifecycleTests failed after 39.621 seconds with 2 issues.
✘ Suite MediaRemoteAdapterTests failed after 40.153 seconds with 5 issues.
✘ Test run with 245 tests in 26 suites failed after 64.679 seconds with 7 issues.
```

## Workflow

- ci step outcome: failure
- ref: full-check-5
- run: https://github.com/wFeeL/music-wave/actions/runs/39736726028
- results: runs/20261022T065638Z-3da899b-mac-full-a1
