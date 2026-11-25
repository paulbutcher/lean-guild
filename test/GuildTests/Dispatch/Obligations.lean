/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import GuildTests.Dispatch.Harness
import GuildTests.Dispatch.Asks

/-! Obligations, woken at once, again as each run ends with it still owed, with the backoff
between, then the human's; and the mechanics of evaluation: the reference's tests, ported. -/

namespace GuildTests.Dispatch.Obligations

open Guild Guild.Forge Guild.Dispatcher GuildTests.Dispatch Json

/-- core#1, an untriaged request from scale, evaluated. -/
def setUp (t : T) : IO Unit := do
  t.issue core 1 "scale" ["request", "new"]
  t.evaluate core 1

/-- The agent's runner claims its work and the run ends. -/
def finish (t : T) (agent := "core") (outcome := "completed") (turns := 20) (cost := 1.0) : Check := do
  t.pass 61
  let some c ← t.io (claim agent) | throw "work was due"
  t.pass 600
  discard <| t.io (endRun agent c.run (Json.mkObj [("outcome", toJson outcome), ("turns", toJson turns),
    ("cost", match Json.Number.ofFloat? cost with | some n => Json.num n | none => .null)]))

def titles (t : T) : IO (List (Nat × String)) := do
  return (((← t.world.get).repos.find? (·.name == coord)).map fun r => r.items.toList.map fun i => (i.number, i.title)).getD []

/-- Three runs leave it standing: the human's. The decision's number. -/
def stall (t : T) : ExceptT String IO Nat := do
  for _ in [0:3] do
    finish t
    t.pass 900
    t.wakeDue
  let some (n, title) := (← titles t).getLast? | throw "no decision"
  same title s!"Stalled: {core}#1"
  return n

def obligations : List (String × (T → Check)) := [
  ("woken again with backoff, then the human's", fun t => do
    setUp t
    same (← t.queued "core") ["untriaged"]
    t.wakeDue
    same (← t.queued "core").length 1 "not again while queued"
    finish t
    t.wakeDue
    same (← t.queued "core") ["untriaged"] "at once, the first time"
    ensure (has ((← t.descriptions "core").headD "") "woken again, 2 of 3") "says it is woken again"
    finish t
    t.wakeDue
    same (← t.queued "core") [] "then not for 15 minutes"
    t.pass 900
    t.wakeDue
    same (← t.queued "core") ["untriaged"]
    finish t
    t.pass 900
    t.wakeDue
    same (← t.queued "core") [] "three runs: it is the human's"
    same ((← titles t).map (·.2)) [s!"Stalled: {core}#1"]
    let body := ((← t.itemOf coord 1).map (·.body)).getD ""
    ensure (has body "`core` was woken 3 times") body
    t.pass 3600
    t.wakeDue
    same (← t.queued "core") [] "and stays so"),
  ("the decision links to the item as the browser reaches it", fun t => do
    setUp t
    let n ← stall t
    let body := ((← t.itemOf coord n).map (·.body)).getD ""
    ensure (has body s!"[{core}#1](http://forge/org/{core}/issues/1)") body),
  ("a stalled decision is closed once it moves on", fun t => do
    setUp t
    let n ← stall t
    t.setLabels core 1 ["request", "accepted"]
    t.evaluate core 1
    ensure (!((← t.itemOf coord n).any (·.isOpen))) "closed"
    ensure ((← t.commentsOn coord n).any (has · "Moved on: `core` no longer owes this (untriaged)")) "says why"),
  ("a stalled decision the human closed is left alone", fun t => do
    setUp t
    let n ← stall t
    t.close coord n
    t.setLabels core 1 ["request", "accepted"]
    t.evaluate core 1
    same (← t.commentsOn coord n) []),
  ("discharged when what it owes changes", fun t => do
    setUp t
    t.setLabels core 1 ["request", "accepted"]
    t.pass 61
    ensure (← t.io (claim "core")).isNone "its trigger is dropped at the claim"
    same (← t.owing) [("core", "to do")]
    -- Back to what it was: owed afresh.
    t.setLabels core 1 ["request", "new"]
    t.evaluate core 1
    same ((← t.io (q "SELECT wakes FROM obligations WHERE what='untriaged'")).toList.map (·.nat "wakes")) [1]),
  ("a run that never got going uses up nothing", fun t => do
    setUp t
    finish t (outcome := "failed: ERR_PROXY_TUNNEL") (turns := 1) (cost := 0)
    same ((← t.io (q "SELECT wakes FROM obligations")).toList.map (·.nat "wakes")) [1]
    same (← t.queued "core") ["untriaged"] "its own trigger, queued again to retry"),
  ("dropped by hand, it comes back after the wait", fun t => do
    setUp t
    t.pass 61
    t.io (exec "UPDATE triggers SET run_id=-1 WHERE run_id IS NULL")
    t.wakeDue
    same (← t.queued "core") ["untriaged"] "the first wait is none"),
  ("the supervisor is woken with the human", fun _ => do
    let t ← T.new Asks.withSupervisor
    setUp t
    for _ in [0:3] do
      finish t
      t.pass 900
      t.wakeDue
    let sup ← t.descriptions "process"
    same sup.length 1
    ensure ((sup.headD "").startsWith s!"{core}#1 has stalled: core was woken 3 times") (sup.headD "")),
  ("a quiet one waits while its agent has other work", fun t => do
    setUp t
    t.issue core 2 "coordinator" ["request", "accepted"]
    t.evaluate core 2
    same (← t.queued "core") ["untriaged"]
    finish t
    t.wakeDue
    same (← t.queued "core") ["untriaged"] "woken again for #1, so #2 still waits"
    t.close core 1
    t.pass 61
    ensure (← t.io (claim "core")).isNone "#1 is no longer owed"
    t.wakeDue
    same (← t.queued "core") ["to do"]),
  ("a quiet one lets at most its patience of runs go ahead", fun t => do
    -- core is kept busy with fresh work. #2 lets two of its runs go ahead, then is woken anyway.
    let busyWith (k : Nat) : Check := discard <| t.io (addTrigger "core" s!"work:{k}" s!"other work {k}")
    busyWith 1
    t.issue core 2 "coordinator" ["request", "accepted"]
    t.evaluate core 2
    same (← t.queued "core") ["work"] "busy: it waits"
    finish t
    busyWith 2
    t.wakeDue
    same (← t.queued "core") ["work"] "it lets a second run go ahead"
    t.wakeDue
    same (← t.queued "core") ["work"] "and isn't due again until that run ends"
    finish t
    busyWith 3
    t.wakeDue
    same (← t.queued "core") ["work", "to do"] "its patience spent, it is woken though core is busy")]

