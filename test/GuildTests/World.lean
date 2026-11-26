/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import GuildTests.Dispatch.Harness
import Guild.Gatekeeper.Service
import Guild.Agent.ForgeCli
import Plausible

/-! The randomised world test. Worlds are drawn from the forge's data model, not the kit's: issues
and pull requests on any repository, by anyone, with any labels, open or closed, and comments by
anyone carrying any of the lines the kit reads, naming any item; releases, changelogs and CI in any
state. The real dispatcher reads them, and simulated agents do, on whatever they are woken for,
something the protocol allows or nothing. The checks don't use the state function:
- once the kit goes quiet, every open item is owed by someone, waits on something that is, or is
  the human's;
- no agent is woken for an obligation that nothing the protocol lets it do would discharge, and
  none is asked to reply to a comment that asks nothing;
- no head is re-run past the limit.

A failure prints the world's seed: `WORLD_SEED=<seed> WORLDS=1 lake test` runs it alone. -/

namespace GuildTests.World

open Guild Guild.Forge Guild.Dispatcher GuildTests.Fake GuildTests.Dispatch Plausible

def cfg : Config :=
  { config with bounds := { config.bounds with maxRunsPerDay := 1000, maxCoordinatorRunsPerDay := 1000, runBudget := 1000 } }

def repoNames : List String := [coord, core, scale, site]
def people : List String := ["core", "scale", "web", "coordinator", "conformance", human, "stranger"]
def labelPool : List String :=
  ["blocked", "needs-human", "ready-for-release", "request", "accepted", "new", "priority", "upstream",
   "verified", "not-verified", "counter-proposal"]

def person (k : Nat) : String := people.getD (k % people.length) "stranger"
def repoAt (k : Nat) : String := repoNames.getD (k % repoNames.length) core

/-! ## Worlds -/

/-- A line of a description or comment. -/
inductive Says where
  | prose
  /-- Names the item at this index among the world's. -/
  | blockedBy (k : Nat)
  | blockedNone
  | waitingOn (who : Nat)
  | releasedIn
  deriving Repr, Inhabited

structure Words where
  noReply : Bool := false
  says : List Says := []
  deriving Repr, Inhabited

structure CommentSpec where
  author : Nat
  words : Words
  deriving Repr, Inhabited

structure ItemSpec where
  repo : Nat
  pull : Bool := false
  author : Nat
  labels : List String := []
  isOpen : Bool := true
  body : Words := {}
  comments : List CommentSpec := []
  merged : Bool := false
  /-- A pull request's `Refs`, to the item at this index. -/
  refs : Option Nat := none
  /-- 0 none, 1 running, 2 success, 3 failure. -/
  ci : Nat := 2
  deriving Repr, Inhabited

structure RepoSpec where
  /-- v0.1.0, three days ago. -/
  released : Bool := false
  /-- Commits on main since. -/
  since : Bool := true
  /-- CHANGELOG.md heads the next version. -/
  entry : Bool := false
  /-- CODEOWNERS give `API.lock` to the coordinator. -/
  level3 : Bool := false
  deriving Repr, Inhabited

structure Spec where
  repos : List RepoSpec := [{}, {}, {}, {}]
  items : List ItemSpec := []
  /-- CI on every pull request fails, the same way on every re-run. -/
  ciFails : Bool := false
  /-- A move an agent makes whenever it can. -/
  eager : Option String := none
  deriving Repr, Inhabited

def upTo (n : Nat) : Gen Nat := do return (← Gen.chooseNatLt 0 (n + 1) (by omega)).val
def chance (pct : Nat) : Gen Bool := do return (← upTo 99) < pct
def few {α} (n : Nat) (g : Gen α) : Gen (List α) := do (List.range (← upTo n)).mapM fun _ => g

def genSays : Gen Says := do
  let r ← upTo 99
  let k ← upTo 9
  return if r < 35 then .prose else if r < 60 then .blockedBy k else if r < 68 then .blockedNone
    else if r < 85 then .waitingOn k else .releasedIn

