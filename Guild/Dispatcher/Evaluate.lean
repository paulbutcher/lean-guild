/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
module

public import Guild.Dispatcher.Rules
public import Guild.Dispatcher.Obligations
public import Guild.Core.Rerun

/-! Evaluation: each unit's state from its facts, what its holders owe, and what its items ask. A
webhook only says which units to evaluate again; a sweep evaluates them all, so nothing is lost
to a missed webhook; a claim evaluates again the units behind its work. Nothing is owed because of
an event, only because of a state. -/

@[expose] public section

namespace Guild.Dispatcher

open Guild.Forge Text

/-- Kinds of notice whose state, when the notices first run on a ledger from before them, was
already reported: recorded as handled. -/
def seedKinds : List String := ["upstream-comment", "rejected", "filed", "pr-opened", "nh", "upstream-blocking"]

/-- Kinds of trigger the reference's event-driven rules queued, dropped once as obligations take
their place. -/
def retiredKinds : List String :=
  ["request", "comment", "review", "ci-failed", "conflicts", "unscheduled", "stuck-merge", "no-ci",
   "merged", "idle-request", "unblocked", "released", "unanswered", "unverified", "answered",
   "review-requested", "rfr", "reviewed", "conf", "conf-reply", "milestone", "mention", "overtaken",
   "closed-unreleased", "waiting", "main-failed", "milestone-done", "next-milestone", "stalled"]

def keyKind (key : String) : String := ((key.splitOn ":").head?).getD ""

def queue (o : Owed) (seed := false) : D Unit := do
  if seed && seedKinds.contains (keyKind o.key) then
    let t ← now
    (← db).atomically fun q => do
      if (← q "SELECT 1 FROM triggers WHERE agent=? AND key=?" [o.agent, o.key]).isEmpty then
        discard <| q "INSERT INTO triggers (agent, key, description, created, run_id) VALUES (?,?,?,?,-1)"
          [o.agent, o.key, o.description, t]
    return
  if o.quiet && (← busy o.agent) then return
  discard <| addTrigger o.agent o.key o.description (once := true) (notBefore := o.notBefore)

/-- Keep the index of what waits on the human in step with an item as last read. -/
def noteWaiting (repo : String) (n : Nat) (waits : Bool) : D Unit :=
  if waits then exec "INSERT OR IGNORE INTO human_waits (repo, number) VALUES (?,?)" [repo, n]
  else exec "DELETE FROM human_waits WHERE repo=? AND number=?" [repo, n]

def waitsOnYou (e : Env) (it : Item) : Bool :=
  it.isOpen && (it.issue.assignees.contains e.human || (it.isPull && it.pull.requestedReviewers.contains e.human))

/-- Record the units a unit waits on, for the loops a Blocked-by: line may close. -/
def setWaits (unit : String) (on : List String) : D Unit := do
  (← db).atomically fun q => do
    discard <| q "DELETE FROM waits WHERE unit=?" [unit]
    for u in on do discard <| q "INSERT INTO waits (unit, on_unit) VALUES (?,?)" [unit, u]

/-- Evaluate a unit again when its timer runs out: the service evaluates what `dueRechecks` gives. -/
def recheck (unit : String) (at_ : Option Float) : D Unit := do
  let some t := at_ | return
  if t ≤ (← now) then return
  withCaches fun c => c.rechecks.modify fun m => if m[unit]?.any (· ≤ t) then m else m.insert unit t

/-- The units whose timers have run out, taken off the list. -/
def dueRechecks : D (List String) := do
  let t ← now
  withCaches fun c => do
    let m ← c.rechecks.get
    let due := m.toList.filter (·.2 ≤ t) |>.map (·.1)
    c.rechecks.set (due.foldl (·.erase ·) m)
    return due

def hasLabel (repo name : String) : D Bool := do
  let ls ← cached s!"labels:{repo}" 3600 (fun | .names ns => some ns | _ => none) .names
    (do fg ((← forge).labels repo))
  return ls.contains name

/-- Keep the `blocked` label in step with the Blocked-by: lines; with none left, the dispatcher's
own label comes off. -/
def setBlocked (it : Item) (blocked : Option Bool) : D Unit := do
  let e ← read
  let blocked := if blocked.isNone && it.isOpen && staleBlocked e it then some false else blocked
  let some b := blocked | return
  if !it.isOpen || b == it.has "blocked" then return
  unless ← hasLabel it.repo "blocked" do return
  if b then fg (e.forge.addLabel it.repo it.n "blocked") else fg (e.forge.removeLabel it.repo it.n "blocked")
  log s!"{if b then "labelled" else "unlabelled"} {it.at_} blocked"

