# WaveFeels mac CI: full

- result: success
- ref: full-check-6c
- sha: 17da405fb16f1fe83821b3a0f7c73a05be2afe52
- run: 33 attempt 1
- app version: 0.0.33 (build 33)
- duration: 314 s

## Steps

| step | outcome | seconds | note |
|---|---|---|---|
| toolchain | success | 5 |  |
| adapter | success | 33 |  |
| build-release | success | 52 |  |
| build-tests | success | 50 |  |
| test | success | 46 |  |
| bundle | success | 26 |  |
| sign | success | 1 |  |
| snapshots | success | 6 |  |
| smoke | success | 3 |  |
| cpu | success | 91 |  |
| zip | success | 1 |  |

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
- ref: full-check-6c
- run: https://github.com/wFeeL/music-wave/actions/runs/39748734141
- results: runs/20261022T083946Z-17da405-mac-full-a1
