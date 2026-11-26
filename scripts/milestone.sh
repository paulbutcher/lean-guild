#!/usr/bin/env bash
# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# End a milestone: open its issue on the coordination repository, with every API.lock change since
# the last milestone, labelled milestone-review, which wakes the milestone reviewers.
#   scripts/milestone.sh "Milestone 2"
# scripts/milestone.sh --diff shows those changes and opens nothing.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
[ $# = 1 ] || { echo "usage: scripts/milestone.sh <milestone name> | --diff" >&2; exit 2; }
if [ "$1" = --diff ]; then
  exec docker compose run --rm -T tools milestone-diff
fi
confirm "This opens the milestone issue \"$1\", which wakes the milestone reviewers"
docker compose run --rm -T tools milestone "$1"
