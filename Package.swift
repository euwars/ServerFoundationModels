// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OpenFoundationModels",
    platforms: [
        .macOS("27.0"),
        .iOS("27.0"),
    ],
    products: [
        .library(name: "OpenFoundationModels", targets: ["OpenFoundationModels"])
    ],
    targets: [
        .target(
            name: "OpenFoundationModels"
        ),
        // Oracle: the same scenarios compiled against Apple's FoundationModels,
        // running against the local on-device model. No dependency on our module,
        // so `canImport(OpenFoundationModels)` is false in this target.
        .testTarget(
            name: "AppleFoundationModelsParityTests"
        ),
        // Subject: the same scenarios compiled against this package, running
        // against a local open model (Ollama / any OpenAI-compatible server).
        .testTarget(
            name: "OpenFoundationModelsParityTests",
            dependencies: ["OpenFoundationModels"],
            swiftSettings: [.define("PARITY_SUBJECT_IS_OPEN_FOUNDATION_MODELS")]
        ),
    ]
)
