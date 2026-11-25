/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Guild.Dispatcher.Service
import GuildTests.Fake

/-! The dispatcher's tests run against the fake forge, with worlds built as the forge would serve
them at given times, a ledger in memory, and a clock the test moves. Timers aren't run: a test says
when time passes. -/

namespace GuildTests.Dispatch

open Guild Guild.Forge Guild.Dispatcher GuildTests.Fake

def coord := "t-plan"
def core := "t-core"
def scale := "t-scale"
def tools := "t-tools"
def site := "t-site"

/-- A project with every kind of agent: `tools` is configured but not yet in the forge, and
`engineer` tracks an upstream project and its recommendations are the human's. -/
def config : Config where
  name := "the test project"
  coordination := coord
  repositories := [{ name := coord }, { name := core }, { name := scale, dependsOn := [core] },
                   { name := tools }, { name := site, dependsOn := [core] }]
  agents :=
    [{ name := "coordinator", kind := .coordinator, owns := some coord, filesOn := .all },
     { name := "core", kind := .library, owns := some core, filesOn := .only [coord] },
     { name := "scale", kind := .library, owns := some scale, filesOn := .only [coord, core] },
     { name := "tools", kind := .library, owns := some tools, filesOn := .only [coord] },
     { name := "web", kind := .site, owns := some site, filesOn := .only [coord, core] },
     { name := "conformance", kind := .prReviewer, filesOn := .all },
     { name := "architecture", kind := .milestoneReviewer, filesOn := .all },
     { name := "engineer", kind := .milestoneReviewer, filesOn := .all, humanDecides := true }]
  upstreams := [{ name := "engine", title := "Engine", tracker := some "engineer" }]
  bounds := { patience := 2, runBudget := 40 }
  layers := { lasm := true }
  forge := .forgejo none false
  template := { namespaceRoot := "Test", readmeLine := "A test." }

def human := "human"

/-- Day zero of the fake's clock, in the dispatcher's seconds. -/
def epoch : Float := Time.when (stamp 0)

/-- Where the clock starts: ten days in, so that times in the past are on the fake's calendar. -/
def start : Nat := 10 * 86400

structure T where
  world : IO.Ref World
  env : Env
  /-- Each test's control directory. -/
  control : System.FilePath

def emptyRepo (name : String) : RepoState :=
  { name, labels := ["blocked", "needs-human", "blocking", "ready-for-release", "request", "accepted",
                     "priority", "recommendation", "upstream", "verified", "not-verified"],
    writers := [] }

/-- A fresh world and ledger, with the rules seeded, as for a ledger already in use. -/
def T.new (cfg : Config := config) (timings : Timings := { settle := 600 }) : IO T := do
  let main (r : RepoState) : RepoState :=
    { r with commits := [{ sha := "m-head", message := "", tree := [], time := stamp (start - 86400) }],
             branches := [("main", "m-head")] }
  let w : World := { clock := start, admins := ["dispatcher", human],
                     repos := (cfg.repoNames.filter (· != tools)).map (main ∘ emptyRepo) }
  let world ← IO.mkRef w
  let dir := (← IO.currentDir) / ".lake" / "dispatch-test" / toString (← IO.monoNanosNow)
  IO.FS.createDirAll (dir / "control")
  IO.FS.createDirAll (dir / "keys")
  let db ← openLedger ":memory:"
  let env : Env :=
    { config := cfg, org := "org", human, forgeWeb := "http://forge", forge := as world "dispatcher",
      db, control := dir / "control", stateDir := dir, keysDir := dir / "keys", adminKeyFile := dir / "admin-key",
      timings, caches := ← Caches.new, log := fun _ => pure (),
      now := do return epoch + (← world.get).clock.toFloat,
      later := fun _ _ => pure () }
  let env := env.forgetWrites
  let t : T := { world, env, control := dir / "control" }
  for k in ["rules-seeded", "obligations-started"] do (kvSet k (toString (← env.now))).run env
  return t

def T.run {α} (t : T) (k : D α) : IO α := k.run t.env

def T.now (t : T) : IO Nat := do return (← t.world.get).clock

/-- Time passes. -/
def T.pass (t : T) (seconds : Nat) : IO Unit := t.world.modify fun w => { w with clock := w.clock + seconds }

/-- A time `ago` seconds before now. -/
def T.at (t : T) (ago : Nat) : IO String := do return stamp ((← t.now) - ago)

