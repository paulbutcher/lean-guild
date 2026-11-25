/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Guild.Agent.ForgeCli
import Guild.Agent.Hook
import GuildTests.Contract

/-! The agents' tools against the fake forge: `forge`'s version (the reference's `test_forge.py`),
its re-run limit, counted from the forge, its reviews and merges; and the hook's stop check. -/

namespace GuildTests.Tools

open Guild Guild.Forge Guild.Agent Guild.Gatekeeper GuildTests.Contract

def a := "def a : Nat\n"
def b := "def b : Nat\n"

def versionOf (tags : List (String × String)) (working : String) : String :=
  ((versionLine (tags.map (·.1)) (fun t => tags.lookup t) working).splitOn ":").headD ""

def passing : String := "on: [pull_request]\njobs:\n  build:\n    runs-on: docker\n    steps:\n      - run: true\n"
def failing : String := "on: [pull_request]\njobs:\n  build:\n    runs-on: docker\n    steps:\n      - run: exit 1\n"

structure World where
  ref : IO.Ref Fake.World
  as : String → Forge

def world : IO World := do
  let w : Fake.World :=
    { admins := ["human"],
      repos := [{ name := "lib", labels := ["request", "new", "needs-human"],
                  writers := ["owner", "reviewer", "coordinator"] }] }
  let ref ← IO.mkRef w
  let as := Fake.as ref
  let k : NewCommit :=
    { branch := "main", message := "start",
      files := [(".forgejo/workflows/checks.yml", passing), ("README.md", "lib")] }
  discard <| ((as "owner").commit "lib" k).run
  return { ref, as }

def cli (w : World) (who : String) (limit : Nat := 1) (rounds : Nat := 2) : Cli :=
  { forge := w.as who, own := some "lib", coordinator := some "coordinator", reviewer := some "reviewer",
    supervisor := some "supervisor", rerunLimit := limit, reviewRounds := rounds, pause := fun _ => pure () }

def out (x : Out α) : T (Except String α) := do
  match ← x.run.run with
  | .ok r => return r
  | .error e => throw (toString e)

def pullWith (w : World) (name workflow : String) : T Nat := do
  let k : NewCommit := { branch := name, start := some "main", message := name,
                         files := [(".forgejo/workflows/checks.yml", workflow), (s!"{name}.txt", name)] }
  discard <| lift ((w.as "owner").commit "lib" k)
  lift ((w.as "owner").createPull "lib" { head := name, title := name })

def spec (statuses : List String) : String :=
  let fs := statuses.map fun s => s!"\{\"section\": \"Definition of done\", \"finding\": \"x\", \"status\": \"{s}\"}"
  s!"\{\"summary\": \"A review.\", \"findings\": [{", ".intercalate fs}]}"

def has (s part : String) : Bool := (s.splitOn part).length > 1

def cases : List (String × T Unit) :=
  [("forge version: from the highest tag and the working tree", do
      let tags := [("v0.9.0", a), ("v0.20.0", a), ("v0.19.0", a), ("not-a-version", b), ("v1.0", b)]
      ensure (versionOf tags a == "v0.20.1") (versionOf tags a)
      ensure (versionOf tags (a ++ b) == "v0.21.0") (versionOf tags (a ++ b))),
   ("forge version: the first release", do ensure (versionOf [] a == "v0.1.0") (versionOf [] a)),
   ("forge ci: a failing run, then one re-run, then no more, counted from the forge", do
      let w ← world
      let n ← pullWith w "broken" failing
      let .ok (line, ok) ← out ((cli w "owner").ciReport "lib" (some n)) | throw "ci failed"
      ensure (!ok && line.startsWith "failure") line
      let .ok said ← out ((cli w "owner").rerun "lib" (some n)) | throw "the first re-run was refused"
      ensure (has said "1 of the 1") said
      let .ok (line, _) ← out ((cli w "owner").ciReport "lib" (some n)) | throw "ci failed"
      ensure (has line "re-run once of the 1 allowed") line
      -- A fresh forge command remembers nothing; the forge's attempt counts refuse it.
      let .error m ← out ((cli w "owner").rerun "lib" (some n)) | throw "a second re-run went ahead"
      ensure (has m "the limit") m
      let .ok _ ← out ((cli w "owner" (limit := 2)).rerun "lib" (some n)) | throw "a limit of two refused the second"),
   ("forge ci --rerun: only a failed run", do
      let w ← world
      let n ← pullWith w "fine" passing
      let .error m ← out ((cli w "owner").rerun "lib" (some n)) | throw "a passing run was run again"
      ensure (has m "only a failed run") m),
   ("forge review: approves without open findings, asks for changes with them", do
      let w ← world
      let n ← pullWith w "reviewed" passing
      let .ok m ← out ((cli w "reviewer").review "lib" n (spec ["fixed", "withdrawn"])) | throw "refused"
      ensure (m.startsWith "Approved") m
      let n ← pullWith w "found" passing
      let .ok m ← out ((cli w "reviewer").review "lib" n (spec ["new", "fixed"])) | throw "refused"
      ensure (m.startsWith "Requested changes") m
      let rs ← lift ((w.as "human").reviews "lib" n)
      ensure (rs.any fun r => r.verdict == .requestChanges && has r.body "conformance-findings") "no findings record"),
   ("forge review: past the rounds, a dispute goes to the human once per head", do
      let w ← world
      let n ← pullWith w "disputed" passing
      for _ in [0, 1] do
        let .ok m ← out ((cli w "reviewer").review "lib" n (spec ["kept"])) | throw "refused"
        ensure (m.startsWith "Requested changes") m
      let .ok m ← out ((cli w "reviewer").review "lib" n (spec ["kept", "agreed"])) | throw "refused"
      ensure (has m "needs-human") m
      let i ← lift ((w.as "human").issue "lib" n)
      ensure ((i.map (·.labels.contains "needs-human")) == some true) "not labelled needs-human"
      let .ok m ← out ((cli w "reviewer").review "lib" n (spec ["kept"])) | throw "refused"
      ensure (m.startsWith "Already put to the human") m),
   ("forge review: only the reviewer, and only once CI passed", do
      let w ← world
      let n ← pullWith w "early" failing
      let .error m ← out ((cli w "owner").review "lib" n (spec [])) | throw "the owner reviewed"
      ensure (has m "only the reviewer") m
      let .error m ← out ((cli w "reviewer").review "lib" n (spec [])) | throw "reviewed a failing build"
      ensure (has m "CI for") m
      let .error m ← out ((cli w "reviewer").review "lib" n "{\"summary\": \"x\", \"findings\": [{\"section\": \"s\", \"finding\": \"f\", \"status\": \"maybe\"}]}")
        | throw "took a finding with no status"
      ensure (has m "status") m),
   ("forge pr approve: the coordinator, on passing CI", do
      let w ← world
      let n ← pullWith w "approve" passing
      let .error _ ← out ((cli w "owner").approve "lib" n "fine") | throw "the owner approved"
      let .ok m ← out ((cli w "coordinator").approve "lib" n "fine") | throw "the coordinator was refused"
      ensure (m.startsWith "Approved") m),
   ("forge pr automerge: merges at once when it can, else schedules", do
      let w ← world
      let n ← pullWith w "merge-now" passing
      let .ok m ← out ((cli w "owner").merge n true) | throw "refused"
      ensure (has m "merged") m
      Fake.protect w.ref "lib" { approvals := 1, approvers := ["reviewer"], contexts := [] } |> lift
      let n ← pullWith w "merge-later" passing
      let .ok m ← out ((cli w "owner").merge n true) | throw "refused"
      ensure (has m "will merge once") m
      let .error m ← out ((cli w "owner").merge n false) | throw "merged without an approval"
      ensure (has m "didn't merge") m),
   ("the hook: a run may not stop with untriaged requests by trusted authors", do
      let w ← world
      let n ← lift ((w.as "reviewer").createIssue "lib" { title := "a request", labels := ["request", "new"] })
      discard <| lift ((w.as "human").createIssue "lib" { title := "the human's", labels := ["request", "new"] })
      let dir := System.FilePath.mk ".lake" / "hook-test" / toString (← IO.monoNanosNow)
      IO.FS.createDirAll dir
      let e : HookEnv := { run := true, entrypoint := "sdk-cli", state := dir, control := dir, repo := some "lib",
                           trusted := ["reviewer"], guard := {}, forge := pure (some (w.as "owner")) }
      ensure ((← untriaged e) == [n]) "the untrusted author's request counted, or the trusted one's didn't"
      let (_, code) ← handle e "stop" (Json.mkObj [])
      ensure (code == 2) s!"stop exited {code}"
      IO.FS.writeFile (dir / "paused") ""
      let (_, code) ← handle e "stop" (Json.mkObj [])
      ensure (code == 0) "while paused, a run was held back from stopping"),
   ("the hook: runs aren't guarded; the human's sessions are", do
      let base : HookEnv := { run := true, entrypoint := "sdk-cli", state := ".", control := ".", repo := none,
                              trusted := [], guard := {}, forge := pure none }
      ensure (!base.human) "a run counted as the human's"
      ensure { base with run := false, entrypoint := "claude-vscode" }.human "the editor's session isn't the human's"
      ensure { base with run := false, entrypoint := "cli" }.human "the command line's session isn't the human's"
      ensure (!{ base with entrypoint := "cli" }.human) "a run from the command line counted as the human's")]

def check : IO Bool := do
  let mut ok := true
  for (name, t) in cases do
    match ← t.run with
    | .ok () => IO.println s!"PASS (tools): {name}"
    | .error m => IO.println s!"FAIL (tools): {name}: {m}"; ok := false
  return ok

end GuildTests.Tools
