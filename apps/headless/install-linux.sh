#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PREFIX="${HEADLESS_INSTALL_PREFIX:-$HOME/.local}"

if [ "$#" -gt 0 ]; then
  if [ "$#" -ne 2 ] || [ "$1" != "--prefix" ]; then
    echo "usage: ./install-linux.sh [--prefix /absolute/path]" >&2
    exit 64
  fi
  PREFIX="$2"
fi

case "$PREFIX" in
  /*) ;;
  *) echo "headless install: prefix must be an absolute path" >&2; exit 64 ;;
esac
if [ "$PREFIX" = "/" ]; then
  echo "headless install: refusing to use / as the install prefix" >&2
  exit 64
fi
if [ "$(uname -s)" != "Linux" ]; then
  echo "headless install: this installer is for Linux" >&2
  exit 69
fi

if [ -x "$SCRIPT_DIR/headless" ] && [ -x "$SCRIPT_DIR/headless-host" ] && [ -x "$SCRIPT_DIR/headless-mcp" ]; then
  SOURCE_DIR="$SCRIPT_DIR"
elif [ -x "$SCRIPT_DIR/build/linux/headless" ] && [ -x "$SCRIPT_DIR/build/linux/headless-host" ] && [ -x "$SCRIPT_DIR/build/linux/headless-mcp" ]; then
  SOURCE_DIR="$SCRIPT_DIR/build/linux"
else
  echo "headless install: Linux binaries were not found; run ./build-linux.sh first" >&2
  exit 69
fi

CHROMIUM=""
for candidate in chromium chromium-browser google-chrome; do
  if command -v "$candidate" >/dev/null 2>&1; then CHROMIUM="$candidate"; break; fi
done
if [ -z "$CHROMIUM" ]; then
  echo "headless install: Chromium is required; install chromium with your system package manager" >&2
  exit 69
fi
if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "headless install: FFmpeg is required for recording; install ffmpeg with your system package manager" >&2
  exit 69
fi

BIN_DIR="$PREFIX/bin"
install -d -m 0755 "$BIN_DIR"
install -m 0755 "$SOURCE_DIR/headless" "$BIN_DIR/headless"
install -m 0755 "$SOURCE_DIR/headless-host" "$BIN_DIR/headless-host"
install -m 0755 "$SOURCE_DIR/headless-mcp" "$BIN_DIR/headless-mcp"

echo "Headless installed in $BIN_DIR"
echo "Browser: $CHROMIUM"
echo "Run: $BIN_DIR/headless capabilities"
