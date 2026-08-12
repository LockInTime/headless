#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../../../.." && pwd)"

die() {
  echo "headless mcp: $*" >&2
  exit 1
}

[ "$#" -eq 0 ] || die "this launcher does not accept arguments"

if [ -n "${HEADLESS_MCP_EXECUTABLE:-}" ]; then
  case "$HEADLESS_MCP_EXECUTABLE" in
    /*) ;;
    *) die "HEADLESS_MCP_EXECUTABLE must be an absolute path" ;;
  esac
  [ -f "$HEADLESS_MCP_EXECUTABLE" ] || die "override is not a regular file: $HEADLESS_MCP_EXECUTABLE"
  [ -x "$HEADLESS_MCP_EXECUTABLE" ] || die "override is not executable: $HEADLESS_MCP_EXECUTABLE"
  exec "$HEADLESS_MCP_EXECUTABLE"
fi

for candidate in \
  "$REPO_ROOT/apps/headless/build/bin/headless-mcp" \
  "$REPO_ROOT/apps/headless/Headless.app/Contents/Resources/bin/headless-mcp" \
  "$REPO_ROOT/apps/headless/build/linux/headless-mcp"
do
  if [ -f "$candidate" ] && [ -x "$candidate" ]; then
    exec "$candidate"
  fi
done

if command -v headless-mcp >/dev/null 2>&1; then
  exec headless-mcp
fi

die "headless-mcp was not found; build Headless or set HEADLESS_MCP_EXECUTABLE"
