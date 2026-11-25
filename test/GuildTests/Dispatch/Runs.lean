/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import GuildTests.Dispatch.Harness

/-! Claims and runs, retries, the summary and the status, the item cache and priority: the
reference's tests, ported. -/

namespace GuildTests.Dispatch.Runs

open Guild Guild.Forge Guild.Dispatcher GuildTests.Dispatch Json

def ago (t : T) (s : Nat) : IO Float := do return (← t.env.now) - s.toFloat

def trigger (t : T) (agent key description : String) (notBefore : Option Float := none) : Check :=
  discard <| t.io (addTrigger agent key description (once := true) (notBefore := notBefore))

def claimRun (t : T) (agent := "core") : ExceptT String IO Nat := do
  match ← t.io (claim agent) with
  | some c => return c.run
  | none => throw s!"no claim for {agent}"

def report (outcome : String) (turns : Option Nat := none) (cost : Option Float := none) : Json :=
  Json.mkObj ([("outcome", toJson outcome)] ++ (turns.map fun k => ("turns", toJson k)).toList ++
    (cost.bind Json.Number.ofFloat? |>.map fun c => ("cost", Json.num c)).toList)

def triggerRow (t : T) (key : String) : IO (Option Row) := do
  return (← t.run (q "SELECT run_id, attempts, not_before, env_held FROM triggers WHERE key=?" [key]))[0]?

def unstarted : List (String × (T → Check)) :=
  let setUp (t : T) : ExceptT String IO Nat := do
    trigger t "core" "work:1" "some work"
    t.io (exec "UPDATE triggers SET created=?" [← ago t 3600])
    claimRun t
  [("an undelivered claim gives its work back", fun t => do
      let run ← setUp t
      t.io (undoClaim run "the reply didn't reach the runner")
      same (← t.queued "core") ["work"]
      ensure ((← t.io (q "SELECT ended FROM runs WHERE id=?" [run]))[0]?.any fun r => !(r.get "ended").isNull) "closed"
      same ((← t.io (claim "core")).map (·.triggers)) (some ["some work"])),
   ("a claim no one starts is closed after a while", fun t => do
      let run ← setUp t
      t.io abandonUnstarted
      same (← t.queued "core") []
      t.io (exec "UPDATE runs SET claimed=? WHERE id=?" [← ago t 901, run])
      t.io abandonUnstarted
      same (← t.queued "core") ["work"]),
   ("a started run is left alone", fun t => do
      let run ← setUp t
      t.io (exec "UPDATE runs SET claimed=?, started=? WHERE id=?" [← ago t 901, ← t.env.now, run])
      t.io abandonUnstarted
      ensure ((← t.io (q "SELECT ended FROM runs WHERE id=?" [run]))[0]?.any fun r => (r.get "ended").isNull) "left alone")]

/-- Something happens, then a quiet spell: what it queued. -/
def spell (t : T) : ExceptT String IO (List String) := do
  t.pass 60
  trigger t "core" s!"work:{← t.now}" "some work"
  t.handled
  t.pass 1260
  t.io checkIdle
  let found := (← t.io (q "SELECT description FROM triggers WHERE run_id IS NULL")).toList.map (·.str "description")
  t.handled
  return found

def waiting (t : T) (items : List (String × Nat)) : IO Unit := do
  t.run (exec "DELETE FROM human_waits")
  for (r, n) in items do t.run (exec "INSERT INTO human_waits (repo, number) VALUES (?,?)" [r, n])

