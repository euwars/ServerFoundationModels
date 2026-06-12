// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LinuxFoundation",
    platforms: [
        .macOS("27.0"),
        .iOS("27.0"),
    ],
    products: [
        .library(name: "LinuxFoundation", targets: ["LinuxFoundation"])
    ],
    targets: [
        .target(
            name: "LinuxFoundation"
        ),
        // Oracle: the same scenarios compiled against Apple's FoundationModels,
        // running against the local on-device model. No dependency on our module,
        // so `canImport(LinuxFoundation)` is false in this target.
        .testTarget(
            name: "AppleFoundationModelsParityTests"
        ),
        // Subject: the same scenarios compiled against this package, running
        // against a local on-device open model (Ollama / any OpenAI-compatible server).
        .testTarget(
            name: "LinuxFoundationParityTests",
            dependencies: ["LinuxFoundation"],
            swiftSettings: [.define("PARITY_SUBJECT_IS_LINUX_FOUNDATION")]
        ),
    ]
)
