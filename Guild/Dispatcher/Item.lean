/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
module

public import Guild.Dispatcher.Ledger
public import Guild.Dispatcher.Text
public import Guild.Gatekeeper

/-! Issues and pull requests as the rules read them, read once until they change: kept until a
webhook names the item, the kit writes to it, a listing shows a newer `updatedAt`, or
`itemMaxAge` passes. The forge bumps `updatedAt` for labels, comments, assignees, a push, a
review, an edit and closing, but not for a review request or main moving, so a pull request is
read afresh every time and its `updatedAt` checks the rest. -/

@[expose] public section

namespace Guild.Dispatcher

open Guild.Forge Guild.Version Text

/-! ## Short-lived reads -/

def withCaches {α} (f : Caches → IO α) : D α := do
  let c := (← read).caches
  c.lock.atomically (f c)

/-- A read kept for `ttl` seconds, by key. -/
def cached {α} (key : String) (ttl : Float) (get : Cached → Option α) (wrap : α → Cached) (fn : D α) : D α := do
  let t ← now
  let hit ← withCaches fun c => do return (← c.reads.get)[key]?
  if let some (at_, v) := hit then
    if t - at_ < ttl then
      if let some a := get v then return a
  let a ← fn
  withCaches fun c => c.reads.modify (·.insert key (t, wrap a))
  return a

def uncache (key : String) : D Unit := withCaches fun c => c.reads.modify (·.erase key)

/-! ## Items -/

def forget (repo : String) (n : Nat) : D Unit := withCaches fun c => do
  let k := itemUnit repo n
  c.items.modify (·.erase k)
  c.gens.modify fun g => g.insert k ((g[k]?.getD 0) + 1)

/-- Forget what a listing shows has changed since it was read. -/
def listed (repo : String) (items : List Issue) : D Unit := do
  let stale ← withCaches fun c => do
    let kept ← c.items.get
    return items.filter fun i => match kept[itemUnit repo i.number]? with
      | some r => r.updated != i.updatedAt
      | none => false
  for i in stale do forget repo i.number

def pruneItems : D Unit := do
  let t ← now
  let age := (← read).timings.itemMaxAge
  withCaches fun c => c.items.modify fun m => m.filter fun _ r => t - r.readAt < age

/-- An item's issue, pull request, timeline and reviews, read afresh or kept; `none` if it
doesn't exist. -/
def itemReads (repo : String) (n : Nat) : D (Option ItemRead) := do
  let e ← read
  let key := itemUnit repo n
  let (kept, gen) ← withCaches fun c => do return ((← c.items.get)[key]?, (← c.gens.get)[key]?.getD 0)
  let t ← now
  let kept := kept.filter fun r => t - r.readAt < e.timings.itemMaxAge
  let kept ← match kept with
    | some r =>
      if r.issue.isPull then
        match ← fg (e.forge.pull repo n) with
        | some p => pure (if p.updatedAt == r.updated then some { r with pull := some p } else none)
        | none => pure none
      else pure (some r)
    | none => pure none
  if let some r := kept then return some r
  let some issue ← fg (e.forge.issue repo n) | return none
  let pull ← if issue.isPull then fg (e.forge.pull repo n) else pure none
  let reviews ← if issue.isPull then fg (e.forge.reviews repo n) else pure []
  let r : ItemRead :=
    { readAt := t, updated := issue.updatedAt, issue, pull,
      timeline := ← fg (e.forge.timeline repo n),
      reviews := reviews.mergeSort (fun a b => a.id ≤ b.id) }
  withCaches fun c => do
    if e.timings.itemMaxAge > 0 && (← c.gens.get)[key]?.getD 0 == gen then
      c.items.modify (·.insert key r)
  return some r

/-! ## The rules' view of an item -/

/-- An issue or pull request, read once for all the rules. -/
structure Item where
  repo : String
  n : Nat
  /-- Read afresh, as for a webhook or a claim: so is what it waits on. -/
  fresh : Bool
  data : ItemRead
  owner : Option String
  pull : Pull

namespace Item

def issue (it : Item) : Issue := it.data.issue
def isPull (it : Item) : Bool := it.issue.isPull
def isOpen (it : Item) : Bool := it.issue.isOpen
def labels (it : Item) : List String := it.issue.labels
def has (it : Item) (label : String) : Bool := it.labels.contains label
def author (it : Item) : String := it.issue.author
def kind (it : Item) : String := if it.isPull then "pull request" else "issue"
def at_ (it : Item) : String := itemUnit it.repo it.n
def head (it : Item) : String := it.pull.headSha
def events (it : Item) : List Entry := it.data.timeline
def reviews (it : Item) : List Review := it.data.reviews

