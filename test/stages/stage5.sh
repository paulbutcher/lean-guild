#!/usr/bin/env bash
# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# Stage 5's acceptance: the reference's stage 6, ported, with the gatekeeper built here.
#   - setup-repo puts testbed-base at level 2, through a pull request the human merges;
#   - the gatekeeper approves a pull request once the CI run for its head succeeded, and with
#     conformance's approval its scheduled merge goes through; a new commit dismisses the
#     approval, and the gatekeeper approves the new head once its run succeeds;
#   - a status posted under CI's name on a failing build gets no approval, and it doesn't merge;
#   - a pull request changing API.lock waits for the human after both approvals;
#   - while control/paused exists the gatekeeper approves nothing, and once it's gone it does;
#   - the human's release, through the gatekeeper's command line, tags main and publishes.
# The plain test project is deployed with mirrors off, in its own compose project, and
# removed at the end unless KEEP=1. Run it in the dev container, never against the host's
# engine. About 20 minutes.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
(cd test && lake build kit-plain >/dev/null)
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

name=gate
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
  echo "FORGE_PORT=3314"
  echo "FORGE_WEB_URL=http://localhost:3314"
  echo "STATE_DIR=state"
  echo "MIRRORS=off"
  echo "GATEKEEPER_SWEEP_SECONDS=30"
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

keys="$(mktemp)"
# phase NAME [ARG...]: a phase of test/stages/gate.sh in the tools container.
phase() {
  local out
  out="$(dc run --rm -T tools test-gate "$@" </dev/null 2>/dev/null || true)"
  printf '%s\n' "$out" | grep -E '^(PASS|FAIL|INFO)' || true
  printf '%s\n' "$out" | grep -q '^FAIL' && fails=$((fails + 1))
  printf '%s\n' "$out" | grep -E '^[A-Z]+ [0-9]+$' >> "$keys" || true
}
key() { awk -v k="$1" '$1 == k { print $2 }' "$keys" | tail -1; }

scripts/up.sh >/dev/null
scripts/bootstrap.sh >/dev/null
state="$dir/state"

echo "== testbed-base at level 2"
phase start
s=0; scripts/setup-repo.sh testbed-base 2 >/dev/null 2>&1 || s=$?
[ "$s" = 3 ] && pass "setup opened a pull request with the files level 2 needs" || fail "setup exited $s"
phase merge-setup
s=0; scripts/setup-repo.sh testbed-base 2 >/dev/null 2>&1 || s=$?
[ "$s" = 0 ] && pass "after the merge, setup finds testbed-base right for level 2" || fail "setup exited $s after the merge"
phase quick-ci

echo "== An ordinary pull request"
phase good

echo "== A status posted under CI's name on a failing build"
phase spoof

echo "== An API.lock change"
phase apilock

echo "== Paused, through the control state"
: > "$state/control/paused"
phase paused-pr
rm -f "$state/control/paused"
phase resumed "$(key PAUSED)"

echo "== The human's release"
phase changelog
if out="$(dc run --rm -T -e TOKEN_FILE=/run/secrets/human/token -v "$state/secrets/human:/run/secrets/human:ro" \
    gatekeeper release --human testbed-base "The first release." </dev/null 2>&1)"; then
  pass "the human released testbed-base through the gatekeeper: $(printf '%s' "$out" | grep -o '"version": "[^"]*"')"
else
  fail "the human's release: $(printf '%s' "$out" | tail -3)"
fi
phase released

echo "== The gatekeeper's log"
log="$(dc logs gatekeeper 2>&1 || true)"
printf '%s\n' "$log" | grep -q 'paused: approving and releasing nothing' \
  && pass "it logged the pause" || fail "it didn't log the pause"
printf '%s\n' "$log" | grep -q 'gatekeeper: running' && pass "it logged resuming" || fail "it didn't log resuming"
rm -f "$keys"

echo
[ "$fails" = 0 ] && echo "Stage 5: all checks passed." || { echo "Stage 5: $fails check(s) failed."; exit 1; }
