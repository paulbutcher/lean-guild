/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
module

public import Guild.Agent.Guard
public import Guild.Control
public import Guild.Forge.Forgejo

/-! Claude Code's hooks in an agent's container, which its managed settings call.

  `guild-hook pre-tool`       in a run, while paused, refuse every tool call; in the human's
                              session, refuse what would change the shared checkouts
  `guild-hook session-start`  the human's session opened: record it, and say that it only consults
  `guild-hook stop`           a run may not stop with untriaged requests
  `guild-hook session-end`    the human's session closed: record it

A session is the human's when Claude Code's entry point is the editor's or the command line's and
the runner didn't start it. -/

@[expose] public section

namespace Guild.Agent

open Json Guild.Forge

structure HookEnv where
  /-- Set by the runner for its runs. -/
  run : Bool
  entrypoint : String
  /-- Where sessions are recorded, for the runner to report. -/
  state : System.FilePath
  control : System.FilePath
  repo : Option String
  /-- Accounts whose requests count, so issue text from anyone else never steers a run. -/
  trusted : List String
  guard : Guard
  forge : IO (Option Forge)

def HookEnv.human (e : HookEnv) : Bool :=
  (e.entrypoint == "claude-vscode" || e.entrypoint == "cli") && !e.run

def denial (reason : String) (stop : Bool) : Json :=
  let decision := Json.mkObj [("hookEventName", toJson "PreToolUse"), ("permissionDecision", toJson "deny"),
    ("permissionDecisionReason", toJson reason)]
  Json.mkObj ([("hookSpecificOutput", decision)] ++
    if stop then [("continue", toJson false), ("stopReason", toJson reason)] else [])

def sessionContext : String :=
  "This session is the human's, not one of your runs, and your runs go on beside it in the same " ++
  "checkouts. Follow \"Sessions with the human\" in your protocol: look, try things in your own clone " ++
  "outside /workspace, and advise; file issues and comment, and change nothing else. The rest of the " ++
  "protocol's actions are for your runs."

def str (j : Json) (k : String) : Option String := (j.getObjVal? k).toOption.bind (·.getStr?.toOption)

def recordSession (e : HookEnv) (event : String) (data : Json) : IO Unit := do
  IO.FS.createDirAll e.state
  let line := Json.mkObj [("event", toJson event), ("session", toJson ((str data "session_id").getD "")),
    ("transcript", toJson ((str data "transcript_path").getD "")), ("at", toJson ((← IO.monoMsNow) / 1000))]
  IO.FS.withFile (e.state / "sessions.jsonl") .append fun h => h.putStrLn line.compress

/-- Open requests on the agent's own repository that are still `new`, by trusted authors. Never
fails: an unreachable forge must not trap the agent. -/
def untriaged (e : HookEnv) : IO (List Nat) := do
  let some repo := e.repo | return []
  let some f ← e.forge | return []
  match ← (f.issues repo { kinds := .issues, labels := ["request", "new"] }).run with
  | .ok is => return (is.filter (e.trusted.contains ·.author)).map (·.number)
  | .error _ => return []

/-- What the hook prints, and its exit code. -/
def handle (e : HookEnv) (event : String) (data : Json) : IO (Option String × UInt32) := do
  match event with
  | "pre-tool" =>
    if e.human then
      let input := (data.getObjVal? "tool_input").toOption.getD (Json.mkObj [])
      let cwd := (str data "cwd").getD "/"
      match e.guard.check ((str data "tool_name").getD "") (str input) cwd with
      | some reason => return (some (denial reason false).compress, 0)
      | none => return (none, 0)
    else if e.run && (← Control.paused e.control) then
      return (some (denial "The kit is paused by the human: stop now and do nothing more." true).compress, 0)
    else return (none, 0)
  | "session-start" =>
    if e.human then
      recordSession e "start" data
      let out := Json.mkObj [("hookSpecificOutput", Json.mkObj [("hookEventName", toJson "SessionStart"),
        ("additionalContext", toJson sessionContext)])]
      return (some out.compress, 0)
    return (none, 0)
  | "session-end" =>
    if e.human then recordSession e "end" data
    return (none, 0)
  | "stop" =>
    let active := ((data.getObjVal? "stop_hook_active").toOption.bind (·.getBool?.toOption)).getD false
    if e.human || active || e.repo.isNone || (← Control.paused e.control) then return (none, 0)
    let pending ← untriaged e
    if pending.isEmpty then return (none, 0)
    -- Numbers only: issue text never goes into what steers a run.
    let lines := "\n".intercalate (pending.map (s!"  - #{·}"))
    IO.eprintln s!"Untriaged requests are waiting on {e.repo.getD ""}:\n{lines}\nTriage each one as your protocol describes before stopping."
    return (none, 2)
  | _ => return (none, 0)

end Guild.Agent
