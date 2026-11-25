# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

FROM debian:trixie-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/libleancurl_shim.so /usr/local/lib/
COPY --from=build /out/guild-gatekeeper /usr/local/bin/
RUN ldconfig
ENTRYPOINT ["guild-gatekeeper"]
