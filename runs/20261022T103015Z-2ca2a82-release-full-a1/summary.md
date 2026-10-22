# WaveFeels mac CI: full

- result: success
- ref: v0.9.0
- sha: 2ca2a8245809da588ab68e29bb7e490fdbada98f
- run: 4 attempt 1
- app version: 0.9.0 (build 4)
- duration: 321 s

## Steps

| step | outcome | seconds | note |
|---|---|---|---|
| toolchain | success | 5 |  |
| adapter | success | 41 |  |
| build-release | success | 56 |  |
| build-tests | success | 58 |  |
| test | success | 43 |  |
| bundle | success | 25 |  |
| sign | success | 1 |  |
| snapshots | success | 4 |  |
| smoke | success | 3 |  |
| cpu | success | 82 |  |
| zip | success | 0 |  |
| bundle-update-test | success | 2 |  |
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
- release step outcome: success
- ref: v0.9.0
- run: https://github.com/wFeeL/music-wave/actions/runs/39762882814
- results: runs/20261022T103015Z-2ca2a82-release-full-a1
