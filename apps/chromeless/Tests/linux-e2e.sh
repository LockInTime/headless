#!/bin/sh
set -eu

export CHROMELESS_ARTIFACT_DIR="/tmp/chromeless-artifacts-e2e-$$"

FIXTURE_ROOT="$(mktemp -d /tmp/chromeless-fixture.XXXXXX)"
INSTALL_ROOT="$(mktemp -d /tmp/chromeless-install.XXXXXX)"
mkdir -p "$FIXTURE_ROOT/designers/dashboard" "$FIXTURE_ROOT/next" "$FIXTURE_ROOT/hostile" "$FIXTURE_ROOT/api"
cp /opt/chromeless/fixtures/dashboard.html "$FIXTURE_ROOT/designers/dashboard/index.html"
cp /opt/chromeless/fixtures/next.html "$FIXTURE_ROOT/next/index.html"
cp /opt/chromeless/fixtures/hostile.html "$FIXTURE_ROOT/hostile/index.html"
cp /opt/chromeless/fixtures/api-diagnostic.json "$FIXTURE_ROOT/api/diagnostic"
busybox httpd -f -p 127.0.0.1:41739 -h "$FIXTURE_ROOT" &
FIXTURE_PID=$!

cleanup() {
  chromeless stop >/dev/null 2>&1 || true
  kill "$FIXTURE_PID" >/dev/null 2>&1 || true
  rm -rf "$FIXTURE_ROOT"
  rm -rf "$INSTALL_ROOT"
  rm -rf "$CHROMELESS_ARTIFACT_DIR"
}
trap cleanup EXIT INT TERM

/opt/chromeless/package/install-linux.sh --prefix "$INSTALL_ROOT" | grep -q 'Chromeless installed'
test -x "$INSTALL_ROOT/bin/chromeless"
test -x "$INSTALL_ROOT/bin/chromeless-host"
if /opt/chromeless/package/install-linux.sh --prefix relative/path >/dev/null 2>&1; then
  echo "relative install prefix was not rejected" >&2
  exit 1
fi
if SNAP_INSTALL="$(CHROMELESS_CHROMIUM_EXECUTABLE=/snap/bin/chromium \
    /opt/chromeless/package/install-linux.sh --prefix "$INSTALL_ROOT/snap" 2>&1)"; then
  echo "Snap Chromium was accepted by the installer" >&2
  exit 1
fi
echo "$SNAP_INSTALL" | grep -q 'Snap Chromium is not supported'

chromeless runtime | grep -q '"executable":"/usr/lib/chromium/chromium"'
chromeless runtime | grep -q '"transport":"inherited-devtools-pipe"'
if SNAP_RUNTIME="$(CHROMELESS_CHROMIUM_EXECUTABLE=/snap/bin/chromium chromeless runtime 2>&1)"; then
  echo "Snap Chromium was accepted by runtime selection" >&2
  exit 1
fi
echo "$SNAP_RUNTIME" | grep -q 'UNSUPPORTED_BROWSER_RUNTIME'
echo "$SNAP_RUNTIME" | grep -q 'Snap Chromium is not reliable'
if RELATIVE_RUNTIME="$(CHROMELESS_CHROMIUM_EXECUTABLE=relative/chromium chromeless runtime 2>&1)"; then
  echo "a relative Chromium override was accepted" >&2
  exit 1
fi
echo "$RELATIVE_RUNTIME" | grep -q 'must be absolute'

chromeless start | grep -q '"ready":true'

# The fixture server is the only TCP listener. Chromium control must stay on
# its inherited DevTools pipe rather than exposing a loopback debugging port.
UNEXPECTED_TCP="$(awk 'NR > 1 && $4 == "0A" && $2 !~ /:A30B$/ { print $2 }' /proc/net/tcp /proc/net/tcp6)"
test -z "$UNEXPECTED_TCP"

chromeless session create qa | grep -q '"session":"qa"'
chromeless session list | grep -q '"qa"'
chromeless --session qa visit http://127.0.0.1:41739/designers/dashboard/ | grep -q 'Designers Dashboard'
# Exercise the control-channel regression directly: the same session must
# survive a second document, reload that document, go back, and reload again.
chromeless --session qa visit http://127.0.0.1:41739/next/ | grep -q 'Designer Details'
chromeless --session qa reload | grep -q 'Designer Details'
chromeless --session qa back | grep -q 'Designers Dashboard'
chromeless --session qa reload | grep -q 'Designers Dashboard'
SNAPSHOT="$(chromeless --session qa inspect --interactive --text)"
echo "$SNAPSHOT" | grep -q '"name":"Continue"'
echo "$SNAPSHOT" | grep -q '"name":"Reviewer"'
! echo "$SNAPSHOT" | grep -q '"pwned":true'
CONSOLE="$(chromeless --session qa console list --level error)"
echo "$CONSOLE" | grep -q 'Next.js runtime error'
NETWORK="$(chromeless --session qa network list)"
echo "$NETWORK" | grep -q '"requestId"'
NETWORK_ID="$(echo "$NETWORK" | sed -n 's/.*"requestId":"\([^"]*\)"[^}]*"url":"[^"]*\/api\/diagnostic".*/\1/p')"
test -n "$NETWORK_ID"
NETWORK_DETAIL="$(chromeless --session qa network get "$NETWORK_ID")"
echo "$NETWORK_DETAIL" | grep -q '"requestHeaders"'
echo "$NETWORK_DETAIL" | grep -q '\[redacted\]'
STYLES="$(chromeless --session qa styles get --role region --name 'Diagnostics probe' --property display)"
echo "$STYLES" | grep -q '"display":"flex"'
COOKIES="$(chromeless --session qa cookies list)"
echo "$COOKIES" | grep -q '"name":"qa_session"'
echo "$COOKIES" | grep -q '"valueBytes"'
STORAGE="$(chromeless --session qa storage list)"
echo "$STORAGE" | grep -q 'qa-diagnostic-key'
echo "$STORAGE" | grep -q 'qa-session-key'
if SENSITIVE_STORAGE="$(chromeless --session qa storage list --values)"; then
  echo "sensitive storage values were available without opt-in" >&2
  exit 1
