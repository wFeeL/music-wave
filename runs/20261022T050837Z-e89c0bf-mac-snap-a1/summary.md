# WaveFeels mac CI: snap

- result: success
- ref: snap-3
- sha: e89c0bfad45b1663ab39a32a59dd33cff428a557
- run: 16 attempt 1
- app version: 0.0.16 (build 16)
- duration: 61 s

## Steps

| step | outcome | seconds | note |
|---|---|---|---|
| toolchain | success | 3 |  |
| build-release | success | 47 |  |
| bundle | success | 4 |  |
| sign | success | 1 |  |
| snapshots | success | 3 |  |
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
- ref: snap-3
- run: https://github.com/wFeeL/music-wave/actions/runs/39726223420
- results: runs/20261022T050837Z-e89c0bf-mac-snap-a1
