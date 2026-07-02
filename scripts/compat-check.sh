#!/bin/bash
# Reproducible third-party compatibility proof: clones real packages written
# against Apple's FoundationModels, swaps the import to ServerFoundationModels, and
# runs their complete test suites.
#
# Usage: scripts/compat-check.sh [cache-dir]
#
# Requires macOS: both corpus packages declare Apple-only platforms and use
# Darwin Foundation API shapes (URLSession.bytes, URL optionality) that
# corelibs-foundation does not provide — their own suites cannot run on
# Linux regardless of which FoundationModels implementation they import.
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "compat-check requires macOS (corpus packages target Apple platforms only)" >&2
  exit 2
fi

LF_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="${1:-/tmp/lf-compat}"
mkdir -p "$CACHE"

# Pinned 2026-07-02 via `git ls-remote <repo> HEAD`
CLAUDE_FM_COMMIT=7559ecdf6315c5bc384c7b5a1a8976654d768c4f
FMU_COMMIT=a047a503b8ec79a76aa0e83d5a3bac54493cc7e5

sed_inplace() {
  local expr="$1" f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    sed -i.bak "$expr" "$f" && rm -f "$f.bak"
  done
}

swap_imports() {
  local dir="$1"
  grep -rl 'import FoundationModels' "$dir"/Sources "$dir"/Tests "$dir"/Examples 2>/dev/null \
    | sed_inplace 's/public import FoundationModels/public import ServerFoundationModels/g; s/import FoundationModels/import ServerFoundationModels/g' || true
  grep -rl 'FoundationModels::' "$dir"/Sources "$dir"/Tests 2>/dev/null \
    | sed_inplace 's/FoundationModels::/ServerFoundationModels::/g' || true
  grep -rl 'FoundationModels\.' "$dir"/Sources "$dir"/Tests 2>/dev/null \
    | sed_inplace 's/FoundationModels\./ServerFoundationModels./g' || true
  # repair over-matched module names
  grep -rl 'ServerFoundationModelsUtilities' "$dir" 2>/dev/null \
    | sed_inplace 's/ServerFoundationModelsUtilities/FoundationModelsUtilities/g' || true
}

add_dependency() {
  local dir="$1" target="$2"
  python3 - "$dir/Package.swift" "$target" "$LF_ROOT" <<'PYEOF'
import re, sys
path, target, lf = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
if lf not in s:
    s = re.sub(r"(\n  targets: \[)", f'\n  dependencies: [\n    .package(name: "ServerFoundationModels", path: "{lf}")\n  ],\\1', s, count=1)
    product = '.product(name: "ServerFoundationModels", package: "ServerFoundationModels")'
    def add_product(m):
        existing = m.group(3)
        # An empty dependency list must not gain a leading comma.
        joined = existing + ", " + product if existing.strip() else product
        return m.group(1) + m.group(2) + joined + "]"
    s = re.sub(
        rf'(name: "{target}",\n)(      dependencies: \[)([^\]]*)\]',
        add_product,
        s, count=1) if f'name: "{target}",\n      dependencies: [' in s else re.sub(
        rf'(\.target\(\n      name: "{target}")',
        rf'\1,\n      dependencies: [{product}]',
        s, count=1)
open(path, 'w').write(s)
PYEOF
}

run() {
  local name="$1" url="$2" commit="$3" target="$4" filter="${5:-}"
  local dir="$CACHE/$name"
  rm -rf "$dir"
  git clone -q "$url" "$dir"
  (cd "$dir" && git fetch --depth 1 origin "$commit" && git checkout "$commit")
  rm -rf "$dir/.git"
  swap_imports "$dir"
  add_dependency "$dir" "$target"
  echo "=== $name: building + testing against ServerFoundationModels"
  local log
  log=$(mktemp)
  if ! (cd "$dir" && swift test --build-system native ${filter:+--filter "$filter"} >"$log" 2>&1); then
    # Parallel-compile noise buries the diagnostic; print error context,
    # plus the tail for failures nothing greps as an error.
    echo "=== $name: FAILED (error context)" >&2
    grep -B3 -A10 -E "error:|: fatal" "$log" | head -120 >&2
    echo "=== $name: last 15 lines" >&2
    tail -15 "$log" >&2
    rm -f "$log"
    exit 1
  fi
  rm -f "$log"
}

run claude-for-foundation-models https://github.com/anthropics/ClaudeForFoundationModels \
  "$CLAUDE_FM_COMMIT" ClaudeForFoundationModels ClaudeForFoundationModelsTests
run foundation-models-utilities https://github.com/apple/foundation-models-utilities \
  "$FMU_COMMIT" FoundationModelsUtilities
echo "=== compat check complete"
