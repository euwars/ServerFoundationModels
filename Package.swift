// swift-tools-version: 6.2
import CompilerPluginSupport
import Foundation
import PackageDescription

/// Swift 6 language mode and complete strict-concurrency checking for all targets.
let concurrencySettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableExperimentalFeature("StrictConcurrency=complete"),
]

let package = Package(
    name: "ServerFoundationModels",
    platforms: [
        .macOS("27.0"),
        .iOS("27.0"),
    ],
    products: [
        .library(name: "ServerFoundationModels", targets: ["ServerFoundationModels"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "600.0.0"..<"700.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
    ],
    targets: {
        var targets: [Target] = [
        .target(
            name: "ServerFoundationModels",
            dependencies: [
                "ServerFoundationModelsMacros",
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: concurrencySettings
        ),
        .macro(
            name: "ServerFoundationModelsMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ],
            swiftSettings: concurrencySettings
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
                    // Xcode 27 beta 4's swiftbuild backend does not propagate a
                    // macro target's own swift-syntax dependencies to the test
                    // bundle's link line — list them explicitly.
                    .product(name: "SwiftSyntax", package: "swift-syntax"),
                    .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                    .product(name: "SwiftParser", package: "swift-syntax"),
                    .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                ],
                swiftSettings: concurrencySettings
            ))
        }
        targets.append(.testTarget(
            name: "ServerFoundationModelsParityTests",
            dependencies: [
                "ServerFoundationModels",
                .product(name: "Logging", package: "swift-log"),
                // Same swiftbuild-backend workaround as above.
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
            ],
            swiftSettings: concurrencySettings + [.define("PARITY_SUBJECT_IS_SERVER_FOUNDATION_MODELS")]
        ))
        // Apple's FoundationModels macros are only available under Xcode; skip this
        // target on macOS CLI builds so `swift test` can run ServerFoundationModels tests.
        let includeAppleParity = ProcessInfo.processInfo.environment["INCLUDE_APPLE_PARITY_TESTS"] == "1"
            || ProcessInfo.processInfo.environment["XCODE_VERSION_ACTUAL"] != nil
        if includeAppleParity {
            targets.append(.testTarget(
                name: "AppleFoundationModelsParityTests",
                swiftSettings: concurrencySettings
            ))
        }
        return targets
    }()
)
