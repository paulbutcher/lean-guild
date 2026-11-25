/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
module

public import Guild.Agent.Runner
public import Guild.Agent.Env

/-! `guild-runner`, which the container's entry point runs for the life of the container, and
`guild-runner stop`, which interrupts the current run. Besides the agent's own settings it reads
`AGENT_WORKSPACE`, `DISPATCHER_URL`, `RUNNER_KEY_FILE`, `MAX_RUN_MINUTES`, `RUNNER_TICK_SECONDS`, `CLAUDE_BIN`
and `CLAUDE_CONFIG_DIR`. -/

@[expose] public section

namespace Guild.Agent.Runner

open Guild.Agent Json

structure Env where
  agent : String
  /-- Claude Code's command. -/
  claude : String := "claude"
  workspace : System.FilePath
  /-- The human's sessions and the runner's own records. -/
  state : System.FilePath
  /-- Run logs, in the agent's own workspace. -/
  logs : System.FilePath
  archive : System.FilePath
  claudeDir : System.FilePath
  dispatcher : Dispatcher
  maxMinutes : Nat
  tick : Nat

def log (m : String) : IO Unit := do
  let err ← IO.getStderr
  err.putStrLn s!"guild-runner: {m}"
  err.flush

def shell (cmd : String) (args : List String) : IO String := do
  let out ← IO.Process.output { cmd, args := args.toArray }
  return out.stdout.trimAscii.toString

def nowIso : IO String := shell "date" ["-u", "+%Y-%m-%dT%H:%M:%SZ"]

def uuid : IO String := do
  let b := (← IO.getRandomBytes 16).toList.map (·.toNat)
  let hex (n : Nat) := String.ofList [Nat.digitChar (n / 16), Nat.digitChar (n % 16)]
  let b := b.set 6 ((b.getD 6 0 % 16) + 64) |>.set 8 ((b.getD 8 0 % 64) + 128)
  let h := String.join (b.map hex)
  return s!"{h.take 8}-{(h.drop 8).take 4}-{(h.drop 12).take 4}-{(h.drop 16).take 4}-{h.drop 20}"

def archiveFile (e : Env) (src : System.FilePath) (rel : String) : IO String := do
  try
    let dst := e.archive / rel
    if let some parent := dst.parent then IO.FS.createDirAll parent
    IO.FS.writeBinFile dst (← IO.FS.readBinFile src)
    return dst.toString
  catch err =>
    log s!"couldn't archive {src}: {err}"
    return ""

/-! ## The human's sessions -/

/-- Reports the human's session starts and ends, which the hook records, and archives their
transcripts. A failed report is tried again next time, from the same place. -/
def syncSessions (e : Env) : IO Unit := do
  let path := e.state / "sessions.jsonl"
  let offsetFile := e.state / "sessions.offset"
  unless ← path.pathExists do return
  let mut offset := ((← try IO.FS.readFile offsetFile catch _ => pure "0").trimAscii.toString.toNat?).getD 0
  let bytes ← IO.FS.readBinFile path
  let text := (String.fromUTF8? (bytes.extract offset bytes.size)).getD ""
  for line in (text.splitOn "\n").filter (· ≠ "") do
    if let .ok ev := parse line then
      if str ev "event" == some "end" then
        if let some t := str ev "transcript" then
          if !t.isEmpty then discard <| archiveFile e t s!"sessions/{(str ev "session").getD "unknown"}.jsonl"
      if (← e.dispatcher.call .post "/sessions" ev).isNone then return
    offset := offset + line.utf8ByteSize + 1
    IO.FS.writeFile offsetFile (toString offset)

/-! ## A run -/

def stopFile (e : Env) : System.FilePath := e.state / "stop-run"

