// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WaveFeels",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "WaveCore", targets: ["WaveCore"]),
    ],
    targets: [
        .target(name: "WaveCore"),
        .testTarget(name: "WaveCoreTests", dependencies: ["WaveCore"]),
    ]
)

#if os(macOS)
// Таргеты WaveFeels и WaveFeelsTests добавляются в задаче 12.
#endif
