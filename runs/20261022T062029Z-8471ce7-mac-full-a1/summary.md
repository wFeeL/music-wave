# WaveFeels mac CI: full

- result: success
- ref: full-check-4a
- sha: 8471ce755f51a9898fa9c9676fc3b143c93f6ab7
- run: 22 attempt 1
- app version: 0.0.22 (build 22)
- duration: 187 s

## Steps

| step | outcome | seconds | note |
|---|---|---|---|
| toolchain | success | 4 |  |
| adapter | success | 23 |  |
| build-release | success | 50 |  |
| build-tests | success | 49 |  |
| test | success | 51 |  |
| bundle | success | 0 |  |
| sign | success | 2 |  |
| snapshots | success | 4 |  |
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
- ref: full-check-4a
- run: https://github.com/wFeeL/music-wave/actions/runs/39733004496
- results: runs/20261022T062029Z-8471ce7-mac-full-a1
