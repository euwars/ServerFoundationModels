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
# macOS: Xcode 26.5+ / 27 betas). On unlisted toolchains — including the
# Xcode 27.0 GM (swiftlang-6.4.0.34.1) until Swift.org publishes its manifest
# — SwiftPM silently falls back to building swift-syntax from source and this
# script fails. Check https://download.swift.org/?list-type=2&prefix=prebuilts/swift-syntax/
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
# Verbose so the log records SwiftPM's prebuilt manifest lookup; kept out of
# the terminal, shown on failure.
if ! swift build -v > build.log 2>&1; then
    tail -40 build.log >&2
    echo "FAIL: consumer build failed" >&2
    exit 1
fi

# SwiftPM creates the prebuilts directory before it knows whether a manifest
# exists for this toolchain, so the directory alone proves nothing: require a
# downloaded manifest and no source-build artifacts. (The swiftbuild backend,
# the default since Xcode 27, does not print "Compiling SwiftSyntax", so a
# log grep alone would pass a from-source build.)
if grep -qE "Prebuilt .*badResponseStatusCode|Failed to decode prebuilt manifest" build.log; then
    echo "FAIL: no prebuilt swift-syntax manifest is published for this toolchain ($(swift --version 2>&1 | head -1))" >&2
    exit 1
fi
if ! ls .build/prebuilts/swift-syntax/*/*.json >/dev/null 2>&1; then
    echo "FAIL: no prebuilt manifest under .build/prebuilts/swift-syntax — prebuilt was not downloaded" >&2
    exit 1
fi
if grep -q "Compiling SwiftSyntax" build.log \
    || [ -n "$(find .build -path '*/prebuilts/*' -prune -o \( -name 'SwiftSyntax.build' -o -name 'SwiftSyntax-t.build' \) -print | head -1)" ]; then
    echo "FAIL: swift-syntax was compiled from source" >&2
    exit 1
fi
echo "OK: consumer build used prebuilt swift-syntax"
