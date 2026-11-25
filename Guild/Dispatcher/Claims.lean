/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
module

public import Guild.Dispatcher.Evaluate
public import Std.Time.Zoned.Database
public import Leancrypto.Compare

/-! Claims and runs. A claim is granted only when the agent has no run, isn't stopped, is under its
daily caps, the kit isn't paused or draining, and its newest trigger has settled for the debounce
period (or its oldest has waited the maximum delay), so a burst of events becomes one run; and only
for triggers whose items still owe them. A run that fails, times out or exits early has its work
queued again, up to `retries` times; then it is the human's. One that failed before it got going
failed for its environment, and waits without counting. -/

@[expose] public section

namespace Guild.Dispatcher

open Json

/-- The agent a runner key belongs to: a file in the keys directory named for the agent. Read on
every request, so a new key needs no restart. -/
def agentForKey (key : String) : D (Option String) := do
  if key.isEmpty then return none
  let dir := (← read).keysDir
  unless ← dir.pathExists do return none
  for f in ← dir.readDir do
    try
      let k := (← IO.FS.readFile f.path).trimAscii.toString
      if Leancrypto.bytesEqual k.toUTF8 key.toUTF8 then return some f.fileName
    catch _ => continue
  return none

/-- Record that the agent's runner called in, at most every 30 seconds. -/
def runnerSeen (agent : String) : D Unit := do
  let t ← now
  if t - (← kvFloat s!"seen:{agent}") ≥ 30 then kvSet s!"seen:{agent}" (toString t)

/-- How long since the agent's runner last called in, if it hasn't lately (and ever has). -/
def runnerSilentFor (agent : String) : D (Option Float) := do
  let seen ← kvFloat s!"seen:{agent}"
  let t ← now
  return if seen > 0 && t - seen > (← read).timings.runnerSilent then some (t - seen) else none

def running (agent : String) : D Bool := mayPush agent

def agentState (agent : String) : D String := do
  if ← running agent then return "running"
  if ← paused then return "paused"
  if ← draining then return "draining"
  if ← stopped agent then return "stopped"
  if (← capped agent).isSome then return "capped"
  return "idle"

/-- The `repo#n` a trigger's key names, if it names one: `<kind>:<repo>#<n>` then `:` or the end. -/
def itemOf (key : String) : Option String := do
  let parts := key.splitOn ":"
  let kind ← parts[0]?
  guard (!kind.isEmpty && kind.all fun c => c.isLower || c == '-')
  let at_ ← parts[1]?
  let [repo, n] := at_.splitOn "#" | none
  guard (!repo.isEmpty && repo.all Text.nameChar && !n.isEmpty && n.all Char.isDigit)
  return at_

/-- Which of these triggers' items are labelled priority, and every open item labelled priority
on the agent's own repository. -/
def priorities (agent : String) (keys : List String) : D (List String × List String) := do
  let e ← read
  let items := (keys.filterMap itemOf).eraseDups
  let hot ← items.filterM fun at_ => do
    let [repo, n] := at_.splitOn "#" | return false
    let some k := n.toNat? | return false
    let issue ← cached s!"issue:{at_}" 20 (fun | .issue i => some i | _ => none) .issue (fg (e.forge.issue repo k))
    return issue.any fun i => i.isOpen && i.labels.contains "priority"
  let mine ← match (e.agent? agent).bind (·.owns) with
    | some own => do
      if ← forgeMissing own then pure []
      else pure ((← fg (e.forge.issues own { which := .open, kinds := .all, labels := ["priority"] })).map
        (itemUnit own ·.number))
    | none => pure []
  return (hot, mine)

def today : D String := do return ((Time.iso (← now)).take 10).toString

structure Claim where
  run : Nat
  triggers : List String

def Claim.json (c : Claim) : Json := Json.mkObj [("run", toJson c.run), ("triggers", toJson c.triggers)]

