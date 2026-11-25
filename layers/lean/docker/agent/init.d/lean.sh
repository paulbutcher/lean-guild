# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# The Lean layer's start-up, run by guild-init with OWN set to the agent's workspace: elan
# and the repository's toolchain, in the volume every agent shares, one agent at a time;
# and the Lean language server for Claude.
(
  flock 9
  if [ ! -x "$HOME/.elan/bin/elan" ]; then
    curl -sSfL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh \
      | sh -s -- -y --default-toolchain none --no-modify-path >/dev/null \
      || echo "lean.sh: couldn't install elan; check the proxy, then restart this container" >&2
  fi
  if [ -f "$OWN/lean-toolchain" ]; then
    elan toolchain install "$(cat "$OWN/lean-toolchain")" >/dev/null 2>&1 \
      || echo "lean.sh: couldn't install $(cat "$OWN/lean-toolchain"); check the proxy" >&2
  fi
) 9>"$HOME/.elan/.guild-init.lock"
claude mcp list 2>/dev/null | grep -q '^lean-lsp' \
  || claude mcp add --scope user lean-lsp -- lean-lsp-mcp >/dev/null 2>&1 || true
