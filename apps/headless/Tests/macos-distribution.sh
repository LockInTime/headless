#!/bin/sh
set -eu

if [ "$#" -ne 4 ]; then
  echo "usage: macos-distribution.sh APP VERSION SIGNATURE_MODE ARCHITECTURES" >&2
  exit 64
fi

APP="$1"
EXPECTED_VERSION="$2"
SIGNATURE_MODE="$3"
EXPECTED_ARCHITECTURES="$4"

fail() {
  echo "macOS distribution: $1" >&2
  exit 1
}

for tool in codesign file lipo plutil; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
done

[ -d "$APP" ] || fail "app bundle does not exist: $APP"
PLIST="$APP/Contents/Info.plist"
[ -f "$PLIST" ] || fail "Info.plist is missing"
ACTUAL_VERSION="$(plutil -extract CFBundleShortVersionString raw "$PLIST")"
[ "$ACTUAL_VERSION" = "$EXPECTED_VERSION" ] || fail "expected version $EXPECTED_VERSION, received $ACTUAL_VERSION"

EXECUTABLES="
$APP/Contents/MacOS/Headless
$APP/Contents/Resources/bin/headless
$APP/Contents/Resources/bin/headless-mcp
"
printf '%s\n' "$EXECUTABLES" | while IFS= read -r executable; do
  [ -n "$executable" ] || continue
  [ -x "$executable" ] || fail "missing executable: $executable"
  file "$executable" | grep -q 'Mach-O' || fail "not a Mach-O executable: $executable"
  ACTUAL_ARCHITECTURES="$(lipo -archs "$executable")"
  for architecture in $EXPECTED_ARCHITECTURES; do
    printf '%s\n' "$ACTUAL_ARCHITECTURES" | grep -Eq "(^| )$architecture( |$)" \
      || fail "$executable is missing $architecture"
  done
  for architecture in $ACTUAL_ARCHITECTURES; do
    printf '%s\n' "$EXPECTED_ARCHITECTURES" | grep -Eq "(^| )$architecture( |$)" \
      || fail "$executable contains unexpected architecture $architecture"
  done
  codesign --verify --strict "$executable" || fail "code signature verification failed: $executable"
  EXECUTABLE_SIGNATURE="$(codesign --display --verbose=4 "$executable" 2>&1)"
  case "$SIGNATURE_MODE" in
    adhoc)
      printf '%s\n' "$EXECUTABLE_SIGNATURE" | grep -q '^Signature=adhoc$' \
        || fail "expected an ad-hoc signature: $executable"
      ;;
    developer-id)
      printf '%s\n' "$EXECUTABLE_SIGNATURE" | grep -q '^Authority=Developer ID Application:' \
        || fail "expected a Developer ID Application signature: $executable"
      printf '%s\n' "$EXECUTABLE_SIGNATURE" | grep -q 'flags=.*runtime' \
        || fail "hardened runtime is not enabled: $executable"
      printf '%s\n' "$EXECUTABLE_SIGNATURE" | grep -q '^Timestamp=' \
        || fail "secure timestamp is missing: $executable"
      ;;
  esac
done

codesign --verify --deep --strict "$APP" || fail "code signature verification failed"
SIGNATURE_DETAILS="$(codesign --display --verbose=4 "$APP" 2>&1)"
ENTITLEMENTS="$(codesign --display --entitlements :- "$APP" 2>/dev/null || true)"
printf '%s\n' "$ENTITLEMENTS" | grep -q 'com.apple.security.get-task-allow' \
  && fail "get-task-allow is forbidden in a distribution build"

case "$SIGNATURE_MODE" in
  adhoc)
    printf '%s\n' "$SIGNATURE_DETAILS" | grep -q '^Signature=adhoc$' \
      || fail "expected an ad-hoc signature"
    ;;
  developer-id)
    printf '%s\n' "$SIGNATURE_DETAILS" | grep -q '^Authority=Developer ID Application:' \
      || fail "expected a Developer ID Application signature"
    printf '%s\n' "$SIGNATURE_DETAILS" | grep -q 'flags=.*runtime' \
      || fail "hardened runtime is not enabled"
    printf '%s\n' "$SIGNATURE_DETAILS" | grep -q '^Timestamp=' \
      || fail "secure timestamp is missing"
    ;;
  *) fail "unknown signature mode: $SIGNATURE_MODE" ;;
esac

if printf '%s\n' "$ENTITLEMENTS" | grep -q 'com.apple.developer.web-browser.public-key-credential'; then
  [ -f "$APP/Contents/embedded.provisionprofile" ] \
    || fail "passkey entitlement requires an embedded provisioning profile"
fi

echo "macOS distribution validation passed ($SIGNATURE_MODE; $EXPECTED_ARCHITECTURES)"
