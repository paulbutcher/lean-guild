#!/usr/bin/env bash
# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# Run a kit command in the tools container with this deployment's settings, for example:
#   scripts/kit.sh api GET /user
set -euo pipefail
. "$(dirname "$0")/lib.sh"
tools "$@"
