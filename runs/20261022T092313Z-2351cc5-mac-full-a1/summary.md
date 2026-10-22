# WaveFeels mac CI: full

- result: failure
- ref: full-check-7
- sha: 2351cc5db001df47f5d89abc05adc772a870ce46
- run: 34 attempt 1
- app version: 0.0.34 (build 34)
- duration: 322 s

## Steps

| step | outcome | seconds | note |
|---|---|---|---|
| toolchain | success | 3 |  |
| adapter | success | 35 |  |
| build-release | success | 60 |  |
| build-tests | success | 62 |  |
| test | failure | 40 | exit 1 |
| bundle | success | 26 |  |
| sign | success | 2 |  |
| snapshots | success | 7 |  |
| smoke | success | 4 |  |
| cpu | success | 82 |  |
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
✘ Test sixHundredTransformsAreFast() recorded an issue at RealFFTTests.swift:73:5: Expectation failed: (elapsed → 3.399836458 seconds) < (limit → 3.0 seconds)
✘ Test sixHundredTransformsAreFast() failed after 16.747 seconds with 1 issue.
✘ Test run with 275 tests in 30 suites failed after 37.349 seconds with 1 issue.
```

## Workflow

- ci step outcome: failure
- ref: full-check-7
- run: https://github.com/wFeeL/music-wave/actions/runs/39754299667
- results: runs/20261022T092313Z-2351cc5-mac-full-a1
