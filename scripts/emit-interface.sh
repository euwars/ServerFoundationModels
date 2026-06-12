#!/bin/bash
# Emits ServerFoundationModels.swiftinterface for the interface diff.
#
# Library evolution must apply ONLY to our target: passing
# `-Xswiftc -enable-library-evolution` globally breaks dependencies
# (swift-log, swift-nio) that do not build resiliently. SwiftPM has no
# CLI for per-target flags, so this temporarily patches the manifest,
# builds, and restores it.
#
# Usage: scripts/emit-interface.sh [out-file] [scratch-dir]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-/tmp/ServerFoundationModels.swiftinterface}"
SCRATCH="${2:-/tmp/sfm-interface-scratch}"

# Restore the manifest byte-for-byte (NOT via git: that would clobber any
# uncommitted edits the working tree had before we patched it).
BACKUP="$(mktemp)"
cp "$ROOT/Package.swift" "$BACKUP"
cleanup() { cp "$BACKUP" "$ROOT/Package.swift"; rm -f "$BACKUP"; }
trap cleanup EXIT

python3 - "$ROOT/Package.swift" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
# swiftSettings must follow dependencies in .target's argument order.
needle = """                ),
            ]
        ),
        .macro("""
flags = """                ),
            ],
            swiftSettings: [.unsafeFlags([
                "-enable-library-evolution",
                "-emit-module-interface",
                "-no-verify-emitted-module-interface",
            ])]
        ),
        .macro("""
assert needle in text, "target spelling changed; update emit-interface.sh"
open(path, "w").write(text.replace(needle, flags, 1))
PY

swift build --scratch-path "$SCRATCH" --target ServerFoundationModels >&2

IFACE="$(find "$SCRATCH" -name 'ServerFoundationModels.swiftinterface' | head -1)"
[ -n "$IFACE" ] || { echo "no interface emitted" >&2; exit 1; }
cp "$IFACE" "$OUT"
echo "$OUT"
