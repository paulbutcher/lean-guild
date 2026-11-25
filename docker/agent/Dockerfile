# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# The kit's base for every agent: Claude Code, tea, git and the tools the kit's scripts
# use. The layers build on it, and the project's configuration picks the top one.
# Versions are pinned, so every agent runs the same tools.
FROM debian:trixie-slim

ARG CLAUDE_CODE_VERSION=2.1.311
ARG TEA_VERSION=0.16.0
ARG TEA_SHA256_AMD64=9c142c8a0b31485eea2387031c1c404f12b7141075eb4ffbd7ced49441590636
ARG TEA_SHA256_ARM64=0e14a036322eeb1fc55e266acafeb8490e523ed99f9232034ae74861e2339879
ARG USER_UID=1000
ARG USER_GID=1000
ARG TARGETARCH

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash ca-certificates curl git jq less procps tmux util-linux xz-utils \
 && rm -rf /var/lib/apt/lists/*

# tea, Forgejo's command line, checked against its published checksum.
RUN case "$TARGETARCH" in \
      amd64) sum="$TEA_SHA256_AMD64" ;; \
      arm64) sum="$TEA_SHA256_ARM64" ;; \
      *) echo "no tea build for $TARGETARCH" >&2; exit 1 ;; \
    esac \
 && curl -fsSL -o /usr/local/bin/tea \
      "https://gitea.com/gitea/tea/releases/download/v${TEA_VERSION}/tea-${TEA_VERSION}-linux-${TARGETARCH}" \
 && echo "$sum  /usr/local/bin/tea" | sha256sum -c - \
 && chmod 0755 /usr/local/bin/tea

# Claude Code's own build, which needs no Node, moved out of root's home.
RUN curl -fsSL https://claude.ai/install.sh | bash -s "${CLAUDE_CODE_VERSION}" \
 && cp -L /root/.local/bin/claude /usr/local/bin/claude \
 && rm -rf /root/.local /root/.claude* \
 && claude --version

# The agent's user, with the host user's IDs so it can read its secrets. -o allows IDs
# the base image already uses.
RUN groupadd -o -g "${USER_GID}" agent \
 && useradd -o -m -u "${USER_UID}" -g "${USER_GID}" -s /bin/bash agent \
 && mkdir -p /home/agent/.claude /home/agent/.elan /home/agent/.config/tea \
             /workspace /var/lib/guild/archive /etc/claude-code /usr/local/share/guild \
 && chown -R agent:agent /home/agent /workspace /var/lib/guild

ENV PATH=/home/agent/.elan/bin:/usr/local/bin:/usr/bin:/bin \
    CLAUDE_CONFIG_DIR=/home/agent/.claude \
    DISABLE_AUTOUPDATER=1
WORKDIR /workspace

# The kit's own tools, built in the kit-build image.
COPY --from=kit /out/libleancurl_shim.so /usr/local/lib/
COPY --from=kit /out/forge /out/guild-hook /out/guild-runner /usr/local/bin/
COPY bin/ /usr/local/bin/
COPY managed-settings.json /etc/claude-code/managed-settings.json
RUN /sbin/ldconfig \
 && mkdir -p /usr/local/lib/guild/init.d /etc/guild \
 && git config --system credential.http://forgejo:3000.helper "" \
 && git config --system --add credential.http://forgejo:3000.helper /usr/local/bin/git-credential-forgejo \
 && git config --system include.path /etc/guild/gitconfig \
 && git config --system push.autoSetupRemote true \
 && git config --system init.defaultBranch main \
 && git config --system safe.directory '/workspace/*'
ENTRYPOINT ["guild-init"]
