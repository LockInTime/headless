#!/bin/sh
set -eu

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
  echo "usage: macos-package.sh APP VERSION OUTPUT_DIRECTORY [--notarize]" >&2
  exit 64
fi

APP="$1"
VERSION="$2"
OUTPUT_DIRECTORY="$3"
MODE="${4:-}"
SCRIPT_DIRECTORY="$(CDPATH='' cd -- "$(dirname "$0")" && pwd -P)"
REPOSITORY_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIRECTORY/../.." && pwd -P)"

[ -d "$APP" ] || { echo "macOS package: app does not exist: $APP" >&2; exit 66; }
SEMVER_PATTERN="$(cat "$REPOSITORY_ROOT/apps/headless/VersionSupport/semver-pattern.txt")"
printf '%s\n' "$VERSION" | grep -Eq "$SEMVER_PATTERN" || {
  echo "macOS package: invalid semantic version: $VERSION" >&2
  exit 64
}
case "$MODE" in
  ""|--notarize) ;;
  *) echo "macOS package: unknown option: $MODE" >&2; exit 64 ;;
esac

mkdir -p "$OUTPUT_DIRECTORY"
OUTPUT_DIRECTORY="$(CDPATH='' cd -- "$OUTPUT_DIRECTORY" && pwd -P)"
APP="$(CDPATH='' cd -- "$(dirname "$APP")" && pwd -P)/$(basename "$APP")"
ARCHIVE="$OUTPUT_DIRECTORY/Headless-${VERSION}-macos.zip"

package_app() {
  ditto -c -k --keepParent "$APP" "$ARCHIVE"
  test -s "$ARCHIVE"
  unzip -t "$ARCHIVE" >/dev/null
  unzip -Z1 "$ARCHIVE" | grep -qx 'Headless.app/Contents/MacOS/Headless'
  unzip -Z1 "$ARCHIVE" | grep -qx 'Headless.app/Contents/Resources/bin/headless'
  unzip -Z1 "$ARCHIVE" | grep -qx 'Headless.app/Contents/Resources/bin/headless-mcp'
}

if [ "$MODE" = "--notarize" ]; then
  : "${APPLE_NOTARY_KEY_PATH:?macOS package: APPLE_NOTARY_KEY_PATH is required}"
  : "${APPLE_NOTARY_KEY_ID:?macOS package: APPLE_NOTARY_KEY_ID is required}"
  : "${APPLE_NOTARY_ISSUER_ID:?macOS package: APPLE_NOTARY_ISSUER_ID is required}"
  [ -f "$APPLE_NOTARY_KEY_PATH" ] || {
    echo "macOS package: notary API key does not exist: $APPLE_NOTARY_KEY_PATH" >&2
    exit 66
  }
  for tool in codesign plutil spctl xcrun; do
    command -v "$tool" >/dev/null 2>&1 || { echo "macOS package: $tool is required" >&2; exit 69; }
  done
  "$REPOSITORY_ROOT/apps/headless/Tests/macos-distribution.sh" \
    "$APP" "$VERSION" developer-id "arm64 x86_64"
fi

package_app

if [ "$MODE" = "--notarize" ]; then
  NOTARY_RESPONSE="$(xcrun notarytool submit "$ARCHIVE" \
    --key "$APPLE_NOTARY_KEY_PATH" \
    --key-id "$APPLE_NOTARY_KEY_ID" \
    --issuer "$APPLE_NOTARY_ISSUER_ID" \
    --wait \
    --output-format json)"
  printf '%s\n' "$NOTARY_RESPONSE"
  NOTARY_STATUS="$(printf '%s\n' "$NOTARY_RESPONSE" | plutil -extract status raw -o - -)"
  [ "$NOTARY_STATUS" = "Accepted" ] || {
    echo "macOS package: Apple rejected the notarization submission ($NOTARY_STATUS)" >&2
    exit 1
  }
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  "$REPOSITORY_ROOT/apps/headless/Tests/macos-distribution.sh" \
    "$APP" "$VERSION" developer-id "arm64 x86_64"
  spctl --assess --type execute --verbose=4 "$APP"
  package_app
fi

echo "macOS package created: $ARCHIVE"
