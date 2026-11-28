/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
module

public import Guild.Dispatcher.Claims

/-! What the kit is doing, for the human: the status JSON the web UI's pages serve, its summary,
the activity stream and the notices. None of it reads the forge: whether CI runs comes from what
the webhooks marked and the last checks found. -/

@[expose] public section

namespace Guild.Dispatcher

open Json

/-! ## CI under way -/

/-- A webhook that can start or end a CI run marks its repository, to be checked. -/
def ciMayRun (repo : String) : D Unit := do
  let e ← read
  if (e.owner? repo).isSome && e.hasCi repo then
    let t ← now
    withCaches fun c => c.ciMarked.modify (·.insert repo t)

/-- Whether a CI run is under way on a repository. A run left waiting for over an hour, its pull
request closed before a runner took it, doesn't count. -/
def ciBusy (repo : String) : D Bool := do
  if ← cached s!"missing:{repo}" 300 (fun | .flag b => some b | _ => none) .flag (forgeMissing repo) then return false
  let t ← now
  let runs ← fg ((← forge).activeRuns repo)
  return runs.any fun r => r.status == .running || (r.status == .waiting && t - Time.when r.created < 3600)

/-- Check the repositories marked or found busy, or with `every`, all of them. A repository marked
again during its check stays marked, and one that can't be checked is marked. -/
def refreshCi (every := false) : D Unit := do
  let e ← read
  let repos ← if every then pure (e.repos.filter e.hasCi)
    else withCaches fun c => do return ((← c.ciMarked.get).toList.map (·.1) ++ (← c.ciBusy.get)).eraseDups
  for repo in repos do
    let checked ← now
    try
      let b ← ciBusy repo
      withCaches fun c => do
        c.ciBusy.modify fun l => if b then (if l.contains repo then l else repo :: l) else l.erase repo
        c.ciMarked.modify fun m => if m[repo]?.any (· ≤ checked) then m.erase repo else m
    catch err =>
      log s!"couldn't tell whether CI runs on {repo}: {err}"
      ciMayRun repo

def ciRunning : D Bool := withCaches fun c => do
  return !(← c.ciMarked.get).isEmpty || !(← c.ciBusy.get).isEmpty

/-- The repositories where CI may be running: marked by a webhook, or found busy. -/
def ciRepos : D (List String) := withCaches fun c => do
  return (((← c.ciMarked.get).toList.map (·.1)) ++ (← c.ciBusy.get)).eraseDups.mergeSort (· ≤ ·)

/-- What a clean stop waits for: runs not yet ended, and CI. -/
def underWay : D (List String) := do
  let runs ← q "SELECT id, agent FROM runs WHERE ended IS NULL ORDER BY id"
  return runs.toList.map (fun r => s!"{r.str "agent"}'s run {r.nat "id"}") ++ (if ← ciRunning then ["CI"] else [])

/-- The open items that wait on the human, as sorted `repo#n`, from the index the evaluations keep. -/
def waitingForHuman : D (List String) := do
  let e ← read
  return (← q "SELECT repo, number FROM human_waits ORDER BY repo, number").toList.filterMap fun r =>
    if (e.owner? (r.str "repo")).isSome then some (itemUnit (r.str "repo") (r.nat "number")) else none

/-! ## The summary -/

/-- A duration, as the human would say it. -/
def span (seconds : Float) : String :=
  let m := (seconds / 60).floor.toUInt64.toNat
  if m < 1 then "under a minute"
  else if m < 120 then s!"{m} minute{if m == 1 then "" else "s"}"
  else s!"{m / 60} hours"

def clipLine (text : String) (n : Nat) : String :=
  if text.length ≤ n then text else ((text.take (n - 1)).toString.trimAsciiEnd.toString) ++ "…"

def plural (n : Nat) (one many : String) : String := if n == 1 then one else many

