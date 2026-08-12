#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
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

if [ -x "$SCRIPT_DIR/headless" ] && [ -x "$SCRIPT_DIR/headless-host" ] && [ -x "$SCRIPT_DIR/headless-mcp" ] && [ -f "$SCRIPT_DIR/Headless_HeadlessProtocol.resources/AgentRuntime.js" ]; then
  SOURCE_DIR="$SCRIPT_DIR"
elif [ -x "$SCRIPT_DIR/build/linux/headless" ] && [ -x "$SCRIPT_DIR/build/linux/headless-host" ] && [ -x "$SCRIPT_DIR/build/linux/headless-mcp" ] && [ -f "$SCRIPT_DIR/build/linux/Headless_HeadlessProtocol.resources/AgentRuntime.js" ]; then
  SOURCE_DIR="$SCRIPT_DIR/build/linux"
else
  echo "headless install: Linux binaries were not found; run ./build-linux.sh first" >&2
  exit 69
fi

if ! RUNTIME="$(HEADLESS_HOST_EXECUTABLE="$SOURCE_DIR/headless-host" "$SOURCE_DIR/headless" runtime 2>&1)"; then
  echo "headless install: unsupported Chromium runtime" >&2
  echo "$RUNTIME" >&2
  exit 69
fi

FFMPEG=""
if [ "${HEADLESS_FFMPEG_EXECUTABLE+x}" = x ]; then
  case "$HEADLESS_FFMPEG_EXECUTABLE" in
    /*) FFMPEG="$HEADLESS_FFMPEG_EXECUTABLE" ;;
    *) echo "headless install: HEADLESS_FFMPEG_EXECUTABLE must be an absolute path" >&2; exit 69 ;;
  esac
else
  for candidate in /usr/local/bin/ffmpeg /usr/bin/ffmpeg; do
    if [ -x "$candidate" ] && [ -f "$candidate" ]; then
      FFMPEG="$candidate"
      break
    fi
  done
fi
if [ -z "$FFMPEG" ] || [ ! -x "$FFMPEG" ] || [ ! -f "$FFMPEG" ]; then
  echo "headless install: FFmpeg was not found in an allowed absolute location" >&2
  echo "headless install: install ffmpeg with the system package manager or set HEADLESS_FFMPEG_EXECUTABLE" >&2
  exit 69
fi

BIN_DIR="$PREFIX/bin"
install -d -m 0755 "$BIN_DIR"
install -m 0755 "$SOURCE_DIR/headless" "$BIN_DIR/headless"
install -m 0755 "$SOURCE_DIR/headless-host" "$BIN_DIR/headless-host"
install -m 0755 "$SOURCE_DIR/headless-mcp" "$BIN_DIR/headless-mcp"
install -d -m 0755 "$BIN_DIR/Headless_HeadlessProtocol.resources"
install -m 0644 "$SOURCE_DIR/Headless_HeadlessProtocol.resources/AgentRuntime.js" \
  "$BIN_DIR/Headless_HeadlessProtocol.resources/AgentRuntime.js"

echo "Headless installed in $BIN_DIR"
echo "Browser runtime verified: $RUNTIME"
echo "Recording runtime: $FFMPEG"
echo "Run: $BIN_DIR/headless capabilities"
echo "Check: $BIN_DIR/headless runtime"
