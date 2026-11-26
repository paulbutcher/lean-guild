/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
module

import Guild.Agent.ForgeCli
import Guild.Agent.Env
import Leancurl

/-! `forge`'s command line. Besides the agent's own, it reads `AGENT_REPO`, `COORDINATOR`, `REVIEWER`,
`SUPERVISOR`, `RERUN_LIMIT` and `REVIEW_ROUNDS` from the environment. -/

open Guild.Agent Guild.Forge Json

def git (args : List String) : IO (UInt32 × String) := do
  let out ← IO.Process.output { cmd := "git", args := args.toArray }
  return (out.exitCode, out.stdout)

def version : ExceptT String IO String := do
  let (code, top) ← git ["rev-parse", "--show-toplevel"]
  if code != 0 then throw "forge version runs in a checkout: cd into your repository first"
  -- A release since the clone; offline, the tags it has.
  discard <| git ["fetch", "--quiet", "--tags", "origin"]
  let (_, tags) ← git ["tag", "-l", "v*"]
  let lock : System.FilePath := System.FilePath.mk top.trimAscii.toString / "API.lock"
  unless ← lock.pathExists do
    throw ("this checkout has no API.lock, so the version can't be computed: write it with " ++
      "`bash scripts/api-lock.sh > API.lock`, as CI checks it")
  let working ← IO.FS.readFile lock
  let names := (tags.splitOn "\n").filter (· ≠ "")
  let mut locks : List (String × String) := []
  for t in names do
    let (c, text) ← git ["show", s!"{t}:API.lock"]
    if c == 0 then locks := (t, text) :: locks
  return versionLine names (fun t => locks.lookup t) working

def bearer (url : String) (keyFile : String) (method : Leancurl.Method) (body : Option String) :
    ExceptT String IO (Nat × String) := do
  let key := (← IO.FS.readFile keyFile).trimAscii.toString
  let req : Leancurl.Request :=
    { url, method, headers := [("Authorization", s!"Bearer {key}"), ("Content-Type", "application/json")],
      body := body.map (·.toUTF8), timeoutMs := some 120000 }
  match ← Leancurl.Curl.send req with
  | .error e => throw s!"can't reach {url}: {e.message}"
  | .ok r => return (r.status.toNat, (String.fromUTF8? r.body).getD "")

def release (me : String) (coordinator : Option String) (repo note : String) (issues : List Nat) :
    ExceptT String IO String := do
  unless coordinator == some me do throw "only the coordinator asks the gatekeeper for releases"
  let body := Json.mkObj [("repo", toJson repo), ("note", toJson note), ("issues", toJson issues)]
  let url := (← opt "GATEKEEPER_URL" "http://gatekeeper:8080") ++ "/release"
  let (status, text) ← bearer url (← opt "GATEKEEPER_KEY_FILE" "/run/secrets/gatekeeper_key") .post (some body.compress)
  let j := (parse text).toOption.getD (Json.mkObj [])
  let s (k : String) := ((j.getObjVal? k).toOption.bind (·.getStr?.toOption)).getD ""
  if status != 200 then throw s!"the gatekeeper didn't release {repo}: {if (s "error").isEmpty then toString status else s "error"}"
  return s!"Released {repo} {s "version"} at {(s "sha").take 12}: {s "reason"}. {s "url"}"

def ledger (me : String) (supervisor : Option String) (days : Nat) : ExceptT String IO String := do
  unless supervisor == some me do throw "only the supervisor reads the ledger"
  let since := (← IO.monoMsNow) / 1000 - days * 86400
  let url := (← opt "DISPATCHER_URL" "http://dispatcher:8080") ++ s!"/ledger?since={since}"
  let (status, text) ← bearer url (← opt "RUNNER_KEY_FILE" "/run/secrets/runner_key") .get none
  if status != 200 then throw s!"the dispatcher answered {status}"
  return text

def finish (r : Except String String) (success : Bool := true) : IO UInt32 := do
  match r with
  | .ok out => IO.print (if out.endsWith "\n" then out else out ++ "\n"); return if success then 0 else 1
  | .error m => IO.eprintln s!"forge: {m}"; return 1

