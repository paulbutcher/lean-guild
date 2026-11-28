#!/usr/bin/env bash
# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# Stage 12's acceptance, in the browser test project, whose configuration has the macOS runner:
#   - with no runner serving the deployment (MACOS_RUNNER off), the macos job is skipped and CI
#     passes, the build job having run the browser tests in Chromium and WebKit;
#   - with MACOS=1, the deployment has MACOS_RUNNER on, and the test waits, up to MACOS_WAIT
#     minutes (60), for scripts/macos-runner.sh on the Mac to run the macos job: the browser tests
#     in Safari, WebKit and Chrome, drawing on the GPU;
#   - npm's cache is kept between jobs: a second run fetches nothing from the registry, two
#     installs at once leave the cache whole, and with the registry unreachable a third run
#     still installs from the cache.
# Removed at the end unless KEEP=1. Run it in the dev container, never against the host's engine.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
(cd test && lake build kit-browser >/dev/null)
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

name=macos
dir="$root/test/.lake/stages/$name"
macos="${MACOS:-}"
export COMPOSE_FILE="compose.yaml:test/compose.test.yaml" KIT_YES=1 NEW_AGENTS=running
export KIT_ENV="$dir/settings.env" KIT="$root/test/.lake/build/bin/kit-browser"
mkdir -p "$dir"
{
  echo "COMPOSE_PROJECT_NAME=guild-test-$name"
  echo "FORGE_ORG=testorg"
  echo "HUMAN_USER=tester"
  echo "HUMAN_EMAIL=tester@noreply.localhost"
  echo "HUMAN_PASSWORD=$(openssl rand -hex 12)"
  echo "FORGE_PORT=3340"
  echo "DISPATCHER_PORT=3341"
  echo "UI_PORT=3342"
  echo "FORGE_WEB_URL=http://localhost:3340"
  echo "STATE_DIR=state"
  echo "MIRRORS=off"
  echo "MACOS_RUNNER=$([ "$macos" = 1 ] && echo on || echo off)"
} > "$dir/settings.env"
dc() { "$root/test/stages/in-kit.sh" docker compose "$@"; }
dc --profile tools down -v --remove-orphans >/dev/null 2>&1 || true
rm -rf "${dir:?}/state"
remove() {
  [ "${KEEP:-}" = 1 ] && { echo "INFO: kept $name"; return; }
  dc --profile tools down -v --remove-orphans >/dev/null 2>&1 || true
}
trap remove EXIT

scripts/up.sh >/dev/null
scripts/bootstrap.sh >/dev/null
state="$dir/state"

until_true() {
  local deadline=$(( $(date +%s) + $1 ))
  shift
  while [ "$(date +%s)" -lt "$deadline" ]; do
    "$@" >/dev/null 2>&1 && return 0
    sleep 10
  done
  return 1
}
get() { dc run --rm -T --no-deps --entrypoint curl tools -fsS -H "Authorization: token $(tr -d '[:space:]' < "$state/secrets/human/token")" \
  "http://forgejo:3000/api/v1/repos/testorg/webbed-ui/$1" </dev/null; }

echo "== The browser fixture"
dc run --rm -T tools test-push-fixture webbed-ui </dev/null
# Forgejo serves a push's files a moment after it accepts it.
until_true 120 get "raw/lakefile.toml?ref=main" || fail "webbed-ui's fixture never appeared"
head="$(get branches/main | jq -r .commit.id)"
run_of() { get "actions/runs?head_sha=$head" | jq -r '[.workflow_runs[]?][0] // empty'; }
done_() { case "$(run_of | jq -r .status)" in success|failure|cancelled) return 0 ;; *) return 1 ;; esac; }
jobs_() { get "actions/runs/$(run_of | jq -r .id)/jobs" | jq -c '[(if type == "array" then . else .jobs end)[] | {id, name, status}]'; }
log_of() { get "actions/jobs/$(jobs_ | jq -r --arg n "$1" '.[] | select(.name == $n) | .id')/logs"; }

if [ "$macos" = 1 ]; then
  port="$(sed -n 's/^FORGE_PORT=//p' "$KIT_ENV")"
  cat <<EOF
INFO: waiting up to ${MACOS_WAIT:-60} minutes for the macos job. On the Mac, with this checkout's path
      on the host as <checkout>, and port $port forwarded from the dev container (VS Code's Ports
      view), as <port> on the Mac:
        cd <checkout> && KIT_ENV=test/.lake/stages/$name/settings.env FORGE_HOST_PORT=<port> \\
          scripts/macos-runner.sh run
