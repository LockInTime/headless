#!/bin/sh
set -eu

export HEADLESS_ARTIFACT_DIR="/tmp/headless-artifacts-e2e-$$"

FIXTURE_ROOT="$(mktemp -d /tmp/headless-fixture.XXXXXX)"
INSTALL_ROOT="$(mktemp -d /tmp/headless-install.XXXXXX)"
mkdir -p "$FIXTURE_ROOT/designers/dashboard" "$FIXTURE_ROOT/next" "$FIXTURE_ROOT/hostile" "$FIXTURE_ROOT/api"
cp /opt/headless/fixtures/dashboard.html "$FIXTURE_ROOT/designers/dashboard/index.html"
cp /opt/headless/fixtures/next.html "$FIXTURE_ROOT/next/index.html"
cp /opt/headless/fixtures/hostile.html "$FIXTURE_ROOT/hostile/index.html"
cp /opt/headless/fixtures/api-diagnostic.json "$FIXTURE_ROOT/api/diagnostic"
busybox httpd -f -p 127.0.0.1:41739 -h "$FIXTURE_ROOT" &
FIXTURE_PID=$!

cleanup() {
  headless stop >/dev/null 2>&1 || true
  kill "$FIXTURE_PID" >/dev/null 2>&1 || true
  rm -rf "$FIXTURE_ROOT"
  rm -rf "$INSTALL_ROOT"
  rm -rf "$HEADLESS_ARTIFACT_DIR"
}
trap cleanup EXIT INT TERM

/opt/headless/package/install-linux.sh --prefix "$INSTALL_ROOT" | grep -q 'Headless installed'
test -x "$INSTALL_ROOT/bin/headless"
test -x "$INSTALL_ROOT/bin/headless-host"
if /opt/headless/package/install-linux.sh --prefix relative/path >/dev/null 2>&1; then
  echo "relative install prefix was not rejected" >&2
  exit 1
fi

headless start | grep -q '"ready":true'

# The fixture server is the only TCP listener. Chromium control must stay on
# its inherited DevTools pipe rather than exposing a loopback debugging port.
UNEXPECTED_TCP="$(awk 'NR > 1 && $4 == "0A" && $2 !~ /:A30B$/ { print $2 }' /proc/net/tcp /proc/net/tcp6)"
test -z "$UNEXPECTED_TCP"

headless session create qa | grep -q '"session":"qa"'
headless session list | grep -q '"qa"'
headless --session qa visit http://127.0.0.1:41739/designers/dashboard/ | grep -q 'Designers Dashboard'
SNAPSHOT="$(headless --session qa inspect --interactive --text)"
echo "$SNAPSHOT" | grep -q '"name":"Continue"'
echo "$SNAPSHOT" | grep -q '"name":"Reviewer"'
! echo "$SNAPSHOT" | grep -q '"pwned":true'
CONSOLE="$(headless --session qa console list --level error)"
echo "$CONSOLE" | grep -q 'Next.js runtime error'
NETWORK="$(headless --session qa network list)"
echo "$NETWORK" | grep -q '"requestId"'
NETWORK_ID="$(echo "$NETWORK" | sed -n 's/.*"requestId":"\([^"]*\)"[^}]*"url":"[^"]*\/api\/diagnostic".*/\1/p')"
test -n "$NETWORK_ID"
NETWORK_DETAIL="$(headless --session qa network get "$NETWORK_ID")"
echo "$NETWORK_DETAIL" | grep -q '"requestHeaders"'
echo "$NETWORK_DETAIL" | grep -q '\[redacted\]'
STYLES="$(headless --session qa styles get --role region --name 'Diagnostics probe' --property display)"
echo "$STYLES" | grep -q '"display":"flex"'
COOKIES="$(headless --session qa cookies list)"
echo "$COOKIES" | grep -q '"name":"qa_session"'
echo "$COOKIES" | grep -q '"valueBytes"'
STORAGE="$(headless --session qa storage list)"
echo "$STORAGE" | grep -q 'qa-diagnostic-key'
echo "$STORAGE" | grep -q 'qa-session-key'
if SENSITIVE_STORAGE="$(headless --session qa storage list --values)"; then
  echo "sensitive storage values were available without opt-in" >&2
  exit 1
fi
echo "$SENSITIVE_STORAGE" | grep -q 'SENSITIVE_DIAGNOSTICS_DISABLED'
QA_REPORT="$(headless --session qa qa report)"
echo "$QA_REPORT" | grep -q '"kind":"console"'
echo "$QA_REPORT" | grep -q '"status":404'
echo "$QA_REPORT" | grep -q '"kind":"framework-error"'
echo "$QA_REPORT" | grep -q '"kind":"local-not-found"'
headless --session qa qa clear | grep -q '"cleared"'
headless --session qa qa report | grep -q '"events":0'
headless --session qa fill @e1 'Ada Lovelace' | grep -q '"valueLength":12'
headless --session qa press Escape | grep -q '"pressed":"Escape"'
if EXTERNAL_RESULT="$(headless --session qa click --role link --name 'External application')"; then
  echo "external application link was not blocked" >&2
  exit 1
fi
echo "$EXTERNAL_RESULT" | grep -q 'UNSAFE_NAVIGATION'
if NON_WEB_RESULT="$(headless --session qa click --role link --name 'Non-web browser URL')"; then
  echo "non-HTTP browser URL was not blocked" >&2
  exit 1
fi
echo "$NON_WEB_RESULT" | grep -q 'UNSAFE_NAVIGATION'
if CREDENTIAL_RESULT="$(headless --session qa click --role link --name 'Credential-bearing URL')"; then
  echo "credential-bearing browser URL was not blocked" >&2
  exit 1
