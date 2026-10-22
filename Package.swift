// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WaveFeels",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "WaveCore", targets: ["WaveCore"]),
        .executable(name: "wave-eval", targets: ["wave-eval"]),
    ],
    targets: [
        .target(name: "WaveCore"),
        // Офлайн-оценка попадания вспышек в долю на записанной музыке; собирается и на Linux.
        .executableTarget(name: "wave-eval", dependencies: ["WaveCore"]),
        .testTarget(name: "WaveCoreTests", dependencies: ["WaveCore"]),
    ]
)

#if os(macOS)
// Приложение и его тесты собираются только на macOS; на Linux виден один WaveCore.
package.targets += [
    .executableTarget(
        name: "WaveFeels",
        dependencies: ["WaveCore"],
        linkerSettings: [
            .linkedFramework("CoreAudio"),
            .linkedFramework("AudioToolbox"),
            .linkedFramework("AVFoundation"),
            .linkedFramework("ServiceManagement"),
        ]
    ),
    .testTarget(name: "WaveFeelsTests", dependencies: ["WaveFeels", "WaveCore"]),
]
#endif
