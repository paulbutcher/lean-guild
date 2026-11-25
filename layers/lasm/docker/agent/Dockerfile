# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# The Lasm layer's agents: Node, and Playwright's headless Chromium and WebKit for
# browser tests. Agents can't download browsers, so repositories pin `playwright` at
# exactly this version, which the protocol names.
FROM node:24.18.1-trixie-slim AS node

FROM lean
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
 && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx
ARG PLAYWRIGHT_VERSION=1.64.1
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
RUN npx -y "playwright@${PLAYWRIGHT_VERSION}" install --with-deps --only-shell chromium \
 && npx -y "playwright@${PLAYWRIGHT_VERSION}" install --with-deps webkit \
 && chmod -R a+rX /opt/ms-playwright \
 && rm -rf /root/.npm /var/lib/apt/lists/*
# Node's built-in fetch ignores the proxy variables unless asked, and agents have no
# route out but the proxy.
ENV NODE_USE_ENV_PROXY=1