def idle : List (String × (T → Check)) := [
  ("a restart starts a quiet spell", fun t => do
    waiting t [(core, 1)]
    same (← spell t) ["the kit is idle; 1 item waits on you"]
    waiting t [(core, 1), (scale, 4)]
    t.pass 600
    let t := { t with env := { t.env with started := ← t.env.now } }
    t.io checkIdle
    same (← t.queuedAll) [] "not until it has been quiet the idle time since the start"
    t.pass 1260
    t.io checkIdle
    same (← t.queuedAll) [("coordinator", "idle")]),
  ("only when what waits on the human changed", fun t => do
    waiting t [(core, 1)]
    same (← spell t) ["the kit is idle; 1 item waits on you"]
    same (← spell t) [] "the same item waits"
    waiting t [(core, 1), (scale, 4)]
    same (← spell t) ["the kit is idle; 2 items wait on you"]
    waiting t []
    same (← spell t) ["the kit is idle; nothing waits on you"]
    same (← spell t) [])]

def lines (t : T) : IO (List String) := do return (← t.run kitSummary).splitOn "\n"

def summary : List (String × (T → Check)) := [
  ("says what each run is for, one line each", fun t => do
    t.io (exec "INSERT INTO runs (agent, triggers, claimed, started) VALUES ('core', ?, ?, ?)"
      [s!"[\"untriaged request {core}#1\", \"comment on {core}#2\"]", ← ago t 600, ← ago t 600])
    trigger t "scale" "work:1" "some work"
    t.io (runnerSeen "scale")
    same (← lines t) ["Kit: working; nothing waits on you",
      s!"  - core running for 10 minutes: untriaged request {core}#1 (and 1 more)",
      "  - 1 queued for scale, the oldest for under a minute"]),
  ("a runner that stopped calling in is stuck", fun t => do
    trigger t "core" "work:1" "some work"
    t.io (kvSet "seen:core" (toString (← ago t 2400)))
    same (← lines t) ["Kit: stuck; nothing waits on you",
      "  - stuck: 1 queued for core, whose runner hasn't called in for 40 minutes: restart its container"]),
  ("a runner running a run isn't stuck", fun t => do
    t.io (exec "INSERT INTO runs (agent, triggers, claimed, started) VALUES ('core', '[\"some work\"]', ?, ?)" [← ago t 360, ← ago t 360])
    trigger t "core" "work:2" "more work"
    t.io (kvSet "seen:core" (toString (← ago t 360)))
    same (← lines t) ["Kit: working; nothing waits on you", "  - core running for 6 minutes: some work",
      "  - 1 queued for core, the oldest for under a minute"]),
  ("queued work says how long it has waited", fun t => do
    trigger t "core" "work:1" "some work"
    t.io (runnerSeen "core")
    t.io (exec "UPDATE triggers SET created=?" [← ago t 300])
    ensure ((← lines t).contains "  - 1 queued for core, the oldest for 5 minutes") "the line"),
  ("queued work not yet due says when it is", fun t => do
    let due := (← t.env.now) + 600
    trigger t "core" "work:1" "some work" (notBefore := some due)
    t.io (runnerSeen "core")
    ensure ((← lines t).contains s!"  - 1 queued for core, the oldest for under a minute (1 not yet due, the first at {Time.iso due})") "the line"),
  ("a claim that never started is stuck", fun t => do
    t.io (exec "INSERT INTO runs (agent, triggers, claimed) VALUES ('core', '[]', ?)" [← ago t 600])
    let ls ← lines t
    same (ls.headD "") "Kit: stuck; nothing waits on you"
    ensure ((ls.getD 1 "").startsWith "  - stuck: core's run") (toString ls)),
  ("quiet", fun t => do same ((← lines t).headD "") "Kit: quiet; nothing waits on you")]