fi
echo "$CREDENTIAL_RESULT" | grep -q 'UNSAFE_NAVIGATION'
if SUSPICIOUS_RESULT="$(headless --session qa click --role link --name 'Suspicious installer')"; then
  echo "suspicious installer link was not blocked" >&2
  exit 1
fi
echo "$SUSPICIOUS_RESULT" | grep -q 'UNSAFE_RESOURCE_TYPE'
headless --session qa click --role button --name 'Scripted non-web navigation' | grep -q '"clicked"'
headless --session qa wait --url /designers/dashboard --settled --timeout 10000 | grep -q 'Designers Dashboard'
headless --session qa screenshot --output viewport.png | grep -q '"name":"viewport.png"'
headless --session qa screenshot --full-page --output full-page.png | grep -q '"name":"full-page.png"'
headless --session qa screenshot --role button --name Continue --output continue.png | grep -q '"name":"continue.png"'
headless --session qa visual compare viewport.png viewport.png --output visual-diff.png | grep -q '"name":"visual-diff.png"'
test -s "$HEADLESS_ARTIFACT_DIR/visual-diff.png"
headless --session qa performance get | grep -q '"webVitals"'
headless --session qa animations list | grep -q '"animations"'
headless --session qa network emulate --latency 25 --download-kbps 1000 --upload-kbps 500 | grep -q '"latencyMs":25'
headless --session qa network emulate | grep -q '"offline":false'
headless --session qa network mock set http://127.0.0.1:41739/api/diagnostic --body '{"mocked":true}' --status 201 | grep -q '"activeMocks":1'
# An active mock must not pause unrelated document and asset requests. This
# reload exercises the mocked API while the dashboard itself remains live.
headless --session qa reload | grep -q 'Designers Dashboard'
headless --session qa network mock clear | grep -q '"cleared":1'
headless --session qa flow start | grep -q '"recording":true'
headless --session qa visit http://127.0.0.1:41739/designers/dashboard/ | grep -q 'Designers Dashboard'
headless --session qa click --role button --name Continue | grep -q '"clicked"'
headless --session qa flow stop --output dashboard-flow.json | grep -q '"name":"dashboard-flow.json"'
headless --session qa flow run dashboard-flow.json | grep -q '"completed":2'
headless --session qa report create --output pr-report.json | grep -q '"name":"pr-report.json"'
grep -q 'headless-qa-report-v1' "$HEADLESS_ARTIFACT_DIR/pr-report.json"
headless --session qa visit http://127.0.0.1:41739/designers/dashboard/ | grep -q 'Designers Dashboard'
test -s "$HEADLESS_ARTIFACT_DIR/viewport.png"
test -s "$HEADLESS_ARTIFACT_DIR/full-page.png"
test -s "$HEADLESS_ARTIFACT_DIR/continue.png"
set -- $(od -An -tu1 -j 20 -N 4 "$HEADLESS_ARTIFACT_DIR/viewport.png")
VIEWPORT_HEIGHT=$(($1 * 16777216 + $2 * 65536 + $3 * 256 + $4))
set -- $(od -An -tu1 -j 20 -N 4 "$HEADLESS_ARTIFACT_DIR/full-page.png")
FULL_HEIGHT=$(($1 * 16777216 + $2 * 65536 + $3 * 256 + $4))
test "$FULL_HEIGHT" -gt "$VIEWPORT_HEIGHT"
if headless --session qa screenshot --output viewport.png >/dev/null 2>&1; then
  echo "artifact overwrite was not rejected" >&2
  exit 1
fi
if headless screenshot --output ../escape.png >/dev/null 2>&1; then
  echo "artifact path traversal was not rejected" >&2
  exit 1
fi
headless --session qa record start --fps 5 | grep -q '"active":true'
headless --session qa record status | grep -q '"active":true'
if headless --session qa record start >/dev/null 2>&1; then
  echo "a second recording was not rejected" >&2
  exit 1
fi
headless --session qa tour --full-page --pace 5000 | grep -q '"durationMs"'
headless --session qa click --role button --name Continue | grep -q '"clicked"'
if ! NEXT_PAGE="$(headless --session qa wait --url /next --text 'Designer details' --settled --timeout 10000)"; then
  echo "$NEXT_PAGE" >&2
  exit 1
fi
echo "$NEXT_PAGE" | grep -q 'Designer Details'
headless --session qa tour --full-page --pace 5000 | grep -q '"durationMs"'
headless --session qa record stop --output dashboard-flow.mp4 | grep -q '"name":"dashboard-flow.mp4"'
headless --session qa record status | grep -q '"active":false'
test -s "$HEADLESS_ARTIFACT_DIR/dashboard-flow.mp4"
head -c 64 "$HEADLESS_ARTIFACT_DIR/dashboard-flow.mp4" | grep -q 'ftyp'
test "$(stat -c %a "$HEADLESS_ARTIFACT_DIR/dashboard-flow.mp4")" = "600"
headless artifacts list | grep -q '"name":"dashboard-flow.mp4"'
headless --session qa back | grep -q 'Designers Dashboard'
headless --session qa reload | grep -q 'Designers Dashboard'
headless --session qa capture-info | grep -q '"engine":"chromium"'
headless --session qa visit http://127.0.0.1:41739/hostile/ | grep -q 'Hostile output fixture'
BOUNDED_SNAPSHOT="$(headless --session qa inspect)"
echo "$BOUNDED_SNAPSHOT" | grep -q '"truncated":true'
test "$(printf %s "$BOUNDED_SNAPSHOT" | wc -c)" -lt 1048576
headless session close qa | grep -q '"closed":"qa"'

echo "Linux P2 end-to-end flow passed"
