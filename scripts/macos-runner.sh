#!/usr/bin/env bash
# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# The macOS runner, on the Mac that hosts the kit: a Tart VM that runs one macos CI job and is
# thrown away, then a fresh one for the next. Run it on the Mac itself, not in a container.
#   scripts/macos-runner.sh image [TOOLCHAIN...]   build the VM image jobs start from, with these
#                                                  Lean toolchains installed (none by default)
#   scripts/macos-runner.sh run                    serve the deployment's macos jobs until Ctrl-C
# For run, KIT_ENV names the deployment's settings, for FORGE_PORT and STATE_DIR; FORGE_HOST_PORT
# replaces the port where the forge is reached through another, such as a dev container's forwarded
# one. The image is the Mac's, for any deployment: MACOS_BASE is the Tart image it starts from,
# MACOS_IMAGE its name, and MACOS_DIR (~/.guild-macos) holds the key that logs in to it.
set -euo pipefail
kit="$(cd "$(dirname "$0")/.." && pwd)"
die() { echo "macos-runner: $*" >&2; exit 1; }
log() { echo "macos-runner: $*"; }

[ "$(uname -s)" = Darwin ] || die "run this on the Mac that hosts the kit"
command -v tart >/dev/null || die "Tart isn't installed: brew install openai/tools/tart"
image="${MACOS_IMAGE:-guild-macos}"
base="${MACOS_BASE:-ghcr.io/cirruslabs/macos-sequoia-base:latest}"
dir="${MACOS_DIR:-$HOME/.guild-macos}"
key="$dir/id_ed25519"
ssh_opts=(-i "$key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)
on() { local ip="$1"; shift; ssh "${ssh_opts[@]}" "admin@$ip" "$@"; }

# A running VM's address, once it answers ssh.
address() {
  local vm="$1" ip i
  ip="$(tart ip --wait 300 "$vm")" || die "$vm got no address"
  for i in $(seq 120); do
    on "$ip" true 2>/dev/null && { echo "$ip"; return; }
    sleep 2
  done
  die "$vm never answered ssh at $ip"
}

stop_vm() {
  local vm="$1"
  tart stop "$vm" >/dev/null 2>&1 || true
  tart delete "$vm" >/dev/null 2>&1 || true
}

version_of() { sed -n "$2" "$1" | head -1; }

cmd_image() {
  mkdir -p "$dir"
  chmod 700 "$dir"
  [ -s "$key" ] || ssh-keygen -q -t ed25519 -N '' -C "$image" -f "$key"
  local node playwright runner ip pid
  node="$(version_of "$kit/layers/lasm/docker/ci/Dockerfile" 's/^FROM node:\([0-9.]*\)-.*/\1/p')"
  playwright="$(version_of "$kit/layers/lasm/docker/ci/Dockerfile" 's/^ARG PLAYWRIGHT_VERSION=\(.*\)/\1/p')"
  runner="$(version_of "$kit/compose.yaml" 's|.*code.forgejo.org/forgejo/runner:\([0-9.]*\).*|\1|p')"
  [ -n "$node" ] && [ -n "$playwright" ] && [ -n "$runner" ] || die "couldn't read the versions from the kit"
  stop_vm "$image"
  log "cloning $base as $image (the first time, this downloads it)"
  tart clone "$base" "$image"
  tart run --no-graphics "$image" >/dev/null 2>&1 &
  pid=$!
  ip="$(tart ip --wait 300 "$image")" || die "$image got no address"
  # The base image's password, once, to install the key.
  printf '#!/bin/sh\necho admin\n' > "$dir/askpass"
  chmod 700 "$dir/askpass"
  local i
  for i in $(seq 120); do
    SSH_ASKPASS="$dir/askpass" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \
      ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 \
        -o PubkeyAuthentication=no "admin@$ip" 'mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys' < "$key.pub" \
      2>/dev/null && break
    sleep 2
  done
  rm -f "$dir/askpass"
  on "$ip" true || die "couldn't log in to $image at $ip"
  scp "${ssh_opts[@]}" "$kit/layers/lasm/macos/provision.sh" "$kit/layers/lasm/macos/job.sh" "admin@$ip:"
  on "$ip" "NODE_VERSION=$node PLAYWRIGHT_VERSION=$playwright RUNNER_VERSION=$runner TOOLCHAINS='$*' bash provision.sh"
  on "$ip" 'rm provision.sh job.sh; sudo shutdown -h now' || true
  wait "$pid" || true
  log "built $image: Node $node, Playwright $playwright, the Forgejo runner $runner${*:+, Lean $*}"
}

cmd_run() {
  : "${KIT_ENV:?set KIT_ENV to the settings file of the deployment}"
  [ -f "$KIT_ENV" ] || die "no settings file at $KIT_ENV"
  KIT_ENV="$(cd "$(dirname "$KIT_ENV")" && pwd)/$(basename "$KIT_ENV")"
  set -a
  . "$KIT_ENV"
  set +a
  STATE_DIR="${STATE_DIR:-.}"
  case "$STATE_DIR" in /*) ;; *) STATE_DIR="$(dirname "$KIT_ENV")/$STATE_DIR" ;; esac
  local port="${FORGE_HOST_PORT:-${FORGE_PORT:-3000}}" secret="$STATE_DIR/secrets/ci/macos-runner-secret"
  [ -s "$secret" ] || die "no $secret: set MACOS_RUNNER=on in $KIT_ENV, then run scripts/up.sh and scripts/bootstrap.sh"
  [ -s "$key" ] && tart list --quiet 2>/dev/null | grep -qx "$image" || die "no $image image: run scripts/macos-runner.sh image first"
  local vm="$image-job" ip tunnel= vmpid started config
  trap '[ -z "$tunnel" ] || kill "$tunnel" 2>/dev/null; stop_vm "$vm"; exit 0' INT TERM
  config="log:
  level: info
runner:
  file: /Users/admin/runner/.runner
  capacity: 1
  timeout: 3h
  envs:
    FORGE_URL: http://localhost:3000
    PLAYWRIGHT_BROWSERS_PATH: /opt/ms-playwright
  labels:
    - \"macos:host\"
"
  while :; do
    stop_vm "$vm"
    tart clone "$image" "$vm"
    started="$(date +%s)"
    tart run --no-graphics "$vm" >/dev/null 2>&1 &
    vmpid=$!
    ip="$(address "$vm")"
    # The VM reaches the forge through the host, which publishes it on its loopback only.
    ssh "${ssh_opts[@]}" -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 \
      -R "3000:127.0.0.1:$port" "admin@$ip" &
    tunnel=$!
    on "$ip" 'mkdir -p runner && cat > runner/secret' < "$secret"
    on "$ip" 'cat > runner/config.tmp && mv runner/config.tmp runner/config.yml' <<<"$config"
    log "$vm is waiting for a macos job"
    wait "$vmpid" || true
    kill "$tunnel" 2>/dev/null || true
    log "$vm is done ($(( $(date +%s) - started ))s); a fresh one takes its place"
    # A VM that stops at once is broken, not busy: don't spin.
    [ $(( $(date +%s) - started )) -ge 60 ] || sleep 30
  done
}

case "${1:-}" in
  image) shift; cmd_image "$@" ;;
  run) cmd_run ;;
  *) die "usage: scripts/macos-runner.sh image [TOOLCHAIN...] | run" ;;
esac