/-- While runs fail before they get going: since when, for whom, and the latest such run's outcome. -/
def envFailingText : D (Option String) := do
  let some since ← kvGet "env-failing" | return none
  let agents := ((← q "SELECT key FROM kv WHERE key LIKE 'env-failures:%'").toList.map fun r =>
    ((r.str "key").drop 13).toString).mergeSort (· ≤ ·)
  if agents.isEmpty then return none
  let ended ← q "SELECT agent, outcome FROM runs WHERE ended IS NOT NULL ORDER BY ended DESC"
  let latest := match ended.toList.find? (fun r => agents.contains (r.str "agent")) with
    | some r => s!"; the latest, {r.str "agent"}'s, ended {clipLine ((r.str? "outcome").getD "?") 160}"
    | none => ""
  return some s!"runs have failed before getting going since {since} ({", ".intercalate agents}){latest}. Their work is tried again when due"

/-- Whether the kit will make progress by itself, is stuck, or waits for the human, on its first
line; then a line for each thing it is doing or waiting on. -/
def kitSummary : D String := do
  let e ← read
  let t ← now
  let waiting := (← waitingForHuman).length
  let wait := if waiting > 0 then s!"{waiting} item{plural waiting "" "s"} wait{plural waiting "s" ""} on you" else "nothing waits on you"
  if ← paused then return s!"Kit: paused, nothing starts until it is resumed; {wait}"
  if ← draining then
    let left ← underWay
    return s!"Kit: draining, nothing starts until it is resumed; {wait}\n" ++
      (if left.isEmpty then "  - drained: safe to stop" else "\n".intercalate (left.map (s!"  - finishing: {·}")))
  let runs ← q "SELECT id, agent, triggers, claimed, started FROM runs WHERE ended IS NULL ORDER BY id"
  let queued ← q "SELECT id, agent, created, not_before FROM triggers WHERE run_id IS NULL"
  let mut cappedAgents : List String := []
  for a in (queued.toList.map (·.str "agent")).eraseDups do
    if (← capped a).isSome then cappedAgents := a :: cappedAgents
  cappedAgents := cappedAgents.mergeSort (· ≤ ·)
  let queued := queued.toList.filter fun r => !cappedAgents.contains (r.str "agent")
  let later := queued.filter fun r => (r.real? "not_before").any (· > t)
  let mut work : List String := []
  let mut stuck : List String := []
  for r in runs do
    if let some started := r.real? "started" then
      let triggers := ((parse (r.str "triggers")).toOption.bind fun j => (fromJson? (α := List String) j).toOption).getD []
      let more := if triggers.length > 1 then s!" (and {triggers.length - 1} more)" else ""
      work := work ++ [s!"{r.str "agent"} running for {span (t - started)}: {clipLine (triggers.head?.getD "its work") 100}{more}"]
    else if t - r.real "claimed" > 120 then
      stuck := stuck ++ [s!"{r.str "agent"}'s run {r.nat "id"} was claimed {span (t - r.real "claimed")} ago and hasn't started (closed by itself after {(e.timings.claimStart / 60).floor.toUInt64} minutes, or restart its container)"]
    else work := work ++ [s!"{r.str "agent"} starting a run"]
  let busyAgents := runs.toList.map (·.str "agent")
  for agent in ((queued.map (·.str "agent")).eraseDups.mergeSort (· ≤ ·)) do
    let mine := queued.filter (·.str "agent" == agent)
    let laterIds := later.map (·.nat "id")
    let silent ← if !busyAgents.contains agent && mine.any (fun r => !laterIds.contains (r.nat "id")) then runnerSilentFor agent else pure none
    if let some s := silent then
      stuck := stuck ++ [s!"{mine.length} queued for {agent}, whose runner hasn't called in for {span s}: restart its container"]
      continue
    let due := (mine.filter fun r => laterIds.contains (r.nat "id")).map (·.real "not_before")
    let held := match due.min? with
      | some m => s!" ({due.length} not yet due, the first at {Time.iso m})"
      | none => ""
    let oldest := ((mine.map (·.real "created")).min?).getD t
    work := work ++ [s!"{mine.length} queued for {agent}, the oldest for {span (t - oldest)}{held}"]
  if ← ciRunning then work := work ++ ["CI running"]
  let failing ← envFailingText
  let mut notes : List String := []
  unless cappedAgents.isEmpty do
    notes := notes ++ [s!"capped with work waiting: {", ".intercalate cappedAgents} (raise its cap, or it waits for midnight UTC)"]
  let head :=
    if !stuck.isEmpty then "stuck" else if failing.isSome then "failing" else if !work.isEmpty then "working"
    else if waiting > 0 || !cappedAgents.isEmpty then "quiet, nothing happens until you act" else "quiet"
  if head == "quiet" then
    notes := notes ++ [s!"once it has been quiet for {(e.timings.idle / 60).floor.toUInt64} minutes, the coordinator summarises what waits on you"]
  let lines := stuck.map (s!"stuck: {·}") ++ (failing.map (s!"failing: {·}")).toList ++ work ++ notes
  return "\n".intercalate (s!"Kit: {head}; {wait}" :: lines.map (s!"  - {·}"))

