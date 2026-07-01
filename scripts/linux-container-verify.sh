#!/usr/bin/env bash
# Run Linux verification inside the official Swift 6.2 container.
#
# Usage:
#   bash scripts/linux-container-verify.sh
#   XAI_API_KEY=... bash scripts/linux-container-verify.sh
#
# Optional env:
#   LINUX_VERIFY_IMAGE=swift:6.2
#   LINUX_VERIFY_PLATFORM=linux/amd64   # useful on Apple Silicon if needed
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${LINUX_VERIFY_IMAGE:-swift:6.2}"

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
  echo "ERROR: docker not found. Install Docker Desktop or run on a Linux host:" >&2
  echo "  bash scripts/linux-verify.sh" >&2
  exit 127
}

echo "=== Running Linux verify in container: $IMAGE ==="

run_args=(run --rm -v "$ROOT:/src:ro" -e XAI_API_KEY -w /src "$IMAGE" \
  bash -lc 'cp -a /src /work && cd /work && bash scripts/linux-verify.sh')
if [[ -n "${LINUX_VERIFY_PLATFORM:-}" ]]; then
  run_args=(run --rm --platform "$LINUX_VERIFY_PLATFORM" -v "$ROOT:/src:ro" -e XAI_API_KEY -w /src "$IMAGE" \
    bash -lc 'cp -a /src /work && cd /work && bash scripts/linux-verify.sh')
fi

docker_cmd "${run_args[@]}"