#!/usr/bin/env bash
# Linux compatibility verification for ServerFoundationModels + XAI provider.
# Intended to run inside the official swift:6.2 container (or native Linux).
#
# Usage (from repo root):
#   bash scripts/linux-verify.sh
#   LINUX_VERIFY_QUICK=1 bash scripts/linux-verify.sh
#   XAI_API_KEY=... bash scripts/linux-verify.sh
#
# From macOS/host via Docker (recommended — persistent .build volume):
#   bash scripts/linux-container-verify.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "=== Linux verify: $(uname -s) $(uname -m) ==="
echo "=== Swift: $(swift --version | head -1) ==="

pass() { echo "OK: $1"; }

XAI_FILTER='XAIWireFormatTests|XAIInlineInputTests|XAIThreadingTests|XAIResponseTranslatorTests|XAISchemaHelpersTests'
PARITY_FILTER='APIParityScenarios|DifferentialParityScenarios|WireCaptureTests|SSEEdgeCaseTests|LoggingTests'

if [[ "${LINUX_VERIFY_QUICK:-}" == "1" ]]; then
  echo "--- QUICK: debug build + XAI unit tests ---"
  swift build --build-tests
  pass "debug build"
  swift test --filter "$XAI_FILTER"
  pass "XAI unit tests"
  echo "=== Linux verify (quick): PASSED ==="
  exit 0
fi

echo "--- build library + tests (release, NIO transport) ---"
swift build -c release --build-tests
pass "release build (AsyncHTTPClient)"

echo "--- build XAILiveProbe (release) ---"
swift build -c release --product XAILiveProbe
pass "XAILiveProbe release build"

echo "--- XAI unit tests ---"
swift test -c release --filter "$XAI_FILTER"
pass "XAI unit tests"

echo "--- build library (URLSession transport, traits disabled) ---"
swift build -c release --disable-default-traits
pass "release build (URLSession / no AsyncHTTPClient)"

echo "--- core parity subset (model-free) ---"
swift test -c release --filter "$PARITY_FILTER"
pass "parity subset tests"

if [[ -n "${XAI_API_KEY:-}" ]]; then
  echo "--- live xAI probe (grok-4.3 chaining + prompt cache) ---"
  swift run -c release XAILiveProbe | tee /tmp/xai-live.log
  grep -q "RESULT: PASS" /tmp/xai-live.log
  pass "XAILiveProbe live (grok-4.3)"
else
  echo "SKIP: XAILiveProbe (set XAI_API_KEY to run live xAI verification)"
fi

echo "=== Linux verify: ALL CHECKS PASSED ==="