/-! ## Backups

`scripts/backup.sh` records its last success in `control/backup-ok`, as its time and folder, and
its last failure in `control/backup-failed`, as its time and log, one per line. -/

/-- A day's backup and a few hours' grace, for a Mac that slept through 03:30. -/
def backupDue : Float := 26 * 3600

def backupRecord (name : String) : D (Option (Float × String)) := do
  let path := (← read).control / name
  unless ← path.pathExists do return none
  match (← IO.FS.readFile path).splitOn "\n" with
  | t :: rest => return (parseFloat? t.trimAscii.toString).map (·, (rest.headD "").trimAscii.toString)
  | [] => return none

/-- A failure newer than the last success is a notice, and so is no success for `backupDue`,
counted from the first start when there has never been one: the job may never have run. -/
def checkBackups : D Unit := do
  let ok ← backupRecord "backup-ok"
  if let some (at_, logFile) ← backupRecord "backup-failed" then
    if ok.all (·.1 < at_) then
      let see := if logFile.isEmpty then "scripts/backup.sh's output" else logFile
      discard <| addNotice s!"backup-failed:{at_.floor.toUInt64}" "backup" none none
        s!"The backup at {Time.iso at_} failed: see {see}."
  let since ← match ok with | some (t, _) => pure t | none => firstStarted
  if (← now) - since > backupDue then
    let what := if ok.isSome then s!"since {Time.iso since}" else s!"since the kit started on {Time.iso since}"
    discard <| addNotice s!"backup-missed:{since.floor.toUInt64}" "backup" none none
      s!"No backup has succeeded {what}. Check that the daily backup is installed (scripts/backup-install.sh) and that Docker was running at 03:30."

def backupJson : D Json := do
  let entry (name field : String) : D Json := do
    return match ← backupRecord name with
      | some (t, v) => Json.mkObj [("at", toJson (Time.iso t)), (field, toJson v)]
      | none => .null
  return Json.mkObj [("ok", ← entry "backup-ok" "folder"), ("failed", ← entry "backup-failed" "log")]

/-! ## JSON -/

def isoOrNull (v : Val) : Json := match v.real? with
  | some t => if t == 0 then .null else toJson (Time.iso t)
  | none => .null

def valJson : Val → Json
  | .null => .null
  | .int i => toJson i
  | .real f => match Json.Number.ofFloat? f with | some n => .num n | none => .null
  | .text s => toJson s

