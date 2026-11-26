#!/usr/bin/env bash
# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# Stage 9's acceptance, in the plain test project:
#   - the reference's stage 8: scripts/backup.sh makes a backup readable by its owner only, and
#     three with BACKUP_KEEP=2 leave the newest two; scripts/restore-test.sh restores the newest
#     into a throwaway Forgejo and finds it matches what Forgejo held;
#   - scripts/restore.sh puts the kit back as it was at the backup: Forgejo, the ledger and the
#     run archive, keeping a raw copy of what it replaced, and the kit answers again;
#   - scripts/new-library.sh seeds an empty library that passes CI, and leaves it alone after;
#   - scripts/milestone.sh shows the API.lock changes and opens the milestone issue, and
#     scripts/release.sh asks the gatekeeper what a release would be.
# Deployed with mirrors off, in its own compose project, and removed at the end unless KEEP=1.
# Run it in the dev container, never against the host's engine.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
(cd test && lake build kit-plain >/dev/null)
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

name=backup
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
  echo "FORGE_PORT=3325"
  echo "DISPATCHER_PORT=3326"
  echo "UI_PORT=3327"
  echo "RESTORE_TEST_PORT=3328"
  echo "FORGE_WEB_URL=http://localhost:3325"
  echo "STATE_DIR=state"
  echo "MIRRORS=off"
} > "$dir/settings.env"
p="guild-test-$name"
dc() { "$root/test/stages/in-kit.sh" docker compose "$@"; }
dc --profile tools down -v --remove-orphans >/dev/null 2>&1 || true
docker compose -p "$p-restore-test" -f docker/restore-test/compose.yaml down -v >/dev/null 2>&1 || true
rm -rf "${dir:?}/state"
remove() {
  [ "${KEEP:-}" = 1 ] && { echo "INFO: kept $name"; return; }
  dc --profile tools down -v --remove-orphans >/dev/null 2>&1 || true
}
trap remove EXIT

scripts/up.sh >/dev/null
scripts/bootstrap.sh >/dev/null
state="$dir/state"
backups="$state/backups"

until_true() {
  local deadline=$(( $(date +%s) + $1 ))
  shift
  while [ "$(date +%s)" -lt "$deadline" ]; do
    "$@" >/dev/null 2>&1 && return 0
    sleep 5
  done
  return 1
}
human() { dc run --rm -T tools api "$@" </dev/null; }
raw() { dc run --rm -T --no-deps --entrypoint curl tools -fsS -H "Authorization: token $(tr -d '[:space:]' < "$state/secrets/human/token")" \
  "http://forgejo:3000/api/v1/repos/testorg/$1/raw/$2?ref=main" </dev/null; }
ledger() {
  docker run --rm --network none --user "$(id -u):$(id -g)" -v "${p}_dispatcher-state:/state" \
    --entrypoint sqlite3 "$p-tools:1" /state/ledger.db "$@"
}
archive() { docker run --rm --network none -v "${p}_run-archive:/archive" --entrypoint sh "$p-tools:1" -c "$1"; }
issue() { human POST /repos/testorg/testbed-coordination/issues "$(jq -nc --arg t "$1" '{title: $t, body: "A note."}')" | jq -r .number; }
open_titles() { human GET "/repos/testorg/testbed-coordination/issues?state=all&type=issues&limit=50" | jq -r '.[].title'; }

echo "== A new library"
dc run --rm -T tools test-push-fixture testbed-base </dev/null
# Forgejo serves a push's files a moment after it accepts it.
until_true 120 raw testbed-base lakefile.toml || fail "testbed-base's fixture never appeared"
if out="$(scripts/new-library.sh testbed-app App 2>&1)"; then
  pass "new-library seeded testbed-app: $(grep -o 'committed the seed.*' <<<"$out")"
else
  fail "new-library: $out"
fi
lakefile="$(raw testbed-app lakefile.lean || true)"
grep -q 'roots := #\[`Testbed.App\]' <<<"$lakefile" && grep -q 'package «testbed-app»' <<<"$lakefile" \
  && pass "its lakefile builds Testbed.App as the package testbed-app" || fail "its lakefile: $lakefile"
[ "$(raw testbed-app lean-toolchain)" = "$(raw testbed-base lean-toolchain)" ] \
  && pass "it shares the source library's toolchain" || fail "its toolchain differs from testbed-base's"
