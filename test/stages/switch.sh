#!/usr/bin/env bash
# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# The switch round trip: the reference's kit, unchanged, deployed with the plain test project's
# agents; drained, stopped and replaced by the guild under the same compose project name and
# STATE_DIR; then the reverse. Each finds the other's ledger, volumes, secrets and control/ files.
# The reference runs from a copy in test/.lake, never from its checkout (REFERENCE, default
# ../inkproof-forge). Neither kit starts agents, having no Claude token, so nothing is spent.
# Removed at the end unless KEEP=1. Run it in the dev container, never against the host's engine.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
(cd test && lake build kit-plain >/dev/null)
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

name=switch
project="guild-test-$name"
dir="$root/test/.lake/stages/$name"
state="$dir/state"
ref="$dir/reference"
reference="${REFERENCE:-$root/../inkproof-forge}"
password="$(openssl rand -hex 12)"
mkdir -p "$dir"

# The reference as its checkout has it, with the test project's agents and roles.
rm -rf "$ref" "$state"
mkdir -p "$ref" "$state"
tar -C "$reference" --exclude=.git -cf - . | tar -C "$ref" -xf -
cat > "$ref/agents.conf" <<'EOF'
coordinator coordinator testbed-coordination *
base library testbed-base testbed-coordination
app library testbed-app testbed-coordination,testbed-base
conformance pr-reviewer - *
architecture milestone-reviewer - *
process supervisor - *
EOF
for a in coordinator base app conformance architecture process; do echo "# Role: $a" > "$ref/roles/$a.md"; done
cat > "$dir/reference.env" <<EOF
COMPOSE_PROJECT_NAME=$project
GH_OWNER=testbed
GH_FORMER_OWNERS=testbed-old
FORGE_ORG=testorg
REPO_PREFIX=testbed-
HUMAN_USER=tester
HUMAN_EMAIL=tester@noreply.localhost
HUMAN_PASSWORD=$password
HOST_UID=$(id -u)
HOST_GID=$(id -g)
FORGE_PORT=3318
DISPATCHER_PORT=3319
STATE_DIR=$state
MIRROR_BRANCHES=main
EOF
# The guild, under the same name and STATE_DIR, with the names the reference's repositories and
# workspaces use.
cat > "$dir/guild.env" <<EOF
COMPOSE_PROJECT_NAME=$project
FORGE_ORG=testorg
HUMAN_USER=tester
HUMAN_EMAIL=tester@noreply.localhost
HUMAN_PASSWORD=$password
FORGE_PORT=3318
DISPATCHER_PORT=3319
FORGE_WEB_URL=http://localhost:3318
STATE_DIR=$state
MIRRORS=off
CI_IMAGE=inkproof-ci:1
TOOLCHAIN_VOLUME=inkproof-elan
REQUIRE_LASM_VAR=INKPROOF_REQUIRE_LASM
WORKSPACE_STATE=.inkproof
EOF

