#!/bin/bash
# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# Run inside the macOS VM, once, by scripts/macos-runner.sh image: what every macos job needs, so
# that a job in a fresh clone of the image starts at once. NODE_VERSION, PLAYWRIGHT_VERSION and
# RUNNER_VERSION are the CI image's and the kit's; TOOLCHAINS are Lean toolchains to install now.
set -euo pipefail
: "${NODE_VERSION:?}" "${PLAYWRIGHT_VERSION:?}" "${RUNNER_VERSION:?}"
# A command over ssh has no /usr/local/bin on its PATH, where Node goes.
export PATH="/usr/local/bin:$PATH"

echo "Node $NODE_VERSION"
curl -fsSL "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-darwin-arm64.tar.gz" \
  | sudo tar -xz -C /usr/local --strip-components=1

echo "Playwright $PLAYWRIGHT_VERSION's WebKit and Chromium, as CI has them, beside Safari"
sudo mkdir -p /opt/ms-playwright
sudo chown "$USER" /opt/ms-playwright
PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright npx -y "playwright@$PLAYWRIGHT_VERSION" install webkit chromium

echo "Safari, through WebDriver"
sudo safaridriver --enable

echo "elan"
curl -sSfL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh | sh -s -- -y --default-toolchain none
for t in ${TOOLCHAINS:-}; do "$HOME/.elan/bin/elan" toolchain install "$t"; done

# Forgejo publishes no macOS build of its runner, so it is built here, and Go goes after.
echo "The Forgejo runner $RUNNER_VERSION"
tmp="$(mktemp -d)"
go="$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -1)"
curl -fsSL "https://go.dev/dl/$go.darwin-arm64.tar.gz" | tar -xz -C "$tmp"
git clone -q --depth 1 --branch "v$RUNNER_VERSION" https://code.forgejo.org/forgejo/runner "$tmp/runner"
(cd "$tmp/runner" && CGO_ENABLED=0 GOPATH="$tmp/gopath" GOCACHE="$tmp/cache" GOFLAGS=-modcacherw \
  "$tmp/go/bin/go" build -trimpath -o "$tmp/forgejo-runner" .)
sudo install -m 755 "$tmp/forgejo-runner" /usr/local/bin/forgejo-runner
rm -rf "$tmp"

# The job runs in the logged-in session, which Safari's automation needs, as soon as the host
# hands it the runner's files.
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/runner"
install -m 755 "$HOME/job.sh" "$HOME/runner-job.sh"
cat > "$HOME/Library/LaunchAgents/guild.runner.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>guild.runner</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$HOME/runner-job.sh</string></array>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF
echo "Provisioned."
