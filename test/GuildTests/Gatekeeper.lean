/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Guild.Gatekeeper.Service
import Guild.Kit
import GuildTests.Contract
import GuildTests.Fuel
import GuildTests.Projects

/-! The gatekeeper: where webhooks say to look, that only the forge's signature is accepted, and
that one look is queued however many webhooks name the same place (the reference's
`test_gatekeeper.py`); then its approvals and releases, against the fake forge. -/

namespace GuildTests.Gatekeeper

open Guild Guild.Forge Guild.Gatekeeper Guild.Version GuildTests.Contract Json Plausible

/-! ## Theorems -/

/-- It approves only on the CI workflow's run, and only when every run for the commit succeeded. -/
theorem ci_success (w : String) (rs : List Run) (h : ci w rs = .success) :
    rs.any (·.workflow == w) = true ∧ rs.all (·.status == .success) = true := by
  unfold ci at h
  split at h
  · cases h
  · split at h
    · simp_all
    · split at h <;> cases h

theorem targets_other (org : String) (h : Hook) (o : h.owner.toLower != org.toLower) :
    targets org h = [] := by
  simp [targets, o]

/-! ## Properties

A version's tag reads back as the version. A property: the proof needs `String.toNat?` of
`toString n`, through `splitOn`, and the library has no lemmas relating them. -/

def tagReadsBack (x y z : Nat) : Bool := tagVersion (Version.tag ⟨x, y, z⟩) == some ⟨x, y, z⟩

/-- The entry under a version's heading is found, and ends at the next heading. -/
def entryFound (x y z : Nat) (s : String) : Bool :=
  let line := s.replace "\n" " " |>.replace "#" " "
  let v : Version := ⟨x, y, z⟩
  let text := s!"# Changelog\n\n## {Version.tag v}\n\n- {line}\n\n## v{x}.{y}.{z + 1}x\n\n- another\n"
  changelogEntry text v == some s!"- {line}".trimAscii.toString

/-! ## Webhooks -/

def org := "org"

def repoJson : String := "{\"name\": \"lib\", \"owner\": {\"login\": \"org\"}}"

def runPayload (pr : Option Nat) : String :=
  let inner := match pr with
    | some n => s!"\{\\\"pull_request\\\": \{\\\"number\\\": {n}}}"
    | none => "{}"
  s!"\{\"run\": \{\"repository\": {repoJson}, \"event_payload\": \"{inner}\"}}"

def pullPayload (action : String) (n : Nat) : String :=
  s!"\{\"repository\": {repoJson}, \"action\": \"{action}\", \"pull_request\": \{\"number\": {n}}}"

def whereOf (kind payload : String) : List (Repo × Option Nat) :=
  match parse payload with
  | .ok j => ((Forgejo.hook kind j).map (targets org)).getD []
  | .error _ => [("unparsed", none)]

def deny (cond : Bool) (message : String) : T Unit := ensure (!cond) message

abbrev Case := String × T Unit

def webhookCases : List Case :=
  [("a finished run names its pull request", do
      ensure (whereOf "action_run_success" (runPayload (some 7)) == [("lib", some 7)]) "wrong target"),
   ("a run on main names the repository", do
      ensure (whereOf "action_run_success" (runPayload none) == [("lib", none)]) "wrong target"),
   ("a pull request opened, reopened or pushed to", do
      for (kind, action) in [("pull_request", "opened"), ("pull_request", "reopened"),
                             ("pull_request_sync", "synchronized")] do
        ensure (whereOf kind (pullPayload action 3) == [("lib", some 3)]) s!"{kind} {action}"),
   ("not its labels, comments, review requests or closing", do
      for (kind, action) in [("pull_request_label", "label_updated"),
                             ("pull_request_review_request", "review_requested"),
                             ("pull_request", "closed"), ("pull_request_comment", "created")] do
        ensure (whereOf kind (pullPayload action 3)).isEmpty s!"{kind} {action}"),
   ("only a push to main", do
      ensure (whereOf "push" s!"\{\"repository\": {repoJson}, \"ref\": \"refs/heads/main\"}" == [("lib", none)])
        "a push to main"
      ensure (whereOf "push" s!"\{\"repository\": {repoJson}, \"ref\": \"refs/heads/agent/x\"}").isEmpty
        "a push to another branch"),
   ("another organisation or event names nothing", do
      ensure (whereOf "pull_request"
        "{\"repository\": {\"name\": \"x\", \"owner\": {\"login\": \"other\"}}, \"action\": \"opened\", \"pull_request\": {\"number\": 1}}").isEmpty
        "another organisation"
      ensure (whereOf "issues" s!"\{\"repository\": {repoJson}, \"issue\": \{\"number\": 1}}").isEmpty "an issue"),
   ("only the right signature is accepted", do
      let body := (pullPayload "opened" 3).toUTF8
      let sig := Leancrypto.Codec.Hex.encodeString (Leancrypto.hmac .sha256 "s3cret".toUTF8 body)
      ensure (Forgejo.signed "s3cret" body sig) "the right signature was refused"
      ensure (Forgejo.signed "s3cret" body sig.toUpper) "an upper-case signature was refused"
      deny (Forgejo.signed "s3cret" body (String.ofList (List.replicate 64 '0'))) "a wrong signature was accepted"
      deny (Forgejo.signed "other" body sig) "another secret's signature was accepted"
      deny (Forgejo.signed "" body sig) "an empty secret accepted a signature")]