raw testbed-app Testbed/App.lean >/dev/null && raw testbed-app test/Main.lean >/dev/null \
  && raw testbed-app .forgejo/workflows/checks.yml >/dev/null \
  && pass "it has its module, its tests and CI" || fail "a file of the seed is missing"
head="$(human GET /repos/testorg/testbed-app/branches/main | jq -r .commit.id)"
ci() { human GET "/repos/testorg/testbed-app/actions/runs?head_sha=$head" | jq -r '[.workflow_runs[]? | .status][0] // ""'; }
ci_done() { case "$(ci)" in success|failure) return 0 ;; *) return 1 ;; esac; }
until_true 900 ci_done || true
[ "$(ci)" = success ] && pass "the seed passes CI" || fail "the seed's CI: $(ci)"
out="$(scripts/new-library.sh testbed-app App 2>&1 || true)"
grep -q 'already seeded' <<<"$out" && pass "run again, it leaves the library alone" || fail "run again: $out"
out="$(scripts/new-library.sh testbed-coordination Coordination 2>&1 || true)"
grep -q "isn't owned by a library" <<<"$out" && pass "it refuses a repository no library owns" || fail "the coordination repository: $out"

echo "== Milestones and releases"
out="$(scripts/milestone.sh --diff 2>&1)"
grep -q '^### testbed-base' <<<"$out" && grep -q 'No earlier milestone recorded' <<<"$out" \
  && pass "milestone --diff shows each library since no milestone" || fail "milestone --diff: $out"
scripts/milestone.sh "M1" >/dev/null 2>&1 || true
labels="$(human GET "/repos/testorg/testbed-coordination/issues?state=open&type=issues&labels=milestone" \
  | jq -r '[.[] | select(.title == "Milestone: M1")][0] | [.labels[].name] | sort | join(",")')"
[ "$labels" = milestone,milestone-review ] && pass "milestone opened its issue, labelled milestone and milestone-review" \
  || fail "the milestone issue's labels: $labels"
out="$(scripts/milestone.sh --diff 2>&1)"
grep -q 'No change to `API.lock` since' <<<"$out" && ! grep -q 'No earlier milestone' <<<"$out" \
  && pass "after it, the diff starts from the milestone's refs" || fail "the diff after the milestone: $out"
out="$(scripts/release.sh testbed-base 2>&1 || true)"
grep -qE '"version"|^Not released:' <<<"$out" && pass "release asks the gatekeeper: $(head -1 <<<"$out")" \
  || fail "release.sh: $out"

echo "== Backups and pruning (the reference's stage 8)"
n="$(issue "Before the backup")"
human POST "/repos/testorg/testbed-coordination/issues/$n/comments" '{"body": "A comment."}' >/dev/null
ledger "INSERT INTO kv VALUES ('stage9', 'before')"
archive 'mkdir -p /archive/base && echo before > /archive/base/stage9.md'
made=()
for i in 1 2 3; do
  if out="$(BACKUP_KEEP=2 scripts/backup.sh 2>&1)"; then
    made+=("$(sed -n 's|^Backed up to .*/\([0-9TZ]*\) .*|\1|p' <<<"$out")")
  else
    fail "backup $i: $out"
  fi
  sleep 1
done
left="$(ls -1 "$backups" | grep -E '^[0-9]+T[0-9]+Z$' | sort | tr '\n' ' ')"
[ "$left" = "${made[1]:-} ${made[2]:-} " ] && pass "three backups with BACKUP_KEEP=2 left the newest two ($left)" \
  || fail "left: $left; made: ${made[*]}"
newest="$backups/${made[2]:-none}"
for f in forgejo.tar.gz ledger.db run-archive.tar.gz before.json after.json; do
  [ -s "$newest/$f" ] || fail "the backup has no $f"
done
[ "$(stat -c %a "$newest/forgejo.tar.gz" 2>/dev/null)" = 600 ] \
  && pass "the backup's files are readable by their owner only" || fail "the backup's files are readable by others"
if out="$(scripts/restore-test.sh 2>&1)"; then
  pass "$(grep '^Compared' <<<"$out")"
else
  fail "restore test: $out"
fi
docker volume ls -q | grep -q "^$p-restore-test_" && fail "the restore test left its volume" \
  || pass "the restore test removed its throwaway Forgejo"
