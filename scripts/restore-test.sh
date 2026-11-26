#!/usr/bin/env bash
# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# Check that a backup restores: restore it (the newest by default) into a throwaway Forgejo of its
# own (docker/restore-test/), then compare its repositories, refs, issues, pull requests and
# comment counts with what the live Forgejo held while the backup was made. The throwaway copy
# can reach nothing, so it can't push old refs to a mirror. It is removed afterwards unless
# KEEP=1, which leaves it on 127.0.0.1:RESTORE_TEST_PORT (3003).
#   scripts/restore-test.sh [<backup folder>]
set -euo pipefail
. "$(dirname "$0")/lib.sh"
dir="${BACKUP_DIR:-$STATE_DIR/backups}"
b="${1:-$(ls -1d "$dir"/[0-9]*Z 2>/dev/null | sort | tail -1)}"
[ -n "$b" ] && [ -s "$b/forgejo.tar.gz" ] || { echo "No backup to test in $dir; run scripts/backup.sh first." >&2; exit 1; }
b="$(cd "$b" && pwd)"
echo "Testing the backup ${b##*/}."
image="$COMPOSE_PROJECT_NAME-tools:1"
p="$COMPOSE_PROJECT_NAME-restore-test"

rt=(docker compose -p "$p" -f docker/restore-test/compose.yaml)
cleanup() { [ "${KEEP:-}" = 1 ] || "${rt[@]}" down -v --remove-orphans >/dev/null 2>&1 || true; }
"${rt[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
trap cleanup EXIT
docker volume create --label com.docker.compose.project="$p" --label com.docker.compose.volume=forgejo-data \
  "${p}_forgejo-data" >/dev/null

# The same step as scripts/restore.sh, into the throwaway volume.
docker run --rm --user 0 --network none --entrypoint restore-volumes \
  -v "${p}_forgejo-data:/restore/forgejo" -v "$b:/backup:ro" "$image" /backup

"${rt[@]}" up -d --wait --quiet-pull forgejo ports >/dev/null 2>&1 \
  || { echo "The restored Forgejo didn't start:" >&2; "${rt[@]}" logs --tail 30 forgejo >&2; exit 1; }
"${rt[@]}" exec -T forgejo forgejo admin regenerate hooks >/dev/null 2>&1 || true

# The same snapshot as the backup's, of the restored copy, with the human's token, whose hash came
# back with the database.
docker run --rm --network "${p}_restored" --user "$HOST_UID:$HOST_GID" \
  -e FORGE_URL=http://forgejo:3000 -e FORGE_ORG -e HUMAN_USER \
  -v "$STATE_DIR/secrets/human:/secrets/human:ro" -v "$KIT_CONFIG:/etc/kit:ro" \
  "$image" snapshot > "$b/restored.json.tmp"
mv "$b/restored.json.tmp" "$b/restored.json"

result="$(docker run --rm --network none -e FORGE_ORG -v "$b:/b:ro" -v "$KIT_CONFIG:/etc/kit:ro" \
  "$image" snapshot-compare /b/before.json /b/after.json /b/restored.json)"
printf '%s\n' "$result" | grep -v '^MATCH$'
if grep -qx MATCH <<<"$result"; then
  echo "Restore test passed: the backup restores everything Forgejo held."
else
  echo "Restore test FAILED: the restored Forgejo differs (above)." >&2
  exit 1
fi
