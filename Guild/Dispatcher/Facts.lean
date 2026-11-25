/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
module

public import Guild.Dispatcher.Item
public import Guild.Core.Issue
public import Guild.Core.Pull
public import Guild.Core.Release
public import Guild.Core.Milestone
public import Guild.Core.Kit

/-! What the states read, from the forge: each unit's facts, reduced to the core's types, and who
each of its roles is. -/

@[expose] public section

namespace Guild.Dispatcher

open Guild.Forge Text

/-- Who each of a unit's roles is, what each is told beyond its state's step, and when a timer it
waits on runs out. -/
structure Who where
  roles : List (Role × List String) := []
  notes : List (Role × String) := []
  recheck : Option Float := none
  deriving Inhabited

def Who.get (w : Who) (r : Role) : List String := (w.roles.lookup r).getD []
def Who.note (w : Who) (r : Role) : String := (w.notes.lookup r).getD ""

/-- Something an item asks an agent to look at, once. -/
structure Owed where
  agent : String
  key : String
  description : String
  notBefore : Option Float := none
  quiet : Bool := false
  deriving Inhabited, Repr

def waitsOnHuman (labels : List String) : Bool :=
  labels.contains "needs-human" || (labels.contains "upstream" && labels.contains "blocking")

/-! ## Blocked-by lines -/

/-- The texts a trusted account wrote on the item: (writer, time, text). -/
def trustedTexts (e : Env) (it : Item) : List (String × String × String) :=
  (if e.trusted it.author then [(it.author, it.issue.createdAt, it.issue.body)] else []) ++
  (it.comments.filter fun (_, who, _, _) => e.trusted who).map fun (_, who, body, time) => (who, time, body)

/-- Every Blocked-by: line naming a project repository, oldest first: (repo, n, writer, time). -/
def blockedByLines (e : Env) (it : Item) : List (String × Nat × String × String) :=
  (trustedTexts e it).flatMap fun (who, time, text) =>
    (Text.blockedBy text).filterMap fun (org, r, k) =>
      if org.toLower == e.org.toLower && e.project r then some (r, k, who, time) else none

/-- The items its Blocked-by: lines name, other than itself, each with when its line was first
written. -/
def blockersOf (e : Env) (it : Item) : List ((String × Nat) × String) :=
  (blockedByLines e it).foldl (fun acc (r, k, _, time) =>
    if (r, k) == (it.repo, it.n) || acc.any (·.1 == (r, k)) then acc else acc ++ [((r, k), time)]) []

structure BlockerState where
  /-- When it stopped blocking, and why. -/
  done : Option (String × String) := none
  /-- The human's latest comment on an open upstream issue: (id, time). -/
  human : Option (Nat × String) := none

/-- When an item stopped blocking (closed, or released) and why, and for an open upstream issue,
the human's latest comment on it. An issue closed while still labelled ready-for-release blocks
until its work is released. -/
def blockerState (repo : String) (n : Nat) : D BlockerState := do
  let e ← read
  let some it ← readItem repo n | return {}
  let labels := it.labels
  let unreleased := !it.isOpen && !it.isPull && labels.contains "ready-for-release"
  if !it.isOpen && !unreleased then
    let at_ := it.issue.closedAt.getD it.issue.updatedAt
    let what := if it.isPull then s!"pull request {repo}#{n} {if it.pull.merged then "merged" else "was closed"}"
      else s!"{if labels.contains "upstream" then "upstream issue" else "issue"} {repo}#{n} was closed"
    return { done := some (at_, what) }
  for (_, who, body, time) in it.comments do
    if let some tag := releasedIn body then
      if who == e.gatekeeper || who == e.human || some who == e.owner? repo then
        return { done := some (time, s!"{repo}#{n} was released in {tag}") }
  if labels.contains "upstream" then
    let mine := it.comments.filter fun (_, who, _, _) => who == e.human
    return { human := mine.getLast?.map fun (id, _, _, time) => (id, time) }
  return {}

