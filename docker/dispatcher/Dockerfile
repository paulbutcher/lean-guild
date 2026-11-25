# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# The dispatcher. tzdata, for the time zones that usage limits name when they reset.
FROM debian:trixie-slim
ARG USER_UID=1000
ARG USER_GID=1000
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl tzdata \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir /state && chown "$USER_UID:$USER_GID" /state
COPY --from=build /out/libleancurl_shim.so /usr/local/lib/
COPY --from=build /out/guild-dispatcher /usr/local/bin/
RUN ldconfig
ENTRYPOINT ["guild-dispatcher"]
