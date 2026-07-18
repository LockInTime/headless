#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../../../.." && pwd)"
IMAGE="${HEADLESS_SKILL_IMAGE:-headless-computer-use}"
CONTAINER="${HEADLESS_SKILL_CONTAINER:-headless-computer-use}"
NETWORK="${HEADLESS_SKILL_NETWORK:-bridge}"
ARTIFACT_ROOT="/home/headless/.local/state/headless/artifacts"

die() {
  echo "headless sandbox: $*" >&2
  exit 1
}

require_docker() {
  command -v docker >/dev/null 2>&1 || die "Docker is required"
  docker info >/dev/null 2>&1 || die "Docker is unavailable or permission was denied"
}

container_exists() {
  docker container inspect "$CONTAINER" >/dev/null 2>&1
}

container_running() {
  [ "$(docker container inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)" = "true" ]
}

ensure_image() {
  if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    docker build --target production \
      -f "$REPO_ROOT/apps/headless/Dockerfile.linux" \
      -t "$IMAGE" "$REPO_ROOT/apps/headless"
  fi
}

start_sandbox() {
  require_docker
  case "$NETWORK" in bridge|host) ;; *) die "network must be bridge or host" ;; esac
  ensure_image
  if container_exists; then
    configured_network="$(docker container inspect -f '{{.HostConfig.NetworkMode}}' "$CONTAINER")"
    [ "$configured_network" = "$NETWORK" ] || die "existing container uses network '$configured_network', requested '$NETWORK'"
    if ! container_running; then docker start "$CONTAINER" >/dev/null; fi
  else
    docker run -d \
      --name "$CONTAINER" \
      --network "$NETWORK" \
      --shm-size=1g \
      --cap-add=SYS_ADMIN \
      --add-host=host.docker.internal:host-gateway \
      --entrypoint /bin/sh \
      "$IMAGE" -c 'trap "exit 0" TERM INT; while :; do sleep 3600 & wait $!; done' \
      >/dev/null
  fi
  docker exec "$CONTAINER" headless runtime
  docker exec "$CONTAINER" headless start
}

exec_headless() {
  require_docker
  container_running || die "container '$CONTAINER' is not running; run '$0 start'"
  [ "$#" -gt 0 ] || die "exec requires Headless CLI arguments"
  docker exec "$CONTAINER" headless "$@"
}

copy_artifact() {
  require_docker
  [ "$#" -eq 2 ] || die "copy requires ARTIFACT_NAME DESTINATION"
  name="$1"
  destination="$2"
  case "$name" in
    */*|.|..|"") die "artifact must be a basename" ;;
  esac
  case "$name" in
    *.png|*.mp4|*.json) ;;
    *) die "artifact must end in .png, .mp4, or .json" ;;
  esac
  container_exists || die "container '$CONTAINER' does not exist"
  [ ! -e "$destination" ] || die "destination already exists: $destination"
  [ -d "$(dirname -- "$destination")" ] || die "destination directory does not exist"
  docker cp "$CONTAINER:$ARTIFACT_ROOT/$name" "$destination"
  chmod 0600 "$destination"
  echo "Copied $name to $destination"
}

status_sandbox() {
  require_docker
  if ! container_exists; then
    echo "Container: absent ($CONTAINER)"
    exit 0
  fi
  state="$(docker container inspect -f '{{.State.Status}}' "$CONTAINER")"
  echo "Container: $state ($CONTAINER)"
  if container_running; then docker exec "$CONTAINER" headless status; fi
}

stop_sandbox() {
  require_docker
  if ! container_exists; then
    echo "Container already absent: $CONTAINER"
    exit 0
  fi
  if container_running; then
    docker exec "$CONTAINER" headless stop >/dev/null 2>&1 || true
    docker stop "$CONTAINER" >/dev/null
  fi
  echo "Stopped $CONTAINER; artifacts remain available to the copy command"
}

remove_sandbox() {
  require_docker
  if container_exists; then docker rm -f "$CONTAINER" >/dev/null; fi
  echo "Removed $CONTAINER and any uncopied artifacts stored inside it"
}

doctor() {
  echo "Repository: $REPO_ROOT"
  echo "Image: $IMAGE"
  echo "Container: $CONTAINER"
  echo "Network: $NETWORK"
  case "$NETWORK" in bridge|host) ;; *) die "network must be bridge or host" ;; esac
  command -v docker >/dev/null 2>&1 || die "Docker is required"
  docker --version
  docker info >/dev/null 2>&1 || die "Docker is unavailable or permission was denied"
  [ -f "$REPO_ROOT/apps/headless/Dockerfile.linux" ] || die "run this script from its repository checkout"
  if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "Image state: present"
  else
    echo "Image state: absent (start will build it)"
  fi
  if container_exists; then
    echo "Container state: $(docker container inspect -f '{{.State.Status}}' "$CONTAINER")"
  else
    echo "Container state: absent"
  fi
}

usage() {
  cat <<EOF
Usage: $0 COMMAND [ARGS]

Commands:
  doctor                     Check Docker and repository prerequisites
  build                      Build the supported Linux production image
  start                      Start/reuse the container and Headless host
  exec ARGS...               Run normal Headless CLI arguments in the container
  mcp                        Run the Headless stdio MCP adapter in the container
  copy NAME DESTINATION      Copy one private artifact without overwriting
  status                     Show container and Headless host state
  stop                       Stop while preserving the container and artifacts
  remove                     Delete the container and all uncopied artifacts
EOF
}

command="${1:-help}"
if [ "$#" -gt 0 ]; then shift; fi
case "$command" in
  doctor) [ "$#" -eq 0 ] || die "doctor takes no arguments"; doctor ;;
  build) [ "$#" -eq 0 ] || die "build takes no arguments"; require_docker; ensure_image ;;
  start) [ "$#" -eq 0 ] || die "start takes no arguments"; start_sandbox ;;
  exec) exec_headless "$@" ;;
  mcp) [ "$#" -eq 0 ] || die "mcp takes no arguments"; require_docker; container_running || die "container is not running"; exec docker exec -i "$CONTAINER" headless-mcp ;;
  copy) copy_artifact "$@" ;;
  status) [ "$#" -eq 0 ] || die "status takes no arguments"; status_sandbox ;;
  stop) [ "$#" -eq 0 ] || die "stop takes no arguments"; stop_sandbox ;;
  remove) [ "$#" -eq 0 ] || die "remove takes no arguments"; remove_sandbox ;;
  help|-h|--help) usage ;;
  *) die "unknown command: $command" ;;
esac
