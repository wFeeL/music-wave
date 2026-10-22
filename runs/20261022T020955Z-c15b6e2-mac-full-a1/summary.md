# WaveFeels mac CI: full

- result: failure
- ref: full-check-1
- sha: c15b6e255f17d96ea256b526cc6cc0a17f7557ec
- run: 1 attempt 1
- app version: 0.0.1 (build 1)
- duration: 56 s

## Steps

| step | outcome | seconds | note |
|---|---|---|---|
| toolchain | success | 4 |  |
| adapter | skipped | - | scripts/build-adapter.sh not present |
| build-release | failure | 31 | exit 1 |
| build-tests | failure | 21 | exit 1 |
| test | skipped | - | test build failed |
| bundle | skipped | - | release build failed |
| sign | skipped | - | release build failed |
| snapshots | skipped | - | release build failed |
| smoke | skipped | - | release build failed |
| cpu | skipped | - | no signed app |
| zip | skipped | - | no signed app |

## Toolchain

```
swift-driver version: 1.148.6 Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)
Target: arm64-apple-macosx26.0
Xcode 26.6
Build version 17F113
```

## Errors and warnings (first 40, full list in errors.txt)

```
/Users/runner/work/music-wave/music-wave/Sources/WaveCore/NotchGeometry.swift:103:76: error: value of type 'CGRect' has no member 'maxY'
/Users/runner/work/music-wave/music-wave/Sources/WaveCore/NotchGeometry.swift:109:40: error: value of type 'CGRect' has no member 'width'
/Users/runner/work/music-wave/music-wave/Sources/WaveCore/NotchGeometry.swift:110:25: error: the compiler is unable to type-check this expression in reasonable time; try breaking up the expression into distinct sub-expressions
/Users/runner/work/music-wave/music-wave/Sources/WaveCore/NotchGeometry.swift:119:67: error: value of type 'CGRect' has no member 'maxY'
/Users/runner/work/music-wave/music-wave/Sources/WaveCore/NotchGeometry.swift:124:15: error: argument passed to call that takes no arguments
/Users/runner/work/music-wave/music-wave/Sources/WaveCore/NotchGeometry.swift:124:25: error: value of type 'CGRect' has no member 'midX'
/Users/runner/work/music-wave/music-wave/Sources/WaveCore/NotchGeometry.swift:30:15: error: type 'NotchLayout' does not conform to protocol 'Equatable'
/Users/runner/work/music-wave/music-wave/Sources/WaveCore/NotchGeometry.swift:4:15: error: type 'ScreenDescriptor' does not conform to protocol 'Equatable'
/Users/runner/work/music-wave/music-wave/Sources/WaveCore/NotchGeometry.swift:47:22: error: argument passed to call that takes no arguments
/Users/runner/work/music-wave/music-wave/Sources/WaveCore/NotchGeometry.swift:48:22: error: value of type 'CGRect' has no member 'minX'
/Users/runner/work/music-wave/music-wave/Sources/WaveCore/NotchGeometry.swift:48:44: error: value of type 'CGRect' has no member 'minY'
/Users/runner/work/music-wave/music-wave/Sources/WaveCore/NotchGeometry.swift:49:26: error: value of type 'CGRect' has no member 'width'
/Users/runner/work/music-wave/music-wave/Sources/WaveCore/NotchGeometry.swift:49:58: error: value of type 'CGRect' has no member 'height'
/Users/runner/work/music-wave/music-wave/Sources/WaveCore/NotchGeometry.swift:56:22: error: argument passed to call that takes no arguments
/Users/runner/work/music-wave/music-wave/Sources/WaveCore/NotchGeometry.swift:57:22: error: value of type 'CGRect' has no member 'midX'
/Users/runner/work/music-wave/music-wave/Sources/WaveCore/NotchGeometry.swift:57:54: error: value of type 'CGRect' has no member 'maxY'
/Users/runner/work/music-wave/music-wave/Sources/WaveCore/NotchGeometry.swift:65:36: error: value of type 'CGRect' has no member 'union'
/Users/runner/work/music-wave/music-wave/Sources/WaveCore/NotchGeometry.swift:66:48: error: value of type 'CGRect' has no member 'minX'
/Users/runner/work/music-wave/music-wave/Sources/WaveCore/NotchGeometry.swift:67:48: error: value of type 'CGRect' has no member 'maxX'
/Users/runner/work/music-wave/music-wave/Sources/WaveCore/NotchGeometry.swift:68:22: error: argument passed to call that takes no arguments
/Users/runner/work/music-wave/music-wave/Sources/WaveCore/NotchGeometry.swift:80:35: error: value of type 'CGRect' has no member 'maxY'
/Users/runner/work/music-wave/music-wave/Sources/WaveCore/NotchGeometry.swift:80:46: error: value of type 'CGRect' has no member 'maxY'
/Users/runner/work/music-wave/music-wave/Sources/WaveCore/NotchGeometry.swift:81:22: error: argument passed to call that takes no arguments
/Users/runner/work/music-wave/music-wave/Sources/WaveCore/NotchGeometry.swift:81:31: error: value of type 'CGRect' has no member 'minX'
/Users/runner/work/music-wave/music-wave/Sources/WaveCore/NotchGeometry.swift:81:45: error: value of type 'CGRect' has no member 'minY'
/Users/runner/work/music-wave/music-wave/Sources/WaveCore/NotchGeometry.swift:81:63: error: value of type 'CGRect' has no member 'width'
/Users/runner/work/music-wave/music-wave/Sources/WaveCore/NotchGeometry.swift:81:89: error: value of type 'CGRect' has no member 'minY'
```

## Workflow

- ci step outcome: failure
- ref: full-check-1
- run: https://github.com/wFeeL/music-wave/actions/runs/39709754910
- results: runs/20261022T020955Z-c15b6e2-mac-full-a1
