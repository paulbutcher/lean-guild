#!/usr/bin/env bash
# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# Stage 7's acceptance without Claude runs: the dispatcher in the plain test project, with
# runners stood in for by the agents' own keys over HTTP, reading its status JSON where the
# reference's tests read status.sh and setting control/ where they ran pause.sh, resume.sh
# and drain.sh.
#   - webhooks are recorded and evaluated: a request filed is its owner's to triage, and the
#     coordinator's to look at;
#   - paused, no claim is granted; draining, none either, and the status says when it is safe
#     to stop; resumed, the work is claimed, and the run's start and end are recorded;
#   - a stopped agent gets no claim while others do;
#   - a request filed while the dispatcher is down is found when it starts;
#   - a burst of comments becomes one claim;
#   - CI that fails the same way after its re-run notifies the human on the pull request.
# The plain test project is deployed with mirrors off, in its own compose project, and removed
# at the end unless KEEP=1. Run it in the dev container, never against the host's engine.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
(cd test && lake build kit-plain >/dev/null)
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

name=dispatch
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
  echo "FORGE_PORT=3316"
  echo "DISPATCHER_PORT=3317"
  echo "FORGE_WEB_URL=http://localhost:3316"
  echo "STATE_DIR=state"
  echo "MIRRORS=off"
  # A burst settles in seconds rather than a minute, so the test needn't wait.
  echo "DEBOUNCE_SECONDS=5"
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
# The bootstrap made the dispatcher's token and keys after it started: it waited for them.
state="$dir/state"
control="$state/control"

