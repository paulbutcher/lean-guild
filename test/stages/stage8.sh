#!/usr/bin/env bash
# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# Stage 8's acceptance: the reference's stage 4 checks through the web UI's JSON and actions, in
# the plain test project, with runners stood in for over HTTP, so nothing is spent.
#   - the UI is on no network an agent is on; without a session every page and action is sent to
#     sign in, a wrong key doesn't sign in, and signed in, an action without its token is refused;
#   - pause: scheduled merges are cancelled and recorded, only the human may merge, and the pages
#     say so; while paused, events queue work for the right agents and needs-human is a notice;
#   - a request filed while the dispatcher is down is found when it starts;
#   - a notice is marked seen; resume restores who may merge and remakes the merge in the
#     human's name; drain says when it is safe to stop, and resume ends it;
#   - an agent is stopped and started, and a run asked to stop; the activity and reviews pages
#     answer.
# Deployed with mirrors off, in its own compose project, and removed at the end unless KEEP=1.
# Run it in the dev container, never against the host's engine.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
(cd test && lake build kit-plain >/dev/null)
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

name=ui
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
  echo "FORGE_PORT=3322"
  echo "DISPATCHER_PORT=3323"
  echo "UI_PORT=3324"
  echo "FORGE_WEB_URL=http://localhost:3322"
  echo "STATE_DIR=state"
  echo "MIRRORS=off"
  echo "DEBOUNCE_SECONDS=5"
} > "$dir/settings.env"
dc() { "$root/test/stages/in-kit.sh" docker compose "$@"; }
dc --profile tools down -v --remove-orphans >/dev/null 2>&1 || true
rm -rf "${dir:?}/state" "$dir/cookies"
remove() {
  [ "${KEEP:-}" = 1 ] && { echo "INFO: kept $name"; return; }
  dc --profile tools down -v --remove-orphans >/dev/null 2>&1 || true
}
trap remove EXIT

scripts/up.sh >/dev/null
scripts/bootstrap.sh >/dev/null
state="$dir/state"
control="$state/control"
site=http://127.0.0.1:3324
jar="$dir/cookies"

until_true() {
  local deadline=$(( $(date +%s) + $1 ))
  shift
  while [ "$(date +%s)" -lt "$deadline" ]; do
    "$@" >/dev/null 2>&1 && return 0
    sleep 3
  done
  return 1
}
human() { dc run --rm -T tools api "$@" </dev/null; }
as() {
  local token
  token="$(tr -d '[:space:]' < "$state/secrets/$1/token")"
  dc run --rm -T --no-deps --entrypoint curl tools -sS -X "$2" -H "Authorization: token $token" \
    -H 'Content-Type: application/json' ${4:+-d "$4"} "http://forgejo:3000/api/v1$3" </dev/null
}
# The UI, as a browser holding the session's cookie.
ui() { curl -sS -b "$jar" -c "$jar" "$@"; }
uijson() { ui -H 'Accept: application/json' "$site${1:-/}"; }
token() { ui "$site/" | grep -o 'X-CSRF-Token&quot;: &quot;[^&]*' | sed 's/.*&quot;//'; }
# uipost PATH: an action, as HTMX sends it, with the page's token; prints the status.
uipost() { local t; t="$(token)"; ui -o /dev/null -w '%{http_code}' -X POST -H "X-CSRF-Token: $t" -H 'HX-Request: true' "$site$1"; }
jqs() { uijson / | jq -r "$@"; }
pending() { uijson /agents | jq -r --arg a "$1" '.agents[$a].pending[].trigger'; }
scheduled_by() {
  human GET "/repos/testorg/$1/issues/$2/timeline?limit=200" \
    | jq -r '[.[] | select(.type == "pull_scheduled_merge" or .type == "pull_cancel_scheduled_merge")]
             | last | if . != null and .type == "pull_scheduled_merge" then .user.login else empty end'
}
request() {
  local n
  n="$(human POST "/repos/testorg/$1/issues" "$(jq -nc --arg t "$2" '{title: $t, body: "Please."}')" | jq -r .number)"
  human POST "/repos/testorg/$1/issues/$n/labels" '{"labels": ["request"]}' >/dev/null
  echo "$n"
}
in_dispatcher() { dc exec -T dispatcher curl -sS "$@"; }
runner() {
  local key
  key="$(tr -d '[:space:]' < "$state/secrets/runner-keys/$1")"
  in_dispatcher -o /dev/stdout -X POST -H "Authorization: Bearer $key" -H 'Content-Type: application/json' \
    -d "${3:-{\}}" "http://127.0.0.1:8080$2"
}

