# WaveFeels mac CI: full

- result: failure
- ref: full-check-8
- sha: 999fa5897453f8f31550aa3e221c31b8bee534e5
- run: 36 attempt 1
- app version: 0.0.36 (build 36)
- duration: 262 s

## Steps

| step | outcome | seconds | note |
|---|---|---|---|
| toolchain | success | 5 |  |
| adapter | success | 39 |  |
| build-release | success | 47 |  |
| build-tests | failure | 47 | exit 1 |
| test | skipped | - | test build failed |
| bundle | success | 28 |  |
| sign | success | 1 |  |
| snapshots | success | 9 |  |
| smoke | success | 4 |  |
| cpu | success | 81 |  |
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
/Users/runner/work/music-wave/music-wave/Tests/WaveFeelsTests/AppModelIslandTests.swift:18:23: error: cannot find type 'IslandState' in scope
/Users/runner/work/music-wave/music-wave/Tests/WaveFeelsTests/AppModelIslandTests.swift:31:30: error: reference to member 'collapsed' cannot be resolved without a contextual type
/Users/runner/work/music-wave/music-wave/Tests/WaveFeelsTests/AppModelIslandTests.swift:31:42: error: reference to member 'expanded' cannot be resolved without a contextual type
/Users/runner/work/music-wave/music-wave/Tests/WaveFeelsTests/AppModelIslandTests.swift:31:53: error: reference to member 'collapsed' cannot be resolved without a contextual type
```

## Workflow

- ci step outcome: failure
- ref: full-check-8
- run: https://github.com/wFeeL/music-wave/actions/runs/39760653969
- results: runs/20261022T101131Z-999fa58-mac-full-a1
