#!/usr/bin/env bash
# Proves a downstream consumer of this package never compiles swift-syntax
# from source: SwiftPM must satisfy the macro target with a Swift.org prebuilt
# (on by default since Swift 6.2; manifests exist per exact toolchain version).
#
# Two properties keep this true, and this script guards both:
#   1. The swift-syntax range resolves to a version with published prebuilts
#      (https://download.swift.org/prebuilts/swift-syntax/<version>/).
#   2. Only the .macro target depends on swift-syntax products — a swift-syntax
#      product on the library target would disable prebuilts for consumers.
#
# Run on a toolchain with published prebuilt manifests (Linux: swift:6.3.2;
# macOS: Xcode 26.5+ / 27 beta). On unlisted toolchains SwiftPM silently
# falls back to building swift-syntax from source and this script fails.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# A path dependency's package identity is its directory basename, which need
# not be "ServerFoundationModels" (e.g. a container mount at /src).
PKG_ID="$(basename "$REPO_DIR")"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/consumer/Sources/Consumer"
cat > "$WORK_DIR/consumer/Package.swift" <<EOF
// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "Consumer",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    dependencies: [.package(path: "$REPO_DIR")],
    targets: [
        .executableTarget(
            name: "Consumer",
            dependencies: [.product(name: "ServerFoundationModels", package: "$PKG_ID")]
        ),
    ]
)
EOF
# @Generable forces macro expansion, so the prebuilt plugin actually executes.
cat > "$WORK_DIR/consumer/Sources/Consumer/main.swift" <<'EOF'
import ServerFoundationModels

@Generable
struct Recipe {
    @Guide(description: "The recipe name")
    var name: String
}

print("consumer built ok")
EOF

cd "$WORK_DIR/consumer"
swift build 2>&1 | tee build.log

if [ ! -d .build/prebuilts/swift-syntax ]; then
    echo "FAIL: no .build/prebuilts/swift-syntax — prebuilt was not downloaded" >&2
    exit 1
fi
if grep -q "Compiling SwiftSyntax" build.log; then
    echo "FAIL: swift-syntax was compiled from source" >&2
    exit 1
fi
echo "OK: consumer build used prebuilt swift-syntax"
