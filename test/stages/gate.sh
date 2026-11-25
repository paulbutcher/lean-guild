# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# The gatekeeper's checks against Forgejo's API, mounted into the tools container by
# test/compose.test.yaml; test/stages/stage5.sh drives them. Phases print PASS, FAIL and
# INFO lines, and KEY value lines for the driver.
#
# They use testbed-base, which the plain test project starts at level 2, with a CI of a
# few seconds of shell that fails when the commit has a file named FAIL. The test plays
# the owner (base) and the reviewer (conformance) with their own accounts; the
# gatekeeper does its real work.

G_FAILS=0
g_pass() { echo "PASS: $*"; }
g_fail() { echo "FAIL: $*"; G_FAILS=$((G_FAILS + 1)); }
g_info() { echo "INFO: $*"; }
g_done() { echo "RESULT: $G_FAILS failure(s)"; [ "$G_FAILS" = 0 ]; }

G=testbed-base
g_b64() { printf '%s' "$1" | base64 -w0; }
as() { local who="$1"; shift; TOKEN="$(token_of "$who")" "$@"; }

G_WORKFLOW='# The gatekeeper test'"'"'s CI: fails when the commit has a file named FAIL.
name: checks
on:
  pull_request:
  push:
    branches: [main]
jobs:
  build:
    runs-on: docker
    env:
      TOKEN: ${{ secrets.DEPS_READ_TOKEN }}
    steps:
      - run: |
          git init -q .
          git -c "http.extraHeader=Authorization: Basic $(printf "ci-reader:%s" "$TOKEN" | base64 -w0)" \
            fetch -q --depth 1 "${FORGE_URL}/${GITHUB_REPOSITORY}.git" "$GITHUB_SHA"
          git checkout -q FETCH_HEAD
          test ! -e FAIL || { echo "FAIL is present"; exit 1; }
'

# g_pr BRANCH FILE CONTENT TITLE: the owner opens a pull request and schedules its merge,
# as an agent does; prints the number.
g_pr() {
  local branch="$1" file="$2" content="$3" title="$4" n have method=POST ok=201
  have="$(as base call 200,404 GET "/repos/$ORG/$G/contents/$file?ref=main" | jq -r 'if type == "object" then .sha // "" else "" end')"
  [ -n "$have" ] && method=PUT ok=200
  as base call "$ok" "$method" "/repos/$ORG/$G/contents/$file" "$(jq -nc --arg b "$branch" --arg c "$(g_b64 "$content")" \
    --arg m "$title" --arg s "$have" '{branch: "main", new_branch: $b, content: $c, message: $m} + (if $s == "" then {} else {sha: $s} end)')" >/dev/null
  n="$(as base call 201 POST "/repos/$ORG/$G/pulls" "$(jq -nc --arg b "$branch" --arg t "$title" \
    '{head: $b, base: "main", title: $t, body: "(no reply needed)\n\nThe kit'"'"'s gatekeeper test."}')" | jq -r .number)"
  g_schedule "$n"
  echo "$n"
}

# Schedules a merge, through Forgejo's short spells of checking mergeability.
g_schedule() {
  local i s
  for i in 1 2 3 4 5 6 7 8 9 10; do
    s="$(as base api POST "/repos/$ORG/$G/pulls/$1/merge" '{"Do":"squash","merge_when_checks_succeed":true,"delete_branch_after_merge":true}')"
    case "$s" in 2*) return 0 ;; esac
    sleep 2
  done
  echo "INFO: scheduling the merge of #$1 answered $s" >&2
}

