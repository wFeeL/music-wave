# WaveFeels mac CI: full

- result: success
- ref: full-check-v1-10
- sha: 2a48693baf07a4953961be935e72382c09088726
- run: 45 attempt 1
- app version: 0.0.45 (build 45)
- duration: 334 s

## Steps

| step | outcome | seconds | note |
|---|---|---|---|
| toolchain | success | 4 |  |
| adapter | success | 38 |  |
| build-release | success | 68 |  |
| build-tests | success | 65 |  |
| test | success | 30 |  |
| bundle | success | 33 |  |
| sign | success | 1 |  |
| snapshots | success | 9 |  |
| smoke | success | 3 |  |
| cpu | success | 83 |  |
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
- ref: full-check-v1-10
- run: https://github.com/wFeeL/music-wave/actions/runs/39816994245
- results: runs/20261022T165330Z-2a48693-mac-full-a1