def mechanics : List (String × (T → Check)) := [
  ("a claim keeps what is still owed", fun t => do
    t.issue core 1 "scale" ["request", "new"]
    t.evaluate core 1
    t.io (exec "UPDATE triggers SET created=?" [((← t.env.now) - 3600 : Float)])
    same ((← t.io (claim "core")).map (·.triggers))
      (some [s!"issue {core}#1 (untriaged): accept it, counter-propose, or close it saying why"])),
  ("the first sweep records the notices the old triggers covered", fun t => do
    t.io (exec "DELETE FROM kv")
    t.issue core 1 "scale" ["request", "new"] (events := [← t.comment "scale" 100])
    t.io reconcile  -- tools, not in the forge yet, is skipped
    same ((← t.queued "core").mergeSort (· ≤ ·)) ["reply", "untriaged"]
    same (← t.queued "coordinator") [] "its notice of the filing is recorded as handled"
    ensure (← t.io (kvGet "rules-seeded")).isSome "seeded"),
  ("the old rules' triggers are dropped once", fun t => do
    t.io (exec "DELETE FROM kv WHERE key='obligations-started'")
    discard <| t.io (addTrigger "core" s!"request:{core}#1:x" "untriaged request")
    discard <| t.io (addTrigger "core" s!"filed:{core}#1:" "request filed")
    discard <| t.io (addTrigger "core" "idle:1" "the kit is idle")
    t.io retireRuleTriggers
    same (← t.queued "core") ["filed", "idle"]
    discard <| t.io (addTrigger "core" s!"request:{core}#2:x" "untriaged request")
    t.io retireRuleTriggers
    same (← t.queued "core").length 3 "once"),
  ("a blocker closing evaluates what waits on it", fun t => do
    t.issue scale 38 "coordinator" ["request"]
    t.issue core 12 "coordinator" ["request", "accepted", "blocked"] (body := line scale 38)
    t.evaluate core 12
    same (← t.stateName s!"{core}#12") "blocked"
    t.close scale 38 5
    t.handle "issues" (Json.mkObj [("action", toJson "closed"),
      ("repository", Json.mkObj [("name", toJson scale), ("owner", Json.mkObj [("login", toJson "org")])]),
      ("sender", Json.mkObj [("login", toJson "coordinator")]),
      ("issue", Json.mkObj [("number", toJson 38), ("state", toJson "closed"), ("labels", Json.arr #[Json.mkObj [("name", toJson "request")]])])])
    same (← t.stateName s!"{core}#12") "to do"),
  ("a merge evaluates the requests it answers", fun t => do
    t.issue core 5 "scale" ["request", "accepted"]
    t.pull core 7 "core" (body := "Refs #5") (isOpen := false) (merged := some 5)
    t.handle "pull_request" (Json.mkObj [("action", toJson "closed"),
      ("repository", Json.mkObj [("name", toJson core), ("owner", Json.mkObj [("login", toJson "org")])]),
      ("sender", Json.mkObj [("login", toJson "core")]),
      ("pull_request", Json.mkObj [("number", toJson 7), ("merged", toJson true), ("user", Json.mkObj [("login", toJson "core")])])])
    same (← t.stateName s!"{core}#5") "merged"),
  ("a deleted item owes nothing", fun t => do
    t.issue core 1 "scale" ["request", "new"]
    t.evaluate core 1
    t.repo core fun r => { r with items := r.items.filter (·.number != 1) }
    t.evaluate core 1
    same (← t.owing) []),
  ("a blocker with fifty comments or more is read once", fun t => do
    let many ← (List.range 59).mapM fun k => t.comment "scale" (100 - k)
    t.issue scale 38 "coordinator" ["request"] (events := many ++ [← t.comment "gatekeeper" 10 "(no reply needed)\n\nReleased in v0.4.3: http://forge/r"])
    same ((← t.io (blockerState scale 38)).done.map (·.2)) (some s!"{scale}#38 was released in v0.4.3"))]

def check : IO Bool := do
  let a ← runCases "dispatcher obligations" obligations
  let b ← runCases "dispatcher mechanics" mechanics
  return a && b

end GuildTests.Dispatch.Obligations
