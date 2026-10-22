# WaveFeels mac CI: full

- result: success
- ref: full-check-7b
- sha: 47f9d6ec2b8a68902c1b183bed44bec4712f4346
- run: 35 attempt 1
- app version: 0.0.35 (build 35)
- duration: 344 s

## Steps

| step | outcome | seconds | note |
|---|---|---|---|
| toolchain | success | 5 |  |
| adapter | success | 45 |  |
| build-release | success | 64 |  |
| build-tests | success | 61 |  |
| test | success | 41 |  |
| bundle | success | 33 |  |
| sign | success | 1 |  |
| snapshots | success | 8 |  |
| smoke | success | 4 |  |
| cpu | success | 81 |  |
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
- ref: full-check-7b
- run: https://github.com/wFeeL/music-wave/actions/runs/39755759511
- results: runs/20261022T093452Z-47f9d6e-mac-full-a1
