#!/usr/bin/env bash
set -euo pipefail

readonly MINIMUM_VIDEO_SECONDS=10
readonly DISPLAY_NUMBER=:99
readonly FIXTURE_URL=http://127.0.0.1:41739
readonly BASE_IMAGE=headless-qa-video-base
readonly VIDEO_IMAGE=headless-qa-video-runtime
readonly SCRIPT_IN_CONTAINER=/workspace/apps/headless/Tests/qa-videos.sh

fail() {
  printf 'qa-videos: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

show_command() {
  printf '\n$'
  printf ' %q' "$@"
  printf '\n'
  "$@"
}

terminal_runtime() {
  printf '\033[2J\033[HHeadless QA: bundled runtime and Snap rejection\n'
  sleep 2
  show_command headless runtime
  sleep 3
  printf '\n$ HEADLESS_CHROMIUM_EXECUTABLE=/snap/bin/chromium headless runtime\n'
  set +e
  snap_output="$(HEADLESS_CHROMIUM_EXECUTABLE=/snap/bin/chromium headless runtime 2>&1)"
  snap_status=$?
  set -e
  printf '%s\nexit status: %s\n' "$snap_output" "$snap_status"
  test "$snap_status" -ne 0 || fail 'Snap Chromium was accepted'
  grep -q 'UNSUPPORTED_BROWSER_RUNTIME' <<<"$snap_output" || fail 'Snap rejection code was absent'
  grep -q 'Snap Chromium is not reliable' <<<"$snap_output" || fail 'Snap rejection reason was absent'
  sleep 4
  show_command headless capabilities
  sleep 3
  printf '\nRuntime selection checks passed.\n'
  sleep 2
}

terminal_mcp() {
  printf '\033[2J\033[HHeadless QA: MCP stdio invocation\n'
  sleep 2
  printf '\n$ printf JSON-RPC_requests | headless-mcp\n'
  mcp_output="$({
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
    printf '%s\n' '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"headless","arguments":{"argv":["status"]}}}'
    printf '%s\n' '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"headless","arguments":{"argv":["--session","qa","inspect","--interactive","--text"]}}}'
  } | headless-mcp)"
  printf '%s\n' "$mcp_output"
  grep -q '"protocolVersion":"2025-06-18"' <<<"$mcp_output" || fail 'MCP initialize response was absent'
  grep -q '"name":"headless"' <<<"$mcp_output" || fail 'MCP tool listing was absent'
  grep -q '\\"ready\\":true' <<<"$mcp_output" || fail 'MCP status result was absent'
  grep -q 'Designers dashboard' <<<"$mcp_output" || fail 'MCP browser result was absent'
  sleep 6
  printf '\nMCP stdio checks passed.\n'
  sleep 4
}

if [[ "${1:-}" == --terminal-runtime ]]; then
  terminal_runtime
  exit 0
fi

if [[ "${1:-}" == --terminal-mcp ]]; then
  terminal_mcp
  exit 0
fi

outer_cleanup() {
  if [[ -n "${OUTPUT_DIR:-}" && -d "${OUTPUT_DIR:-}" ]]; then
    docker run --rm --user root -v "$OUTPUT_DIR:/evidence" "$VIDEO_IMAGE" \
      chown -R "$(id -u):$(id -g)" /evidence >/dev/null 2>&1 || true
    chmod 0700 "$OUTPUT_DIR" >/dev/null 2>&1 || true
  fi
}