/-- Whether the agent's work is due; with `grant`, the run is started and returned, its priority
work first. -/
def due (agent : String) (grant := false) (prio : List String × List String := ([], [])) : D (Option Claim) := do
  let e ← read
  if ← running agent then return none
  if (← paused) || (← draining) || (← stopped agent) then return none
  let t ← now
  let rows ← q "SELECT id, key, description, created FROM triggers WHERE agent=? AND run_id IS NULL
    AND (not_before IS NULL OR not_before<=?) ORDER BY created" [agent, t]
  let some first := rows[0]? | return none
  let some last := rows.back? | return none
  if let some why ← capped agent then
    let day ← today
    let waiting := "\n".intercalate ((rows.toList.map (·.str "description")).eraseDups.map ("- " ++ ·))
    notifyAgent agent s!"cap:{agent}:{day}" "cap" s!"{agent} reached {why} ({day})" [
      ("Question", s!"`{agent}` reached {why} at {Time.iso t}, with {rows.size} trigger(s) waiting. Should it carry on today?"),
      ("Options", s!"- Raise `{e.capSetting agent}` (or `maxSpendPerDay`) in the project's bounds, and rebuild and restart the kit: the waiting work starts within a minute.\n- Leave it: the waiting work starts after midnight UTC."),
      ("Recommendation", "Leave it unless the waiting work is urgent. If caps are reached most days, raise them."),
      ("If you say go ahead", "Nothing changes: the waiting work starts after midnight UTC. Close this issue."),
      ("Blocked on this", s!"`{agent}`'s waiting work:\n{waiting}")]
    return none
  if t - last.real "created" < e.timings.debounce && t - first.real "created" < e.timings.maxDelay then return none
  if !grant then return some { run := 0, triggers := [] }
  let (hot, mine) := prio
  let firsts := (rows.toList.filter fun r => (itemOf (r.str "key")).any hot.contains).map
    fun r => s!"priority: {r.str "description"}"
  let rest := (rows.toList.filter fun r => !(itemOf (r.str "key")).any hot.contains).map (·.str "description")
  let others := mine.filter (!hot.contains ·)
  let firsts := if others.isEmpty then firsts else
    firsts ++ [s!"priority items open on your repository: {", ".intercalate others}: they come before anything new (Protocol: Priority)"]
  let descs := (firsts ++ rest).eraseDups
  let runId : Option Nat ← e.db.atomically fun q => do
    -- Checked again under the lock: a claim from the same runner may have raced this one.
    if !(← q "SELECT 1 FROM runs WHERE agent=? AND ended IS NULL" [agent]).isEmpty then return none
    let r ← q "INSERT INTO runs (agent, triggers, claimed) VALUES (?,?,?) RETURNING id" [agent, (toJson descs).compress, t]
    let some (id : Nat) := r[0]?.bind (·.nat? "id") | return none
    for row in rows do discard <| q "UPDATE triggers SET run_id=?, env_held=0 WHERE id=?" [id, row.get "id"]
    return some id
  let some id := runId | return none
  log s!"{agent} claimed run {id}: {", ".intercalate descs}"
  return some { run := id, triggers := descs }

/-- A run for the agent if its work is due, after checking that each item behind it still owes
that work: dropped, and renamed so the same state can queue it again, if not. Each unit it is for
is counted against the run budget. -/
def claim (agent : String) : D (Option Claim) := do
  if (← due agent).isNone then return none
  let rows ← q "SELECT id, key FROM triggers WHERE agent=? AND run_id IS NULL" [agent]
  let stale ← noLongerOwed rows.toList
  unless stale.isEmpty do
    let t ← now
    for i in stale do
      exec "UPDATE triggers SET run_id=-1, key = key || ':stale:' || CAST(? AS INTEGER) WHERE run_id IS NULL AND id=?" [t.floor.toUInt64.toNat, i]
    log s!"dropped {stale.length} trigger(s) for {agent} that are no longer owed"
  let prio ← try priorities agent (rows.toList.map (·.str "key"))
    catch err => do log s!"couldn't read {agent}'s priority items: {err}"; pure ([], [])
  let c ← due agent (grant := true) prio
  if let some c := c then
    let units ← q "SELECT DISTINCT key FROM triggers WHERE run_id=? AND key LIKE 'owe:%'" [c.run]
    let names := (units.toList.filterMap fun r =>
      let parts := ((r.str "key").drop 4).toString.splitOn ":"
      if parts.length ≥ 3 then some (":".intercalate parts.dropLast.dropLast) else none).eraseDups
    for u in names do
      try checkBudget u catch err => log s!"couldn't check {u}'s run budget: {err}"
  return c

/-- The run's work is still to do, through no fault of the run: queue it again as it was. -/
def requeue (runId : Nat) : D Unit := exec "UPDATE triggers SET run_id=NULL WHERE run_id=?" [runId]

/-- A claim no runner will start: closed unstarted, and its work queued again as it was. -/
def undoClaim (runId : Nat) (why : String) : D Unit := do
  exec "UPDATE runs SET ended=?, outcome=? WHERE id=? AND started IS NULL AND ended IS NULL"
    [← now, s!"never started: {why}", runId]
  requeue runId
  log s!"run {runId} never started ({why}); its work is queued again"