out="$(scripts/backup-install.sh 2>&1 || true)"
grep -q crontab <<<"$out" && echo "INFO: not on a Mac: backup-install offers a crontab line" || echo "INFO: backup-install: $out"

echo "== Restoring"
issue "After the backup" >/dev/null
ledger "UPDATE kv SET value = 'after' WHERE key = 'stage9'"
archive 'echo after > /archive/base/stage9.md && echo after > /archive/base/later.md'
if out="$(RESTORE_CONFIRM=restore scripts/restore.sh "$newest" 2>&1)"; then
  pass "restore.sh restored ${made[2]:-}"
else
  fail "restore.sh: $(tail -5 <<<"$out")"
fi
ls "$backups"/pre-restore-*.tar.gz >/dev/null 2>&1 && pass "it kept a raw copy of the Forgejo it replaced" \
  || fail "it kept no copy of the Forgejo it replaced"
titles="$(open_titles)"
grep -qx "Before the backup" <<<"$titles" && ! grep -qx "After the backup" <<<"$titles" \
  && pass "Forgejo is as it was at the backup" || fail "Forgejo's issues: $titles"
snap="$(dc run --rm -T tools snapshot </dev/null)"
printf '%s' "$snap" > "$dir/now.json"
cmp="$(docker run --rm --network none -e FORGE_ORG=testorg -v "$newest:/b:ro" -v "$dir/now.json:/now.json:ro" \
  -v "$state/config:/etc/kit:ro" "$p-tools:1" snapshot-compare /b/before.json /b/after.json /now.json)"
grep -qx MATCH <<<"$cmp" && pass "every repository, ref and item matches the backup" || fail "after restoring: $cmp"
[ "$(ledger "SELECT value FROM kv WHERE key = 'stage9'")" = before ] \
  && pass "the ledger is the backup's" || fail "the ledger: $(ledger "SELECT value FROM kv WHERE key = 'stage9'")"
[ "$(archive 'cat /archive/base/stage9.md; ls /archive/base/later.md 2>/dev/null')" = before ] \
  && pass "the run archive is the backup's" || fail "the run archive: $(archive 'ls -l /archive/base')"
until_true 120 curl -fsS "http://127.0.0.1:3326/status" && pass "the dispatcher answers again" \
  || fail "the dispatcher doesn't answer after restoring"
out="$(scripts/bootstrap.sh 2>&1 | tail -1)"
[ "$out" = 0 ] && pass "bootstrap finds nothing to change" || fail "bootstrap after restoring: $out"

echo "== New agents start stopped"
agents="$(cut -f1 "$state/config/agents.tsv")"
kept="$(head -1 <<<"$agents")"
# A workspace, as a switch from the reference brings it.
docker volume create --label com.docker.compose.project="$p" --label com.docker.compose.volume="work-$kept" \
  "${p}_work-$kept" >/dev/null
printf 'not-a-real-token\n' > "$state/secrets/claude/oauth-token"
scripts/up.sh >/dev/null
stopped=1
for a in $agents; do
  if [ "$a" = "$kept" ]; then
    [ -e "$state/control/stopped-$a" ] && { fail "$a, which has a workspace, was stopped"; stopped=0; }
  else
    [ -e "$state/control/stopped-$a" ] || { fail "$a, never started, isn't stopped"; stopped=0; }
  fi
done
[ "$stopped" = 1 ] && pass "agents never started are stopped, and $kept, which has a workspace, isn't"
running="$(dc ps --status running --services)"
grep -qx "$(sed -n 2p <<<"$agents")" <<<"$running" && pass "a stopped agent's container runs, taking no work" \
  || fail "the agents' containers: $running"
second="$(sed -n 2p <<<"$agents")"
rm -f "$state/control/stopped-$second"
scripts/up.sh >/dev/null
[ -e "$state/control/stopped-$second" ] && fail "up.sh stopped $second again after it was started" \
  || pass "once started, an agent isn't stopped again"
out="$(NEW_AGENTS=maybe scripts/up.sh 2>&1 || true)"
grep -q 'must be stopped or running' <<<"$out" && pass "a malformed NEW_AGENTS is an error" || fail "NEW_AGENTS=maybe: $out"

echo
[ "$fails" = 0 ] && echo "Stage 9: all checks passed." || { echo "Stage 9: $fails check(s) failed."; exit 1; }
