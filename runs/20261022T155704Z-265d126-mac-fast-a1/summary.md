# WaveFeels mac CI: fast

- result: failure
- ref: ci-v1-7
- sha: 265d1262733de72b79f1b438ee4355507c8e9c00
- run: 41 attempt 1
- app version: 0.0.41 (build 41)
- duration: 108 s

## Steps

| step | outcome | seconds | note |
|---|---|---|---|
| toolchain | success | 3 |  |
| build-tests | success | 78 |  |
| test | failure | 27 | exit 1 |

## Toolchain

```
swift-driver version: 1.148.6 Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)
Target: arm64-apple-macosx26.0
Xcode 26.6
Build version 17F113
```

## Errors and warnings (first 40, full list in errors.txt)

```
✘ Test diagnosticsHaveRhythmSection() recorded an issue at AppModelRenderTests.swift:102:9: Expectation failed: (empty.rows.map(\.value) → ["нет", "0.00", "нет", "13 мс", "33 мс", "7 мс", "0 мс"]) == ["нет", "0.00", "нет", "0 мс", "33 мс", "7 мс", "0 мс"]
✘ Test diagnosticsHaveRhythmSection() failed after 8.761 seconds with 1 issue.
✘ Suite AppModelRenderTests failed after 8.765 seconds with 1 issue.
✘ Test run with 424 tests in 48 suites failed after 19.112 seconds with 1 issue.
```

## Workflow

- ci step outcome: failure
- ref: ci-v1-7
- run: https://github.com/wFeeL/music-wave/actions/runs/39809321261
- results: runs/20261022T155704Z-265d126-mac-fast-a1