def abandonUnstarted : D Unit := do
  let e ← read
  for r in ← q "SELECT id FROM runs WHERE started IS NULL AND ended IS NULL AND claimed<?" [(← now) - e.timings.claimStart] do
    undoClaim (r.nat "id") s!"no runner started it within {(e.timings.claimStart / 60).floor.toUInt64} minutes of its claim"

/-- Queue a failed run's work again after a delay, up to `retries` times; then put it to the human.
Whether it was queued again. -/
def retry (agent : String) (runId : Nat) (outcome : String) : D Bool := do
  let e ← read
  let rows ← q "SELECT description, attempts FROM triggers WHERE run_id=?" [runId]
  if rows.isEmpty then return false
  let attempt := (rows.toList.map (·.nat "attempts")).foldl max 0 + 1
  if attempt ≤ e.timings.retries then
    exec "UPDATE triggers SET run_id=NULL, attempts=?, not_before=?, env_held=0 WHERE run_id=?"
      [attempt, (← now) + e.timings.retryDelay * attempt.toFloat, runId]
    log s!"{agent} run {runId} {outcome}: its work is queued again (retry {attempt} of {e.timings.retries})"
    return true
  let work := "\n".intercalate ((rows.toList.map (·.str "description")).eraseDups.map ("- " ++ ·))
  notifyAgent agent s!"retries:{agent}:{runId}" "failed-run" s!"{agent}'s work failed {attempt} times (run {runId})" [
    ("Question", s!"Run {runId} of `{agent}` ended `{outcome}`, the last of {attempt} tries at the same work. It won't be tried again by itself. What should happen to it?"),
    ("Options", s!"- Find out why from the run's log in the kit's activity, or by opening the run in the Claude extension in `{agent}`'s container and asking it, then fix the cause. Your session can't do the run's work itself: file what remains as an issue for the agent.\n- Leave it: what its items still owe is found again by the dispatcher's sweep; the rest waits for the next event on it."),
    ("Recommendation", "Find out why first: a run that fails every time is usually a cause outside it, such as a credential, the run length (`maxRunMinutes`) or the turn limit."),
    ("If you say go ahead", "Nothing happens on its own. Close this issue once you've dealt with it."),
    ("Blocked on this", s!"`{agent}`'s work from that run:\n{work}")]
  return false

/-- A failed run that did nothing: at most one turn, nothing spent, no change in the forge. A run
with no turns reported didn't say, so it is an ordinary failure. -/
def neverGotGoing (outcome : String) (turns : Option Nat) (cost : Option Float) (changes : Nat) : Bool :=
  outcome != "completed" && outcome != "interrupted" && turns.any (· ≤ 1) && cost.all (· == 0) && changes == 0

def months : List String := ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

/-- What a usage limit's message says about when it resets: `resets 4:40pm (UTC)`, or with a day,
`resets Nov 30, 9am (Europe/London)`. (month and day, hour, minute, time zone). -/
def parseResets (outcome : String) : Option (Option (Nat × Nat) × Nat × Nat × String) :=
  let cs := outcome.toList
  go [] cs (cs.length + 1)
where
  ws (cs : List Char) : List Char := cs.dropWhile Char.isWhitespace
  spaced (cs : List Char) : Option (List Char) := if cs.head?.any Char.isWhitespace then some (ws cs) else none
  digits (cs : List Char) (most : Nat) : Option (Nat × List Char) :=
    let ds := (cs.takeWhile Char.isDigit)
    if ds.isEmpty || ds.length > most then none else (String.ofList ds).toNat?.map (·, cs.drop ds.length)
  monthDay (cs : List Char) : Option ((Nat × Nat) × List Char) := do
    let mon := String.ofList ((cs.take 3).map Char.toLower)
    let m ← months.idxOf? mon
    let r := (cs.drop 3).dropWhile Char.isLower
    let r := if r.head? == some '.' then r.drop 1 else r
    let r ← spaced r
    let (d, r) ← digits r 2
    let r := if r.head? == some ',' then r.drop 1 else r
    let r ← spaced r
    let r := if Text.startsCI r "at" then ((spaced (r.drop 2)).getD r) else r
    return ((m + 1, d), r)
  clock (cs : List Char) : Option ((Nat × Nat × String) × List Char) := do
    let (h, r) ← digits cs 2
    let (mi, r) ← if r.head? == some ':' then do
        digits (r.drop 1) 2
      else pure (0, r)
    let r := ws r
    let ap := String.ofList ((r.take 2).map Char.toLower)
    guard (ap == "am" || ap == "pm")
    let r := ws (r.drop 2)
    guard (r.head? == some '(')
    let tz := (r.drop 1).takeWhile (· != ')')
    guard (!tz.isEmpty && (r.drop (1 + tz.length)).head? == some ')')
    return ((h % 12 + (if ap == "pm" then 12 else 0), mi, String.ofList tz), r)
  attempt (cs : List Char) : Option (Option (Nat × Nat) × Nat × Nat × String) := do
    let r ← spaced (cs.drop 6)
    match monthDay r with
    | some (md, r2) => match clock r2 with
      | some ((h, mi, tz), _) => some (some md, h, mi, tz)
      | none => (clock r).map fun ((h, mi, tz), _) => (none, h, mi, tz)
    | none => (clock r).map fun ((h, mi, tz), _) => (none, h, mi, tz)
  go (before cs : List Char) : Nat → Option (Option (Nat × Nat) × Nat × Nat × String)
    | 0 => none
    | fuel + 1 =>
      match cs with
      | [] => none
      | c :: rest =>
        let found := if !(before.head?.any Text.wordChar) && Text.startsCI cs "resets" then attempt cs else none
        match found with
        | some f => some f
        | none => go (c :: before) rest fuel

