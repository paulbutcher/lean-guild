#!/usr/bin/env bash
# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# Seed a new library's repository in Forgejo with a package that builds and passes CI, then give
# the agents' teams access and the labels, as scripts/bootstrap.sh does. Add the library and its
# agent to the configuration first. Safe to re-run.
#   scripts/new-library.sh <repository> <Name>
# Then scripts/mirrors.sh for its push mirror, and scripts/setup-repo.sh for its autonomy level.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
[ $# = 2 ] || { echo "usage: scripts/new-library.sh <repository> <Name>" >&2; exit 2; }
confirm "This seeds $1 in Forgejo and gives the agents' teams access to it"
tools new-library "$1" "$2"
tools bootstrap
