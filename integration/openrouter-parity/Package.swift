// swift-tools-version: 6.2
// Standalone live-parity harness. Deliberately its OWN package (not part of
// the root manifest): euwars/OpenrouterForFoundationModels depends on
// ServerFoundationModels, so the root package can never depend on it without
// a cycle. Here the local checkout overrides that transitive dependency, so
// the harness always exercises the working tree — on macOS or Linux.
//
//   OPENROUTER_API_KEY=<key> swift run --package-path integration/openrouter-parity
import PackageDescription

let package = Package(
    name: "openrouter-parity",
    platforms: [
        .macOS("27.0"),
        .iOS("27.0"),
    ],
    dependencies: [
        // Identity matches the transitive dependency of the OpenRouter bridge;
        // a root-level path dependency overrides it with this working tree.
        .package(name: "ServerFoundationModels", path: "../.."),
        .package(
            url: "https://github.com/euwars/OpenrouterForFoundationModels.git",
            branch: "main",
            traits: ["ServerFoundationModels"]
        ),
    ],
    targets: [
        .executableTarget(
            name: "OpenRouterParitySmoke",
            dependencies: [
                .product(name: "ServerFoundationModels", package: "ServerFoundationModels"),
                .product(name: "OpenRouterForFoundationModels", package: "OpenrouterForFoundationModels"),
            ]
        )
    ]
)
