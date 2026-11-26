/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Guild.Forge
import GuildTests.Fake

/-! The contract tests: what the kit relies on a forge to do, run against the real Forgejo and the
fake alike, so the fake stays honest. Each check is about behaviour that has surprised the kit:
paging, dropped labels, `updated_at`, requested reviewers, scheduled merges and re-runs. -/

namespace GuildTests.Contract

open Guild.Forge

structure Env where
  repo : Repo
  /-- Writes to the repository and opens pull requests. -/
  owner : Forge
  /-- Writes to it too, and reviews. -/
  reviewer : Forge
  /-- May only file issues. -/
  outsider : Forge
  admin : Forge
  /-- A label the repository has. -/
  label : String
  /-- Makes `main` need one approval, counted only from `reviewer`, and a successful `checks` status. -/
  protect : M Unit
  /-- Sets a commit's `checks` status, as CI does. -/
  setStatus : (sha : String) → StatusState → M Unit
  /-- Long enough for a later write to have a later time, and for the forge to act on a write. -/
  settle : IO Unit
  /-- How many times to settle while waiting for something, such as a CI run. -/
  patience : Nat
  /-- Distinguishes this run's branches from an earlier run's. -/
  suffix : String

abbrev T := ExceptT String IO

def lift (x : M α) : T α := do
  match ← x.run with
  | .ok a => pure a
  | .error e => throw (toString e)

def ensure (cond : Bool) (message : String) : T Unit := unless cond do throw message

def settle (e : Env) : T Unit := (e.settle : IO Unit)

/-- Whether `cond` holds within the environment's patience. -/
def eventually (e : Env) (cond : T Bool) : T Bool := do
  for _ in List.range e.patience do
    if ← cond then return true
    settle e
  cond

def openPull (e : Env) (name : String) : T (Nat × String) := do
  let branch := s!"{name}-{e.suffix}"
  let sha ← lift (e.owner.commit e.repo
    { branch, start := some "main", message := name, files := [(s!"{branch}.txt", name)] })
  let n ← lift (e.owner.createPull e.repo { head := branch, title := name })
  return (n, sha)

def mergedPull (e : Env) (n : Nat) : T Bool := do
  return ((← lift (e.admin.pull e.repo n)).map (·.merged)).getD false

/-- A merge, or with `schedule` a scheduled one, through the forge's short spells of checking
mergeability. -/
def mergeNow (e : Env) (n : Nat) (schedule := false) : T MergeResult := do
  for _ in List.range e.patience do
    match ← lift (e.owner.merge e.repo n schedule) with
    | .tryLater => settle e
    | r => return r
  lift (e.owner.merge e.repo n schedule)

def labelFilter (e : Env) : T Unit := do
  let n ← lift (e.owner.createIssue e.repo { title := "labelled", labels := [e.label] })
  discard <| lift (e.owner.createIssue e.repo { title := "unlabelled" })
  let none ← lift (e.owner.issues e.repo { labels := ["no-such-label"] })
  ensure none.isEmpty s!"a filter on a label the repository lacks matched {none.length} item(s)"
  let some ← lift (e.owner.issues e.repo { labels := [e.label] })
  ensure (some.all (·.labels.contains e.label)) "a label filter matched an item without the label"
  ensure (some.any (·.number == n)) "a label filter missed an item with the label"

def droppedLabels (e : Env) : T Unit := do
  let n ← lift (e.outsider.createIssue e.repo { title := "an outsider's request", labels := [e.label] })
  let i ← lift (e.admin.issue e.repo n)
  ensure ((i.map (·.labels)) == some []) s!"an outsider's labels were kept: {repr (i.map (·.labels))}"
  let m ← lift (e.owner.createIssue e.repo { title := "an owner's request", labels := [e.label] })
  let j ← lift (e.admin.issue e.repo m)
  ensure ((j.map (·.labels)) == some [e.label]) "an owner's labels were dropped"
  match ← (e.outsider.addLabel e.repo n e.label).run with
  | .ok () => throw "an outsider added a label"
  | .error (.status 403 _) => pure ()
  | .error err => throw s!"an outsider adding a label: {err}"

