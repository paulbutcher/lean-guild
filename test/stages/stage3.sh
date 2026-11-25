#!/usr/bin/env bash
# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# Stage 3's acceptance: the reference's stage 1, ported, and the push mirrors.
#   - the plain test project, mirroring to a second organisation in its own Forgejo:
#     bootstrap is idempotent, the networks allow only what they should, CI builds in its
#     own engine and fetches a dependency named by GitHub URL from Forgejo, an owner can't
#     tag or release, webhooks reach the dispatcher, and the mirror carries
#     main and the release tag;
#   - the same project deployed with mirrors off: bootstrap succeeds with no mirror token,
#     creates no mirror, and nothing leaves the test Forgejo;
#   - the browser project: its images carry the Lasm layer, Node's fetch goes through the
#     proxy, and WebKit is there beside Chromium.
# Each deployment has its own compose project and state, and is removed at the end
# unless KEEP=1. Run it in the dev container, never against the host's engine.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
# allows DESCRIPTION COMMAND...: the command must succeed.
allows() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d"; fi; }
# refuses DESCRIPTION COMMAND...: the command must fail.
refuses() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then fail "$d"; else pass "$d"; fi; }

(cd test && lake build kit-plain kit-browser >/dev/null)
export COMPOSE_FILE="compose.yaml:test/compose.test.yaml" KIT_YES=1

# deploy NAME KIT PORT [SETTING=VALUE...]: a deployment's settings, in its own state.
deploy() {
  local name="$1" kit="$2" port="$3" dir="$root/test/.lake/stages/$1"
  shift 3
  mkdir -p "$dir"
  {
    echo "COMPOSE_PROJECT_NAME=guild-test-$name"
    echo "FORGE_ORG=testorg"
    echo "HUMAN_USER=tester"
    echo "HUMAN_EMAIL=tester@noreply.localhost"
    echo "HUMAN_PASSWORD=$(openssl rand -hex 12)"
    echo "FORGE_PORT=$port"
    echo "FORGE_WEB_URL=http://localhost:$port"
    echo "STATE_DIR=state"
    printf '%s\n' "$@"
  } > "$dir/settings.env"
  export KIT_ENV="$dir/settings.env" KIT="$root/test/.lake/build/bin/$kit"
  # A kept deployment from an earlier run, and its secrets, which belong to its Forgejo.
  dc --profile tools down -v --remove-orphans >/dev/null 2>&1 || true
  rm -rf "${dir:?}/state"
}
in_kit() { test/stages/in-kit.sh "$@"; }
dc() { in_kit docker compose "$@"; }
tools() { dc run --rm tools "$@"; }
remove() {
  [ "${KEEP:-}" = 1 ] && { echo "INFO: kept $1"; return; }
  dc --profile tools down -v --remove-orphans >/dev/null 2>&1 || true
}

echo "== The plain project, mirroring to a second organisation"
deploy plain kit-plain 3310 MIRROR_BASE=http://forgejo:3000
trap 'remove plain' EXIT
scripts/up.sh
# A first bootstrap makes the human's account and token, with which the test makes the
# mirrors' second organisation and their token.
MIRRORS=off scripts/bootstrap.sh >/dev/null
tools api POST /orgs '{"username":"testbed","visibility":"private"}' >/dev/null
for r in testbed-coordination testbed-base testbed-app; do
  tools api POST /orgs/testbed/repos "{\"name\":\"$r\",\"private\":true}" >/dev/null
  # As on GitHub, the mirror runs no CI of its own here.
  tools api PATCH "/repos/testbed/$r" '{"has_actions":false}' >/dev/null
done
state="$(in_kit sh -c 'echo "$STATE_DIR"')"
cp "$state/secrets/human/token" "$state/secrets/github/mirror-token"
scripts/bootstrap.sh >/dev/null
n="$(scripts/bootstrap.sh 2>/dev/null | tail -1)"
[ "$n" = 0 ] && pass "re-running bootstrap changes nothing" || fail "re-running bootstrap made $n change(s)"
tools test-push-fixtures </dev/null >/dev/null
# 3: it opened a pull request with the files a level needs.
s=0; scripts/setup-repo.sh >/dev/null || s=$?
[ "$s" = 0 ] || [ "$s" = 3 ] && pass "setup-repo set up every repository" || fail "setup-repo exited $s"
bound="$(dc port ports 3000)"
case "$bound" in
  127.0.0.1:*) pass "Forgejo is published on $bound only" ;;
  *) fail "Forgejo is published on $bound" ;;
esac

echo "== Agents' network (probe container)"
dc --profile tools up -d probe >/dev/null 2>&1
p() { dc exec -T probe "$@"; }
allows  "an agent reaches github.com through the proxy" p curl -fsS -m 20 -o /dev/null https://github.com
allows  "an agent reaches Anthropic through the proxy" p curl -sS -m 20 -o /dev/null https://api.anthropic.com
refuses "an agent can't reach api.github.com" p curl -fsS -m 20 -o /dev/null https://api.github.com
refuses "an agent can't reach an unlisted domain" p curl -fsS -m 20 -o /dev/null https://example.com
refuses "without the Lasm layer, an agent can't reach npm" p curl -fsS -m 20 -o /dev/null https://registry.npmjs.org/
refuses "an agent has no direct route out" p curl -fsS -m 10 --noproxy '*' -o /dev/null https://github.com
allows  "an agent reaches Forgejo directly" p curl -fsS -m 10 -o /dev/null http://forgejo:3000/api/healthz
allows  "an agent reaches the dispatcher directly" p curl -fsS -m 10 -o /dev/null http://dispatcher:8080/healthz
dc --profile tools rm -sf probe >/dev/null 2>&1