/-- Keep `blocking` on an open upstream issue in step with the open items whose Blocked-by: lines
name it: an agent waits on it, so it waits on the human. -/
def keepBlocking (repo : String) (n : Nat) : D Unit := do
  let e ← read
  let some r ← itemReads repo n | return
  if !r.issue.isOpen || !r.issue.labels.contains "upstream" then return
  let mut want := false
  for d in ← q "SELECT repo, number FROM blocked_by WHERE on_repo=? AND on_number=?" [repo, n] do
    if let some dr ← itemReads (d.str "repo") (d.nat "number") then
      if dr.issue.isOpen then want := true; break
  if want == r.issue.labels.contains "blocking" then return
  unless ← hasLabel repo "blocking" do return
  if want then fg (e.forge.addLabel repo n "blocking") else fg (e.forge.removeLabel repo n "blocking")
  log s!"{if want then "labelled" else "unlabelled"} {repo}#{n} blocking"

def setAssigned (repo : String) (n : Nat) (assignees : List String) (assign : Bool) : D Unit := do
  let e ← read
  if assign == assignees.contains e.human then return
  let want := if assign then assignees ++ [e.human] else assignees.filter (· != e.human)
  fg (e.forge.setAssignees repo n want)
  log s!"{if assign then "assigned" else "unassigned"} {e.human} {if assign then "to" else "from"} {repo}#{n}"

/-- The open pull requests on `repo` that refer to issue `n`. -/
def prsFor (repo : String) (n : Nat) : D (List String) := do
  let ps ← fg ((← forge).pulls repo .open)
  let refs ← ps.filterM fun p => do return (← prRefsOf repo p).contains n
  return refs.map (itemUnit repo ·.number)

/-- Property 8: CI that failed on a head with every re-run spent is the human's, since the loop of
re-runs is over and another fix is theirs to judge. Counted from the forge, once per head. -/
def checkReruns (repo : String) (n : Option Nat) (sha : String) : D Unit := do
  let e ← read
  if sha.isEmpty then return
  let limit := e.bounds.rerunLimit
  -- Read afresh: a re-run that fails again within a minute must be counted.
  let reruns ← fg (e.forge.reruns repo sha)
  unless Rerun.spent limit (reruns + 1) do return
  let text := s!"CI failed on {(sha.take 12).toString} after {limit} re-run{if limit == 1 then "" else "s"}, the limit: running it again won't help, and the cause is outside what an agent should keep trying. Look at its logs."
  match n with
  | some k => notify s!"reruns:{repo}#{k}:{sha}" "reruns" repo k text
  | none => discard <| addNotice s!"reruns:{repo}:{sha}" "reruns" (some repo) none s!"{repo}'s main: {text}"

/-! ## Units -/

structure ItemOwes where
  owes : List Owe
  owed : List Owed
  blocked : Option Bool
  found : List ((String × Nat) × String)

/-- Everything owed on an item: its obligations and its notices, whether it is blocked, and what
its lines name. -/
def owedOn (it : Item) : D ItemOwes := do
  let b ← blockedRules it
  let label := s!"{it.kind} {it.at_}"
  let (owes, who, waitsOn) ← if it.isPull then do
      let (f, who) ← pullFacts it b
      if f.isOpen && f.ci == .failure then checkReruns it.repo (some it.n) it.head
      let s := Pull.state f
      pure (← stateOwes it.at_ "pull request" s s.name.label who label, who, [])
    else do
      let (f, who) ← issueFacts it b
      let s := Issue.state f
      let on ← match s.name with
        | .inProgress => prsFor it.repo it.n
        | .ready => pure [s!"release:{it.repo}"]
        | _ => pure []
      pure (← stateOwes it.at_ (kindLabel f.kind) s s.name.label who label, who, on)
  setWaits it.at_ waitsOn
  let asked := (← asks it).map fun (a, what, d) => ({ agent := a, what, description := d, quiet := false } : Owe)
  recheck it.at_ who.recheck
  return { owes := owes ++ asked, owed := b.owed ++ (← notices it), blocked := b.blocked, found := b.found }

