/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Guild.Forge

/-! A fake forge, in memory, behaving as the contract tests find Forgejo does. Its clock moves one
second with every write, so every write is later than the one before.

CI is simulated: a commit runs each workflow its tree has, under `.forgejo/workflows/`, and a run
fails when its workflow contains `exit 1`. -/

namespace GuildTests.Fake

open Guild.Forge

structure Protection where
  approvals : Nat
  /-- Whose approvals count. -/
  approvers : List String
  contexts : List String
  /-- With `some`, only these accounts may merge. -/
  mergers : Option (List String) := none

structure PullPart where
  head : String
  base : String
  headSha : String
  merged : Bool := false
  mergedAt : Option String := none
  mergeable : Option Bool := some true
  scheduled : Bool := false
  requested : List String := []
  reviews : Array Review := #[]
  /-- The paths it changes, when a test says so rather than through commits. -/
  files : Option (List String) := none

structure Item where
  number : Nat
  title : String
  body : String
  author : String
  isOpen : Bool := true
  labels : List String := []
  assignees : List String := []
  createdAt : String
  updatedAt : String
  closedAt : Option String := none
  comments : Array Comment := #[]
  timeline : Array Entry := #[]
  pull : Option PullPart := none

structure Commit where
  sha : String
  message : String
  tree : List (String × String)
  time : String

structure RunPart where
  run : Run
  jobs : List Job

structure RepoState where
  name : String
  labels : List String
  writers : List String
  branches : List (String × String) := []
  commits : List Commit := []
  items : Array Item := #[]
  statuses : List (String × Status) := []
  runs : Array RunPart := #[]
  releases : List Release := []
  tags : List Tag := []
  protection : Option Protection := none
  milestones : List Milestone := []

structure World where
  clock : Nat := 0
  next : Nat := 1
  admins : List String
  repos : List RepoState

def pad2 (n : Nat) : String := if n < 10 then s!"0{n}" else toString n

/-- A time `n` seconds into the fake's day zero. -/
def stamp (n : Nat) : String :=
  s!"2026-01-{pad2 (1 + n / 86400)}T{pad2 (n / 3600 % 24)}:{pad2 (n / 60 % 60)}:{pad2 (n % 60)}Z"

def hex (n : Nat) : String :=
  let digits := Nat.toDigits 16 n
  String.ofList (List.replicate (40 - digits.length) '0' ++ digits)

abbrev W := StateT World (ExceptT Error IO)

def fail (code : Nat) (message : String) : W α := throw (.status code message)

def tick : W String := do
  let w ← get
  set { w with clock := w.clock + 1 }
  return stamp (w.clock + 1)

def fresh : W Nat := do
  let w ← get
  set { w with next := w.next + 1 }
  return w.next

def repoOf (repo : Repo) : W RepoState := do
  match (← get).repos.find? (·.name == repo) with
  | some r => pure r
  | none => fail 404 s!"no repository {repo}"

def setRepo (r : RepoState) : W Unit :=
  modify fun w => { w with repos := w.repos.map fun x => if x.name == r.name then r else x }

def canWrite (who : String) (r : RepoState) : W Bool := do
  return (← get).admins.contains who || r.writers.contains who

def itemOf (r : RepoState) (n : Nat) : W Item :=
  match r.items.find? (·.number == n) with
  | some i => pure i
  | none => fail 404 s!"no item {n}"

def setItem (r : RepoState) (i : Item) : RepoState :=
  { r with items := r.items.map fun x => if x.number == i.number then i else x }

def pullOf (i : Item) : W PullPart :=
  match i.pull with
  | some p => pure p
  | none => fail 404 s!"{i.number} isn't a pull request"

def toIssue (i : Item) : Issue :=
  { number := i.number, isPull := i.pull.isSome, isOpen := i.isOpen, title := i.title,
    body := i.body, author := i.author, labels := i.labels, assignees := i.assignees,
    createdAt := i.createdAt, updatedAt := i.updatedAt, closedAt := i.closedAt, milestone := none }

/-- Forgejo lists everyone who has approved among the requested reviewers, asked or not. -/
def toPull (i : Item) (p : PullPart) : Pull :=
  let approvers := (p.reviews.filter (·.verdict == .approve)).toList.map (·.author)
  { number := i.number, isOpen := i.isOpen, merged := p.merged, title := i.title, body := i.body,
    author := i.author, headSha := p.headSha, headRef := p.head, baseRef := p.base,
    mergeable := p.mergeable, requestedReviewers := (p.requested ++ approvers).eraseDups,
    createdAt := i.createdAt, updatedAt := i.updatedAt, mergedAt := p.mergedAt }

