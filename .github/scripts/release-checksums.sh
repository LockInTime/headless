#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
  echo "usage: release-checksums.sh VERSION DIST_DIRECTORY" >&2
  exit 64
fi

VERSION="$1"
DIST_DIRECTORY="$2"

case "$VERSION" in
  ""|[!0-9A-Za-z]*|*[!0-9A-Za-z.-]*|*..*|*.)
    echo "release checksums: invalid version: $VERSION" >&2
    exit 64
    ;;
esac
if [ "${#VERSION}" -gt 64 ]; then
  echo "release checksums: version is too long" >&2
  exit 64
fi
if [ ! -d "$DIST_DIRECTORY" ]; then
  echo "release checksums: dist directory does not exist: $DIST_DIRECTORY" >&2
  exit 66
fi

DIST_DIRECTORY="$(CDPATH='' cd -- "$DIST_DIRECTORY" && pwd -P)"
set -- \
  "Headless-${VERSION}-macos.zip" \
  "headless-${VERSION}-linux-amd64.tar.gz" \
  "headless-${VERSION}-linux-arm64.tar.gz"

for asset in "$@"; do
  path="$DIST_DIRECTORY/$asset"
  if [ ! -f "$path" ] || [ -L "$path" ] || [ ! -s "$path" ]; then
    echo "release checksums: missing or unsafe release asset: $asset" >&2
    exit 66
  fi
done

checksum_files() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$@"
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$@"
  else
    echo "release checksums: sha256sum or shasum is required" >&2
    exit 69
  fi
}

verify_manifest() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -c SHA256SUMS
  else
    shasum -a 256 -c SHA256SUMS
  fi
}

MANIFEST="$DIST_DIRECTORY/SHA256SUMS"
TEMP_MANIFEST="$(mktemp "$DIST_DIRECTORY/.SHA256SUMS.XXXXXX")"
trap '[ -z "$TEMP_MANIFEST" ] || rm -f "$TEMP_MANIFEST"' EXIT INT TERM

(
  cd "$DIST_DIRECTORY"
  checksum_files "$@"
) > "$TEMP_MANIFEST"
chmod 0644 "$TEMP_MANIFEST"
mv -f "$TEMP_MANIFEST" "$MANIFEST"
TEMP_MANIFEST=""

(
  cd "$DIST_DIRECTORY"
  verify_manifest
)
