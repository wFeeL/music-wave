# WaveFeels mac CI: snap

- result: success
- ref: snap-6
- sha: 5373491f3e43324eccaf3aca2fdb7d5d4d7e9ecc
- run: 30 attempt 1
- app version: 0.0.30 (build 30)
- duration: 107 s

## Steps

| step | outcome | seconds | note |
|---|---|---|---|
| toolchain | success | 3 |  |
| build-release | success | 66 |  |
| bundle | success | 27 |  |
| sign | success | 1 |  |
| snapshots | success | 7 |  |
| smoke | success | 3 |  |

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
- ref: snap-6
- run: https://github.com/wFeeL/music-wave/actions/runs/39742805265
- results: runs/20261022T074800Z-5373491-mac-snap-a1
