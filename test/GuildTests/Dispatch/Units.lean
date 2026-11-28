/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import GuildTests.Dispatch.Harness

/-! Pull requests, releases, milestones and the kit: the reference's tests, ported. -/

namespace GuildTests.Dispatch.Units

open Guild Guild.Forge Guild.Dispatcher GuildTests.Dispatch Json

def sha (c : Char) : String := String.ofList (List.replicate 40 c)

/-- A pull request on core that is scheduled, approved by conformance and passing, unless said. -/
def pr (t : T) (n : Nat) (sha := defaultSha) (ci := Ci.success) (events : Option (List Ev) := none)
    (reviews : Option (List Review) := none) (mergeable : Option Bool := some true) (title := "Work")
    (labels : List String := []) : IO (Option (String × List String)) := do
  let events ← match events with | some e => pure e | none => pure [← t.event .scheduleMerge "core" 3000]
  let reviews ← match reviews with | some r => pure r | none => pure [← t.review "conformance" .approve 100 (commit := sha)]
  t.pull core n "core" labels (sha := sha) (events := events) (reviews := reviews) (mergeable := mergeable)
    (title := title) (ci := ci)
  t.evaluate core n
  t.state s!"{core}#{n}"

def pulls : List (String × (T → Check)) := [
  ("what its author must fix", fun t => do
    same (← pr t 1 (ci := .failure)) (some ("CI failing", ["core"]))
    same (← pr t 2 (sha := sha 'b') (mergeable := some false)) (some ("conflicting", ["core"]))
    same (← pr t 3 (sha := sha 'c') (title := "WIP: later")) (some ("in draft", ["core"]))
    same (← pr t 4 (sha := sha 'd') (reviews := some [← t.review "conformance" .requestChanges 100 (commit := sha 'd')]))
      (some ("changes requested", ["core"]))),
  ("CI running is a timer until it is late", fun t => do
    t.status core defaultSha .pending 600
    same ((← pr t 7 (ci := .none_)).map (·.1)) (some "CI running")
    t.status core (sha 'b') .pending 4000
    same (← pr t 8 (sha := sha 'b') (ci := .none_) (events := some [← t.event .push "core" 4000, ← t.event .scheduleMerge "core" 4000]))
      (some ("CI stuck", ["core"]))),
  ("25: no CI run for its head", fun t => do
    same ((← pr t 4 (ci := .none_) (events := some [← t.event .push "core" 3000])).map (·.1)) (some "no CI")
    same ((← pr t 5 (sha := sha 'b') (ci := .none_) (events := some [← t.event .push "core" 60])).map (·.1)) (some "CI running")
      "pushed a minute ago: CI may yet start"
    ensure (has ((← t.descriptions "core").headD "") "Merge main into it and push") "the step"),
  ("19: conformance reviews a passing head once it has settled", fun t => do
    same (← pr t 7 (reviews := some [])) (some ("in review", ["conformance"]))
    let run ← t.running "core"
    same (← pr t 8 (sha := sha 'b') (reviews := some []) (events := some [← t.event .push "core" 30])) (some ("settling", ["timer"]))
    -- Its author's run ends: the head has settled.
    discard <| t.io (endRun "core" run (Json.mkObj [("outcome", toJson "completed")]))
    t.io (evaluateAfterRun "core")
    same (← t.state s!"{core}#8") (some ("in review", ["conformance"]))),
  ("14: the coordinator's review once CI passed", fun t => do
    t.file scale ".forgejo/CODEOWNERS" ".* @gatekeeper @conformance\nAPI\\.lock @coordinator\n"
    for (repo, owner) in [(scale, "scale"), (core, "core")] do  -- core has no CODEOWNERS on main
      t.pull repo 9 owner (requested := ["coordinator"]) (ci := .success) (events := [← t.event .scheduleMerge owner 50])
        (reviews := [← t.review "conformance" .approve 100])
      t.evaluate repo 9
    same (← t.state s!"{scale}#9") (some ("in review", ["coordinator"]))
    let ds := (← t.descriptions "coordinator").filter (has · "in review")
    let level3 := (ds.find? (has · scale)).getD ""
    let below := (ds.find? (has · core)).getD ""
    ensure (has level3 s!"{scale} is at level 3: CODEOWNERS on main gives `API.lock` to you") level3
    ensure (has level3 "a comment alone leaves it waiting") level3
    ensure (has below s!"{core} is below level 3, so the human approves its `API.lock`") below),
  ("14: after a push dismissed its approval", fun t => do
    t.pull scale 8 "scale" (sha := sha 'b') (ci := .success) (events :=
      [← t.event .push "scale" 3000, ← t.event (.reviewRequest "coordinator" false) "scale" 3000, ← t.event .push "scale" 1000])
      (reviews := [← t.review "coordinator" .approve 2000 (dismissed := true)])
    t.evaluate scale 8
    ensure (((← t.state s!"{scale}#8").map (·.2)).getD [] |>.contains "coordinator") "the coordinator is asked again"),
  ("20: the author replied to its request for changes", fun t => do
    same (← pr t 7 (reviews := some [← t.review "conformance" .requestChanges 100])
      (events := some [← t.comment "core" 50 "I keep it because ..."])) (some ("author replied", ["conformance"]))),
  ("20: not while the pull request is blocked", fun t => do
    t.issue core 37 "core"
    same (← pr t 35 (labels := ["blocked"]) (reviews := some [← t.review "conformance" .requestChanges 100])
      (events := some [← t.comment "core" 50 s!"#37 replaces the gate; I'll merge main in once it lands.\n\n{line core 37}"]))
      (some ("blocked", ["unit:blockers"]))),
  ("5: its merge to schedule once nothing else stands in its way", fun t => do
    same (← pr t 7 (events := some [])) (some ("unscheduled", ["core"]))
    same (← t.descriptions "core")
      [s!"pull request {core}#7 (unscheduled): schedule its merge (`forge pr automerge`), or close it if it's no longer wanted"]
    discard <| t.running "core"
    same (← pr t 8 (sha := sha 'b') (events := some [])) (some ("unscheduled", ["core"]))
    same (← t.queued "core").length 1 "quiet: not while its owner runs"),
  ("5: a scheduled merge that never fired", fun t => do
    let approvals ← ["gatekeeper", "conformance"].mapM fun w => t.review w .approve 1600
    let everyone ← ["gatekeeper", "conformance"].mapM fun w => t.event (.reviewRequest w false) "core" 4000
    same (← pr t 7 (events := some (everyone ++ [← t.event .scheduleMerge "core" 1500])) (reviews := some approvals))
      (some ("stuck", ["core"]))
    same (← pr t 8 (events := some (everyone ++ [← t.event .scheduleMerge "core" 300])) (reviews := some approvals))
      (some ("merging", ["timer"]))),
  ("the human's part is the human's", fun t => do
    t.pull core 7 human (ci := .success) (reviews := [← t.review "conformance" .approve 100])
    t.evaluate core 7
    same (← t.state s!"{core}#7") (some ("unscheduled", ["human"]))
    same (← t.owing (some s!"{core}#7")) [])]