for r in testbed-coordination testbed-base testbed-app; do
  human POST "/repos/testorg/$r/contents" "$(jq -nc --arg c "$(printf '# %s\n' "$r" | base64 -w0)" \
    '{branch: "main", message: "A first commit", files: [{operation: "create", path: "README.md", content: $c}]}')" >/dev/null || true
done

echo "== Who reaches the UI"
until_true 120 curl -fsS "$site/sign-in" && pass "it answers on the host's loopback" || fail "it never answered"
# Straight there, and through the agents' proxy, which answers an error page of its own: -f.
for how in direct proxy; do
  args=(-fsS -m 10)
  [ "$how" = direct ] && args+=(--noproxy "*")
  if dc run --rm -T --entrypoint curl probe "${args[@]}" http://ui:8080/sign-in </dev/null >/dev/null 2>&1; then
    fail "an agent's network reaches it ($how)"
  else
    pass "an agent's network can't reach it ($how)"
  fi
done
code="$(curl -sS -o /dev/null -w '%{http_code}' "$site/" || true)"
[ "$code" = 303 ] && pass "a page without a session is sent to sign in" || fail "a page without a session: $code"
code="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$site/kit/pause" || true)"
[ ! -e "$control/paused" ] && pass "an action without a session changes nothing ($code)" || fail "paused without a session"
form() { ui "$site/sign-in" | grep -o 'name="__anti-forgery-token" value="[^"]*' | sed 's/.*value="//'; }
code="$(ui -o /dev/null -w '%{http_code}' -X POST --data-urlencode "key=wrong" \
  --data-urlencode "__anti-forgery-token=$(form)" "$site/sign-in")"
[ "$code" = 403 ] && pass "a wrong key doesn't sign in" || fail "a wrong key: $code"
code="$(ui -o /dev/null -w '%{http_code}' -X POST --data-urlencode "key=$(tr -d '[:space:]' < "$state/secrets/ui/key")" \
  --data-urlencode "__anti-forgery-token=$(form)" "$site/sign-in")"
[ "$code" = 303 ] && pass "the key from secrets/ui/key signs in" || fail "signing in: $code"
code="$(ui -o /dev/null -w '%{http_code}' -X POST "$site/kit/pause")"
[ "$code" = 403 ] && [ ! -e "$control/paused" ] && pass "signed in, an action without its token is refused" \
  || fail "an action without its token: $code"
until_true 120 sh -c "curl -sS -b '$jar' -H 'Accept: application/json' '$site/' | jq -e '.reconciled != null'" \
  || fail "the dispatcher's first sweep never finished"

echo "== testbed-base at level 2, with a scheduled merge"
gate() { dc run --rm -T tools test-gate "$@" </dev/null 2>/dev/null | grep -E '^(FAIL)' || true; }
gate start
scripts/setup-repo.sh testbed-base 2 >/dev/null 2>&1 || true
gate merge-setup
gate quick-ci
as base POST /repos/testorg/testbed-base/contents "$(jq -nc --arg c "$(printf 'A change.\n' | base64 -w0)" \
  '{branch: "main", new_branch: "agent/base/change", message: "A change", files: [{operation: "create", path: "change.md", content: $c}]}')" >/dev/null
