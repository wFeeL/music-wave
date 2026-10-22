# WaveFeels mac CI: snap

- result: success
- ref: snap-1
- sha: 16ac3fa71e95b4a4002ffc208a8d3f3908ad11c9
- run: 14 attempt 1
- app version: 0.0.14 (build 14)
- duration: 42 s

## Steps

| step | outcome | seconds | note |
|---|---|---|---|
| toolchain | success | 3 |  |
| build-release | success | 31 |  |
| bundle | success | 3 |  |
| sign | success | 0 |  |
| snapshots | success | 2 |  |
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
- ref: snap-1
- run: https://github.com/wFeeL/music-wave/actions/runs/39723891156
- results: runs/20261022T044330Z-16ac3fa-mac-snap-a1
