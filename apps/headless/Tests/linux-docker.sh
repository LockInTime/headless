#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

command -v docker >/dev/null 2>&1 || { echo "Linux E2E tests require Docker" >&2; exit 69; }
docker build --target test -f Dockerfile.linux -t headless-p1-test .
# SYS_ADMIN is limited to this disposable test container so Chromium can use
# its nested namespace sandbox. The shipped host still runs as non-root and
# never enables --no-sandbox.
docker run --rm --name headless-p1-e2e --shm-size=1g --cap-add=SYS_ADMIN \
  headless-p1-test /opt/headless/linux-e2e.sh
