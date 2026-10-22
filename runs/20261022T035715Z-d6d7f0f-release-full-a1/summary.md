# WaveFeels mac CI: full

- result: success
- ref: v0.1.0-alpha.1
- sha: d6d7f0fa46029e59affd09c292268412a44b4c7f
- run: 1 attempt 1
- app version: 0.1.0 (build 1)
- duration: 122 s

## Steps

| step | outcome | seconds | note |
|---|---|---|---|
| toolchain | success | 2 |  |
| adapter | success | 20 |  |
| build-release | success | 28 |  |
| build-tests | success | 25 |  |
| test | success | 40 |  |
| bundle | success | 1 |  |
| sign | success | 1 |  |
| snapshots | skipped | - | app has no --render-snapshots yet |
| smoke | success | 4 |  |
| cpu | skipped | - | scripts/cpu-probe.sh not present |
| zip | success | 0 |  |
| bundle-update-test | success | 0 |  |
| sign-update-test | success | 1 |  |
| requirements | success | 0 |  |
| zip-update-test | success | 0 |  |

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
- ref: v0.1.0-alpha.1
- run: https://github.com/wFeeL/music-wave/actions/runs/39719461071
- results: runs/20261022T035715Z-d6d7f0f-release-full-a1
