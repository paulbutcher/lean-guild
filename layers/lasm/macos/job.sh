#!/bin/bash
# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# Run inside a clone of the macOS image, at login: waits for the host to hand over the runner's
# secret and configuration, runs one macos job, and shuts the VM down, so that the host throws
# it away and the next job starts in a fresh clone.
cd "$HOME/runner" || exit 1
until [ -s config.yml ] && [ -s secret ]; do sleep 2; done
{
  forgejo-runner create-runner-file -c config.yml --instance http://localhost:3000 \
    --secret "$(tr -d '[:space:]' < secret)" --name macos
  rm -f secret
  forgejo-runner one-job --wait -c config.yml
} >> job.log 2>&1
sudo shutdown -h now
