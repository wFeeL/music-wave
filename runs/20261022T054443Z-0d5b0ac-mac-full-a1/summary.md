# WaveFeels mac CI: full

- result: success
- ref: full-check-3c
- sha: 0d5b0aca6e0749e84570423fc32afbed4d45bec0
- run: 19 attempt 1
- app version: 0.0.19 (build 19)
- duration: 162 s

## Steps

| step | outcome | seconds | note |
|---|---|---|---|
| toolchain | success | 3 |  |
| adapter | success | 19 |  |
| build-release | success | 36 |  |
| build-tests | success | 47 |  |
| test | success | 49 |  |
| bundle | success | 0 |  |
| sign | success | 1 |  |
| snapshots | success | 3 |  |
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
- ref: full-check-3c
- run: https://github.com/wFeeL/music-wave/actions/runs/39729500956
- results: runs/20261022T054443Z-0d5b0ac-mac-full-a1
