#!/bin/zsh
set -euo pipefail
cd "${0:a:h}/.."

for tool in node curl defaults lsof; do
  command -v "$tool" >/dev/null 2>&1 || { echo "macOS E2E tests require $tool" >&2; exit 69; }
done

CLI="$PWD/Headless.app/Contents/Resources/bin/headless"
HOST="$PWD/Headless.app/Contents/MacOS/Headless"
[[ -x "$CLI" && -x "$HOST" ]] || { echo "Build Headless.app before macOS E2E tests" >&2; exit 1; }

PORT=$((43000 + RANDOM % 1000))
RUNTIME="/tmp/headless-$(id -u)"
mkdir -p "$RUNTIME"
chmod 700 "$RUNTIME"
export HEADLESS_SOCKET="$RUNTIME/macos-e2e-$$.sock"
export HEADLESS_ARTIFACT_DIR="$RUNTIME/artifacts-macos-e2e-$$"
export HEADLESS_HOST_EXECUTABLE="$HOST"
export HEADLESS_FIXTURE_PORT="$PORT"
LOG="$(mktemp "${TMPDIR:-/tmp}/headless-macos-e2e.XXXXXX")"
HOST_LOG="$(mktemp "${TMPDIR:-/tmp}/headless-macos-host.XXXXXX")"
RESTORE_LOG="$(mktemp "${TMPDIR:-/tmp}/headless-macos-restore.XXXXXX")"
export HEADLESS_HOST_LOG="$HOST_LOG"
STEP="boot"
RESTORE_PID=""
DEFAULTS_DOMAIN="com.headless.app"
DEFAULTS_HAD_LAST_URL=0
DEFAULTS_LAST_URL=""
if DEFAULTS_LAST_URL="$(defaults read "$DEFAULTS_DOMAIN" LastURL 2>/dev/null)"; then
  DEFAULTS_HAD_LAST_URL=1
fi

restore_last_url() {
  if [[ "$DEFAULTS_HAD_LAST_URL" == 1 ]]; then
    defaults write "$DEFAULTS_DOMAIN" LastURL -string "$DEFAULTS_LAST_URL"
  else
    defaults delete "$DEFAULTS_DOMAIN" LastURL >/dev/null 2>&1 || true
  fi
}

fail() {
  trap - ERR
  print -r -u2 -- "macOS E2E failed during: $STEP"
  print -r -u2 -- "---- fixture log ----"
  cat "$LOG" >&2 || true
  print -r -u2 -- "---- host log ----"
  cat "$HOST_LOG" >&2 || true
  print -r -u2 -- "---- restore log ----"
  cat "$RESTORE_LOG" >&2 || true
  exit 1
}
trap 'fail' ERR

node Tests/fixture-server.mjs >"$LOG" 2>&1 &
FIXTURE_PID=$!

cleanup() {
  "$CLI" stop >/dev/null 2>&1 || true
  if [[ -n "$RESTORE_PID" ]]; then
    kill "$RESTORE_PID" >/dev/null 2>&1 || true
  fi
  kill "$FIXTURE_PID" >/dev/null 2>&1 || true
  restore_last_url
  rm -rf "$HEADLESS_ARTIFACT_DIR"
  rm -f "$LOG" "$HOST_LOG" "$RESTORE_LOG"
}
trap cleanup EXIT INT TERM

STEP="fixture-server"
for _ in {1..100}; do
  curl -fsS "http://127.0.0.1:$PORT/designers/dashboard" >/dev/null 2>&1 && break
  sleep 0.05
done
curl -fsS "http://127.0.0.1:$PORT/designers/dashboard" >/dev/null

STEP="restored-url-fallback"
UNAVAILABLE_PORT=$((PORT + 2000))
if lsof -nP -iTCP:"$UNAVAILABLE_PORT" -sTCP:LISTEN 2>/dev/null | grep -q LISTEN; then
  echo "macOS E2E restore port is unexpectedly in use: $UNAVAILABLE_PORT" >&2
  fail
