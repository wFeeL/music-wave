# WaveFeels mac CI: full

- result: success
- ref: full-check-v1-10b
- sha: fecd1b3b336b67078891db678806baa717a8fbba
- run: 46 attempt 1
- app version: 0.0.46 (build 46)
- duration: 330 s

## Steps

| step | outcome | seconds | note |
|---|---|---|---|
| toolchain | success | 5 |  |
| adapter | success | 38 |  |
| build-release | success | 64 |  |
| build-tests | success | 68 |  |
| test | success | 29 |  |
| bundle | success | 31 |  |
| sign | success | 2 |  |
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
- ref: full-check-v1-10b
- run: https://github.com/wFeeL/music-wave/actions/runs/39819802000
- results: runs/20261022T171223Z-fecd1b3-mac-full-a1
