// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "hummingbird-smoke",
    platforms: [.macOS("27.0")],
    dependencies: [
        .package(name: "LinuxFoundation", path: "../.."),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "HummingbirdSmoke",
            dependencies: [
                .product(name: "LinuxFoundation", package: "LinuxFoundation"),
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
        )
    ]
)
