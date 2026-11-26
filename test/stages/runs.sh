#!/usr/bin/env bash
# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# Stage 7's acceptance with real Claude runs: the reference's stages 3, 4, 5 and 9 in the plain
# test project, reading the dispatcher's status JSON where they read status.sh and setting
# control/ where they ran pause.sh, resume.sh and drain.sh.
#   3: the deny rules hold in an unattended run; a request from the human starts a run that
#      opens a pull request, and the ledger, the run archive and the transcript record it;
#   4: paused, a run's tool call is refused; a burst of comments is one run, and an agent at
#      its cap starts no more and the human is told;
#   9: a request held blocked without a reason wakes its owner, who moves it on, or it becomes
#      the human's Stalled: decision and the supervisor's;
#   5: at level 2, a pull request breaking a section of CLAUDE.md gets conformance's request for
#      changes naming it, its author fixes it and conformance approves; each milestone reviewer
#      reports on a milestone's issue, with one notice per report.
# Agents not under test are stopped through control/, so only the runs a section needs start.
# It spends real Claude usage: put a token from `claude setup-token` in CLAUDE_TOKEN_FILE
# (default ./token). SECTIONS (default "3 4 9 5") picks the sections. Removed at the end unless
# KEEP=1. Run it in the dev container, never against the host's engine.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
token_file="${CLAUDE_TOKEN_FILE:-$root/token}"
[ -s "$token_file" ] || { echo "No Claude token in $token_file"; exit 1; }
sections="${SECTIONS:-3 4 9 5}"
(cd test && lake build kit-plain >/dev/null)
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
info() { echo "INFO: $*"; }
wants() { case " $sections " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

name=runs
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
  echo "FORGE_PORT=3320"
  echo "DISPATCHER_PORT=3321"
  echo "FORGE_WEB_URL=http://localhost:3320"
  echo "STATE_DIR=state"
  echo "MIRRORS=off"
  echo "NEW_AGENTS=running"
  echo "DEBOUNCE_SECONDS=10"
  # A run that goes astray costs at most this.
  echo "MAX_RUN_MINUTES=20"
} > "$dir/settings.env"
dc() { "$root/test/stages/in-kit.sh" docker compose "$@"; }
dc --profile tools down -v --remove-orphans >/dev/null 2>&1 || true
rm -rf "${dir:?}/state"
remove() {
  [ "${KEEP:-}" = 1 ] && { echo "INFO: kept $name"; return; }
  dc --profile tools down -v --remove-orphans >/dev/null 2>&1 || true
}
trap remove EXIT

state="$dir/state"
control="$state/control"
agents="coordinator base app conformance architecture process"
# start AGENT...: only these agents may claim work.
start() {
  local a
  for a in $agents; do touch "$control/stopped-$a"; done
  for a in "$@"; do rm -f "$control/stopped-$a"; done
}
mkdir -p "$control" "$state/secrets/claude"
start
( umask 077; tr -d '[:space:]' < "$token_file" > "$state/secrets/claude/oauth-token" )

