// swift-tools-version: 6.2
import CompilerPluginSupport
import Foundation
import PackageDescription

let package = Package(
    name: "ServerFoundationModels",
    platforms: [
        .macOS("27.0"),
        .iOS("27.0"),
    ],
    products: [
        .library(name: "ServerFoundationModels", targets: ["ServerFoundationModels"]),
        .executable(name: "XAILiveProbe", targets: ["XAILiveProbe"]),
        .executable(name: "XAIServerToolsProbe", targets: ["XAIServerToolsProbe"]),
        .executable(name: "XAIDeepResearchProbe", targets: ["XAIDeepResearchProbe"]),
        .executable(name: "XAISubagentsProbe", targets: ["XAISubagentsProbe"]),
        .executable(name: "XAIRecursiveResearchProbe", targets: ["XAIRecursiveResearchProbe"]),
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
    targets: {
        var targets: [Target] = [
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
        ]
        // Macro expansion tests (assertMacroExpansion) for the @Generable /
        // @Guide / @SessionPropertyEntry implementations. Their
        // SwiftSyntaxMacrosTestSupport dependency needs XCTest, which the
        // macOS Command Line Tools SDK lacks — opt out on CLT-only machines
        // with SKIP_MACRO_TESTS=1 (CI always runs them).
        if ProcessInfo.processInfo.environment["SKIP_MACRO_TESTS"] != "1" {
            targets.append(.testTarget(
                name: "ServerFoundationModelsMacroTests",
                dependencies: [
                    "ServerFoundationModelsMacros",
                    .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
                ]
            ))
        }
        targets.append(contentsOf: [
        // Subject: the same scenarios compiled against this package, running
        // against a local on-device open model (Ollama / any OpenAI-compatible server).
        .executableTarget(
            name: "XAILiveProbe",
            dependencies: ["ServerFoundationModels"],
            path: "integration/xai-live-probe"
        ),
        .executableTarget(
            name: "XAIServerToolsProbe",
            dependencies: ["ServerFoundationModels"],
            path: "integration/xai-server-tools-probe"
        ),
        .executableTarget(
            name: "XAIDeepResearchProbe",
            dependencies: ["ServerFoundationModels"],
            path: "integration/xai-deep-research"
        ),
        .executableTarget(
            name: "XAISubagentsProbe",
            dependencies: ["ServerFoundationModels"],
            path: "integration/xai-subagents"
        ),
        .executableTarget(
            name: "XAIRecursiveResearchProbe",
            dependencies: ["ServerFoundationModels"],
            path: "integration/xai-recursive-research"
        ),
        .testTarget(
            name: "ServerFoundationModelsParityTests",
            dependencies: [
                "ServerFoundationModels",
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [.define("PARITY_SUBJECT_IS_SERVER_FOUNDATION_MODELS")]
        ),
        ])
        // Apple's FoundationModels macros are only available under Xcode; skip this
        // target on macOS CLI builds so `swift test` can run ServerFoundationModels tests.
        let includeAppleParity = ProcessInfo.processInfo.environment["INCLUDE_APPLE_PARITY_TESTS"] == "1"
            || ProcessInfo.processInfo.environment["XCODE_VERSION_ACTUAL"] != nil
        if includeAppleParity {
            targets.append(.testTarget(name: "AppleFoundationModelsParityTests"))
        }
        return targets
    }()
)
