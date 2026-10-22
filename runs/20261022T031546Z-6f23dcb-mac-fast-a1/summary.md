# WaveFeels mac CI: fast

- result: failure
- ref: ci-3
- sha: 6f23dcb9b9f2951c08f2c3c0385951ecf8b70725
- run: 7 attempt 1
- app version: 0.0.7 (build 7)
- duration: 92 s

## Steps

| step | outcome | seconds | note |
|---|---|---|---|
| toolchain | success | 4 |  |
| build-tests | success | 36 |  |
| test | failure | 52 | exit 1 |

## Toolchain

```
swift-driver version: 1.148.6 Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)
Target: arm64-apple-macosx26.0
Xcode 26.6
Build version 17F113
```

## Errors and warnings (first 40, full list in errors.txt)

```
✘ Test restartHoldExpires() recorded an issue at MediaRemoteAdapterTests.swift:154:9: Expectation failed: await waitUntil(.seconds(5)) { adapter.info?.title == "One" }
✘ Test restartKeepsTrackUntilNewPayload() recorded an issue at MediaRemoteAdapterTests.swift:133:9: Expectation failed: await waitUntil(.seconds(5)) { adapter.info?.title == "One" }
✘ Test restartKeepsTrackUntilNewPayload() recorded an issue at MediaRemoteAdapterTests.swift:140:9: Expectation failed: (titles → [Optional("Two")]) == (["One", "Two"] → [Optional("One"), Optional("Two")])
✘ Test hungTestIsKilledAndStreamStillStarts() recorded an issue at MediaRemoteAdapterTests.swift:80:9: Expectation failed: started
✘ Test restartKeepsTrackUntilNewPayload() failed after 10.660 seconds with 2 issues.
✘ Test hungTestIsKilledAndStreamStillStarts() recorded an issue at MediaRemoteAdapterTests.swift:81:9: Expectation failed: (adapter.lastTestExitCode → nil) == (SIGKILL → 9)
✘ Test hungTestIsKilledAndStreamStillStarts() recorded an issue at MediaRemoteAdapterTests.swift:82:9: Expectation failed: (adapter.availability → .checking) == .available
✘ Test hungTestIsKilledAndStreamStillStarts() recorded an issue at MediaRemoteAdapterTests.swift:83:9: Expectation failed: (fake.defaults.integer(forKey: MediaRemoteAdapter.testExitCodeKey) → 0) == (Int(SIGKILL) → 9)
✘ Test hungTestIsKilledAndStreamStillStarts() recorded an issue at MediaRemoteAdapterTests.swift:84:9: Expectation failed: (fake.defaults.string(forKey: MediaRemoteAdapter.testedBuildKey) → nil) == "1"
✘ Test hungTestIsKilledAndStreamStillStarts() failed after 10.663 seconds with 5 issues.
✘ Test restartHoldExpires() recorded an issue at MediaRemoteAdapterTests.swift:157:9: Expectation failed: await waitUntil(.seconds(1)) { adapter.info == nil }
✘ Test restartHoldExpires() failed after 11.682 seconds with 2 issues.
✘ Suite MediaRemoteAdapterTests failed after 11.683 seconds with 9 issues.
✘ Test run with 160 tests in 16 suites failed after 48.104 seconds with 9 issues.
```

## Workflow

- ci step outcome: failure
- ref: ci-3
- run: https://github.com/wFeeL/music-wave/actions/runs/39715715575
- results: runs/20261022T031546Z-6f23dcb-mac-fast-a1
