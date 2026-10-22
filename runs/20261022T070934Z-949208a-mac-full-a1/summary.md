# WaveFeels mac CI: full

- result: success
- ref: full-check-5c
- sha: 949208a4bcc6c58290ad03597860d9a95ecbe244
- run: 27 attempt 1
- app version: 0.0.27 (build 27)
- duration: 184 s

## Steps

| step | outcome | seconds | note |
|---|---|---|---|
| toolchain | success | 5 |  |
| adapter | success | 25 |  |
| build-release | success | 43 |  |
| build-tests | success | 50 |  |
| test | success | 50 |  |
| bundle | success | 1 |  |
| sign | success | 1 |  |
| snapshots | success | 5 |  |
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
- ref: full-check-5c
- run: https://github.com/wFeeL/music-wave/actions/runs/39738223541
- results: runs/20261022T070934Z-949208a-mac-full-a1
