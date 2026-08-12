#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/headless-installer-tests.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT INT TERM
TOOLS="$ROOT/tools"
RELEASE="$ROOT/release"
BUNDLE="$ROOT/bundle"
mkdir -p "$TOOLS" "$RELEASE" "$BUNDLE/Headless_HeadlessProtocol.resources"

cat > "$TOOLS/uname" <<'EOF'
#!/bin/sh
if [ "$1" = "-s" ]; then printf '%s\n' "${FAKE_SYSTEM:-Linux}"; else printf '%s\n' "${FAKE_ARCH:-x86_64}"; fi
EOF
cat > "$TOOLS/curl" <<'EOF'
#!/bin/sh
output=""
write_out=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    --write-out) write_out="$2"; shift 2 ;;
    --proto) shift 2 ;;
    --tlsv1.2|--fail|--location|--silent|--show-error) shift ;;
    *) url="$1"; shift ;;
  esac
done
if [ -n "$write_out" ]; then
  printf '%s' 'https://github.com/LockInTime/headless/releases/tag/v9.8.7'
else
  cp "$INSTALLER_FIXTURES/${url##*/}" "$output"
fi
EOF
chmod 0755 "$TOOLS/uname" "$TOOLS/curl"

cat > "$BUNDLE/headless" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "runtime" ]; then
  printf '%s\n' '{"engine":"chromium","executable":"/fixture/chromium","supported":true}'
  exit 0
fi
exit 64
EOF
printf '#!/bin/sh\nexit 0\n' > "$BUNDLE/headless-host"
printf '#!/bin/sh\nexit 0\n' > "$BUNDLE/headless-mcp"
printf '#!/bin/sh\nexit 0\n' > "$ROOT/ffmpeg"
printf 'fixture runtime\n' > "$BUNDLE/Headless_HeadlessProtocol.resources/AgentRuntime.js"
printf 'P1\n' > "$BUNDLE/P1.md"
printf 'P2\n' > "$BUNDLE/P2.md"
cp install-linux.sh "$BUNDLE/install-linux.sh"
chmod 0755 "$BUNDLE/headless" "$BUNDLE/headless-host" "$BUNDLE/headless-mcp" \
  "$BUNDLE/install-linux.sh" "$ROOT/ffmpeg"

ASSET="headless-9.8.7-linux-amd64.tar.gz"
tar -czf "$RELEASE/$ASSET" -C "$BUNDLE" \
  headless headless-host headless-mcp Headless_HeadlessProtocol.resources install-linux.sh P1.md P2.md
if command -v sha256sum >/dev/null 2>&1; then
  (cd "$RELEASE" && sha256sum "$ASSET") > "$RELEASE/SHA256SUMS"
else
  (cd "$RELEASE" && shasum -a 256 "$ASSET") > "$RELEASE/SHA256SUMS"
fi

run_installer() {
  PATH="$TOOLS:$PATH" INSTALLER_FIXTURES="$RELEASE" \
    HEADLESS_FFMPEG_EXECUTABLE="$ROOT/ffmpeg" "$@"
}

PREFIX_EXPLICIT="$ROOT/explicit"
EXPLICIT_OUTPUT="$(run_installer env HEADLESS_VERSION=9.8.7 sh install.sh --prefix "$PREFIX_EXPLICIT")"
grep -q "Headless installed" <<< "$EXPLICIT_OUTPUT"
test -x "$PREFIX_EXPLICIT/bin/headless"
test -x "$PREFIX_EXPLICIT/bin/headless-host"
test -x "$PREFIX_EXPLICIT/bin/headless-mcp"
test -r "$PREFIX_EXPLICIT/bin/Headless_HeadlessProtocol.resources/AgentRuntime.js"

PREFIX_LATEST="$ROOT/latest"
LATEST_OUTPUT="$(run_installer env -u HEADLESS_VERSION sh install.sh --prefix "$PREFIX_LATEST")"
grep -q "Headless installed" <<< "$LATEST_OUTPUT"
test -x "$PREFIX_LATEST/bin/headless"

cp "$RELEASE/$ASSET" "$RELEASE/original.tar.gz"
printf 'corruption\n' >> "$RELEASE/$ASSET"
if run_installer env HEADLESS_VERSION=9.8.7 sh install.sh --prefix "$ROOT/corrupt" >/dev/null 2>&1; then
  echo "bootstrap accepted a release with a mismatched checksum" >&2
  exit 1
fi
mv "$RELEASE/original.tar.gz" "$RELEASE/$ASSET"

cp "$RELEASE/$ASSET" "$RELEASE/safe.tar.gz"
printf 'unexpected\n' > "$BUNDLE/unexpected"
tar -czf "$RELEASE/$ASSET" -C "$BUNDLE" \
  headless headless-host headless-mcp Headless_HeadlessProtocol.resources install-linux.sh P1.md P2.md unexpected
if command -v sha256sum >/dev/null 2>&1; then
  (cd "$RELEASE" && sha256sum "$ASSET") > "$RELEASE/SHA256SUMS"
else
  (cd "$RELEASE" && shasum -a 256 "$ASSET") > "$RELEASE/SHA256SUMS"
fi
if run_installer env HEADLESS_VERSION=9.8.7 sh install.sh --prefix "$ROOT/unexpected" >/dev/null 2>&1; then
  echo "bootstrap accepted an unexpected archive path" >&2
  exit 1
fi
mv "$RELEASE/safe.tar.gz" "$RELEASE/$ASSET"

if run_installer env FAKE_ARCH=riscv64 HEADLESS_VERSION=9.8.7 sh install.sh \
    --prefix "$ROOT/unsupported" >/dev/null 2>&1; then
  echo "bootstrap accepted an unsupported architecture" >&2
  exit 1
fi
for invalid_version in 09.8.7 9.08.7 9.8.07 9.8.7-01 9.8.7-.beta 9.8.7-beta. 9.8.7+build..1; do
  if run_installer env HEADLESS_VERSION="$invalid_version" sh install.sh \
      --prefix "$ROOT/version" >/dev/null 2>&1; then
    echo "bootstrap accepted an invalid semantic version: $invalid_version" >&2
    exit 1
  fi
done
if PATH="$TOOLS:$PATH" HEADLESS_FFMPEG_EXECUTABLE=relative/ffmpeg \
    HEADLESS_CHROMIUM_EXECUTABLE=/fixture/chromium \
    sh "$BUNDLE/install-linux.sh" --prefix "$ROOT/ffmpeg-relative" >/dev/null 2>&1; then
  echo "package installer accepted a relative FFmpeg override" >&2
  exit 1
fi

echo "Linux bootstrap installer tests passed"
