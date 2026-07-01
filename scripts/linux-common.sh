#!/usr/bin/env bash
# Shared helpers for Linux container/native verify scripts.

linux_job_count() {
  if [[ -n "${SWIFT_BUILD_JOBS:-}" ]]; then
    echo "$SWIFT_BUILD_JOBS"
    return
  fi
  if command -v nproc >/dev/null 2>&1; then
    nproc
    return
  fi
  if command -v sysctl >/dev/null 2>&1; then
    sysctl -n hw.ncpu 2>/dev/null && return
  fi
  echo 4
}

# Populated when sourced from linux-verify.sh
SWIFT_JOBS="$(linux_job_count)"
SWIFT_BUILD_FLAGS=(-j "$SWIFT_JOBS")
# Unit tests are independent — run in parallel when supported.
# `--parallel-worker-count` is not a valid `swift test` option in Swift 6.2;
# `--parallel` alone parallelizes (swift-testing runs concurrently by default).
SWIFT_TEST_FLAGS=(-j "$SWIFT_JOBS" --parallel)