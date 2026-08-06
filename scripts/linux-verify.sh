#!/usr/bin/env bash
# Linux compatibility verification for ServerFoundationModels (core library).
# Intended to run inside the official swift:6.2 container (or native Linux).
#
# Usage (from repo root):
#   bash scripts/linux-verify.sh
#   LINUX_VERIFY_QUICK=1 bash scripts/linux-verify.sh
#   SWIFT_BUILD_JOBS=20 bash scripts/linux-verify.sh
#   OPENROUTER_API_KEY=... bash scripts/linux-verify.sh   # adds the live smoke
#
# From macOS/host via Docker (recommended — persistent .build volume):
#   bash scripts/linux-container-verify.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/linux-common.sh"

echo "=== Linux verify: $(uname -s) $(uname -m) ==="
echo "=== Swift: $(swift --version | head -1) ==="
echo "=== Parallel jobs: $SWIFT_JOBS (override with SWIFT_BUILD_JOBS) ==="

pass() { echo "OK: $1"; }

if [[ "${LINUX_VERIFY_QUICK:-}" == "1" ]]; then
  echo "--- QUICK: debug build + offline suite ---"
  swift build "${SWIFT_BUILD_FLAGS[@]}" --build-tests
  pass "debug build"
  swift test "${SWIFT_TEST_FLAGS[@]}"
  pass "offline test suite"
  echo "=== Linux verify (quick): PASSED ==="
  exit 0
fi

echo "--- build library + tests (release) ---"
# Release strips -enable-testing by default, so a standalone `build --build-tests`
# compiles the @testable test modules against a non-testing library and fails.
# `swift test` enables it implicitly; match that here.
swift build -c release "${SWIFT_BUILD_FLAGS[@]}" --build-tests -Xswiftc -enable-testing
pass "release build"

echo "--- full offline suite (live suites self-gate) ---"
swift test -c release "${SWIFT_TEST_FLAGS[@]}"
pass "offline test suite"

# Live model-backed validation goes through the OpenRouter bridge harness
# (euwars/OpenrouterForFoundationModels built with its ServerFoundationModels
# trait, resolving this working tree via path override).
if [[ -n "${OPENROUTER_API_KEY:-}" ]]; then
  echo "--- live OpenRouter smoke (respond, streaming, guided, tools) ---"
  swift run --package-path integration/openrouter-parity | tee /tmp/openrouter-smoke.log
  grep -q "SMOKE GREEN" /tmp/openrouter-smoke.log
  pass "OpenRouter live smoke"
else
  echo "SKIP: OpenRouter live smoke (set OPENROUTER_API_KEY to run)"
fi

echo "=== Linux verify: ALL CHECKS PASSED ==="
