# WaveFeels mac CI: snap

- result: success
- ref: snap-2
- sha: 2fd54270396817b90a8c8aea216d8de05e1c9af7
- run: 15 attempt 1
- app version: 0.0.15 (build 15)
- duration: 86 s

## Steps

| step | outcome | seconds | note |
|---|---|---|---|
| toolchain | success | 7 |  |
| build-release | success | 64 |  |
| bundle | success | 6 |  |
| sign | success | 1 |  |
| snapshots | success | 4 |  |
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
- ref: snap-2
- run: https://github.com/wFeeL/music-wave/actions/runs/39725380637
- results: runs/20261022T050018Z-2fd5427-mac-snap-a1