structure Blocked where
  /-- Notices for the owner: the human's comments on upstream issues the item waits on. -/
  owed : List Owed := []
  /-- Whether its lines block it; `none` if it names nothing. -/
  blocked : Option Bool := none
  /-- When it last stopped being blocked. -/
  unblockedAt : Option Float := none
  found : List ((String × Nat) × String) := []

/-- What an item's Blocked-by: lines say, and rule 8: the human's comment on an upstream issue it
waits on, once per comment, for its owner to read. -/
def blockedRules (it : Item) : D Blocked := do
  let e ← read
  let found := blockersOf e it
  let some owner := it.owner | return { found }
  if found.isEmpty || !it.isOpen then return { found }
  if it.fresh then
    for ((r, k), _) in found do forget r k
  let states ← found.mapM fun (b, at_) => do return (b, at_, ← blockerState b.1 b.2)
  let done := (states.filterMap fun (_, _, s) => s.done.map fun (t, w) => (Time.when t, w)).mergeSort (·.1 ≤ ·.1)
  let blocked := done.length < found.length
  let owed := states.filterMap fun ((r, k), at_, s) => s.human.bind fun (id, time) =>
    if Time.when time ≥ Time.when at_ then
      some { agent := owner, key := s!"upstream-comment:{it.at_}:{id}",
             description := s!"{e.human} commented on upstream issue {r}#{k}; {it.at_} is blocked on it" }
    else none
  return { owed, blocked := some blocked, found,
           unblockedAt := if blocked then none else done.getLast?.map (·.1) }

/-- Whether the waits from `first` lead back to `start`: the open items' Blocked-by: lines, and the
waits between units their states give. -/
def loopsBack (start first : String) : D Bool := do
  let mut seen : List String := []
  let mut todo := [first]
  for _ in [0:10000] do
    match todo with
    | [] => return false
    | cur :: rest =>
      todo := rest
      if cur == start then return true
      if seen.contains cur then continue
      seen := cur :: seen
      let next ← q "SELECT on_repo || '#' || on_number AS u FROM blocked_by WHERE repo || '#' || number = ?
        UNION SELECT on_unit AS u FROM waits WHERE unit = ?" [cur, cur]
      todo := todo ++ next.toList.map (·.str "u")
  return false

/-- The `blocked` label is the dispatcher's, left with no Blocked-by: lines to keep it. One someone
else put on stays theirs. -/
def staleBlocked (e : Env) (it : Item) : Bool :=
  it.has "blocked" && (it.labelEvent "blocked").any (·.actor == e.me)

inductive BlockerFact where
  | none | pending | done | invalid (writer : String) | bareLabel

/-- A line naming the item itself is invalid while it is the newest; one that closes a loop of
waits, while they wait. -/
def blockerFact (it : Item) (blocked : Option Bool) : D BlockerFact := do
  let e ← read
  let lines := blockedByLines e it
  if let some (r, k, who, _) := lines.getLast? then
    if (r, k) == (it.repo, it.n) then return .invalid who
  match blocked with
  | some true =>
    for (r, k, who, _) in lines do
      if (r, k) != (it.repo, it.n) then
        if ← loopsBack it.at_ (itemUnit r k) then return .invalid who
    return .pending
  | some false => return .done
  | none => return if it.has "blocked" && !staleBlocked e it then .bareLabel else .none

/-- Who does an author's part: an agent, the human, or for an outsider, whom nothing wakes, the
owner. -/
def authorOf (e : Env) (it : Item) : String :=
  if e.isAgent it.author || it.author == e.human then it.author else (it.owner.getD e.human)

