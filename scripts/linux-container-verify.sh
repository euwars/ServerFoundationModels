#!/usr/bin/env bash
# Run Linux verification inside the official Swift 6.2 container.
#
# Usage:
#   bash scripts/linux-container-verify.sh              # full verify
#   LINUX_VERIFY_QUICK=1 bash scripts/linux-container-verify.sh   # fast dev loop
#   XAI_API_KEY=... bash scripts/linux-container-verify.sh
#
# Optional env:
#   LINUX_VERIFY_IMAGE=swift:6.2
#   LINUX_VERIFY_PLATFORM=linux/amd64
#   LINUX_VERIFY_QUICK=1          — debug build + XAI tests only (~2 min warm)
#   LINUX_VERIFY_NO_CACHE=1       — discard persistent .build volume
#   LINUX_VERIFY_BUILD_VOLUME=sfm-linux-build-cache
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${LINUX_VERIFY_IMAGE:-swift:6.2}"
BUILD_VOLUME="${LINUX_VERIFY_BUILD_VOLUME:-sfm-linux-build-cache}"

docker_cmd() {
  if command -v docker >/dev/null 2>&1; then
    command docker "$@"
    return
  fi
  local mac_docker="/Applications/Docker.app/Contents/Resources/bin/docker"
  if [[ -x "$mac_docker" ]]; then
    "$mac_docker" "$@"
    return
  fi
  echo "ERROR: docker not found. Install Docker Desktop or OrbStack, or run on Linux:" >&2
  echo "  bash scripts/linux-verify.sh" >&2
  exit 127
}

if [[ "${LINUX_VERIFY_NO_CACHE:-}" != "1" ]]; then
  docker_cmd volume create "$BUILD_VOLUME" >/dev/null 2>&1 || true
fi

echo "=== Running Linux verify in container: $IMAGE ==="
if [[ "${LINUX_VERIFY_QUICK:-}" == "1" ]]; then
  echo "=== Mode: QUICK (debug build + XAI unit tests) ==="
else
  echo "=== Mode: FULL ==="
fi

mount_args=(-v "$ROOT:/work:rw")
if [[ "${LINUX_VERIFY_NO_CACHE:-}" != "1" ]]; then
  mount_args+=(-v "$BUILD_VOLUME:/work/.build")
fi

run_args=(run --rm "${mount_args[@]}" -e XAI_API_KEY -e LINUX_VERIFY_QUICK -w /work "$IMAGE" \
  bash scripts/linux-verify.sh)
if [[ -n "${LINUX_VERIFY_PLATFORM:-}" ]]; then
  run_args=(run --rm --platform "$LINUX_VERIFY_PLATFORM" "${mount_args[@]}" -e XAI_API_KEY -e LINUX_VERIFY_QUICK -w /work "$IMAGE" \
    bash scripts/linux-verify.sh)
fi

docker_cmd "${run_args[@]}"