def mainSha := "m-head"

/-- core released v0.2.0, with an API.lock that main has added to, and CI passing on main. -/
def setUp (t : T) : IO Unit := do
  t.status core mainSha .success
  t.release core "v0.2.0" 9000
  t.file core "API.lock" "def a : Nat\n" (ref := "v0.2.0")
  t.file core "API.lock" "def a : Nat\ndef b : Nat\n"

def release (t : T) (repo := core) : IO (Option (String × List String)) := do
  t.clearCache
  t.run (evaluateRepo repo)
  t.state s!"release:{repo}"

def changelog (t : T) (text : String) (ref := "main") : IO Unit := t.file core "CHANGELOG.md" text (ref := ref)

theorem no_entry_needs_code_since_the_tag (f : Release.Facts) :
    (Release.state f).name = .noEntry → f.unreleased = true := by
  cases f with | mk ci late unreleased rfr heading held level3 decision =>
  cases ci <;> cases late <;> cases unreleased <;> cases rfr <;> cases heading <;> cases held <;>
    cases level3 <;> cases decision <;> decide

theorem code_since_the_tag_is_unreleased (since : List (List String)) (ps : List String) (p : String)
    (hp : p ∈ ps) (h : p ≠ "CHANGELOG.md") : Release.changelogOnly (since ++ [ps]) = false := by
  have : ps.all (· == "CHANGELOG.md") = false := by
    rw [List.all_eq_false]; exact ⟨p, hp, by simpa using h⟩
  simp [Release.changelogOnly, List.all_append, this]

theorem a_merge_after_the_tag_isnt_held (since : List String) (m : String) (ms : List (Option String))
    (h : m ∈ since) : Release.holds since (some m :: ms) = false := by
  simp [Release.holds, h]

