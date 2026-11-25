#!/usr/bin/env bash
# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# Stage 4's acceptance: the contract tests pass against a real Forgejo, as `lake test` shows they
# do against the fake. The plain test project is deployed with mirrors off, in its own compose
# project, and removed at the end unless KEEP=1. Run it in the dev container, never against the
# host's engine.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
(cd test && lake build kit-plain contract >/dev/null)

name=contract
dir="$root/test/.lake/stages/$name"
export COMPOSE_FILE="compose.yaml:test/compose.test.yaml" KIT_YES=1
export KIT_ENV="$dir/settings.env" KIT="$root/test/.lake/build/bin/kit-plain"
mkdir -p "$dir"
{
  echo "COMPOSE_PROJECT_NAME=guild-test-$name"
  echo "FORGE_ORG=testorg"
  echo "HUMAN_USER=tester"
  echo "HUMAN_EMAIL=tester@noreply.localhost"
  echo "HUMAN_PASSWORD=$(openssl rand -hex 12)"
  echo "FORGE_PORT=3313"
  echo "FORGE_WEB_URL=http://localhost:3313"
  echo "STATE_DIR=state"
  echo "MIRRORS=off"
} > "$dir/settings.env"
dc() { "$root/test/stages/in-kit.sh" docker compose "$@"; }
# A kept deployment from an earlier run, and its secrets, which belong to its Forgejo.
dc --profile tools down -v --remove-orphans >/dev/null 2>&1 || true
rm -rf "${dir:?}/state"
remove() {
  [ "${KEEP:-}" = 1 ] && { echo "INFO: kept $name"; return; }
  dc --profile tools down -v --remove-orphans >/dev/null 2>&1 || true
}
trap remove EXIT

scripts/up.sh >/dev/null
scripts/bootstrap.sh >/dev/null
# The base library's owner writes to it; the coordinator approves there; an architecture
# reviewer may only file issues.
cd test
FORGE_URL=http://localhost:3313 FORGE_ORG=testorg SECRETS="$dir/state/secrets" HUMAN_USER=tester \
  CONTRACT_REPO=testbed-base CONTRACT_OWNER=base CONTRACT_REVIEWER=coordinator \
  CONTRACT_OUTSIDER=architecture lake exe contract
