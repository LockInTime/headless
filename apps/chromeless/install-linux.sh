#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PREFIX="${CHROMELESS_INSTALL_PREFIX:-$HOME/.local}"

if [ "$#" -gt 0 ]; then
  if [ "$#" -ne 2 ] || [ "$1" != "--prefix" ]; then
    echo "usage: ./install-linux.sh [--prefix /absolute/path]" >&2
    exit 64
  fi
  PREFIX="$2"
fi

case "$PREFIX" in
  /*) ;;
  *) echo "chromeless install: prefix must be an absolute path" >&2; exit 64 ;;
esac
if [ "$PREFIX" = "/" ]; then
  echo "chromeless install: refusing to use / as the install prefix" >&2
  exit 64
fi
if [ "$(uname -s)" != "Linux" ]; then
  echo "chromeless install: this installer is for Linux" >&2
  exit 69
fi

if [ -x "$SCRIPT_DIR/chromeless" ] && [ -x "$SCRIPT_DIR/chromeless-host" ] && [ -x "$SCRIPT_DIR/chromeless-mcp" ]; then
  SOURCE_DIR="$SCRIPT_DIR"
elif [ -x "$SCRIPT_DIR/build/linux/chromeless" ] && [ -x "$SCRIPT_DIR/build/linux/chromeless-host" ] && [ -x "$SCRIPT_DIR/build/linux/chromeless-mcp" ]; then
  SOURCE_DIR="$SCRIPT_DIR/build/linux"
else
  echo "chromeless install: Linux binaries were not found; run ./build-linux.sh first" >&2
  exit 69
fi

CHROMIUM=""
for candidate in chromium chromium-browser google-chrome; do
  if command -v "$candidate" >/dev/null 2>&1; then CHROMIUM="$candidate"; break; fi
done
if [ -z "$CHROMIUM" ]; then
  echo "chromeless install: Chromium is required; install chromium with your system package manager" >&2
  exit 69
fi
if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "chromeless install: FFmpeg is required for recording; install ffmpeg with your system package manager" >&2
  exit 69
fi

BIN_DIR="$PREFIX/bin"
install -d -m 0755 "$BIN_DIR"
install -m 0755 "$SOURCE_DIR/chromeless" "$BIN_DIR/chromeless"
install -m 0755 "$SOURCE_DIR/chromeless-host" "$BIN_DIR/chromeless-host"
install -m 0755 "$SOURCE_DIR/chromeless-mcp" "$BIN_DIR/chromeless-mcp"

echo "Chromeless installed in $BIN_DIR"
echo "Browser: $CHROMIUM"
echo "Run: $BIN_DIR/chromeless capabilities"