/-- Records, for the run under way, a change made in the forge that no webhook credits to the agent:
a re-run, or a release the gatekeeper makes. -/
def record (r : Except String String) (what : String) : IO (Except String String) := do
  if r matches .ok _ then
    if let some path := (← IO.getEnv "GUILD_ACTIONS").filter (!·.isEmpty) then
      let h ← IO.FS.Handle.mk path .append
      h.putStrLn what
  return r

def runOut (x : Out String) : IO (Except String String) := do
  match ← x.run.run with
  | .ok r => return r
  | .error e => return .error s!"the forge: {e}"

public def main (args : List String) : IO UInt32 := do
  let me ← opt "AGENT_NAME" ""
  let role (n : String) : IO (Option String) := do return (← IO.getEnv n).filter (!·.isEmpty)
  let cli : IO Cli := do
    return { forge := ← agentForge, own := ← role "AGENT_REPO", coordinator := ← role "COORDINATOR",
             reviewer := ← role "REVIEWER", supervisor := ← role "SUPERVISOR",
             rerunLimit := (← opt "RERUN_LIMIT" "1").toNat?.getD 1,
             reviewRounds := (← opt "REVIEW_ROUNDS" "3").toNat?.getD 3,
             pause := fun s => IO.sleep (s * 1000).toUInt32 }
  let target (s : String) : Option (Option Nat) := if s == "main" then some none else (number? s).map some
  match args with
  | ["pr", "automerge", n] | ["pr", "merge", n] =>
    let some k := number? n | finish (.error s!"{n} isn't a pull request number")
    finish (← runOut ((← cli).merge k (args[1]? == some "automerge")))
  | "ci" :: r :: t :: rest =>
    let (some repo, some tgt) := (repoName? r, target t) | finish (.error "usage: forge ci <repo> <pr|main> [--log [all] | --rerun]")
    match rest with
    | [] =>
      -- Succeeds only when CI did, so a script can wait on it.
      match ← ((← cli).ciReport repo tgt).run.run with
      | .ok (.ok (line, ok)) => finish (.ok line) ok
      | .ok (.error m) => finish (.error m)
      | .error e => finish (.error s!"the forge: {e}")
    | ["--log"] => finish (← runOut ((← cli).ciLogs repo tgt false))
    | ["--log", "all"] => finish (← runOut ((← cli).ciLogs repo tgt true))
    | ["--rerun"] => finish (← record (← runOut ((← cli).rerun repo tgt)) s!"rerun {repo} {t}")
    | _ => finish (.error "usage: forge ci <repo> <pr|main> [--log [all] | --rerun]")
  | ["review", r, n, file] =>
    let (some repo, some k) := (repoName? r, number? n) | IO.eprintln usage; return 2
    let spec ← try IO.FS.readFile file catch e => return ← finish (.error s!"{file}: {e}")
    finish (← runOut ((← cli).review repo k spec))
  | ["reviews", r, n] =>
    let (some repo, some k) := (repoName? r, number? n) | IO.eprintln usage; return 2
    finish (← runOut ((← cli).reviews repo k))
  | "pr" :: "approve" :: r :: n :: words@(_ :: _) =>
    let (some repo, some k) := (repoName? r, number? n) | IO.eprintln usage; return 2
    finish (← runOut ((← cli).approve repo k (" ".intercalate words)))
  | "release" :: r :: note :: issues =>
    let (some repo, some ns) := (repoName? r, issues.mapM number?) | IO.eprintln usage; return 2
    finish (← record (← (release me (← role "COORDINATOR") repo note ns).run) s!"release {repo}")
  | ["version"] => finish (← version.run)
  | ["ledger"] => finish (← (ledger me (← role "SUPERVISOR") 30).run)
  | ["ledger", d] => finish (← (ledger me (← role "SUPERVISOR") ((number? d).getD 30)).run)
  | _ => IO.eprintln usage; return 2
