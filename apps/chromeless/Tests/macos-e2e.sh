#!/bin/zsh
set -euo pipefail
cd "${0:a:h}/.."

for tool in node curl lsof; do
  command -v "$tool" >/dev/null 2>&1 || { echo "macOS E2E tests require $tool" >&2; exit 69; }
done

CLI="$PWD/Chromeless.app/Contents/Resources/bin/chromeless"
HOST="$PWD/Chromeless.app/Contents/MacOS/Chromeless"
[[ -x "$CLI" && -x "$HOST" ]] || { echo "Build Chromeless.app before macOS E2E tests" >&2; exit 1; }

PORT=$((43000 + RANDOM % 1000))
RUNTIME="/tmp/chromeless-$(id -u)"
export CHROMELESS_SOCKET="$RUNTIME/macos-e2e-$$.sock"
export CHROMELESS_ARTIFACT_DIR="$RUNTIME/artifacts-macos-e2e-$$"
export CHROMELESS_HOST_EXECUTABLE="$HOST"
export CHROMELESS_FIXTURE_PORT="$PORT"
LOG="$(mktemp "${TMPDIR:-/tmp}/chromeless-macos-e2e.XXXXXX")"

node Tests/fixture-server.mjs >"$LOG" 2>&1 &
FIXTURE_PID=$!

cleanup() {
  "$CLI" stop >/dev/null 2>&1 || true
  kill "$FIXTURE_PID" >/dev/null 2>&1 || true
  rm -rf "$CHROMELESS_ARTIFACT_DIR"
  rm -f "$LOG"
}
trap cleanup EXIT INT TERM

for _ in {1..100}; do
  curl -fsS "http://127.0.0.1:$PORT/designers/dashboard" >/dev/null 2>&1 && break
  sleep 0.05
done
curl -fsS "http://127.0.0.1:$PORT/designers/dashboard" >/dev/null

START_RESULT="$("$CLI" start)"
echo "$START_RESULT" | grep -q '"ready":true'
HOST_PID="$(echo "$START_RESULT" | sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p')"
test -n "$HOST_PID"
if lsof -nP -a -p "$HOST_PID" -iTCP -sTCP:LISTEN 2>/dev/null | grep -q LISTEN; then
  echo "Chromeless host opened an unexpected TCP listener" >&2
  exit 1
fi
"$CLI" session create qa | grep -q '"session":"qa"'
"$CLI" session list | grep -q '"qa"'
"$CLI" --session qa visit "http://127.0.0.1:$PORT/designers/dashboard" | grep -q 'Designers Dashboard'
SNAPSHOT="$("$CLI" --session qa inspect --interactive --text)"
echo "$SNAPSHOT" | grep -q '"name":"Continue"'
echo "$SNAPSHOT" | grep -q '"name":"Reviewer"'
! echo "$SNAPSHOT" | grep -q '"pwned":true'
CONSOLE="$("$CLI" --session qa console list --level error)"
echo "$CONSOLE" | grep -q 'Next.js runtime error'
NETWORK="$("$CLI" --session qa network list)"
echo "$NETWORK" | grep -q '"requestId"'
NETWORK_ID="$(echo "$NETWORK" | sed -n 's/.*"requestId":"\([^"]*\)"[^}]*"url":"[^"]*\/api\/diagnostic".*/\1/p')"
test -n "$NETWORK_ID"
NETWORK_DETAIL="$("$CLI" --session qa network get "$NETWORK_ID")"
echo "$NETWORK_DETAIL" | grep -q '"requestHeaders"'
echo "$NETWORK_DETAIL" | grep -q '\[redacted\]'
STYLES="$("$CLI" --session qa styles get --role region --name 'Diagnostics probe' --property display)"
echo "$STYLES" | grep -q '"display":"flex"'
COOKIES="$("$CLI" --session qa cookies list)"
echo "$COOKIES" | grep -q '"name":"qa_session"'
echo "$COOKIES" | grep -q '"valueBytes"'
STORAGE="$("$CLI" --session qa storage list)"
echo "$STORAGE" | grep -q 'qa-diagnostic-key'
echo "$STORAGE" | grep -q 'qa-session-key'
if SENSITIVE_STORAGE="$("$CLI" --session qa storage list --values)"; then
  echo "sensitive storage values were available without opt-in" >&2
  exit 1
fi
echo "$SENSITIVE_STORAGE" | grep -q 'SENSITIVE_DIAGNOSTICS_DISABLED'
QA_REPORT="$("$CLI" --session qa qa report)"
echo "$QA_REPORT" | grep -q '"kind":"console"'
echo "$QA_REPORT" | grep -q '"status":404'
echo "$QA_REPORT" | grep -q '"kind":"framework-error"'
echo "$QA_REPORT" | grep -q '"kind":"local-not-found"'
"$CLI" --session qa qa clear | grep -q '"cleared"'
"$CLI" --session qa qa report | grep -q '"events":0'
"$CLI" --session qa fill @e1 'Ada Lovelace' | grep -q '"valueLength":12'
"$CLI" --session qa press Escape | grep -q '"pressed":"Escape"'
if EXTERNAL_RESULT="$("$CLI" --session qa click --role link --name 'External application')"; then
  echo "external application link was not blocked" >&2
  exit 1
fi
echo "$EXTERNAL_RESULT" | grep -q 'UNSAFE_NAVIGATION'
if NON_WEB_RESULT="$("$CLI" --session qa click --role link --name 'Non-web browser URL')"; then
  echo "non-HTTP browser URL was not blocked" >&2
  exit 1
fi
echo "$NON_WEB_RESULT" | grep -q 'UNSAFE_NAVIGATION'
if CREDENTIAL_RESULT="$("$CLI" --session qa click --role link --name 'Credential-bearing URL')"; then
  echo "credential-bearing browser URL was not blocked" >&2
  exit 1
