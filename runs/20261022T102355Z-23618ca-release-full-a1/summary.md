# WaveFeels mac CI: full

- result: failure
- ref: v0.9.0
- sha: 23618ca5f43e5defa41ed7f2c4d066d94a38db6a
- run: 3 attempt 1
- app version: 0.9.0 (build 3)
- duration: 327 s

## Steps

| step | outcome | seconds | note |
|---|---|---|---|
| toolchain | success | 4 |  |
| adapter | success | 37 |  |
| build-release | success | 56 |  |
| build-tests | success | 56 |  |
| test | failure | 46 | exit 1 |
| bundle | success | 32 |  |
| sign | success | 1 |  |
| snapshots | success | 7 |  |
| smoke | success | 4 |  |
| cpu | success | 82 |  |
| zip | success | 0 |  |
| bundle-update-test | success | 1 |  |
| sign-update-test | success | 1 |  |
| requirements | success | 0 |  |
| zip-update-test | success | 0 |  |

## Toolchain

```
swift-driver version: 1.148.6 Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)
Target: arm64-apple-macosx26.0
Xcode 26.6
Build version 17F113
```

## Errors and warnings (first 40, full list in errors.txt)

```
✘ Test pointerExpandsAndCollapsesIslandAndReportsStateChanges() recorded an issue at AppModelIslandTests.swift:26:9: Expectation failed: await waitUntil(.seconds(10)) { model.islandState == .collapsed }
✘ Test pointerExpandsAndCollapsesIslandAndReportsStateChanges() failed after 18.479 seconds with 1 issue.
✘ Suite AppModelIslandTests failed after 21.264 seconds with 1 issue.
✘ Test run with 300 tests in 34 suites failed after 44.488 seconds with 1 issue.
```

## Workflow

- ci step outcome: failure
- release step outcome: skipped
- ref: v0.9.0
- run: https://github.com/wFeeL/music-wave/actions/runs/39762094222
- results: runs/20261022T102355Z-23618ca-release-full-a1