/-- A time zone's offset from UTC at a time, in seconds. -/
def offsetAt (tz : String) (t : Float) : IO (Option Int) := do
  if tz.trimAscii.toString.toUpper == "UTC" then return some 0
  try
    let zr ← Std.Time.Database.defaultGetZoneRules tz.trimAscii.toString
    let ts := Std.Time.Timestamp.ofSecondsSinceUnixEpoch (.ofInt t.floor.toInt64.toInt)
    return some (zr.timezoneAt ts).offset.second.val
  catch _ => return none

/-- When the usage limit a run's outcome names resets, if it names one in a form understood here,
within eight days. -/
def limitResets (outcome : String) (at_ : Float) : IO (Option Float) := do
  let some (md, h, mi, tz) := parseResets outcome | return none
  let some off ← offsetAt tz at_ | return none
  let local_ : Int := at_.floor.toInt64.toInt + off
  let day := if local_ ≥ 0 then local_ / 86400 else (local_ - 86399) / 86400
  let clockSecs : Int := h * 3600 + mi * 60
  let target : Int ← match md with
    | some (m, d) => do
      let (y, _, _) := Time.civilFromDays day
      let t := Time.daysFromCivil y m d * 86400 + clockSecs
      pure (if t < local_ - 86400 then Time.daysFromCivil (y + 1) m d * 86400 + clockSecs else t)
    | none =>
      let t := day * 86400 + clockSecs
      -- A clock a little ahead of the API's is still today.
      pure (if t < local_ - 3600 then t + 86400 else t)
  let reset := Float.ofInt (target - off)
  return if reset - at_ < 8 * 86400 then some reset else none

/-- Queue a run's work again without counting it as a try: after the usage limit its outcome
names resets, or else after the next of the environment's delays. The human hears once while runs
keep failing this way. -/
def envRetry (agent : String) (runId : Nat) (outcome : String) : D Unit := do
  let e ← read
  let t ← now
  let k := ((← kvGet s!"env-failures:{agent}").bind String.toNat?).getD 0
  kvSet s!"env-failures:{agent}" (toString (k + 1))
  let reset ← limitResets outcome t
  let delays := e.timings.envDelays
  let until_ : Float := match reset with
    | some r => max (r + e.timings.limitMargin) (t + 60)
    | none => t + (delays[min k (delays.length - 1)]?).getD 3600
  exec "UPDATE triggers SET run_id=NULL, not_before=?, env_held=1 WHERE run_id=?" [until_, runId]
  -- A usage limit is the account's, so every agent's held work waits for it, and none longer.
  if reset.isSome then exec "UPDATE triggers SET not_before=? WHERE env_held=1 AND run_id IS NULL" [until_]
  let since ← match ← kvGet "env-failing" with
    | some s => pure s
    | none => do let s := Time.iso t; kvSet "env-failing" s; pure s
  let minutes := ", then ".intercalate (delays.map fun d => s!"{(d / 60).floor.toUInt64} minutes")
  discard <| addNotice s!"env-failing:{since}" "env-failing" none none
    (s!"runs are failing before they get going ({agent} run {runId}: {outcome}). Their work is retried " ++
     match reset with
     | some _ => s!"after the usage limit resets, at {Time.iso until_}. "
     | none => s!"after {minutes}, and then at that interval, until runs get going again. Look for an outage, the proxy or the Claude credential.")
  log s!"{agent} run {runId} {outcome}: its work is queued again at {Time.iso until_}{if reset.isSome then ", when the usage limit has reset" else ""}"

