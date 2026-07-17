#!/bin/sh
set -eu

CASE="${1:-}"
case "$CASE" in chromeless|chromeless-warm|selenium|puppeteer) ;; *) echo "unknown benchmark case" >&2; exit 64;; esac

FIXTURE_ROOT="$(mktemp -d /tmp/chromeless-benchmark-fixture.XXXXXX)"
export BENCH_OUTPUT="$(mktemp -d /tmp/chromeless-benchmark-output.XXXXXX)"
export BENCH_URL="http://127.0.0.1:41739/designers/dashboard/"
mkdir -p "$FIXTURE_ROOT/designers/dashboard" "$FIXTURE_ROOT/next" "$FIXTURE_ROOT/api"
cp /opt/chromeless/fixtures/dashboard.html "$FIXTURE_ROOT/designers/dashboard/index.html"
cp /opt/chromeless/fixtures/next.html "$FIXTURE_ROOT/next/index.html"
cp /opt/chromeless/fixtures/api-diagnostic.json "$FIXTURE_ROOT/api/diagnostic"
busybox httpd -f -p 127.0.0.1:41739 -h "$FIXTURE_ROOT" >/dev/null 2>&1 &
SERVER_PID=$!
cleanup() {
  chromeless stop >/dev/null 2>&1 || true
  kill "$SERVER_PID" >/dev/null 2>&1 || true
  rm -rf "$FIXTURE_ROOT" "$BENCH_OUTPUT"
}
trap cleanup EXIT INT TERM

for _ in $(seq 1 100); do
  busybox wget -q -O /dev/null "$BENCH_URL" 2>/dev/null && break
  sleep 0.05
done
busybox wget -q -O /dev/null "$BENCH_URL"

if [ "$CASE" = "chromeless-warm" ]; then
  export CHROMELESS_ARTIFACT_DIR="$BENCH_OUTPUT"
  chromeless start >/dev/null
  chromeless session create bench >/dev/null
fi

cpu_usage() { awk '$1 == "usage_usec" {print $2}' /sys/fs/cgroup/cpu.stat; }
CPU_START="$(cpu_usage)"
WALL_START="$(date +%s%N)"
case "$CASE" in
  chromeless) /opt/chromeless/benchmarks/chromeless.sh ;;
  chromeless-warm) /opt/chromeless/benchmarks/chromeless_warm.sh ;;
  selenium) python3 /opt/chromeless/benchmarks/selenium_case.py ;;
  puppeteer) node /opt/chromeless/benchmarks/puppeteer.cjs ;;
esac
WALL_END="$(date +%s%N)"
CPU_END="$(cpu_usage)"

test -s "$BENCH_OUTPUT/flow.mp4"
test -s "$BENCH_OUTPUT/final.png"
WORKFLOW="/opt/chromeless/benchmarks/$CASE"
case "$CASE" in
  chromeless) WORKFLOW="$WORKFLOW.sh" ;;
  chromeless-warm) WORKFLOW="/opt/chromeless/benchmarks/chromeless_warm.sh" ;;
  selenium) WORKFLOW="/opt/chromeless/benchmarks/selenium_case.py" ;;
  puppeteer) WORKFLOW="$WORKFLOW.cjs" ;;
esac
WORKFLOW_BYTES="$(wc -c < "$WORKFLOW" | tr -d ' ')"
ESTIMATED_TOKENS=$(((WORKFLOW_BYTES + 3) / 4))
ARTIFACT_BYTES="$(du -cb "$BENCH_OUTPUT/flow.mp4" "$BENCH_OUTPUT/final.png" | awk 'END {print $1}')"
MEMORY_PEAK="$(cat /sys/fs/cgroup/memory.peak)"
WALL_MS=$(((WALL_END - WALL_START) / 1000000))
CPU_MS=$(((CPU_END - CPU_START) / 1000))
printf '{"case":"%s","wallMs":%s,"cpuMs":%s,"memoryPeakBytes":%s,"artifactBytes":%s,"workflowBytes":%s,"estimatedTokens":%s}\n' \
  "$CASE" "$WALL_MS" "$CPU_MS" "$MEMORY_PEAK" "$ARTIFACT_BYTES" "$WORKFLOW_BYTES" "$ESTIMATED_TOKENS"
