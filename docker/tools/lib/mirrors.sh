# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# Push mirrors to GitHub, for a project whose configuration has them: every repository
# gets one to its namesake under the configured owner, at MIRROR_BASE (GitHub, or a test
# deployment's own forge), with a token of the human's own from secrets/github. A
# deployment with MIRRORS=off creates, changes and syncs none.

GITHUB_MIRROR_TOKEN=/secrets/github/mirror-token

mirrors_off() { [ "${MIRRORS:-on}" = off ]; }

# ensure_mirrors [--rotate]: every repository's push mirror, with the configured branch
# filter and every tag; --rotate replaces each mirror's token with the current one.
ensure_mirrors() {
  local rotate="${1:-}" pw r url existing name
  [ -n "$MIRROR_OWNER" ] || return 0
  if mirrors_off; then
    log "Mirrors are off in this deployment: no push mirror is created, changed or synced."
    return 0
  fi
  [ -s "$GITHUB_MIRROR_TOKEN" ] \
    || die "the configuration mirrors to $MIRROR_OWNER, but secrets/github/mirror-token is missing: put a token with Contents read and write on the repositories there, or set MIRRORS=off for a deployment that mustn't mirror"
  pw="$(tr -d '[:space:]' < "$GITHUB_MIRROR_TOKEN")"
  for r in $(all_repos); do
    [ "$(api GET "/repos/$ORG/$r")" = 200 ] || { log "$ORG/$r isn't in Forgejo; skipping its mirror."; continue; }
    url="$MIRROR_BASE/$MIRROR_OWNER/$r.git"
    existing="$(call 200 GET "/repos/$ORG/$r/push_mirrors" \
      | jq -c --arg u "$url" '[.[] | select(.remote_address == $u)][0] // empty')"
    if [ -n "$existing" ]; then
      name="$(jq -r .remote_name <<<"$existing")"
      if [ "$rotate" != --rotate ] && [ "$(jq -r '.branch_filter // ""' <<<"$existing")" = "$MIRROR_BRANCHES" ]; then
        continue
      fi
      call 204 DELETE "/repos/$ORG/$r/push_mirrors/$name" >/dev/null
    fi
    call 200,201 POST "/repos/$ORG/$r/push_mirrors" "$(jq -nc --arg u "$url" --arg h "$HUMAN_USER" \
      --arg p "$pw" --arg b "$MIRROR_BRANCHES" '{
        remote_address: $u, remote_username: $h, remote_password: $p,
        sync_on_commit: true, interval: "24h", branch_filter: $b, use_ssh: false}')" >/dev/null
    changed "push mirror $ORG/$r -> $url (branches: $MIRROR_BRANCHES; tags: all)"
  done
}

cmd_mirrors() {
  TOKEN="$(token_of human)"
  ensure_mirrors "${1:-}"
  log "Made $CHANGES change(s) to mirrors."
}

# kit mirror-status: each repository's push mirrors, with their last sync and error.
cmd_mirror_status() {
  TOKEN="$(token_of human)"
  [ -n "$MIRROR_OWNER" ] || { echo "The configuration has no mirrors."; return 0; }
  mirrors_off && echo "Mirrors are off in this deployment."
  local r
  for r in $(all_repos); do
    [ "$(api GET "/repos/$ORG/$r")" = 200 ] || continue
    call 200 GET "/repos/$ORG/$r/push_mirrors" \
      | jq -r --arg r "$r" '.[] | "\($r)\t\(.remote_address)\tbranches=\(.branch_filter // "")\tlast=\(.last_update)\terror=\(.last_error // "")"'
  done
}