def failed : List (String × (T → Check)) :=
  let claimWork (t : T) : ExceptT String IO Nat := do
    t.io (exec "UPDATE triggers SET created=?, not_before=NULL" [← ago t 3600])
    claimRun t
  let ending (t : T) (r : Json) : ExceptT String IO Row := do
    discard <| t.io (endRun "core" (← claimWork t) r)
    match ← triggerRow t "work:1" with | some row => pure row | none => throw "no trigger"
  let setUp (t : T) : Check := trigger t "core" "work:1" "some work"
  [("a completed run consumes its work", fun t => do
      setUp t
      ensure (!((← ending t (report "completed")).get "run_id").isNull) "consumed"),
   ("a failed run is retried later, then put to the human", fun t => do
      setUp t
      let r ← ending t (report "failed: error_max_turns")
      same ((r.get "run_id").isNull, r.nat "attempts") (true, 1)
      ensure (((r.real "not_before") - ((← t.env.now) + 300)).abs < 5) "after the retry delay"
      let r ← ending t (report "timed out after 240 minutes")
      same ((r.get "run_id").isNull, r.nat "attempts") (true, 2)
      ensure (((r.real "not_before") - ((← t.env.now) + 600)).abs < 5) "after twice the delay"
      let r ← ending t (report "exited (status 1) before finishing a reply")
      ensure (!(r.get "run_id").isNull) "given up on"
      let posted := (((← t.world.get).repos.find? (·.name == core)).map fun r => r.items.toList.map (·.title)).getD []
      same posted.length 1
      ensure (has (posted.headD "") "failed 3 times") (posted.headD "")),
   ("a run that never got going waits longer and isn't counted", fun t => do
      setUp t
      for delay in [300, 900, 3600, 3600] do
        discard <| t.io (endRun "core" (← claimWork t) (report "failed: ERR_PROXY_TUNNEL" (some 1) (some 0)))
        let some r ← triggerRow t "work:1" | throw "no trigger"
        same ((r.get "run_id").isNull, r.nat "attempts") (true, 0)
        ensure (((r.real "not_before") - ((← t.env.now) + delay.toFloat)).abs < 5) s!"after {delay}"
      same (← t.io (runsToday "core")) 0 "nor do they use up its day"
      -- No decision for the human, and one notice however many fail.
      same (((← t.world.get).repos.find? (·.name == core)).map (·.items.size)) (some 0)
      same ((← t.io (q "SELECT kind FROM notices")).toList.map (·.str "kind")) ["env-failing"]
      -- Once a run gets going, the delays start again, and so does the notice.
      trigger t "core" "work:2" "other work"
      t.io (exec "UPDATE triggers SET created=?, not_before=NULL" [← ago t 3600])
      discard <| t.io (endRun "core" (← claimRun t) (report "completed" (some 30) (some 1.5)))
      ensure (← t.io (kvGet "env-failures:core")).isNone "the agent's count is gone"
      ensure (← t.io (kvGet "env-failing")).isNone "the notice's spell is over"),
   ("work held for its environment keeps its delay when its rule queues it again", fun t => do
      setUp t
      discard <| t.io (endRun "core" (← claimWork t) (report "failed: API Error" (some 1) (some 0)))
      trigger t "core" "work:1" "some work"
      ensure (((← triggerRow t "work:1").map (·.real "not_before")).getD 0 > (← t.env.now)) "still held"),
   ("a run getting going releases every agent's work held for the environment", fun t => do
      setUp t
      let limit := report "failed: Claude AI usage limit reached" (some 1) (some 0)
      discard <| t.io (endRun "core" (← claimWork t) limit)
      t.pass 1
      trigger t "scale" "work:2" "other work"
      t.io (exec "UPDATE triggers SET created=?, not_before=NULL WHERE key='work:2'" [← ago t 3600])
      discard <| t.io (endRun "scale" (← claimRun t "scale") limit)
      let s ← t.io kitSummary
      ensure (has s "failing: runs have failed before getting going since") s
      ensure (has s "(core, scale); the latest, scale's, ended failed: Claude AI usage limit reached") s
      trigger t "web" "work:3" "web work"
      t.io (exec "UPDATE triggers SET created=? WHERE key='work:3'" [← ago t 3600])
      discard <| t.io (endRun "web" (← claimRun t "web") (report "completed" (some 9) (some 0.4)))
      let held ← t.io (q "SELECT not_before, env_held FROM triggers WHERE key IN ('work:1', 'work:2')")
      let now ← t.env.now
      ensure (held.all fun r => r.real "not_before" ≤ now && r.int "env_held" == 0) "released"
      -- The others still count as failing until a run of theirs gets going.
      ensure (← t.io (kvGet "env-failing")).isSome "still failing"),
   ("a usage limit is retried when it resets, for every agent, however far the run got", fun t => do
      setUp t
      let some reset ← limitResets "resets 4:40pm (UTC)" (← t.env.now) | throw "no reset"
      trigger t "scale" "work:2" "other work"
      t.io (exec "UPDATE triggers SET created=?, not_before=NULL WHERE key='work:2'" [← ago t 3600])
      discard <| t.io (endRun "scale" (← claimRun t "scale") (report "failed: API Error" (some 1) (some 0)))
      -- Cut short after 33 turns: not counted, and held until the reset.
      discard <| t.io (endRun "core" (← claimWork t) (report "failed: You've hit your session limit · resets 4:40pm (UTC)" (some 33) (some 0.71)))
      let expected := max (reset + 120) ((← t.env.now) + 60)
      for r in ← t.io (q "SELECT key, attempts, not_before FROM triggers WHERE key IN ('work:1', 'work:2') ORDER BY key") do
        same (r.nat "attempts") 0
        ensure ((r.real "not_before" - expected).abs < 5) s!"{r.str "key"} held until the reset"
      same (((← t.world.get).repos.find? (·.name == core)).map (·.items.size)) (some 0)),
   ("when a usage limit resets", fun _ => do
      let utc (y m d h mi : Int) : Float := Float.ofInt (Time.daysFromCivil y m d * 86400 + h * 3600 + mi * 60)
      let at_ := utc 2026 11 23 16 20
      for (text, expected) in [
          ("failed: You've hit your session limit · resets 4:40pm (UTC)", some (utc 2026 11 23 16 40)),
          ("resets 5pm (UTC)", some (utc 2026 11 23 17 0)),
          ("resets 3am (UTC)", some (utc 2026 11 24 3 0)),  -- tomorrow
          ("resets 4pm (UTC)", some (utc 2026 11 23 16 0)),  -- just passed: still today
          ("resets 12:15am (Europe/London)", some (utc 2026 11 24 0 15)),
          ("resets 9am (America/New_York)", some (utc 2026 11 24 14 0)),
          ("weekly limit · resets Nov 27, 9am (UTC)", some (utc 2026 11 27 9 0)),
          ("failed: error_max_turns", none),
          ("resets 4:40pm", none),  -- no zone: can't tell when
          ("resets 4:40pm (Nowhere/Atlantis)", none),
          ("resets Dec 31, 9am (UTC)", none)] do  -- too far off to be a usage limit
        same ((← limitResets text at_).map Time.iso) (expected.map Time.iso) text),
   ("a run that did something is an ordinary failure", fun t => do
      setUp t
      discard <| t.io (endRun "core" (← claimWork t) (report "failed: error_during_execution" (some 1) (some 0.2)))
      same ((← triggerRow t "work:1").map (·.nat "attempts")) (some 1)
      same (← t.io (q "SELECT kind FROM notices")).size 0),
   ("a retry keeps its delay when its rule queues it again", fun t => do
      setUp t
      discard <| ending t (report "failed: error_max_turns")
      trigger t "core" "work:1" "some work"
      ensure ((← triggerRow t "work:1").any fun r => !(r.get "not_before").isNull) "still delayed"),
   ("a run the human stopped isn't retried", fun t => do
      setUp t
      ensure (!((← ending t (report "interrupted")).get "run_id").isNull) "consumed"),
   ("a run cut short by a pause is queued again as it was", fun t => do
      setUp t
      let run ← claimWork t
      IO.FS.writeFile (t.control / "paused") ""
      discard <| t.io (endRun "core" run (report "completed"))
      IO.FS.removeFile (t.control / "paused")
      let some r ← triggerRow t "work:1" | throw "no trigger"
      same ((r.get "run_id").isNull, r.nat "attempts") (true, 0))]

