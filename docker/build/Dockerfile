# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# Builds the kit's executables, for the images that run them to copy from /out. The
# dependencies are built before the kit's own source is copied, so a change to the kit
# rebuilds only the kit.
FROM debian:trixie-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends bash ca-certificates curl git build-essential \
      pkg-config libcurl4-openssl-dev xz-utils zstd \
 && rm -rf /var/lib/apt/lists/*
ENV ELAN_HOME=/opt/elan
ENV PATH=/opt/elan/bin:$PATH
WORKDIR /kit
COPY lean-toolchain lakefile.lean lake-manifest.json ./
RUN curl -sSfL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh \
    | sh -s -- -y --no-modify-path --default-toolchain "$(cat lean-toolchain)"
RUN lake build Json JsonDeriving Leancurl Leancrypto RoutingStd
COPY . .
RUN lake build guild-gatekeeper forge guild-hook guild-runner \
 && mkdir -p /out \
 && cp .lake/build/bin/guild-gatekeeper .lake/build/bin/forge .lake/build/bin/guild-hook \
      .lake/build/bin/guild-runner /out/ \
 && cp "$(find .lake -name libleancurl_shim.so | head -1)" /out/
