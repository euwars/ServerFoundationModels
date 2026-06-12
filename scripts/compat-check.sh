#!/bin/bash
# Reproducible third-party compatibility proof: clones real packages written
# against Apple's FoundationModels, swaps the import to LinuxFoundation, and
# runs their complete test suites.
#
# Usage: scripts/compat-check.sh [cache-dir]
set -euo pipefail

LF_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="${1:-/tmp/lf-compat}"
mkdir -p "$CACHE"

swap_imports() {
  local dir="$1"
  grep -rl 'import FoundationModels' "$dir"/Sources "$dir"/Tests "$dir"/Examples 2>/dev/null \
    | xargs sed -i '' \
      's/public import FoundationModels/public import LinuxFoundation/g; s/import FoundationModels/import LinuxFoundation/g' || true
  grep -rl 'FoundationModels::' "$dir"/Sources "$dir"/Tests 2>/dev/null \
    | xargs sed -i '' 's/FoundationModels::/LinuxFoundation::/g' || true
  grep -rl 'FoundationModels\.' "$dir"/Sources "$dir"/Tests 2>/dev/null \
    | xargs sed -i '' 's/FoundationModels\./LinuxFoundation./g' || true
  # repair over-matched module names
  grep -rl 'LinuxFoundationUtilities' "$dir" 2>/dev/null \
    | xargs sed -i '' 's/LinuxFoundationUtilities/FoundationModelsUtilities/g' || true
}

add_dependency() {
  local dir="$1" target="$2"
  python3 - "$dir/Package.swift" "$target" "$LF_ROOT" <<'PYEOF'
import re, sys
path, target, lf = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
if lf not in s:
    s = re.sub(r"(\n  targets: \[)", f'\n  dependencies: [\n    .package(path: "{lf}")\n  ],\\1', s, count=1)
    s = re.sub(
        rf'(name: "{target}",\n)(      dependencies: \[)([^\]]*)\]',
        rf'\1\2\3, .product(name: "LinuxFoundation", package: "LinuxFoundation")]',
        s, count=1) if f'name: "{target}",\n      dependencies: [' in s else re.sub(
        rf'(\.target\(\n      name: "{target}")',
        rf'\1,\n      dependencies: [.product(name: "LinuxFoundation", package: "LinuxFoundation")]',
        s, count=1)
open(path, 'w').write(s)
PYEOF
}

run() {
  local name="$1" url="$2" target="$3" filter="${4:-}"
  local dir="$CACHE/$name"
  rm -rf "$dir"
  git clone -q --depth 1 "$url" "$dir"
  rm -rf "$dir/.git"
  swap_imports "$dir"
  add_dependency "$dir" "$target"
  echo "=== $name: building + testing against LinuxFoundation"
  (cd "$dir" && swift test --build-system native ${filter:+--filter "$filter"} 2>&1 | tail -1)
}

run claude-for-foundation-models https://github.com/anthropics/ClaudeForFoundationModels \
  ClaudeForFoundationModels ClaudeForFoundationModelsTests
run foundation-models-utilities https://github.com/apple/foundation-models-utilities \
  FoundationModelsUtilities
echo "=== compat check complete"
