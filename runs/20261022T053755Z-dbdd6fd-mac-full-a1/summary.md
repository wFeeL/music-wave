# WaveFeels mac CI: full

- result: success
- ref: full-check-3b
- sha: dbdd6fd4e838b8991546a7c4c58962e1c88f1736
- run: 18 attempt 1
- app version: 0.0.18 (build 18)
- duration: 141 s

## Steps

| step | outcome | seconds | note |
|---|---|---|---|
| toolchain | success | 3 |  |
| adapter | success | 21 |  |
| build-release | success | 32 |  |
| build-tests | success | 33 |  |
| test | success | 44 |  |
| bundle | success | 0 |  |
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
- ref: full-check-3b
- run: https://github.com/wFeeL/music-wave/actions/runs/39728894711
- results: runs/20261022T053755Z-dbdd6fd-mac-full-a1
