#!/usr/bin/env bash
# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# Build and start Forgejo, CI, the proxies and the webhook sink. Safe to re-run.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
confirm "This builds the kit's images and starts or recreates its containers"
# Mounted into containers; must exist before Docker creates them as root.
mkdir -p "$STATE_DIR/secrets/ci" "$STATE_DIR/secrets/dispatcher" "$STATE_DIR/secrets/gatekeeper" \
  "$STATE_DIR/secrets/github" "$STATE_DIR/secrets/runner-keys" "$STATE_DIR/control" "$STATE_DIR/proxy"
# Extra domains for Forgejo's proxy: empty except while an import runs.
[ -e "$STATE_DIR/proxy/domains.txt" ] || : > "$STATE_DIR/proxy/domains.txt"

# The images up to the project's top layer, and the kit's services.
images="agent-base agent-lean ci-lean kit-build"
[ "$TOP_LAYER" = lasm ] && images="$images agent-lasm ci-lasm"
docker compose --profile build build $images
# After kit-build, whose image it copies from.
docker compose build gatekeeper
docker compose --profile tools build tools
docker tag "$COMPOSE_PROJECT_NAME-ci-$TOP_LAYER:1" "$CI_IMAGE"
tools init-secrets
docker compose up -d --remove-orphans forgejo ports proxy ci-proxy forge-proxy sink ci-docker gatekeeper

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
docker compose ps
echo "Forgejo: http://localhost:${FORGE_PORT:-3000}/"
