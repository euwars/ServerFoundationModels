#!/usr/bin/env bash
# Run Linux verification inside the official Swift 6.2 container.
#
# Usage:
#   bash scripts/linux-container-verify.sh              # full verify
#   LINUX_VERIFY_QUICK=1 bash scripts/linux-container-verify.sh
#   XAI_API_KEY=... bash scripts/linux-container-verify.sh
#
# Docker / CPU env:
#   SWIFT_BUILD_JOBS=20           — swift -j (default: container nproc)
#   LINUX_VERIFY_CPUS=20          — optional docker --cpus cap (default: none = VM max)
#   LINUX_VERIFY_SHM_SIZE=4g      — shared memory for parallel C++ compiles (default 4g)
#   LINUX_VERIFY_IMAGE=swift:6.2
#   LINUX_VERIFY_PLATFORM=linux/amd64
#   LINUX_VERIFY_QUICK=1
#   LINUX_VERIFY_NO_CACHE=1
#   LINUX_VERIFY_BUILD_VOLUME=sfm-linux-build-cache
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${LINUX_VERIFY_IMAGE:-swift:6.2}"
BUILD_VOLUME="${LINUX_VERIFY_BUILD_VOLUME:-sfm-linux-build-cache}"
SHM_SIZE="${LINUX_VERIFY_SHM_SIZE:-4g}"

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
  echo "ERROR: docker not found. Install OrbStack/Docker, or run on Linux:" >&2
  echo "  bash scripts/linux-verify.sh" >&2
  exit 127
}

if [[ "${LINUX_VERIFY_NO_CACHE:-}" != "1" ]]; then
  docker_cmd volume create "$BUILD_VOLUME" >/dev/null 2>&1 || true
fi

# Match swift -j to CPUs the container actually sees (not macOS host guess).
if [[ -z "${SWIFT_BUILD_JOBS:-}" ]]; then
  SWIFT_BUILD_JOBS="$(docker_cmd run --rm "$IMAGE" nproc)"
fi

docker_cpus="$(docker_cmd info --format '{{.NCPU}}' 2>/dev/null || echo "?")"

echo "=== Running Linux verify in container: $IMAGE ==="
echo "=== Docker daemon CPUs: $docker_cpus | swift -j: $SWIFT_BUILD_JOBS | shm: $SHM_SIZE ==="
if [[ "${LINUX_VERIFY_QUICK:-}" == "1" ]]; then
  echo "=== Mode: QUICK ==="
else
  echo "=== Mode: FULL ==="
fi

mount_args=(-v "$ROOT:/work:rw")
if [[ "${LINUX_VERIFY_NO_CACHE:-}" != "1" ]]; then
  mount_args+=(-v "$BUILD_VOLUME:/work/.build")
fi

# Docker runtime tuning for parallel Swift/C++ builds.
# Default: no --cpus (cgroup unlimited within the OrbStack VM — faster than mis-capped).
# --shm-size: BoringSSL/NIO C++ compiles spawn many threads; default 64m is too small.
docker_runtime=(--shm-size="$SHM_SIZE")
if [[ -n "${LINUX_VERIFY_CPUS:-}" ]]; then
  docker_runtime+=(--cpus="$LINUX_VERIFY_CPUS")
  echo "=== docker --cpus=$LINUX_VERIFY_CPUS (explicit cap) ==="
fi

env_args=(
  -e "XAI_API_KEY=${XAI_API_KEY:-}"
  -e "LINUX_VERIFY_QUICK=${LINUX_VERIFY_QUICK:-}"
  -e "SWIFT_BUILD_JOBS=$SWIFT_BUILD_JOBS"
)

platform_args=()
if [[ -n "${LINUX_VERIFY_PLATFORM:-}" ]]; then
  platform_args=(--platform "$LINUX_VERIFY_PLATFORM")
fi

# `${platform_args[@]+…}` guard: macOS bash 3.2 treats an empty array under
# `set -u` as unbound, so expand to nothing when no platform override is set.
docker_cmd run --rm -it=false "${platform_args[@]+"${platform_args[@]}"}" "${docker_runtime[@]}" \
  "${mount_args[@]}" "${env_args[@]}" -w /work "$IMAGE" \
  bash scripts/linux-verify.sh