echo "== Forgejo's egress"
f() { dc exec -T forgejo "$@"; }
refuses "Forgejo has no direct route out" f curl -fsS -m 10 --noproxy '*' -o /dev/null https://github.com
allows  "Forgejo reaches github.com through forge-proxy" f curl -fsS -m 20 -x http://forge-proxy:3128 -o /dev/null https://github.com
refuses "Forgejo can't reach api.github.com" f curl -fsS -m 20 -x http://forge-proxy:3128 -o /dev/null https://api.github.com

echo "== CI jobs' network (as a job runs: host network of the CI engine)"
ci_image="$(in_kit sh -c 'echo "$CI_IMAGE"')"
j() { dc exec -T ci-docker docker run --rm --network host "$ci_image" "$@"; }
refuses "a job has no direct route out" j curl -fsS -m 10 -o /dev/null https://github.com
allows  "a job reaches github.com through ci-proxy" j curl -fsS -m 20 -x http://ci-proxy:3128 -o /dev/null https://github.com
refuses "a job can't reach an unlisted domain" j curl -fsS -m 20 -x http://ci-proxy:3128 -o /dev/null https://example.com
allows  "a job reaches Forgejo" j curl -fsS -m 10 -o /dev/null http://forgejo:3000/api/healthz
refuses "a job can't reach the agents' network" j curl -fsS -m 10 -o /dev/null http://dispatcher:8080/healthz
refuses "a job can't use the CI engine's API (plain)" j curl -fsS -m 5 http://127.0.0.1:2375/version
refuses "a job can't use the CI engine's API (TLS, no client certificate)" j curl -fsSk -m 5 https://127.0.0.1:2376/version

echo "== Forgejo API: registration, CI, permissions, mirrors"
start="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if tools test-stage1; then :; else fails=$((fails + 1)); fi

echo "== Webhooks (the dispatcher, since $start)"
events="$(dc exec -T dispatcher cat /state/events.jsonl 2>/dev/null \
  | awk -v s="$start" -F'"at": "' '{ split($2, a, "\""); if (a[1] >= s) print }' || true)"
if [ -z "$events" ]; then
  fail "the dispatcher received no webhooks during the test"
else
  pass "the dispatcher received $(printf '%s\n' "$events" | grep -c .) webhooks"
  echo "INFO: event types: $(printf '%s\n' "$events" | sed -n 's/.*"type": "\([^"]*\)".*/\1/p' | sort | uniq -c | tr -s ' ' | tr '\n' ';')"
  if printf '%s\n' "$events" | grep -q '"type": "action_run_failure"'; then
    pass "Forgejo sends a webhook when a CI run fails"
  else
    echo "INFO: no webhook for a failed CI run; the dispatcher must read Actions runs"
  fi
fi
remove plain
trap - EXIT

echo "== The plain project, deployed with mirrors off"
deploy off kit-plain 3311 MIRRORS=off
trap 'remove off' EXIT
scripts/up.sh >/dev/null
if scripts/bootstrap.sh >/dev/null; then
  pass "bootstrap succeeds with mirrors off and no mirror token"
else
  fail "bootstrap failed with mirrors off"
fi
if tools test-mirrors-off; then :; else fails=$((fails + 1)); fi
log="$(dc exec -T forge-proxy cat /var/log/squid/access.log 2>/dev/null || true)"
[ -z "$log" ] && pass "nothing left the test Forgejo" || fail "forge-proxy carried: $(printf '%s\n' "$log" | head -3)"
remove off
trap - EXIT

echo "== The browser project: the Lasm layer"
deploy browser kit-browser 3312 MIRRORS=off
trap 'remove browser' EXIT
scripts/up.sh >/dev/null
scripts/bootstrap.sh >/dev/null && pass "bootstrap succeeds for a project with a site" || fail "bootstrap failed for the browser project"
dc --profile tools up -d probe >/dev/null 2>&1
allows "Node's fetch goes through the proxy in an agent's container" dc exec -T probe \
  node -e "fetch('https://registry.npmjs.org/').then(r => process.exit(r.ok ? 0 : 1), () => process.exit(1))"
allows "an agent's image has Playwright's WebKit beside Chromium" dc exec -T probe \
  sh -c 'ls /opt/ms-playwright | grep -q webkit && ls /opt/ms-playwright | grep -q chromium'
ci_image="$(in_kit sh -c 'echo "$CI_IMAGE"')"
allows "the CI image has Playwright's WebKit beside Chromium" dc exec -T ci-docker docker run --rm "$ci_image" \
  sh -c 'ls /opt/ms-playwright | grep -q webkit && ls /opt/ms-playwright | grep -q chromium'
remove browser
trap - EXIT

echo
[ "$fails" = 0 ] && echo "Stage 3: all checks passed." || { echo "Stage 3: $fails check(s) failed."; exit 1; }
