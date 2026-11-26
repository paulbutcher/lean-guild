#!/usr/bin/env bash
# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# Open VS Code attached to an agent's running container, at its workspace, with its live run log
# in a tab. Dev Containers builds nothing: the container is already running from scripts/up.sh.
#   scripts/open.sh <agent>
set -euo pipefail
. "$(dirname "$0")/lib.sh"
[ $# = 1 ] || { echo "usage: scripts/open.sh <agent>" >&2; exit 2; }
agent="$1"
owns="$(awk -F'\t' -v a="$agent" '$1 == a { print $3 }' "$KIT_CONFIG/agents.tsv")"
[ -n "$owns" ] || { echo "$agent isn't an agent in the configuration" >&2; exit 1; }
if [ "$owns" = - ]; then workspace="/workspace/$agent"; else workspace="/workspace/$owns"; fi
container="$(docker compose ps -q "$agent")"
[ -n "$container" ] || { echo "$agent isn't running; start it with scripts/up.sh" >&2; exit 1; }
name="$(docker inspect -f '{{.Name}}' "$container" | sed 's#^/##')"
command -v code >/dev/null || { echo "Put VS Code's 'code' command on your PATH (Command Palette: Shell Command: Install 'code' command in PATH)." >&2; exit 1; }

# The attach configuration Dev Containers uses for this container: the agent's user, its workspace
# and the extensions.
case "$(uname)" in
  Darwin) cfg_dir="$HOME/Library/Application Support/Code/User/globalStorage/ms-vscode-remote.remote-containers/nameConfigs" ;;
  *) cfg_dir="$HOME/.config/Code/User/globalStorage/ms-vscode-remote.remote-containers/nameConfigs" ;;
esac
mkdir -p "$cfg_dir"
cat > "$cfg_dir/$name.json" <<JSON
{
  "remoteUser": "agent",
  "workspaceFolder": "$workspace",
  "extensions": ["anthropic.claude-code", "leanprover.lean4"],
  "settings": {
    "remote.autoForwardPorts": false
  }
}
JSON

hex="$(printf '{"containerName":"/%s"}' "$name" | od -An -tx1 | tr -d ' \n')"
code --folder-uri "vscode-remote://attached-container+$hex$workspace"
code --file-uri "vscode-remote://attached-container+$hex$workspace/${WORKSPACE_STATE:-.guild}/current.md" 2>/dev/null || true
