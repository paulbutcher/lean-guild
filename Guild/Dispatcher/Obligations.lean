/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
module

public import Guild.Dispatcher.Notify
public import Guild.Dispatcher.Facts
public import Guild.Core.Obligation
public import Guild.Core.Holder
public import Guild.Core.Budget

/-! Obligations: each agent that owes something on a unit has one row per state it holds there or
ask it hasn't answered. It is discharged as soon as the unit no longer owes it. Until then it
moves on as `Obligation.step` says each time it is due: it wakes its agent, again after each run
it woke ends with it standing, spaced by the backoff, and then it is the human's, as a `Stalled:`
decision with the supervisor woken to find out why. A quiet one lets at most `patience` runs of its
busy agent go ahead of it. A wake counts once its run has ended, so an outage, a cap or a pause,
which hold the run back, uses up nothing. -/

@[expose] public section

namespace Guild.Dispatcher

/-- What an agent owes on a unit. -/
structure Owe where
  agent : String
  what : String
  description : String
  quiet : Bool
  deriving Inhabited, Repr

/-- Python's `json.dumps` of a list of names, as the units table keeps holders. -/
def namesJson (names : List String) : String :=
  "[" ++ ", ".intercalate (names.map Json.renderString) ++ "]"

/-- The agents (or the human) a role names on a unit, as the units table records them. -/
def resolveNames (e : Env) (who : Who) (r : Role) : List String :=
  let toHolder (n : String) : Holder := if n == e.human then .human else .agent n
  (Guild.resolve (fun role => ((who.get role).filter (!·.isEmpty)).map toHolder) r).map fun
    | .agent n => n
    | .human => Role.human.label
    | .other role => role.label

/-- Record a unit's state, and return what its agent holders owe, each described as
`<label> (<state>): <step>`. -/
def stateOwes {N} (unit kind : String) (s : State N) (name : String) (who : Who) (label : String) : D (List Owe) := do
  let e ← read
  let holders := (s.holders.flatMap (resolveNames e who)).eraseDups.mergeSort (· ≤ ·)
  let t ← now
  let encoded := namesJson holders
  e.db.atomically fun q => do
    let row ← q "SELECT state, holders FROM units WHERE unit=?" [unit]
    if row[0]?.any fun r => r.str "state" == name && r.str "holders" == encoded then
      discard <| q "UPDATE units SET seen=? WHERE unit=?" [t, unit]
    else
      discard <| q "INSERT OR REPLACE INTO units (unit, kind, state, holders, step, since, seen) VALUES (?,?,?,?,?,?,?)"
        [unit, kind, name, encoded, s.step, t, t]
  return s.holders.flatMap fun role =>
    (resolveNames e who role).filterMap fun a =>
      if e.isAgent a then some { agent := a, what := name, quiet := s.quiet,
                                 description := s!"{label} ({name}): {s.step}{who.note role}" }
      else none

def obligation (i : Nat) : D (Option Row) := do return (← q "SELECT * FROM obligations WHERE id=?" [i])[0]?

/-- A unit's page in the forge, as the human's browser reaches it. -/
def unitLink (unit : String) : D String := do
  let e ← read
  match unit.splitOn "#" with
  | [repo, n] => if n.all Char.isDigit && !n.isEmpty then return s!"{e.forgeWeb}/{e.org}/{repo}/issues/{n}" else
      return s!"{e.forgeWeb}/{e.org}/{e.coordination}/milestones"
  | _ =>
    if unit.startsWith "release:" then return s!"{e.forgeWeb}/{e.org}/{(unit.drop 8).toString}"
    return s!"{e.forgeWeb}/{e.org}/{e.coordination}/milestones"

def stalledKey (r : Row) : String :=
  s!"stalled:{r.str "unit"}:{r.str "what"}:{r.str "agent"}:{(r.real "since").floor.toUInt64}"