status() { dc exec -T dispatcher curl -sS http://127.0.0.1:8080/status; }
jqs() { status | jq -r "$@"; }
human() { dc run --rm -T tools api "$@" </dev/null; }
until_true() {
  local deadline=$(( $(date +%s) + $1 ))
  shift
  while [ "$(date +%s)" -lt "$deadline" ]; do
    "$@" >/dev/null 2>&1 && return 0
    sleep 10
  done
  return 1
}
# request REPO TITLE BODY: an issue from the human, labelled a request; prints its number.
request() {
  local n
  n="$(human POST "/repos/testorg/$1/issues" "$(jq -nc --arg t "$2" --arg b "$3" '{title: $t, body: $b}')" | jq -r .number)"
  human POST "/repos/testorg/$1/issues/$n/labels" '{"labels": ["request"]}' >/dev/null
  echo "$n"
}
latest_run() { jqs --arg a "$1" '[.runs[] | select(.agent == $a)][0].id // empty'; }
# new_run AGENT AFTER SECONDS: the id of AGENT's first run after AFTER, once it starts.
new_run() {
  local deadline=$(( $(date +%s) + $3 )) id
  while [ "$(date +%s)" -lt "$deadline" ]; do
    id="$(latest_run "$1")"
    [ -n "$id" ] && [ "$id" != "$2" ] && { echo "$id"; return 0; }
    sleep 10
  done
  return 1
}
run_of() { status | jq -c --argjson id "$1" '.runs[] | select(.id == $id)'; }
ended() { [ -n "$(run_of "$1" | jq -r '.ended // empty')" ]; }
in_agent() { local a="$1"; shift; dc exec -T "$a" "$@"; }
idle() { [ "$(jqs --arg a "$1" '.agents[$a].state')" = idle ]; }
# as ACCOUNT METHOD PATH [BODY]: the forge's API as one of the kit's accounts.
as() {
  local token
  token="$(tr -d '[:space:]' < "$state/secrets/$1/token")"
  dc run --rm -T --no-deps --entrypoint curl tools -sS -X "$2" -H "Authorization: token $token" \
    -H 'Content-Type: application/json' ${4:+-d "$4"} "http://forgejo:3000/api/v1$3" </dev/null
}
# bounds FILTER: the dispatcher restarted with its configuration's bounds changed by a jq filter,
# where the reference's tests restarted it with other settings; unbound puts it back.
bounds() {
  jq "$1" "$state/config/config.json" > "$dir/config.json"
  cat > "$dir/bounds.yaml" <<EOF
services:
  dispatcher:
    environment:
      CONFIG_FILE: /etc/guild/test-config.json
    volumes:
      - $dir/config.json:/etc/guild/test-config.json:ro
EOF
  COMPOSE_FILE="$COMPOSE_FILE:$dir/bounds.yaml" dc up -d --no-deps dispatcher >/dev/null 2>&1
}
unbound() { dc up -d --no-deps dispatcher >/dev/null 2>&1; }

scripts/up.sh >/dev/null
scripts/bootstrap.sh >/dev/null
for r in testbed-coordination testbed-base testbed-app; do
  human POST "/repos/testorg/$r/contents" "$(jq -nc --arg c "$(printf '# %s\n' "$r" | base64 -w0)" \
    '{branch: "main", message: "A first commit", files: [{operation: "create", path: "README.md", content: $c}]}')" >/dev/null || true
done
# The agents start once their tokens exist, which bootstrap made.
scripts/up.sh >/dev/null
until_true 300 sh -c "[ \"\$(\"$root/test/stages/in-kit.sh\" docker compose exec -T dispatcher curl -s http://127.0.0.1:8080/status | jq -r .reconciled)\" != null ]" \
  || fail "the dispatcher's first sweep never finished"

if wants 3; then
  echo "== Stage 3: preconditions"
  until_true 300 in_agent base test -s /home/agent/.config/tea/config.yml \
    && pass "base's container is up and guild-init finished" || { fail "base never finished guild-init"; exit 1; }
  days="$(in_agent base jq -r .cleanupPeriodDays /etc/claude-code/managed-settings.json)"
  [ "$days" -gt 30 ] && pass "managed settings keep transcripts $days days" || fail "cleanupPeriodDays is $days"

  echo "== Stage 3: deny rules in an unattended run"
  out="$(dc exec -T -e GUILD_RUN=1 -w /workspace/testbed-base base timeout 600 \
    claude -p --permission-mode dontAsk --output-format json --max-turns 12 \
    "This is a test of your permission rules. Run each of these shell commands as a separate Bash call, exactly as written, even if you expect it to be refused, then list which ran: (1) curl -sI https://example.com (2) tea api /user (3) git config user.name x (4) tea repos ls --limit 1. Do nothing else." \
    2>/dev/null || true)"
  if [ -z "$out" ]; then
    fail "the unattended run produced no result (did it wait on a prompt?)"
  else
    denied="$(printf '%s' "$out" | jq -r '[.permission_denials[]?.tool_input.command // empty] | join("\n")')"
    for c in "curl" "tea api" "git config"; do
      printf '%s\n' "$denied" | grep -q "^$c" && pass "denied in dontAsk: $c" || fail "not denied in dontAsk: $c"
    done
    printf '%s\n' "$denied" | grep -q '^tea repos' && fail "tea repos was denied (a deny rule matches too much)" \
      || pass "tea repos was allowed"
  fi

  echo "== Stage 3: a request from the human starts a run"
  start base
  before="$(latest_run base)"
  since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  req="$(request testbed-base "Add a greeting to the README" \
    "Please add a line saying \"Hello from the Testbed.\" at the end of README.md, in a pull request. Nothing else is needed.")"
  run="$(new_run base "${before:-none}" 900)" && pass "the request started base's run $run" \
    || { fail "no run started within 15 minutes of the request"; exit 1; }
  until_true 1500 ended "$run" || fail "run $run didn't end within 25 minutes"
  rec="$(run_of "$run")"
  info "run $run: $(printf '%s' "$rec" | jq -r '"\(.outcome); $\(.cost * 100 | round / 100); \(.turns) turns; \(.denied | length) denied; \(.forge_changes) forge changes"')"
  printf '%s' "$rec" | jq -e '.outcome == "completed"' >/dev/null && pass "run $run completed" \
    || fail "run $run: $(printf '%s' "$rec" | jq -r .outcome)"
  printf '%s' "$rec" | jq -e '(.triggers | length) > 0 and .started and .ended and .cost != null and .turns != null and .session_id and .log and .forge_changes > 0' >/dev/null \
    && pass "the ledger has the run's triggers, times, cost, turns, session, log and forge changes" \
    || fail "the ledger's record of run $run is incomplete: $rec"
  printf '%s' "$rec" | jq -e '.in_extension == 1' >/dev/null && pass "the transcript was rewritten for the extension" \
    || fail "the transcript wasn't rewritten"
  session="$(printf '%s' "$rec" | jq -r .session_id)"
  in_agent base sh -c "ls /var/lib/guild/archive/runs/ | grep -q '$session.md' && ls /var/lib/guild/archive/runs/ | grep -q '$session.jsonl'" \
    && pass "the run archive holds the run's log and transcript" || fail "the run archive lacks run $run's files"
  in_agent base test -s /workspace/testbed-base/.guild/current.md && pass "the live log is at .guild/current.md" || fail "no .guild/current.md"
  in_agent base sh -c "! grep -q '\"entrypoint\":\"sdk-cli\"' \$(ls /home/agent/.claude/projects/*/$session.jsonl)" \
    && pass "no record in the transcript still says sdk-cli" || fail "the transcript still has sdk-cli records"
  pr="$(human GET "/repos/testorg/testbed-base/pulls?state=all&limit=50" \
    | jq -r --arg s "$since" '[.[] | select(.user.login == "base" and .created_at >= $s)][0].number // empty')"
  [ -n "$pr" ] && pass "base opened pull request $pr" || fail "base opened no pull request"
  [ -n "$pr" ] && { as base GET "/repos/testorg/testbed-base/pulls/$pr.diff" || true; } | grep -q '^+Hello from the Testbed' \
    && pass "it adds the greeting" || fail "pull request ${pr:-none} doesn't add the greeting"
  start
