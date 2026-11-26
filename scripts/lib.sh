# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# Sourced by every script: loads the deployment's settings, exports the project's
# configuration through its kit executable, and moves to the kit's folder.
#   KIT_ENV  the deployment's settings file
#   KIT      the project's kit executable, built with its configuration
# A relative STATE_DIR in the settings is relative to the settings file.

: "${KIT_ENV:?set KIT_ENV to the deployment's settings file}" "${KIT:?set KIT to the project's kit executable}"
KIT_ENV="$(cd "$(dirname "$KIT_ENV")" && pwd)/$(basename "$KIT_ENV")"
KIT="$(cd "$(dirname "$KIT")" && pwd)/$(basename "$KIT")"
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[ -f "$KIT_ENV" ] || { echo "No settings file at $KIT_ENV." >&2; exit 1; }
set -a
. "$KIT_ENV"
set +a
STATE_DIR="${STATE_DIR:-.}"
case "$STATE_DIR" in /*) ;; *) STATE_DIR="$(dirname "$KIT_ENV")/$STATE_DIR" ;; esac
mkdir -p "$STATE_DIR"
STATE_DIR="$(cd "$STATE_DIR" && pwd)"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-guild}"
HOST_UID="${HOST_UID:-$(id -u)}"
HOST_GID="${HOST_GID:-$(id -g)}"
KIT_CONFIG="$STATE_DIR/config"
export STATE_DIR COMPOSE_PROJECT_NAME HOST_UID HOST_GID KIT_CONFIG
"$KIT" export "$KIT_CONFIG" || { echo "The kit couldn't export the project's configuration." >&2; exit 1; }
# Each agent's service, generated with the export; once, for a script another runs.
case ":${COMPOSE_FILE:-}:" in
  *":$KIT_CONFIG/compose.agents.yaml:"*) ;;
  *) COMPOSE_FILE="${COMPOSE_FILE:-compose.yaml}:$KIT_CONFIG/compose.agents.yaml" ;;
esac
export COMPOSE_FILE
set -a
. "$KIT_CONFIG/project.env"
set +a
# Forgejo's own mirroring follows the deployment's setting too.
case "${MIRRORS:-on}" in off) FORGE_MIRRORS=false ;; *) FORGE_MIRRORS=true ;; esac
export FORGE_MIRRORS

# Asks before a script changes the kit, naming which kit it would change. KIT_YES=1
# answers yes, for a script that runs others; without it, and with no terminal to ask on,
# the script stops having changed nothing.
confirm() {
  [ "${KIT_YES:-}" = 1 ] && return 0
  [ -t 0 ] || { echo "$1, on the kit $COMPOSE_PROJECT_NAME. Set KIT_YES=1 to go ahead without being asked." >&2; exit 1; }
  printf '%s, on the kit %s (%s). Go ahead? [y/N] ' "$1" "$COMPOSE_PROJECT_NAME" "$KIT_ENV" >&2
  local answer
  read -r answer
  case "$answer" in
    [yY]|[yY][eE][sS]) ;;
    *) echo "Nothing changed." >&2; exit 1 ;;
  esac
}

tools() { docker compose run --rm tools "$@"; }

# The admin tools run from their image, so rebuild it whenever the kit's copy of them
# changes; Docker's cache makes this quick when nothing has.
[ -n "${KIT_NO_BUILD:-}" ] || docker compose --profile tools build --quiet tools >/dev/null \
  || { echo "Couldn't build the tools image; see: docker compose --profile tools build tools" >&2; exit 1; }
