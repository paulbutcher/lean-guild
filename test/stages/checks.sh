# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# The stage tests' checks against Forgejo's API, mounted into the tools container by
# test/compose.test.yaml. test/stages/stage3.sh runs them and adds the network checks.

FAILS=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
info() { echo "INFO: $*"; }

PROBE=stage-probe

# The Actions run for a commit in REPO: prints its status once finished.
run_for() {
  call 200 GET "/repos/$ORG/$1/actions/runs?limit=50" \
    | jq -r --arg sha "$2" '(.workflow_runs // .)[]? | select((.commit_sha // .head_sha) == $sha) | .status' | head -1
}

wait_run() {
  local repo="$1" sha="$2" deadline=$(( $(date +%s) + ${3:-2400} )) s
  while [ "$(date +%s)" -lt "$deadline" ]; do
    s="$(run_for "$repo" "$sha")"
    case "$s" in
      success|failure|cancelled|skipped|blocked) echo "$s"; return ;;
    esac
    sleep 10
  done
  echo timeout
}

# push_fixture REPO: the fixture and the kit's repository templates, as main's first
# commit, by the human. Prints the working copy.
push_fixture() {
  local repo="$1" work
  work="$(mktemp -d)"
  cp -r /etc/kit/templates/repo/. "${work:?}/"
  for f in "/etc/kit-fixtures/$repo"/*; do
    case "$f" in *.broken.lean) ;; *) cp "$f" "${work:?}/" ;; esac
  done
  (
    cd "$work"
    git init -q -b main && git add -A
    git_as commit -qm "$repo fixture"
    git_as push -q "$FORGE_URL/$ORG/$repo.git" main
  ) >&2 || return 1
  echo "$work"
}

cmd_test_stage1() {
  TOKEN="$(token_of human)"
  local base_work app_work sha_base sha_app sha_bad s pr t0 t1

  s="$(curl -sS -o "$RESP" -w '%{http_code}' "$FORGE_URL/user/sign_up")"
  if [ "$s" = 404 ] || [ "$s" = 403 ] || grep -qi 'registration is disabled' "$RESP"; then
    pass "registration is disabled ($s)"
  else
    fail "registration page answered $s"
  fi

  # The base library, released as v0.1.0.
  base_work="$(push_fixture testbed-base)" || { fail "couldn't push testbed-base"; return 1; }
  sha_base="$(git -C "$base_work" rev-parse HEAD)"
  (cd "$base_work" && git tag v0.1.0 && git_as push -q "$FORGE_URL/$ORG/testbed-base.git" v0.1.0) \
    || fail "the human couldn't push a release tag"
  info "waiting for CI on testbed-base's main; the first run downloads a Lean toolchain"
  t0="$(date +%s)"
  s="$(wait_run testbed-base "$sha_base")"
  t1="$(date +%s)"
  [ "$s" = success ] && pass "CI built testbed-base in $((t1 - t0))s" || fail "CI on testbed-base's main ended: $s"

  # The app, which names the base library by its former owner's GitHub URL.
  app_work="$(push_fixture testbed-app)" || { fail "couldn't push testbed-app"; return 1; }
  sha_app="$(git -C "$app_work" rev-parse HEAD)"
  s="$(wait_run testbed-app "$sha_app")"
  [ "$s" = success ] && pass "CI fetched a dependency named by GitHub URL from Forgejo" \
                     || fail "CI on testbed-app's main ended: $s"

  # A pull request with a sorry must fail.
  (
    cd "$base_work"
    git checkout -q -b broken
    cp /etc/kit-fixtures/testbed-base/TestbedBase.broken.lean TestbedBase.lean
    git_as commit -qam "Use sorry"
    git_as push -q "$FORGE_URL/$ORG/testbed-base.git" broken
  )
  sha_bad="$(git -C "$base_work" rev-parse HEAD)"
  pr="$(call 201 POST "/repos/$ORG/testbed-base/pulls" '{"head":"broken","base":"main","title":"Use sorry"}' | jq -r .number)"
  s="$(wait_run testbed-base "$sha_bad")"
  [ "$s" = failure ] && pass "CI failed the pull request with a sorry (#$pr)" || fail "CI on the sorry pull request ended: $s"

  # The owner agent's permissions on its own repository.
  s="$(TOKEN="$(token_of base)" api POST "/repos/$ORG/testbed-base/releases" '{"tag_name":"v9.9.9","target_commitish":"main","name":"v9.9.9"}')"
  [ "$s" = 403 ] && pass "an owner can't create a release (403)" || fail "an owner creating a release got $s: $(head -c 300 "$RESP")"
  if (cd "$base_work" && TOKEN="$(token_of base)" git_as push -q "$FORGE_URL/$ORG/testbed-base.git" "HEAD:refs/heads/agent/base/probe" 2>/dev/null); then
    pass "an owner can push a branch"
  else
    fail "an owner can't push a branch"
  fi
  if (cd "$base_work" && git tag v9.9.9 && TOKEN="$(token_of base)" git_as push -q "$FORGE_URL/$ORG/testbed-base.git" v9.9.9 2>/dev/null); then
    fail "an owner pushed a tag"
  else
    pass "an owner can't push a tag"
  fi
  local bad_run
  bad_run="$(call 200 GET "/repos/$ORG/testbed-base/actions/runs?limit=50" \
    | jq -r --arg s "$sha_bad" '[(.workflow_runs // .)[] | select((.commit_sha // .head_sha) == $s)] | max_by(.id) | .id')"
  s="$(TOKEN="$(token_of base)" api POST "/repos/$ORG/testbed-base/actions/runs/$bad_run/rerun")"
  [ "${s:0:1}" = 2 ] && pass "an owner can re-run a failed CI run in its own repository ($s)" \
    || fail "an owner re-running run $bad_run got $s: $(head -c 300 "$RESP")"
  s="$(TOKEN="$(token_of base)" api PUT "/repos/$ORG/testbed-base/actions/secrets/KIT_PROBE" '{"data":"x"}')"
  [ "$s" = 403 ] || [ "$s" = 404 ] && pass "an owner can't write an Actions secret ($s)" || fail "an owner writing an Actions secret got $s"
  s="$(TOKEN="$(token_of base)" api POST "/repos/$ORG/testbed-base/actions/variables/KIT_PROBE" '{"value":"x"}')"
  [ "$s" = 403 ] || [ "$s" = 404 ] && pass "an owner can't write an Actions variable ($s)" || fail "an owner writing an Actions variable got $s"
  s="$(TOKEN="$(token_of base)" api GET "/repos/$ORG/testbed-base/actions/runners/registration-token")"
  [ "$s" = 403 ] || [ "$s" = 404 ] && pass "an owner can't get a runner registration token ($s)" \
    || fail "an owner getting a runner registration token got $s"

  # Tag protection also covers a release that creates its tag. The probe account may
  # write releases; only tag protection stands in its way.
  call 201 POST /admin/users "$(jq -nc --arg u "$PROBE" --arg p "$(random_hex 24)" \
    '{username: $u, email: "\($u)@noreply.localhost", password: $p, must_change_password: false}')" >/dev/null
  local probe_team probe_pw probe_tok tp
  probe_team="$(call 201 POST "/orgs/$ORG/teams" "$(jq -nc --arg n "$PROBE" \
    '{name: $n, permission: "write", includes_all_repositories: false,
      units_map: {"repo.code": "write", "repo.releases": "write"}}')" | jq -r .id)"
  call 204 PUT "/teams/$probe_team/members/$PROBE" >/dev/null
  call 204 PUT "/teams/$probe_team/repos/$ORG/testbed-app" >/dev/null
  probe_pw="$(random_hex 24)"
  call 200 PATCH "/admin/users/$PROBE" "$(jq -nc --arg u "$PROBE" --arg p "$probe_pw" '{login_name: $u, source_id: 0, password: $p}')" >/dev/null
  probe_tok="$(BASIC="$PROBE:$probe_pw" call 201 POST "/users/$PROBE/tokens" '{"name":"probe","scopes":["write:repository"]}' | jq -r .sha1)"
  s="$(TOKEN="$probe_tok" api POST "/repos/$ORG/testbed-app/releases" '{"tag_name":"v9.9.8","target_commitish":"main","name":"v9.9.8"}')"
  if [ "$s" = 201 ]; then fail "a release created a protected tag"; else pass "tag protection refused a release creating its tag ($s)"; fi
  tp="$(call 200 GET "/repos/$ORG/testbed-app/tag_protections" | jq -r '.[0].id')"
  call 204 DELETE "/repos/$ORG/testbed-app/tag_protections/$tp" >/dev/null
  s="$(TOKEN="$probe_tok" api POST "/repos/$ORG/testbed-app/releases" '{"tag_name":"v9.9.7","target_commitish":"main","name":"v9.9.7"}')"
  [ "$s" = 201 ] && pass "control: without tag protection the same release is created" || fail "control release got $s: $(head -c 300 "$RESP")"
  api DELETE "/teams/$probe_team" >/dev/null
  api DELETE "/admin/users/$PROBE?purge=true" >/dev/null

  # The push mirror carries main and the release tag to the second organisation.
  local deadline mirrored=""
  deadline=$(( $(date +%s) + 120 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ "$(api GET "/repos/$MIRROR_OWNER/testbed-base/branches/main")" = 200 ] \
       && [ "$(jq -r .commit.id "$RESP")" = "$sha_base" ] \
       && [ "$(api GET "/repos/$MIRROR_OWNER/testbed-base/tags/v0.1.0")" = 200 ]; then
      mirrored=1; break
    fi
    sleep 5
  done
  [ -n "$mirrored" ] && pass "the push mirror carried main and the release tag to $MIRROR_OWNER/testbed-base" \
                     || fail "nothing reached the mirror $MIRROR_OWNER/testbed-base"

  echo "RESULT: $FAILS failure(s)"
  [ "$FAILS" = 0 ]
}

# With mirrors off, no repository has a push mirror.
cmd_test_mirrors_off() {
  TOKEN="$(token_of human)"
  local r n total=0
  for r in $(all_repos); do
    n="$(call 200 GET "/repos/$ORG/$r/push_mirrors" | jq length)"
    total=$((total + n))
  done
  [ "$total" = 0 ] && pass "with mirrors off, bootstrap created no push mirror" || fail "with mirrors off, $total push mirror(s) exist"
  [ "$FAILS" = 0 ]
}