fi
RESTORED_URL="http://127.0.0.1:$UNAVAILABLE_PORT/restored"
defaults write "$DEFAULTS_DOMAIN" LastURL -string "$RESTORED_URL"
HEADLESS_AGENT_HOST=0 "$HOST" >"$RESTORE_LOG" 2>&1 &
RESTORE_PID=$!
for _ in {1..100}; do
  "$CLI" status >/dev/null 2>&1 && break
  sleep 0.05
done
"$CLI" status | grep -q '"ready":true'
RESTORED_URL_CLEARED=0
for _ in {1..300}; do
  if ! defaults read "$DEFAULTS_DOMAIN" LastURL >/dev/null 2>&1; then
    RESTORED_URL_CLEARED=1
    break
  fi
  sleep 0.05
done
if [[ "$RESTORED_URL_CLEARED" != 1 ]]; then
  echo "failed restored URL was not cleared" >&2
  "$CLI" qa report >&2 || true
  fail
fi
sleep 1
RESTORED_SNAPSHOT="$("$CLI" inspect --text)"
echo "$RESTORED_SNAPSHOT" | grep -q 'search or enter a url'
"$CLI" stop >/dev/null
for _ in {1..100}; do
  ! kill -0 "$RESTORE_PID" >/dev/null 2>&1 && break
  sleep 0.05
done
if kill -0 "$RESTORE_PID" >/dev/null 2>&1; then
  echo "manual restore-test host did not stop" >&2
  fail
fi
wait "$RESTORE_PID" || true
RESTORE_PID=""
restore_last_url
echo "▸ unavailable restored URL fell back to the start page"

STEP="start-host"
START_RESULT="$("$CLI" start)" || {
  print -r -u2 -- "headless start failed:"
  print -r -u2 -- "$START_RESULT"
  fail
}
echo "$START_RESULT" | grep -q '"ready":true' || {
  print -r -u2 -- "host did not become ready: $START_RESULT"
  fail
}
echo "▸ host ready"
STEP="tcp-check"
HOST_PID="$(echo "$START_RESULT" | sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p')"
test -n "$HOST_PID"
if lsof -nP -a -p "$HOST_PID" -iTCP -sTCP:LISTEN 2>/dev/null | grep -q LISTEN; then
  echo "Headless host opened an unexpected TCP listener" >&2
  fail
fi
STEP="session-visit"
"$CLI" session create qa | grep -q '"session":"qa"'
"$CLI" session list | grep -q '"qa"'
"$CLI" --session qa visit "http://127.0.0.1:$PORT/designers/dashboard" | grep -q 'Designers Dashboard'
STEP="inspect-diagnostics"
SNAPSHOT="$("$CLI" --session qa inspect --interactive --text)"
echo "$SNAPSHOT" | grep -q '"name":"Continue"'
echo "$SNAPSHOT" | grep -q '"name":"Reviewer"'
! echo "$SNAPSHOT" | grep -q '"pwned":true'
ACTION_SNAPSHOT="$("$CLI" --session qa inspect --context actions --task 'click Continue')"
echo "$ACTION_SNAPSHOT" | grep -q '"contextMode":"actions"'
echo "$ACTION_SNAPSHOT" | grep -q '"task":"click Continue"'
echo "$ACTION_SNAPSHOT" | grep -q '"name":"Continue"'
echo "$ACTION_SNAPSHOT" | grep -q '"actions":\["click"\]'
echo "$ACTION_SNAPSHOT" | grep -q '"relevance"'
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
  fail
fi
echo "$SENSITIVE_STORAGE" | grep -q 'SENSITIVE_DIAGNOSTICS_DISABLED'
STEP="qa-report"
QA_REPORT="$("$CLI" --session qa qa report)"
echo "$QA_REPORT" | grep -q '"kind":"console"'
echo "$QA_REPORT" | grep -q '"status":404'
echo "$QA_REPORT" | grep -q '"kind":"framework-error"'
echo "$QA_REPORT" | grep -q '"kind":"local-not-found"'
"$CLI" --session qa qa clear | grep -q '"cleared"'
"$CLI" --session qa qa report | grep -q '"events":0'
STEP="safe-input-navigation"
"$CLI" --session qa fill @e1 'Ada Lovelace' | grep -q '"valueLength":12'
"$CLI" --session qa press Escape | grep -q '"pressed":"Escape"'
STEP="safe-input-external-link"
if EXTERNAL_RESULT="$("$CLI" --session qa click --role link --name 'External application')"; then
  echo "external application link was not blocked" >&2
  fail