def genWords : Gen Words := do return { noReply := ← chance 25, says := ← few 2 genSays }

def genItem : Gen ItemSpec := do
  let pull ← chance 35
  let isOpen ← chance 80
  let labels ← few 3 do return labelPool.getD (← upTo (labelPool.length - 1)) "new"
  let merged ← chance 60
  let refs ← chance 60
  let target ← upTo 9
  return { repo := ← upTo 3, pull, author := ← upTo 6, labels := labels.eraseDups, isOpen,
           body := ← genWords, comments := ← few 3 do return { author := ← upTo 6, words := ← genWords },
           merged := !isOpen && merged, refs := if refs then some target else none, ci := ← upTo 3 }

def genRepo : Gen RepoSpec := do
  return { released := ← chance 60, since := ← chance 50, entry := ← chance 40, level3 := ← chance 50 }

def genSpec : Gen Spec := do
  let n ← upTo 4
  return { repos := ← [0, 1, 2, 3].mapM fun _ => genRepo, items := ← (List.range (n + 2)).mapM fun _ => genItem,
           ciFails := ← chance 50 }

/-- Each item's repository and number, numbered in order on each. -/
def places (s : Spec) : List (String × Nat) :=
  s.items.foldl (fun acc i => let r := repoAt i.repo; acc ++ [(r, (acc.filter (·.1 == r)).length + 1)]) []

def Words.render (ps : List (String × Nat)) (w : Words) : String :=
  let line : Says → String
    | .prose => "Can you look at this?"
    | .blockedBy k => match ps[k % max ps.length 1]? with
      | some (r, n) => s!"Blocked-by: org/{r}#{n}"
      | none => "Blocked-by: none"
    | .blockedNone => "Blocked-by: none"
    | .waitingOn k => s!"Waiting-on: {person k}"
    | .releasedIn => "Released in v0.1.0"
  "\n".intercalate ((if w.noReply then ["(no reply needed)", ""] else []) ++ w.says.map line)

def ciOf : Nat → Ci | 0 => .none_ | 1 => .pending | 2 => .success | _ => .failure

def act {α} (m : M α) : IO Unit := discard m.run

def addRun (t : T) (repo sha : String) (status : RunStatus) : IO Unit := do
  let id ← t.nextId
  let created ← t.at 0
  let part : RunPart :=
    { run := { id, workflow := "checks.yml", status, sha, event := "push", created },
      jobs := [{ id := id + 100000, name := "build", status, attempt := 1 }] }
  t.repo repo fun r => { r with runs := r.runs.push part }

def checks : String := "checks / build (pull_request)"

