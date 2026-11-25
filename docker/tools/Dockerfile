# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# Admin tasks against Forgejo's API: bootstrap, repository setup, mirrors and tests,
# with known bash and jq versions, whatever the host has.
FROM alpine:3.24
RUN apk add --no-cache bash curl jq git openssl coreutils
COPY --chmod=0755 kit /usr/local/bin/kit
COPY --chmod=0755 lib/ /usr/local/lib/kit/
ENV HOME=/tmp
ENTRYPOINT ["/usr/local/bin/kit"]