pr="$(as base POST /repos/testorg/testbed-base/pulls '{"head": "agent/base/change", "base": "main", "title": "A change", "body": "(no reply needed)"}' | jq -r .number)"
until_true 60 sh -c "'$root/test/stages/in-kit.sh' docker compose run --rm -T --no-deps --entrypoint curl tools -sS -o /dev/null -w '%{http_code}' -X POST \
  -H 'Authorization: token $(tr -d '[:space:]' < "$state/secrets/base/token")' -H 'Content-Type: application/json' \
  -d '{\"Do\":\"squash\",\"merge_when_checks_succeed\":true,\"delete_branch_after_merge\":true}' \
  http://forgejo:3000/api/v1/repos/testorg/testbed-base/pulls/$pr/merge </dev/null | grep -q '^20'"
[ "$(scheduled_by testbed-base "$pr")" = base ] && pass "base scheduled the merge of testbed-base#$pr" \
  || fail "base couldn't schedule the merge of testbed-base#$pr"

echo "== Pause"
[ "$(uipost /kit/pause)" = 200 ] || fail "the pause action didn't answer"
[ -e "$control/paused" ] && pass "control/paused exists" || fail "control/paused is missing"
[ -z "$(scheduled_by testbed-base "$pr")" ] && pass "the scheduled merge of testbed-base#$pr is cancelled" \
  || fail "testbed-base#$pr is still scheduled"
jq -e --argjson n "$pr" 'any(.[]; .repo == "testbed-base" and .number == $n and .scheduled_by == "base")' \
  "$control/paused-merges.json" >/dev/null && pass "and recorded for resuming" || fail "it isn't recorded"
human GET /repos/testorg/testbed-base/branch_protections/main \
  | jq -e '.enable_merge_whitelist and .merge_whitelist_usernames == ["tester"]' >/dev/null \
  && pass "only tester may merge into testbed-base" || fail "testbed-base's merge list wasn't narrowed"
jqs -e '.paused and ([.agents[].state] | all(. == "paused" or . == "running"))' >/dev/null \
  && pass "the kit page's JSON reports every agent paused" || fail "the kit page doesn't report the pause"
has "$(ui "$site/")" "Paused: no run starts" && pass "and its page says so" || fail "the kit page doesn't say it's paused"

echo "== Events, while paused"
req="$(request testbed-base "A request from the human")"
until_true 60 sh -c "curl -sS -b '$jar' -H 'Accept: application/json' '$site/agents' | jq -e '.agents.base.pending[] | select(.trigger | test(\"testbed-base#$req \\\\(untriaged\\\\)\"))'" \
  && pass "base has its request to triage" || fail "base has no work for testbed-base#$req: $(pending base)"
told() { pending coordinator | grep -q "request filed: testbed-base#$req"; }
until_true 60 told && pass "the coordinator is told it was filed" \
  || fail "the coordinator wasn't told: $(pending coordinator)"
nh="$(as base POST /repos/testorg/testbed-base/issues "$(jq -nc '{title: "Needs the human", body: "(no reply needed)\n\n## Question\n\nA test.\n\n## Options\n\nNone.\n\n## Recommendation\n\nClose it.\n\n## If you say go ahead\n\nNothing.\n\n## Blocked on this\n\nNothing."}')" | jq -r .number)"
human POST "/repos/testorg/testbed-base/issues/$nh/labels" '{"labels": ["needs-human"]}' >/dev/null
until_true 60 sh -c "curl -sS -b '$jar' -H 'Accept: application/json' '$site/notices' | jq -e '.notices[] | select(.kind == \"needs-human\" and .number == $nh)'" \
  && pass "needs-human on testbed-base#$nh is a notice" || fail "no needs-human notice for testbed-base#$nh"

