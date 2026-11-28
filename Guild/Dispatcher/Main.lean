/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
module

import Guild.Dispatcher.Service

/-! The dispatcher's command line: with no arguments it serves.

The project's configuration is the kit's export, `CONFIG_FILE`. Its settings come from the
environment: `FORGE_ORG`, `HUMAN_USER` and `FORGE_WEB_URL`, and optionally `FORGE_URL`,
`DISPATCHER_ACCOUNT`, `GATEKEEPER_ACCOUNT`, `STATE_DIR`, `CONTROL_DIR`, `DISPATCHER_SECRETS`,
`RUNNER_KEYS_DIR`, `PORT`, and the timings, by the reference's names. -/

open Guild Guild.Dispatcher Json

def opt (name default : String) : IO String := do return (← IO.getEnv name).getD default

def need (name : String) : IO String := do
  match ← IO.getEnv name with
  | some v => if v.isEmpty then throw (IO.userError s!"{name} is empty") else pure v
  | none => throw (IO.userError s!"{name} is not set")

def seconds (name : String) (default : Float) : IO Float := do
  return ((← IO.getEnv name).bind parseFloat?).getD default

def log (m : String) : IO Unit := do
  let err ← IO.getStderr
  err.putStrLn s!"dispatcher: {m}"
  err.flush

def timings : IO Timings := do
  let delays := ((← opt "ENV_RETRY_DELAYS" "300,900,3600").splitOn ",").filterMap parseFloat?
  return {
    debounce := ← seconds "DEBOUNCE_SECONDS" 60, maxDelay := ← seconds "MAX_DELAY_SECONDS" 900,
    reconcile := ← seconds "RECONCILE_SECONDS" 900, settle := ← seconds "CONFORMANCE_SETTLE_SECONDS" 600,
    stuck := ← seconds "MERGE_STUCK_SECONDS" 600, noCi := ← seconds "CI_MISSING_SECONDS" 600,
    ciLate := ← seconds "CI_LATE_SECONDS" 3600, openedHold := ← seconds "PR_OPENED_HOLD_SECONDS" 600,
    retries := (← seconds "MAX_RUN_RETRIES" 2).toUInt64.toNat, retryDelay := ← seconds "RETRY_DELAY_SECONDS" 300,
    envDelays := if delays.isEmpty then [300, 900, 3600] else delays,
    limitMargin := ← seconds "LIMIT_RESET_MARGIN_SECONDS" 120, idle := ← seconds "IDLE_SECONDS" 1200,
    claimStart := ← seconds "CLAIM_START_SECONDS" 900, itemMaxAge := ← seconds "ITEM_CACHE_SECONDS" 3600 }

def serve : IO UInt32 := do
  let configFile ← opt "CONFIG_FILE" "/etc/guild/config.json"
  let config ← match (parse (← IO.FS.readFile configFile)).toOption.map (fromJson? (α := Guild.Config)) with
    | some (.ok c) => pure c
    | _ => throw (IO.userError s!"{configFile} isn't the kit's configuration")
  let secrets : System.FilePath := ← opt "DISPATCHER_SECRETS" "/run/secrets/dispatcher"
  let tokenFile := secrets / "token"
  -- Bootstrap makes the token after the kit starts.
  unless ← tokenFile.pathExists do
    log s!"waiting for {tokenFile}"
    repeat
      IO.sleep 10000
      if ← tokenFile.pathExists then break
  let token := (← IO.FS.readFile tokenFile).trimAscii.toString
  let org ← need "FORGE_ORG"
  let me ← opt "DISPATCHER_ACCOUNT" "dispatcher"
  let stateDir : System.FilePath := ← opt "STATE_DIR" "/state"
  IO.FS.createDirAll stateDir
  let clock := Time.unixNow
  let started ← clock
  let e : Env :=
    { config, org, human := ← need "HUMAN_USER", forgeWeb := ((← need "FORGE_WEB_URL").dropSuffix "/").toString,
      gatekeeper := ← opt "GATEKEEPER_ACCOUNT" "gatekeeper", me,
      forge := Forge.Forgejo.connect { url := ← opt "FORGE_URL" "http://forgejo:3000", org, account := me, token },
      db := ← openLedger (stateDir / "ledger.db"), control := ← opt "CONTROL_DIR" "/control", stateDir,
      keysDir := ← opt "RUNNER_KEYS_DIR" "/run/secrets/runner-keys", adminKeyFile := secrets / "admin-key",
      timings := ← timings, caches := ← Caches.new, now := clock, log,
      later := fun delay act => discard <| IO.asTask do IO.sleep (delay * 1000).toUInt32; act,
      started }
  let e := e.forgetWrites
  discard <| firstStarted.run e
  -- Until the first check, CI may be running anywhere.
  for r in e.repos do (ciMayRun r).run e
  let keys : Keys := { webhookSecret := secrets / "webhook-secret", adminKey := e.adminKeyFile }
  let port := (← opt "PORT" "8080").toNat?.getD 8080
  let addr : Std.Net.SocketAddress := .v4 { addr := Std.Net.IPv4Addr.ofParts 0 0 0 0, port := port.toUInt16 }
  discard <| (Std.Http.Server.serve addr (app e keys)).block
  log s!"listening on :{port}; agents: {", ".intercalate config.agentNames}"
  discard <| IO.asTask (every e 60 "the idler" idler)
  discard <| IO.asTask (every e 5 "rechecking timers" rechecker)
  -- Until a sweep has gone through, as when the forge started after the dispatcher, try again
  -- every minute rather than waiting the whole interval, since webhooks wait on it.
  repeat
    try reconciler.run e catch err => log s!"the reconciler failed: {err}"
    let seeded := (← (kvGet "rules-seeded").run e).isSome
    IO.sleep ((if seeded then e.timings.reconcile else 60) * 1000).toUInt32
  return 0

public def main (args : List String) : IO UInt32 := do
  match args with
  | [] => serve
  | _ => IO.eprintln "usage: guild-dispatcher"; return 2