def draining : List (String × (T → Check)) :=
  let setUp (t : T) : ExceptT String IO Nat := do
    trigger t "core" "work:1" "some work"
    trigger t "scale" "work:2" "other work"
    t.io (exec "UPDATE triggers SET created=?" [← ago t 3600])
    let run ← claimRun t
    IO.FS.writeFile (t.control / "draining") ""
    return run
  [("a run under way finishes, and nothing starts", fun t => do
      let run ← setUp t
      ensure (← t.io (claim "scale")).isNone "nothing starts"
      same (← t.io (agentState "scale")) "draining"
      let s ← t.io status
      same ((s.getObjVal? "draining").toOption, (s.getObjVal? "drained").toOption, (s.getObjVal? "under_way").toOption)
        (some (toJson true), some (toJson false), some (toJson [s!"core's run {run}"]))
      discard <| t.io (endRun "core" run (report "completed" (some 20) (some 1.0)))
      t.env.caches.ciBusy.set [core]
      same ((← t.io status).getObjVal? "under_way").toOption (some (toJson ["CI"]))
      t.env.caches.ciBusy.set []
      let s ← t.io status
      same ((s.getObjVal? "drained").toOption, (s.getObjVal? "under_way").toOption) (some (toJson true), some (toJson ([] : List String)))
      ensure (has (← t.io kitSummary) "drained: safe to stop") "says so"
      -- The work it didn't start waits, and starts once resumed.
      IO.FS.removeFile (t.control / "draining")
      ensure (← t.io (claim "scale")).isSome "starts once resumed"),
   ("the quiet brings no summary", fun t => do
      let run ← setUp t
      discard <| t.io (endRun "core" run (report "completed" (some 20) (some 1.0)))
      t.io (exec "UPDATE triggers SET run_id=-1 WHERE run_id IS NULL")
      t.pass 4800
      t.io checkIdle
      same (← t.io (q "SELECT key FROM triggers WHERE run_id IS NULL")).size 0)]