/-- An obligation its agent was woken for its every try without it going away: the human's, and
the supervisor's to find out why. -/
def escalate (r : Row) : D Unit := do
  let e ← read
  exec "UPDATE obligations SET escalated=1 WHERE id=?" [r.get "id"]
  let unit := r.str "unit"
  let agent := r.str "agent"
  let wakes := r.nat "wakes"
  let link ← unitLink unit
  decisionIssue e.coordination (stalledKey r) "stalled" s!"Stalled: {unit}" [
    ("Question", s!"`{agent}` was woken {wakes} times for [{unit}]({link}), and it still owes the same: {r.str "description"}. What should happen?"),
    ("Options", s!"- Find out why: the kit's activity for {unit} and for `{agent}` shows what happened; if the kit lacks a step, fix the kit.\n- Tell `{agent}` on the item what to do.\n- Close the item, saying why."),
    ("Recommendation", "Find out why first: an agent that can't do a step should say what it waits for in a way the kit can see, and one that doesn't is a gap in the protocol or its role." ++
      (if e.supervisor?.isSome then " The supervisor has been woken to look into it too." else "")),
    ("If you say go ahead", s!"Nothing changes by itself: say on the item what should happen, then close this issue. The kit doesn't wake anyone for it again until what it owes changes. If `{agent}` no longer owes it before you act, the kit says so here and closes this issue."),
    ("Blocked on this", s!"{unit}.")]
  log s!"{agent} was woken {wakes} times for {unit} ({r.str "what"}): it is the human's"
  if let some sup := e.supervisor? then
    if sup != agent && (← capped sup).isNone then
      discard <| addTrigger sup s!"supervise:{unit}:{r.nat "id"}"
        s!"{unit} has stalled: {agent} was woken {wakes} times for it without it moving on, and it is now a decision for the human. What it owes: {r.str "description"}. Find out why, move it on if you can, and report the gap (Role: Supervision)"

/-- An escalated obligation that went away: its `Stalled:` decision is closed, saying so, unless
the human closed it already. -/
def unstall (r : Row) : D Unit := do
  let e ← read
  let rows ← q "SELECT number FROM notices WHERE key=? AND posted=1" [stalledKey r]
  let some n := rows[0]?.bind (·.nat? "number") | return
  try
    let some issue ← fg (e.forge.issue e.coordination n) | return
    unless issue.isOpen do return
    fg (e.forge.comment e.coordination n
      s!"{Text.noReply}\n\n@{e.human} Moved on: `{r.str "agent"}` no longer owes this ({r.str "what"}), so it needs nothing from you. Closed by the kit; whatever kept it stalled may still be worth a look.")
    fg (e.forge.close e.coordination n)
    log s!"{r.str "unit"} moved on: closed its decision {e.coordination}#{n}"
  catch err => log s!"couldn't close the decision {e.coordination}#{n} for {r.str "unit"}: {err}"

/-- Whether a run of the agent ended after `t`. -/
def ranSince (agent : String) (t : Float) : D Bool := do
  return !(← q "SELECT 1 FROM runs WHERE agent=? AND ended>?" [agent, t]).isEmpty

