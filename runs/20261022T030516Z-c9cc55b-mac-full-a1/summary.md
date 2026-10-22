# WaveFeels mac CI: full

- result: success
- ref: full-check-2
- sha: c9cc55b854bd0b499b82c20ae854e54bf8d80e25
- run: 6 attempt 1
- app version: 0.0.6 (build 6)
- duration: 119 s

## Steps

| step | outcome | seconds | note |
|---|---|---|---|
| toolchain | success | 3 |  |
| adapter | success | 21 |  |
| build-release | success | 26 |  |
| build-tests | success | 24 |  |
| test | success | 40 |  |
| bundle | success | 0 |  |
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
- ref: full-check-2
- run: https://github.com/wFeeL/music-wave/actions/runs/39714723771
- results: runs/20261022T030516Z-c9cc55b-mac-full-a1