/-- What holds an issue or pull request, whatever its kind, and the roles that names. -/
def holdFact (it : Item) (blocked : Option Bool) : D (Hold × List (Role × List String)) := do
  let e ← read
  let nh := it.labelEvent "needs-human"
  let hand := it.issue.assignees.contains e.human && !waitsOnHuman it.labels
  let waiting := if it.isOpen then it.waitingOn e else none
  let bf ← blockerFact it blocked
  let humanAnswered := nh.any fun n => it.by_ e.human Item.isComment > Time.when n.time
  if (it.has "needs-human" && !humanAnswered) || hand then return (.human, [])
  if it.has "upstream" && !it.isPull then return (.upstream, [])
  if let some (who, _) := waiting then return (.waiting, [(.waited, [who])])
  match bf with
  | .invalid w =>
    return (.invalid, [(.writer, [if e.isAgent w || w == e.human then w else it.owner.getD e.human])])
  | .pending => return (.blocked, [])
  | .bareLabel => return (.bareLabel, [])
  | _ => return (.none, [])

/-! ## Issues -/

def issueKind (e : Env) (it : Item) : Issue.Kind :=
  if it.repo == e.coordination && it.has "milestone-review" then .milestone
  else if it.has "recommendation" then .recommendation
  else if it.author == e.me then .kitDecision
  else if some it.author == e.coordinator? && it.issue.title == s!"Release {it.repo}" then .releaseDecision
  else if it.has "request" && some it.author != it.owner then .request
  else .task

def kindLabel : Issue.Kind → String
  | .request => "request" | .task => "task" | .milestone => "milestone"
  | .recommendation => "recommendation" | .kitDecision => "kit-decision"
  | .releaseDecision => "release-decision"

/-- Whether the owner merged work for it since it was last unblocked or accepted, and since its
latest release. -/
def mergedSince (it : Item) (unblockedAt : Option Float) : D Bool := do
  let e ← read
  let some owner := it.owner | return false
  let since := match unblockedAt with
    | some t => t
    | none => match it.labelEvent "blocked" false <|> it.labelEvent "accepted" with
      | some ev => Time.when ev.time
      | none => Time.when it.issue.createdAt
  let since := match (it.released e).getLast? with
    | some (time, _) => max since (Time.when time)
    | none => since
  let prs ← ownerPrs it.repo owner true
  return prs.any fun (p, refs) => refs.contains it.n && p.mergedAt.any (Time.when · ≥ since)

def issueFacts (it : Item) (blocked : Option Bool) (unblockedAt : Option Float) : D (Issue.Facts × Who) := do
  let e ← read
  let kind := issueKind e it
  let (hold, heldBy) ← holdFact it blocked
  let released := it.released e
  let nv := it.labelEvent "not-verified"
  let reviewers := if kind == .milestone then
      let labelled := Time.when ((it.labelEvent "milestone-review").map (·.time) |>.getD it.issue.createdAt)
      e.milestoneReviewers.filter fun r => it.by_ r Item.isComment < labelled
    else []
  let overtaken ← if kind == .releaseDecision then do
      match ← latestRelease it.repo with
      | some rel =>
        let acted := max (Time.when it.issue.createdAt) ((e.coordinator?.map (it.by_ ·)).getD 0)
        pure (rel.publishedAt.any (Time.when · > acted))
      | none => pure false
    else pure false
  let untriaged := (kind == .request && it.has "new") ||
    (some it.author != it.owner && (it.owner.map (it.by_ ·)).getD 0 == 0 &&
      !it.has "accepted" && !it.has "counter-proposal")
  let openPr := (← openRefs it.repo).contains it.n
  let merged ← if it.owner.isSome && e.hasCi it.repo then mergedSince it unblockedAt else pure false
  let notVerified := kind == .request && !released.isEmpty && it.has "not-verified" &&
    (match nv, released.getLast? with
     | some n, some (time, _) => Time.when n.time > Time.when time
     | _, _ => false)
  let f : Issue.Facts :=
    { isOpen := it.isOpen, kind, untriaged, counter := kind == .request && it.has "counter-proposal",
      hold, openPr, merged, rfr := it.has "ready-for-release", released := !released.isEmpty,
      verified := kind == .request && it.has "verified", notVerified, overtaken,
      unreported := !reviewers.isEmpty }
  let who : Who :=
    { roles := [(.owner, it.owner.toList), (.requester, [authorOf e it]),
                (.coordinator, [e.coordinator?.getD e.human]), (.reviewers, reviewers)] ++ heldBy,
      notes := match released.getLast? with
        | some (_, tag) => [(.requester, s!" (released in {tag})")]
        | none => [] }
  return (f, who)