def T.repo (t : T) (name : String) (f : RepoState → RepoState) : IO Unit :=
  t.world.modify fun w => { w with repos := w.repos.map fun r => if r.name == name then f r else r }

def T.item (t : T) (repo : String) (n : Nat) (f : Fake.Item → Fake.Item) : IO Unit :=
  t.repo repo fun r => { r with items := r.items.map fun i => if i.number == n then f i else i }

/-! ## Building items -/

/-- A timeline entry and, for a comment, the comment. -/
structure Ev where
  entry : Entry
  comment : Option Comment := none

def T.nextId (t : T) : IO Nat := do
  let w ← t.world.get
  t.world.set { w with next := w.next + 1 }
  return 1000 + w.next

def T.comment (t : T) (who : String) (ago : Nat) (body := "A question?") (id : Option Nat := none) : IO Ev := do
  let id ← match id with | some i => pure i | none => t.nextId
  let time ← t.at ago
  return { entry := { time, actor := who, event := .comment id body }, comment := some { id, author := who, body, createdAt := time } }

def T.label (t : T) (name : String) (added : Bool) (ago : Nat) (who := "core") : IO Ev := do
  return { entry := { time := ← t.at ago, actor := who, event := .label name added } }

def T.event (t : T) (e : Event) (who : String) (ago : Nat) : IO Ev := do
  return { entry := { time := ← t.at ago, actor := who, event := e } }

def T.issue (t : T) (repo : String) (n : Nat) (author : String) (labels : List String := []) (isOpen := true)
    (body := "") (created := 7200) (events : List Ev := []) (closed : Option Nat := none) (title := "An issue")
    (assignees : List String := []) : IO Unit := do
  let now ← t.now
  let item : Fake.Item :=
    { number := n, title, body, author, isOpen, labels, assignees, createdAt := stamp (now - created),
      updatedAt := stamp now, closedAt := closed.map (stamp <| now - ·),
      comments := (events.filterMap (·.comment)).toArray, timeline := (events.map (·.entry)).toArray }
  t.repo repo fun r => { r with items := (r.items.filter (·.number != n)).push item }

inductive Ci where
  | pending | success | failure | none_
  deriving BEq

def Ci.state : Ci → Option StatusState
  | .pending => some .pending | .success => some .success | .failure => some .failure | .none_ => none

def T.status (t : T) (repo sha : String) (ci : Ci) (ago := 0) : IO Unit := do
  let time ← t.at ago
  t.repo repo fun r => match ci.state with
    | some s => { r with statuses := (sha, { context := "checks / build (pull_request)", state := s, updatedAt := time }) ::
        r.statuses.filter (·.1 != sha) }
    | none => { r with statuses := r.statuses.filter (·.1 != sha) }

def defaultSha : String := String.ofList (List.replicate 40 'a')

def T.pull (t : T) (repo : String) (n : Nat) (author : String) (labels : List String := []) (sha := defaultSha)
    (events : List Ev := []) (reviews : List Review := []) (mergeable : Option Bool := some true) (title := "Work")
    (body := "") (requested : List String := []) (merged : Option Nat := none) (isOpen := true) (created := 7200)
    (ci := Ci.pending) (files : List String := ["Test/Core.lean"]) : IO Unit := do
  t.issue repo n author labels isOpen body created events (title := title)
  let now ← t.now
  -- A head CI has started on, as the forge marks it at once, unless a test says otherwise.
  let hasStatus := (← t.world.get).repos.any fun r => r.name == repo && r.statuses.any (·.1 == sha)
  unless hasStatus do t.status repo sha ci
  let part : PullPart :=
    { head := s!"branch-{n}", base := "main", headSha := sha, merged := merged.isSome,
      mergedAt := merged.map (stamp <| now - ·), mergeable, requested, reviews := reviews.toArray,
      files := some files }
  t.item repo n fun i => { i with pull := some part }

def T.review (t : T) (who : String) (verdict : Verdict) (ago : Nat) (commit := defaultSha) (body := "") (dismissed := false) :
    IO Review := do
  return { id := ← t.nextId, author := who, verdict, commit, dismissed, stale := false, submittedAt := ← t.at ago, body }

/-- A release published `ago` seconds ago, with its tag. -/
def T.release (t : T) (repo tag : String) (ago : Nat) (draft := false) : IO Unit := do
  let time ← t.at ago
  t.repo repo fun r => { r with releases := { tag, draft, publishedAt := some time } :: r.releases,
                                tags := if draft then r.tags else { name := tag, sha := s!"tag-{tag}" } :: r.tags }

