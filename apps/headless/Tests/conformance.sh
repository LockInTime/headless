#!/bin/sh
# One portable scenario run unchanged against WebKit and Chromium. It locks
# the common HostCore response shapes and consults the declared engine profile
# only where the contract intentionally differs.
set -eu

: "${HEADLESS_CONFORMANCE_CLI:?set HEADLESS_CONFORMANCE_CLI to the built headless CLI}"
: "${HEADLESS_CONFORMANCE_ENGINE:?set HEADLESS_CONFORMANCE_ENGINE to webkit or chromium}"
: "${HEADLESS_CONFORMANCE_BASE_URL:?set HEADLESS_CONFORMANCE_BASE_URL to the fixture origin}"

CLI="$HEADLESS_CONFORMANCE_CLI"
ENGINE="$HEADLESS_CONFORMANCE_ENGINE"
BASE_URL="${HEADLESS_CONFORMANCE_BASE_URL%/}"
SESSION="conformance-$ENGINE-$$"
PREFIX="conformance-$ENGINE-$$"

case "$ENGINE" in
  webkit|chromium) ;;
  *) echo "conformance: unsupported engine: $ENGINE" >&2; exit 2 ;;
esac

fail() {
  echo "cross-engine conformance failed ($ENGINE): $1" >&2
  exit 1
}

assert_field() {
  printf '%s' "$1" | grep -q '"'"$2"'":' || fail "missing JSON field: $2"
}

assert_value() {
  printf '%s' "$1" | grep -q "$2" || fail "missing JSON value: $2"
}

cleanup() {
  "$CLI" session close "$SESSION" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

CAPABILITIES="$("$CLI" capabilities)"
assert_value "$CAPABILITIES" '"currentEngine":"'"$ENGINE"'"'
assert_field "$CAPABILITIES" engines
assert_value "$CAPABILITIES" '"webkit"'
assert_value "$CAPABILITIES" '"chromium"'

PING="$("$CLI" status)"
assert_value "$PING" '"ready":true'
assert_value "$PING" '"engine":"'"$ENGINE"'"'
for field in protocolVersion capabilities artifactDirectory recordingAvailable; do
  assert_field "$PING" "$field"
done

"$CLI" session create "$SESSION" | grep -q '"session":"'"$SESSION"'"'
"$CLI" session list | grep -q '"'"$SESSION"'"'

if EMPTY_BACK="$("$CLI" --session "$SESSION" back 2>&1)"; then
  fail "back without history unexpectedly succeeded"
fi
assert_value "$EMPTY_BACK" '"code":"OPERATION_FAILED"'

VISIT="$("$CLI" --session "$SESSION" visit "$BASE_URL/designers/dashboard")"
for field in url title readyState; do assert_field "$VISIT" "$field"; done
assert_value "$VISIT" 'Designers Dashboard'

INSPECT="$("$CLI" --session "$SESSION" inspect --context actions --task 'click Continue')"
for field in url title contextMode task elements contextStats omitted truncated untrustedContent; do
  assert_field "$INSPECT" "$field"
done
assert_value "$INSPECT" '"contextMode":"actions"'
assert_value "$INSPECT" '"name":"Continue"'

WAITED="$("$CLI" --session "$SESSION" wait --settled --timeout 10000)"
for field in url title readyState; do assert_field "$WAITED" "$field"; done
"$CLI" --session "$SESSION" press Escape | grep -q '"pressed":"Escape"'

CAPTURE="$("$CLI" --session "$SESSION" capture-info)"
for field in engine page trace recording; do assert_field "$CAPTURE" "$field"; done
assert_value "$CAPTURE" '"engine":"'"$ENGINE"'"'
assert_value "$CAPTURE" '"active":false'

CONSOLE="$("$CLI" --session "$SESSION" console list --level error)"
for field in untrustedContent messages returned available; do assert_field "$CONSOLE" "$field"; done
NETWORK="$("$CLI" --session "$SESSION" network list)"
for field in untrustedContent requests returned available; do assert_field "$NETWORK" "$field"; done
QA="$("$CLI" --session "$SESSION" qa report)"
for field in untrustedContent summary issues events omitted truncated; do assert_field "$QA" "$field"; done

STYLES="$("$CLI" --session "$SESSION" styles get --role region --name 'Diagnostics probe' --property display)"
for field in ref role name box styles; do assert_field "$STYLES" "$field"; done
assert_value "$STYLES" '"display":"flex"'
COOKIES="$("$CLI" --session "$SESSION" cookies list)"
for field in cookies returned available truncated source; do assert_field "$COOKIES" "$field"; done
assert_value "$COOKIES" '"name":"qa_session"'
STORAGE="$("$CLI" --session "$SESSION" storage list)"
for field in origin stores; do assert_field "$STORAGE" "$field"; done
assert_value "$STORAGE" '"scope":"local"'
assert_value "$STORAGE" '"scope":"session"'

PERFORMANCE="$("$CLI" --session "$SESSION" performance get)"
for field in url timing resources webVitals caveat; do assert_field "$PERFORMANCE" "$field"; done
ANIMATIONS="$("$CLI" --session "$SESSION" animations list)"
for field in count animations truncated; do assert_field "$ANIMATIONS" "$field"; done

SCREENSHOT="$("$CLI" --session "$SESSION" screenshot --output "$PREFIX.png")"
for field in name path kind bytes createdAt; do assert_field "$SCREENSHOT" "$field"; done
assert_value "$SCREENSHOT" '"name":"'"$PREFIX"'.png"'

"$CLI" --session "$SESSION" flow start | grep -q '"recording":true'
"$CLI" --session "$SESSION" visit "$BASE_URL/designers/dashboard" >/dev/null
"$CLI" --session "$SESSION" click --role button --name Continue | grep -q '"clicked"'
FLOW="$("$CLI" --session "$SESSION" flow stop --output "$PREFIX-flow.json")"
for field in name path kind bytes createdAt; do assert_field "$FLOW" "$field"; done
FLOW_RUN="$("$CLI" --session "$SESSION" flow run "$PREFIX-flow.json")"
assert_value "$FLOW_RUN" '"completed":2'
assert_field "$FLOW_RUN" input

REPORT="$("$CLI" --session "$SESSION" report create --output "$PREFIX-report.json")"
for field in name path kind bytes createdAt; do assert_field "$REPORT" "$field"; done

case "$ENGINE" in
  chromium)
    assert_value "$PING" '"networkEmulation":true'
    EMULATION="$("$CLI" --session "$SESSION" network emulate --latency 25)"
    assert_value "$EMULATION" '"latencyMs":25'
    ;;
  webkit)
    assert_value "$PING" '"networkEmulation":false'
    if EMULATION="$("$CLI" --session "$SESSION" network emulate --latency 25 2>&1)"; then
      fail "declared-unsupported network emulation succeeded"
    fi
    assert_value "$EMULATION" '"code":"UNSUPPORTED_CAPABILITY"'
    ;;
esac

"$CLI" session close "$SESSION" | grep -q '"closed":"'"$SESSION"'"'
if CLOSED="$("$CLI" --session "$SESSION" inspect 2>&1)"; then
  fail "closed session remained reachable"
fi
assert_value "$CLOSED" '"code":"SESSION_NOT_FOUND"'
trap - EXIT INT TERM

echo "Cross-engine conformance passed ($ENGINE)"