def interrupt (pid : UInt32) : IO Unit :=
  discard <| IO.Process.output { cmd := "sh", args := #["-c", s!"kill -INT {pid}"] }

def transcriptFor (e : Env) (session : String) : IO (Option System.FilePath) := do
  let projects := e.claudeDir / "projects"
  unless ← projects.isDir do return none
  for d in ← projects.readDir do
    let p := d.path / s!"{session}.jsonl"
    if ← p.pathExists then return some p
  return none

def run (e : Env) (id : Nat) (triggers : List String) : IO Unit := do
  -- A library added since the container started: clone it before the run.
  discard <| (IO.Process.output { cmd := "guild-clone-all", args := #["--quick"] }).toBaseIO
  let session ← uuid
  let stamp ← shell "date" ["-u", "+%Y%m%d-%H%M%S"]
  IO.FS.createDirAll (e.logs / "runs")
  let logPath := e.logs / "runs" / s!"{stamp}-{session.take 8}.md"
  let name := (s!"{e.agent}: {", ".intercalate triggers}".take 120).toString
  discard <| e.dispatcher.call .post s!"/runs/{id}/start"
    (some (Json.mkObj [("session_id", toJson session), ("log", toJson logPath.toString)]))
  let header := s!"# {name}\n\nRun {id}, session `{session}`, started {← nowIso}.\n\n" ++
    String.join (triggers.map (s!"- {·}\n")) ++ "\n---\n\n"
  let logH ← IO.FS.Handle.mk logPath .write
  let current ← IO.FS.Handle.mk (e.logs / "current.md") .write
  let write (t : String) : IO Unit := do
    for h in [logH, current] do h.putStr t; h.flush
  write header
  log s!"run {id} started: {", ".intercalate triggers}"
  let child ← IO.Process.spawn
    { cmd := e.claude, cwd := e.workspace, stdout := .piped, stderr := .piped,
      env := #[("GUILD_RUN", some "1")],
      args := #["-p", "--permission-mode", "dontAsk", "--output-format", "stream-json", "--verbose",
                "--session-id", session, "--name", name, prompt triggers] }
  let stderrTask ← IO.asTask child.stderr.readToEnd
  let done ← IO.mkRef false
  let timedOut ← IO.mkRef false
  let interrupted ← IO.mkRef false
  let started ← IO.monoMsNow
  -- Watches for the time limit and for `guild-runner stop`.
  let watcher ← IO.asTask do
    repeat
      if ← done.get then break
      if (← IO.monoMsNow) - started > e.maxMinutes * 60000 then
        timedOut.set true; interrupt child.pid; break
      if ← (stopFile e).pathExists then
        IO.FS.removeFile (stopFile e)
        interrupted.set true; log "interrupting the run"; interrupt child.pid; break
      IO.sleep 1000
  let mut result : Option Json := none
  repeat
    let line ← child.stdout.getLine
    if line.isEmpty then break
    if let .ok ev := parse line then
      let (md, r) := render ev
      unless md.isEmpty do write md
      if r.isSome then result := r
  let code ← child.wait
  done.set true
  discard <| IO.wait watcher
  let err := match ← IO.wait stderrTask with
    | .ok s => s.trimAscii.toString
    | .error _ => ""
  let outcome := outcome e.maxMinutes (← timedOut.get) (← interrupted.get) result code
  let r := result.getD (Json.mkObj [])
  let denied := (arr r "permission_denials").map fun d =>
    Json.mkObj [("tool", (d.getObjVal? "tool_name").toOption.getD .null), ("input", (d.getObjVal? "tool_input").toOption.getD .null)]
  if !err.isEmpty && outcome != "completed" then write s!"\n**stderr**\n{fence}\n{clip err}\n{fence}\n"
  let transcript ← transcriptFor e session
  let rewritten ← match transcript with
    | some t =>
      let (text, n) := rewriteEntrypoint (← IO.FS.readFile t)
      if n > 0 then IO.FS.writeFile t text
      pure n
    | none => pure 0
  let cost := ((r.getObjVal? "total_cost_usd").toOption.bind (·.getNum?.toOption)).map (·.toFloat) |>.getD 0
  let turns := ((r.getObjVal? "num_turns").toOption.bind (·.getNat?.toOption)).getD 0
  write (s!"\n---\n\nEnded {← nowIso}: {outcome}. Cost ${(cost * 100).round / 100}, {turns} turns, " ++
    s!"{denied.length} denied command(s). " ++
    (if rewritten > 0 then "Listed in the extension." else "**Not listed in the extension**; resume it by ID.") ++ "\n")
  logH.flush; current.flush
  let report := Json.mkObj [
    ("outcome", toJson outcome), ("cost", (r.getObjVal? "total_cost_usd").toOption.getD .null),
    ("turns", (r.getObjVal? "num_turns").toOption.getD .null), ("denied", Json.arr denied.toArray),
    ("session_id", toJson session), ("log", toJson logPath.toString),
    ("transcript", toJson ((transcript.map (·.toString)).getD "")), ("in_extension", toJson (decide (rewritten > 0))),
    ("archived_log", toJson (← archiveFile e logPath s!"runs/{stamp}-{session}.md")),
    ("archived_transcript", toJson (← match transcript with
      | some t => archiveFile e t s!"runs/{stamp}-{session}.jsonl"
      | none => pure ""))]
  for _ in List.range 20 do
    if (← e.dispatcher.call .post s!"/runs/{id}/end" (some report)).isSome then break
    IO.sleep 15000
  log s!"run {id} ended: {outcome}"

def loop (e : Env) : IO Unit := do
  IO.FS.createDirAll e.state
  -- A run claimed before a restart can't be finished; tell the dispatcher.
  discard <| e.dispatcher.call .post "/runs/abandon" (some (Json.mkObj []))
  -- The human's sessions come and go while a run is under way, so they're reported from a task
  -- of their own.
  discard <| IO.asTask do
    repeat
      try syncSessions e catch err => log s!"sessions: {err}"
      IO.sleep (e.tick * 1000).toUInt32
  repeat
    try
      if let some (200, j) ← e.dispatcher.call .post "/claim" (some (Json.mkObj [])) then
        if let some (id, triggers) := claimOf j then
          run e id triggers
          continue
    catch err => log s!"error: {err}"
    IO.sleep (e.tick * 1000).toUInt32


end Guild.Agent.Runner