fi
echo "$SENSITIVE_STORAGE" | grep -q 'SENSITIVE_DIAGNOSTICS_DISABLED'
QA_REPORT="$(chromeless --session qa qa report)"
echo "$QA_REPORT" | grep -q '"kind":"console"'
echo "$QA_REPORT" | grep -q '"status":404'
echo "$QA_REPORT" | grep -q '"kind":"framework-error"'
echo "$QA_REPORT" | grep -q '"kind":"local-not-found"'
chromeless --session qa qa clear | grep -q '"cleared"'
chromeless --session qa qa report | grep -q '"events":0'
chromeless --session qa fill @e1 'Ada Lovelace' | grep -q '"valueLength":12'
chromeless --session qa press Escape | grep -q '"pressed":"Escape"'
if EXTERNAL_RESULT="$(chromeless --session qa click --role link --name 'External application')"; then
  echo "external application link was not blocked" >&2
  exit 1
fi
echo "$EXTERNAL_RESULT" | grep -q 'UNSAFE_NAVIGATION'
if NON_WEB_RESULT="$(chromeless --session qa click --role link --name 'Non-web browser URL')"; then
  echo "non-HTTP browser URL was not blocked" >&2
  exit 1
fi
echo "$NON_WEB_RESULT" | grep -q 'UNSAFE_NAVIGATION'
if CREDENTIAL_RESULT="$(chromeless --session qa click --role link --name 'Credential-bearing URL')"; then
  echo "credential-bearing browser URL was not blocked" >&2
  exit 1
fi
echo "$CREDENTIAL_RESULT" | grep -q 'UNSAFE_NAVIGATION'
if SUSPICIOUS_RESULT="$(chromeless --session qa click --role link --name 'Suspicious installer')"; then
  echo "suspicious installer link was not blocked" >&2
  exit 1
fi
echo "$SUSPICIOUS_RESULT" | grep -q 'UNSAFE_RESOURCE_TYPE'
chromeless --session qa click --role button --name 'Scripted non-web navigation' | grep -q '"clicked"'
chromeless --session qa wait --url /designers/dashboard --settled --timeout 10000 | grep -q 'Designers Dashboard'
chromeless --session qa screenshot --output viewport.png | grep -q '"name":"viewport.png"'
chromeless --session qa screenshot --full-page --output full-page.png | grep -q '"name":"full-page.png"'
chromeless --session qa screenshot --role button --name Continue --output continue.png | grep -q '"name":"continue.png"'
chromeless --session qa visual compare viewport.png viewport.png --output visual-diff.png | grep -q '"name":"visual-diff.png"'
test -s "$CHROMELESS_ARTIFACT_DIR/visual-diff.png"
chromeless --session qa performance get | grep -q '"webVitals"'
chromeless --session qa animations list | grep -q '"animations"'
chromeless --session qa network emulate --latency 25 --download-kbps 1000 --upload-kbps 500 | grep -q '"latencyMs":25'
chromeless --session qa network emulate | grep -q '"offline":false'
chromeless --session qa network mock set http://127.0.0.1:41739/api/diagnostic --body '{"mocked":true}' --status 201 | grep -q '"activeMocks":1'
# An active mock must not pause unrelated document and asset requests. This
# reload exercises the mocked API while the dashboard itself remains live.
chromeless --session qa reload | grep -q 'Designers Dashboard'
chromeless --session qa network mock clear | grep -q '"cleared":1'
chromeless --session qa flow start | grep -q '"recording":true'
chromeless --session qa visit http://127.0.0.1:41739/designers/dashboard/ | grep -q 'Designers Dashboard'
chromeless --session qa click --role button --name Continue | grep -q '"clicked"'
chromeless --session qa flow stop --output dashboard-flow.json | grep -q '"name":"dashboard-flow.json"'
chromeless --session qa flow run dashboard-flow.json | grep -q '"completed":2'
chromeless --session qa report create --output pr-report.json | grep -q '"name":"pr-report.json"'
grep -q 'chromeless-qa-report-v1' "$CHROMELESS_ARTIFACT_DIR/pr-report.json"
chromeless --session qa visit http://127.0.0.1:41739/designers/dashboard/ | grep -q 'Designers Dashboard'
test -s "$CHROMELESS_ARTIFACT_DIR/viewport.png"
test -s "$CHROMELESS_ARTIFACT_DIR/full-page.png"
test -s "$CHROMELESS_ARTIFACT_DIR/continue.png"
test "$(od -An -tx1 -N8 "$CHROMELESS_ARTIFACT_DIR/viewport.png" | tr -d ' \n')" = "89504e470d0a1a0a"
test "$(od -An -tx1 -N8 "$CHROMELESS_ARTIFACT_DIR/full-page.png" | tr -d ' \n')" = "89504e470d0a1a0a"
test "$(od -An -tx1 -N8 "$CHROMELESS_ARTIFACT_DIR/continue.png" | tr -d ' \n')" = "89504e470d0a1a0a"
set -- $(od -An -tu1 -j 20 -N 4 "$CHROMELESS_ARTIFACT_DIR/viewport.png")
VIEWPORT_HEIGHT=$(($1 * 16777216 + $2 * 65536 + $3 * 256 + $4))
set -- $(od -An -tu1 -j 20 -N 4 "$CHROMELESS_ARTIFACT_DIR/full-page.png")
FULL_HEIGHT=$(($1 * 16777216 + $2 * 65536 + $3 * 256 + $4))
test "$FULL_HEIGHT" -gt "$VIEWPORT_HEIGHT"
if chromeless --session qa screenshot --output viewport.png >/dev/null 2>&1; then
  echo "artifact overwrite was not rejected" >&2
  exit 1
