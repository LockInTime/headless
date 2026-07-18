#!/bin/sh
# Build native Linux binaries without installing Swift on the host.
set -eu
cd "$(dirname "$0")"

command -v docker >/dev/null 2>&1 || {
  echo "chromeless Linux build: Docker is required (Swift is not)." >&2
  exit 69
}

IMAGE="chromeless-linux-build"
if [ -n "${CHROMELESS_LINUX_PLATFORM:-}" ]; then
  docker build --platform "$CHROMELESS_LINUX_PLATFORM" --target production -f Dockerfile.linux -t "$IMAGE" .
else
  docker build --target production -f Dockerfile.linux -t "$IMAGE" .
fi
mkdir -p build/linux
CONTAINER="$(docker create "$IMAGE")"
cleanup() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM
docker cp "$CONTAINER:/usr/local/bin/chromeless" build/linux/chromeless
docker cp "$CONTAINER:/usr/local/bin/chromeless-host" build/linux/chromeless-host
docker cp "$CONTAINER:/usr/local/bin/chromeless-mcp" build/linux/chromeless-mcp
chmod 0755 build/linux/chromeless build/linux/chromeless-host build/linux/chromeless-mcp
cp install-linux.sh build/linux/install-linux.sh
cp docs/P1.md docs/P2.md build/linux/
chmod 0755 build/linux/install-linux.sh
PLATFORM_LABEL="${CHROMELESS_LINUX_PLATFORM##*/}"
if [ -z "$PLATFORM_LABEL" ]; then PLATFORM_LABEL="$(uname -m)"; fi
ARCHIVE="build/chromeless-linux-$PLATFORM_LABEL.tar.gz"
tar -czf "$ARCHIVE" -C build/linux chromeless chromeless-host chromeless-mcp install-linux.sh P1.md P2.md
echo "Linux binaries: $PWD/build/linux"
echo "Linux package: $PWD/$ARCHIVE"
echo "The Docker image includes Debian Chromium at /usr/lib/chromium/chromium."
echo "The portable binaries require a native, non-Snap Chromium runtime; Ubuntu Snap Chromium is not supported."
echo "Run chromeless runtime after installation to verify the selected executable."
