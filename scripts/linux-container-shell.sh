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
SHM_SIZE="${LINUX_VERIFY_SHM_SIZE:-4g}"

docker_cmd() {
  command -v docker >/dev/null 2>&1 && command docker "$@" && return
  [[ -x /Applications/Docker.app/Contents/Resources/bin/docker ]] \
    && /Applications/Docker.app/Contents/Resources/bin/docker "$@" && return
  echo "docker not found" >&2; exit 127
}

DOCKER_RUNTIME=(--shm-size="$SHM_SIZE")
[[ -n "${LINUX_VERIFY_CPUS:-}" ]] && DOCKER_RUNTIME+=(--cpus="$LINUX_VERIFY_CPUS")

if [[ -z "${SWIFT_BUILD_JOBS:-}" ]]; then
  SWIFT_BUILD_JOBS="$(docker_cmd run --rm "$IMAGE" nproc 2>/dev/null || echo 4)"
  export SWIFT_BUILD_JOBS
fi

docker_cmd volume create "$BUILD_VOLUME" >/dev/null 2>&1 || true

if [[ $# -gt 0 ]]; then
  docker_cmd run --rm -it \
    "${DOCKER_RUNTIME[@]}" \
    -e SWIFT_BUILD_JOBS \
    -v "$ROOT:/work:rw" \
    -v "$BUILD_VOLUME:/work/.build" \
    -w /work \
    "$IMAGE" \
    "$@"
else
  docker_cmd run --rm -it \
    "${DOCKER_RUNTIME[@]}" \
    -e SWIFT_BUILD_JOBS \
    -v "$ROOT:/work:rw" \
    -v "$BUILD_VOLUME:/work/.build" \
    -w /work \
    "$IMAGE" \
    bash
fi