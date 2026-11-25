/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
module

public import Guild.Forge.Forgejo

/-! What the agents' tools read from their container's environment. -/

@[expose] public section

namespace Guild.Agent

def opt (name default : String) : IO String := do return (← IO.getEnv name).getD default

def need (name : String) : IO String := do
  match ← IO.getEnv name with
  | some v => if v.isEmpty then throw (IO.userError s!"{name} is empty") else pure v
  | none => throw (IO.userError s!"{name} is not set")

def words (name : String) : IO (List String) := do
  return ((← opt name "").split Char.isWhitespace).toList.map (·.toString) |>.filter (· ≠ "")

/-- The agent's own account on the forge, with its token. -/
def agentForge : IO Guild.Forge.Forge := do
  let token := (← IO.FS.readFile (← opt "TOKEN_FILE" "/run/secrets/forgejo_token")).trimAscii.toString
  return Guild.Forge.Forgejo.connect
    { url := ← opt "FORGE_URL" "http://forgejo:3000", org := ← need "FORGE_ORG",
      account := ← need "AGENT_NAME", token }

/-- The workspace's state directory, where runs and sessions are recorded. -/
def stateDir : IO System.FilePath := do
  return System.FilePath.mk (← opt "SHARED_DIR" "/workspace") / (← opt "WORKSPACE_STATE" ".guild")

end Guild.Agent
