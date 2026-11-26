# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# kit new-library REPO NAME: commit a new library's seed to its repository's main, as the human,
# creating the repository if bootstrap hasn't: a Lake package for the module NAME under the
# project's namespace, with a test package, that builds and passes CI. REPO must be owned by a
# library or a site in the configuration.
#
# The seed is the export's library template with REPO and NAME filled in, and from the source
# library's main (the template's seedFrom, else the first other library with a lakefile), its
# copyright header, its shared files (CLAUDE.md, LICENSE, .gitignore, lean-toolchain) and its
# Lake manifests' format. It also has the CI workflow, the pin check and the request template, as
# setup-repo would add them, and a site's Pages workflow.
#
# Safe to re-run: a repository already seeded is left alone, and an empty one is seeded. One with
# other content is refused, so the seed never lands on real work.

# has_file REPO PATH: whether PATH is on REPO's main; its contents are in $RESP.
has_file() { [ "$(api GET "/repos/$ORG/$1/raw/$2?ref=main")" = 200 ]; }

seeded() { has_file "$1" lakefile.lean || has_file "$1" lakefile.toml; }

seed_source() {
  local r
  if [ -n "$SEED_FROM" ]; then echo "$SEED_FROM"; return; fi
  for r in $LIBRARIES; do
    [ "$r" != "$1" ] && seeded "$r" && { echo "$r"; return; }
  done
  return 0
}

cmd_new_library() {
  local repo="${1:-}" name="${2:-}" src header text path f
  [ -n "$repo" ] && [ -n "$name" ] || die "usage: new-library <repository> <Name>"
  [[ "$name" =~ ^[A-Z][A-Za-z0-9]*$ ]] || die "the name is one component of a Lean module name, such as Float"
  [[ " $LIBRARIES " == *" $repo "* ]] \
    || die "$repo isn't owned by a library or a site in the configuration; add its agent there first"
  TOKEN="$(token_of human)"

  if [ "$(api GET "/repos/$ORG/$repo")" = 200 ]; then
    if [ "$(jq -r .empty "$RESP")" != true ]; then
      seeded "$repo" && { log "$ORG/$repo is already seeded; nothing to do."; return 0; }
      die "$ORG/$repo already has content but no lakefile on main; not seeding over it"
    fi
  else
    call 201 POST "/orgs/$ORG/repos" "$(jq -nc --arg n "$repo" '{name: $n, private: true, default_branch: "main"}')" >/dev/null
    changed "created $ORG/$repo"
  fi

  src="$(seed_source "$repo")"
  [ -n "$src" ] || die "no library to take the shared files from: seed one by hand, or name it as the template's seedFrom"
  has_file "$src" lean-toolchain || die "$src has no lean-toolchain on main"
  header=""
  if has_file "$src" lakefile.lean; then
    header="$(awk 'NR == 1 && !/^\/-/ { exit } { print } /^-\/$/ { exit }' "$RESP")"
  fi

  declare -A files
  while IFS= read -r f; do
    path="${f#/etc/kit/templates/library/}"
    path="${path//NAME/$name}"
    text="$(cat "$f")"
    if [ -z "$header" ]; then
      case "$text" in "{{HEADER}}"*) text="${text#"{{HEADER}}"}"; text="${text#$'\n'}"; text="${text#$'\n'}" ;; esac
    fi
    text="${text//\{\{HEADER\}\}/$header}"
    text="${text//\{\{REPO\}\}/$repo}"
    files["$path"]="${text//\{\{NAME\}\}/$name}"
  done < <(find /etc/kit/templates/library -type f | sort)
  # CI from the first commit, as setup-repo would add it: a branch started before its pull
  # request merges still has a workflow to run. CODEOWNERS depends on the level, so setup-repo
  # adds it.
  for f in .forgejo/workflows/checks.yml scripts/check-pins.sh .forgejo/issue_template/request.md; do
    files["$f"]="$(cat "/etc/kit/templates/repo/$f")"
  done
  is_site "$repo" && files["$SITE_WORKFLOW"]="$(cat "/etc/kit/templates/site/$SITE_WORKFLOW")"
  for f in CLAUDE.md LICENSE .gitignore lean-toolchain; do
    has_file "$src" "$f" && files["$f"]="$(cat "$RESP")"
  done
  files[test/lean-toolchain]="${files[lean-toolchain]}"
  # The manifests in the source's format: nothing required at the root, and the library itself,
  # by path, in the test package.
  if has_file "$src" lake-manifest.json; then
    files[lake-manifest.json]="$(jq --arg n "«$repo»" '.packages = [] | .name = $n' "$RESP")"
  fi
  if has_file "$src" test/lake-manifest.json \
    && text="$(jq -e --arg n "«$repo»" --arg t "«$repo-test»" '
        [.packages[] | select(.type == "path" and .dir == "..")][0] as $self
        | select($self) | .packages = [$self | .name = $n] | .name = $t' "$RESP")"; then
    files[test/lake-manifest.json]="$text"
  fi

  local ops='[]'
  for path in "${!files[@]}"; do
    ops="$(jq -c --arg p "$path" --arg c "$(printf '%s\n' "${files[$path]}" | base64 -w0)" \
      '. + [{operation: "create", path: $p, content: $c}]' <<<"$ops")"
  done
  call 201 POST "/repos/$ORG/$repo/contents" "$(jq -nc --argjson f "$ops" --arg s "$src" --arg m "$name" '
    {branch: "main", new_branch: "main", files: ($f | sort_by(.path)),
     message: "Seed the library \($m) (scripts/new-library.sh, shared files from \($s))"}')" >/dev/null
  changed "$repo: committed the seed to main ($(jq length <<<"$ops") files)"
}
