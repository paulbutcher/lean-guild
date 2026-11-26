/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
module

public import Guild.Config
public import Guild.Forge.Forgejo
public import Guild.Ui.App
public import MiddlewareCookieStore

/-! `guild-ui`: the human's web UI, in its own container on a network the agents aren't on.

Besides `FORGE_ORG`, `HUMAN_USER` and `FORGE_WEB_URL` it reads `CONFIG_FILE`, `DISPATCHER_URL`,
`FORGE_URL`, `CONTROL_DIR`, `PORT`, and from `UI_SECRETS` the sign-in key `key` and the cookie
sealing key `session-key`; the dispatcher's admin key from `ADMIN_KEY_FILE`, and the human's forge
token from `HUMAN_TOKEN_FILE`. -/

namespace Guild.Ui

def log (m : String) : IO Unit := do
  let err ← IO.getStderr
  err.putStrLn s!"guild-ui: {m}"
  err.flush

def opt (name default : String) : IO String := do return (← IO.getEnv name).getD default

def need (name : String) : IO String := do
  match ← IO.getEnv name with
  | some v => if v.isEmpty then throw (IO.userError s!"{name} is empty") else pure v
  | none => throw (IO.userError s!"{name} isn't set")

/-- A key that has to exist: a UI that started without one would refuse every sign-in, or forget
every session, and say nothing about why. -/
def secret (path : System.FilePath) : IO String := do
  let k ← readKey path
  if k.isEmpty then throw (IO.userError s!"{path} is missing or empty")
  return k

def serve : IO UInt32 := do
  let configFile ← opt "CONFIG_FILE" "/etc/guild/config.json"
  let config ← match (Json.parse (← IO.FS.readFile configFile)).toOption.map (Json.fromJson? (α := Guild.Config)) with
    | some (.ok c) => pure c
    | _ => throw (IO.userError s!"{configFile} isn't the kit's configuration")
  let secrets : System.FilePath := ← opt "UI_SECRETS" "/run/secrets/ui"
  discard <| secret (secrets / "key")
  let some sealing := Leancrypto.Codec.Hex.decodeString (← secret (secrets / "session-key"))
    | throw (IO.userError s!"{secrets / "session-key"} isn't hex")
  unless sealing.size == 32 do throw (IO.userError s!"{secrets / "session-key"} isn't 32 bytes")
  let org ← need "FORGE_ORG"
  let human ← need "HUMAN_USER"
  let tokenFile : System.FilePath := ← opt "HUMAN_TOKEN_FILE" "/run/secrets/human/token"
  -- Bootstrap makes the token after the kit starts.
  unless ← tokenFile.pathExists do
    log s!"waiting for {tokenFile}"
    repeat
      IO.sleep 10000
      if ← tokenFile.pathExists then break
  let u : Env :=
    { site := { forgeWeb := ((← need "FORGE_WEB_URL").dropSuffix "/").toString, org },
      dispatcher := ← opt "DISPATCHER_URL" "http://dispatcher:8080",
      adminKey := ← opt "ADMIN_KEY_FILE" "/run/secrets/dispatcher/admin-key",
      signInKey := secrets / "key",
      brakes := { control := ← opt "CONTROL_DIR" "/control", human,
                  repos := config.repositories.map (·.name),
                  forge := Forge.Forgejo.connect
                    { url := ← opt "FORGE_URL" "http://forgejo:3000", org, account := human,
                      token := ← readKey tokenFile } },
      report := ← IO.mkRef [] }
  let sessions ← Middleware.CookieStore.new { key := some sealing }
  let handler ← match server u sessions with
    | .ok h => pure h
    | .error report => throw (IO.userError s!"routes that can't be reached:\n{report}")
  let port := (← opt "PORT" "8080").toNat?.getD 8080
  let addr : Std.Net.SocketAddress := .v4 { addr := Std.Net.IPv4Addr.ofParts 0 0 0 0, port := port.toUInt16 }
  let server ← (Std.Http.Server.serve addr handler).block
  log s!"listening on :{port}"
  server.waitShutdown.block
  return 0

end Guild.Ui

public def main (args : List String) : IO UInt32 := do
  match args with
  | [] => Guild.Ui.serve
  | _ => IO.eprintln "usage: guild-ui"; return 2