/-- A row as JSON, with the named columns as ISO times and the others parsed as JSON lists. -/
def rowJson (r : Row) (times : List String := []) (lists : List String := []) : Json :=
  Json.mkObj (r.cols.toList.map fun (k, v) =>
    (k, if times.contains k then isoOrNull v
        else if lists.contains k then ((v.str?.bind fun s => (parse s).toOption).getD (.arr #[]))
        else valJson v))

def status : D Json := do
  let e ← read
  let mut agents : List (String × Json) := []
  for a in e.agents do
    let pending ← q "SELECT description, created, not_before FROM triggers WHERE agent=? AND run_id IS NULL ORDER BY created" [a.name]
    agents := agents ++ [(a.name, Json.mkObj [
      ("state", toJson (← agentState a.name)), ("runs_today", toJson (← runsToday a.name)),
      ("cap", toJson (e.capOf a.name)), ("spend_today", valJson (.real (← spendToday a.name))),
      ("spend_cap", match e.bounds.maxSpendPerDay with | some c => toJson c | none => .null),
      ("pending", Json.arr (pending.map fun p => Json.mkObj [("trigger", toJson (p.str "description")),
        ("since", isoOrNull (p.get "created")), ("after", isoOrNull (p.get "not_before"))]))])]
  let runs ← q "SELECT * FROM runs ORDER BY id DESC LIMIT 50"
  let sessions ← q "SELECT * FROM sessions ORDER BY id DESC LIMIT 20"
  let notices ← q "SELECT * FROM notices ORDER BY id DESC LIMIT 50"
  let obligations ← q "SELECT unit, agent, what, description, wakes, escalated, since, next_at FROM obligations ORDER BY agent, since"
  let units ← q "SELECT unit, kind, state, holders, step, since FROM units ORDER BY unit"
  let drain ← draining
  let left ← if drain then some <$> underWay else pure none
  let reconciled ← kvGet "reconciled"
  return Json.mkObj [
    ("paused", toJson (← paused)), ("draining", toJson drain),
    ("under_way", match left with | some l => toJson l | none => .null),
    ("drained", toJson (drain && left.any (·.isEmpty))),
    ("reconciled", match reconciled.bind parseFloat? with | some t => toJson (Time.iso t) | none => .null),
    ("stopped", toJson (← e.agents.filterMapM fun a => do return if ← stopped a.name then some a.name else none)),
    ("waiting_on_you", toJson (← waitingForHuman)),
    ("ci", toJson (← ciRepos)),
    ("agents", Json.mkObj agents),
    ("runs", Json.arr (runs.map (rowJson · ["claimed", "started", "ended"] ["triggers", "denied"]))),
    ("sessions", Json.arr (sessions.map (rowJson · ["started", "ended"]))),
    ("notices", Json.arr (notices.map (rowJson · ["at", "seen"]))),
    ("obligations", Json.arr (obligations.map (rowJson · ["since", "next_at"]))),
    ("units", Json.arr (units.map (rowJson · ["since"] ["holders"]))),
    ("backup", ← backupJson),
    ("summary", toJson (← kitSummary))]

/-- The human has seen notice `id`, if there is one. Seeing a run budget's notice starts its unit's
count again. -/
def markSeen (id : Nat) : D Bool := do
  let some n := (← q "SELECT key, kind FROM notices WHERE id=?" [id])[0]? | return false
  let t ← now
  exec "UPDATE notices SET seen=? WHERE id=? AND seen IS NULL" [t, id]
  -- Its key is `budget:<unit>:<when the count last started>`.
  if n.str "kind" == "budget" then
    let parts := ((n.str "key").dropPrefix "budget:").toString.splitOn ":"
    let unit := ":".intercalate parts.dropLast
    unless unit.isEmpty do kvSet s!"budget-seen:{unit}" (toString t)
  return true

/-- The reviews the dispatcher has read, from its item cache alone like the rest of the status:
each pull request's, updated in the last `days`, with their verdicts; each milestone's reports;
and each recommendation, with what became of it. -/
def reviews (days : Nat) : D Json := do
  let e ← read
  let t ← now
  let items ← withCaches fun c => do return (← c.items.get).toList
  let recent (r : ItemRead) := t - Time.when r.issue.updatedAt ≤ days.toFloat * 86400
  let byUpdate := (items.filter (recent ·.2)).mergeSort fun a b => a.2.issue.updatedAt ≥ b.2.issue.updatedAt
  let verdict : Forge.Verdict → String
    | .approve => "approved" | .requestChanges => "changes requested" | .comment => "commented"
    | .other v => v
  let pulls := byUpdate.filter (fun (_, r) => r.pull.isSome && !r.reviews.isEmpty) |>.map fun (unit, r) =>
    Json.mkObj [("unit", toJson unit), ("title", toJson r.issue.title), ("author", toJson r.issue.author),
      ("open", toJson r.issue.isOpen),
      ("reviews", toJson (r.reviews.map fun (v : Forge.Review) => Json.mkObj [("by", toJson v.author),
        ("verdict", toJson (verdict v.verdict)), ("at", toJson v.submittedAt),
        ("current", toJson (!v.stale && !v.dismissed))]))]
  let milestones := byUpdate.filter (fun (unit, r) =>
      unit.startsWith s!"{e.coordination}#" && r.issue.labels.contains "milestone-review") |>.map fun (unit, r) =>
    Json.mkObj [("unit", toJson unit), ("title", toJson r.issue.title), ("open", toJson r.issue.isOpen),
      ("reports", toJson (r.timeline.filterMap fun (en : Forge.Entry) => match en.event with
        | Forge.Event.comment .. => if e.milestoneReviewers.contains en.actor then
            some (Json.mkObj [("by", toJson en.actor), ("at", toJson en.time)]) else none
        | _ => none))]
  let recommendations := byUpdate.filter (·.2.issue.labels.contains "recommendation") |>.map fun (unit, r) =>
    let by_ := (r.issue.labels.find? (fun (l : String) => l.startsWith "review:")).map fun (l : String) => (l.drop 7).toString
    let outcome := if r.issue.isOpen then "open"
      else if r.issue.labels.contains "declined" then "declined" else "accepted"
    Json.mkObj [("unit", toJson unit), ("title", toJson r.issue.title), ("review", toJson by_),
      ("outcome", toJson outcome)]
  return Json.mkObj [("days", toJson days), ("pulls", toJson pulls), ("milestones", toJson milestones),
    ("recommendations", toJson recommendations)]

/-- One notice per line: id, kind, where, text, with tabs and newlines removed. -/
def noticesText (after : Nat) : D String := do
  let rows ← q "SELECT * FROM notices WHERE id>? ORDER BY id" [after]
  let clean (s : String) := " ".intercalate ((s.splitToList Char.isWhitespace).filter (!·.isEmpty))
  return String.join (rows.toList.map fun n =>
    let where_ := match n.nat? "number" with
      | some k => if k > 0 then s!"{n.str "repo"}#{k}" else n.str "repo"
      | none => n.str "repo"
    s!"{n.nat "id"}\t{n.str "kind"}\t{where_}\t{clean (n.str "text")}\n")

/-! ## Idle summaries -/

/-- When anything last happened: an event, work queued, a run ending or the dispatcher starting,
leaving out the idle summaries themselves and the human's sessions. -/
def lastActivity : D Float := do
  let e ← read
  let m (sql : String) (args : List Val := []) : D Float := do
    return (((← q sql args)[0]?).bind (·.real? "m")).getD 0
  return [e.started, ← m "SELECT MAX(at) AS m FROM events",
    ← m "SELECT MAX(created) AS m FROM triggers WHERE key NOT LIKE 'idle:%'",
    ← m "SELECT MAX(ended) AS m FROM runs WHERE triggers NOT LIKE ?" ["%the kit is idle%"]].foldl max 0

/-- Once the kit has gone quiet (no run, no queued work but an agent's held by its cap or a stop,
no CI, and nothing new for the idle time), wake the coordinator to tell the human what it needs
from them, once per quiet spell, and only when what waits on them has changed since the last. -/
def checkIdle : D Unit := do
  let e ← read
  let some coord := e.coordinator? | return
  if e.timings.idle ≤ 0 || (← paused) || (← draining) then return
  unless (← q "SELECT 1 FROM runs WHERE ended IS NULL").isEmpty do return
  for r in ← q "SELECT DISTINCT agent FROM triggers WHERE run_id IS NULL" do
    if (← capped (r.str "agent")).isNone && !(← stopped (r.str "agent")) then return
  let last ← lastActivity
  let t ← now
  if t - last < e.timings.idle || (← kvFloat "idle-summary") ≥ last then return
  if ← ciRunning then return
  kvSet "idle-summary" (toString t)
  let items ← waitingForHuman
  let encoded := (toJson items).compress
  if (← kvGet "idle-waiting") == some encoded then
    log "quiet, and the same items wait on the human as at the last idle summary: no summary"
    return
  kvSet "idle-waiting" encoded
  let n := items.length
  let waiting := if n > 0 then s!"{n} item{plural n "" "s"} wait{plural n "s" ""} on you" else "nothing waits on you"
  discard <| addTrigger coord s!"idle:{t.floor.toUInt64}" s!"the kit is idle; {waiting}"

end Guild.Dispatcher
