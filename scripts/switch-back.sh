#!/usr/bin/env bash
# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# The way back to the reference, run while the guild is up: lists each open item the reference
# would find blocked on more than the guild does. The reference reads every Blocked-by: line in an
# item, where the guild reads its description's and its newest comment's, so a line a later comment
# replaced blocks again. Edit those lines out, then run this again. Exits 1 while any are listed.
#
# With --hand-back, run once the guild is stopped: gives the ledger to uid 1000, which the
# reference's dispatcher runs as whatever the host's uid is.
set -euo pipefail
KIT_NO_BUILD=1
. "$(dirname "$0")/lib.sh"
if [ "${1:-}" = --hand-back ]; then
  [ -z "$(docker compose ps -q dispatcher)" ] \
    || { echo "The guild's dispatcher is running: stop the kit, then run this again." >&2; exit 1; }
  confirm "This gives the ledger to the reference's dispatcher, uid 1000"
  docker run --rm --network none -v "${COMPOSE_PROJECT_NAME}_dispatcher-state:/state" alpine:3.24 \
    chown -R 1000:1000 /state
  echo "The ledger is the reference's: start it with its scripts/up.sh."
  exit 0
fi
key="$(tr -d '[:space:]' < "$STATE_DIR/secrets/dispatcher/admin-key")"
out="$(curl -fsS -X POST -H "Authorization: Bearer $key" -H 'Content-Type: application/json' -d '{}' \
  "http://127.0.0.1:${DISPATCHER_PORT:-3001}/admin/switch-back")" \
  || { echo "The guild's dispatcher didn't answer: start the kit, then run this again." >&2; exit 1; }
if [ -z "$out" ]; then
  echo "The reference would read every open item's Blocked-by: lines as the guild does."
  exit 0
fi
echo "The reference would read these differently:"
printf '%s\n' "$out" | sed 's/^/- /'
exit 1
