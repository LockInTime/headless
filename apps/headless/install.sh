#!/bin/sh
set -eu

REPOSITORY="LockInTime/headless"
RELEASE_ROOT="https://github.com/$REPOSITORY/releases"

fail() {
  echo "headless bootstrap: $1" >&2
  exit "${2:-69}"
}

command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v tar >/dev/null 2>&1 || fail "tar is required"
[ "$(uname -s)" = "Linux" ] || fail "this installer is for Linux"

case "$(uname -m)" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) fail "unsupported architecture: $(uname -m)" ;;
esac

VERSION="${HEADLESS_VERSION:-}"
if [ -z "$VERSION" ]; then
  LATEST_URL="$(curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
    --output /dev/null --write-out '%{url_effective}' "$RELEASE_ROOT/latest")"
  TAG="${LATEST_URL##*/}"
  case "$TAG" in
    v*) VERSION="${TAG#v}" ;;
    *) fail "latest release did not resolve to a v-prefixed tag" ;;
  esac
fi
printf '%s\n' "$VERSION" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)(\.(0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*))?(\+([0-9A-Za-z-]+)(\.[0-9A-Za-z-]+)*)?$' \
  || fail "HEADLESS_VERSION must be a semantic version without a v prefix" 64

ASSET="headless-${VERSION}-linux-${ARCH}.tar.gz"
DOWNLOAD_ROOT="$RELEASE_ROOT/download/v${VERSION}"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/headless-bootstrap.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT INT TERM

download() {
  curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
    --output "$2" "$1"
}

download "$DOWNLOAD_ROOT/SHA256SUMS" "$TEMP_DIR/SHA256SUMS"
download "$DOWNLOAD_ROOT/$ASSET" "$TEMP_DIR/$ASSET"

EXPECTED="$(awk -v asset="$ASSET" '$2 == asset { print $1 }' "$TEMP_DIR/SHA256SUMS")"
[ "$(printf '%s\n' "$EXPECTED" | wc -l | tr -d ' ')" -eq 1 ] \
  || fail "SHA256SUMS must contain exactly one entry for $ASSET"
printf '%s\n' "$EXPECTED" | grep -Eq '^[0-9a-fA-F]{64}$' \
  || fail "SHA256SUMS contains an invalid digest for $ASSET"

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL="$(sha256sum "$TEMP_DIR/$ASSET" | awk '{ print $1 }')"
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL="$(shasum -a 256 "$TEMP_DIR/$ASSET" | awk '{ print $1 }')"
else
  fail "sha256sum or shasum is required to verify the release"
fi
[ "$ACTUAL" = "$EXPECTED" ] || fail "checksum verification failed for $ASSET"

CONTENTS="$TEMP_DIR/archive-contents"
tar -tzf "$TEMP_DIR/$ASSET" > "$CONTENTS"
EXPECTED_CONTENTS="$TEMP_DIR/expected-contents"
cat > "$EXPECTED_CONTENTS" <<'EOF'
Headless_HeadlessProtocol.resources/
Headless_HeadlessProtocol.resources/AgentRuntime.js
P1.md
P2.md
headless
headless-host
headless-mcp
install-linux.sh
EOF
LC_ALL=C sort -u "$CONTENTS" > "$CONTENTS.sorted"
LC_ALL=C sort -u "$EXPECTED_CONTENTS" > "$EXPECTED_CONTENTS.sorted"
cmp -s "$CONTENTS.sorted" "$EXPECTED_CONTENTS.sorted" \
  || fail "release archive contains unexpected or missing paths"

tar -xzf "$TEMP_DIR/$ASSET" -C "$TEMP_DIR"
sh "$TEMP_DIR/install-linux.sh" "$@"
