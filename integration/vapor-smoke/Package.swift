// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "vapor-smoke",
    platforms: [.macOS("27.0")],
    dependencies: [
        .package(name: "ServerFoundationModels", path: "../.."),
        .package(url: "https://github.com/vapor/vapor.git", from: "4.110.0"),
    ],
    targets: [
        .executableTarget(
            name: "VaporSmoke",
            dependencies: [
                .product(name: "ServerFoundationModels", package: "ServerFoundationModels"),
                .product(name: "ServerFoundationModelsUtilities", package: "ServerFoundationModels"),
                .product(name: "Vapor", package: "vapor"),
            ]
        )
    ]
)