/-- main one commit past v0.2.0, which changed `files` and nothing else. -/
def pastTag (t : T) (files : List (String × String)) : IO Unit := do
  changelog t "## v0.2.0\n\n- a.\n" (ref := "v0.2.0")
  t.repo core fun r =>
    let tree := files.foldl (fun tr (p, x) => (p, x) :: tr.filter (·.1 != p)) (Fake.tree r "tag-v0.2.0")
    { r with commits := r.commits.map fun c => if c.sha == mainSha then { c with parent := some "tag-v0.2.0", tree } else c }

/-- Issue `n`, ready for release, whose work core merged in pull request `pr`, as the commit `merge`. -/
def mergedIn (t : T) (pr n : Nat) (merge : String) : IO Unit := do
  t.issue core n "scale" ["request", "accepted", "ready-for-release"]
  t.pull core pr "core" (body := s!"Refs #{n}") (isOpen := false) (merged := some 5000)
  t.item core pr fun i => { i with pull := i.pull.map ({ · with mergeSha := some merge }) }

def releases : List (String × (T → Check)) := [
  ("9: CI failing on main", fun t => do
    setUp t
    t.status core mainSha .failure
    same (← release t) (some ("main failing", ["core"]))),
  ("up to date", fun t => do
    setUp t
    same (← release t) (some ("up to date", []))),
  ("15: ready for release is the coordinator's, and says who releases", fun t => do
    setUp t
    changelog t "## v0.3.0\n\n- b.\n\n## v0.2.0\n"
    t.issue core 13 "scale" ["request", "ready-for-release"]
    same (← release t) (some ("releasable", ["coordinator"]))
    same (← t.descriptions "coordinator") [
      s!"the release of {core} (releasable): it is below level 3: put the release to the human as a `Release <repo>` decision, whose command is `scripts/release.sh {core} '<one-line note>' 13`, completing {core}#13"]
    t.file core ".forgejo/CODEOWNERS" ".* @gatekeeper @conformance\nAPI\\.lock @coordinator\n"
    discard <| release t
    same ((← t.io (q "SELECT description FROM obligations")).toList.map (·.str "description"))
      [s!"the release of {core} (releasable): release it with `forge release`, naming every ready-for-release issue it completes: `forge release {core} '<one-line note>' 13`, completing {core}#13"]
    -- Below level 3, once the decision is open, the human releases it.
    t.file core ".forgejo/CODEOWNERS" "* @gatekeeper\n"
    t.issue core 14 "coordinator" ["needs-human"] (title := s!"Release {core}")
    same (← release t) (some ("with the human", ["human"]))),
  ("an entry above the last release is enough", fun t => do
    setUp t
    changelog t "## v0.3.0\n\n- b.\n\n## v0.2.0\n"
    same (← release t) (some ("releasable", ["coordinator"]))
    ensure (has ((← t.descriptions "coordinator").headD "") "nothing is labelled ready-for-release, but CHANGELOG.md on main heads v0.3.0") "the step"),
  ("lines under an already released heading say so", fun t => do
    setUp t
    -- Written before v0.2.0 was tagged, merged after: its lines land under v0.2.0.
    changelog t "## v0.2.0\n\n- a.\n" (ref := "v0.2.0")
    changelog t "## v0.2.0\n\n- a.\n- b.\n"
    t.issue core 5 "scale" ["request", "accepted", "ready-for-release"]
    same (← release t) (some ("no entry", ["core"]))
    ensure (has ((← t.descriptions "core").headD "")
      "(CHANGELOG.md's newest heading, v0.2.0, is already released, and lines were added under it after v0.2.0 was tagged: move them under a new heading; if v0.2.0 already holds an issue's work, comment `Released in v0.2.0` on the issue instead)") "added lines"
    -- Nothing added: only which heading is the last release.
    changelog t "## v0.2.0\n\n- a.\n"
    discard <| release t
    ensure (((← t.io (q "SELECT description FROM obligations WHERE agent='core'"))[0]?.map (·.str "description")).getD ""
      |>.endsWith "(CHANGELOG.md's newest heading, v0.2.0, is the last release; if v0.2.0 already holds an issue's work, comment `Released in v0.2.0` on the issue instead)") "the last release"),
  ("changelog lines alone after the tag ask for no release", fun t => do
    setUp t
    -- As inkproof-demos at v0.47.0: #4 is in the tag, and a later commit only added its lines.
    pastTag t [("CHANGELOG.md", "## v0.2.0\n\n- a.\n- b.\n")]
    mergedIn t 4 5 "tag-v0.2.0"
    same (← release t) (some ("up to date", []))
    same (← t.owing (some s!"release:{core}")) []
    ensure ((← t.commentsOn core 5).any (has · "Released in v0.2.0, which holds #4.")) "recorded as released"
    t.evaluate core 5
    same (← t.state s!"{core}#5") (some ("released", ["scale"]))
    ensure ((← t.queued "core").isEmpty) "the owner isn't woken"
    discard <| release t
    same ((← t.commentsOn core 5).filter (has · "Released in")).length 1 "recorded once"),
  ("an issue whose work the tag holds is released, though code merged since", fun t => do
    setUp t
    pastTag t [("Test/Core.lean", "def c := 1\n")]
    mergedIn t 4 5 "tag-v0.2.0"
    same (← release t) (some ("up to date", []))
    ensure ((← t.commentsOn core 5).any (has · "Released in v0.2.0, which holds #4.")) "recorded as released"),
  ("code merged after the tag still asks for a release", fun t => do
    setUp t
    pastTag t [("Test/Core.lean", "def c := 1\n"), ("CHANGELOG.md", "## v0.2.0\n\n- a.\n- b.\n")]
    mergedIn t 4 5 mainSha
    same (← release t) (some ("no entry", ["core"]))
    ensure (!(← t.commentsOn core 5).any (has · "Released in")) "not recorded as released"),
  ("a heading the gatekeeper would refuse is the owner's", fun t => do
    setUp t
    changelog t "## v0.2.1\n\n- b.\n\n## v0.2.0\n"
    t.issue core 5 "scale" ["request", "accepted", "ready-for-release"]
    same (← release t) (some ("wrong entry", ["core"]))
    ensure (has ((← t.descriptions "core").headD "") "(`forge version` gives v0.3.0; CHANGELOG.md heads v0.2.1)") "the versions"),
  ("the last release is the highest tag, as the gatekeeper finds it", fun t => do
    setUp t
    -- Tagged before the forge had releases for it, as a migrated repository may be.
    t.repo core fun r => { r with tags := r.tags ++ [{ name := "v0.3.0", sha := "t3" }, { name := "not-a-version", sha := "t4" }] }
    t.file core "API.lock" "def a : Nat\ndef b : Nat\n" (ref := "v0.3.0")
    changelog t "## v0.3.0\n\n- b.\n"
    same (← release t) (some ("up to date", [])) "v0.3.0 is released"
    changelog t "## v0.3.1\n\n- c.\n\n## v0.3.0\n"
    same (← release t) (some ("releasable", ["coordinator"])) "API.lock unchanged since v0.3.0: a patch"),
  ("ready for release with no entry is the owner's", fun t => do
    setUp t
    t.issue core 5 "scale" ["request", "accepted", "ready-for-release"]
    same (← release t) (some ("no entry", ["core"]))),
  ("not while main's CI runs", fun t => do
    setUp t
    changelog t "## v0.3.0\n\n## v0.2.0\n"
    t.status core mainSha .pending 100
    same (← release t) (some ("main CI running", ["timer"]))
    t.status core mainSha .success 50
    same ((← release t).map (·.1)) (some "releasable")),
  ("held by what holds a ready issue", fun t => do
    setUp t
    changelog t "## v0.3.0\n\n## v0.2.0\n"
    t.issue core 13 "coordinator" ["request", "ready-for-release"] (events :=
      [← t.comment "coordinator" 300 "Refused: the README is stale.\n\nWaiting-on: core"])
    same (← release t) (some ("held", ["unit:held"]))
    t.evaluate core 13
    same (← t.owing) [("core", "reply"), ("core", "waiting")]),
  ("CI on main finishing evaluates the release", fun t => do
    setUp t
    changelog t "## v0.3.0\n\n## v0.2.0\n"
    t.handle "action_run_success" (Json.mkObj [
      ("repository", Json.mkObj [("name", toJson core), ("owner", Json.mkObj [("login", toJson "org")])]),
      ("sender", Json.mkObj [("login", toJson "ci")]), ("run", Json.mkObj [("event", toJson "push")])])
    same ((← t.state s!"release:{core}").map (·.1)) (some "releasable"))]