run_outer() {
  require_command docker
  local repository_root run_stamp
  repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

  run_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  OUTPUT_DIR="${HEADLESS_QA_VIDEO_DIR:-$repository_root/build/qa-evidence/videos-$run_stamp}"
  [[ "$OUTPUT_DIR" = /* ]] || fail 'HEADLESS_QA_VIDEO_DIR must be an absolute path'
  [[ ! -e "$OUTPUT_DIR" ]] || fail "evidence directory already exists: $OUTPUT_DIR"
  mkdir -p "$OUTPUT_DIR"
  chmod 0777 "$OUTPUT_DIR"
  trap outer_cleanup EXIT INT TERM

  printf 'Building the shipped Linux test runtime...\n'
  docker build --target test -f "$repository_root/apps/headless/Dockerfile.linux" \
    -t "$BASE_IMAGE" "$repository_root/apps/headless"

  printf 'Adding video-only packages to the QA runtime...\n'
  docker build --build-arg BASE_IMAGE="$BASE_IMAGE" -t "$VIDEO_IMAGE" - <<'DOCKERFILE'
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends nodejs xvfb xterm x11-utils fonts-dejavu-core \
    && rm -rf /var/lib/apt/lists/*
USER headless
DOCKERFILE

  local container_name
  container_name="headless-qa-videos-$(printf '%s' "$run_stamp" | tr '[:upper:]' '[:lower:]')"
  docker run --rm --name "$container_name" --shm-size=1g \
    --cap-add=SYS_ADMIN -e HEADLESS_EVIDENCE_DIR=/evidence \
    -v "$repository_root:/workspace:ro" -v "$OUTPUT_DIR:/evidence" \
    "$VIDEO_IMAGE" "$SCRIPT_IN_CONTAINER" --inside

  outer_cleanup
  trap - EXIT INT TERM
  printf 'QA video evidence: %s\n' "$OUTPUT_DIR"
}

ACTIVE_RECORDING=
FIXTURE_PID=
XVFB_PID=
ARTIFACT_DIR=

inside_cleanup() {
  if [[ -n "$ACTIVE_RECORDING" ]]; then
    headless --session qa record stop >/dev/null 2>&1 || true
  fi
  headless stop >/dev/null 2>&1 || true
  if [[ -n "$FIXTURE_PID" ]]; then
    kill "$FIXTURE_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$XVFB_PID" ]]; then
    kill "$XVFB_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$ARTIFACT_DIR" && -d "$ARTIFACT_DIR" ]]; then
    rm -rf -- "$ARTIFACT_DIR"
  fi
}

qa_pause() {
  sleep "$1"
}

expect_output() {
  local pattern=$1
  shift
  local output
  if ! output="$("$@" 2>&1)"; then
    printf '%s\n' "$output" >&2
    fail "command failed: $*"
  fi
  printf '%s\n' "$output"
  grep -q "$pattern" <<<"$output" || fail "expected output was absent: $pattern"
}

expect_failure() {
  local pattern=$1
  shift
  local output status
  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e
  printf '%s\n' "$output"
  test "$status" -ne 0 || fail "command unexpectedly succeeded: $*"
  grep -q "$pattern" <<<"$output" || fail "expected failure was absent: $pattern"
}

dashboard() {
  expect_output 'Designers Dashboard' headless --session qa visit "$FIXTURE_URL/designers/dashboard"
  expect_output 'Designers Dashboard' headless --session qa wait --url /designers/dashboard --settled --timeout 10000
}

record_start() {
  ACTIVE_RECORDING=$1
  expect_output '"active":true' headless --session qa record start --fps 5 --output "$ACTIVE_RECORDING"
}

record_stop() {
  expect_output "\"name\":\"$ACTIVE_RECORDING\"" headless --session qa record stop
  ACTIVE_RECORDING=
}

record_terminal() {
  local output=$1 mode=$2 title=$3
  ffmpeg -hide_banner -loglevel error -y -f x11grab -draw_mouse 0 \
    -framerate 15 -video_size 1280x720 -i "$DISPLAY" -t 18 -an \
    -c:v mpeg4 -q:v 3 -pix_fmt yuv420p -movflags +faststart "/evidence/$output" &
  local ffmpeg_pid=$!
  qa_pause 1
  xterm -display "$DISPLAY" -geometry 126x36+0+0 -fa Monospace -fs 13 \
    -bg '#111318' -fg '#f4f4f5' -title "$title" -e "$SCRIPT_IN_CONTAINER" "$mode"
  wait "$ffmpeg_pid"
}

browser_startup_navigation() {
  dashboard
  record_start 02-startup-session-navigation.mp4
  headless --session qa tour --full-page --pace 1000
  qa_pause 2
  expect_output 'Designer Details' headless --session qa visit "$FIXTURE_URL/next"
  expect_output 'Designer Details' headless --session qa wait --url /next --text 'Designer details' --settled --timeout 10000
  qa_pause 3
  expect_output 'Designer Details' headless --session qa reload
  qa_pause 3
  expect_output 'Designers Dashboard' headless --session qa back
  qa_pause 3
  expect_output 'Designers Dashboard' headless --session qa reload
  qa_pause 2
  record_stop
}

browser_screenshots_visual() {
  dashboard
  record_start 03-screenshots-visual-comparison.mp4
  expect_output '"name":"Reviewer"' headless --session qa inspect --interactive --text
  expect_output '"name":"visual-before.png"' headless --session qa screenshot --output visual-before.png
  qa_pause 2
  headless --session qa scroll bottom
  expect_output '"name":"visual-full-page.png"' headless --session qa screenshot --full-page --output visual-full-page.png
  qa_pause 3
  headless --session qa scroll top
  expect_output '"valueLength":11' headless --session qa fill @e1 'QA reviewer'
  expect_output '"name":"visual-after.png"' headless --session qa screenshot --output visual-after.png
  expect_output '"name":"visual-diff.png"' headless --session qa visual compare visual-before.png visual-after.png --output visual-diff.png
  qa_pause 3
  headless --session qa tour --full-page --pace 1000
  qa_pause 3
  record_stop
}

browser_diagnostics() {
  dashboard
  record_start 04-diagnostics.mp4
  expect_output 'Designers Dashboard' headless --session qa reload
  qa_pause 3
  expect_output 'Next.js runtime error' headless --session qa console list --level error
  headless --session qa scroll down --amount 650
  qa_pause 3
  expect_output '"requestId"' headless --session qa network list
  expect_output '"name":"qa_session"' headless --session qa cookies list
  headless --session qa scroll bottom
  qa_pause 3
  expect_output 'qa-diagnostic-key' headless --session qa storage list
  expect_output 'qa-session-key' headless --session qa storage list
  expect_output '"kind":"console"' headless --session qa qa report
  headless --session qa scroll top
  qa_pause 3
  record_stop
}

browser_network_controls() {
  dashboard
  record_start 05-network-emulation-mocking.mp4
  expect_output '"latencyMs":25' headless --session qa network emulate --latency 25 --download-kbps 1000 --upload-kbps 500
  qa_pause 2
  expect_output 'Designers Dashboard' headless --session qa reload
  qa_pause 3
  expect_output '"activeMocks":1' headless --session qa network mock set "$FIXTURE_URL/api/diagnostic" --body '{"mocked":true}' --status 201 --content-type application/json
  expect_output 'Designers Dashboard' headless --session qa reload
  headless --session qa scroll bottom
  qa_pause 3
  expect_output '"cleared":1' headless --session qa network mock clear
  expect_output 'Designers Dashboard' headless --session qa reload
  headless --session qa scroll top
  qa_pause 3
  headless --session qa tour --full-page --pace 1000
  qa_pause 2
  record_stop
}

browser_safe_input() {
  dashboard
  record_start 06-safe-navigation-input.mp4
  expect_output '"name":"Reviewer"' headless --session qa inspect --interactive --text
  expect_output '"valueLength":11' headless --session qa fill @e1 'QA reviewer'
  expect_output '"pressed":"Tab"' headless --session qa press Tab
  expect_output '"pressed":"Escape"' headless --session qa press Escape
  qa_pause 2
  headless --session qa scroll bottom
  qa_pause 3
  expect_failure 'UNSAFE_NAVIGATION' headless --session qa click --role link --name 'External application'
  expect_failure 'UNSAFE_NAVIGATION' headless --session qa click --role link --name 'Non-web browser URL'
  expect_failure 'UNSAFE_NAVIGATION' headless --session qa click --role link --name 'Credential-bearing URL'
  expect_failure 'UNSAFE_RESOURCE_TYPE' headless --session qa click --role link --name 'Suspicious installer'
  qa_pause 3
  expect_output '"clicked"' headless --session qa click --role button --name 'Scripted non-web navigation'
  expect_output 'Designers Dashboard' headless --session qa wait --url /designers/dashboard --settled --timeout 10000
  qa_pause 2
  expect_output '"clicked"' headless --session qa click --role button --name Continue
  expect_output 'Designer Details' headless --session qa wait --url /next --text 'Designer details' --settled --timeout 10000
  qa_pause 3
  record_stop
}

browser_flows_reports() {
  dashboard
  record_start 07-flows-reports.mp4
  expect_output '"recording":true' headless --session qa flow start
  expect_output 'Designers Dashboard' headless --session qa visit "$FIXTURE_URL/designers/dashboard"
  qa_pause 2
  expect_output '"clicked"' headless --session qa click --role button --name Continue
  qa_pause 3
  expect_output '"name":"dashboard-flow.json"' headless --session qa flow stop --output dashboard-flow.json
  expect_output 'Designer Details' headless --session qa wait --url /next --text 'Designer details' --settled --timeout 10000
  expect_output '"completed":2' headless --session qa flow run dashboard-flow.json
  expect_output 'Designer Details' headless --session qa wait --url /next --settled --timeout 10000
  qa_pause 3
  expect_output '"name":"pr-report.json"' headless --session qa report create --output pr-report.json
  headless --session qa tour --full-page --pace 1000
  qa_pause 4
  record_stop
}

browser_performance_animations() {
  dashboard
  record_start 08-performance-animations.mp4
  expect_output '"webVitals"' headless --session qa performance get
  headless --session qa tour --full-page --pace 1000
  qa_pause 3
  expect_output '"animations"' headless --session qa animations list
  headless --session qa scroll bottom
  qa_pause 3
  expect_output 'Designer Details' headless --session qa visit "$FIXTURE_URL/next"
  expect_output '"webVitals"' headless --session qa performance get
  qa_pause 3
  expect_output 'Designers Dashboard' headless --session qa back
  expect_output '"animations"' headless --session qa animations list
  qa_pause 3
  record_stop
}

browser_recording_artifacts() {
  dashboard
  record_start 09-recording-artifact-lifecycle.mp4
  expect_output '"active":true' headless --session qa record status
  expect_failure 'already active' headless --session qa record start
  qa_pause 2
  expect_output '"name":"lifecycle-viewport.png"' headless --session qa screenshot --output lifecycle-viewport.png
  headless --session qa scroll bottom
  qa_pause 3
  expect_output 'lifecycle-viewport.png' headless artifacts list
  headless --session qa tour --full-page --pace 1000
  qa_pause 3
  expect_output '"engine":"chromium"' headless --session qa capture-info
  headless --session qa scroll top
  qa_pause 3
  expect_output '"name":"lifecycle-full-page.png"' headless --session qa screenshot --full-page --output lifecycle-full-page.png
  qa_pause 2
  record_stop
  expect_output '"active":false' headless --session qa record status
  expect_output '09-recording-artifact-lifecycle.mp4' headless artifacts list
}

validate_evidence() {
  local first=1 video duration codec sensitive_matches sensitive_status
  shopt -s nullglob
  local videos=(/evidence/*.mp4)
  test "${#videos[@]}" -eq 10 || fail "expected 10 MP4 files, found ${#videos[@]}"

  printf '{\n  "minimumSeconds": %s,\n  "videos": [\n' "$MINIMUM_VIDEO_SECONDS" > /evidence/media-probe.json
  for video in "${videos[@]}"; do
    test -s "$video" || fail "empty video: $(basename "$video")"
    codec="$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=nokey=1:noprint_wrappers=1 "$video")"
    test -n "$codec" || fail "video stream missing: $(basename "$video")"
    duration="$(ffprobe -v error -show_entries format=duration -of default=nokey=1:noprint_wrappers=1 "$video")"
    awk -v actual="$duration" -v minimum="$MINIMUM_VIDEO_SECONDS" 'BEGIN { exit !(actual + 0 >= minimum) }' \
      || fail "video is shorter than ${MINIMUM_VIDEO_SECONDS}s: $(basename "$video") (${duration}s)"
    if [[ $first -eq 0 ]]; then
      printf ',\n' >> /evidence/media-probe.json
    fi
    first=0
    printf '    {"file":"%s","durationSeconds":%s,"codec":"%s"}' \
      "$(basename "$video")" "$duration" "$codec" >> /evidence/media-probe.json
  done
  printf '\n  ],\n  "result": "pass"\n}\n' >> /evidence/media-probe.json

  set +e
  sensitive_matches="$(grep -R -a -E -l \
    --include='*.mp4' --include='*.json' --include='*.png' \
    'fixture-secret|response-secret|Bearer fixture|qa:secret' /evidence)"
  sensitive_status=$?
  set -e
  if [[ $sensitive_status -eq 0 ]]; then
    printf '%s\n' "$sensitive_matches" >&2
    fail 'sensitive fixture text found in evidence artifacts'
  fi
  [[ $sensitive_status -eq 1 ]] || fail 'sensitive fixture scan failed'

  printf '%s\n' \
    '{' \
    '  "result": "pass",' \
    '  "runtime": "/usr/lib/chromium/chromium",' \
    '  "fixture": "apps/headless/Tests/fixture-server.mjs",' \
    '  "recordings": 10' \
    '}' > /evidence/test-results.json

  chmod 0600 /evidence/*
  (
    cd /evidence
    find . -maxdepth 1 -type f \( -name '*.mp4' -o -name '*.json' -o -name '*.png' \) \
      -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
    chmod 0600 SHA256SUMS
    sha256sum -c SHA256SUMS
  )
}

run_inside() {
  for command in headless headless-mcp node ffmpeg ffprobe Xvfb xterm xdpyinfo; do
    require_command "$command"
  done
  [[ "${HEADLESS_EVIDENCE_DIR:-}" == /evidence ]] || fail 'HEADLESS_EVIDENCE_DIR must be /evidence in the QA container'
  test -x /usr/lib/chromium/chromium || fail 'bundled Chromium is missing'
  ffmpeg -hide_banner -devices 2>/dev/null | grep -q 'x11grab' \
    || fail 'FFmpeg x11grab is unavailable; terminal recordings cannot be created'

  ARTIFACT_DIR="$(mktemp -d /tmp/headless-qa-artifacts.XXXXXX)"
  chmod 0700 "$ARTIFACT_DIR"
  export HEADLESS_ARTIFACT_DIR="$ARTIFACT_DIR"
  export HEADLESS_CHROMIUM_EXECUTABLE=/usr/lib/chromium/chromium
  export DISPLAY="$DISPLAY_NUMBER"
  trap inside_cleanup EXIT INT TERM

  Xvfb "$DISPLAY" -screen 0 1280x720x24 -nolisten tcp >/tmp/headless-qa-xvfb.log 2>&1 &
  XVFB_PID=$!
  for _ in {1..50}; do
    xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 && break
    qa_pause 0.1
  done
  xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 \
    || fail 'DISPLAY=:99 is unavailable; terminal recordings require working Xvfb and x11grab'

  node /workspace/apps/headless/Tests/fixture-server.mjs >/tmp/headless-qa-fixture.log 2>&1 &
  FIXTURE_PID=$!
  for _ in {1..50}; do
    grep -q 'fixture server ready' /tmp/headless-qa-fixture.log 2>/dev/null && break
    qa_pause 0.1
  done
  grep -q 'fixture server ready' /tmp/headless-qa-fixture.log \
    || fail 'existing fixture server did not become ready'

  record_terminal 01-runtime-selection-snap-rejection.mp4 --terminal-runtime 'Runtime selection and Snap rejection'

  expect_output '"executable":"/usr/lib/chromium/chromium"' headless runtime
  expect_output '"ready":true' headless start
  expect_output '"session":"qa"' headless session create qa
  expect_output '"qa"' headless session list

  browser_startup_navigation
  browser_screenshots_visual
  browser_diagnostics
  browser_network_controls
  browser_safe_input
  browser_flows_reports
  browser_performance_animations
  browser_recording_artifacts

  dashboard
  record_terminal 10-mcp-stdio-invocation.mp4 --terminal-mcp 'MCP stdio invocation'

  expect_output '"closed":"qa"' headless session close qa
  expect_output '"stopping":true' headless stop
  cp "$ARTIFACT_DIR"/*.mp4 /evidence/
  cp "$ARTIFACT_DIR"/*.png /evidence/
  cp "$ARTIFACT_DIR"/*.json /evidence/
  validate_evidence
  printf 'All QA evidence checks passed.\n'
}

case "${1:-}" in
  --inside) run_inside ;;
  '') run_outer ;;
  *) fail "unknown option: $1" ;;
esac