fi
echo "$EXTERNAL_RESULT" | grep -q 'UNSAFE_NAVIGATION'
STEP="safe-input-non-web-link"
if NON_WEB_RESULT="$("$CLI" --session qa click --role link --name 'Non-web browser URL')"; then
  echo "non-HTTP browser URL was not blocked" >&2
  fail
fi
echo "$NON_WEB_RESULT" | grep -q 'UNSAFE_NAVIGATION'
STEP="safe-input-credential-link"
if CREDENTIAL_RESULT="$("$CLI" --session qa click --role link --name 'Credential-bearing URL')"; then
  echo "credential-bearing browser URL was not blocked" >&2
  fail
fi
echo "$CREDENTIAL_RESULT" | grep -q 'UNSAFE_NAVIGATION'
STEP="safe-input-suspicious-link"
if SUSPICIOUS_RESULT="$("$CLI" --session qa click --role link --name 'Suspicious installer')"; then
  echo "suspicious installer link was not blocked" >&2
  fail
fi
echo "$SUSPICIOUS_RESULT" | grep -q 'UNSAFE_RESOURCE_TYPE'
STEP="safe-input-scripted-navigation"
"$CLI" --session qa click --role button --name 'Scripted non-web navigation' | grep -q '"clicked"'
"$CLI" --session qa wait --url /designers/dashboard --settled --timeout 10000 | grep -q 'Designers Dashboard'
STEP="safe-input-download"
"$CLI" --session qa click --role link --name 'Download fixture' | grep -q '"clicked"'
sleep 1
BLOCKED_DOWNLOAD_REPORT="$("$CLI" --session qa qa report)"
STEP="safe-input-download-report"
echo "$BLOCKED_DOWNLOAD_REPORT" | grep -q '"kind":"download-blocked"'
echo "$BLOCKED_DOWNLOAD_REPORT" | grep -q '/download.txt'
"$CLI" --session qa qa clear | grep -q '"cleared"'
STEP="artifacts-visual"
"$CLI" --session qa screenshot --output viewport.png | grep -q '"name":"viewport.png"'
"$CLI" --session qa screenshot --full-page --output full-page.png | grep -q '"name":"full-page.png"'
"$CLI" --session qa screenshot --role button --name Continue --output continue.png | grep -q '"name":"continue.png"'
"$CLI" --session qa screenshot --format jpg --output viewport.jpg --clipboard | grep -q '"clipboard":true'
"$CLI" --session qa screenshot --format pdf --full-page --output full-page.pdf | grep -q '"name":"full-page.pdf"'
VIEWPORT_SERIES="$("$CLI" --session qa screenshot --every-viewport --format jpg --output scroll-capture)"
echo "$VIEWPORT_SERIES" | grep -q '"series":"viewport"'
echo "$VIEWPORT_SERIES" | grep -q '"name":"scroll-capture-001.jpg"'
test -s "$HEADLESS_ARTIFACT_DIR/scroll-capture-001.jpg"
SCROLL_CAPTURE_COUNT="$(find "$HEADLESS_ARTIFACT_DIR" -maxdepth 1 -name 'scroll-capture-*.jpg' | wc -l | tr -d ' ')"
test "$SCROLL_CAPTURE_COUNT" -ge 2
SECTION_SERIES="$("$CLI" --session qa screenshot --by-section --output section-capture)"
echo "$SECTION_SERIES" | grep -q '"series":"section"'
SECTION_CAPTURE_COUNT="$(find "$HEADLESS_ARTIFACT_DIR" -maxdepth 1 -name 'section-capture-*.png' | wc -l | tr -d ' ')"
test "$SECTION_CAPTURE_COUNT" -ge 3
"$CLI" --session qa visual compare viewport.png viewport.png --output visual-diff.png | grep -q '"name":"visual-diff.png"'
test -s "$HEADLESS_ARTIFACT_DIR/visual-diff.png"
"$CLI" --session qa performance get | grep -q '"webVitals"'
ANIMATIONS="$("$CLI" --session qa animations list)"
echo "$ANIMATIONS" | grep -q '"animations"'
echo "$ANIMATIONS" | grep -q '"iterations":null'
STEP="network-emulate-unsupported"
if NETWORK_SIMULATION="$("$CLI" --session qa network emulate --latency 25)"; then
  echo "WebKit network emulation was unexpectedly exposed" >&2
  fail
