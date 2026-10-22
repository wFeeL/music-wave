# WaveFeels mac CI: fast

- result: failure
- ref: ci-5
- sha: 15cb2c1da206f2854fbb3dc27062d94caf95feb9
- run: 9 attempt 1
- app version: 0.0.9 (build 9)
- duration: 31 s

## Steps

| step | outcome | seconds | note |
|---|---|---|---|
| toolchain | success | 3 |  |
| build-tests | failure | 28 | exit 1 |
| test | skipped | - | test build failed |

## Toolchain

```
swift-driver version: 1.148.6 Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)
Target: arm64-apple-macosx26.0
Xcode 26.6
Build version 17F113
```

## Errors and warnings (first 40, full list in errors.txt)

```
/Users/runner/work/music-wave/music-wave/Sources/WaveFeels/App/AppModel.swift:32:32: error: 'RGBColor' is ambiguous for type lookup in this context
macro expansion @ObservationTracked:2:25: error: 'RGBColor' is ambiguous for type lookup in this context
```

## Workflow

- ci step outcome: failure
- ref: ci-5
- run: https://github.com/wFeeL/music-wave/actions/runs/39717922097
- results: runs/20261022T033847Z-15cb2c1-mac-fast-a1
