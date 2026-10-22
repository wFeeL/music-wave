# WaveFeels mac CI: fast

- result: failure
- ref: ci-v1-5
- sha: 9ceb59587bc8526f44def2d3e1eccce769239b46
- run: 39 attempt 1
- app version: 0.0.39 (build 39)
- duration: 147 s

## Steps

| step | outcome | seconds | note |
|---|---|---|---|
| toolchain | success | 4 |  |
| build-tests | success | 80 |  |
| test | failure | 63 | exit 1 |

## Toolchain

```
swift-driver version: 1.148.6 Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)
Target: arm64-apple-macosx26.0
Xcode 26.6
Build version 17F113
```

## Errors and warnings (first 40, full list in errors.txt)

```
✘ Test hungTestIsKilledAndStreamStillStarts() recorded an issue at MediaRemoteAdapterTests.swift:103:9: Expectation failed: started
✘ Test hungTestIsKilledAndStreamStillStarts() recorded an issue at MediaRemoteAdapterTests.swift:104:9: Expectation failed: (adapter.lastTestExitCode → nil) == (SIGKILL → 9)
✘ Test hungTestIsKilledAndStreamStillStarts() recorded an issue at MediaRemoteAdapterTests.swift:105:9: Expectation failed: (adapter.availability → .checking) == .available
✘ Test hungTestIsKilledAndStreamStillStarts() recorded an issue at MediaRemoteAdapterTests.swift:106:9: Expectation failed: (fake.defaults.integer(forKey: MediaRemoteAdapter.testExitCodeKey) → 0) == (Int(SIGKILL) → 9)
✘ Test hungTestIsKilledAndStreamStillStarts() recorded an issue at MediaRemoteAdapterTests.swift:108:9: Expectation failed: (fake.defaults.string(forKey: MediaRemoteAdapter.testedBuildKey) → nil) == (key → "1 | Version 26.6.2 (Build 25G83)")
✘ Test hungTestIsKilledAndStreamStillStarts() failed after 32.847 seconds with 5 issues.
✘ Test pointerExpandsAndCollapsesIslandAndReportsStateChanges() recorded an issue at AppModelIslandTests.swift:26:9: Expectation failed: await waitUntil(.seconds(30)) { model.islandState == .collapsed }
✘ Test pointerExpandsAndCollapsesIslandAndReportsStateChanges() failed after 35.162 seconds with 1 issue.
✘ Suite MediaRemoteAdapterTests failed after 36.741 seconds with 5 issues.
✘ Suite AppModelIslandTests failed after 37.535 seconds with 1 issue.
✘ Test run with 425 tests in 49 suites failed after 53.780 seconds with 6 issues.
```

## Workflow

- ci step outcome: failure
- ref: ci-v1-5
- run: https://github.com/wFeeL/music-wave/actions/runs/39798147036
- results: runs/20261022T144549Z-9ceb595-mac-fast-a1
