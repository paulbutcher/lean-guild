/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import GuildTests.Contract
import Guild.Forge.Forgejo

/-! The contract tests against a running Forgejo, which `test/stages/stage4.sh` provides. Each
account's token is read from `$SECRETS/<account>/token`, the human's from `$SECRETS/human/token`.
  FORGE_URL, FORGE_ORG, SECRETS, HUMAN_USER
  CONTRACT_REPO      a repository the accounts below can reach, empty or not
  CONTRACT_OWNER     an account that writes to it
  CONTRACT_REVIEWER  another account that writes to it
  CONTRACT_OUTSIDER  an account that may only file issues there -/

open Guild.Forge GuildTests.Contract Json

def need (name : String) : IO String := do
  match ← IO.getEnv name with
  | some v => if v.isEmpty then throw (IO.userError s!"{name} is empty") else pure v
  | none => throw (IO.userError s!"{name} is not set")

def toIO (x : M α) : IO α := do
  match ← x.run with
  | .ok a => pure a
  | .error e => throw (IO.userError (toString e))

def main : IO UInt32 := do
  let url ← need "FORGE_URL"
  let org ← need "FORGE_ORG"
  let secrets ← need "SECRETS"
  let human ← need "HUMAN_USER"
  let repo ← need "CONTRACT_REPO"
  let conn (account dir : String) : IO Forgejo.Conn := do
    let token := (← IO.FS.readFile s!"{secrets}/{dir}/token").trimAscii.toString
    return { url, org, account, token }
  let as (account : String) : IO Forge := do return Forgejo.connect (← conn account account)
  let admin ← conn human "human"
  let path := s!"/repos/{org}/{repo}"
  let reviewer ← need "CONTRACT_REVIEWER"
  let protect : M Unit := do
    let rule := [("enable_push", toJson false), ("required_approvals", toJson (1 : Nat)),
      ("enable_approvals_whitelist", toJson true), ("approvals_whitelist_username", toJson [reviewer]),
      ("enable_status_check", toJson true), ("status_check_contexts", toJson ["checks"])]
    if (← Forgejo.send admin .get s!"{path}/branch_protections/main").1 == 404 then
      discard <| Forgejo.write admin .post s!"{path}/branch_protections"
        (Json.mkObj ([("rule_name", toJson "main")] ++ rule)) [201]
    else
      discard <| Forgejo.write admin .patch s!"{path}/branch_protections/main" (Json.mkObj rule) [200]
  let setStatus (sha : String) (s : StatusState) : M Unit := do
    let state := match s with
      | .pending => "pending" | .success => "success" | .failure => "failure"
      | .error => "error" | .warning => "warning" | .other n => n
    let body := Json.mkObj [("state", toJson state), ("context", toJson "checks")]
    discard <| Forgejo.write admin .post s!"{path}/statuses/{sha}" body [201]
  let env : Env :=
    { repo, owner := ← as (← need "CONTRACT_OWNER"), reviewer := ← as reviewer,
      outsider := ← as (← need "CONTRACT_OUTSIDER"), admin := Forgejo.connect admin,
      label := "request", protect, setStatus, settle := IO.sleep 1100, patience := 120,
      suffix := toString (← IO.monoMsNow) }
  return if ← run "Forgejo" env then 0 else 1