/-- The agent's run got going: its environment works again, and the agents share most of it, so
work held back for theirs is due now too. -/
def gotGoing (agent : String) : D Unit := do
  let t ← now
  exec "DELETE FROM kv WHERE key=?" [s!"env-failures:{agent}"]
  let held ← q "SELECT DISTINCT agent FROM triggers WHERE env_held=1 AND run_id IS NULL AND not_before>?" [t]
  unless held.isEmpty do
    exec "UPDATE triggers SET not_before=?, env_held=0 WHERE env_held=1 AND run_id IS NULL" [t]
    log s!"{agent}'s run got going: work held back for the environment is due now ({", ".intercalate (held.toList.map (·.str "agent"))})"
  if (← q "SELECT 1 FROM kv WHERE key LIKE 'env-failures:%'").isEmpty then exec "DELETE FROM kv WHERE key='env-failing'"

def jsonStr (j : Json) (k : String) : Option String := (j.getObjVal? k).toOption.bind (·.getStr?.toOption)
def jsonNum (j : Json) (k : String) : Option Json.Number := (j.getObjVal? k).toOption.bind (·.getNum?.toOption)

/-- A run ended, as its runner reports it. Whether the run was this agent's. -/
def endRun (agent : String) (runId : Nat) (r : Json) : D Bool := do
  let e ← read
  let rows ← q "SELECT claimed FROM runs WHERE id=? AND agent=?" [runId, agent]
  let some row := rows[0]? | return false
  let t ← now
  let changes : Nat := ((← q "SELECT COUNT(*) AS n FROM events WHERE sender=? AND at>=? AND at<=?"
    [agent, row.real "claimed", (t + 5 : Float)])[0]?.map (·.nat "n")).getD 0
  let outcome := (jsonStr r "outcome").getD ""
  let cost := (jsonNum r "cost").map (·.toFloat)
  let turns := (jsonNum r "turns").bind (·.toNat?)
  let inExt := ((r.getObjVal? "in_extension").toOption.bind (·.getBool?.toOption)).getD false
  let denied := ((r.getObjVal? "denied").toOption.getD (.arr #[])).compress
  exec "UPDATE runs SET ended=?, outcome=?, cost=?, turns=?, denied=?, session_id=?, log=?, transcript=?,
    in_extension=?, forge_changes=?, archived_log=?, archived_transcript=? WHERE id=?"
    [t, outcome, Val.opt cost, Val.opt turns, denied, Val.opt (jsonStr r "session_id"), Val.opt (jsonStr r "log"),
     Val.opt (jsonStr r "transcript"), inExt, changes, Val.opt (jsonStr r "archived_log"),
     Val.opt (jsonStr r "archived_transcript"), runId]
  -- A usage limit cuts a run short however far it got: its environment's fault, not its work's.
  let idle := neverGotGoing outcome turns cost changes || (← limitResets outcome t).isSome
  unless idle do gotGoing agent
  if (← paused) && outcome != "interrupted" then
    requeue runId  -- the pause refused its tool calls: it did what it could, not its work
  else if idle then envRetry agent runId outcome
  else
    let retried ← if outcome == "completed" || outcome == "interrupted" then pure false else retry agent runId outcome
    -- Done, stopped by the human, or given up on: what it left owing moves on.
    unless retried do
      e.later 30 do
        try (evaluateAfterRun agent).run e catch err => e.log s!"evaluating after {agent}'s run failed: {err}"
  if let some sid := jsonStr r "session_id" then
    if !inExt && !sid.isEmpty then
      notifyAgent agent s!"not-listed:{agent}:{runId}" "transcript-rewrite" s!"Run {runId} of {agent} isn't listed in the Claude extension" [
        ("Question", s!"Run {runId} of `{agent}` isn't listed in the Claude extension in its container, because its transcript couldn't be rewritten. Do you need to open that conversation?"),
        ("Options", s!"- Resume it by its session ID: `claude --resume {sid}` in `{agent}`'s container.\n- Leave it: its log and transcript are in the run archive."),
        ("Recommendation", "Leave it unless you need that conversation. If this keeps happening, the runner's transcript rewrite needs fixing in the kit."),
        ("If you say go ahead", "Nothing happens. Close this issue."),
        ("Blocked on this", "Nothing.")]
  log s!"{agent} run {runId} ended: {outcome}"
  return true

end Guild.Dispatcher