/-- What one item owes now: its obligations, and its notices queued; its `blocked` label and the
index of what it waits on kept. With `fresh` it is read afresh, as for a webhook or a claim. The
item, if it exists. -/
def evaluateOne (repo : String) (n : Nat) (seed := false) (fresh := true) : D (Option Item) := do
  let e ← read
  let some it ← readItem repo n fresh | do
    noteWaiting repo n false
    sync (itemUnit repo n) []
    setWaits (itemUnit repo n) []
    return none
  noteWaiting repo n (waitsOnYou e it)
  let o ← owedOn it
  -- Only an open item waits: a closed one's lines block nothing.
  let nowOn := if it.isOpen then o.found.map (·.1) else []
  let wasOn ← (← db).atomically fun q => do
    let was ← q "SELECT on_repo, on_number FROM blocked_by WHERE repo=? AND number=?" [repo, n]
    discard <| q "DELETE FROM blocked_by WHERE repo=? AND number=?" [repo, n]
    for (r, k) in nowOn do
      discard <| q "INSERT INTO blocked_by (repo, number, on_repo, on_number) VALUES (?,?,?,?)" [repo, n, r, k]
    return was.toList.map fun d => (d.str "on_repo", d.nat "on_number")
  setBlocked it o.blocked
  for b in (wasOn.filter (!nowOn.contains ·)) ++ (nowOn.filter (!wasOn.contains ·)) do
    try keepBlocking b.1 b.2 catch err => log s!"keeping blocking on {b.1}#{b.2} failed: {err}"
  for x in o.owed do queue x seed
  sync it.at_ o.owes
  return some it

/-- An item, then the items waiting on it and the issues a pull request refers to. -/
def evaluate (repo : String) (n : Nat) (seed := false) (fresh := true) : D Unit := do
  let some it ← evaluateOne repo n seed fresh | return
  if it.isPull then
    -- A pull request opened or merged changes what the requests it refers to owe.
    for k in [s!"prs:{repo}:open", s!"prs:{repo}:merged", s!"openrefs:{repo}"] do uncache k
    for k in ← prRefsOf repo it.pull do
      try discard <| evaluateOne repo k (fresh := false)
      catch err => log s!"evaluating {repo}#{k} failed: {err}"
  for d in ← q "SELECT repo, number FROM blocked_by WHERE on_repo=? AND on_number=?" [repo, n] do
    try discard <| evaluateOne (d.str "repo") (d.nat "number") (fresh := false)
    catch err => log s!"evaluating {d.str "repo"}#{d.nat "number"} failed: {err}"

def openItems (repo : String) : D (List Forge.Issue) := do
  fg ((← forge).issues repo { which := .open, kinds := .all })

/-- What a repository's release owes now. -/
def evaluateRelease (repo : String) : D Unit := do
  let e ← read
  if (e.owner? repo).isNone || !e.hasCi repo then return
  let unit := s!"release:{repo}"
  let items ← openItems repo
  listed repo items
  let (f, who, ready) ← releaseFacts repo items
  if f.mainCi == .failure then
    if let some m ← mainOf repo then checkReruns repo none m.sha
  let s := Release.state f
  sync unit (← stateOwes unit "release" s s.name.label who s!"the release of {repo}")
  setWaits unit (if s.name == .held then ready.map (·.at_) else [])
  recheck unit who.recheck