def build (s : Spec) : IO T := do
  let t ← T.new cfg
  t.world.modify fun w => { w with admins := w.admins ++ ["gatekeeper"] }
  let ps := places s
  for (r, rs) in repoNames.zip s.repos do
    t.repo r fun x => { x with writers := cfg.agentNames, labels := (x.labels ++ labelPool).eraseDups }
    if rs.released then t.release r "v0.1.0" (3 * 86400)
    let sha := if rs.released && !rs.since then "tag-v0.1.0" else "m-head"
    t.main r sha (ago := 3 * 86400)
    let entry := rs.entry && (rs.since || !rs.released)
    let log := (if entry then "## v0.1.1\n\n- More.\n\n" else "") ++ (if rs.released then "## v0.1.0\n\n- First.\n" else "")
    for ref in ["main"] ++ (if rs.released && rs.since then ["v0.1.0"] else []) do
      t.file r "API.lock" "Test.f : Nat\n" ref
      unless log.isEmpty do t.file r "CHANGELOG.md" (if ref == "main" then log else "## v0.1.0\n\n- First.\n") ref
    if rs.level3 then t.file r ".forgejo/CODEOWNERS" "API\\.lock @coordinator\n"
    if r != coord then
      t.status r sha .success
      addRun t r sha .success
  for ((spec, (r, n)), k) in (s.items.zip ps).zipIdx do
    let created := 2 * 86400 - k * 3600
    let author := person spec.author
    let labeller := if author == "stranger" then human else author
    let mut events := []
    for l in spec.labels do events := events ++ [← t.label l true (created - 30) labeller]
    for (c, j) in spec.comments.zipIdx do
      events := events ++ [← t.comment (person c.author) (created - 600 * (j + 1)) (c.words.render ps)]
    let closed := if spec.isOpen then none else some (created - 7000)
    let body := spec.body.render ps
    if spec.pull then
      let refs := match spec.refs.bind (ps[·]?) with
        | some (r', k') => if r' == r && k' != n then s!"\n\nRefs #{k'}" else ""
        | none => ""
      let sha := s!"head-{r}-{n}"
      t.pull r n author spec.labels sha events (body := body ++ refs) (title := s!"Work {k}")
        (merged := if spec.merged then closed else none) (isOpen := spec.isOpen) (created := created)
        (ci := ciOf spec.ci)
      if spec.ci == 3 then addRun t r sha .failure
      if spec.ci == 2 then addRun t r sha .success
      -- A head is a commit on main, so merging it keeps what main has.
      let time ← t.at created
      t.repo r fun x =>
        let tree := ((x.branches.lookup "main").bind fun s => (x.commits.find? (·.sha == s)).map (·.tree)).getD []
        { x with commits := { sha, message := "Work", tree := ("Test/Work.lean", s!"-- {n}") :: tree, time } :: x.commits }
    else
      t.issue r n author spec.labels spec.isOpen body created events closed (title := s!"Item {k}")
  return t

/-- CI that was running finishes, and CI starts on every head without it: on pull requests it
fails if the world says so, the same way each time; on main it passes. -/
def settleCi (t : T) (fails : Bool) : IO Unit := do
  for r in (← t.world.get).repos do
    if r.name == coord then continue
    let main := r.branches.lookup "main"
    let heads := r.items.toList.filterMap fun i => i.pull.bind fun p => if i.isOpen then some p.headSha else none
    for sha in main.toList ++ heads do
      let st := r.statuses.filter fun (s, x) => s == sha && x.context.startsWith "checks"
      if st.isEmpty || st.any (·.2.state == .pending) then
        let fail := fails && main != some sha
        act (setStatus t.world r.name sha checks (if fail then .failure else .success))
        unless r.runs.any (·.run.sha == sha) do addRun t r.name sha (if fail then .failure else .success)

/-! ## What agents may do -/

structure Move where
  name : String
  /-- Whether the protocol counts it as doing the step, rather than saying something about it. -/
  substantive : Bool := true
  go : T → IO Unit

def gatekeeper (t : T) : Guild.Gatekeeper.Env :=
  { forge := as t.world "gatekeeper", org := "org", me := "gatekeeper", coordinator := "coordinator",
    workflow := "checks.yml", control := t.control, log := fun _ => pure () }

/-- Whether the gatekeeper would release the repository now. -/
def releasable (t : T) (repo : String) : IO (Option Guild.Gatekeeper.Plan) := do
  match ← (Guild.Gatekeeper.plan (gatekeeper t) repo).run with
  | .ok (.ok p) => return some p
  | _ => return none

def cli (t : T) (agent : String) : Guild.Agent.Cli :=
  { forge := as t.world agent, own := (cfg.owner? agent).bind (·.owns), coordinator := some "coordinator",
    reviewer := some "conformance", supervisor := none, rerunLimit := cfg.bounds.rerunLimit,
    reviewRounds := 3, pause := fun _ => pure () }

/-- What `forge ci --rerun` answered, refusals included. -/
initialize answers : IO.Ref (List String) ← IO.mkRef []