EOF
fi
until_true $(( ${MACOS_WAIT:-60} * 60 + 1800 )) done_ || true
run="$(run_of)"
[ "$(jq -r .status <<<"$run")" = success ] && pass "CI passes on the fixture" || fail "CI on the fixture: $(jq -c '{status}' <<<"$run") $(jobs_)"
build="$(log_of build || true)"
grep -q 'chromium: drew the colour' <<<"$build" && grep -q 'webkit: drew the colour' <<<"$build" \
  && pass "the build job ran the browser tests in Chromium and WebKit" || fail "the build job's log: $(tail -20 <<<"$build")"
mac="$(jobs_ | jq -r '.[] | select(.name == "macos") | .status')"
if [ "$macos" = 1 ]; then
  log="$(log_of macos || true)"
  [ "$mac" = success ] && pass "the macos job ran on the Mac" || fail "the macos job: $mac"
  for b in safari webkit chromium; do
    line="$(grep -o "$b: drew the colour.*" <<<"$log" | head -1 || true)"
    grep -q 'on the GPU' <<<"$line" && pass "$line" || fail "$b on the Mac: $(grep "$b:" <<<"$log" | head -1)"
  done
else
  [ "$mac" = skipped ] && pass "with no macOS runner, the macos job is skipped" || fail "the macos job, with no runner: ${mac:-absent}"
  status="$(get "commits/$head/status" | jq -r .state)"
  [ "$status" = success ] && pass "and the commit's status, which the dispatcher and branch protection read, is success" \
    || fail "the commit's status: $status ($(get "commits/$head/status" | jq -c '[.statuses[] | {context, status}]'))"
fi

echo "== npm's cache"
# Squid logs a tunnel when it closes, and writes its log asynchronously.
registry() { sleep 5; dc exec -T ci-proxy cat /var/log/squid/access.log | grep -c 'registry\.npmjs\.org' || true; }
post() {
  dc run --rm -T --no-deps --entrypoint curl tools -fsS -X POST -H "Authorization: token $(tr -d '[:space:]' < "$state/secrets/human/token")" \
    -H 'Content-Type: application/json' -d "$2" "http://forgejo:3000/api/v1/repos/testorg/webbed-ui/$1" </dev/null
}
# A commit to main, which runs CI again; run_of follows it.
again() {
  post "contents/notes/$1.md" "$(jq -nc --arg c "$(echo "$1" | base64 -w0)" --arg m "$1" '{content: $c, message: $m, branch: "main"}')" >/dev/null
  head="$(get branches/main | jq -r .commit.id)"
  until_true 1800 done_ || true
}
installed() { log_of build | grep -q 'added [0-9]* packages'; }
first="$(registry)"
[ "$first" -gt 0 ] && pass "the first run fetched from the registry ($first tunnels)" || fail "the first run fetched nothing from the registry"
again second
[ "$(run_of | jq -r .status)" = success ] && installed && [ "$(registry)" = "$first" ] \
  && pass "a second run's npm ci fetches nothing from the registry" \
  || fail "the second run: $(run_of | jq -c '{status}'), $(registry) registry tunnels, $first before"
# Two installs at once into one empty cache, as jobs running together fill it, leave it whole.
job() {
  tar -C test/fixtures/webbed-ui/test -cf - package.json package-lock.json |
    dc exec -T ci-docker docker run --rm -i --network host -e https_proxy=http://ci-proxy:3128 \
      -e npm_config_cache=/var/cache/npm -v guild-npm-concurrent:/var/cache/npm guild-ci:1 sh -c "$1"
}
install='mkdir /p && tar -C /p -xf - && cd /p && npm ci --no-fund --no-audit'
job "$install" >/dev/null 2>&1 & a=$!
job "$install" >/dev/null 2>&1 & b=$!
wait "$a" && wait "$b" && job 'npm cache verify' </dev/null | grep -q 'Cache verified' \
  && pass "two installs at once into one cache both succeed, and leave it whole" || fail "concurrent installs into one cache"
dc exec -T ci-docker docker volume rm guild-npm-concurrent >/dev/null 2>&1 || true
# The registry, out of ci-proxy's allowlist until it restarts.
dc exec -T ci-proxy sh -c "sed -i '/registry\.npmjs\.org/d' /etc/squid/allowed-domains.txt && squid -f /etc/squid/squid.conf -k reconfigure"
sleep 2  # squid applies a reconfigure asynchronously
job 'npm_config_cache=/tmp/empty npm view playwright@1.64.1 version' </dev/null >/dev/null 2>&1 \
  && fail "the registry is still reachable" || pass "the registry is unreachable"
again third
[ "$(run_of | jq -r .status)" = success ] && installed && pass "with the registry unreachable, npm ci succeeds from the cache" \
  || fail "the third run, with the registry unreachable: $(run_of | jq -c '{status}') $(log_of build | grep -i 'npm' | tail -5)"
dc restart ci-proxy >/dev/null

echo
[ "$fails" = 0 ] && echo "Stage 12: all checks passed." || { echo "Stage 12: $fails check(s) failed."; exit 1; }
