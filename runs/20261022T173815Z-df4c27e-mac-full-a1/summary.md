# WaveFeels mac CI: full

- result: success
- ref: full-check-v1-11
- sha: df4c27e9290842dad127791d7e9751ae1c23ef78
- run: 48 attempt 1
- app version: 0.0.48 (build 48)
- duration: 309 s

## Steps

| step | outcome | seconds | note |
|---|---|---|---|
| toolchain | success | 3 |  |
| adapter | success | 32 |  |
| build-release | success | 59 |  |
| build-tests | success | 59 |  |
| test | success | 31 |  |
| bundle | success | 29 |  |
| sign | success | 1 |  |
| snapshots | success | 9 |  |
| smoke | success | 3 |  |
| cpu | success | 83 |  |
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
- ref: full-check-v1-11
- run: https://github.com/wFeeL/music-wave/actions/runs/39823659527
- results: runs/20261022T173815Z-df4c27e-mac-full-a1