g_head() { as human call 200 GET "/repos/$ORG/$G/pulls/$1" | jq -r .head.sha; }
g_merged() { as human call 200 GET "/repos/$ORG/$G/pulls/$1" | jq -r .merged; }
g_ci() { as human call 200 GET "/repos/$ORG/$G/actions/runs?head_sha=$1" | jq -r --arg s "$1" '[.workflow_runs[]? | select(.commit_sha == $s) | .status][0] // ""'; }
# g_approval WHO N SHA: WHO's live approval of N at SHA, as JSON, or nothing.
g_approval() {
  as human call 200 GET "/repos/$ORG/$G/pulls/$2/reviews" | jq -c --arg w "$1" --arg s "$3" \
    '[.[] | select(.user.login == $w and .state == "APPROVED" and .commit_id == $s and (.dismissed | not) and (.stale | not))][0] // empty'
}
# g_wait SECONDS COMMAND...: until COMMAND prints something; prints it.
g_wait() {
  local deadline=$(( $(date +%s) + $1 )) out
  shift
  while [ "$(date +%s)" -lt "$deadline" ]; do
    out="$("$@" 2>/dev/null || true)"
    [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
    sleep 5
  done
  return 1
}
g_ci_done() { case "$(g_ci "$1")" in success|failure) g_ci "$1" ;; esac; }
g_is_merged() { [ "$(g_merged "$1")" = true ] && echo merged; }
g_dismissed() { [ -z "$(g_approval "$@")" ] && echo dismissed; }
g_conformance_approves() {
  as conformance call 200 POST "/repos/$ORG/$G/pulls/$1/reviews" "$(jq -nc --arg s "$(g_head "$1")" \
    '{event: "APPROVED", body: "(no reply needed)\n\nThe gatekeeper test: nothing to find.", commit_id: $s}')" >/dev/null
}

