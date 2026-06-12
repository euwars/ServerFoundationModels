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
        // NIO-based HTTP transport (connection pooling; avoids corelibs
        // URLSession concurrency bugs). Default-on: production servers
        // already carry NIO. Opt out for a dependency-light build with
        // `.package(..., traits: [])` — streaming then uses URLSession.
        .trait(name: "AsyncHTTPClient"),
        .default(enabledTraits: ["AsyncHTTPClient"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "600.0.0"..<"700.0.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.24.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
    ],
    targets: [
        .target(
            name: "ServerFoundationModels",
            dependencies: [
                "ServerFoundationModelsMacros",
                .product(name: "Logging", package: "swift-log"),
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
        // Macro expansion tests (assertMacroExpansion) for the @Generable /
        // @Guide / @SessionPropertyEntry implementations.
        .testTarget(
            name: "ServerFoundationModelsMacroTests",
            dependencies: [
                "ServerFoundationModelsMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
        // Subject: the same scenarios compiled against this package, running
        // against a local on-device open model (Ollama / any OpenAI-compatible server).
        .testTarget(
            name: "ServerFoundationModelsParityTests",
            dependencies: [
                "ServerFoundationModels",
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [.define("PARITY_SUBJECT_IS_SERVER_FOUNDATION_MODELS")]
        ),
    ]
)