/-! ## The fake world -/

def settings : Settings := GuildTests.Projects.settings

def coordinator : String :=
  (GuildTests.Projects.plain.config.coordinator?.map (·.name)).getD "coordinator"

def codeownersAt (level : Nat) : String :=
  Kit.codeowners GuildTests.Projects.plain.config settings level

def passing : String := "on: [pull_request, push]\njobs:\n  build:\n    runs-on: docker\n    steps:\n      - run: true\n"
def failing : String := "on: [pull_request, push]\njobs:\n  build:\n    runs-on: docker\n    steps:\n      - run: exit 1\n"

structure World where
  ref : IO.Ref Fake.World
  control : System.FilePath
  env : Guild.Gatekeeper.Env
  st : State
  as : String → Guild.Forge.Forge
  logs : IO.Ref (Array String)

def world (level : Nat) (control : System.FilePath) : IO World := do
  let w : Fake.World :=
    { admins := ["human"],
      repos := [{ name := "lib", labels := ["request", "ready-for-release", "priority"],
                  writers := ["owner", "gatekeeper", coordinator] },
                { name := "the-tool", labels := [], writers := ["owner"] }] }
  let ref ← IO.mkRef w
  let as := Fake.as ref
  IO.FS.createDirAll control
  let logs ← IO.mkRef #[]
  let env : Guild.Gatekeeper.Env :=
    { forge := as "gatekeeper", org, me := "gatekeeper", coordinator,
      workflow := "checks.yml", control, log := fun m => logs.modify (·.push m) }
  let files := (if level == 1 then [] else [(".forgejo/CODEOWNERS", codeownersAt level)]) ++
    [(".forgejo/workflows/checks.yml", passing), ("API.lock", "theorem one : 1 = 1\n"),
     ("CHANGELOG.md", "# Changelog\n\n## v0.1.0\n\n- The first release.\n")]
  discard <| (as "owner").commit "lib" { branch := "main", message := "start", files } |>.run
  return { ref, control, env, st := ← State.new, as, logs }

/-- A pull request by the owner, with the given CI workflow on its branch. -/
def pullWith (w : World) (name workflow : String) : T (Nat × String) := do
  let owner := w.as "owner"
  let k : NewCommit :=
    { branch := name, start := some "main", message := name,
      files := [(".forgejo/workflows/checks.yml", workflow), (s!"{name}.txt", name)] }
  let sha ← lift (owner.commit "lib" k)
  let n ← lift (owner.createPull "lib" { head := name, title := name })
  return (n, sha)

def gatekeeperApproved (w : World) (n : Nat) (sha : String) : T Bool := do
  return approved "gatekeeper" sha (← lift (w.env.forge.reviews "lib" n))

def pause (w : World) : IO Unit := IO.FS.writeFile (w.control / "paused") ""
def resume (w : World) : IO Unit := IO.FS.removeFile (w.control / "paused")

def scratch : IO System.FilePath := do
  let dir := System.FilePath.mk ".lake" / "gatekeeper-test" / toString (← IO.monoNanosNow)
  IO.FS.createDirAll dir
  return dir