def milestones : List (String × (T → Check)) := [
  ("17: finished on every repository it spans", fun t => do
    t.milestones scale [ms]
    t.milestones core [ms (open_ := 2)]
    t.milestones coord [ms (closed := 0)]  -- an empty namesake counts neither way
    t.io evaluateMilestones
    same (← t.state "milestone:M1") (some ("in progress", ["unit:issues"]))
    same (← t.state "kit") (some ("in progress", ["unit:milestones"]))
    t.milestones core [ms]
    t.io evaluateMilestones
    same (← t.owing (some "milestone:M1")) [("coordinator", "finished")]
    same (← t.owing (some "kit")) [("coordinator", "what next")] "and no milestone has open work"
    ensure (has ((← t.descriptions "coordinator").headD "") "open its milestone issue and add milestone-review") "the step"),
  ("its issue, its reviews, and its acceptance", fun t => do
    t.milestones coord [ms (open_ := 1)]
    t.issue coord 9 "coordinator" ["milestone", "milestone-review"] (title := "Milestone: M1") (events :=
      [← t.label "milestone-review" true 600 "coordinator", ← t.comment "engineer" 500 "(no reply needed)\nNo findings."])
    t.evaluate coord 9
    t.io evaluateMilestones
    same (← t.state s!"{coord}#9") (some ("in review", ["architecture"]))
    t.add coord 9 (← t.comment "architecture" 400 "(no reply needed)\nReport.")
    t.evaluate coord 9
    same (← t.state s!"{coord}#9") (some ("reviewed", ["coordinator"]))
    -- A comment isn't an answer: a Blocked-by: line is.
    t.add coord 9 (← t.comment "coordinator" 300 "(no reply needed)\nWaiting on #85.")
    t.evaluate coord 9
    same (← t.stateName s!"{coord}#9") "reviewed"
    t.issue coord 85 "coordinator"
    t.add coord 9 (← t.comment "coordinator" 200 s!"(no reply needed)\n{line coord 85}")
    t.evaluate coord 9
    same (← t.stateName s!"{coord}#9") "blocked"
    -- Accepted: its issue closed, its milestones still open.
    t.close coord 9
    t.milestones coord [ms]
    t.evaluate coord 9
    t.io evaluateMilestones
    same (← t.state "milestone:M1") (some ("accepted", ["coordinator"]))
    t.milestones coord [ms (isOpen := false)]
    t.io evaluateMilestones
    same (← t.state "milestone:M1") (some ("closed", []))),
  ("21: its reviews, even once accepted", fun t => do
    t.issue coord 73 "coordinator" ["milestone-review"] (isOpen := false) (closed := some 60) (events :=
      [← t.label "milestone-review" true 70 "coordinator", ← t.comment "coordinator" 60 "(no reply needed)\nAccepted.",
       ← t.comment "engineer" 30 "(no reply needed)\nNo findings."])
    t.evaluate coord 73
    same (← t.owing) [("architecture", "in review")]
    t.add coord 73 (← t.comment "architecture" 10 "(no reply needed)\nReport.")
    t.evaluate coord 73
    same (← t.owing) []),
  ("23: what next, once no milestone has open work", fun t => do
    t.milestones coord [ms (isOpen := false)]
    let run ← t.running "coordinator"
    t.io evaluateMilestones
    same (← t.owing) [("coordinator", "what next")]
    same (← t.queued "coordinator") [] "quiet: not while it runs, drafting the next one perhaps"
    t.io (exec "UPDATE runs SET ended=? WHERE id=?" [← t.env.now, run])
    t.wakeDue
    ensure (has ((← t.descriptions "coordinator").headD "") "close out any left open") "the step"
    -- A decision for the human, a pull request on its repository, or the project finished answers it.
    t.issue coord 5 "coordinator" ["needs-human"] (assignees := [human])
    t.io evaluateMilestones
    same (← t.state "kit") (some ("with the human", ["human"]))
    t.close coord 5
    t.file coord "ROADMAP.md" "# Roadmap\n\nStatus: finished\n"
    t.io evaluateMilestones
    same (← t.state "kit") (some ("finished", []))
    same (← t.owing) [])]

def check : IO Bool := do
  let a ← runCases "dispatcher pull requests" pulls
  let b ← runCases "dispatcher releases" releases
  let c ← runCases "dispatcher milestones" milestones
  return a && b && c

end GuildTests.Dispatch.Units
