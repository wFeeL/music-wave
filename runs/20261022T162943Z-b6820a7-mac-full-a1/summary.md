# WaveFeels mac CI: full

- result: success
- ref: full-check-9
- sha: b6820a73556125607f7a3cfc190a4560a16e6c1c
- run: 44 attempt 1
- app version: 0.0.44 (build 44)
- duration: 299 s

## Steps

| step | outcome | seconds | note |
|---|---|---|---|
| toolchain | success | 3 |  |
| adapter | success | 28 |  |
| build-release | success | 66 |  |
| build-tests | success | 59 |  |
| test | success | 20 |  |
| bundle | success | 29 |  |
| sign | success | 1 |  |
| snapshots | success | 8 |  |
| smoke | success | 3 |  |
| cpu | success | 82 |  |
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
```

## Workflow

- ci step outcome: success
- ref: full-check-9
- run: https://github.com/wFeeL/music-wave/actions/runs/39812964651
- results: runs/20261022T162943Z-b6820a7-mac-full-a1
