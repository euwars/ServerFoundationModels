#!/usr/bin/env bash
# Interactive Linux dev shell with persistent .build cache (fast rebuild loop).
#
# Usage:
#   bash scripts/linux-container-shell.sh
#   bash scripts/linux-container-shell.sh swift test --filter XAIWireFormatTests
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${LINUX_VERIFY_IMAGE:-swift:6.2}"
BUILD_VOLUME="${LINUX_VERIFY_BUILD_VOLUME:-sfm-linux-build-cache}"
HOST_CPUS="${LINUX_VERIFY_CPUS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo "")}"
CPU_ARGS=()
[[ -n "$HOST_CPUS" ]] && CPU_ARGS=(--cpus="$HOST_CPUS")

docker_cmd() {
  command -v docker >/dev/null 2>&1 && command docker "$@" && return
  [[ -x /Applications/Docker.app/Contents/Resources/bin/docker ]] \
    && /Applications/Docker.app/Contents/Resources/bin/docker "$@" && return
  echo "docker not found" >&2; exit 127
}

docker_cmd volume create "$BUILD_VOLUME" >/dev/null 2>&1 || true

if [[ $# -gt 0 ]]; then
  docker_cmd run --rm -it \
    "${CPU_ARGS[@]}" \
    -e SWIFT_BUILD_JOBS \
    -v "$ROOT:/work:rw" \
    -v "$BUILD_VOLUME:/work/.build" \
    -w /work \
    "$IMAGE" \
    "$@"
else
  docker_cmd run --rm -it \
    "${CPU_ARGS[@]}" \
    -e SWIFT_BUILD_JOBS \
    -v "$ROOT:/work:rw" \
    -v "$BUILD_VOLUME:/work/.build" \
    -w /work \
    "$IMAGE" \
    bash
fi