/-- What each milestone, and the kit itself, owes now. -/
def evaluateMilestones : D Unit := do
  let e ← read
  let some coord := e.coordinator? | return
  if ← forgeMissing e.coordination then return
  let mut byTitle : List (String × List (String × Forge.Milestone)) := []
  for repo in e.repos do
    if ← forgeMissing repo then continue
    for m in ← fg (e.forge.milestones repo) do
      byTitle := match byTitle.lookup m.title with
        | some spans => (byTitle.filter (·.1 != m.title)) ++ [(m.title, spans ++ [(repo, m)])]
        | none => byTitle ++ [(m.title, [(repo, m)])]
  let issues ← fg (e.forge.issues e.coordination { which := .all, kinds := .issues, labels := ["milestone"] })
  let mut seen : List String := []
  for (title, spans) in byTitle do
    let mine := issues.filter fun i => i.labels.contains "milestone" &&
      (i.title == s!"Milestone: {title}" || i.milestone == some title)
    let f : Milestone.Facts :=
      { closed := spans.all (!·.2.isOpen), openWork := spans.any (·.2.openIssues > 0),
        hadWork := spans.any (·.2.closedIssues > 0),
        issue := if mine.isEmpty then .none else if mine.any (·.isOpen) then .isOpen else .closed }
    let unit := s!"milestone:{title}"
    seen := unit :: seen
    let repos := ((spans.filter (·.2.isOpen)).map (·.1)).eraseDups.mergeSort (· ≤ ·)
    let who : Who := { roles := [(.owner, [coord]), (.coordinator, [coord])],
                       notes := [(.coordinator, if repos.isEmpty then "" else s!" (open on {", ".intercalate repos})")] }
    let s := Milestone.state f
    sync unit (← stateOwes unit "milestone" s s.name.label who s!"milestone {title}")
  for r in ← q "SELECT DISTINCT unit FROM obligations WHERE unit LIKE 'milestone:%'" do
    unless seen.contains (r.str "unit") do sync (r.str "unit") []
  let every := byTitle.flatMap (·.2.map (·.2))
  let roadmap := (← fileText e.coordination "ROADMAP.md" "main").getD ""
  let open_ ← fg (e.forge.issues e.coordination { which := .open, kinds := .issues })
  let decisions := open_.filter fun i => i.assignees.contains e.human && i.author == coord &&
    !i.labels.contains "recommendation" && !i.labels.contains "milestone"
  let f : Kit.Facts :=
    { milestones := if every.any (·.openIssues > 0) then .openWork
        else if every.any (·.closedIssues > 0) then .done else .noneEver,
      finished := roadmapFinished roadmap,
      planning := !(← fg (e.forge.pulls e.coordination .open)).isEmpty,
      decision := !decisions.isEmpty }
  let s := Kit.state f
  sync "kit" (← stateOwes "kit" "kit" s s.name.label { roles := [(.owner, [coord]), (.coordinator, [coord])] } "the project")

/-- Evaluate a unit again, without its dependents. -/
def evaluateUnit (unit : String) : D Unit := do
  match unit.splitOn "#" with
  | [repo, n] =>
    match n.toNat? with
    | some k => discard <| evaluateOne repo k
    | none => evaluateMilestones
  | _ =>
    if unit.startsWith "release:" then evaluateRelease (unit.drop 8).toString
    else evaluateMilestones

/-- Move on every obligation that may be due. -/
def wakeDue : D Unit := do
  for r in ← q "SELECT id FROM obligations WHERE escalated=0 ORDER BY id" do
    try advance evaluateUnit (r.nat "id")
    catch err => log s!"moving obligation {r.nat "id"} on failed: {err}"

/-- A repository's release, and with `items`, its open issues and pull requests. -/
def evaluateRepo (repo : String) (items := false) (seed := false) : D Unit := do
  evaluateRelease repo
  unless items do return
  let open_ ← openItems repo
  listed repo open_
  for i in open_ do
    try discard <| evaluateOne repo i.number seed (fresh := false)
    catch err => log s!"evaluating {repo}#{i.number} failed: {err}"
  -- Only an open item waits on the human: one that closed with no webhook to say so leaves the index.
  for r in ← q "SELECT number FROM human_waits WHERE repo=?" [repo] do
    unless open_.any (·.number == r.nat "number") do noteWaiting repo (r.nat "number") false

/-- Every repository's release and open items, issues closed lately (a rejected request),
upstream issues' `blocking`, the human's assignments, the milestones and the kit: what a missed
webhook would have lost, and what no webhook brings. Whether it all went through. -/
def sweep (seed := false) : D Bool := do
  let e ← read
  pruneItems
  let last ← kvFloat "reconciled"
  let since := Time.iso (max (last - e.timings.reconcile) ((← now) - 86400))
  let mut ok := true
  for repo in e.repos do
    try
      if ← forgeMissing repo then
        log s!"{repo} is configured but not in the forge (or has no main): skipped"
        continue
      evaluateRepo repo (items := true) seed
      let closed ← fg (e.forge.issues repo { which := .closed, kinds := .issues, since := some since })
      listed repo closed
      for i in closed do discard <| evaluateOne repo i.number seed (fresh := false)
      let upstream ← fg (e.forge.issues repo { which := .open, kinds := .issues, labels := ["upstream"] })
      listed repo upstream
      for i in upstream do keepBlocking repo i.number
      -- What waits on the human but isn't assigned to them: from before assignment, or a missed webhook.
      for i in ← openItems repo do
        if waitsOnHuman i.labels then setAssigned repo i.number i.assignees true
    catch err =>
      ok := false
      log s!"sweeping {repo} failed: {err}"
  try evaluateMilestones
  catch err =>
    ok := false
    log s!"evaluating the milestones failed: {err}"
  kvSet "reconciled" (toString (← now))
  return ok