fi
echo "$CREDENTIAL_RESULT" | grep -q 'UNSAFE_NAVIGATION'
if SUSPICIOUS_RESULT="$("$CLI" --session qa click --role link --name 'Suspicious installer')"; then
  echo "suspicious installer link was not blocked" >&2
  exit 1
fi
echo "$SUSPICIOUS_RESULT" | grep -q 'UNSAFE_RESOURCE_TYPE'
"$CLI" --session qa click --role button --name 'Scripted non-web navigation' | grep -q '"clicked"'
"$CLI" --session qa wait --url /designers/dashboard --settled --timeout 10000 | grep -q 'Designers Dashboard'
"$CLI" --session qa screenshot --output viewport.png | grep -q '"name":"viewport.png"'
"$CLI" --session qa screenshot --full-page --output full-page.png | grep -q '"name":"full-page.png"'
"$CLI" --session qa screenshot --role button --name Continue --output continue.png | grep -q '"name":"continue.png"'
"$CLI" --session qa visual compare viewport.png viewport.png --output visual-diff.png | grep -q '"name":"visual-diff.png"'
test -s "$CHROMELESS_ARTIFACT_DIR/visual-diff.png"
"$CLI" --session qa performance get | grep -q '"webVitals"'
"$CLI" --session qa animations list | grep -q '"animations"'
if NETWORK_SIMULATION="$($CLI --session qa network emulate --latency 25)"; then
  echo "WebKit network emulation was unexpectedly exposed" >&2
  exit 1
fi
echo "$NETWORK_SIMULATION" | grep -q 'UNSUPPORTED_CAPABILITY'
"$CLI" --session qa flow start | grep -q '"recording":true'
"$CLI" --session qa visit "http://127.0.0.1:$PORT/designers/dashboard" | grep -q 'Designers Dashboard'
"$CLI" --session qa click --role button --name Continue | grep -q '"clicked"'
"$CLI" --session qa flow stop --output dashboard-flow.json | grep -q '"name":"dashboard-flow.json"'
"$CLI" --session qa flow run dashboard-flow.json | grep -q '"completed":2'
"$CLI" --session qa report create --output pr-report.json | grep -q '"name":"pr-report.json"'
grep -q 'chromeless-qa-report-v1' "$CHROMELESS_ARTIFACT_DIR/pr-report.json"
"$CLI" --session qa visit "http://127.0.0.1:$PORT/designers/dashboard" | grep -q 'Designers Dashboard'
test -s "$CHROMELESS_ARTIFACT_DIR/viewport.png"
test -s "$CHROMELESS_ARTIFACT_DIR/full-page.png"
test -s "$CHROMELESS_ARTIFACT_DIR/continue.png"
VIEWPORT_HEIGHT="$(sips -g pixelHeight "$CHROMELESS_ARTIFACT_DIR/viewport.png" | awk '/pixelHeight/ {print $2}')"
FULL_HEIGHT="$(sips -g pixelHeight "$CHROMELESS_ARTIFACT_DIR/full-page.png" | awk '/pixelHeight/ {print $2}')"
test "$FULL_HEIGHT" -gt "$VIEWPORT_HEIGHT"
if "$CLI" --session qa screenshot --output viewport.png >/dev/null 2>&1; then
  echo "artifact overwrite was not rejected" >&2
  exit 1
fi
if "$CLI" screenshot --output ../escape.png >/dev/null 2>&1; then
  echo "artifact path traversal was not rejected" >&2
  exit 1
fi
"$CLI" --session qa record start --fps 5 | grep -q '"active":true'
"$CLI" --session qa record status | grep -q '"active":true'
if "$CLI" --session qa record start >/dev/null 2>&1; then
  echo "a second recording was not rejected" >&2
  exit 1
fi
"$CLI" --session qa tour --full-page --pace 5000 | grep -q '"durationMs"'
"$CLI" --session qa click --role button --name Continue | grep -q '"clicked"'
"$CLI" --session qa wait --url /next --text 'Designer details' --settled --timeout 10000 | grep -q 'Designer Details'
"$CLI" --session qa tour --full-page --pace 5000 | grep -q '"durationMs"'
"$CLI" --session qa record stop --output dashboard-flow.mp4 | grep -q '"name":"dashboard-flow.mp4"'
"$CLI" --session qa record status | grep -q '"active":false'
test -s "$CHROMELESS_ARTIFACT_DIR/dashboard-flow.mp4"
file "$CHROMELESS_ARTIFACT_DIR/dashboard-flow.mp4" | grep -Eq 'ISO Media|MP4'
test "$(stat -f %Lp "$CHROMELESS_ARTIFACT_DIR/dashboard-flow.mp4")" = "600"
"$CLI" artifacts list | grep -q '"name":"dashboard-flow.mp4"'
"$CLI" --session qa back | grep -q 'Designers Dashboard'
"$CLI" --session qa reload | grep -q 'Designers Dashboard'
CAPTURE="$("$CLI" --session qa capture-info)"
echo "$CAPTURE" | grep -q '"engine":"webkit"'
echo "$CAPTURE" | grep -q '"windowId"'
echo "$CAPTURE" | grep -q '"trace"'
"$CLI" --session qa visit "http://127.0.0.1:$PORT/hostile" | grep -q 'Hostile output fixture'
BOUNDED_SNAPSHOT="$("$CLI" --session qa inspect)"
echo "$BOUNDED_SNAPSHOT" | grep -q '"truncated":true'
test "$(printf %s "$BOUNDED_SNAPSHOT" | wc -c)" -lt 1048576
"$CLI" session close qa | grep -q '"closed":"qa"'

echo "macOS P2 end-to-end flow passed"