def pagedComments (e : Env) : T Unit := do
  let n ← lift (e.owner.createIssue e.repo { title := "many comments" })
  let bodies := (List.range 55).map (s!"comment {·}")
  for b in bodies do lift (e.owner.comment e.repo n b)
  let cs ← lift (e.owner.comments e.repo n)
  ensure (cs.map (·.body) == bodies) s!"read {cs.length} comments, not the {bodies.length} written, in order"
  let entries ← lift (e.owner.timeline e.repo n)
  let said := entries.filterMap fun x => match x.event with | .comment _ b => some b | _ => none
  ensure (said == bodies) s!"the timeline has {said.length} of the {bodies.length} comments"

def pagedIssues (e : Env) : T Unit := do
  let title := s!"one of many {e.suffix}"
  for _ in List.range 51 do discard <| lift (e.owner.createIssue e.repo { title })
  let all ← lift (e.owner.issues e.repo { which := .all, kinds := .issues })
  let mine := (all.filter (·.title == title)).length
  ensure (mine == 51) s!"listed {mine} of 51 issues"
  ensure ((all.map (·.number)).eraseDups.length == all.length) "an issue was listed twice"

def updatedAt (e : Env) : T Unit := do
  let (n, _) ← openPull e "updated"
  let stampOf := fun () => do
    let some p ← lift (e.admin.pull e.repo n) | throw "the pull request vanished"
    pure p.updatedAt
  let moves (what : String) (act : M Unit) : T Unit := do
    let before ← stampOf ()
    settle e
    lift act
    let after ← stampOf ()
    ensure (before < after) s!"{what} left updated_at at {before}"
  moves "a comment" (e.owner.comment e.repo n "a comment")
  moves "a label" (e.owner.addLabel e.repo n e.label)
  moves "a review request" (e.owner.requestReviewers e.repo n [e.reviewer.account])

def requestedReviewers (e : Env) : T Unit := do
  let (n, sha) ← openPull e "requested"
  lift (e.owner.requestReviewers e.repo n [e.reviewer.account])
  lift (e.admin.review e.repo n .approve "unasked" sha)
  lift (e.reviewer.review e.repo n .approve "asked" sha)
  let some p ← lift (e.admin.pull e.repo n) | throw "the pull request vanished"
  for who in [e.reviewer.account, e.admin.account] do
    ensure (p.requestedReviewers.contains who) s!"{who} approved but isn't among the requested reviewers"
  let asked := (← lift (e.admin.timeline e.repo n)).filterMap fun x => match x.event with
    | .reviewRequest r false => some r
    | _ => none
  ensure (asked == [e.reviewer.account]) s!"the timeline's review requests are {asked}"

def scheduledFires (e : Env) : T Unit := do
  let (n, sha) ← openPull e "scheduled"
  lift (e.setStatus sha .pending)
  let direct ← mergeNow e n
  ensure (direct != .merged) "a pull request without approval or CI merged"
  let r ← mergeNow e n (schedule := true)
  ensure (r == .scheduled) s!"scheduling a merge gave {repr r}"
  lift (e.reviewer.review e.repo n .approve "fine" sha)
  lift (e.setStatus sha .success)
  ensure (← eventually e (mergedPull e n)) "a merge scheduled while CI ran didn't fire when it passed"
  let events := (← lift (e.admin.timeline e.repo n)).map (·.event)
  ensure (events.contains .scheduleMerge && events.contains .merged) "the timeline lacks the schedule or the merge"

def scheduledStuck (e : Env) : T Unit := do
  let (n, sha) ← openPull e "stuck"
  lift (e.setStatus sha .success)
  lift (e.reviewer.review e.repo n .approve "fine" sha)
  settle e
  let r ← mergeNow e n (schedule := true)
  ensure (r == .scheduled) s!"scheduling a merge that could go ahead gave {repr r}"
  for _ in List.range 3 do settle e
  ensure (!(← mergedPull e n)) "a merge scheduled once everything passed fired"
  lift (e.owner.cancelMerge e.repo n)
  let r ← mergeNow e n
  ensure (r == .merged) s!"merging directly instead gave {repr r}"

def narrowedMergers (e : Env) : T Unit := do
  let (n, sha) ← openPull e "mergers"
  lift (e.setStatus sha .success)
  lift (e.reviewer.review e.repo n .approve "fine" sha)
  lift (e.admin.mergers e.repo (some [e.admin.account]))
  let r ← mergeNow e n
  ensure (r != .merged) "a writer merged past a list of mergers that leaves them out"
  lift (e.admin.mergers e.repo none)
  let r ← mergeNow e n
  ensure (r == .merged) s!"with the list restored, merging gave {repr r}"

