#!/usr/bin/env bash
# Linux compatibility verification for ServerFoundationModels + XAI provider.
# Intended to run inside the official swift:6.2 container (or native Linux).
#
# Usage (from repo root):
#   bash scripts/linux-verify.sh
#   LINUX_VERIFY_QUICK=1 bash scripts/linux-verify.sh
#   SWIFT_BUILD_JOBS=20 bash scripts/linux-verify.sh
#   XAI_API_KEY=... bash scripts/linux-verify.sh
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

XAI_FILTER='XAIWireFormatTests|XAIInlineInputTests|XAIThreadingTests|XAIResponseTranslatorTests|XAISchemaHelpersTests|XAIServerToolSegmentTests|XAIServerToolWireTests'
PARITY_FILTER='APIParityScenarios|DifferentialParityScenarios|WireCaptureTests|SSEEdgeCaseTests|LoggingTests'

if [[ "${LINUX_VERIFY_QUICK:-}" == "1" ]]; then
  echo "--- QUICK: debug build + XAI unit tests ---"
  swift build "${SWIFT_BUILD_FLAGS[@]}" --build-tests
  pass "debug build"
  swift test "${SWIFT_TEST_FLAGS[@]}" --filter "$XAI_FILTER"
  pass "XAI unit tests"
  echo "=== Linux verify (quick): PASSED ==="
  exit 0
fi

echo "--- build library + tests (release, NIO transport) ---"
swift build -c release "${SWIFT_BUILD_FLAGS[@]}" --build-tests
pass "release build (AsyncHTTPClient)"

echo "--- build XAILiveProbe (release) ---"
swift build -c release "${SWIFT_BUILD_FLAGS[@]}" --product XAILiveProbe
pass "XAILiveProbe release build"

echo "--- XAI unit tests ---"
swift test -c release "${SWIFT_TEST_FLAGS[@]}" --filter "$XAI_FILTER"
pass "XAI unit tests"

echo "--- build library (URLSession transport, traits disabled) ---"
swift build -c release "${SWIFT_BUILD_FLAGS[@]}" --disable-default-traits
pass "release build (URLSession / no AsyncHTTPClient)"

echo "--- core parity subset (model-free) ---"
swift test -c release "${SWIFT_TEST_FLAGS[@]}" --filter "$PARITY_FILTER"
pass "parity subset tests"

if [[ -n "${XAI_API_KEY:-}" ]]; then
  echo "--- live xAI probe (grok-4.3 chaining + prompt cache) ---"
  swift run -c release "${SWIFT_BUILD_FLAGS[@]}" XAILiveProbe | tee /tmp/xai-live.log
  grep -q "RESULT: PASS" /tmp/xai-live.log
  pass "XAILiveProbe live (grok-4.3)"

  echo "--- live xAI server-tools probe (strict segment + citation coverage) ---"
  swift run -c release "${SWIFT_BUILD_FLAGS[@]}" XAIServerToolsProbe | tee /tmp/xai-server-tools.log
  grep -q "RESULT: PASS" /tmp/xai-server-tools.log
  pass "XAIServerToolsProbe live (webSearch, xSearch, open_page, citations)"
else
  echo "SKIP: XAILiveProbe / XAIServerToolsProbe (set XAI_API_KEY to run live xAI verification)"
fi

echo "=== Linux verify: ALL CHECKS PASSED ==="