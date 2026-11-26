#!/usr/bin/env bash
# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# Release a library yourself, at any autonomy level, even while paused:
#   scripts/release.sh <repository>                        show what the release would be
#   scripts/release.sh <repository> "<note>" [<issue>...]  release it
# The version is computed from API.lock's changes since the last release tag, as the gatekeeper
# computes it for the coordinator. It refuses unless CHANGELOG.md on main has an entry for that
# version and CI passed on main's head. It tags main's head as you, publishes the release with the
# note and the changelog entry, and comments the release on each issue named, which must be open
# and labelled ready-for-release.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
[ $# -ge 1 ] || { sed -n '5,12p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
repo="$1"; shift
run=(docker compose run --rm --no-deps -T)
if [ $# = 0 ]; then
  exec "${run[@]}" gatekeeper plan "$repo"
fi
confirm "This releases $repo"
# The gatekeeper's code, with your token instead of its own.
exec "${run[@]}" -e TOKEN_FILE=/run/secrets/human/token -v "$STATE_DIR/secrets/human:/run/secrets/human:ro" \
  gatekeeper release --human "$repo" "$@"
