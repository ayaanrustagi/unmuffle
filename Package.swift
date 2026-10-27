// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Unmuffle",
    platforms: [
        // Core Audio process taps (system-wide audio capture) arrived in macOS 14.2.
        .macOS("14.2"),
    ],
    products: [
        .executable(name: "Unmuffle", targets: ["Unmuffle"]),
        .executable(name: "unmuffle-cli", targets: ["unmuffle-cli"]),
        .library(name: "UnmuffleDSP", targets: ["UnmuffleDSP"]),
    ],
    targets: [
        // Pure Swift signal processing. No Apple-only frameworks, so it builds and
        // tests on Linux too.
        .target(name: "UnmuffleDSP"),

        // The menu bar app. macOS only; on other platforms it compiles to a stub.
        .executableTarget(name: "Unmuffle", dependencies: ["UnmuffleDSP"]),

        // Offline processor for WAV files, handy for testing and for fixing downloads.
        .executableTarget(name: "unmuffle-cli", dependencies: ["UnmuffleDSP"]),

        .testTarget(name: "UnmuffleDSPTests", dependencies: ["UnmuffleDSP"]),
    ]
)