def approvalCases : List (String × (System.FilePath → T Unit)) :=
  [("the kit's code owners for each level read back as that level", fun _ => do
      for l in [1, 2, 3] do
        let got := level (if l == 1 then none else some (codeownersAt l)) "gatekeeper" coordinator
        ensure (got == l) s!"level {l}'s code owners read as level {got}"),
   ("it approves a pull request whose CI succeeded, once", fun dir => do
      let w ← world 2 dir
      let (n, sha) ← pullWith w "good" passing
      lift (check w.env w.st "lib" (some n))
      ensure (← gatekeeperApproved w n sha) "no approval"
      lift (check w.env w.st "lib" (some n))
      let mine := (← lift (w.env.forge.reviews "lib" n)).filter (·.author == "gatekeeper")
      ensure (mine.length == 1) s!"{mine.length} approvals"
      ensure (mine.all (·.body.startsWith noReply)) "its approval asks for a reply"),
   ("it doesn't approve a failing build, whatever statuses say", fun dir => do
      let w ← world 2 dir
      let (n, sha) ← pullWith w "spoof" failing
      lift (Fake.setStatus w.ref "lib" sha "checks / build (pull_request)" .success)
      lift (check w.env w.st "lib" (some n))
      deny (← gatekeeperApproved w n sha) "it approved a failing build"),
   ("it does nothing at level 1", fun dir => do
      let w ← world 1 dir
      let (n, sha) ← pullWith w "level1" passing
      lift (check w.env w.st "lib" (some n))
      deny (← gatekeeperApproved w n sha) "it approved at level 1"),
   ("while paused it approves nothing, and resuming sweeps", fun dir => do
      let w ← world 2 dir
      let (n, sha) ← pullWith w "paused" passing
      pause w
      enqueue w.st (.look "lib" (some n))
      discard (work w.env w.st : IO Bool)
      lift (sweep w.env w.st)
      deny (← gatekeeperApproved w n sha) "it approved while paused"
      resume w
      lift (sweep w.env w.st)
      ensure (← gatekeeperApproved w n sha) "a sweep after resuming didn't approve"),
   ("a new head needs a new approval", fun dir => do
      let w ← world 2 dir
      let (n, sha) ← pullWith w "moving" passing
      lift (check w.env w.st "lib" (some n))
      let sha' ← lift ((w.as "owner").commit "lib" { branch := "moving", message := "more", files := [("more.txt", "more")] })
      ensure (sha' != sha) "the head didn't move"
      deny (← gatekeeperApproved w n sha') "the old approval counted for the new head"
      lift (check w.env w.st "lib" (some n))
      ensure (← gatekeeperApproved w n sha') "the new head wasn't approved"),
   ("one look is queued however many webhooks name it", fun dir => do
      let w ← world 2 dir
      for _ in [0, 1, 2] do enqueue w.st (.look "lib" (some 3))
      enqueue w.st .sweep
      enqueue w.st .sweep
      ensure ((← w.st.queue.atomically get).toList == [.look "lib" (some 3), .sweep]) "the queue repeats a job")]

def releaseCases : List (String × (System.FilePath → T Unit)) :=
  [("at level 3 it releases, ending what isn't a request", fun dir => do
      let w ← world 3 dir
      let owner := w.as "owner"
      let task ← lift (owner.createIssue "lib" { title := "a task", labels := ["ready-for-release"] })
      let req ← lift (owner.createIssue "lib" { title := "a request", labels := ["ready-for-release", "request"] })
      match ← lift (release w.env w.st "lib" "The first." [task, req] false) with
      | .error m => throw s!"refused: {m}"
      | .ok r =>
        ensure (Version.tag r.plan.version == "v0.1.0") s!"released {Version.tag r.plan.version}"
        ensure ((← lift (w.env.forge.tags "lib")).any (·.name == "v0.1.0")) "no tag"
        let t ← lift (w.env.forge.issue "lib" task)
        let q ← lift (w.env.forge.issue "lib" req)
        ensure ((t.map (·.isOpen)) == some false) "the task stayed open"
        ensure ((q.map (·.isOpen)) == some true) "the request was closed before its requester verified it"
        ensure ((q.map (·.labels.contains "ready-for-release")) == some false) "ready-for-release stayed"
        let said := (← lift (w.env.forge.comments "lib" req)).map (·.body)
        ensure (said.any (·.endsWith r.url)) "no comment with the release"),
   ("it refuses below level 3, while paused, without CI, and a second time", fun dir => do
      let w2 ← world 2 (dir / "two")
      let .error m ← lift (release w2.env w2.st "lib" "note" [] false) | throw "released at level 2"
      ensure ((m.splitOn "level 3").length > 1) m
      let w ← world 3 (dir / "three")
      pause w
      let .error m ← lift (release w.env w.st "lib" "note" [] false) | throw "released while paused"
      ensure ((m.splitOn "paused").length > 1) m
      resume w
      let .ok _ ← lift (release w.env w.st "lib" "note" [] false) | throw "refused a good release"
      let .error m ← lift (release w.env w.st "lib" "note" [] false) | throw "released the same commit twice"
      ensure ((m.splitOn "already released").length > 1) m
      let k : NewCommit :=
        { branch := "main", message := "break CI",
          files := [(".forgejo/workflows/checks.yml", failing),
                   ("CHANGELOG.md", "# Changelog\n\n## v0.1.1\n\n- A fix.\n")] }
      discard <| lift ((w.as "owner").commit "lib" k)
      let .error m ← lift (release w.env w.st "lib" "note" [] false) | throw "released with failing CI"
      ensure ((m.splitOn "CI run").length > 1) m),
   ("without a CHANGELOG entry it says which headings there are", fun dir => do
      let w ← world 3 dir
      let k : NewCommit :=
        { branch := "main", message := "no entry",
          files := [("CHANGELOG.md", "# Changelog\n\n## v9.9.9\n\n- Not this.\n")] }
      discard <| lift ((w.as "owner").commit "lib" k)
      let .error m ← lift (release w.env w.st "lib" "note" [] false) | throw "released without an entry"
      ensure ((m.splitOn "## v9.9.9").length > 1) m),
   ("a name that isn't a repository gets a suggestion", fun dir => do
      let w ← world 3 dir
      let .error m ← lift (release w.env w.st "tool" "note" [] false) | throw "released a missing repository"
      ensure ((m.splitOn "did you mean the-tool?").length > 1) m),
   ("the human releases at any level, and while paused", fun dir => do
      let w ← world 2 dir
      pause w
      let .ok r ← lift (release w.env w.st "lib" "By hand." [] true) | throw "refused the human"
      ensure (Version.tag r.plan.version == "v0.1.0") "wrong version")]

/-! ## Over HTTP -/

def port : UInt16 := 18731

def post (path : String) (headers : List (String × String)) (body : String) : IO Nat := do
  let req : Leancurl.Request :=
    { url := s!"http://127.0.0.1:{port}{path}", method := .post,
      headers := headers, body := some body.toUTF8, timeoutMs := some 10000 }
  match ← Leancurl.Curl.send req with
  | .ok r => return r.status.toNat
  | .error e => throw (IO.userError e.message)

def httpCases : List (String × (System.FilePath → T Unit)) :=
  [("over HTTP, a signed webhook is queued once and a bad one refused", fun dir => do
      let w ← world 2 dir
      IO.FS.writeFile (dir / "webhook-secret") "s3cret\n"
      IO.FS.writeFile (dir / "coordinator-key") "k3y\n"
      let keys : Keys := { webhookSecret := dir / "webhook-secret", coordinatorKey := dir / "coordinator-key" }
      let addr : Std.Net.SocketAddress := .v4 { addr := Std.Net.IPv4Addr.ofParts 127 0 0 1, port }
      let server ← (Std.Http.Server.serve addr (app w.env w.st keys)).block
      try
        let body := pullPayload "opened" 3
        let sig := Leancrypto.Codec.Hex.encodeString (Leancrypto.hmac .sha256 "s3cret".toUTF8 body.toUTF8)
        let hdrs (s : String) := [("X-Forgejo-Signature", s), ("X-Forgejo-Event", "pull_request"),
          ("X-Forgejo-Event-Type", "pull_request"), ("Content-Type", "application/json")]
        ensure ((← post "/hook" (hdrs sig) body) == 200) "a signed webhook wasn't accepted"
        ensure ((← post "/hook" (hdrs sig) body) == 200) "a second signed webhook wasn't accepted"
        ensure ((← post "/hook" (hdrs (String.ofList (List.replicate 64 '0'))) body) == 403) "a bad signature wasn't refused"
        ensure ((← w.st.queue.atomically get).toList == [.look "lib" (some 3)]) "the queue isn't one look"
        ensure ((← post "/release" [("Authorization", "Bearer wrong")] "{\"repo\": \"lib\", \"note\": \"x\"}") == 403)
          "a release without the coordinator's key wasn't refused"
        ensure ((← post "/release" [("Authorization", "Bearer k3y")] "{\"repo\": \"lib\", \"note\": \"x\"}") == 409)
          "a release below level 3 wasn't refused as a conflict"
      finally
        (server.shutdownAndWait).block)]

def run (name : String) (t : T Unit) : IO Bool := do
  match ← t.run with
  | .ok () => IO.println s!"PASS (gatekeeper): {name}"; return true
  | .error m => IO.println s!"FAIL (gatekeeper): {name}: {m}"; return false

def check : IO Bool := do
  let mut ok := true
  for (name, t) in webhookCases do ok := (← run name t) && ok
  for (name, t) in approvalCases ++ releaseCases ++ httpCases do
    ok := (← run name (t (← scratch))) && ok
  let name := "a version's tag reads back as the version"
  match ← Fuel.checkIO (∀ x y z, tagReadsBack x y z = true) { numInst := 1000 } with
  | .success _ => IO.println s!"PASS (gatekeeper): {name}"
  | r => IO.println s!"FAIL (gatekeeper): {name}: {r}"; ok := false
  let name := "a version's CHANGELOG entry is found"
  match ← Fuel.checkIO (∀ x y z s, entryFound x y z s = true) { numInst := 1000 } with
  | .success _ => IO.println s!"PASS (gatekeeper): {name}"
  | r => IO.println s!"FAIL (gatekeeper): {name}: {r}"; ok := false
  return ok

end GuildTests.Gatekeeper