fi
echo "$NETWORK_SIMULATION" | grep -q 'UNSUPPORTED_CAPABILITY'
STEP="flows-reports"
"$CLI" --session qa flow start | grep -q '"recording":true'
"$CLI" --session qa visit "http://127.0.0.1:$PORT/designers/dashboard" | grep -q 'Designers Dashboard'
"$CLI" --session qa click --role button --name Continue | grep -q '"clicked"'
"$CLI" --session qa flow stop --output dashboard-flow.json | grep -q '"name":"dashboard-flow.json"'
"$CLI" --session qa flow run dashboard-flow.json | grep -q '"completed":2'
"$CLI" --session qa report create --output pr-report.json | grep -q '"name":"pr-report.json"'
grep -q 'headless-qa-report-v1' "$HEADLESS_ARTIFACT_DIR/pr-report.json"
"$CLI" --session qa visit "http://127.0.0.1:$PORT/designers/dashboard" | grep -q 'Designers Dashboard'
test -s "$HEADLESS_ARTIFACT_DIR/viewport.png"
test -s "$HEADLESS_ARTIFACT_DIR/full-page.png"
test -s "$HEADLESS_ARTIFACT_DIR/continue.png"
test -s "$HEADLESS_ARTIFACT_DIR/viewport.jpg"
test -s "$HEADLESS_ARTIFACT_DIR/full-page.pdf"
test "$(xxd -p -l 3 "$HEADLESS_ARTIFACT_DIR/viewport.jpg")" = "ffd8ff"
head -c 5 "$HEADLESS_ARTIFACT_DIR/full-page.pdf" | grep -q '%PDF-'
VIEWPORT_HEIGHT="$(sips -g pixelHeight "$HEADLESS_ARTIFACT_DIR/viewport.png" | awk '/pixelHeight/ {print $2}')"
FULL_HEIGHT="$(sips -g pixelHeight "$HEADLESS_ARTIFACT_DIR/full-page.png" | awk '/pixelHeight/ {print $2}')"
test "$FULL_HEIGHT" -gt "$VIEWPORT_HEIGHT"
if "$CLI" --session qa screenshot --output viewport.png >/dev/null 2>&1; then
  echo "artifact overwrite was not rejected" >&2
  fail
fi
if "$CLI" screenshot --output ../escape.png >/dev/null 2>&1; then
  echo "artifact path traversal was not rejected" >&2
  fail
fi
STEP="recording"
"$CLI" --session qa record start --fps 5 | grep -q '"active":true'
"$CLI" --session qa record status | grep -q '"active":true'
if "$CLI" --session qa record start >/dev/null 2>&1; then
  echo "a second recording was not rejected" >&2
  fail