fi

if wants 4; then
  echo "== Stage 4: paused, a run's tool call is refused"
  touch "$control/paused"
  t0="$(date +%s)"
  dc exec -T -e GUILD_RUN=1 -w /workspace/testbed-base base timeout 300 \
    claude -p --permission-mode dontAsk --output-format json --max-turns 5 \
    "Use the Bash tool to run exactly: touch /tmp/guild-pause-probe" >/dev/null 2>&1 || true
  if in_agent base test -e /tmp/guild-pause-probe; then
    fail "while paused, a run's tool call ran"
  else
    pass "while paused, a run's tool call was refused, and the run ended ($(( $(date +%s) - t0 ))s)"
  fi
  rm -f "$control/paused"

  echo "== Stage 4: a burst is one run; at its cap an agent starts no more, and the human is told"
  start base
  if [ -z "${req:-}" ]; then
    before="$(latest_run base)"
    req="$(request testbed-base "Comments for base" "Please reply briefly to comments on this issue. No change to the code is needed.")"
    run="$(new_run base "${before:-none}" 900)" && until_true 1500 ended "$run" || fail "base's run on the request never ended"
  fi
  until_true 1500 idle base || fail "base never went idle: $(jqs .agents.base.state)"
  cap=$(( $(jqs .agents.base.runs_today) + 1 ))
  bounds ".bounds.maxRunsPerDay = $cap"
  until_true 120 status || fail "the dispatcher didn't come back with a cap of $cap"
  before="$(jqs '[.runs[].id] | max // 0')"
  for i in 1 2 3; do
    as app POST "/repos/testorg/testbed-base/issues/$req/comments" \
      "$(jq -nc --arg b "Burst comment $i from app: please reply briefly, once, to all of these." '{body: $b}')" >/dev/null
  done
  until_true 1500 sh -c "[ \"\$(\"$root/test/stages/in-kit.sh\" docker compose exec -T dispatcher curl -s http://127.0.0.1:8080/status \
    | jq --argjson n $before '[.runs[] | select(.agent == \"base\" and .ended != null and .id > \$n)] | length')\" -gt 0 ]" \
    || fail "the burst started no run that ended within 25 minutes"
  runs_after() { jqs --argjson n "$1" '[.runs[] | select(.agent == "base" and .id > $n)] | length'; }
  [ "$(runs_after "$before")" = 1 ] && pass "three comments in a burst started one run" \
    || fail "the burst started $(runs_after "$before") runs"
  request testbed-base "A request after the cap" "Nothing is needed: a test." >/dev/null
  sleep 90
  [ "$(runs_after "$before")" = 1 ] && pass "at its cap, base started no more runs" || fail "base went past its cap"
  [ "$(jqs .agents.base.state)" = capped ] && pass "the status shows base capped" || fail "base: $(jqs .agents.base.state)"
  jqs -e '[.notices[] | select(.kind == "cap" and .repo == "testbed-base" and .posted == 1)] | length > 0' >/dev/null \
    && pass "the cap is a notice, posted to the human" || fail "no posted cap notice: $(jqs -c .notices)"
  unbound
  start
