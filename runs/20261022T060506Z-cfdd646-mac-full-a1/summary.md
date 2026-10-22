# WaveFeels mac CI: full

- result: success
- ref: full-check-3e
- sha: cfdd6468757d29f07a303047a8491cae6138b2ff
- run: 21 attempt 1
- app version: 0.0.21 (build 21)
- duration: 158 s

## Steps

| step | outcome | seconds | note |
|---|---|---|---|
| toolchain | success | 3 |  |
| adapter | success | 26 |  |
| build-release | success | 38 |  |
| build-tests | success | 39 |  |
| test | success | 43 |  |
| bundle | success | 1 |  |
| sign | success | 1 |  |
| snapshots | success | 3 |  |
| smoke | success | 3 |  |
| cpu | skipped | - | scripts/cpu-probe.sh not present |
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
- ref: full-check-3e
- run: https://github.com/wFeeL/music-wave/actions/runs/39731481531
- results: runs/20261022T060506Z-cfdd646-mac-full-a1
