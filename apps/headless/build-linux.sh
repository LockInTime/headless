#!/bin/sh
# Build native Linux binaries without installing Swift on the host.
set -eu
cd "$(dirname "$0")"

command -v docker >/dev/null 2>&1 || {
  echo "headless Linux build: Docker is required (Swift is not)." >&2
  exit 69
}

IMAGE="headless-linux-build"
if [ -n "${HEADLESS_LINUX_PLATFORM:-}" ]; then
  docker build --platform "$HEADLESS_LINUX_PLATFORM" --target production -f Dockerfile.linux -t "$IMAGE" .
else
  docker build --target production -f Dockerfile.linux -t "$IMAGE" .
fi
mkdir -p build/linux
CONTAINER="$(docker create "$IMAGE")"
cleanup() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM
docker cp "$CONTAINER:/usr/local/bin/headless" build/linux/headless
docker cp "$CONTAINER:/usr/local/bin/headless-host" build/linux/headless-host
docker cp "$CONTAINER:/usr/local/bin/headless-mcp" build/linux/headless-mcp
chmod 0755 build/linux/headless build/linux/headless-host build/linux/headless-mcp
cp install-linux.sh build/linux/install-linux.sh
cp docs/P1.md docs/P2.md build/linux/
chmod 0755 build/linux/install-linux.sh
PLATFORM_LABEL="${HEADLESS_LINUX_PLATFORM##*/}"
if [ -z "$PLATFORM_LABEL" ]; then PLATFORM_LABEL="$(uname -m)"; fi
ARCHIVE="build/headless-linux-$PLATFORM_LABEL.tar.gz"
tar -czf "$ARCHIVE" -C build/linux headless headless-host headless-mcp install-linux.sh P1.md P2.md
echo "Linux binaries: $PWD/build/linux"
echo "Linux package: $PWD/$ARCHIVE"
echo "Install Chromium from your Linux distribution, then put the CLI, host, and MCP binaries on PATH."
