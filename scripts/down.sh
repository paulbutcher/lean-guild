#!/usr/bin/env bash
# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# Stop everything and keep the volumes; scripts/up.sh starts it again.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
confirm "This stops every container of the kit, keeping its volumes"
docker compose --profile tools --profile build down --remove-orphans