# --- testbed-base, with a quick CI, before its setup for level 2 -------------------
g_start() {
  TOKEN="$(token_of human)"
  local ops
  ops="$(jq -nc --arg w "$(g_b64 "$G_WORKFLOW")" --arg a "$(g_b64 'theorem one : 1 = 1
')" '[{operation: "create", path: ".forgejo/workflows/checks.yml", content: $w},
      {operation: "create", path: "API.lock", content: $a}]')"
  call 201 POST "/repos/$ORG/$G/contents" "$(jq -nc --argjson f "$ops" '{branch: "main", files: $f, message: "A quick CI and an API.lock"}')" >/dev/null \
    && g_info "pushed a quick CI and an API.lock to $G's main" || g_fail "couldn't push to $G's main"
  g_done
}

# The human merges the setup's pull request, as an admin may without an approval.
g_merge_setup() {
  TOKEN="$(token_of human)"
  local n
  n="$(call 200 GET "/repos/$ORG/$G/pulls?state=open&limit=50" | jq -r '[.[] | select(.head.ref | startswith("kit/setup-level-2"))][0].number // empty')"
  [ -n "$n" ] || { g_fail "setup opened no pull request for level 2"; g_done; return; }
  local i s
  # Forgejo answers "try again later" while it checks that a new pull request merges cleanly.
  for i in 1 2 3 4 5 6 7 8 9 10; do
    s="$(api POST "/repos/$ORG/$G/pulls/$n/merge" '{"Do":"squash","force_merge":true,"delete_branch_after_merge":true}')"
    [ "$s" = 200 ] && break
    sleep 3
  done
  [ "$s" = 200 ] && g_pass "the human merged the setup's pull request (#$n)" \
    || g_fail "couldn't merge the setup's pull request ($s): $(head -c 200 "$RESP")"
  call 200 GET "/repos/$ORG/$G/branch_protections/main" \
    | jq -e --arg h "$HUMAN_USER" '(.approvals_whitelist_username | sort) == (["gatekeeper", "conformance", $h] | sort)
             and .block_on_official_review_requests and .dismiss_stale_approvals' >/dev/null \
    && g_pass "$G is protected as at level 2: approvals from $HUMAN_USER, gatekeeper and conformance" \
    || g_fail "$G's protection isn't level 2's"
  g_done
}

# g_human_change FILE CONTENT MESSAGE: the human changes a file on main as main's protection
# lets an admin: through a pull request they merge without an approval.
g_human_change() {
  local file="$1" content="$2" message="$3" branch have n i s
  TOKEN="$(token_of human)"
  branch="human/$(date +%s%N)"
  have="$(call 200,404 GET "/repos/$ORG/$G/contents/$file?ref=main" | jq -r 'if type == "object" then .sha // "" else "" end')"
  if [ -n "$have" ]; then
    call 200 PUT "/repos/$ORG/$G/contents/$file" "$(jq -nc --arg b "$branch" --arg c "$(g_b64 "$content")" \
      --arg m "$message" --arg s "$have" '{branch: "main", new_branch: $b, content: $c, message: $m, sha: $s}')" >/dev/null || return 1
  else
    call 201 POST "/repos/$ORG/$G/contents/$file" "$(jq -nc --arg b "$branch" --arg c "$(g_b64 "$content")" \
      --arg m "$message" '{branch: "main", new_branch: $b, content: $c, message: $m}')" >/dev/null || return 1
  fi
  n="$(call 201 POST "/repos/$ORG/$G/pulls" "$(jq -nc --arg b "$branch" --arg t "$message" \
    '{head: $b, base: "main", title: $t, body: "(no reply needed)"}')" | jq -r .number)" || return 1
  # Forgejo answers "try again later" while it checks that a new pull request merges cleanly.
  for i in 1 2 3 4 5 6 7 8 9 10; do
    s="$(api POST "/repos/$ORG/$G/pulls/$n/merge" '{"Do":"squash","force_merge":true,"delete_branch_after_merge":true}')"
    [ "$s" = 200 ] && return 0
    sleep 3
  done
  return 1
}

# The setup brings the kit's Lean CI, which this repository has no Lean for: the human puts
# the quick CI back.
g_quick_ci() {
  g_human_change .forgejo/workflows/checks.yml "$G_WORKFLOW" "The quick CI again" \
    && g_info "the quick CI is back on main" || g_fail "couldn't put the quick CI back"
  g_done
}

# --- an ordinary pull request merges on the gatekeeper's and conformance's approvals
g_good() {
  local n sha ci a f new
  n="$(g_pr agent/base/good docs/good.md 'An ordinary change.
' 'Gatekeeper test: an ordinary change')"
  echo "GOOD $n"
  g_info "the owner's ordinary pull request: $G#$n, its merge scheduled"
  sha="$(g_head "$n")"
  ci="$(g_wait 600 g_ci_done "$sha")" || { g_fail "no CI run finished for $sha within 10 minutes"; g_done; return; }
  [ "$ci" = success ] && g_pass "its CI run succeeded" || g_fail "its CI run: $ci"
  if a="$(g_wait 180 g_approval gatekeeper "$n" "$sha")"; then
    g_pass "the gatekeeper approved the head commit (${sha:0:12}) after its run succeeded"
    jq -e '.official and (.body | startswith("(no reply needed)"))' <<<"$a" >/dev/null \
      && g_pass "its approval is official and needs no reply" || g_fail "its approval: $(jq -c '{official, body: .body[:60]}' <<<"$a")"
  else
    g_fail "the gatekeeper didn't approve ${sha:0:12} within 3 minutes"
  fi
  sleep 20
  [ "$(g_merged "$n")" = false ] && g_pass "with the gatekeeper's approval alone, it waits for conformance" \
    || g_fail "it merged without conformance's approval"
  # A new commit dismisses the approval; the gatekeeper approves the new head.
  f="$(as base call 200 GET "/repos/$ORG/$G/contents/docs/good.md?ref=agent/base/good" | jq -r .sha)"
  as base call 200 PUT "/repos/$ORG/$G/contents/docs/good.md" "$(jq -nc --arg c "$(g_b64 'An ordinary change, revised.
')" --arg s "$f" '{branch: "agent/base/good", content: $c, sha: $s, message: "Revise it"}')" >/dev/null
  for _ in 1 2 3 4 5 6; do new="$(g_head "$n")"; [ "$new" != "$sha" ] && break; sleep 2; done
  g_wait 60 g_dismissed gatekeeper "$n" "$sha" >/dev/null && g_pass "a new commit dismissed the approval of the old head" \
    || g_fail "the approval of ${sha:0:12} still stands after a new commit"
  g_wait 600 g_ci_done "$new" >/dev/null
  g_wait 180 g_approval gatekeeper "$n" "$new" >/dev/null \
    && g_pass "the gatekeeper approved the new head (${new:0:12}) once its run succeeded" \
    || g_fail "the gatekeeper didn't approve the new head ${new:0:12}"
  g_conformance_approves "$n" && g_pass "conformance approved" || g_fail "conformance couldn't approve"
  g_wait 180 g_is_merged "$n" >/dev/null \
    && g_pass "with conformance's approval too, its scheduled merge went through" \
    || g_fail "$G#$n didn't merge within 3 minutes of conformance's approval"
  g_done
}

# --- a status posted under CI's name doesn't get a failing build approved -------------
g_spoof() {
  local n sha ci ctx s
  n="$(g_pr agent/base/spoof FAIL 'This file makes CI fail.
' 'Gatekeeper test: a failing build')"
  g_info "the owner's pull request with a failing build: $G#$n, its merge scheduled"
  sha="$(g_head "$n")"
  ci="$(g_wait 600 g_ci_done "$sha")" || { g_fail "no CI run finished for $sha"; g_done; return; }
  [ "$ci" = failure ] && g_pass "its CI run failed" || g_fail "its CI run: $ci"
  ctx="$(as human call 200 GET "/repos/$ORG/$G/commits/$sha/statuses" | jq -r '[.[].context][0] // "checks / build (pull_request)"')"
  as base call 201 POST "/repos/$ORG/$G/statuses/$sha" "$(jq -nc --arg c "$ctx" \
    '{state: "success", context: $c, description: "Successful (posted by the owner, not CI)"}')" >/dev/null
  s="$(as human call 200 GET "/repos/$ORG/$G/commits/$sha/status" | jq -r .state)"
  g_info "the owner posted \"$ctx\" as success; the commit's combined status is now $s"
  g_conformance_approves "$n"
  sleep 75  # two of the gatekeeper's sweeps
  [ -z "$(g_approval gatekeeper "$n" "$sha")" ] && g_pass "the gatekeeper didn't approve it" \
    || g_fail "the gatekeeper approved a failing build"
  [ "$(g_merged "$n")" = false ] && g_pass "it didn't merge" || g_fail "a failing build merged"
  s="$(as base api POST "/repos/$ORG/$G/pulls/$n/merge" '{"Do":"squash"}')"
  [ "$s" != 200 ] && g_pass "the owner can't merge it either ($s)" || g_fail "the owner merged a failing build"
  g_done
}

# --- an API.lock change waits for the human -----------------------------------------
g_apilock() {
  local n sha s
  n="$(g_pr agent/base/api API.lock 'theorem one : 1 = 1
theorem two : 2 = 2
' 'Gatekeeper test: an API change')"
  g_info "the owner's pull request changing API.lock: $G#$n, its merge scheduled"
  sleep 3
  as human call 200 GET "/repos/$ORG/$G/pulls/$n" | jq -e --arg h "$HUMAN_USER" '[.requested_reviewers[]?.login] | index($h)' >/dev/null \
    && g_pass "$HUMAN_USER's review is requested" || g_fail "$HUMAN_USER's review isn't requested"
  sha="$(g_head "$n")"
  g_wait 600 g_ci_done "$sha" >/dev/null
  g_wait 180 g_approval gatekeeper "$n" "$sha" >/dev/null \
    && g_pass "the gatekeeper approved it" || g_fail "the gatekeeper didn't approve it"
  g_conformance_approves "$n" && g_pass "conformance approved it" || g_fail "conformance couldn't approve it"
  sleep 60
  [ "$(g_merged "$n")" = false ] && g_pass "with the gatekeeper's and conformance's approvals, it still waits for $HUMAN_USER" \
    || { g_fail "an API.lock change merged without $HUMAN_USER"; g_done; return; }
  s="$(as base api POST "/repos/$ORG/$G/pulls/$n/merge" '{"Do":"squash"}')"
  [ "$s" != 200 ] && g_pass "the owner can't merge it ($s)" || g_fail "the owner merged it without $HUMAN_USER"
  as human call 200 POST "/repos/$ORG/$G/pulls/$n/reviews" \
    '{"event":"APPROVED","body":"(no reply needed)\n\nApproved (gatekeeper test)."}' >/dev/null
  g_wait 180 g_is_merged "$n" >/dev/null \
    && g_pass "once $HUMAN_USER approved, its scheduled merge went through" \
    || g_fail "it didn't merge within 3 minutes of $HUMAN_USER's approval"
  g_done
}

# --- while paused, the gatekeeper approves nothing ------------------------------------
g_paused_pr() {
  local n sha
  as base call 201 POST "/repos/$ORG/$G/contents/docs/paused.md" "$(jq -nc --arg c "$(g_b64 'While paused.
')" '{branch: "main", new_branch: "agent/base/paused", content: $c, message: "While paused"}')" >/dev/null
  n="$(as base call 201 POST "/repos/$ORG/$G/pulls" '{"head":"agent/base/paused","base":"main","title":"Gatekeeper test: while paused","body":"(no reply needed)"}' | jq -r .number)"
  echo "PAUSED $n"
  sha="$(g_head "$n")"
  [ "$(g_wait 600 g_ci_done "$sha")" = success ] || { g_fail "its CI run didn't succeed, so the pause proves nothing"; g_done; return; }
  sleep 75
  [ -z "$(g_approval gatekeeper "$n" "$sha")" ] && g_pass "while paused, the gatekeeper didn't approve $G#$n, whose run succeeded" \
    || g_fail "the gatekeeper approved while paused"
  g_done
}

g_resumed() {
  local n="$1"
  g_wait 180 g_approval gatekeeper "$n" "$(g_head "$n")" >/dev/null \
    && g_pass "after resuming, it approved $G#$n" || g_fail "after resuming, it didn't approve $G#$n within 3 minutes"
  g_done
}

# --- the human's release, which needs a CHANGELOG entry and CI on main's head ------------
g_changelog() {
  g_human_change CHANGELOG.md '# Changelog

## v0.1.0

- The first release.
' "Changelog for v0.1.0" || { g_fail "couldn't write CHANGELOG.md on main"; g_done; return; }
  local sha
  sha="$(as human call 200 GET "/repos/$ORG/$G/branches/main" | jq -r .commit.id)"
  [ "$(g_wait 600 g_ci_done "$sha")" = success ] || g_fail "CI on main's head didn't succeed"
  g_info "main is at ${sha:0:12}, with a CHANGELOG entry for v0.1.0"
  g_done
}

g_released() {
  TOKEN="$(token_of human)"
  [ "$(api GET "/repos/$ORG/$G/releases/tags/v0.1.0")" = 200 ] \
    && g_pass "the release v0.1.0 exists" || g_fail "there is no release v0.1.0"
  [ "$(api GET "/repos/$ORG/$G/tags/v0.1.0")" = 200 ] \
    && g_pass "main's head is tagged v0.1.0" || g_fail "there is no tag v0.1.0"
  g_done
}

cmd_test_gate() {
  local phase="${1:-}"
  shift || true
  case "$phase" in
    start) g_start ;;
    merge-setup) g_merge_setup ;;
    quick-ci) g_quick_ci ;;
    good) g_good ;;
    spoof) g_spoof ;;
    apilock) g_apilock ;;
    paused-pr) g_paused_pr ;;
    resumed) g_resumed "$@" ;;
    changelog) g_changelog ;;
    released) g_released ;;
    *) die "usage: test-gate start|merge-setup|quick-ci|good|spoof|apilock|paused-pr|resumed N|changelog|released" ;;
  esac
}
