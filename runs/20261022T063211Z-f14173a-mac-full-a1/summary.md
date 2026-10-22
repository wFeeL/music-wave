# WaveFeels mac CI: full

- result: success
- ref: full-check-4b
- sha: f14173a7dec5255493e73e0e67ee5ae1b19bc9a7
- run: 23 attempt 1
- app version: 0.0.23 (build 23)
- duration: 223 s

## Steps

| step | outcome | seconds | note |
|---|---|---|---|
| toolchain | success | 4 |  |
| adapter | success | 31 |  |
| build-release | success | 47 |  |
| build-tests | success | 60 |  |
| test | success | 68 |  |
| bundle | success | 1 |  |
| sign | success | 1 |  |
| snapshots | success | 7 |  |
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
- ref: full-check-4b
- run: https://github.com/wFeeL/music-wave/actions/runs/39734136427
- results: runs/20261022T063211Z-f14173a-mac-full-a1
