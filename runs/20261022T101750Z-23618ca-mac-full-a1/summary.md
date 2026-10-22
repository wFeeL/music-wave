# WaveFeels mac CI: full

- result: success
- ref: full-check-8b
- sha: 23618ca5f43e5defa41ed7f2c4d066d94a38db6a
- run: 37 attempt 1
- app version: 0.0.37 (build 37)
- duration: 318 s

## Steps

| step | outcome | seconds | note |
|---|---|---|---|
| toolchain | success | 4 |  |
| adapter | success | 30 |  |
| build-release | success | 60 |  |
| build-tests | success | 64 |  |
| test | success | 37 |  |
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
- ref: full-check-8b
- run: https://github.com/wFeeL/music-wave/actions/runs/39761334019
- results: runs/20261022T101750Z-23618ca-mac-full-a1
