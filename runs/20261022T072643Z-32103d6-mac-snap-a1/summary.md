# WaveFeels mac CI: snap

- result: success
- ref: snap-4
- sha: 32103d61eb4f1e3ea1467d063ab33196ea1a4187
- run: 28 attempt 1
- app version: 0.0.28 (build 28)
- duration: 71 s

## Steps

| step | outcome | seconds | note |
|---|---|---|---|
| toolchain | success | 3 |  |
| build-release | success | 46 |  |
| bundle | success | 10 |  |
| sign | success | 1 |  |
| snapshots | success | 7 |  |
| smoke | success | 4 |  |

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
- ref: snap-4
- run: https://github.com/wFeeL/music-wave/actions/runs/39740380465
- results: runs/20261022T072643Z-32103d6-mac-snap-a1
