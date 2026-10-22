# WaveFeels mac CI: full

- result: failure
- ref: full-check-6
- sha: 0556736365bc4122f7dec1d3a73576071276c40a
- run: 31 attempt 1
- app version: 0.0.31 (build 31)
- duration: 301 s

## Steps

| step | outcome | seconds | note |
|---|---|---|---|
| toolchain | success | 4 |  |
| adapter | success | 35 |  |
| build-release | success | 51 |  |
| build-tests | success | 46 |  |
| test | failure | 45 | exit 1 |
| bundle | success | 29 |  |
| sign | success | 1 |  |
| snapshots | success | 5 |  |
| smoke | success | 4 |  |
| cpu | success | 81 |  |
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
✘ Test hungTestIsKilledAndStreamStillStarts() failed after 40.964 seconds with 5 issues.
✘ Suite MediaRemoteAdapterTests failed after 41.555 seconds with 5 issues.
✘ Test run with 248 tests in 26 suites failed after 43.226 seconds with 5 issues.
```

## Workflow

- ci step outcome: failure
- ref: full-check-6
- run: https://github.com/wFeeL/music-wave/actions/runs/39744930079
- results: runs/20261022T080842Z-0556736-mac-full-a1
