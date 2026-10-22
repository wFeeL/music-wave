# WaveFeels mac CI: snap

- result: success
- ref: snap-5
- sha: d605d00c57898e55f7393490d68e783b75dd0fdc
- run: 29 attempt 1
- app version: 0.0.29 (build 29)
- duration: 114 s

## Steps

| step | outcome | seconds | note |
|---|---|---|---|
| toolchain | success | 5 |  |
| build-release | success | 64 |  |
| bundle | success | 30 |  |
| sign | success | 1 |  |
| snapshots | success | 11 |  |
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
- ref: snap-5
- run: https://github.com/wFeeL/music-wave/actions/runs/39741964036
- results: runs/20261022T074106Z-d605d00-mac-snap-a1
