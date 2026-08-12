#!/bin/sh
set -eu

PLIST="${1:?usage: macos-bundle-security.sh /path/to/Info.plist}"

fail() {
  echo "macOS bundle security: $1" >&2
  exit 1
}

command -v plutil >/dev/null 2>&1 || fail "plutil is required"
plutil -lint "$PLIST" >/dev/null || fail "Info.plist is invalid"

if plutil -extract NSAppTransportSecurity.NSAllowsArbitraryLoads raw "$PLIST" >/dev/null 2>&1; then
  fail "NSAllowsArbitraryLoads must not disable ATS for the entire app"
fi

WEB_CONTENT_EXCEPTION="$(
  plutil -extract NSAppTransportSecurity.NSAllowsArbitraryLoadsInWebContent raw "$PLIST" 2>/dev/null
)" || fail "the WKWebView-scoped ATS exception is missing"
test "$WEB_CONTENT_EXCEPTION" = "true" || fail "the WKWebView-scoped ATS exception must be true"

echo "macOS bundle ATS configuration passed"