def tree (r : RepoState) (sha : String) : List (String × String) :=
  ((r.commits.find? (·.sha == sha)).map (·.tree)).getD []

def branchSha (r : RepoState) (name : String) : Option String := r.branches.lookup name

def note (i : Item) (actor time : String) (e : Event) : Item :=
  { i with timeline := i.timeline.push { time, actor, event := e }, updatedAt := time }

/-- Each workflow in the commit's tree runs, once. -/
def startRuns (r : RepoState) (c : Commit) (time : String) : W RepoState := do
  let mut r := r
  for (path, text) in c.tree do
    if path.startsWith ".forgejo/workflows/" then
      let id ← fresh
      let failing := (text.splitOn "exit 1").length > 1
      let status : RunStatus := if failing then .failure else .success
      let run := { id, workflow := (path.splitOn "/").getLastD path, status, sha := c.sha,
                   event := "push", created := time }
      r := { r with runs := r.runs.push { run, jobs := [{ id := ← fresh, name := "job", status, attempt := 1 }] } }
  return r

/-- Whether branch protection lets a pull request merge now. -/
def allowed (r : RepoState) (i : Item) (p : PullPart) : Bool :=
  match r.protection with
  | none => true
  | some prot =>
    let approvals := (p.reviews.filter fun v =>
      v.verdict == .approve && v.commit == p.headSha && !v.dismissed && v.author != i.author &&
      prot.approvers.contains v.author).size
    let passed (ctx : String) := r.statuses.any fun (sha, s) =>
      sha == p.headSha && s.context == ctx && s.state == .success
    decide (prot.approvals ≤ approvals) && prot.contexts.all passed

def doMerge (r : RepoState) (i : Item) (p : PullPart) (actor time : String) : W RepoState := do
  let sha := hex (← fresh)
  let c := { sha, message := i.title, tree := tree r p.headSha, time }
  let i := note { i with isOpen := false, closedAt := some time,
                         pull := some { p with merged := true, mergedAt := some time, scheduled := false } } actor time .merged
  let r := { r with commits := c :: r.commits,
                    branches := (p.base, sha) :: ((r.branches.filter (·.1 != p.base)).filter (·.1 != p.head)) }
  startRuns (setItem r i) c time

/-- Forgejo acts on a scheduled merge only when a review or a status arrives after it. -/
def fireScheduled (r : RepoState) (sha time : String) : W RepoState := do
  let mut r := r
  for i in r.items do
    if let some p := i.pull then
      if p.scheduled && p.headSha == sha && i.isOpen && allowed r i p then
        r ← doMerge r i p i.author time
  return r

def run (ref : IO.Ref World) (act : W α) : M α := do
  let (a, w) ← act.run (← ref.get)
  ref.set w
  pure a

def selects (q : IssueQuery) (i : Item) : Bool :=
  (match q.which with | .open => i.isOpen | .closed => !i.isOpen | .all => true) &&
  (match q.kinds with | .issues => i.pull.isNone | .pulls => i.pull.isSome | .all => true) &&
  q.labels.all i.labels.contains &&
  (match q.since with | some s => decide (s ≤ i.updatedAt) | none => true)

