# WaveFeels mac CI: full

- result: success
- ref: v0.9.0-beta.1
- sha: 2205ee21c4776751158060d6bda0dd8cb22d61ba
- run: 2 attempt 1
- app version: 0.9.0 (build 2)
- duration: 278 s

## Steps

| step | outcome | seconds | note |
|---|---|---|---|
| toolchain | success | 3 |  |
| adapter | success | 23 |  |
| build-release | success | 51 |  |
| build-tests | success | 42 |  |
| test | success | 45 |  |
| bundle | success | 23 |  |
| sign | success | 1 |  |
| snapshots | success | 4 |  |
| smoke | success | 3 |  |
| cpu | success | 81 |  |
| zip | success | 0 |  |
| bundle-update-test | success | 1 |  |
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
- ref: v0.9.0-beta.1
- run: https://github.com/wFeeL/music-wave/actions/runs/39756709236
- results: runs/20261022T094108Z-2205ee2-release-full-a1