/-! ## Pull requests -/

def pullFacts (it : Item) (blocked : Option Bool) : D (Pull.Facts × Who) := do
  let e ← read
  let t ← now
  let tm := e.timings
  let pushes := it.events.filter fun ev => match ev.event with | .push => true | _ => false
  let pushed := Time.when ((pushes.getLast?.map (·.time)).getD it.pull.createdAt)
  let (ci, late, ciAt) ← if e.hasCi it.repo then do
      let (s, at_) ← ciSettled it.repo it.head
      let late := (s == .none && t ≥ pushed + tm.noCi) || (s == .running && t ≥ max at_ pushed + tm.ciLate)
      pure ((match s with
        | .none => Pull.Ci.none | .running => .running | .failure => .failure | .success => .success), late, at_)
    else pure (.unused, false, 0)
  let verdicts := it.verdicts
  let asked := verdicts.filter fun (_, r) => r.verdict == .requestChanges
  let replied (w : String) (r : Review) : Bool :=
    let since := (it.comments.filter (·.2.1 == w)).foldl (fun m (_, _, _, time) => max m (Time.when time))
      (Time.when r.submittedAt)
    it.comments.any fun (_, who, body, time) => who == it.author && wantsReply body && Time.when time > since
  let atHead := asked.filter fun (_, r) => r.commit == it.head
  let (changes, changesBy) :=
    if !atHead.isEmpty then
      (if atHead.all fun (w, r) => replied w r then Pull.Changes.replied else .atHead, atHead.map (·.1))
    else if !asked.isEmpty then (.older, asked.map (·.1)) else (.none, [])
  let reviewer := e.reviewer?
  let authorIdle := e.isAgent it.author && !(← mayPush it.author)
  let conformance :=
    match reviewer with
    | none => Pull.Conformance.reviewed
    | some rv =>
      if it.author == rv || it.reviews.any (fun r => r.author == rv && r.commit == it.head) then .reviewed
      else if !authorIdle && t < pushed + tm.settle then .settling
      else .due
  let requested := (it.requested ++ it.pull.requestedReviewers).eraseDups
  let approved := (verdicts.filter fun (_, r) => r.verdict == .approve && r.commit == it.head).map (·.1)
  let waiting := requested.filter fun w =>
    !approved.contains w && w != it.author && (e.isAgent w || w == e.human)
  let ready ← if it.isOpen then it.readySince else pure none
  let scheduled := it.mergeScheduled
  let checkFrom := max pushed (Time.when it.pull.updatedAt)
  let checkLate := it.pull.mergeable.isNone && t ≥ checkFrom + tm.noCi
  let times :=
    (if conformance == .settling then [pushed + tm.settle] else []) ++
    (if ci == .none && !late then [pushed + tm.noCi] else []) ++
    (if ci == .running && !late then [max ciAt pushed + tm.ciLate] else []) ++
    (if it.pull.mergeable.isNone && !checkLate then [checkFrom + tm.noCi] else []) ++
    (match ready with | some r => if scheduled then [r + tm.stuck] else [] | none => [])
  let (hold, heldBy) ← holdFact it blocked
  let f : Pull.Facts :=
    { isOpen := it.isOpen, hold, wip := wip it.pull.title, ci, ciLate := late,
      mergeable := match it.pull.mergeable with | some true => .yes | some false => .no | none => .unknown,
      checkLate, changes, conformance,
      pendingCoordinator := waiting.any (some · == e.coordinator?),
      pendingAgent := waiting.any fun w => e.isAgent w && some w != e.coordinator?,
      pendingHuman := waiting.contains e.human,
      approved := !approved.isEmpty, scheduled,
      stuck := scheduled && ready.any (t ≥ · + tm.stuck) }
  let level3 ← if waiting.any (some · == e.coordinator?) then atLevel3 it.repo else pure false
  let who : Who :=
    { roles := [(.owner, it.owner.toList), (.author, [authorOf e it]),
                (.coordinator, [e.coordinator?.getD e.human]), (.conformance, reviewer.toList),
                (.changesBy, changesBy),
                (.pending, (waiting.filter fun w => e.isAgent w && some w != e.coordinator?).mergeSort (· ≤ ·))] ++
               heldBy,
      notes := if waiting.any (some · == e.coordinator?) then
          [(.coordinator, if level3 then
            s!". {it.repo} is at level 3: CODEOWNERS on main gives `API.lock` to you, so it waits for your review. Approve it, request changes, or put a trade-off to the human as a decision; a comment alone leaves it waiting"
            else s!". {it.repo} is below level 3, so the human approves its `API.lock`; your review is advisory")]
        else [],
      recheck := (times.filter (· > t)).min? }
  return (f, who)

