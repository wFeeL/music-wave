# WaveFeels mac CI: snap

- result: success
- ref: snap-v1-10c
- sha: f8d42337091870fb604633229164ee3706dc27f8
- run: 47 attempt 1
- app version: 0.0.47 (build 47)
- duration: 79 s

## Steps

| step | outcome | seconds | note |
|---|---|---|---|
| toolchain | success | 3 |  |
| build-release | success | 45 |  |
| bundle | success | 21 |  |
| sign | success | 0 |  |
| snapshots | success | 6 |  |
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
- ref: snap-v1-10c
- run: https://github.com/wFeeL/music-wave/actions/runs/39821247402
- results: runs/20261022T171821Z-f8d4233-mac-snap-a1
