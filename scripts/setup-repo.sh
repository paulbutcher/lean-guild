#!/usr/bin/env bash
# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# Apply an autonomy level to a repository: its Forgejo settings, and a pull request for
# you to merge with the files the level needs. With no arguments, sets up every
# repository at the level the configuration starts it at.
#   scripts/setup-repo.sh [REPOSITORY LEVEL]
set -euo pipefail
. "$(dirname "$0")/lib.sh"
confirm "This applies autonomy levels to the project's repositories"
if [ $# = 0 ]; then
  status=0
  while IFS=$'\t' read -r repo level _; do
    tools setup-repo "$repo" "$level" || { s=$?; [ "$s" = 3 ] && status=3 || exit "$s"; }
  done < "$KIT_CONFIG/repos.tsv"
  exit "$status"
fi
tools setup-repo "$@"
