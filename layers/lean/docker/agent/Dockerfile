# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# The Lean layer's agents: lean-lsp-mcp, the Lean tools repositories' CLAUDE.md files
# ask agents to use. elan installs toolchains into the agents' shared volume.
FROM base
ARG LEAN_LSP_MCP_VERSION=0.32.0
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 python3-pip \
 && rm -rf /var/lib/apt/lists/* \
 && pip install --no-cache-dir --break-system-packages "lean-lsp-mcp==${LEAN_LSP_MCP_VERSION}"

COPY init.d/ /usr/local/lib/guild/init.d/
RUN jq '.permissions.allow += ["mcp__lean-lsp"]' /etc/claude-code/managed-settings.json > /tmp/settings.json \
 && mv /tmp/settings.json /etc/claude-code/managed-settings.json
