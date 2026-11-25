#!/usr/bin/env bash
# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# Runs a command in a deployment's environment, as the kit's scripts see it.
set -euo pipefail
. "$(dirname "$0")/../../scripts/lib.sh"
"$@"
