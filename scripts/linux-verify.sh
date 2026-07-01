#!/usr/bin/env bash
# Linux compatibility verification for ServerFoundationModels + XAI provider.
# Intended to run inside the official swift:6.2 container (or native Linux).
#
# Usage (from repo root):
#   bash scripts/linux-verify.sh
#   XAI_API_KEY=... bash scripts/linux-verify.sh   # also runs live xAI probe
#
# From macOS/host via Docker:
#   bash scripts/linux-container-verify.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "=== Linux verify: $(uname -s) $(uname -m) ==="
echo "=== Swift: $(swift --version | head -1) ==="

pass() { echo "OK: $1"; }

XAI_FILTER='XAIWireFormatTests|XAIInlineInputTests|XAIThreadingTests|XAIResponseTranslatorTests|XAISchemaHelpersTests'
PARITY_FILTER='APIParityScenarios|DifferentialParityScenarios|WireCaptureTests|SSEEdgeCaseTests|LoggingTests'

echo "--- build library (NIO transport, default traits) ---"
swift build -c release
pass "release build (AsyncHTTPClient)"

echo "--- build XAILiveProbe ---"
swift build -c release --product XAILiveProbe
pass "XAILiveProbe release build"

echo "--- XAI unit tests (wire format, threading, inline replay) ---"
swift test --filter "$XAI_FILTER"
pass "XAI unit tests"

echo "--- build library (URLSession transport, traits disabled) ---"
swift build -c release --disable-default-traits
pass "release build (URLSession / no AsyncHTTPClient)"

echo "--- core parity subset (model-free) ---"
swift test --filter "$PARITY_FILTER"
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