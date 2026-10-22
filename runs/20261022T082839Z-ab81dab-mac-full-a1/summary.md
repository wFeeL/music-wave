# WaveFeels mac CI: full

- result: failure
- ref: full-check-6b
- sha: ab81dabc2cd7f9c23b0a0d6b7d06ea3129e29efc
- run: 32 attempt 1
- app version: 0.0.32 (build 32)
- duration: 405 s

## Steps

| step | outcome | seconds | note |
|---|---|---|---|
| toolchain | success | 7 |  |
| adapter | success | 57 |  |
| build-release | success | 92 |  |
| build-tests | success | 57 |  |
| test | failure | 49 | exit 1 |
| bundle | success | 32 |  |
| sign | success | 1 |  |
| snapshots | success | 6 |  |
| smoke | success | 4 |  |
| cpu | success | 99 |  |
| zip | success | 1 |  |

## Toolchain

```
swift-driver version: 1.148.6 Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)
Target: arm64-apple-macosx26.0
Xcode 26.6
Build version 17F113
```

## Errors and warnings (first 40, full list in errors.txt)

```
✘ Test idleEngineTicksAtFifteenHertz() recorded an issue at CoreAudioSmokeTests.swift:87:9: Expectation failed: (idleFrames → 477) <= 20
✘ Test idleEngineTicksAtFifteenHertz() failed after 34.516 seconds with 1 issue.
✘ Suite CoreAudioSmokeTests failed after 34.523 seconds with 1 issue.
✘ Test hungTestIsKilledAndStreamStillStarts() recorded an issue at MediaRemoteAdapterTests.swift:81:9: Expectation failed: (adapter.lastTestExitCode → 0) == (SIGKILL → 9)
✘ Test hungTestIsKilledAndStreamStillStarts() recorded an issue at MediaRemoteAdapterTests.swift:83:9: Expectation failed: (fake.defaults.integer(forKey: MediaRemoteAdapter.testExitCodeKey) → 0) == (Int(SIGKILL) → 9)
✘ Test hungTestIsKilledAndStreamStillStarts() failed after 37.532 seconds with 2 issues.
✘ Suite MediaRemoteAdapterTests failed after 40.189 seconds with 2 issues.
✘ Test rendersAllSnapshotsWithVisibleWaves() recorded an issue at SnapshotRendererTests.swift:123:9: Expectation failed: (longest → 37.358735167000006 seconds) < (.seconds(5) → 5.0 seconds)
✘ Test rendersAllSnapshotsWithVisibleWaves() failed after 44.061 seconds with 1 issue.
✘ Suite SnapshotRendererTests failed after 44.063 seconds with 1 issue.
✘ Test run with 249 tests in 26 suites failed after 46.019 seconds with 4 issues.
```

## Workflow

- ci step outcome: failure
- ref: full-check-6b
- run: https://github.com/wFeeL/music-wave/actions/runs/39746546070
- results: runs/20261022T082839Z-ab81dab-mac-full-a1
