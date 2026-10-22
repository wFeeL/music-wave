# WaveFeels mac CI: full

- result: success
- ref: full-check-3d
- sha: 4df768f0bd358c29466d8d567c7dbf292d6ba26d
- run: 20 attempt 1
- app version: 0.0.20 (build 20)
- duration: 173 s

## Steps

| step | outcome | seconds | note |
|---|---|---|---|
| toolchain | success | 3 |  |
| adapter | success | 30 |  |
| build-release | success | 42 |  |
| build-tests | success | 41 |  |
| test | success | 49 |  |
| bundle | success | 1 |  |
| sign | success | 0 |  |
| snapshots | success | 4 |  |
| smoke | success | 3 |  |
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
- ref: full-check-3d
- run: https://github.com/wFeeL/music-wave/actions/runs/39730581594
- results: runs/20261022T055608Z-4df768f-mac-full-a1