/-- Once, on a ledger from before the states: the work the old rules queued and no run has taken
is dropped, since obligations take its place. -/
def retireRuleTriggers : D Unit := do
  if (← kvGet "obligations-started").isSome then return
  let rows := (← q "SELECT id, key FROM triggers WHERE run_id IS NULL").toList.filter fun r =>
    retiredKinds.contains (keyKind (r.str "key"))
  for r in rows do exec "UPDATE triggers SET run_id=-1 WHERE id=?" [r.get "id"]
  kvSet "obligations-started" (toString (← now))
  unless rows.isEmpty do log s!"dropped {rows.length} trigger(s) the old rules queued: obligations take their place"

/-- The first sweep on a new ledger records what the notices find as handled. -/
def reconcile : D Unit := do
  retireRuleTriggers
  if (← kvGet "rules-seeded").isNone then
    if ← sweep (seed := true) then
      kvSet "rules-seeded" (toString (← now))
      log "the rules' first sweep is done: from now on they queue work"
  else discard sweep

/-- The ids of queued triggers, among obligations and notices, that are no longer owed: the pull
request merged meanwhile, the comment was answered, the head moved on. Each unit behind them is
evaluated again first. -/
def noLongerOwed (rows : List Row) : D (List Nat) := do
  let mut units : List (String × List (Row × Nat)) := []
  let mut items : List ((String × Nat) × List Row) := []
  for r in rows do
    let key := r.str "key"
    if key.startsWith "owe:" then
      let parts := ((key.drop 4).toString.splitOn ":")
      let unit := ":".intercalate (parts.dropLast.dropLast)
      let some i := (parts.dropLast.getLast?).bind String.toNat? | continue
      units := match units.lookup unit with
        | some rs => (units.filter (·.1 != unit)) ++ [(unit, rs ++ [(r, i)])]
        | none => units ++ [(unit, [(r, i)])]
      continue
    let parts := key.splitOn ":"
    if let [kind, at_] := parts.take 2 then
      if ruleKinds.contains kind && parts.length ≥ 3 then
        if let [repo, n] := at_.splitOn "#" then
          if let some k := n.toNat? then
            items := match items.lookup (repo, k) with
              | some rs => (items.filter (·.1 != (repo, k))) ++ [((repo, k), rs ++ [r])]
              | none => items ++ [((repo, k), [r])]
  let mut stale : List Nat := []
  for (unit, rs) in units do
    try evaluateUnit unit
    catch err =>
      log s!"couldn't check {unit} is still owed: {err}"
      continue
    for (r, i) in rs do
      match ← obligation i with
      | some o => if o.int "escalated" != 0 || o.nat? "trigger" != r.nat? "id" then stale := stale ++ [r.nat "id"]
      | none => stale := stale ++ [r.nat "id"]
  for ((repo, n), rs) in items do
    try
      let keys ← match ← readItem repo n (fresh := true) with
        | some it => do pure (((← blockedRules it).owed ++ (← notices it)).map (·.key))
        | none => pure []
      stale := stale ++ (rs.filter fun r => !keys.contains (r.str "key")).map (·.nat "id")
    catch err => log s!"couldn't check {repo}#{n} is still owed: {err}"
  return stale

/-- An agent's run has ended: what it left its open pull requests and accepted requests owing was
held while it could still act on them. -/
def evaluateAfterRun (agent : String) : D Unit := do
  let e ← read
  let some repo := (e.agent? agent).bind (·.owns) | return
  if (e.owner? repo).isNone || (← mayPush agent) then return
  for k in [s!"prs:{repo}:open", s!"prs:{repo}:merged"] do uncache k
  let mine := (← ownerPrs repo agent false).map (·.1.number)
  let accepted := (← fg (e.forge.issues repo { which := .open, kinds := .issues, labels := ["accepted"] })).map (·.number)
  for n in mine ++ accepted do
    try discard <| evaluateOne repo n
    catch err => log s!"evaluating {repo}#{n} failed: {err}"

def evaluateLabelled (repo name : String) : D Unit := do
  for i in ← fg ((← forge).issues repo { which := .open, kinds := .all, labels := [name] }) do
    try discard <| evaluateOne repo i.number
    catch err => log s!"evaluating {repo}#{i.number} failed: {err}"

end Guild.Dispatcher