/-- A file's text at a branch or tag: main unless said. -/
def T.file (t : T) (repo path text : String) (ref := "main") (ago := 86400) : IO Unit := do
  let time ← t.at ago
  t.repo repo fun r =>
    let sha := ((r.branches.lookup ref).orElse fun _ => (r.tags.find? (·.name == ref)).map (·.sha)).getD ref
    let c := (r.commits.find? (·.sha == sha)).getD { sha, message := "", tree := [], time }
    let c := { c with tree := (path, text) :: c.tree.filter (·.1 != path) }
    { r with commits := c :: r.commits.filter (·.sha != sha),
             branches := if r.tags.any (·.name == ref) || r.branches.any (·.1 == ref) || ref == sha then r.branches
                         else (ref, sha) :: r.branches }

/-- main, with its head commit made `ago` seconds ago. -/
def T.main (t : T) (repo : String) (sha := "m-head") (ago := 86400) : IO Unit := do
  let time ← t.at ago
  t.repo repo fun r =>
    let tree := ((r.branches.lookup "main").bind fun s => (r.commits.find? (·.sha == s)).map (·.tree)).getD []
    { r with commits := { sha, message := "", tree, time } :: r.commits.filter (·.sha != sha),
             branches := ("main", sha) :: r.branches.filter (·.1 != "main") }

/-! ## Reading the ledger -/

/-- What a trigger is for: an obligation's state or ask, or a notice's kind. -/
def T.what (t : T) (key : String) : IO String := t.run do
  if key.startsWith "owe:" then
    let parts := (key.drop 4).toString.splitOn ":"
    let some i := (parts.dropLast.getLast?).bind String.toNat? | return "gone"
    match ← obligation i with
    | some o => return ((o.str "what").splitOn ":").headD ""
    | none => return "gone"
  return (key.splitOn ":").headD ""

/-- What each waiting trigger is for, for one agent. -/
def T.queued (t : T) (agent : String) : IO (List String) := do
  let rows ← t.run (q "SELECT agent, key FROM triggers WHERE run_id IS NULL ORDER BY id")
  (rows.toList.filter (·.str "agent" == agent)).mapM fun r => t.what (r.str "key")

/-- (agent, what) of each waiting trigger. -/
def T.queuedAll (t : T) : IO (List (String × String)) := do
  let rows ← t.run (q "SELECT agent, key FROM triggers WHERE run_id IS NULL ORDER BY id")
  rows.toList.mapM fun r => do return (r.str "agent", ← t.what (r.str "key"))

/-- (agent, what) of each obligation standing, on one unit or all, an ask without its comment's id. -/
def T.owing (t : T) (unit : Option String := none) : IO (List (String × String)) := do
  let rows ← t.run (q "SELECT agent, unit, what FROM obligations ORDER BY id")
  return ((rows.toList.filter fun r => unit.all (· == r.str "unit")).map fun r =>
    (r.str "agent", ((r.str "what").splitOn ":").headD "")).mergeSort fun a b => a.1 < b.1 || (a.1 == b.1 && a.2 ≤ b.2)

def T.state (t : T) (unit : String) : IO (Option (String × List String)) := do
  let rows ← t.run (q "SELECT state, holders FROM units WHERE unit=?" [unit])
  return rows[0]?.map fun r => (r.str "state",
    ((Json.parse (r.str "holders")).toOption.bind fun j => (Json.fromJson? (α := List String) j).toOption).getD [])

def T.stateName (t : T) (unit : String) : IO String := do return ((← t.state unit).map (·.1)).getD "none"

def T.descriptions (t : T) (agent : String) : IO (List String) := do
  let rows ← t.run (q "SELECT description FROM triggers WHERE agent=? AND run_id IS NULL ORDER BY id" [agent])
  return rows.toList.map (·.str "description")

/-- Every waiting trigger taken by a run. -/
def T.handled (t : T) : IO Unit := t.run (exec "UPDATE triggers SET run_id=1 WHERE run_id IS NULL")

/-- A run under way for the agent. -/
def T.running (t : T) (agent : String) : IO Nat := do
  let rows ← t.run (q "INSERT INTO runs (agent, triggers, claimed) VALUES (?, '[]', ?) RETURNING id" [agent, ← t.env.now])
  return (rows[0]?.map (·.nat "id")).getD 0