/-- The comments, from the timeline: (id, author, body, time). -/
def comments (it : Item) : List (Nat × String × String × String) :=
  it.events.filterMap fun e => match e.event with
    | .comment id body => some (id, e.actor, body, e.time)
    | _ => none

def isComment : Event → Bool | .comment .. => true | _ => false
def isLabel : Event → Bool | .label .. => true | _ => false

/-- When `who` last did anything here (of the timeline's kinds `kinds` accepts), reviews
included; 0 if never. -/
def by_ (it : Item) (who : String) (kinds : Event → Bool := fun _ => true) : Float :=
  let ts := (it.events.filter fun e => e.actor == who && kinds e.event).map (Time.when ·.time) ++
    ((it.reviews.filter fun r => r.author == who && !r.submittedAt.isEmpty).map (Time.when ·.submittedAt))
  ts.foldl max 0

/-- When a label was last added (or removed), with who did it. -/
def labelEvent (it : Item) (label : String) (added := true) : Option Entry :=
  (it.events.filter fun e => match e.event with
    | .label l a => l == label && a == added
    | _ => false).getLast?

/-- The agent this item waits on, with the comment that says so. The latest `Waiting-on:` line
from a trusted account decides, and the wait holds until the agent it names acts here. A name
that isn't an agent's, or the writer's own, says nothing. -/
def waitingOn (e : Env) (it : Item) : Option (String × Nat × String × String × String) :=
  go it.comments.reverse
where
  go : List (Nat × String × String × String) → Option (String × Nat × String × String × String)
    | [] => none
    | (c@(_, who, body, time)) :: rest =>
      let names := if e.trusted who then Text.waitingOn body else []
      match names.getLast? with
      | some name =>
        if e.isAgent name && name != who && it.by_ name < Time.when time then some (name, c) else none
      | none => go rest

/-- The `Released in vX.Y.Z` comments, from the gatekeeper, the human or the owner, oldest first,
as (time, tag). -/
def released (e : Env) (it : Item) : List (String × String) :=
  it.comments.filterMap fun (_, who, body, time) =>
    if who == e.gatekeeper || who == e.human || some who == it.owner then
      (releasedIn body).map (time, ·)
    else none

/-- The latest schedule or cancellation decides. -/
def mergeScheduled (it : Item) : Bool :=
  match (it.events.filter fun e => match e.event with
    | .scheduleMerge | .cancelScheduledMerge => true | _ => false).getLast? with
  | some { event := .scheduleMerge, .. } => true
  | _ => false

/-- Everyone a review was requested from, code owners included, and not since unrequested. -/
def requested (it : Item) : List String :=
  it.events.foldl (fun acc e => match e.event with
    | .reviewRequest who removed =>
      if who.isEmpty then acc else if removed then acc.erase who else if acc.contains who then acc else acc ++ [who]
    | _ => acc) []

/-- Each reviewer's latest approval or request for changes that stands. -/
def verdicts (it : Item) : List (String × Review) :=
  it.reviews.foldl (fun acc r =>
    if (r.verdict == .approve || r.verdict == .requestChanges) && !r.dismissed then
      (acc.filter (·.1 != r.author)) ++ [(r.author, r)]
    else acc) []

end Item

/-- An item as the rules read it, or `none` if it doesn't exist. With `fresh`, read afresh. -/
def readItem (repo : String) (n : Nat) (fresh := false) : D (Option Item) := do
  if fresh then forget repo n
  let some r ← itemReads repo n | return none
  let e ← read
  let pull := r.pull.getD
    { number := n, isOpen := r.issue.isOpen, merged := false, title := r.issue.title, body := r.issue.body,
      author := r.issue.author, headSha := "", headRef := "", baseRef := "", mergeable := none,
      requestedReviewers := [], createdAt := r.issue.createdAt, updatedAt := r.issue.updatedAt, mergedAt := none }
  return some { repo, n, fresh, data := r, owner := e.owner? repo, pull }

/-- The paths a pull request changes at its head, read when a rule first asks. -/
def Item.files (it : Item) : D (List String) := do
  match it.data.files.lookup it.head with
  | some fs => return fs
  | none =>
    let fs ← fg ((← forge).pullFiles it.repo it.n)
    withCaches fun c => c.items.modify fun m => match m[it.at_]? with
      | some r => if r.updated == it.data.updated then m.insert it.at_ { r with files := (it.head, fs) :: r.files } else m
      | none => m
    return fs

/-! ## Reading the forge -/

inductive CiState where
  | success | failure | running | none
  deriving BEq, Repr, Inhabited

/-- CI as branch protection sees it, from the statuses whose context starts with `checks`, and
when they last changed (0 if there are none). -/
def ciSettled (repo sha : String) : D (CiState × Float) := do
  let st ← fg ((← forge).statuses repo sha)
  let checks := st.filter (·.context.startsWith "checks")
  let at_ := (checks.map (Time.when ·.updatedAt)).foldl max 0
  if checks.isEmpty then return (.none, at_)
  if checks.any fun s => s.state == .failure || s.state == .error then return (.failure, at_)
  -- A job skipped by its condition, such as macos where no runner serves it, passes, as the
  -- forge's combined status has it.
  if checks.all fun s => s.state == .success || s.state == .warning || s.state == .other "skipped" then
    return (.success, at_)
  return (.running, at_)

def ciState (repo sha : String) : D CiState := do return (← ciSettled repo sha).1

def Item.ci (it : Item) : D CiState := do
  if (← read).hasCi it.repo then ciState it.repo it.head else return .none

/-- When nothing last stood in the way of merging it, or `none` while something does: CI passed
on the head, where the repository has CI; no conflict; no request for changes standing; everyone a
review was requested from approved the head; at least one approval. Ready since the latest of
those approvals, the last push and the merge's scheduling. -/
def Item.readySince (it : Item) : D (Option Float) := do
  if it.pull.mergeable != some true then return none
  if (← read).hasCi it.repo then
    if (← it.ci) != CiState.success then return none
  let vs := it.verdicts
  if vs.any fun (_, r) => r.verdict == .requestChanges then return none
  let approved := vs.filter fun (_, r) => r.commit == it.head
  if approved.isEmpty || it.requested.any (fun w => !(approved.any (·.1 == w))) then return none
  let ts := approved.map (fun (_, r) => Time.when r.submittedAt) ++
    (it.events.filter fun e => match e.event with | .push | .scheduleMerge => true | _ => false).map (Time.when ·.time)
  return some (ts.foldl max 0)

/-- main's head commit. -/
def mainOf (repo : String) : D (Option Branch) := do
  cached s!"main:{repo}" 20 (fun | .branch b => some b | _ => none) .branch
    (do fg ((← forge).branch repo "main"))

/-- The newest published release. -/
def latestRelease (repo : String) : D (Option Release) := do
  cached s!"release:{repo}" 20 (fun | .release r => some r | _ => none) .release
    (do return (← fg ((← forge).releases repo)).find? (!·.draft))

/-- The highest release tag, as the gatekeeper finds it. -/
def lastTag (repo : String) : D (Option (String × Version)) := do
  cached s!"tag:{repo}" 20 (fun | .tag t => some t | _ => none) .tag
    (do return (Gatekeeper.lastTag (← fg ((← forge).tags repo))).map fun (t, v) => (t.name, v))

/-- The release tag at main's head, if main has nothing since its last release: whatever has merged
is in that release. -/
def tagAtMain (repo : String) : D (Option String) := do
  let some main ← mainOf repo | return none
  cached s!"tagat:{repo}:{main.sha}" 20 (fun | .text s => some s | _ => none) .text do
    return (Gatekeeper.lastTag (← fg ((← forge).tags repo))).bind fun (t, _) =>
      if t.sha == main.sha then some t.name else none

def fileText (repo path ref : String) : D (Option String) := do fg ((← forge).file repo path ref)

/-- CHANGELOG.md's newest heading on main, if it is above the last release's tag (or there is
none): work merged and described, waiting for a release. -/
def unreleasedEntry (repo : String) : D (Option String) := do
  cached s!"unreleased:{repo}" 60 (fun | .text s => some s | _ => none) .text do
    let some text ← fileText repo "CHANGELOG.md" "main" | return none
    let some top := changelogTop text | return none
    match ← lastTag repo with
    | some (_, last) => return if Gatekeeper.Version.lt last top then some (Gatekeeper.Version.tag top) else none
    | none => return some (Gatekeeper.Version.tag top)

/-- If CHANGELOG.md's newest heading on main is the last release's: its tag, and whether lines
were added under it after the tag. -/
def releasedTop (repo : String) : D (Option (String × Bool)) := do
  let some (tag, v) ← lastTag repo | return none
  let some text ← fileText repo "CHANGELOG.md" "main" | return none
  if changelogTop text != some v then return none
  let then_ ← fileText repo "CHANGELOG.md" tag
  return some (tag, topSection text != (then_.bind topSection))

/-- The version the gatekeeper would give a release of main now, if it can be told. -/
def expectedVersion (repo : String) : D (Option String) := do
  let some main ← mainOf repo | return none
  let last ← lastTag repo
  let tag := (last.map (·.1)).getD ""
  cached s!"expected:{repo}:{tag}:{main.sha}" 3600 (fun | .text s => some s | _ => none) .text do
    let some lock ← fileText repo "API.lock" main.sha | return none
    let old ← match last with
      | some (t, _) => fileText repo "API.lock" t
      | none => pure none
    return some (Gatekeeper.Version.tag (Version.next (last.map (·.2)) (old.getD "") lock))

/-- Whether code owners on main give `API.lock` to the coordinator. -/
def atLevel3 (repo : String) : D Bool := do
  let some coord := (← read).coordinator? | return false
  cached s!"level3:{repo}" 300 (fun | .flag b => some b | _ => none) .flag do
    let text ← fileText repo s!"{(← read).config.forgeDir}CODEOWNERS" "main"
    return (text.map (Text.level3 · coord)).getD false

/-- The issues on `repo` a pull request refers to with `Refs` or "part of", in its title, its
description or its commits. -/
def prRefsOf (repo : String) (p : Pull) : D (List Nat) := do
  let e ← read
  cached s!"refs:{repo}:{p.number}:{p.headSha}:{p.title}:{p.body}" 3600 (fun | .nats ns => some ns | _ => none) .nats do
    let texts := [p.title, p.body] ++ (← fg (e.forge.pullCommits repo p.number))
    let found := texts.flatMap Text.prRefs |>.filterMap fun r =>
      let here := match r.org, r.repo with
        | some o, some rp => o.toLower == e.org.toLower && rp == repo
        | _, _ => true
      if here && r.n != p.number then some r.n else none
    return found.eraseDups

/-- The owner's pull requests on `repo`, open or the last twenty merged, each with the issues it
refers to. -/
def ownerPrs (repo owner : String) (merged : Bool) : D (List (Pull × List Nat)) := do
  let key := s!"prs:{repo}:{if merged then "merged" else "open"}"
  cached key 30 (fun | .prs ps => some ps | _ => none) .prs do
    let ps ← fg ((← forge).pulls repo (if merged then .closed else .open))
    let ps := if merged then (ps.filter (·.merged)).take 20 else ps
    (ps.filter (·.author == owner)).mapM fun p => do return (p, ← prRefsOf repo p)

/-- The issues on `repo` that open pull requests, anyone's, refer to. -/
def openRefs (repo : String) : D (List Nat) := do
  cached s!"openrefs:{repo}" 30 (fun | .nats ns => some ns | _ => none) .nats do
    let ps ← fg ((← forge).pulls repo .open)
    return (← ps.mapM (prRefsOf repo)).flatten.eraseDups

/-- Whether a repository, or its main, doesn't exist (yet). -/
def forgeMissing (repo : String) : D Bool := do
  let f ← forge
  if !(← fg (f.repoExists repo)) then return true
  return (← fg (f.branch repo "main")).isNone

end Guild.Dispatcher

namespace Guild.Dispatcher

/-- The forge as the dispatcher uses it: what it writes to an item, it reads afresh. -/
def Env.forgetWrites (e : Env) : Env :=
  let f := e.forge
  let after {α} (repo : String) (n : Nat) (m : Forge.M α) : Forge.M α := do
    let a ← m
    (forget repo n).run e
    return a
  { e with forge := { f with
      setAssignees := fun r n as => after r n (f.setAssignees r n as),
      close := fun r n => after r n (f.close r n),
      addLabel := fun r n l => after r n (f.addLabel r n l),
      removeLabel := fun r n l => after r n (f.removeLabel r n l),
      comment := fun r n b => after r n (f.comment r n b),
      requestReviewers := fun r n ws => after r n (f.requestReviewers r n ws),
      review := fun r n v b c => after r n (f.review r n v b c),
      merge := fun r n s => after r n (f.merge r n s),
      cancelMerge := fun r n => after r n (f.cancelMerge r n) } }

end Guild.Dispatcher
