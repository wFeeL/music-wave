# WaveFeels mac CI: full

- result: success
- ref: full-check-3
- sha: 0ededb5a5ed680727155b7ede56b920e273a2b4a
- run: 17 attempt 1
- app version: 0.0.17 (build 17)
- duration: 236 s

## Steps

| step | outcome | seconds | note |
|---|---|---|---|
| toolchain | success | 6 |  |
| adapter | success | 40 |  |
| build-release | success | 57 |  |
| build-tests | success | 58 |  |
| test | success | 64 |  |
| bundle | success | 1 |  |
| sign | success | 1 |  |
| snapshots | success | 5 |  |
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
- ref: full-check-3
- run: https://github.com/wFeeL/music-wave/actions/runs/39728178485
- results: runs/20261022T053205Z-0ededb5-mac-full-a1
