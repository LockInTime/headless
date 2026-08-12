#!/bin/sh
set -eu
cd "$(dirname "$0")"

REPEATS="${1:-3}"
OUTPUT="${2:-../../packages/benchmark-results/results.json}"
if [ "$#" -gt 2 ]; then
  echo "usage: ./benchmark.sh [positive-repeat-count] [output-path]" >&2
  exit 64
fi
case "$REPEATS" in *[!0-9]*|'') echo "usage: ./benchmark.sh [positive-repeat-count] [output-path]" >&2; exit 64;; esac
test "$REPEATS" -gt 0 || { echo "repeat count must be positive" >&2; exit 64; }
test "$REPEATS" -le 100 || { echo "repeat count must not exceed 100" >&2; exit 64; }

command -v docker >/dev/null 2>&1 || { echo "docker is required" >&2; exit 69; }

OUTPUT_DIRECTORY="$(dirname "$OUTPUT")"
mkdir -p "$OUTPUT_DIRECTORY"
OUTPUT="$(CDPATH='' cd -- "$OUTPUT_DIRECTORY" && pwd -P)/$(basename "$OUTPUT")"
RAW_RESULTS="$(mktemp "${TMPDIR:-/tmp}/headless-benchmark.XXXXXX")"
IMAGE="headless-p1-benchmark:run-$$"
cleanup() {
  rm -f "$RAW_RESULTS"
  docker image rm "$IMAGE" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

docker build --quiet --target benchmark -f Dockerfile.linux -t "$IMAGE" . >/dev/null
for case_name in headless headless-warm selenium puppeteer; do
  iteration=1
  while [ "$iteration" -le "$REPEATS" ]; do
    echo "Benchmarking $case_name ($iteration/$REPEATS)" >&2
    docker run --rm --shm-size=1g --cap-add=SYS_ADMIN "$IMAGE" "$case_name" >> "$RAW_RESULTS"
    iteration=$((iteration + 1))
  done
done

PLATFORM="$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$IMAGE")"
GENERATED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
docker run --rm \
  --user "$(id -u):$(id -g)" \
  --mount "type=bind,src=$RAW_RESULTS,dst=/tmp/headless-benchmark.ndjson,readonly" \
  --mount "type=bind,src=$OUTPUT_DIRECTORY,dst=/output" \
  --entrypoint node \
  "$IMAGE" \
  /opt/headless/benchmarks/summarize.mjs \
  /tmp/headless-benchmark.ndjson \
  "/output/$(basename "$OUTPUT")" \
  "$REPEATS" \
  "$GENERATED_AT" \
  "$PLATFORM"
echo "Benchmark results: $OUTPUT"
