#!/usr/bin/env bash
# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# Stage 6's acceptance, beyond `lake test`, which ports the reference's test-hook.sh: in the
# agents' own image, against a real Forgejo,
#   - `forge ci --rerun` runs a failed run again once, then refuses, counted from the forge;
#   - `forge version` works in a checkout cloned with the agent's credentials;
#   - the hook refuses a human session's push, and stops a run while paused;
#   - the image carries the tools, the managed settings that call the hook, and git's rules.
# The plain test project is deployed with mirrors off, in its own compose project, and removed
# at the end unless KEEP=1. Run it in the dev container, never against the host's engine.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
(cd test && lake build kit-plain >/dev/null)
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

name=tools
dir="$root/test/.lake/stages/$name"
export COMPOSE_FILE="compose.yaml:test/compose.test.yaml" KIT_YES=1
export KIT_ENV="$dir/settings.env" KIT="$root/test/.lake/build/bin/kit-plain"
mkdir -p "$dir"
{
  echo "COMPOSE_PROJECT_NAME=guild-test-$name"
  echo "FORGE_ORG=testorg"
  echo "HUMAN_USER=tester"
  echo "HUMAN_EMAIL=tester@noreply.localhost"
  echo "HUMAN_PASSWORD=$(openssl rand -hex 12)"
  echo "FORGE_PORT=3315"
  echo "FORGE_WEB_URL=http://localhost:3315"
  echo "STATE_DIR=state"
  echo "MIRRORS=off"
} > "$dir/settings.env"
dc() { "$root/test/stages/in-kit.sh" docker compose "$@"; }
dc --profile tools down -v --remove-orphans >/dev/null 2>&1 || true
rm -rf "${dir:?}/state"
remove() {
  [ "${KEEP:-}" = 1 ] && { echo "INFO: kept $name"; return; }
  dc --profile tools down -v --remove-orphans >/dev/null 2>&1 || true
}
trap remove EXIT

scripts/up.sh >/dev/null
scripts/bootstrap.sh >/dev/null
state="$dir/state"
config="$state/config"

# agent COMMAND...: a command in the agents' image, as the owner of testbed-base.
agent() {
  dc run --rm -T --entrypoint "" -e AGENT_NAME=base -e AGENT_REPO=testbed-base -e FORGE_ORG=testorg \
    -e RERUN_LIMIT=1 -v "$state/secrets/base/token:/run/secrets/forgejo_token:ro" \
    -v "$config/gitconfig:/etc/guild/gitconfig:ro" probe "$@" </dev/null
}
b64() { printf '%s' "$1" | base64 -w0; }

echo "== The image"
agent sh -c 'test -x /usr/local/bin/forge && test -x /usr/local/bin/guild-hook && test -x /usr/local/bin/guild-runner \
  && test -x /usr/local/bin/guild-init && test -x /usr/local/bin/guild-clone-all' \
  && pass "the image has forge, guild-hook, guild-runner and the shell helpers" || fail "the image lacks a tool"
s="$(agent jq -r '[.hooks[][].hooks[].command] | join(" ")' /etc/claude-code/managed-settings.json 2>&1 || true)"
has "$s" "/usr/local/bin/guild-hook pre-tool" && pass "the managed settings call the hook" || fail "the managed settings: $s"
s="$(agent jq -r '.permissions.allow | join(" ")' /etc/claude-code/managed-settings.json 2>&1 || true)"
has "$s" "mcp__lean-lsp" && pass "the Lean layer allows its language server" || fail "the allowed tools: $s"
s="$(agent git config --system --get-all credential.http://forgejo:3000.helper 2>&1 || true)"
has "$s" git-credential-forgejo && pass "git uses the agent's credentials for the forge" || fail "git's helpers: $s"

echo "== The hook"
s="$(agent sh -c 'echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git push\"},\"cwd\":\"/tmp\"}" | CLAUDE_CODE_ENTRYPOINT=cli guild-hook pre-tool' 2>&1 || true)"
has "$s" '"permissionDecision":"deny"' && pass "it refuses a push in the human's session" || fail "the hook said: $s"
s="$(agent sh -c 'mkdir -p /tmp/control && touch /tmp/control/paused && echo "{}" | GUILD_RUN=1 CONTROL_DIR=/tmp/control guild-hook pre-tool' 2>&1 || true)"
has "$s" '"continue":false' && pass "it stops a run while paused" || fail "the hook said: $s"

echo "== forge ci --rerun, counted from the forge"
dc run --rm -T tools api POST /repos/testorg/testbed-base/contents "$(jq -nc \
  --arg w "$(b64 'on: [push]
jobs:
  build:
    runs-on: docker
    steps:
      - run: exit 1
')" --arg a "$(b64 'theorem one : 1 = 1
')" '{branch: "main", message: "A failing CI and an API.lock",
      files: [{operation: "create", path: ".forgejo/workflows/checks.yml", content: $w},
              {operation: "create", path: "API.lock", content: $a}]}')" </dev/null >/dev/null
# until_says SECONDS TEXT COMMAND...: until the command's output contains TEXT.
until_says() {
  local deadline=$(( $(date +%s) + $1 )) text="$2" out=""
  shift 2
  while [ "$(date +%s)" -lt "$deadline" ]; do
    out="$("$@" 2>&1 || true)"
    has "$out" "$text" && { printf '%s\n' "$out"; return 0; }
    sleep 5
  done
  printf '%s\n' "$out"
  return 1
}
s="$(until_says 600 failure agent forge ci testbed-base main)" && pass "forge ci reports the failed run: $s" \
  || fail "forge ci never reported a failure: $s"
s="$(agent forge ci testbed-base main --rerun 2>&1 || true)"
has "$s" "1 of the 1" && pass "the first re-run goes ahead: $s" || fail "the first re-run: $s"
s="$(until_says 600 "failure (" agent sh -c 'forge ci testbed-base main | grep "re-run once"')" \
  && pass "after the re-run failed too, forge ci counts it: $s" || fail "forge ci after the re-run: $s"
s="$(agent forge ci testbed-base main --rerun 2>&1 || true)"
has "$s" "the limit" && pass "a second re-run is refused: $s" || fail "a second re-run: $s"

echo "== forge version in a checkout"
s="$(agent sh -c 'cd /tmp && git clone -q http://forgejo:3000/testorg/testbed-base.git c && cd c && forge version' 2>&1 || true)"
has "$s" "v0.1.0: the first release" && pass "forge version, in a clone made with the agent's credentials: $s" \
  || fail "forge version: $s"

echo
[ "$fails" = 0 ] && echo "Stage 6: all checks passed." || { echo "Stage 6: $fails check(s) failed."; exit 1; }
