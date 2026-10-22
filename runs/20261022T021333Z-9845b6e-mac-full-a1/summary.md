# WaveFeels mac CI: full

- result: success
- ref: full-check-1b
- sha: 9845b6e07d5196f74f4949500091e5eaabcb104a
- run: 2 attempt 1
- app version: 0.0.2 (build 2)
- duration: 110 s

## Steps

| step | outcome | seconds | note |
|---|---|---|---|
| toolchain | success | 3 |  |
| adapter | skipped | - | scripts/build-adapter.sh not present |
| build-release | success | 27 |  |
| build-tests | success | 30 |  |
| test | success | 44 |  |
| bundle | success | 1 |  |
| sign | success | 1 |  |
| snapshots | skipped | - | app has no --render-snapshots yet |
| smoke | success | 4 |  |
| cpu | skipped | - | scripts/cpu-probe.sh not present |
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
- ref: full-check-1b
- run: https://github.com/wFeeL/music-wave/actions/runs/39710014330
- results: runs/20261022T021333Z-9845b6e-mac-full-a1