fi
if chromeless screenshot --output ../escape.png >/dev/null 2>&1; then
  echo "artifact path traversal was not rejected" >&2
  exit 1
fi
chromeless --session qa record start --fps 5 | grep -q '"active":true'
chromeless --session qa record status | grep -q '"active":true'
if chromeless --session qa record start >/dev/null 2>&1; then
  echo "a second recording was not rejected" >&2
  exit 1
fi
chromeless --session qa tour --full-page --pace 5000 | grep -q '"durationMs"'
chromeless --session qa click --role button --name Continue | grep -q '"clicked"'
if ! NEXT_PAGE="$(chromeless --session qa wait --url /next --text 'Designer details' --settled --timeout 10000)"; then
  echo "$NEXT_PAGE" >&2
  exit 1
fi
echo "$NEXT_PAGE" | grep -q 'Designer Details'
chromeless --session qa tour --full-page --pace 5000 | grep -q '"durationMs"'
chromeless --session qa record stop --output dashboard-flow.mp4 | grep -q '"name":"dashboard-flow.mp4"'
chromeless --session qa record status | grep -q '"active":false'
test -s "$CHROMELESS_ARTIFACT_DIR/dashboard-flow.mp4"
head -c 64 "$CHROMELESS_ARTIFACT_DIR/dashboard-flow.mp4" | grep -q 'ftyp'
ffprobe -v error -select_streams v:0 \
  -show_entries stream=codec_name,width,height -of csv=p=0 \
  "$CHROMELESS_ARTIFACT_DIR/dashboard-flow.mp4" | grep -Eq '^[^,]+,[1-9][0-9]*,[1-9][0-9]*$'
test "$(stat -c %a "$CHROMELESS_ARTIFACT_DIR/dashboard-flow.mp4")" = "600"
chromeless artifacts list | grep -q '"name":"dashboard-flow.mp4"'
chromeless --session qa back | grep -q 'Designers Dashboard'
chromeless --session qa reload | grep -q 'Designers Dashboard'
chromeless --session qa capture-info | grep -q '"engine":"chromium"'
chromeless --session qa capture-info | grep -q '"browserExecutable":"/usr/lib/chromium/chromium"'
chromeless --session qa visit http://127.0.0.1:41739/hostile/ | grep -q 'Hostile output fixture'
BOUNDED_SNAPSHOT="$(chromeless --session qa inspect)"
echo "$BOUNDED_SNAPSHOT" | grep -q '"truncated":true'
test "$(printf %s "$BOUNDED_SNAPSHOT" | wc -c)" -lt 1048576
chromeless session close qa | grep -q '"closed":"qa"'

if [ -n "${CHROMELESS_EVIDENCE_DIR:-}" ]; then
  umask 077
  mkdir -p "$CHROMELESS_EVIDENCE_DIR"
  cp "$CHROMELESS_ARTIFACT_DIR"/*.png "$CHROMELESS_EVIDENCE_DIR/"
  cp "$CHROMELESS_ARTIFACT_DIR"/*.mp4 "$CHROMELESS_EVIDENCE_DIR/"
  cp "$CHROMELESS_ARTIFACT_DIR"/*.json "$CHROMELESS_EVIDENCE_DIR/"
  (
    cd "$CHROMELESS_EVIDENCE_DIR"
    sha256sum ./*.png ./*.mp4 ./*.json > SHA256SUMS
  )
fi

echo "Linux P2 end-to-end flow passed"