# in_dispatcher ARGS...: curl against the dispatcher, from inside its own container.
in_dispatcher() { dc exec -T dispatcher curl -sS "$@"; }
status() { in_dispatcher http://127.0.0.1:8080/status; }
jqs() { status | jq -r "$@"; }
# runner AGENT PATH [BODY]: a runner's request, with the agent's runner key; prints the code
# then the body.
runner() {
  local key data="${3:-}"
  [ -n "$data" ] || data="{}"
  key="$(tr -d '[:space:]' < "$state/secrets/runner-keys/$1")"
  in_dispatcher -o /dev/stdout -w '\n%{http_code}' -X POST -H "Authorization: Bearer $key" \
    -H 'Content-Type: application/json' -d "$data" "http://127.0.0.1:8080$2"
}
code() { printf '%s\n' "$1" | tail -1; }
body() { printf '%s\n' "$1" | sed '$d'; }
# as ACCOUNT METHOD PATH [BODY]: the forge's API as one of the kit's accounts.
as() {
  local token
  token="$(tr -d '[:space:]' < "$state/secrets/$1/token")"
  dc run --rm -T --no-deps --entrypoint curl tools -sS -X "$2" -H "Authorization: token $token" \
    -H 'Content-Type: application/json' ${4:+-d "$4"} "http://forgejo:3000/api/v1$3" </dev/null
}
human() { dc run --rm -T tools api "$@" </dev/null; }
# until_true SECONDS COMMAND...: until the command succeeds.
until_true() {
  local deadline=$(( $(date +%s) + $1 ))
  shift
  while [ "$(date +%s)" -lt "$deadline" ]; do
    "$@" >/dev/null 2>&1 && return 0
    sleep 3
  done
  return 1
}
request() {
  human POST "/repos/testorg/$1/issues" "$(jq -nc --arg t "$2" '{title: $t, body: "Please."}')" | jq -r .number
}

# Each repository with a main, as a project's have.
for r in testbed-coordination testbed-base testbed-app; do
  human POST "/repos/testorg/$r/contents" "$(jq -nc --arg c "$(printf '# %s\n' "$r" | base64 -w0)" \
    '{branch: "main", message: "A first commit", files: [{operation: "create", path: "README.md", content: $c}]}')" >/dev/null || true
done

echo "== The dispatcher"
until_true 120 in_dispatcher -f http://127.0.0.1:8080/healthz && pass "it answers" || fail "it never answered"
s="$(status || true)"
printf '%s' "$s" | jq -e '.agents | has("coordinator") and has("base") and has("app")' >/dev/null \
  && pass "its status lists every agent" || fail "its status: $s"
until_true 120 sh -c "[ \"\$(\"$root/test/stages/in-kit.sh\" docker compose exec -T dispatcher curl -s http://127.0.0.1:8080/status | jq -r .reconciled)\" != null ]" \
  && pass "its first sweep ran" || fail "its first sweep never finished"

echo "== A request filed"
req="$(request testbed-base "A request from the human")"
human POST "/repos/testorg/testbed-base/issues/$req/labels" '{"labels": ["request"]}' >/dev/null
unit="testbed-base#$req"
until_true 60 sh -c "\"$root/test/stages/in-kit.sh\" docker compose exec -T dispatcher curl -s http://127.0.0.1:8080/status \
  | jq -e --arg u '$unit' '.units[] | select(.unit == \$u and .state == \"untriaged\")'" \
  && pass "$unit is untriaged, its owner's" || fail "$unit's state: $(jqs --arg u "$unit" '.units[] | select(.unit == $u)')"
[ "$(jqs '.agents.base.pending | length')" -ge 1 ] && pass "base has work queued" || fail "base has nothing queued"
jqs '.agents.coordinator.pending[].trigger' | grep -q "request filed: $unit" \
  && pass "the coordinator is told of the filing" || fail "the coordinator wasn't told: $(jqs '.agents.coordinator.pending')"
[ "$(dc exec -T dispatcher sh -c 'wc -l < /state/events.jsonl' | tr -d ' ')" -gt 0 ] \
  && pass "the dispatcher keeps the webhooks it received" || fail "no webhooks kept"

echo "== Paused"
sleep 6  # past the debounce
touch "$control/paused"
r="$(runner base /claim)"
[ "$(code "$r")" = 204 ] && pass "no claim while paused" || fail "a claim while paused: $r"
[ "$(jqs .paused)" = true ] && [ "$(jqs .agents.base.state)" = paused ] && pass "the status says so" \
  || fail "the status: paused $(jqs .paused), base $(jqs .agents.base.state)"
has "$(jqs .summary)" "Kit: paused" && pass "and so does its summary" || fail "the summary: $(jqs .summary)"

echo "== Draining"
rm "$control/paused"
touch "$control/draining"
r="$(runner base /claim)"
[ "$(code "$r")" = 204 ] && pass "no claim while draining" || fail "a claim while draining: $r"
until_true 120 sh -c "[ \"\$(\"$root/test/stages/in-kit.sh\" docker compose exec -T dispatcher curl -s http://127.0.0.1:8080/status | jq -r .drained)\" = true ]" \
  && pass "drained once nothing is under way" || fail "never drained: $(jqs .under_way)"
has "$(jqs .summary)" "safe to stop" && pass "its summary says it is safe to stop" || fail "the summary: $(jqs .summary)"

echo "== Resumed"
rm "$control/draining"
r="$(runner base /claim)"
if [ "$(code "$r")" = 200 ] && has "$(body "$r")" "$unit"; then
  pass "base claims its work: $(body "$r" | jq -c .triggers)"
else
  fail "base's claim: $r"
fi
run="$(body "$r" | jq -r .run 2>/dev/null || true)"
runner base "/runs/$run/start" '{"session_id": "s-1", "log": "/workspace/.guild/current.md"}' >/dev/null
[ "$(jqs .agents.base.state)" = running ] && pass "base is running" || fail "base: $(jqs .agents.base.state)"
r="$(runner base /claim)"
[ "$(code "$r")" = 204 ] && pass "no second claim while it runs" || fail "a second claim: $r"
runner base "/runs/$run/end" '{"outcome": "completed", "turns": 7, "cost": 0.25, "in_extension": true, "denied": []}' >/dev/null
[ "$(jqs --argjson r "$run" '.runs[] | select(.id == $r) | .outcome')" = completed ] \
  && pass "its end is recorded" || fail "the run: $(jqs --argjson r "$run" '.runs[] | select(.id == $r)')"

echo "== A stopped agent"
app_req="$(request testbed-app "A request for app")"
human POST "/repos/testorg/testbed-app/issues/$app_req/labels" '{"labels": ["request"]}' >/dev/null
until_true 60 sh -c "[ \"\$(\"$root/test/stages/in-kit.sh\" docker compose exec -T dispatcher curl -s http://127.0.0.1:8080/status | jq -r '.agents.app.pending | length')\" -ge 1 ]" \
  || fail "app was given no work"
touch "$control/stopped-app"
sleep 6
r="$(runner app /claim)"
[ "$(code "$r")" = 204 ] && pass "no claim for a stopped agent" || fail "a claim for a stopped agent: $r"
[ "$(jqs .agents.app.state)" = stopped ] && pass "the status says it is stopped" || fail "app: $(jqs .agents.app.state)"
rm "$control/stopped-app"
r="$(runner app /claim)"
[ "$(code "$r")" = 200 ] && pass "started again, it claims its work" || fail "app's claim: $r"
run="$(body "$r" | jq -r .run 2>/dev/null || true)"
runner app "/runs/$run/end" '{"outcome": "completed", "turns": 3, "cost": 0.1}' >/dev/null

echo "== Reconciliation"
dc stop dispatcher >/dev/null 2>&1
missed="$(request testbed-app "Filed while the dispatcher is down")"
human POST "/repos/testorg/testbed-app/issues/$missed/labels" '{"labels": ["request"]}' >/dev/null
dc start dispatcher >/dev/null 2>&1
until_true 120 sh -c "\"$root/test/stages/in-kit.sh\" docker compose exec -T dispatcher curl -s http://127.0.0.1:8080/status \
  | jq -e '.units[] | select(.unit == \"testbed-app#$missed\")'" \
  && pass "a request filed while it was down is found when it starts" || fail "testbed-app#$missed was never found"

echo "== A burst is one claim"
for i in 1 2 3; do
  human POST "/repos/testorg/testbed-base/issues/$req/comments" "$(jq -nc --arg b "Question $i?" '{body: $b}')" >/dev/null
done
until_true 60 sh -c "\"$root/test/stages/in-kit.sh\" docker compose exec -T dispatcher curl -s http://127.0.0.1:8080/status \
  | jq -e '.agents.base.pending[] | select(.trigger | test(\"comment on\"))'" || fail "the comments were never queued for base"
sleep 8
r="$(runner base /claim)"
[ "$(code "$r")" = 200 ] && [ "$(body "$r" | jq '[.triggers[] | select(test("comment on"))] | length')" = 1 ] \
  && pass "three comments are one claim, for the newest" || fail "the claim: $r"
run="$(body "$r" | jq -r .run 2>/dev/null || true)"
runner base "/runs/$run/end" '{"outcome": "completed", "turns": 4, "cost": 0.2}' >/dev/null

echo "== CI that fails again after its re-run"
b64() { printf '%s' "$1" | base64 -w0; }
human POST /repos/testorg/testbed-base/contents "$(jq -nc --arg w "$(b64 'on: [pull_request]
name: checks
jobs:
  build:
    runs-on: docker
    steps:
      - run: exit 1
')" '{branch: "main", new_branch: "always-fails", message: "A CI that always fails",
      files: [{operation: "create", path: ".forgejo/workflows/checks.yml", content: $w}]}')" >/dev/null
pr="$(as base POST /repos/testorg/testbed-base/pulls '{"head": "always-fails", "base": "main", "title": "Always fails"}' | jq -r .number)"
probe() {
  dc run --rm -T --entrypoint "" -e AGENT_NAME=base -e AGENT_REPO=testbed-base -e FORGE_ORG=testorg \
    -e RERUN_LIMIT=1 -v "$state/secrets/base/token:/run/secrets/forgejo_token:ro" probe "$@" </dev/null
}
until_true 600 sh -c "\"$root/test/stages/in-kit.sh\" docker compose run --rm -T --entrypoint '' -e AGENT_NAME=base -e FORGE_ORG=testorg \
  -v '$state/secrets/base/token:/run/secrets/forgejo_token:ro' probe forge ci testbed-base $pr </dev/null | grep -q 'failure ('" \
  && pass "CI fails on pull request $pr" || fail "CI never failed on pull request $pr"
s="$(probe forge ci testbed-base "$pr" --rerun 2>&1 || true)"
has "$s" "1 of the 1" && pass "its author re-runs it once" || fail "the re-run: $s"
until_true 600 sh -c "\"$root/test/stages/in-kit.sh\" docker compose run --rm -T tools api GET /repos/testorg/testbed-base/issues/$pr/comments </dev/null \
  | jq -e '.[] | select(.body | test(\"after 1 re-run\"))'" \
  && pass "failing again, the human is told on the pull request" || fail "no notice on pull request $pr"
jqs '.notices[].kind' | grep -qx reruns && pass "and it is a notice in the status" || fail "no reruns notice: $(jqs '.notices')"

echo
[ "$fails" = 0 ] && echo "Stage 7: all checks passed." || { echo "Stage 7: $fails check(s) failed."; exit 1; }
