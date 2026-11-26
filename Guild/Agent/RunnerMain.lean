/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
module

import Guild.Agent.RunnerIO
import Guild.Agent.Env

open Guild.Agent Guild.Agent.Runner

public def main (args : List String) : IO UInt32 := do
  let agent ← need "AGENT_NAME"
  let repo ← opt "AGENT_REPO" ""
  let shared ← opt "SHARED_DIR" "/workspace"
  -- An agent that owns no repository has a folder of its own.
  let workspace : System.FilePath := ← opt "AGENT_WORKSPACE" (shared ++ "/" ++ repo)
  let stateName ← opt "WORKSPACE_STATE" ".guild"
  let home ← opt "HOME" "/home/agent"
  let e : Env :=
    { agent, claude := ← opt "CLAUDE_BIN" "claude", workspace, state := System.FilePath.mk shared / stateName, logs := workspace / stateName,
      archive := ← opt "RUN_ARCHIVE" "/var/lib/guild/archive",
      claudeDir := ← opt "CLAUDE_CONFIG_DIR" (home ++ "/.claude"),
      dispatcher := { url := ← opt "DISPATCHER_URL" "http://dispatcher:8080",
                      keyFile := ← opt "RUNNER_KEY_FILE" "/run/secrets/runner_key" },
      maxMinutes := (← opt "MAX_RUN_MINUTES" "240").toNat?.getD 240,
      tick := (← opt "RUNNER_TICK_SECONDS" "15").toNat?.getD 15,
      control := ← opt "CONTROL_DIR" "/etc/guild/control" }
  match args with
  | [] => loop e; return 0
  | ["stop"] =>
    IO.FS.createDirAll e.state
    IO.FS.writeFile (stopFile e) ""
    IO.println "Asked the runner to interrupt the current run, if there is one."
    return 0
  | _ => IO.eprintln "usage: guild-runner [stop]"; return 2