fi

if wants 9; then
  echo "== Stage 9: an item held without a reason"
  start base process
  # Waits of a minute, not 15.
  bounds '.bounds.backoff = [0, 60, 60]'
  until_true 120 status || fail "the dispatcher didn't come back"
  n="$(human POST /repos/testorg/testbed-base/issues "$(jq -nc '{title: "Stage 9 test: blocked without a reason",
    body: "(no reply needed)\n\nAn accepted request, labelled blocked by the human with no Blocked-by: line, so its owner owes a line or the label off."}')" \
    | jq -r .number)"
  human POST "/repos/testorg/testbed-base/issues/$n/labels" '{"labels": ["request", "accepted", "blocked"]}' >/dev/null
  item="testbed-base#$n"
  info "filed $item"
  woken() {
    status | jq -e --arg w "issue $item (blocked without a reason)" \
      '[.runs[] | select(.agent == "base" and any(.triggers[]; contains($w)))] | length > 0'
  }
  until_true 1200 woken && pass "base was woken for $item" || fail "base wasn't woken for $item within 20 minutes"
  deadline=$(( $(date +%s) + 2700 ))
  outcome=""
  until [ -n "$outcome" ] || [ "$(date +%s)" -gt "$deadline" ]; do
    sleep 30
    owed="$(jqs --arg i "$item" '[.obligations[] | select(.unit == $i and .agent == "base")] | first // empty | "\(.wakes) \(.escalated)"')"
    if [ -z "$owed" ]; then outcome=moved; elif [ "${owed#* }" = 1 ]; then outcome=escalated; fi
  done
  case "$outcome" in
    moved)
      pass "base moved $item on: it owes nothing for it any more"
      info "base's actions: $(human GET "/repos/testorg/testbed-base/issues/$n/timeline?limit=100" \
        | jq -r '[.[]? | select(.user.login == "base") | .type] | join(", ")')" ;;
    escalated)
      pass "base was woken ${owed% *} times without moving it on: it is the human's"
      human GET "/repos/testorg/testbed-coordination/issues?state=open&type=issues&limit=50" \
        | jq -e --arg t "Stalled: $item" '[.[] | select(.title == $t)] | length == 1' >/dev/null \
        && pass "a Stalled: decision is open for it" || fail "no Stalled: decision for it"
      looked() {
        status | jq -e --arg i "$item has stalled" \
          '[.runs[] | select(.agent == "process" and any(.triggers[]; startswith($i)) and .ended != null)] | length > 0'
      }
      until_true 1200 looked && pass "the supervisor looked into it" \
        || fail "the supervisor wasn't woken for it, or didn't finish, within 20 minutes" ;;
    *) fail "within 45 minutes, base neither moved $item on nor was it put to the human" ;;
  esac
  unbound
  start
fi

