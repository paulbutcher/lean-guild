# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# The image CI jobs run in, for the Lean layer. Toolchains live in a volume of the CI
# engine, mounted at /opt/elan/toolchains, so each is downloaded once.
FROM debian:trixie-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends bash ca-certificates curl git jq xz-utils zstd \
 && rm -rf /var/lib/apt/lists/*
ENV ELAN_HOME=/opt/elan
ENV PATH=/opt/elan/bin:$PATH
RUN curl -sSfL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh \
    | sh -s -- -y --no-modify-path --default-toolchain none \
 && mkdir -p /opt/elan/toolchains