def T.evaluate (t : T) (repo : String) (n : Nat) : IO Unit := t.run (Guild.Dispatcher.evaluate repo n)

/-- The writes the dispatcher made: comments, labels and issues, as the fake's timelines show. -/
def T.notices (t : T) : IO (List String) := do
  let rows ← t.run (q "SELECT key FROM notices ORDER BY id")
  return rows.toList.map (·.str "key")

def has (s part : String) : Bool := (s.splitOn part).length > 1

/-! ## Checks -/

abbrev Check := ExceptT String IO Unit

def ensure (b : Bool) (msg : String) : Check := unless b do throw msg

def same {α} [BEq α] [Repr α] (got want : α) (what := "") : Check :=
  unless got == want do throw s!"{what}{if what.isEmpty then "" else ": "}got {repr got}, wanted {repr want}"

def runCases (group : String) (cases : List (String × (T → Check))) : IO Bool := do
  let mut ok := true
  for (name, c) in cases do
    let t ← T.new
    match ← (c t).run.toBaseIO with
    | .ok (.ok ()) => IO.println s!"PASS ({group}): {name}"
    | .ok (.error m) => IO.println s!"FAIL ({group}): {name}: {m}"; ok := false
    | .error err => IO.println s!"FAIL ({group}): {name}: {err}"; ok := false
  return ok

end GuildTests.Dispatch

namespace GuildTests.Dispatch

open Guild Guild.Forge Guild.Dispatcher GuildTests.Fake

/-- Something happens on an item: a timeline entry, and its comment. -/
def T.add (t : T) (repo : String) (n : Nat) (ev : Ev) : IO Unit := do
  let now ← t.now
  t.item repo n fun i => { i with timeline := i.timeline.push ev.entry, updatedAt := stamp now,
                                  comments := match ev.comment with | some c => i.comments.push c | none => i.comments }

def T.setLabels (t : T) (repo : String) (n : Nat) (labels : List String) : IO Unit := do
  let now ← t.now
  t.item repo n fun i => { i with labels, updatedAt := stamp now }

def T.addLabel (t : T) (repo : String) (n : Nat) (label : String) : IO Unit := do
  let now ← t.now
  t.item repo n fun i => { i with labels := (i.labels ++ [label]).eraseDups, updatedAt := stamp now }

def T.labelsOf (t : T) (repo : String) (n : Nat) : IO (List String) := do
  return (((← t.world.get).repos.find? (·.name == repo)).bind fun r => (r.items.find? (·.number == n)).map (·.labels)).getD []

def T.itemOf (t : T) (repo : String) (n : Nat) : IO (Option Fake.Item) := do
  return ((← t.world.get).repos.find? (·.name == repo)).bind fun r => r.items.find? (·.number == n)

def T.commentsOn (t : T) (repo : String) (n : Nat) : IO (List String) := do
  return ((← t.itemOf repo n).map fun i => i.comments.toList.map (·.body)).getD []

def T.clearCache (t : T) : IO Unit := t.env.caches.lock.atomically do
  t.env.caches.items.set {}
  t.env.caches.reads.set {}

def T.wakeDue (t : T) : IO Unit := t.run Guild.Dispatcher.wakeDue

def T.handle (t : T) (event : String) (payload : Json) : IO Unit := t.run (Guild.Dispatcher.handle event payload)

def T.close (t : T) (repo : String) (n : Nat) (ago := 0) : IO Unit := do
  let time ← t.at ago
  t.item repo n fun i => { i with isOpen := false, closedAt := some time, updatedAt := time }

def released (tag : String) : String := s!"(no reply needed)\n\nReleased in {tag}: ..."

def line (repo : String) (n : Nat) : String := s!"Blocked-by: org/{repo}#{n}"

end GuildTests.Dispatch

namespace GuildTests.Dispatch

/-- A dispatcher action, within a check. -/
def T.io {α} (t : T) (k : Guild.Dispatcher.D α) : ExceptT String IO α := ExceptT.lift (k.run t.env)

end GuildTests.Dispatch

namespace GuildTests.Dispatch

def ms (title := "M1") (isOpen := true) (open_ := 0) (closed := 3) : Guild.Forge.Milestone :=
  { title, isOpen, openIssues := open_, closedIssues := closed }

def T.milestones (t : T) (repo : String) (m : List Guild.Forge.Milestone) : IO Unit :=
  t.repo repo fun r => { r with milestones := m }

end GuildTests.Dispatch
