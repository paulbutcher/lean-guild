# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# kit milestone NAME: open the issue on the coordination repository that ends a milestone. It
# records each library's main, carries every API.lock change since the last milestone issue, and
# is labelled milestone-review, which wakes the milestone reviewers.
# kit milestone-diff: just the API.lock changes since the last milestone.

# The refs the last milestone issue recorded, as JSON {repo: sha}, or {}.
last_milestone_refs() {
  call 200 GET "/repos/$ORG/$COORDINATION/issues?state=all&type=issues&labels=milestone&limit=50" \
    | jq -r '[.[] | .body | capture("<!-- milestone-refs: (?<r>\\{.*?\\}) -->").r][0] // "{}"'
}

# Every repository but the coordination one that has a main branch.
library_repos() {
  local r
  for r in $(all_repos); do
    [ "$r" != "$COORDINATION" ] && [ "$(api GET "/repos/$ORG/$r/branches/main")" = 200 ] && echo "$r"
  done
  return 0
}

# api_lock REPO REF: API.lock's text at REF, or nothing.
api_lock() {
  [ -n "$2" ] || return 0
  [ "$(api GET "/repos/$ORG/$1/raw/API.lock?ref=$2")" = 200 ] || return 0
  cat "$RESP"
}

# Prints the diff in Markdown, and leaves the current refs in MILESTONE_REFS.
milestone_diff() {
  local prev r old new d was is
  prev="$(last_milestone_refs)"
  MILESTONE_REFS='{}'
  was="$(mktemp)" is="$(mktemp)"
  for r in $(library_repos); do
    new="$(call 200 GET "/repos/$ORG/$r/branches/main" | jq -r .commit.id)"
    MILESTONE_REFS="$(jq -c --arg r "$r" --arg s "$new" '. + {($r): $s}' <<<"$MILESTONE_REFS")"
    old="$(jq -r --arg r "$r" '.[$r] // ""' <<<"$prev")"
    # One after the other: both fetches use $RESP.
    api_lock "$r" "$old" > "$was"
    api_lock "$r" "$new" > "$is"
    d="$(diff -u --label "API.lock at ${old:0:12}" --label "API.lock at ${new:0:12}" "$was" "$is" || true)"
    echo "### $r"
    echo
    if [ -z "$old" ]; then
      echo "No earlier milestone recorded $r; this is all of \`API.lock\` at \`${new:0:12}\`."
      echo
    fi
    if [ -z "$d" ]; then
      echo "No change to \`API.lock\` since \`${old:0:12}\`."
    else
      echo '```diff'
      printf '%s\n' "$d"
      echo '```'
    fi
    echo
  done
}

cmd_milestone_diff() {
  TOKEN="$(token_of human)"
  milestone_diff
}

# label_ids REPO NAME,...: the labels' ids, as a JSON array.
label_ids() {
  call 200 GET "/repos/$ORG/$1/labels?limit=100" | jq -c --arg n "$2" '[.[] | select(.name as $x | $n | split(",") | index($x)) | .id]'
}

cmd_milestone() {
  local name="${1:-}" reviewers body url
  [ -n "$name" ] || die "usage: milestone <name>"
  [ -n "$MILESTONE_REVIEWERS" ] || die "the configuration has no milestone reviewer to wake"
  TOKEN="$(token_of human)"
  milestone_diff > "$REQ.diff"
  reviewers="$(sed 's/\([^ ]*\)/@\1/g; s/ /, /g' <<<"$MILESTONE_REVIEWERS")"
  body="$(cat <<BODY
(no reply needed)

The end of milestone **$name**. The milestone reviewers ($reviewers) report here, each with its recommendations as issues labelled \`recommendation\`. The milestone is accepted once you've decided on them.

## Every API.lock change since the last milestone

$(cat "$REQ.diff")

<!-- milestone-refs: $MILESTONE_REFS -->
BODY
)"
  url="$(call 201 POST "/repos/$ORG/$COORDINATION/issues" "$(printf '%s' "$body" | jq -Rsc --arg t "Milestone: $name" \
    --argjson l "$(label_ids "$COORDINATION" milestone,milestone-review)" '{title: $t, body: ., labels: $l}')" | jq -r .html_url)"
  log "Opened $url; the reviews start shortly."
}
