#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
SCRIPT="../../.github/scripts/release-checksums.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/headless-release-checksums.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

VERSION="1.2.3-rc.1"
MACOS="Headless-${VERSION}-macos.zip"
AMD64="headless-${VERSION}-linux-amd64.tar.gz"
ARM64="headless-${VERSION}-linux-arm64.tar.gz"

printf 'macOS package\n' > "$TEST_ROOT/$MACOS"
printf 'Linux amd64 package\n' > "$TEST_ROOT/$AMD64"
printf 'Linux arm64 package\n' > "$TEST_ROOT/$ARM64"

"$SCRIPT" "$VERSION" "$TEST_ROOT" >/dev/null
test "$(wc -l < "$TEST_ROOT/SHA256SUMS" | tr -d ' ')" -eq 3
if [ "$(uname -s)" = "Darwin" ]; then
  test "$(stat -f %Lp "$TEST_ROOT/SHA256SUMS")" = "644"
else
  test "$(stat -c %a "$TEST_ROOT/SHA256SUMS")" = "644"
fi
awk '{print $2}' "$TEST_ROOT/SHA256SUMS" > "$TEST_ROOT/names"
printf '%s\n' "$MACOS" "$AMD64" "$ARM64" > "$TEST_ROOT/expected-names"
cmp -s "$TEST_ROOT/names" "$TEST_ROOT/expected-names"

if command -v sha256sum >/dev/null 2>&1; then
  (cd "$TEST_ROOT" && sha256sum -c SHA256SUMS >/dev/null)
else
  (cd "$TEST_ROOT" && shasum -a 256 -c SHA256SUMS >/dev/null)
fi

cp "$TEST_ROOT/SHA256SUMS" "$TEST_ROOT/original-manifest"
"$SCRIPT" "$VERSION" "$TEST_ROOT" >/dev/null
cmp -s "$TEST_ROOT/SHA256SUMS" "$TEST_ROOT/original-manifest"

rm "$TEST_ROOT/$ARM64"
if "$SCRIPT" "$VERSION" "$TEST_ROOT" >/dev/null 2>&1; then
  echo "release checksum test: missing assets must fail" >&2
  exit 1
fi
cmp -s "$TEST_ROOT/SHA256SUMS" "$TEST_ROOT/original-manifest"

ln -s "$AMD64" "$TEST_ROOT/$ARM64"
if "$SCRIPT" "$VERSION" "$TEST_ROOT" >/dev/null 2>&1; then
  echo "release checksum test: symlink assets must fail" >&2
  exit 1
fi

for invalid_version in '' '../1.2.3' '.1.2.3' '1.2.3/' '1..2' '1.2.3.' \
  'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; do
  if "$SCRIPT" "$invalid_version" "$TEST_ROOT" >/dev/null 2>&1; then
    echo "release checksum test: invalid version accepted: $invalid_version" >&2
    exit 1
  fi
done

echo "Release checksum tests passed"
