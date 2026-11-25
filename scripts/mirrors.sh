#!/usr/bin/env bash
# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# The repositories' push mirrors to GitHub.
#   scripts/mirrors.sh            give every repository its mirror
#   scripts/mirrors.sh --rotate   also replace every mirror's token
#   scripts/mirrors.sh --status   each mirror's last sync and error
set -euo pipefail
. "$(dirname "$0")/lib.sh"
case "${1:-}" in
  --status) tools mirror-status ;;
  *) confirm "This creates or replaces the repositories' push mirrors"; tools mirrors "$@" ;;
esac
