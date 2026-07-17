#!/bin/sh
set -eu
cd "$(dirname "$0")"

REPEATS="${1:-3}"
case "$REPEATS" in *[!0-9]*|'') echo "usage: ./benchmark.sh [positive-repeat-count]" >&2; exit 64;; esac
test "$REPEATS" -gt 0 || { echo "repeat count must be positive" >&2; exit 64; }

docker build --quiet --target benchmark -f Dockerfile.linux -t chromeless-p1-benchmark . >/dev/null
for case_name in chromeless chromeless-warm selenium puppeteer; do
  iteration=1
  while [ "$iteration" -le "$REPEATS" ]; do
    docker run --rm --shm-size=1g --cap-add=SYS_ADMIN chromeless-p1-benchmark "$case_name"
    iteration=$((iteration + 1))
  done
done
