#!/usr/bin/env bash
# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# Build and start Forgejo, CI, the proxies, the dispatcher, the gatekeeper and the web UI. Safe to
# re-run.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
confirm "This builds the kit's images and starts or recreates its containers"
# Mounted into containers; must exist before Docker creates them as root.
mkdir -p "$STATE_DIR/secrets/ci" "$STATE_DIR/secrets/dispatcher" "$STATE_DIR/secrets/gatekeeper" \
  "$STATE_DIR/secrets/github" "$STATE_DIR/secrets/runner-keys" "$STATE_DIR/secrets/claude" "$STATE_DIR/secrets/ui" \
  "$STATE_DIR/secrets/human" "$STATE_DIR/control" \
  "$STATE_DIR/proxy"
# Extra domains for Forgejo's proxy: empty except while an import runs.
[ -e "$STATE_DIR/proxy/domains.txt" ] || : > "$STATE_DIR/proxy/domains.txt"

# The images up to the project's top layer, and the kit's services.
# kit-build first: the agents' images and the gatekeeper's copy from it.
docker compose --profile build build kit-build
images="agent-base agent-lean ci-lean"
[ "$TOP_LAYER" = lasm ] && images="$images agent-lasm ci-lasm"
docker compose --profile build build $images
docker compose build gatekeeper dispatcher ui
docker compose --profile tools build tools
docker tag "$COMPOSE_PROJECT_NAME-ci-$TOP_LAYER:1" "$CI_IMAGE"
tools init-secrets
docker compose up -d --remove-orphans forgejo ports proxy ci-proxy forge-proxy dispatcher ci-docker gatekeeper ui

printf 'Waiting for Forgejo'
i=0
until docker compose exec -T forgejo curl -fsS http://127.0.0.1:3000/api/healthz >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 90 ] || { echo; echo "Forgejo didn't start; see: docker compose logs forgejo" >&2; exit 1; }
  printf '.'
  sleep 2
done
echo

# CI: Forgejo learns the runner's secret, the job image goes into the CI engine (which
# never pulls from a registry), then the runner starts.
docker compose exec -T forgejo forgejo forgejo-cli actions register \
  --name ci --secret "$(tr -d '[:space:]' < "$STATE_DIR/secrets/ci/runner-secret")" --labels docker >/dev/null
i=0
until docker compose exec -T ci-docker docker info >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || { echo "The CI engine didn't start; see: docker compose logs ci-docker" >&2; exit 1; }
  sleep 2
done
want="$(docker image inspect -f '{{.Id}}' "$CI_IMAGE")"
have="$(docker compose exec -T ci-docker docker image inspect -f '{{.Id}}' "$CI_IMAGE" 2>/dev/null || true)"
if [ "$want" != "$have" ]; then
  echo "Loading the CI image into the CI engine..."
  docker save "$CI_IMAGE" | docker compose exec -T ci-docker docker load >/dev/null
fi
docker compose up -d ci-runner

# Agents. Each needs its forge token (bootstrap), its runner key and the Claude credential; without
# them it isn't started, rather than started into runs that can only fail.
claude_token="$STATE_DIR/secrets/claude/oauth-token"
if [ ! -s "$claude_token" ]; then
  echo "Not starting agents: put a token from \`claude setup-token\` in $claude_token first."
else
  ( umask 077; printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$(tr -d '[:space:]' < "$claude_token")" \
      > "$STATE_DIR/secrets/claude/agent.env" )
  ready=""
  for a in $(cut -f1 "$KIT_CONFIG/agents.tsv"); do
    if [ -s "$STATE_DIR/secrets/$a/token" ] && [ -s "$STATE_DIR/secrets/runner-keys/$a" ]; then
      ready="$ready $a"
    else
      echo "Not starting $a: run scripts/bootstrap.sh, then this script again."
    fi
  done
  # An agent the kit has never started comes up stopped, for the human to start in the web UI once
  # its repository is ready. Never started means no workspace, so a switch from the reference,
  # whose agents have theirs but no stopped- files, leaves them running.
  case "${NEW_AGENTS:-stopped}" in
    stopped|running) ;;
    *) echo "NEW_AGENTS is \"$NEW_AGENTS\": it must be stopped or running." >&2; exit 1 ;;
  esac
  for a in $ready; do
    if [ "${NEW_AGENTS:-stopped}" = stopped ] && ! docker volume inspect "${COMPOSE_PROJECT_NAME}_work-$a" >/dev/null 2>&1; then
      : > "$STATE_DIR/control/stopped-$a"
      echo "Starting $a stopped: start it in the web UI once its repository is ready."
    fi
  done
  [ -z "$ready" ] || docker compose up -d $ready
fi

docker compose ps
echo "Forgejo: http://localhost:${FORGE_PORT:-3000}/"
echo "The web UI: http://localhost:${UI_PORT:-3002}/, signing in with the key in $STATE_DIR/secrets/ui/key"