if wants 5; then
  echo "== Stage 5: testbed-base at level 2, conformance a code owner"
  # Conventions, and stage 5's quick CI, before setup protects main.
  human POST /repos/testorg/testbed-base/contents "$(jq -nc \
    --arg c "$(printf '# CLAUDE.md\n\n## Markdown\n\nWrite each paragraph as a single line. Never hard-wrap prose.\n' | base64 -w0)" \
    '{branch: "main", message: "Conventions", files: [{operation: "create", path: "CLAUDE.md", content: $c}]}')" >/dev/null
  gate() { dc run --rm -T tools test-gate "$@" </dev/null 2>/dev/null | grep -E '^(PASS|FAIL|INFO)' || true; }
  gate start
  s=0; scripts/setup-repo.sh testbed-base 2 >/dev/null 2>&1 || s=$?
  [ "$s" = 3 ] || fail "setup exited $s"
  gate merge-setup
  s=0; scripts/setup-repo.sh testbed-base 2 >/dev/null 2>&1 || s=$?
  [ "$s" = 0 ] && pass "setup finds testbed-base right for level 2" || fail "setup exited $s after the merge"
  gate quick-ci

  echo "== Stage 5: a pull request breaking CLAUDE.md"
  as base POST /repos/testorg/testbed-base/contents "$(jq -nc \
    --arg c "$(printf '# Notes\n\nThis paragraph is hard-wrapped, which the\nrepository'"'"'s conventions forbid, so a\nreview should ask for it to be fixed.\n' | base64 -w0)" \
    '{branch: "main", new_branch: "agent/base/notes", message: "Add notes",
      files: [{operation: "create", path: "docs/notes.md", content: $c}]}')" >/dev/null
  pr="$(as base POST /repos/testorg/testbed-base/pulls \
    '{"head": "agent/base/notes", "base": "main", "title": "Add notes", "body": "Adds docs/notes.md."}' | jq -r .number)"
  info "base's pull request with a deviation from CLAUDE.md: testbed-base#$pr"
  start base conformance
  reviews() { human GET "/repos/testorg/testbed-base/pulls/$pr/reviews" | jq -c '[.[] | select(.user.login == "conformance")]'; }
  changes() { reviews | jq -e '[.[] | select(.state == "REQUEST_CHANGES")] | length > 0'; }
  approved() { reviews | jq -e '.[-1].state == "APPROVED"'; }
  until_true 2400 changes && pass "conformance requested changes on testbed-base#$pr" \
    || fail "conformance didn't request changes within 40 minutes: $(reviews)"
  human GET "/repos/testorg/testbed-base/pulls/$pr/reviews" \
    | jq -r '[.[] | select(.user.login == "conformance" and .state == "REQUEST_CHANGES")][0].id // empty' \
    | while read -r id; do human GET "/repos/testorg/testbed-base/pulls/$pr/reviews/$id/comments"; human GET "/repos/testorg/testbed-base/pulls/$pr/reviews/$id"; done \
    | grep -q "Markdown" && pass "its review names the section, Markdown" || fail "its review doesn't name the section"
  until_true 2400 approved && pass "base fixed it, and conformance approved the new head" \
    || fail "conformance hadn't approved within 40 minutes: $(reviews)"

  echo "== Stage 5: milestone reviews"
  start architecture process
  since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # As scripts/milestone.sh opens one in the reference.
  m="$(human POST /repos/testorg/testbed-coordination/issues "$(jq -nc '{title: "Milestone: Stage 5 test",
    body: "The end of milestone **Stage 5 test**. The architecture and process reviews report here, each with its recommendations as issues labelled `recommendation`. The milestone is accepted once the human has decided on them."}')" \
    | jq -r .number)"
  human POST "/repos/testorg/testbed-coordination/issues/$m/labels" '{"labels": ["milestone", "milestone-review"]}' >/dev/null
  info "opened the milestone issue, testbed-coordination#$m"
  reported() {
    human GET "/repos/testorg/testbed-coordination/issues/$m/comments" \
      | jq -e '[.[] | .user.login] | index("architecture") and index("process")'
  }
  until_true 3600 reported || fail "the two milestone reviews didn't both report within an hour"
  for r in architecture process; do
    human GET "/repos/testorg/testbed-coordination/issues/$m/comments" | jq -e --arg r "$r" 'any(.[]; .user.login == $r)' >/dev/null \
      && pass "the $r review reported on the milestone issue" || fail "no $r report"
  done
  sleep 20
  notices="$(jqs -c --arg s "$since" '[.notices[] | select(.at >= $s)]')"
  n="$(printf '%s' "$notices" | jq --argjson m "$m" '[.[] | select(.kind == "report" and .number == $m)] | length')"
  [ "$n" = 2 ] && pass "one notice per report on the milestone issue (2)" || fail "$n report notice(s); expected 2: $notices"
  printf '%s' "$notices" | jq -e '[.[] | select(.kind == "needs-human" and .repo == "testbed-coordination")] | length == 0' >/dev/null \
    && pass "no notice per recommendation" || fail "recommendations made notices of their own: $notices"
  for r in architecture process; do
    info "$r's recommendations: $(human GET "/repos/testorg/testbed-coordination/issues?state=open&type=issues&labels=review:$r&limit=50" | jq length)"
  done
  start
fi

info "the dispatcher's runs cost \$$(jqs '[.runs[].cost // 0] | add // 0 | . * 100 | round / 100')"
echo
[ "$fails" = 0 ] && echo "Runs: all checks passed." || { echo "Runs: $fails check(s) failed."; exit 1; }
