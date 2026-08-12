#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
  echo "usage: container-smoke.sh IMAGE EXPECTED_VERSION" >&2
  exit 64
fi

IMAGE="$1"
EXPECTED_VERSION="$2"

command -v docker >/dev/null 2>&1 || { echo "container smoke: Docker is required" >&2; exit 69; }

ACTUAL_VERSION="$(docker run --rm --entrypoint /usr/local/bin/headless "$IMAGE" --version)"
[ "$ACTUAL_VERSION" = "headless $EXPECTED_VERSION" ] || {
  echo "container smoke: expected headless $EXPECTED_VERSION, received $ACTUAL_VERSION" >&2
  exit 1
}

[ "$(docker run --rm --entrypoint /usr/bin/id "$IMAGE" -u)" = "10001" ] || {
  echo "container smoke: image does not run as the unprivileged headless user" >&2
  exit 1
}

docker run --rm --entrypoint /usr/local/bin/headless "$IMAGE" capabilities \
  | grep -q '"protocolVersion"'
docker run --rm --entrypoint /usr/local/bin/headless "$IMAGE" runtime \
  | grep -q '"executable":"/usr/lib/chromium/chromium"'
docker run --rm --entrypoint /bin/sh "$IMAGE" -c 'test -x /usr/bin/ffmpeg'

EXPOSED_PORTS="$(docker image inspect --format '{{json .Config.ExposedPorts}}' "$IMAGE")"
case "$EXPOSED_PORTS" in
  null|'{}') ;;
  *) echo "container smoke: image declares unexpected exposed ports: $EXPOSED_PORTS" >&2; exit 1 ;;
esac

SOURCE_LABEL="$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.source"}}' "$IMAGE")"
[ "$SOURCE_LABEL" = "https://github.com/LockInTime/headless" ] || {
  echo "container smoke: source label does not link the image to the repository" >&2
  exit 1
}

echo "Production container smoke tests passed: $IMAGE"