/-- Move an obligation on when it is due. Before a second wake, or the human, its unit is
evaluated again with `reeval`, so only what still stands goes further. -/
def advance (reeval : String → D Unit) (i : Nat) (fresh := false) : D Unit := do
  let e ← read
  let some r ← obligation i | return
  if r.int "escalated" != 0 then return
  let mut r := r
  if let some tid := r.nat? "trigger" then
    let tr ← q "SELECT run_id FROM triggers WHERE id=?" [tid]
    let run := (tr[0]?.map (·.get "run_id")).getD (.int (-1))
    let some runId := run.int? | return  -- queued
    let end_ ← if runId > 0 then do
        let ended ← q "SELECT ended FROM runs WHERE id=?" [runId]
        match ended[0]?.bind (·.real? "ended") with
        | some t => pure t
        | none => return  -- under way
      else now  -- dropped by hand
    let backoff := e.bounds.backoff
    let wait := (backoff[(min (r.nat "wakes") backoff.length) - 1]?).getD 0
    exec "UPDATE obligations SET trigger=NULL, next_at=? WHERE id=?" [end_ + wait.toFloat, i]
    let some r' ← obligation i | return
    r := r'
  let some next := r.real? "next_at" | return
  if next > (← now) then return
  let quiet := r.int "quiet" != 0
  let agent := r.str "agent"
  let isBusy ← busy agent
  -- A quiet one that let a run go ahead is due again only when that run ends.
  if quiet && isBusy then
    if let some since := r.real? "waited_since" then
      unless ← ranSince agent since do return
  if !fresh then
    try reeval (r.str "unit")
    catch err =>
      log s!"evaluating {r.str "unit"} again failed: {err}"
      return
    let some r' ← obligation i | return
    if r'.int "escalated" != 0 || !(r'.get "trigger").isNull then return
    r := r'
  let st : Obligation.St := { wakes := r.nat "wakes", waited := r.nat "waited" }
  let b : Obligation.Bounds := { tries := e.tries, patience := e.bounds.patience }
  let st' := Obligation.step b quiet st { busy := isBusy, discharged := false }
  if st'.escalated then
    escalate r
  else if Obligation.woke st st' then
    let again := if r.nat "wakes" > 0 then
        s!" (woken again, {r.nat "wakes" + 1} of {e.tries}, since nothing has changed: do it now, or record what it waits for where the kit can see it, with a Blocked-by: line, Waiting-on:, or needs-human with a decision; otherwise it becomes the human's)"
      else ""
    let key := s!"owe:{r.str "unit"}:{i}:{r.nat "wakes" + 1}"
    let description := r.str "description" ++ again
    let tid ← match ← addTrigger agent key description with
      | some tid => pure (some tid)
      | none => do
        -- The ledger reuses a deleted obligation's id, so a trigger with this key may still be
        -- queued for the one it replaced: it is this one's now, with its description.
        let queued ← q "SELECT id FROM triggers WHERE agent=? AND key=? AND run_id IS NULL" [agent, key]
        let some row := queued[0]? | pure none
        exec "UPDATE triggers SET description=? WHERE id=?" [description, row.get "id"]
        pure (row.nat? "id")
    if let some tid := tid then
      exec "UPDATE obligations SET wakes=wakes+1, trigger=?, next_at=NULL, waited=0, waited_since=NULL WHERE id=?" [tid, i]
  else if st'.waited > st.waited then
    exec "UPDATE obligations SET waited=?, waited_since=? WHERE id=?" [st'.waited, ← now, i]

/-- What a unit owes now: what it no longer owes is discharged, and what is new is woken. -/
def sync (unit : String) (owes : List Owe) : D Unit := do
  let t ← now
  let (gone, new) ← (← db).atomically fun q => do
    let rows ← q "SELECT * FROM obligations WHERE unit=?" [unit]
    let want := owes.foldl (fun (acc : List Owe) o =>
      if acc.any fun x => x.agent == o.agent && x.what == o.what then acc else acc ++ [o]) []
    let gone := rows.toList.filter fun r => !want.any fun o => o.agent == r.str "agent" && o.what == r.str "what"
    for r in gone do discard <| q "DELETE FROM obligations WHERE id=?" [r.get "id"]
    let mut new := #[]
    -- What isn't quiet first, so that a quiet one waits for it.
    for o in want.filter (!·.quiet) ++ want.filter (·.quiet) do
      match rows.find? fun r => o.agent == r.str "agent" && o.what == r.str "what" with
      | some r => discard <| q "UPDATE obligations SET description=?, quiet=? WHERE id=?" [o.description, o.quiet, r.get "id"]
      | none =>
        let ins ← q "INSERT INTO obligations (agent, unit, what, description, quiet, since, next_at) VALUES (?,?,?,?,?,?,?) RETURNING id"
          [o.agent, unit, o.what, o.description, o.quiet, t, t]
        if let some id := ins[0]?.bind (·.nat? "id") then new := new.push id
    return (gone, new)
  for r in gone do
    if r.int "escalated" != 0 then unstall r
  for i in new do advance (fun _ => pure ()) i (fresh := true)

/-- The run budget: once a unit's agent runs since the human last marked its notice seen reach the
budget, the human gets one notice. Counted from the ledger, whatever the states say. -/
def checkBudget (unit : String) : D Unit := do
  let e ← read
  let seen ← kvFloat s!"budget-seen:{unit}"
  let rows ← q "SELECT COUNT(DISTINCT t.run_id) AS n FROM triggers t JOIN runs r ON r.id = t.run_id
    WHERE t.key LIKE ? AND r.claimed > ?" [s!"owe:{unit}:%", seen]
  let runs := (rows[0]?.map (·.nat "n")).getD 0
  let key := s!"budget:{unit}:{seen.floor.toUInt64}"
  let noticed := !(← q "SELECT 1 FROM notices WHERE key=?" [key]).isEmpty
  if runs == 0 then return
  let (_, tell) := Budget.run e.bounds.runBudget { runs := runs - 1, noticed }
  unless tell do return
  let text := s!"{unit} has had {runs} agent runs since you last looked, the run budget: it may be going round in circles. Look at its activity, and mark this notice seen to start the count again."
  match unit.splitOn "#" with
  | [repo, n] =>
    match n.toNat? with
    | some k => notify key "budget" repo k text
    | none => discard <| addNotice key "budget" none none text
  | _ => discard <| addNotice key "budget" none none text

end Guild.Dispatcher
