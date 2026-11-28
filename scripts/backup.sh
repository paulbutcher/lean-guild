#!/usr/bin/env bash
# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# Back up the kit into BACKUP_DIR (default backups/ under STATE_DIR), one folder per backup named
# by its UTC time, keeping the newest BACKUP_KEEP (7). scripts/backup-install.sh runs it daily;
# scripts/restore-test.sh checks that the newest restores. Each backup holds:
#   forgejo.tar.gz      `forgejo dump`: repositories, the database as SQL, attachments and
#                       Forgejo's configuration
#   ledger.db           the dispatcher's run ledger, an SQLite online backup
#   run-archive.tar.gz  every run's and session's log and transcript
#   before.json, after.json
#                       what Forgejo held just before and after the dump (kit snapshot), for
#                       scripts/restore-test.sh
# secrets/ and control/ aren't in it: they are files under STATE_DIR.
# Each attempt is recorded for the dispatcher, which shows it and makes a failure a notice:
# control/backup-ok holds the last success's time and folder, control/backup-failed the last
# failure's time and BACKUP_LOG, the log the daily job writes to. A failure before STATE_DIR is
# known goes unrecorded, and becomes a notice once no backup has succeeded for a day.
set -euo pipefail
out=""
finish() {
  local rc=$? name detail
  [ -z "$out" ] || rm -rf "$out.partial"
  case "${STATE_DIR:-}" in /*) [ -d "$STATE_DIR/control" ] || return 0 ;; *) return 0 ;; esac
  if [ "$rc" = 0 ]; then name=backup-ok detail="$out"; else name=backup-failed detail="${BACKUP_LOG:-}"; fi
  printf '%s\n%s\n' "$(date +%s)" "$detail" > "$STATE_DIR/control/$name.partial"
  mv "$STATE_DIR/control/$name.partial" "$STATE_DIR/control/$name"
}
trap finish EXIT
. "$(dirname "$0")/lib.sh"
umask 077  # tokens' hashes, Forgejo's secrets, transcripts
dir="${BACKUP_DIR:-$STATE_DIR/backups}"
keep="${BACKUP_KEEP:-7}"
out="$dir/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$out.partial"
image="$COMPOSE_PROJECT_NAME-tools:1"
volume() { echo "${COMPOSE_PROJECT_NAME}_$1"; }

docker compose run --rm -T tools snapshot > "$out.partial/before.json"

docker compose exec -T forgejo sh -c 'rm -f /tmp/gitea/kit-dump.tar.gz && forgejo dump --quiet --type tar.gz --skip-index --skip-repo-archives --skip-log --file /tmp/gitea/kit-dump.tar.gz >&2'
docker compose exec -T forgejo cat /tmp/gitea/kit-dump.tar.gz > "$out.partial/forgejo.tar.gz"
docker compose exec -T forgejo rm -f /tmp/gitea/kit-dump.tar.gz

# As the dispatcher's user, so that any journal SQLite makes belongs to it.
docker run --rm --network none --user "$HOST_UID:$HOST_GID" -v "$(volume dispatcher-state):/state" \
  --entrypoint sh "$image" -c 'sqlite3 /state/ledger.db ".backup /tmp/ledger.db" && cat /tmp/ledger.db' \
  > "$out.partial/ledger.db"

# Through compose, which makes the volume with its labels if no agent has yet.
docker compose run --rm --no-deps -T --entrypoint tar archive-init -C /archive -czf - . > "$out.partial/run-archive.tar.gz"

docker compose run --rm -T tools snapshot > "$out.partial/after.json"

mv "$out.partial" "$out"
echo "Backed up to $out ($(du -sh "$out" | cut -f1))."

# The newest $keep backups stay; so does anything that isn't a backup.
ls -1d "$dir"/[0-9]*Z 2>/dev/null | sort -r | tail -n +"$((keep + 1))" | while read -r old; do
  rm -rf "$old"
  echo "Removed the old backup $old."
done