/-! ## Releases -/

def releaseFacts (repo : String) (items : List Forge.Issue) : D (Release.Facts × Who × List Item) := do
  let e ← read
  let t ← now
  let tm := e.timings
  let main ← mainOf repo
  let sha := (main.map (·.sha)).getD ""
  let (ci, ciAt) ← ciSettled repo sha
  let since := max ciAt ((main.map (Time.when ·.timestamp)).getD 0)
  let late := (ci == .none && t ≥ since + tm.noCi) || (ci == .running && t ≥ since + tm.ciLate)
  let ready ← (items.filter (·.labels.contains "ready-for-release")).filterMapM fun i => readItem repo i.number
  let held ← ready.filterM fun it => do
    let b ← blockedRules it
    return (← holdFact it b.blocked).1 != .none
  let entry ← unreleasedEntry repo
  let expected ← if entry.isSome then expectedVersion repo else pure none
  let heading : Release.Heading := match entry with
    | none => .none
    | some en => if expected.any (· != en) then .wrong else .right
  let level3 ← atLevel3 repo
  let f : Release.Facts :=
    { mainCi := match ci with | .none => .none | .running => .running | .failure => .failure | .success => .success,
      mainCiLate := late, rfr := !ready.isEmpty, heading, held := !held.isEmpty, level3,
      decision := items.any fun i => !i.isPull && some i.author == e.coordinator? && i.title == s!"Release {repo}" }
  let names := " ".intercalate (ready.map (toString ·.n))
  let ownerNote ← if heading == .wrong then
      pure s!" (`forge version` gives {expected.getD "?"}; CHANGELOG.md heads {entry.getD "?"})"
    else if (Release.state f).name == .noEntry then do
      match ← releasedTop repo with
      | some (tag, true) => pure s!" (CHANGELOG.md's newest heading, {tag}, is already released, and lines were added under it after {tag} was tagged: move them under a new heading)"
      | some (tag, false) => pure s!" (CHANGELOG.md's newest heading, {tag}, is the last release)"
      | none => pure ""
    else pure ""
  let how := if level3 then s!": `forge release {repo} '<one-line note>' {names}`".trimAsciiEnd.toString
    else s!", whose command is `scripts/release.sh {repo} '<one-line note>' {names}`".trimAsciiEnd.toString
  let what := if !ready.isEmpty then s!", completing {", ".intercalate (ready.map (·.at_))}"
    else s!"; nothing is labelled ready-for-release, but CHANGELOG.md on main heads {entry.getD "?"}, above its last release"
  let who : Who :=
    { roles := [(.owner, (e.owner? repo).toList), (.coordinator, [e.coordinator?.getD e.human])],
      notes := [(.owner, ownerNote), (.coordinator, how ++ what)],
      recheck := if (ci == .none || ci == .running) && !late then
          some (since + if ci == .none then tm.noCi else tm.ciLate) else none }
  return (f, who, ready)

end Guild.Dispatcher
