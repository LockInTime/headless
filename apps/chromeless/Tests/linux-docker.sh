#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

command -v docker >/dev/null 2>&1 || { echo "Linux E2E tests require Docker" >&2; exit 69; }
docker build --target test -f Dockerfile.linux -t chromeless-p1-test .
EVIDENCE_ROOT="${CHROMELESS_EVIDENCE_ROOT:-$PWD/build/qa-evidence}"
mkdir -p "$EVIDENCE_ROOT"
EVIDENCE_DIR="$(mktemp -d "$EVIDENCE_ROOT/linux.XXXXXX")"
chmod 0777 "$EVIDENCE_DIR"
restore_evidence_owner() {
  docker run --rm --user root -v "$EVIDENCE_DIR:/evidence" \
    chromeless-p1-test chown -R "$(id -u):$(id -g)" /evidence >/dev/null 2>&1 || true
  chmod 0700 "$EVIDENCE_DIR" >/dev/null 2>&1 || true
}
trap restore_evidence_owner EXIT INT TERM
# SYS_ADMIN is limited to this disposable test container so Chromium can use
# its nested namespace sandbox. The shipped host still runs as non-root and
# never enables --no-sandbox.
docker run --rm --name chromeless-p1-e2e --shm-size=1g --cap-add=SYS_ADMIN \
  -e CHROMELESS_EVIDENCE_DIR=/evidence -v "$EVIDENCE_DIR:/evidence" \
  chromeless-p1-test /opt/chromeless/linux-e2e.sh
restore_evidence_owner
trap - EXIT INT TERM
(
  cd "$EVIDENCE_DIR"
  sha256sum -c SHA256SUMS
)
test -s "$EVIDENCE_DIR/viewport.png"
test -s "$EVIDENCE_DIR/full-page.png"
test -s "$EVIDENCE_DIR/dashboard-flow.mp4"
test "$(stat -c %a "$EVIDENCE_DIR/viewport.png")" = "600"
test "$(stat -c %a "$EVIDENCE_DIR/dashboard-flow.mp4")" = "600"
echo "Linux QA evidence: $EVIDENCE_DIR"