def failingWorkflow : String :=
  "on: [push]\njobs:\n  fail:\n    runs-on: docker\n    steps:\n      - run: exit 1\n"

/-- Whether every job of a run is finished, at the given attempt. -/
def finished (e : Env) (run attempt : Nat) : T Bool := do
  let jobs ← lift (e.owner.jobs e.repo run)
  return !jobs.isEmpty && jobs.all fun j => j.attempt == attempt && j.status.finished

def reruns (e : Env) : T Unit := do
  let branch := s!"failing-{e.suffix}"
  let sha ← lift (e.owner.commit e.repo
    { branch, start := some "main", message := "fail", files := [(".forgejo/workflows/fail.yml", failingWorkflow)] })
  let failing : T (Option Run) := do
    return (← lift (e.owner.runs e.repo sha)).find? (·.workflow == "fail.yml")
  ensure (← eventually e (return (← failing).isSome)) "the failing workflow never ran"
  let some run ← failing | throw "no run"
  ensure (← eventually e (finished e run.id 1)) "the failing run didn't finish"
  let before ← lift (e.owner.reruns e.repo sha)
  let runs ← lift (e.owner.runs e.repo sha)
  lift (e.owner.rerun e.repo run.id)
  ensure (← eventually e (finished e run.id 2)) "the re-run didn't finish"
  let after ← lift (e.owner.reruns e.repo sha)
  ensure (after == before + 1) s!"one re-run took the count from {before} to {after}"
  let again ← lift (e.owner.runs e.repo sha)
  ensure (again.length == runs.length) s!"a re-run made {again.length} runs from {runs.length}"

def checks : List (String × (Env → T Unit)) :=
  [("a label filter is exact", labelFilter),
   ("labels from an account that may not write are dropped", droppedLabels),
   ("every comment is read, though the forge doesn't page them", pagedComments),
   ("every issue is read, past a page", pagedIssues),
   ("updated_at moves with a comment, a label and a review request", updatedAt),
   ("approvers are listed as requested; the timeline says who was asked", requestedReviewers),
   ("a merge scheduled while CI runs fires when it passes", scheduledFires),
   ("a merge scheduled once everything passed never fires", scheduledStuck),
   ("only the listed mergers merge, until the list is lifted", narrowedMergers),
   ("re-runs are counted from the forge", reruns)]

/-- Runs every check against a forge with a `main` branch, printing each result. -/
def run (name : String) (e : Env) : IO Bool := do
  let start : M Unit := do
    if (← e.owner.branch e.repo "main").isNone then
      discard <| e.owner.commit e.repo { branch := "main", message := "contract", files := [("README.md", e.suffix)] }
  match ← start.run with
  | .error err => IO.println s!"FAIL ({name}): couldn't make main: {err}"; return false
  | .ok () => pure ()
  match ← e.protect.run with
  | .error err => IO.println s!"FAIL ({name}): couldn't protect main: {err}"; return false
  | .ok _ => pure ()
  let mut ok := true
  for (what, check) in checks do
    match ← (check e).run with
    | .ok () => IO.println s!"PASS ({name}): {what}"
    | .error m => IO.println s!"FAIL ({name}): {what}: {m}"; ok := false
  return ok

def fakeEnv : IO Env := do
  let world : Fake.World :=
    { admins := ["admin"],
      repos := [{ name := "repo", labels := ["request", "priority"], writers := ["owner", "reviewer"] }] }
  let ref ← IO.mkRef world
  return { repo := "repo", owner := Fake.as ref "owner", reviewer := Fake.as ref "reviewer",
           outsider := Fake.as ref "outsider", admin := Fake.as ref "admin", label := "request",
           protect := Fake.protect ref "repo" { approvals := 1, approvers := ["reviewer"], contexts := ["checks"] },
           setStatus := fun sha s => Fake.setStatus ref "repo" sha "checks" s,
           settle := pure (), patience := 3, suffix := "fake" }

def checkFake : IO Bool := do run "fake" (← fakeEnv)

end GuildTests.Contract