fi
"$CLI" --session qa tour --full-page --pace 5000 | grep -q '"durationMs"'
"$CLI" --session qa click --role button --name Continue | grep -q '"clicked"'
"$CLI" --session qa wait --url /next --text 'Designer details' --settled --timeout 10000 | grep -q 'Designer Details'
"$CLI" --session qa tour --full-page --pace 5000 | grep -q '"durationMs"'
"$CLI" --session qa record stop --output dashboard-flow.mp4 | grep -q '"name":"dashboard-flow.mp4"'
"$CLI" --session qa record status | grep -q '"active":false'
test -s "$HEADLESS_ARTIFACT_DIR/dashboard-flow.mp4"
file "$HEADLESS_ARTIFACT_DIR/dashboard-flow.mp4" | grep -Eq 'ISO Media|MP4'
test "$(stat -f %Lp "$HEADLESS_ARTIFACT_DIR/dashboard-flow.mp4")" = "600"
"$CLI" --session qa record start --fps 3 --format mov --quality fast | grep -q '"format":"mov"'
"$CLI" --session qa scroll top | grep -q '"direction":"top"'
"$CLI" --session qa tour --full-page --pace 5000 | grep -q '"durationMs"'
"$CLI" --session qa record stop --output dashboard-flow.mov | grep -q '"name":"dashboard-flow.mov"'
test -s "$HEADLESS_ARTIFACT_DIR/dashboard-flow.mov"
file "$HEADLESS_ARTIFACT_DIR/dashboard-flow.mov" | grep -Eq 'ISO Media|QuickTime'
"$CLI" artifacts list | grep -q '"name":"dashboard-flow.mp4"'
"$CLI" artifacts list | grep -q '"name":"dashboard-flow.mov"'
"$CLI" --session qa back | grep -q 'Designers Dashboard'
"$CLI" --session qa reload | grep -q 'Designers Dashboard'
STEP="capture-hostile"
CAPTURE="$("$CLI" --session qa capture-info)"
echo "$CAPTURE" | grep -q '"engine":"webkit"'
echo "$CAPTURE" | grep -q '"windowId"'
echo "$CAPTURE" | grep -q '"trace"'
STEP="progressive-context-pruning"
"$CLI" --session qa visit "http://127.0.0.1:$PORT/large-document" | grep -q 'Large Operations Handbook'
SUMMARY="$("$CLI" --session qa inspect --context summary --task 'Linux service-account authentication' --limit 8 --budget 700)"
echo "$SUMMARY" | grep -q '"contextMode":"summary"'
echo "$SUMMARY" | grep -q 'Linux service-account authentication'
echo "$SUMMARY" | grep -q '"budget":700'
test "$(printf %s "$SUMMARY" | wc -c)" -lt 3200
OUTLINE="$("$CLI" --session qa inspect --context outline --task 'Linux service-account authentication' --limit 8 --budget 900)"
TARGET_REGION="$(printf %s "$OUTLINE" | sed -n 's/.*"name":"Linux service-account authentication"[^}]*"ref":"\(@r[0-9]*\)".*/\1/p')"
test -n "$TARGET_REGION"
SCOPED_TEXT="$("$CLI" --session qa inspect --context text --within "$TARGET_REGION" --task 'Ubuntu service account' --limit 4 --budget 700)"
echo "$SCOPED_TEXT" | grep -q 'short-lived service account'
SCOPED_ACTIONS="$("$CLI" --session qa inspect --context actions --within "$TARGET_REGION" --task 'copy authentication command' --limit 5 --budget 700)"
echo "$SCOPED_ACTIONS" | grep -q '"name":"Copy authentication command"'
"$CLI" --session qa visit "http://127.0.0.1:$PORT/hostile" | grep -q 'Hostile output fixture'
BOUNDED_SNAPSHOT="$("$CLI" --session qa inspect)"
echo "$BOUNDED_SNAPSHOT" | grep -q '"truncated":true'
test "$(printf %s "$BOUNDED_SNAPSHOT" | wc -c)" -lt 1048576
HOSTILE_DIAGNOSTICS="$("$CLI" --session qa qa report)"
echo "$HOSTILE_DIAGNOSTICS" | grep -q 'hostile forged diagnostic'
echo "$HOSTILE_DIAGNOSTICS" | grep -q '"source":"webkit-page-bridge"'
echo "$HOSTILE_DIAGNOSTICS" | grep -q '"untrustedContent":true'
echo "$HOSTILE_DIAGNOSTICS" | grep -q '"events":500'
echo "$HOSTILE_DIAGNOSTICS" | grep -q '"truncated":true'
if echo "$HOSTILE_DIAGNOSTICS" | grep -q 'hostile-claims-trusted'; then
  echo "hostile page controlled diagnostic provenance" >&2
  fail
fi
"$CLI" session close qa | grep -q '"closed":"qa"'

echo "macOS P2 end-to-end flow passed"
