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
SNAP_CHROMIUM=""

consider_chromium() {
  candidate="$1"
  case "$candidate" in
    /snap|/snap/*|/var/lib/snapd/snap|/var/lib/snapd/snap/*|/usr/bin/snap)
      SNAP_CHROMIUM="$candidate"
      return 1
      ;;
  esac
  [ -x "$candidate" ] && [ -f "$candidate" ] || return 1
  resolved="$(readlink -f "$candidate" 2>/dev/null || true)"
  [ -n "$resolved" ] || resolved="$candidate"
  case "$resolved" in
    /snap|/snap/*|/var/lib/snapd/snap|/var/lib/snapd/snap/*|/usr/bin/snap)
      SNAP_CHROMIUM="$candidate"
      return 1
      ;;
  esac
  case "$(sed -n '1p' "$resolved" 2>/dev/null || true)" in
    '#!'*)
      if grep -Eq '/snap/bin/|/usr/bin/snap|snap run ' "$resolved"; then
        SNAP_CHROMIUM="$candidate"
        return 1
      fi
      ;;
  esac
  CHROMIUM="$resolved"
  return 0
}

if [ "${HEADLESS_CHROMIUM_EXECUTABLE+x}" = x ]; then
  case "$HEADLESS_CHROMIUM_EXECUTABLE" in
    /*) ;;
    *)
      echo "headless install: HEADLESS_CHROMIUM_EXECUTABLE must be an absolute path" >&2
      exit 69
      ;;
  esac
  if ! consider_chromium "$HEADLESS_CHROMIUM_EXECUTABLE"; then
    if [ -n "$SNAP_CHROMIUM" ]; then
      echo "headless install: Ubuntu Snap Chromium is not supported with the inherited DevTools pipe: $SNAP_CHROMIUM" >&2
    else
      echo "headless install: HEADLESS_CHROMIUM_EXECUTABLE is not an executable regular file: $HEADLESS_CHROMIUM_EXECUTABLE" >&2
    fi
    echo "headless install: use the bundled Docker runtime or a native distribution Chromium binary" >&2
    exit 69
  fi
else
  for candidate in \
    "$SCRIPT_DIR/runtime/chromium/chromium" \
    /usr/lib/chromium/chromium \
    /usr/lib64/chromium/chromium \
    /usr/lib64/chromium-browser/chromium-browser \
    /opt/google/chrome/chrome \
    /opt/google/chrome/google-chrome \
    /usr/bin/chromium \
    /usr/bin/chromium-browser \
    /usr/bin/google-chrome-stable \
    /usr/bin/google-chrome
  do
    if consider_chromium "$candidate"; then break; fi
  done
  if [ -z "$CHROMIUM" ]; then
    for command_name in chromium chromium-browser google-chrome-stable google-chrome; do
      candidate="$(command -v "$command_name" 2>/dev/null || true)"
      [ -n "$candidate" ] || continue
      if consider_chromium "$candidate"; then break; fi
    done
  fi
  if [ -z "$CHROMIUM" ]; then
    if [ -n "$SNAP_CHROMIUM" ]; then
      echo "headless install: Ubuntu Snap Chromium is not supported with the inherited DevTools pipe: $SNAP_CHROMIUM" >&2
    else
      echo "headless install: no supported Chromium runtime was found" >&2
    fi
    echo "headless install: use the bundled Docker runtime or install a native distribution Chromium binary" >&2
    exit 69
  fi
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
echo "Browser runtime: $CHROMIUM (supported inherited DevTools pipe)"
echo "Run: $BIN_DIR/headless capabilities"
echo "Check: $BIN_DIR/headless runtime"
