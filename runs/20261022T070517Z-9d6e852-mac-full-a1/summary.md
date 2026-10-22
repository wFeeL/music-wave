# WaveFeels mac CI: full

- result: failure
- ref: full-check-5b
- sha: 9d6e852defab6e4b6a5fc483fb9dab7401b58107
- run: 26 attempt 1
- app version: 0.0.26 (build 26)
- duration: 109 s

## Steps

| step | outcome | seconds | note |
|---|---|---|---|
| toolchain | success | 5 |  |
| adapter | success | 29 |  |
| build-release | failure | 38 | exit 1 |
| build-tests | failure | 37 | exit 1 |
| test | skipped | - | test build failed |
| bundle | skipped | - | release build failed |
| sign | skipped | - | release build failed |
| snapshots | skipped | - | release build failed |
| smoke | skipped | - | release build failed |
| cpu | skipped | - | no signed app |
| zip | skipped | - | no signed app |

## Toolchain

```
swift-driver version: 1.148.6 Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)
Target: arm64-apple-macosx26.0
Xcode 26.6
Build version 17F113
```

## Errors and warnings (first 40, full list in errors.txt)

```
/Users/runner/work/music-wave/music-wave/Sources/WaveFeels/App/WaveFeelsApp.swift:50:22: error: value of type 'AppDelegate' has no member 'showSettings'
```

## Workflow

- ci step outcome: failure
- ref: full-check-5b
- run: https://github.com/wFeeL/music-wave/actions/runs/39737878448
- results: runs/20261022T070517Z-9d6e852-mac-full-a1
