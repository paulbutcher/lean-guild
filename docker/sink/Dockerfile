# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# Stands in for the dispatcher and the gatekeeper until they exist: answers health
# checks, and records each webhook's time and event type.
FROM alpine:3.24
RUN apk add --no-cache bash socat
COPY --chmod=0755 handle /usr/local/bin/handle
CMD ["socat", "TCP-LISTEN:8080,fork,reuseaddr", "EXEC:/usr/local/bin/handle"]