echo "== Reconciliation"
dc stop dispatcher >/dev/null 2>&1
missed="$(request testbed-app "Filed while the dispatcher is down")"
dc start dispatcher >/dev/null 2>&1
until_true 180 sh -c "curl -sS -b '$jar' -H 'Accept: application/json' '$site/agents' | jq -e '.agents.app.pending[] | select(.trigger | test(\"testbed-app#$missed \"))'" \
  && pass "a request filed while the dispatcher was down is found" || fail "testbed-app#$missed was never found"

echo "== Notices"
id="$(uijson /notices | jq -r --argjson n "$nh" '[.notices[] | select(.kind == "needs-human" and .number == $n)][0].id')"
[ "$(uipost "/notices/$id/seen")" = 200 ] || fail "the seen action didn't answer"
uijson /notices | jq -e --argjson i "$id" '.notices[] | select(.id == $i) | .seen != null' >/dev/null \
  && pass "notice $id is marked seen" || fail "notice $id isn't marked seen"

echo "== Resume"
uipost /kit/resume >/dev/null
[ ! -e "$control/paused" ] && pass "control/paused is gone" || fail "control/paused is still there"
human GET /repos/testorg/testbed-base/branch_protections/main | jq -e '.enable_merge_whitelist == false' >/dev/null \
  && pass "testbed-base's merge list is restored" || fail "testbed-base's merge list is still narrowed"
merged_by="$(human GET "/repos/testorg/testbed-base/pulls/$pr" | jq -r 'if .merged then .merged_by.login else empty end')"
by="${merged_by:-$(scheduled_by testbed-base "$pr")}"
[ "$by" = tester ] && pass "testbed-base#$pr is ${merged_by:+merged}${merged_by:-scheduled again} in tester's name" \
  || fail "testbed-base#$pr after resuming: ${by:-neither merged nor scheduled}"

echo "== Drain"
uipost /kit/drain >/dev/null
[ -e "$control/draining" ] && pass "control/draining exists" || fail "control/draining is missing"
until_true 300 sh -c "curl -sS -b '$jar' -H 'Accept: application/json' '$site/' | jq -e .drained" \
  && pass "drained once nothing is under way" || fail "never drained: $(jqs -c .under_way)"
has "$(ui "$site/")" "safe to stop" && pass "the kit page says it is safe to stop" || fail "the kit page doesn't say it's safe to stop"
uipost /kit/resume >/dev/null
[ ! -e "$control/draining" ] && pass "resume ends the drain" || fail "control/draining is still there"

echo "== Agents and runs"
uipost /agents/app/stop >/dev/null
[ -e "$control/stopped-app" ] && [ "$(uijson /agents | jq -r .agents.app.state)" = stopped ] \
  && pass "app is stopped" || fail "app isn't stopped"
uipost /agents/app/start >/dev/null
[ ! -e "$control/stopped-app" ] && pass "and started again" || fail "app is still stopped"
sleep 6
run="$(runner base /claim | jq -r .run)"
runner base "/runs/$run/start" '{"session_id": "s-1", "log": "/workspace/.guild/current.md"}' >/dev/null
uipost "/runs/$run/stop" >/dev/null
[ -e "$control/stop-run-$run" ] && pass "run $run is asked to stop" || fail "no control/stop-run-$run"
runner base "/runs/$run/end" '{"outcome": "interrupted", "turns": 1, "cost": 0.01}' >/dev/null
ui "$site/" >/dev/null
[ ! -e "$control/stop-run-$run" ] && pass "once it has ended, the request is tidied away" || fail "control/stop-run-$run is left behind"

echo "== Activity and reviews"
uijson /activity | jq -e --arg r "testbed-base#$req" 'any(.[]; .text | contains($r))' >/dev/null \
  && pass "the activity page has the request" || fail "the activity page lacks testbed-base#$req"
uijson /reviews | jq -e 'has("pulls") and has("milestones") and has("recommendations")' >/dev/null \
  && pass "the reviews page answers" || fail "the reviews page: $(uijson /reviews)"

echo
[ "$fails" = 0 ] && echo "Stage 8: all checks passed." || { echo "Stage 8: $fails check(s) failed."; exit 1; }
