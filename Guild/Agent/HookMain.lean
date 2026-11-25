/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
module

import Guild.Agent.Hook
import Guild.Agent.Env

open Guild.Agent Json

public def main (args : List String) : IO UInt32 := do
  let input ← (← IO.getStdin).readToEnd
  let data := (parse input).toOption.getD (Json.mkObj [])
  let e : HookEnv :=
    { run := (← IO.getEnv "GUILD_RUN").isSome, entrypoint := ← opt "CLAUDE_CODE_ENTRYPOINT" "",
      state := ← stateDir, control := ← opt "CONTROL_DIR" "/etc/guild/control",
      repo := (← IO.getEnv "AGENT_REPO").filter (!·.isEmpty), trusted := ← words "TRUSTED_AUTHORS",
      guard := { shared := ← opt "SHARED_DIR" "/workspace", home := ← opt "HOME" "/home/agent" },
      forge := do try return some (← agentForge) catch _ => return none }
  let (out, code) ← handle e (args.headD "") data
  if let some o := out then IO.println o
  return code