/-- A forge that fails every read, for what must read nothing. -/
def refusing (f : Guild.Forge.Forge) : Guild.Forge.Forge :=
  let no {α} (what : String) : Guild.Forge.M α := throw (.transport s!"read the forge: {what}")
  { f with issue := fun _ _ => no "issue", issues := fun _ _ => no "issues", pull := fun _ _ => no "pull",
           pulls := fun _ _ => no "pulls", timeline := fun _ _ => no "timeline", reviews := fun _ _ => no "reviews",
           statuses := fun _ _ => no "statuses", activeRuns := fun _ => no "runs", branch := fun _ _ => no "branch",
           file := fun _ _ _ => no "file", repoExists := fun _ => no "repo", releases := fun _ => no "releases",
           tags := fun _ => no "tags", milestones := fun _ => no "milestones" }

def ciRun (status : RunStatus) (created : String) : Fake.RunPart :=
  { run := { id := 1, workflow := "checks.yml", status, sha := "x", event := "push", created }, jobs := [] }

def marked (t : T) : IO (List String) := do return (← t.env.caches.ciMarked.get).toList.map (·.1)

def statusReads : List (String × (T → Check)) := [
  ("what waits on the human follows the evaluations", fun t => do
    t.issue core 1 "core" ["needs-human"] (assignees := [human])
    t.pull core 2 "core" (requested := [human])
    t.issue core 3 "core" ["request", "accepted"]
    for n in [1, 2, 3] do t.evaluate core n
    same (← t.io waitingForHuman) [s!"{core}#1", s!"{core}#2"]
    -- Closed, and seen closed.
    t.close core 2
    t.evaluate core 2
    same (← t.io waitingForHuman) [s!"{core}#1"]
    -- Closed with no webhook: the sweep's pass over open items drops it.
    t.close core 1
    t.io (evaluateRepo core (items := true))
    same (← t.io waitingForHuman) []),
  ("CI is checked only where a webhook marked it", fun t => do
    t.io (ciMayRun core)
    let quiet := { t with env := { t.env with forge := refusing t.env.forge } }
    ensure (← quiet.io ciRunning) "marked and not yet checked: it may be running"
    t.repo core fun r => { r with runs := #[ciRun .running (Fake.stamp 0)] }
    t.io (refreshCi)
    same (← marked t, ← t.env.caches.ciBusy.get) ([], [core])
    ensure (← t.io ciRunning) "busy"
    -- Busy, so checked again until the run is over; then nothing is.
    t.repo core fun r => { r with runs := #[] }
    t.io refreshCi
    ensure (!(← t.io ciRunning)) "over"
    quiet.io refreshCi
    -- A run long left waiting doesn't count.
    let long ← t.at 7200
    t.repo scale fun r => { r with runs := #[ciRun .waiting long] }
    t.io (ciMayRun scale)
    t.io refreshCi
    ensure (!(← t.io ciRunning)) "a run long left waiting"),
  ("a mark during a check stands", fun t => do
    t.io (ciMayRun core)
    let f := t.env.forge
    let meanwhile := { t with env := { t.env with forge := { f with activeRuns := fun r => do
      t.pass 1
      (ciMayRun r).run t.env
      f.activeRuns r } } }
    meanwhile.io refreshCi
    same (← marked t) [core]),
  ("what can start CI marks its repository", fun t => do
    t.handle "push" (Json.mkObj [("repository", Json.mkObj [("name", toJson core), ("owner", Json.mkObj [("login", toJson "org")])]),
      ("sender", Json.mkObj [("login", toJson "core")]), ("ref", toJson "refs/heads/agent/x")])
    t.handle "issue_comment" (Json.mkObj [("repository", Json.mkObj [("name", toJson scale), ("owner", Json.mkObj [("login", toJson "org")])]),
      ("sender", Json.mkObj [("login", toJson "scale")]), ("action", toJson "created")])
    same (← marked t) [core]),
  ("the status page calls nothing", fun t => do
    t.issue core 1 "core" ["needs-human"] (assignees := [human])
    t.evaluate core 1
    let quiet := { t with env := { t.env with forge := refusing t.env.forge } }
    let s ← quiet.io status
    let text := ((s.getObjVal? "summary").toOption.bind (·.getStr?.toOption)).getD ""
    ensure (text.startsWith "Kit: quiet, nothing happens until you act; 1 item waits on you") text)]

/-- The env's forge, counting reads of each item's issue, pull request, timeline and reviews. -/
def counting (t : T) (calls : IO.Ref (List String)) : T :=
  let f := t.env.forge
  let note (what : String) : Guild.Forge.M Unit := calls.modify (· ++ [what])
  { t with env := { t.env with forge := { f with
      issue := fun r n => do note s!"{r}#{n} issue"; f.issue r n,
      pull := fun r n => do note s!"{r}#{n} pr"; f.pull r n,
      timeline := fun r n => do note s!"{r}#{n} timeline"; f.timeline r n,
      reviews := fun r n => do note s!"{r}#{n} reviews"; f.reviews r n } } }

def readsOf (calls : IO.Ref (List String)) (repo : String) (n : Nat) : IO (List String) := do
  return ((← calls.get).filterMap fun c => (c.dropPrefix s!"{repo}#{n} ").toString |> fun s =>
    if c.startsWith s!"{repo}#{n} " then some s else none).mergeSort (· ≤ ·)

def itemsReadOnce : List (String × (T → Check)) := [
  ("an unchanged issue is read once", fun t => do
    let calls ← IO.mkRef []
    let t := counting t calls
    t.issue core 1 "scale" ["request", "accepted"]
    t.evaluate core 1
    same (← readsOf calls core 1) ["issue", "timeline"]
    calls.set []
    t.io (evaluateRepo core (items := true))  -- the sweep
    same (← readsOf calls core 1) []
    -- A webhook names it: read afresh.
    t.evaluate core 1
    same (← readsOf calls core 1) ["issue", "timeline"]),
  ("a listing with a newer update drops it", fun t => do
    let calls ← IO.mkRef []
    let t := counting t calls
    t.issue core 1 "scale" ["request", "accepted"]
    t.evaluate core 1
    calls.set []
    t.pass 5
    t.item core 1 fun i => { i with updatedAt := "2026-01-30T00:00:00Z" }
    t.io (evaluateRepo core (items := true))
    same (← readsOf calls core 1) ["issue", "timeline"]),
  ("a pull request is read afresh, and its update checks the rest", fun t => do
    let calls ← IO.mkRef []
    let t := counting t calls
    t.pull core 7 "core" (ci := .success)
    t.evaluate core 7
    calls.set []
    discard <| t.io (evaluateOne core 7 (fresh := false))
    same (← readsOf calls core 7) ["pr"] "only the pull request itself"
    calls.set []
    t.item core 7 fun i => { i with updatedAt := "2026-01-30T00:00:00Z" }  -- pushed to, say
    discard <| t.io (evaluateOne core 7 (fresh := false))
    same (← readsOf calls core 7) ["issue", "pr", "pr", "reviews", "timeline"] "its pull request, changed, and so the rest afresh"),
  ("what is too old is read again", fun t => do
    let calls ← IO.mkRef []
    let t := counting t calls
    t.issue core 1 "scale" ["request", "accepted"]
    t.evaluate core 1
    calls.set []
    t.pass 3601
    discard <| t.io (evaluateOne core 1 (fresh := false))
    same (← readsOf calls core 1) ["issue", "timeline"]),
  ("a read overtaken by a webhook is not kept", fun t => do
    t.issue core 1 "scale" ["request", "accepted"]
    let f := t.env.forge
    let overtaken := { t with env := { t.env with forge := { f with timeline := fun r n => do
      (forget core 1).run t.env
      f.timeline r n } } }
    discard <| overtaken.io (itemReads core 1)
    ensure (!((← t.env.caches.items.get).contains s!"{core}#1")) "not kept"),
  ("a write to an item is one the kit reads afresh", fun t => do
    let calls ← IO.mkRef []
    let t := counting t calls
    t.issue core 1 "scale" ["request", "accepted"]
    t.evaluate core 1
    calls.set []
    t.io (fg (t.env.forge.addLabel core 1 "blocked"))
    discard <| t.io (evaluateOne core 1 (fresh := false))
    same (← readsOf calls core 1) ["issue", "timeline"])]

def priority : List (String × (T → Check)) := [
  ("a run's priority work comes first", fun t => do
    t.issue core 1 "scale" ["request", "accepted"]
    t.issue core 2 "scale" ["request", "new", "priority"]
    t.issue core 3 "scale" ["request", "accepted", "priority"]  -- nothing queued for it
    t.issue core 4 "scale" ["request", "accepted", "priority"] (isOpen := false)
    discard <| t.io (addTrigger "core" s!"comment:{core}#1:1" s!"a comment on {core}#1")
    discard <| t.io (addTrigger "core" s!"request:{core}#2:1" s!"untriaged request {core}#2")
    discard <| t.io (addTrigger "core" "idle:1" "the kit is idle")
    t.io (exec "UPDATE triggers SET created=?" [← ago t 3600])
    same ((← t.io (claim "core")).map (·.triggers)) (some [
      s!"priority: untriaged request {core}#2",
      s!"priority items open on your repository: {core}#3: they come before anything new (Protocol: Priority)",
      s!"a comment on {core}#1", "the kit is idle"]))]

def check : IO Bool := do
  let rs ← [("dispatcher unstarted runs", unstarted), ("dispatcher idle summary", idle), ("dispatcher summary", summary),
            ("dispatcher failed runs", failed), ("dispatcher draining", draining), ("dispatcher status", statusReads),
            ("dispatcher item cache", itemsReadOnce), ("dispatcher priority", priority)].mapM fun (g, cs) => runCases g cs
  return rs.all id

end GuildTests.Dispatch.Runs

namespace GuildTests.Dispatch.Runs

open Guild Guild.Forge Guild.Dispatcher GuildTests.Dispatch Json

/-- What the guild adds to the reference's dispatcher. -/
def additions : List (String × (T → Check)) := [
  ("a stopped agent gets no claim until it is started again", fun t => do
    trigger t "core" "work:1" "some work"
    t.io (exec "UPDATE triggers SET created=?" [← ago t 3600])
    IO.FS.writeFile (t.control / "stopped-core") ""
    ensure (← t.io (claim "core")).isNone "no claim while stopped"
    same (← t.io (agentState "core")) "stopped"
    IO.FS.removeFile (t.control / "stopped-core")
    ensure (← t.io (claim "core")).isSome "claimed once started"),
  ("the run budget tells the human once, until the notice is seen", fun _ => do
    let t ← T.new { config with bounds := { config.bounds with runBudget := 2 } }
    t.issue core 1 "scale" ["request", "new"]
    let cycle : Check := do
      t.evaluate core 1
      t.pass 61
      let some c ← t.io (claim "core") | throw "no claim"
      t.pass 60
      discard <| t.io (endRun "core" c.run (report "completed" (some 5) (some 0.1)))
      t.pass 1000
      t.wakeDue
    cycle
    same ((← t.io (q "SELECT kind FROM notices")).toList.map (·.str "kind")) [] "one run: within the budget"
    cycle
    same ((← t.io (q "SELECT kind FROM notices WHERE kind='budget'")).size) 1 "the second run reaches it"
    ensure ((← t.commentsOn core 1).any (has · "the run budget")) "the human is told on the item"
    t.io (kvSet s!"budget-seen:{core}#1" (toString (← t.env.now)))
    t.pass 1000
    t.wakeDue
    cycle
    same ((← t.io (q "SELECT kind FROM notices WHERE kind='budget'")).size) 1 "seen: the count starts again"),
  ("CI that fails again after its re-runs is the human's", fun t => do
    t.pull core 7 "core" (ci := .failure)
    let part (attempt : Nat) : Fake.RunPart :=
      { run := { id := 1, workflow := "checks.yml", status := .failure, sha := defaultSha, event := "pull_request",
                 created := Fake.stamp 0 },
        jobs := [{ id := 1, name := "build", status := .failure, attempt }] }
    t.repo core fun r => { r with runs := #[part 1] }
    t.evaluate core 7
    ensure (!(← t.commentsOn core 7).any (has · "re-run")) "not before its re-run"
    t.repo core fun r => { r with runs := #[part 2] }
    t.clearCache
    t.evaluate core 7
    ensure ((← t.commentsOn core 7).any (has · "after 1 re-run, the limit")) (toString (← t.commentsOn core 7))
    same ((← t.io (q "SELECT kind FROM notices")).toList.map (·.str "kind")) ["reruns"])]

def burst : List (String × (T → Check)) := [
  ("a newer ask before the claim is the one claimed", fun t => do
    t.issue core 1 "core" ["needs-human"] (events := [← t.comment "scale" 300 "First?" (id := some 1)])
    t.evaluate core 1
    t.add core 1 (← t.comment "scale" 200 "Second?" (id := some 2))
    t.evaluate core 1
    t.pass 61
    let some c ← t.io (claim "core") | throw "no claim"
    same (c.triggers.filter (has · "comment on")) [s!"comment on issue {core}#1 from scale: http://forge/org/{core}/issues/1#issuecomment-2"])]

def checkAdditions : IO Bool := do
  let a ← runCases "dispatcher additions" additions
  let b ← runCases "dispatcher additions" burst
  return a && b

end GuildTests.Dispatch.Runs
