/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
module

import Guild.Gatekeeper.Service

/-! The gatekeeper's command line. With no arguments it serves; `plan` says what a release would be;
`release --human` is the human's own release, run with the human's token in `TOKEN_FILE`.

Its settings come from the environment: `FORGE_ORG` and `COORDINATOR` (the coordinator's account),
and optionally `FORGE_URL`, `GATEKEEPER_ACCOUNT`, `GATEKEEPER_WORKFLOW`, `GATEKEEPER_SWEEP_SECONDS`,
`PORT`, `CONTROL_DIR`, `TOKEN_FILE`, `COORDINATOR_KEY_FILE` and `WEBHOOK_SECRET_FILE`. -/

open Guild Guild.Forge Guild.Gatekeeper Json

def usage : String :=
  "usage: guild-gatekeeper                        serve: approve on CI, answer the coordinator\n" ++
  "       guild-gatekeeper plan <repo>            what a release of <repo> would be, as JSON\n" ++
  "       guild-gatekeeper release --human <repo> <note> [<issue>...]"

def opt (name default : String) : IO String := do return (← IO.getEnv name).getD default

def need (name : String) : IO String := do
  match ← IO.getEnv name with
  | some v => if v.isEmpty then throw (IO.userError s!"{name} is empty") else pure v
  | none => throw (IO.userError s!"{name} is not set")

def log (m : String) : IO Unit := do
  let err ← IO.getStderr
  err.putStrLn s!"gatekeeper: {m}"
  err.flush

def env (wait := false) : IO Env := do
  let org ← need "FORGE_ORG"
  let me ← opt "GATEKEEPER_ACCOUNT" "gatekeeper"
  let tokenFile : System.FilePath := ← opt "TOKEN_FILE" "/run/secrets/gatekeeper/token"
  -- Bootstrap makes the token after the kit starts.
  if wait then
    unless ← tokenFile.pathExists do
      log s!"waiting for {tokenFile}"
      repeat
        IO.sleep 10000
        if ← tokenFile.pathExists then break
  let token := (← IO.FS.readFile tokenFile).trimAscii.toString
  return { forge := Forgejo.connect { url := ← opt "FORGE_URL" "http://forgejo:3000", org, account := me, token },
           org, me, coordinator := ← need "COORDINATOR", workflow := ← opt "GATEKEEPER_WORKFLOW" "checks.yml",
           control := ← opt "CONTROL_DIR" "/control", log }

def serve : IO UInt32 := do
  let e ← env (wait := true)
  let st ← State.new
  let keys : Keys :=
    { webhookSecret := ← opt "WEBHOOK_SECRET_FILE" "/run/secrets/gatekeeper/webhook-secret",
      coordinatorKey := ← opt "COORDINATOR_KEY_FILE" "/run/secrets/gatekeeper/coordinator-key" }
  let every := (← opt "GATEKEEPER_SWEEP_SECONDS" "900").toNat?.getD 900
  let port := (← opt "PORT" "8080").toNat?.getD 8080
  let addr : Std.Net.SocketAddress := .v4 { addr := Std.Net.IPv4Addr.ofParts 0 0 0 0, port := port.toUInt16 }
  discard <| (Std.Http.Server.serve addr (app e st keys)).block
  discard <| IO.asTask (worker e st)
  scheduler e st every
  return 0

def printJson (j : Json) : IO Unit := IO.println j.pretty

public def main (args : List String) : IO UInt32 := do
  match args with
  | [] => serve
  | ["plan", repo] =>
    match ← (plan (← env) repo).run with
    | .ok (.ok p) => printJson p.json; return 0
    | .ok (.error m) => IO.eprintln s!"Not released: {m}"; return 1
    | .error err => IO.eprintln s!"The forge: {err}"; return 1
  | "release" :: "--human" :: repo :: note :: issues =>
    let some ns := issues.mapM String.toNat? | IO.eprintln usage; return 2
    match ← (release (← env) (← State.new) repo note ns true).run with
    | .ok (.ok r) => printJson r.json; return 0
    | .ok (.error m) => IO.eprintln s!"Not released: {m}"; return 1
    | .error err => IO.eprintln s!"The forge: {err}"; return 1
  | _ => IO.eprintln usage; return 2