def as (ref : IO.Ref World) (who : String) : Forge where
  account := who
  repos := run ref do return (← get).repos.map fun r => { name := r.name, archived := false }
  repoExists repo := run ref do return (← get).repos.any (·.name == repo)
  branch repo name := run ref do
    let r ← repoOf repo
    return (branchSha r name).map fun sha =>
      { sha, timestamp := ((r.commits.find? (·.sha == sha)).map (·.time)).getD "" }
  file repo path ref' := run ref do
    let r ← repoOf repo
    let sha := ((branchSha r ref').orElse fun _ => (r.tags.find? (·.name == ref')).map (·.sha)).getD ref'
    return (tree r sha).lookup path
  issue repo n := run ref do
    return ((← repoOf repo).items.find? (·.number == n)).map toIssue
  issues repo q := run ref do
    return ((← repoOf repo).items.filter (selects q)).toList.map toIssue
  labels repo := run ref do return (← repoOf repo).labels
  comments repo n := run ref do return (← itemOf (← repoOf repo) n).comments.toList
  timeline repo n := run ref do return (← itemOf (← repoOf repo) n).timeline.toList
  pull repo n := run ref do
    let r ← repoOf repo
    return (r.items.find? (·.number == n)).bind fun i => i.pull.map (toPull i)
  pulls repo w := run ref do
    let r ← repoOf repo
    let q : IssueQuery := { which := w, kinds := .pulls }
    return (r.items.filter (selects q)).toList.filterMap fun i => i.pull.map (toPull i)
  pullCommits repo n := run ref do
    let i ← itemOf (← repoOf repo) n
    return [i.title]
  pullFiles repo n := run ref do
    let r ← repoOf repo
    let p ← pullOf (← itemOf r n)
    if let some fs := p.files then return fs
    let base := (branchSha r p.base).map (tree r) |>.getD []
    return ((tree r p.headSha).filter fun f => base.lookup f.1 != some f.2).map (·.1)
  reviews repo n := run ref do return (← pullOf (← itemOf (← repoOf repo) n)).reviews.toList
  statuses repo sha := run ref do
    return ((← repoOf repo).statuses.filter (·.1 == sha)).map (·.2)
  runs repo sha := run ref do
    return ((← repoOf repo).runs.filter (·.run.sha == sha)).toList.reverse.map (·.run)
  activeRuns repo := run ref do
    return ((← repoOf repo).runs.filter (!·.run.status.finished)).toList.reverse.map (·.run)
  jobs repo id := run ref do
    match (← repoOf repo).runs.find? (·.run.id == id) with
    | some p => pure p.jobs
    | none => fail 404 s!"no run {id}"
  jobLog _ job := run ref do return s!"job {job}"
  releases repo := run ref do return (← repoOf repo).releases
  tags repo := run ref do return (← repoOf repo).tags
  milestones repo := run ref do return (← repoOf repo).milestones
  createIssue repo k := run ref do
    let r ← repoOf repo
    let time ← tick
    let n := r.items.size + 1
    -- Forgejo drops the labels of an account that may not write to the repository.
    let labels := if ← canWrite who r then k.labels else []
    for l in labels do
      unless r.labels.contains l do fail 422 s!"{repo} has no label {l}"
    setRepo { r with items := r.items.push (
      { number := n, title := k.title, body := k.body, author := who, labels,
        assignees := k.assignees, createdAt := time, updatedAt := time }) }
    return n
  setAssignees repo n as := run ref do
    let r ← repoOf repo
    let i ← itemOf r n
    let time ← tick
    setRepo (setItem r { i with assignees := as, updatedAt := time })
  close repo n := run ref do
    let r ← repoOf repo
    let i ← itemOf r n
    let time ← tick
    setRepo (setItem r (note { i with isOpen := false, closedAt := some time } who time .closed))
  addLabel repo n l := run ref do
    let r ← repoOf repo
    unless ← canWrite who r do fail 403 "you may not change labels"
    unless r.labels.contains l do fail 422 s!"{repo} has no label {l}"
    let i ← itemOf r n
    let time ← tick
    setRepo (setItem r (note { i with labels := (i.labels ++ [l]).eraseDups } who time (.label l true)))
  removeLabel repo n l := run ref do
    let r ← repoOf repo
    unless ← canWrite who r do fail 403 "you may not change labels"
    let i ← itemOf r n
    let time ← tick
    setRepo (setItem r (note { i with labels := i.labels.erase l } who time (.label l false)))
  comment repo n text := run ref do
    let r ← repoOf repo
    let i ← itemOf r n
    let time ← tick
    let id ← fresh
    let i := note { i with comments := i.comments.push { id, author := who, body := text, createdAt := time } }
      who time (.comment id text)
    setRepo (setItem r i)
  createPull repo k := run ref do
    let r ← repoOf repo
    let some headSha := branchSha r k.head | fail 404 s!"no branch {k.head}"
    let time ← tick
    let n := r.items.size + 1
    setRepo { r with items := r.items.push (
      { number := n, title := k.title, body := k.body, author := who, createdAt := time,
        updatedAt := time, pull := some { head := k.head, base := k.base, headSha },
        timeline := #[{ time, actor := who, event := .push }] }) }
    return n
  requestReviewers repo n reviewers := run ref do
    let r ← repoOf repo
    let i ← itemOf r n
    let p ← pullOf i
    let time ← tick
    let i := reviewers.foldl (fun i a => note i who time (.reviewRequest a false))
      { i with pull := some { p with requested := (p.requested ++ reviewers).eraseDups } }
    setRepo (setItem r i)
  review repo n v text commit := run ref do
    let r ← repoOf repo
    let i ← itemOf r n
    let p ← pullOf i
    let time ← tick
    let id ← fresh
    let rv := { id, author := who, verdict := v, commit, dismissed := false, stale := false,
                submittedAt := time, body := text }
    let i := note { i with pull := some { p with reviews := p.reviews.push rv } } who time .review
    setRepo (← fireScheduled (setItem r i) p.headSha time)
  merge repo n schedule := run ref do
    let r ← repoOf repo
    let i ← itemOf r n
    let p ← pullOf i
    unless ← canWrite who r do fail 403 "you may not merge"
    unless i.isOpen do return .refused "the pull request is closed"
    let time ← tick
    if schedule then
      setRepo (setItem r (note { i with pull := some { p with scheduled := true } } who time .scheduleMerge))
      return .scheduled
    if r.protection.any (·.mergers.any (!·.contains who)) then
      return .refused "you are not allowed to merge this pull request"
    if allowed r i p then
      setRepo (← doMerge r i p who time)
      return .merged
    return .refused "Not all required status checks successful, or not enough approvals"
  cancelMerge repo n := run ref do
    let r ← repoOf repo
    let i ← itemOf r n
    let p ← pullOf i
    let time ← tick
    setRepo (setItem r (note { i with pull := some { p with scheduled := false } } who time .cancelScheduledMerge))
  mergers repo who' := run ref do
    let r ← repoOf repo
    setRepo { r with protection := r.protection.map ({ · with mergers := who' }) }
  rerun repo id := run ref do
    let r ← repoOf repo
    unless ← canWrite who r do fail 403 "you may not re-run"
    let some part := r.runs.find? (·.run.id == id) | fail 404 s!"no run {id}"
    let part := { part with jobs := part.jobs.map fun j => { j with attempt := j.attempt + 1 } }
    setRepo { r with runs := r.runs.map fun x => if x.run.id == id then part else x }
  createRelease repo k := run ref do
    let r ← repoOf repo
    let time ← tick
    let sha := ((branchSha r k.target).getD k.target)
    setRepo { r with releases := { tag := k.tag, draft := false, publishedAt := some time } :: r.releases,
                     tags := if r.tags.any (·.name == k.tag) then r.tags else { name := k.tag, sha } :: r.tags }
    return s!"https://forge.invalid/{repo}/releases/tag/{k.tag}"
  commit repo k := run ref do
    let r ← repoOf repo
    unless ← canWrite who r do fail 403 "you may not push"
    let parent ← match k.start with
      | some s => match branchSha r s with
        | some sha => pure (some sha)
        | none => fail 404 s!"no branch {s}"
      | none => match branchSha r k.branch with
        | some sha => pure (some sha)
        | none => if r.branches.isEmpty then pure none else fail 404 s!"no branch {k.branch}"
    let time ← tick
    let base := (parent.map (tree r)).getD []
    let files := k.files.foldl (fun t (path, text) => (path, text) :: t.filter (·.1 != path)) base
    let c := { sha := hex (← fresh), message := k.message, tree := files, time }
    let r := { r with commits := c :: r.commits,
                      branches := (k.branch, c.sha) :: r.branches.filter (·.1 != k.branch) }
    -- A push to a pull request's branch moves its head.
    let r := { r with items := r.items.map fun i => match i.pull with
      | some p => if p.head == k.branch && i.isOpen then note { i with pull := some { p with headSha := c.sha } } who time .push else i
      | none => i }
    setRepo (← startRuns r c time)
    return c.sha

/-- What CI and the human do to the fake that no account's `Forge` can. -/
def setStatus (ref : IO.Ref World) (repo : Repo) (sha context : String) (state : StatusState) : M Unit :=
  run ref do
    let r ← repoOf repo
    let time ← tick
    let r := { r with statuses := (sha, { context, state, updatedAt := time }) ::
      r.statuses.filter fun (s, st) => !(s == sha && st.context == context) }
    setRepo (← fireScheduled r sha time)

def protect (ref : IO.Ref World) (repo : Repo) (p : Protection) : M Unit :=
  run ref do setRepo { ← repoOf repo with protection := some p }

end GuildTests.Fake