def rerun (repo : String) (n : Nat) (agent : String) (t : T) : IO Unit := do
  match ← ((cli t agent).rerun repo (some n)).run.run with
  | .ok (.ok out) =>
    answers.modify (· ++ [out])
    let some p ← t.itemOf repo n | return
    if let some part := p.pull then act (setStatus t.world repo part.headSha checks .pending)
  | .ok (.error m) => answers.modify (· ++ [m])
  | .error e => answers.modify (· ++ [toString e])

def say (a repo : String) (n : Nat) (text : String) (t : T) : IO Unit := act ((as t.world a).comment repo n text)

def linesOf (i : Fake.Item) : List (String × String × Nat) :=
  Text.blockedBy i.body ++ i.comments.toList.flatMap (Text.blockedBy ·.body)

def parseUnit (unit : String) : Option (String × Nat) :=
  match unit.splitOn "#" with
  | [r, n] => n.toNat?.map (r, ·)
  | _ => none

def moves (t : T) (a unit : String) : IO (List Move) := do
  let w ← t.world.get
  let ownerOf (r : String) := (cfg.owner? r).map (·.name)
  if unit.startsWith "release:" then
    let r := (unit.drop 8).toString
    let plan ← releasable t r
    let ok := plan.isSome
    let log := ((← ((as t.world a).file r "CHANGELOG.md" "main").run).toOption.join).getD ""
    let heading := (plan.map fun p => s!"## {Guild.Gatekeeper.Version.tag p.version}\n\n- More.\n\n").getD ""
    let level3 := (← ((as t.world a).file r ".forgejo/CODEOWNERS" "main").run).toOption.join.isSome
    let mainFails := (w.repos.find? (·.name == r)).any fun x =>
      x.statuses.any fun (s, st) => x.branches.lookup "main" == some s && st.state == .failure
    let own := ownerOf r == some a
    return (if own && ok then [{ name := "changelog", go := fun t => act ((as t.world a).commit r
        { branch := "main", message := "Changelog", files := [("CHANGELOG.md", heading ++ log)] }) }] else []) ++
      (if own && mainFails then [{ name := "fix main", go := fun t => act ((as t.world a).commit r
        { branch := "main", message := "Fix", files := [("Test/Fix.lean", "-- fixed")] }) }] else []) ++
      (if a == "coordinator" && ok && !level3 then [{ name := "decision", go := fun t => act ((as t.world a).createIssue r
        { title := s!"Release {r}", body := "## Question\n\nRelease it?", assignees := [human] }) }] else []) ++
      (if a == "coordinator" && ok && level3 then [{ name := "release", go := fun t => do
        discard (Guild.Gatekeeper.release (gatekeeper t) (← Guild.Gatekeeper.State.new) r "A release." [] true).run }] else [])
  let some (r, n) := parseUnit unit | return []
  let some i ← t.itemOf r n | return []
  let mine := ownerOf r == some a
  let base : List Move :=
    [{ name := "say", substantive := false, go := say a r n "I can't see what to do here." },
     { name := "marker", substantive := false, go := say a r n s!"Blocked-by: org/{r}#{n + 1}" },
     { name := "wait", substantive := false, go := say a r n "Waiting-on: coordinator" }] ++
    (if (linesOf i).isEmpty then [] else [{ name := "unblock", go := say a r n "Blocked-by: none" }]) ++
    (if i.labels.contains "blocked" && (mine || i.author == a) then
      [{ name := "unlabel blocked", go := fun t => act ((as t.world a).removeLabel r n "blocked") }] else []) ++
    (if i.labels.contains "ready-for-release" && !i.isOpen && a == "coordinator" then
      [{ name := "unlabel released", go := fun t => act ((as t.world a).removeLabel r n "ready-for-release") }] else [])
  if let some p := i.pull then
    -- An outsider's part is the owner's, as the kit hands it.
    let byAuthor := if cfg.agentNames.contains i.author || i.author == human then i.author == a else mine
    let author := if byAuthor then
        [{ name := "push", go := fun t => do
            let k ← t.nextId
            act ((as t.world a).commit r
            { branch := p.head, start := some "main", message := "Fix", files := [("Test/Fix.lean", s!"-- {k}")] }) },
         { name := "merge", go := fun t => act ((as t.world a).merge r n true) },
         { name := "close", go := fun t => act ((as t.world a).close r n) },
         { name := "rerun", go := rerun r n a }]
      else []
    let review := if a == "conformance" || a == "coordinator" then
        [{ name := "approve", go := fun t => act ((as t.world a).review r n .approve "Fine." p.headSha) },
         { name := "changes", go := fun t => act ((as t.world a).review r n .requestChanges "Not yet." p.headSha) }]
      else []
    return base ++ author ++ review
  let blockers := (linesOf i).filterMap fun (_, r', k) => do
    let rs ← w.repos.find? (·.name == r')
    let b ← rs.items.find? (·.number == k)
    if b.isOpen && b.author == a && b.comments.any (fun c => (Text.releasedIn c.body).isSome) then some (r', k) else none
  let owner := if mine then
      [{ name := "pr", go := fun t => do
          let k ← t.nextId
          act ((as t.world a).commit r { branch := s!"work-{k}", start := some "main", message := "Work", files := [("Test/Work.lean", s!"-- {k}")] })
          act ((as t.world a).createPull r { head := s!"work-{k}", title := "Work", body := s!"Refs #{n}" }) },
       { name := "close", go := fun t => do say a r n "Done." t; act ((as t.world a).close r n) },
       { name := "rfr", go := fun t => act ((as t.world a).addLabel r n "ready-for-release") },
       { name := "accept", go := fun t => do
          act ((as t.world a).removeLabel r n "new"); act ((as t.world a).addLabel r n "accepted") }]
    else []
  let requester := if i.author == a && !mine then
      [{ name := "verify", go := fun t => do act ((as t.world a).addLabel r n "verified"); act ((as t.world a).close r n) },
       { name := "not verified", go := fun t => do
          act ((as t.world a).addLabel r n "not-verified"); say a r n "It falls short." t }]
    else []
  let coordinator := if a == "coordinator" && r == coord && !mine then
      [{ name := "close", go := fun t => act ((as t.world a).close r n) }] else []
  let verifyBlockers := blockers.map fun (r', k) =>
    { name := "verify the blocker", go := fun t => do
        act ((as t.world a).addLabel r' k "verified"); act ((as t.world a).close r' k) : Move }
  return base ++ owner ++ requester ++ coordinator ++ verifyBlockers

/-! ## Checks -/

/-- A comment asks something unless it says it needs no reply or is only lines the kit reads. -/
def asksSomething (body : String) : Bool :=
  let ls := (body.trimAscii.toString.splitOn "\n").map (·.trimAscii.toString)
  !(ls.headD "").startsWith "(no reply needed)" &&
    ls.any fun l => !l.isEmpty && !l.startsWith "Blocked-by:" && !l.startsWith "Waiting-on:" && !l.startsWith "Released in"

def stands (t : T) (a unit what : String) : IO Bool := do
  return !(← t.run (q "SELECT 1 FROM obligations WHERE agent=? AND unit=? AND what=? AND escalated=0" [a, unit, what])).isEmpty

def clone (t : T) : IO T := do
  let c ← T.new cfg
  c.world.set (← t.world.get)
  return c

structure Wake where
  agent : String
  unit : String
  what : String
  description : String

/-- Why a wake was for nothing, if it was. -/
def judge (t : T) (wk : Wake) : IO (Option String) := do
  if wk.what.startsWith "reply:" then
    let some id := (wk.what.drop 6).toString.toNat? | return none
    let w ← t.world.get
    let body := w.repos.findSome? fun r => r.items.findSome? fun i => (i.comments.find? (·.id == id)).map (·.body)
    return if body.all asksSomething then none
      else some s!"{wk.agent} was asked to reply to a comment that asks nothing: {wk.description}"
  if wk.unit == "kit" || wk.unit.startsWith "milestone:" then return none
  let base ← clone t
  discard <| base.run (sweep)
  unless ← stands base wk.agent wk.unit wk.what do return none
  let ms ← moves t wk.agent wk.unit
  for m in ms.filter fun m => m.substantive || (m.name == "say" && (wk.what.startsWith "waiting" || wk.what == "changes requested")) do
    let c ← clone t
    m.go c
    discard <| c.run (sweep)
    unless ← stands c wk.agent wk.unit wk.what do return none
  return some s!"{wk.agent} was woken for {wk.unit} ({wk.what}), and nothing the protocol lets it do there changes it: {wk.description}"

def owedOrTold (t : T) (unit : String) : IO Bool := do
  unless (← t.run (q "SELECT 1 FROM obligations WHERE unit=?" [unit])).isEmpty do return true
  -- A release that is the human's waits on its `Release` decision, assigned to them.
  let some (r, n) := parseUnit unit | return ((← t.state unit).map (·.2)).getD [] |>.contains human
  unless (← t.run (q "SELECT 1 FROM notices WHERE repo=? AND number=?" [r, n])).isEmpty do return true
  let some i ← t.itemOf r n | return true
  -- The human's own pull request, which only they can move on, is theirs to know about.
  let holders := ((← t.state unit).map (·.2)).getD []
  return !i.isOpen || i.labels.any (["needs-human", "upstream"].contains ·) || i.assignees.contains human ||
    i.author == "dispatcher" || (i.author == human && holders.contains human)

/-- Owed, the human's, or waiting on something that is. -/
def covered (t : T) : Nat → String → IO Bool
  | 0, _ => return false
  | fuel + 1, unit => do
    if ← owedOrTold t unit then return true
    let on ← t.run (q "SELECT on_unit AS u FROM waits WHERE unit=?
      UNION SELECT on_repo || '#' || CAST(on_number AS TEXT) AS u FROM blocked_by WHERE repo || '#' || CAST(number AS TEXT) = ?" [unit, unit])
    for r in on do
      if ← covered t fuel (r.str "u") then return true
    return false

def report : Json := Json.mkObj [("outcome", Json.toJson "completed"), ("turns", Json.toJson (5 : Nat)), ("cost", Json.toJson (1 : Nat))]

/-- What a world's simulation found, whether it went quiet, and how many wakes it judged. -/
structure Outcome where
  problems : List String
  quiet : Bool
  judged : Nat

/-- Runs a world until it goes quiet, or for a few simulated days. -/
def simulate (s : Spec) (t : T) : IO Outcome := do
  let mut problems : List String := []
  let mut judged : List (String × String × String) := []
  discard <| t.run (sweep)
  t.wakeDue
  settleCi t s.ciFails
  let mut quiet := 0
  for _ in [0:60] do
    t.pass 120
    for a in cfg.agentNames do
      let some c ← t.run (claim a) | continue
      for row in ← t.run (q "SELECT key FROM triggers WHERE run_id=?" [c.run]) do
        let key := row.str "key"
        unless key.startsWith "owe:" do continue
        let parts := (key.drop 4).toString.splitOn ":"
        let unit := ":".intercalate (parts.dropLast.dropLast)
        let some oid := (parts.dropLast.getLast?).bind String.toNat? | continue
        let some o ← t.run (obligation oid) | continue
        let wk : Wake := { agent := a, unit, what := o.str "what", description := o.str "description" }
        unless judged.contains (a, unit, wk.what) do
          judged := judged ++ [(a, unit, wk.what)]
          if let some p ← judge t wk then problems := problems ++ [p]
        let ms ← moves t a unit
        let pick := match s.eager with
          | some name => ms.find? (·.name == name)
          | none => none
        let pick ← match pick with
          | some m => pure (some m)
          | none => do
            let k ← IO.rand 0 (ms.length + ms.length / 2)
            pure ms[k]?
        if let some m := pick then
          m.go t
          if let some (r, n) := parseUnit unit then t.evaluate r n
      discard <| t.run (endRun a c.run report)
    t.pass 1800
    settleCi t s.ciFails
    discard <| t.run (sweep)
    t.wakeDue
    let queued ← t.run (q "SELECT 1 FROM triggers WHERE run_id IS NULL")
    quiet := if queued.isEmpty then quiet + 1 else 0
    if quiet ≥ 3 then break
  if quiet ≥ 3 then
    for r in (← t.world.get).repos do
      for i in r.items do
        if i.isOpen && !(← covered t 20 s!"{r.name}#{i.number}") then
          problems := problems ++ [s!"the kit went quiet with {r.name}#{i.number} open, owed by no one and not the human's ({← t.stateName s!"{r.name}#{i.number}"})"]
  for r in (← t.world.get).repos do
    for sha in (r.runs.toList.map (·.run.sha)).eraseDups do
      let n ← (as t.world human).reruns r.name sha |>.run
      if let .ok k := n then
        if k > cfg.bounds.rerunLimit then problems := problems ++ [s!"{r.name}'s {sha} was re-run {k} times"]
  return { problems, quiet := quiet ≥ 3, judged := judged.length }

/-! ## Worlds the reference's reviews met -/


def wakesOf (t : T) (agent : String) : IO (List String) := do
  return (← t.run (q "SELECT description FROM triggers WHERE agent=?" [agent])).toList.map (·.str "description")

/-- (name, world, checks once it is read, checks after the simulation) -/
def known : List (String × Spec × (T → IO (List String)) × (T → IO (List String))) :=
  [("a comment made only of markers wakes no one",
     { items := [{ repo := 1, author := 1, labels := ["request", "accepted"],
                   comments := [{ author := 1, words := { noReply := true, says := [.prose] } },
                                { author := 1, words := { says := [.blockedBy 1] } }] },
                 { repo := 2, author := 1 }] },
     fun t => do
       let o ← t.owing (some "t-core#1")
       return if o.any (·.2.startsWith "reply") then [s!"core owes a reply: {o}"] else [],
     fun _ => pure []),
   ("a label added after its release",
     { repos := [{}, { released := true, since := false }, {}, {}],
       items := [{ repo := 1, author := 1, labels := ["request", "accepted", "ready-for-release"] }] },
     fun t => do
       let mut out := []
       let st ← t.stateName "t-core#1"
       unless st == "released" do out := out ++ [s!"t-core#1 is {st}, not released"]
       let o ← t.owing (some "release:t-core")
       unless o.isEmpty do out := out ++ [s!"the release is owed: {o}"]
       unless (← t.descriptions "scale").any (has · "v0.1.0") do out := out ++ ["scale isn't told it was released in v0.1.0"]
       return out,
     fun _ => pure []),
   ("a released but open blocker",
     { items := [{ repo := 1, author := 0, body := { says := [.blockedBy 1] } },
                 { repo := 2, author := 0, labels := ["request", "accepted"],
                   comments := [{ author := 1, words := { noReply := true, says := [.releasedIn] } }] }] },
     fun t => do
       let d ← t.descriptions "core"
       return if d.any fun x => has x "t-core#1" && has x "t-scale#1" && has x "verify" then []
         else [s!"core isn't told to verify t-scale#1 first: {d}"],
     fun _ => pure []),
   ("a loop a later comment corrects",
     { items := [{ repo := 1, author := 0, comments := [{ author := 0, words := { says := [.blockedBy 1] } }] },
                 { repo := 2, author := 1, comments := [{ author := 1, words := { says := [.blockedBy 0] } },
                                                         { author := 1, words := { says := [.blockedNone] } }] }] },
     fun t => do
       let o ← t.owing
       return if o.any (·.2 == "invalid") then [s!"a corrected loop is still invalid: {o}"] else [],
     fun _ => pure []),
   ("a loop names its items and lines",
     { items := [{ repo := 1, author := 0, comments := [{ author := 0, words := { says := [.blockedBy 1] } }] },
                 { repo := 2, author := 1, comments := [{ author := 1, words := { says := [.blockedBy 0] } }] }] },
     fun t => do
       let d := (← t.descriptions "core") ++ (← t.descriptions "scale")
       return if d.any fun x => has x "invalid" && has x "t-core#1" && has x "t-scale#1" && has x "issuecomment" then []
         else [s!"the loop isn't named: {d}"],
     fun _ => pure []),
   ("a stale Waiting-on:",
     { items := [{ repo := 1, author := 1, labels := ["request", "accepted"],
                   comments := [{ author := 1, words := { says := [.prose, .waitingOn 0] } },
                                { author := 2, words := { says := [.waitingOn 0] } },
                                { author := 0, words := { says := [.prose] } }] }] },
     fun t => do
       let o ← t.owing (some "t-core#1")
       return if o.any (·.2 == "waiting") then [s!"core still owes the wait: {o}"] else [],
     fun _ => pure []),
   ("CI that fails the same way on every re-run",
     { items := [{ repo := 1, pull := true, author := 0, ci := 3 }], ciFails := true, eager := some "rerun" },
     fun _ => pure [],
     fun t => do
       let mut out := []
       let said ← answers.get
       unless said.any fun x => has x "build" && has x "re-run" && has x "isn't the runner" do
         out := out ++ [s!"the refusal doesn't say what failed again: {said}"]
       unless (← wakesOf t "core").any fun x => has x "CI failing" && has x "re-run" do
         out := out ++ [s!"the CI failing wake doesn't say it was re-run: {← wakesOf t "core"}"]
       return out)]

/-- The ledger's view of a world that failed. -/
def dump (t : T) : IO Unit := do
  for r in ← t.run (q "SELECT unit, state, holders FROM units ORDER BY unit") do
    IO.println s!"    unit {r.str "unit"}: {r.str "state"} {r.str "holders"}"
  for r in ← t.run (q "SELECT agent, unit, what, wakes, escalated FROM obligations ORDER BY unit") do
    IO.println s!"    owes {r.str "agent"} {r.str "unit"} {r.str "what"} wakes {r.nat "wakes"} escalated {r.int "escalated"}"
  for r in ← t.run (q "SELECT unit, on_unit FROM waits") do
    IO.println s!"    waits {r.str "unit"} on {r.str "on_unit"}"

def runKnown : IO Bool := do
  let mut ok := true
  for (name, s, atStart, atEnd) in known do
    answers.set []
    let t ← build s
    discard <| t.run (sweep)
    t.wakeDue
    let first ← atStart t
    let rest := (← simulate s t).problems
    let last ← atEnd t
    let problems := first ++ rest ++ last
    if problems.isEmpty then IO.println s!"PASS (world): {name}"
    else
      ok := false
      for p in problems do IO.println s!"FAIL (world): {name}: {p}"
      dump t
  return ok

def envNat (name : String) (default : Nat) : IO Nat := do
  return ((← IO.getEnv name).bind String.toNat?).getD default

def runRandom : IO Bool := do
  let seed ← envNat "WORLD_SEED" 1
  let count ← envNat "WORLDS" 100
  let mut ok := true
  let mut quietWorlds := 0
  let mut wakes := 0
  for k in [0:count] do
    IO.stdGenRef.set (mkStdGen (seed + k))
    let s ← Gen.run genSpec 10
    answers.set []
    let t ← build s
    let o ← simulate s t
    let problems := o.problems
    if o.quiet then quietWorlds := quietWorlds + 1
    wakes := wakes + o.judged
    unless problems.isEmpty do
      ok := false
      IO.println s!"FAIL (world): seed {seed + k}: {repr s}"
      for p in problems do IO.println s!"  {p}"
      dump t
  if ok then IO.println s!"PASS (world): {count} random worlds from seed {seed}, {quietWorlds} of them quiet at the end, {wakes} wakes judged"
  return ok

def check : IO Bool := do
  let a ← runKnown
  let b ← runRandom
  return a && b

end GuildTests.World