refkit() { (cd "$ref" && env -u COMPOSE_FILE KIT_ENV="$dir/reference.env" KIT_YES=1 "$@"); }
guild() { env -u COMPOSE_FILE KIT_ENV="$dir/guild.env" KIT="$root/test/.lake/build/bin/kit-plain" KIT_YES=1 "$@"; }
in_guild() { guild "$root/test/stages/in-kit.sh" "$@"; }
remove() {
  [ "${KEEP:-}" = 1 ] && { echo "INFO: kept $name"; return; }
  clear_kit
}
# Whatever an earlier run kept.
clear_kit() {
  local label="label=com.docker.compose.project=$project"
  docker ps -aq --filter "$label" | xargs -r docker rm -f >/dev/null
  docker volume ls -q --filter "$label" | xargs -r docker volume rm >/dev/null
  docker network ls -q --filter "$label" | xargs -r docker network rm >/dev/null
}
clear_kit
trap remove EXIT
volumes() { docker volume ls -q --filter "label=com.docker.compose.project=$project" | sort; }
# The status JSON, from whichever kit's dispatcher is up, read from the host's side of its port.
status() { curl -fsS http://127.0.0.1:3319/status; }
jqs() { status | jq -r "$@"; }
until_true() {
  local deadline=$(( $(date +%s) + $1 ))
  shift
  while [ "$(date +%s)" -lt "$deadline" ]; do
    "$@" >/dev/null 2>&1 && return 0
    sleep 5
  done
  return 1
}
token() { tr -d '[:space:]' < "$state/secrets/human/token"; }
api() {
  curl -fsS -X "$1" -H "Authorization: token $(token)" -H 'Content-Type: application/json' ${3:+-d "$3"} \
    "http://127.0.0.1:3318/api/v1$2"
}
request() {
  local n
  n="$(api POST "/repos/testorg/$1/issues" "$(jq -nc --arg t "$2" '{title: $t, body: "Please."}')" | jq -r .number)"
  api POST "/repos/testorg/$1/issues/$n/labels" '{"labels": ["request"]}' >/dev/null
  echo "$n"
}
owes() { status | jq -e --arg u "$1" '[.obligations[] | select(.unit == $u)] | length > 0'; }
# A sweep now, through the admin endpoint both kits have: a dispatcher that started before the
# forge did has seen nothing yet.
reconcile() {
  curl -fsS -X POST -H "Authorization: Bearer $(tr -d '[:space:]' < "$state/secrets/dispatcher/admin-key")" \
    http://127.0.0.1:3319/admin/reconcile
}

echo "== The reference's kit"
refkit scripts/up.sh >/dev/null
refkit scripts/bootstrap.sh >/dev/null
# The reference makes repositories when it imports or adds a library: here, the test project's.
for r in testbed-coordination testbed-base testbed-app; do
  api POST /orgs/testorg/repos "$(jq -nc --arg n "$r" '{name: $n, auto_init: true, default_branch: "main"}')" >/dev/null
done
refkit scripts/bootstrap.sh >/dev/null
until_true 120 status && pass "its dispatcher answers" || fail "its dispatcher never answered"
until_true 300 reconcile || fail "it never swept"
first="$(request testbed-base "Filed under the reference")"
until_true 120 owes "testbed-base#$first" && pass "it owes testbed-base#$first" || fail "it never evaluated testbed-base#$first"
ref_volumes="$(volumes)"
refkit timeout 900 scripts/drain.sh >/dev/null && pass "it drains" || fail "it never drained"
refkit scripts/down.sh >/dev/null
# The reference's runs on testbed-base#$first, past the test project's run budget of 40, claimed
# before the guild could raise a notice: the budget counts none of them. Its agents never run here.
in_guild docker compose --profile tools build --quiet tools >/dev/null
for i in $(seq 41); do
  echo "INSERT INTO runs (agent, claimed, ended, outcome) VALUES ('base', strftime('%s','now') - 172800 + $i, strftime('%s','now') - 172800 + $i, 'completed');
INSERT INTO triggers (agent, key, description, created, run_id) VALUES ('base', 'owe:testbed-base#$first:$i:1', '', 0, last_insert_rowid());"
done | docker run --rm -i --network none --user 0 -v "${project}_dispatcher-state:/state" \
  --entrypoint sqlite3 "$project-tools:1" /state/ledger.db
# The reference's dispatcher runs as uid 1000 and the guild's as the host's, which here is 1000 too.
# A ledger owned by another uid stands in for a host whose uid isn't, in each direction.
foreign() {
  docker run --rm --network none -v "${project}_dispatcher-state:/state" alpine:3.24 chown -R 4242:4242 /state
}
foreign

echo "== The guild, in its place"
guild scripts/up.sh >/dev/null
until_true 120 status && pass "its dispatcher answers" || fail "its dispatcher never answered"
until_true 300 reconcile || fail "it never swept"
until_true 120 owes "testbed-base#$first" && pass "it finds the reference's ledger: testbed-base#$first is owed" \
  || fail "it doesn't owe testbed-base#$first: $(jqs .obligations)"
[ "$(jqs .draining)" = true ] && pass "it finds the reference's drain" || fail "it isn't draining"
until_true 300 sh -c "curl -fsS http://127.0.0.1:3319/status | jq -e '.reconciled != null'" \
  && pass "its sweep reads the forge with the reference's token" || fail "its sweep never finished"
added="$(comm -13 <(printf '%s\n' "$ref_volumes") <(volumes) | grep -E 'forgejo|dispatcher-state|ci-' || true)"
[ -z "$added" ] && pass "it uses the reference's volumes" || fail "it made volumes of its own: $added"
rm -f "$state/control/draining"
# A claim checks the budget of each unit it wakes for, as a runner asks for it.
owner="$(jqs --arg u "testbed-base#$first" '[.obligations[] | select(.unit == $u)][0].agent')"
runner() {
  in_guild docker compose exec -T dispatcher curl -fsS -X POST \
    -H "Authorization: Bearer $(tr -d '[:space:]' < "$state/secrets/runner-keys/$owner")" \
    -H 'Content-Type: application/json' -d "${2:-"{}"}" "http://127.0.0.1:8080$1"
}
claimed=""
deadline=$(( $(date +%s) + 300 ))
until [ -n "$claimed" ] || [ "$(date +%s)" -ge "$deadline" ]; do
  claimed="$(runner /claim)" || claimed=""
  [ -n "$claimed" ] || sleep 5
done
if [ -z "$claimed" ]; then
  fail "$owner never claimed testbed-base#$first"
else
  runner "/runs/$(jq -r .run <<<"$claimed")/end" '{"outcome": "completed", "turns": 1, "cost": 0, "denied": []}' >/dev/null
  budget="$(jqs '[.notices[] | select(.kind == "budget")] | length')"
  [ "$budget" = 0 ] && pass "a claim counts none of the reference's runs against the budget" \
    || fail "the reference's runs raised $budget budget notice(s): $(jqs '.notices')"
fi
second="$(request testbed-app "Filed under the guild")"
until_true 120 owes "testbed-app#$second" && pass "resumed, it owes testbed-app#$second" || fail "it never evaluated testbed-app#$second"

# Lines a newer comment replaced, which the reference reads still: the way back lists them.
blocker="$(request testbed-base "A blocker")"
other="$(request testbed-base "Another blocker")"
comment() { api POST "/repos/testorg/testbed-app/issues/$1/comments" "$(jq -nc --arg b "$2" '{body: $b}')" | jq -r .id; }
item() { api POST /repos/testorg/testbed-app/issues "$(jq -nc --arg t "$1" '{title: $t, body: "Work."}')" | jq -r .number; }
blocked() { api GET "/repos/testorg/testbed-app/issues/$1/labels" | jq -e 'any(.[]; .name == "blocked")' >/dev/null; }
cleared="$(item "Cleared by Blocked-by: none")"
line1="$(comment "$cleared" "Blocked-by: testorg/testbed-base#$blocker")"
comment "$cleared" "Blocked-by: none" >/dev/null
moved="$(item "Moved to another blocker")"
line2="$(comment "$moved" "Blocked-by: testorg/testbed-base#$blocker")"
comment "$moved" "Blocked-by: testorg/testbed-base#$other" >/dev/null
reconcile >/dev/null
! blocked "$cleared" && blocked "$moved" && pass "the guild reads each item's newest Blocked-by: lines" \
  || fail "the guild's blocked labels: #$cleared $(blocked "$cleared" && echo on || echo off), #$moved $(blocked "$moved" && echo on || echo off)"
out="$(guild scripts/switch-back.sh 2>&1)" && rc=0 || rc=$?
[ "$rc" = 1 ] && grep -q "testbed-app#$cleared isn't blocked" <<<"$out" && grep -q "testbed-app#$moved waits on testbed-base#$other" <<<"$out" \
  && pass "the way back lists both, with the lines the reference would still read" || fail "switch-back.sh ($rc): $out"
# As the reference's protocol has it, the human edits the replaced lines out.
for c in "$line1" "$line2"; do api PATCH "/repos/testorg/testbed-app/issues/comments/$c" '{"body": "No longer."}' >/dev/null; done
out="$(guild scripts/switch-back.sh 2>&1)" && pass "with them edited out, it lists nothing" || fail "switch-back.sh after the edits: $out"
touch "$state/control/draining"
until_true 300 sh -c "curl -fsS http://127.0.0.1:3319/status | jq -e .drained" && pass "it drains" || fail "it never drained"
in_guild docker compose --profile tools --profile build down --remove-orphans >/dev/null
foreign
guild scripts/switch-back.sh --hand-back >/dev/null && pass "it hands the ledger back" || fail "switch-back.sh --hand-back failed"

echo "== The reference again"
refkit scripts/up.sh >/dev/null
until_true 120 status && pass "its dispatcher answers" || fail "its dispatcher never answered"
until_true 300 reconcile || fail "it never swept"
until_true 120 owes "testbed-app#$second" && pass "it finds the guild's ledger: testbed-app#$second is owed" \
  || fail "it doesn't owe testbed-app#$second: $(jqs .obligations)"
[ "$(jqs .draining)" = true ] && pass "it finds the guild's drain" || fail "it isn't draining"
! blocked "$cleared" && blocked "$moved" && pass "it reads the Blocked-by: lines as the guild did" \
  || fail "the reference's blocked labels: #$cleared $(blocked "$cleared" && echo on || echo off), #$moved $(blocked "$moved" && echo on || echo off)"
refkit scripts/resume.sh >/dev/null && [ "$(jqs .draining)" = false ] && pass "and resumes" || fail "it didn't resume"

echo
[ "$fails" = 0 ] && echo "The switch: all checks passed." || { echo "The switch: $fails check(s) failed."; exit 1; }
