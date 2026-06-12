// swift-tools-version: 6.2
import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "ServerFoundationModels",
    platforms: [
        .macOS("27.0"),
        .iOS("27.0"),
    ],
    products: [
        .library(name: "ServerFoundationModels", targets: ["ServerFoundationModels"])
    ],
    traits: [
        // NIO-based HTTP transport for production Linux streaming
        // (connection pooling; avoids corelibs URLSession concurrency bugs).
        .trait(name: "AsyncHTTPClient"),
        .default(enabledTraits: []),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "600.0.0"..<"700.0.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.24.0"),
    ],
    targets: [
        .target(
            name: "ServerFoundationModels",
            dependencies: [
                "ServerFoundationModelsMacros",
                .product(
                    name: "AsyncHTTPClient",
                    package: "async-http-client",
                    condition: .when(traits: ["AsyncHTTPClient"])
                ),
            ]
        ),
        .macro(
            name: "ServerFoundationModelsMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        // Oracle: the same scenarios compiled against Apple's FoundationModels,
        // running against the local on-device model. No dependency on our module,
        // so `canImport(ServerFoundationModels)` is false in this target.
        .testTarget(
            name: "AppleFoundationModelsParityTests"
        ),
        // Subject: the same scenarios compiled against this package, running
        // against a local on-device open model (Ollama / any OpenAI-compatible server).
        .testTarget(
            name: "ServerFoundationModelsParityTests",
            dependencies: ["ServerFoundationModels"],
            swiftSettings: [.define("PARITY_SUBJECT_IS_SERVER_FOUNDATION_MODELS")]
        ),
    ]
)
