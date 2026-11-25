/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

/-! A project's static configuration: what it decides, checked when the project compiles.
Deployment settings and secrets are read from the environment instead (`Guild.Settings`). -/

namespace Guild

inductive Kind
  /-- Owns the coordination repository; comments on and approves the rest. -/
  | coordinator
  /-- Owns a repository; files issues on its dependencies. -/
  | library
  /-- A library whose release tags are deployed as a site: the Lasm layer's. -/
  | site
  /-- Owns nothing; reviews pull requests everywhere. -/
  | prReviewer
  /-- Owns nothing; reviews each milestone. -/
  | milestoneReviewer
  /-- A milestone reviewer that also supervises: woken when the kit is quiet with work
  stalled. -/
  | supervisor
  deriving DecidableEq, Repr, Inhabited

namespace Kind

def owns : Kind → Bool
  | coordinator | library | site => true
  | _ => false

def reviewsMilestones : Kind → Bool
  | milestoneReviewer | supervisor => true
  | _ => false

end Kind

structure Repository where
  name : String
  /-- The project's repositories it depends on. -/
  dependsOn : List String := []
  /-- The autonomy level repository setup starts it at. Afterwards its level is the forge's,
  `CODEOWNERS` on `main`, which only the human changes. -/
  level : Nat := 1
  deriving DecidableEq, Repr, Inhabited

/-- The repositories an agent files issues on. -/
inductive FilesOn
  /-- Every repository but its own. -/
  | all
  | only (repos : List String)
  deriving DecidableEq, Repr, Inhabited

structure Agent where
  name : String
  kind : Kind
  /-- The repository it owns, for the kinds that own one. -/
  owns : Option String := none
  filesOn : FilesOn := .only []
  /-- A milestone reviewer whose recommendations are the human's to decide, never the
  coordinator's: those that would change the kit or go upstream. -/
  humanDecides : Bool := false
  deriving DecidableEq, Repr, Inhabited

/-- A project outside the kit that the project depends on, with issues for it on the
coordination repository labelled `upstream:<name>`. -/
structure Upstream where
  /-- As its label names it: `upstream:<name>`. -/
  name : String
  /-- As the agents' instructions name it. -/
  title : String
  /-- The agent woken when one of its issues blocks work. -/
  tracker : Option String := none
  deriving DecidableEq, Repr, Inhabited

/-- The bounds the states and their proofs depend on. -/
structure Bounds where
  /-- Seconds before each wake again of an obligation still standing: their number is how many
  runs may leave it standing before it is the human's. -/
  backoff : List Nat := [0, 900, 900]
  /-- Runs of its busy agent a quiet obligation lets go ahead of it: once it has waited, it is due
  again each time that agent's run ends, and waits again if the agent has more work queued. -/
  patience : Nat
  /-- CI re-runs per head commit. -/
  rerunLimit : Nat := 1
  /-- Agent runs for a unit before the human is told. -/
  runBudget : Nat
  /-- Rounds of conformance review before the human decides what is still disputed. -/
  reviewRounds : Nat := 3
  maxRunMinutes : Nat := 240
  maxRunsPerDay : Nat := 20
  maxCoordinatorRunsPerDay : Nat := 40
  /-- Dollars per agent per day, if spend is capped. -/
  maxSpendPerDay : Option Nat := none
  /-- Comments a day by the supervisor on one item that wake whoever they mention. -/
  supervisorNudges : Nat := 3
  deriving DecidableEq, Repr, Inhabited

structure Layers where
  /-- The Lasm layer, for a project that targets the browser. -/
  lasm : Bool := false
  /-- The Lasm layer's optional macOS runner. -/
  macos : Bool := false
  deriving DecidableEq, Repr, Inhabited

/-- Push mirrors to GitHub. -/
structure Mirror where
  owner : String
  /-- Owners the repositories had before, which old tags' lakefiles name. -/
  formerOwners : List String := []
  branches : List String := ["main"]
  deriving DecidableEq, Repr, Inhabited

inductive Forge
  | forgejo (mirror : Option Mirror) (imported : Bool)
  | github (owner : String)
  deriving DecidableEq, Repr, Inhabited

/-- The Lean layer's template for a new library. -/
structure LibraryTemplate where
  /-- The root of every library's namespace, such as `Acme` for `Acme.Core`. -/
  namespaceRoot : String
  /-- The line under the title of every library's `README.md`. -/
  readmeLine : String
  /-- Lake's `leanOptions`, as name and value. -/
  leanOptions : List (String × String) := []
  /-- The library whose shared files and copyright header a new one starts from. -/
  seedFrom : Option String := none
  deriving DecidableEq, Repr, Inhabited

structure Config where
  /-- The project's name, as the agents' instructions use it. -/
  name : String
  /-- Where the coordinator works, and requests and the upstream tracker live. It has no CI, so
  it stays at level 1. -/
  coordination : String
  repositories : List Repository
  agents : List Agent
  upstreams : List Upstream := []
  bounds : Bounds
  layers : Layers := {}
  forge : Forge
  template : LibraryTemplate
  /-- Files only the human may change, besides the kit's and the layers'. -/
  humanOnly : List String := []
  /-- Domains the project's agents and CI may reach, besides the kit's and the layers': one per
  line, a leading dot allowing subdomains. -/
  allowAgents : List String := []
  allowCi : List String := []
  deriving Repr, Inhabited

namespace Config

def repoNames (c : Config) : List String := c.repositories.map (·.name)
def agentNames (c : Config) : List String := c.agents.map (·.name)

def agent? (c : Config) (name : String) : Option Agent := c.agents.find? (·.name == name)
def repository? (c : Config) (name : String) : Option Repository :=
  c.repositories.find? (·.name == name)

/-- The agent that owns a repository. -/
def owner? (c : Config) (repo : String) : Option Agent := c.agents.find? (·.owns == some repo)

/-- The repositories an agent files issues on. -/
def filesOn (c : Config) (a : Agent) : List String :=
  match a.filesOn with
  | .all => c.repoNames.filter (some · != a.owns)
  | .only rs => rs

/-! ## Rules that name agents -/

/-- The pull request reviewer, on every approvals list and a code owner of every path. -/
def reviewer? (c : Config) : Option Agent := c.agents.find? (·.kind == .prReviewer)

def supervisor? (c : Config) : Option Agent := c.agents.find? (·.kind == .supervisor)

def coordinator? (c : Config) : Option Agent := c.agents.find? (·.kind == .coordinator)

/-- The agents woken when a milestone issue is labelled `milestone-review`. -/
def milestoneReviewers (c : Config) : List Agent := c.agents.filter (·.kind.reviewsMilestones)

/-- Labels on every repository for recommendations, one per milestone reviewer. -/
def reviewLabels (c : Config) : List String := c.milestoneReviewers.map ("review:" ++ ·.name)

def upstreamLabels (c : Config) : List String := c.upstreams.map ("upstream:" ++ ·.name)

/-- The upstream project an agent tracks, if any. -/
def tracks? (c : Config) (agent : String) : Option Upstream :=
  c.upstreams.find? (·.tracker == some agent)

/-- Labels whose recommendations the coordinator doesn't take on: the human decides them. -/
def humanDecidesLabels (c : Config) : List String :=
  (c.milestoneReviewers.filter (·.humanDecides)).map ("review:" ++ ·.name)

/-- The forge's directory for workflows and code owners. -/
def forgeDir (c : Config) : String :=
  match c.forge with
  | .forgejo .. => ".forgejo/"
  | .github _ => ".github/"

/-- Every file only the human may change: the kit's, the Lean layer's, then the project's. -/
def humanOnlyFiles (c : Config) : List String :=
  ["CLAUDE.md", c.forgeDir, "lean-toolchain", "REQUIREMENTS.md"] ++ c.humanOnly

/-! ## Checks -/

def duplicates (xs : List String) : List String :=
  (xs.filter (fun x => xs.count x > 1)).eraseDups

/-- What is wrong with the configuration: empty when it is fine. -/
def errors (c : Config) : List String :=
  let repos := c.repoNames
  let agents := c.agentNames
  let unknownRepo (what r : String) := if repos.contains r then [] else [s!"{what} names {r}, which is not a listed repository"]
  let unknownAgent (what a : String) := if agents.contains a then [] else [s!"{what} names {a}, which is not an agent"]
  let count (k : Kind) := (c.agents.filter (·.kind == k)).length
  (duplicates repos).map (s!"repository {·} is listed twice") ++
  (duplicates agents).map (s!"agent {·} is listed twice") ++
  unknownRepo "the coordination repository" c.coordination ++
  (if count .coordinator == 1 then [] else ["there must be exactly one coordinator"]) ++
  (if count .prReviewer ≤ 1 then [] else ["there is more than one pull request reviewer"]) ++
  (if count .supervisor ≤ 1 then [] else ["there is more than one supervisor"]) ++
  (match c.coordinator? with
   | some a => if a.owns == some c.coordination then [] else [s!"the coordinator must own {c.coordination}"]
   | none => []) ++
  c.agents.flatMap (fun a =>
    (match a.owns, a.kind.owns with
     | some r, true => unknownRepo s!"agent {a.name}" r
     | none, true => [s!"agent {a.name} must own a repository"]
     | some _, false => [s!"agent {a.name} owns a repository, which its kind doesn't"]
     | none, false => []) ++
    (match a.filesOn with
     | .all => []
     | .only rs => rs.flatMap (unknownRepo s!"agent {a.name}'s issues")) ++
    (if a.humanDecides && !a.kind.reviewsMilestones then
      [s!"agent {a.name} isn't a milestone reviewer, so it has no recommendations"] else []) ++
    (if a.kind == .site && !c.layers.lasm then [s!"agent {a.name} is a site, which needs the Lasm layer"] else [])) ++
  (duplicates (c.agents.filterMap (·.owns))).map (s!"repository {·} has more than one owner") ++
  c.repositories.flatMap (fun r =>
    r.dependsOn.flatMap (unknownRepo s!"repository {r.name}'s dependency") ++
    (if r.level < 1 || r.level > 3 then [s!"repository {r.name}'s level must be 1, 2 or 3"] else []) ++
    (if r.name == c.coordination && r.level != 1 then
      [s!"{r.name} has no CI, so it stays at level 1"] else []) ++
    (if (c.owner? r.name).isNone then [s!"repository {r.name} has no owner"] else [])) ++
  (duplicates (c.upstreams.map (·.name))).map (s!"upstream {·} is listed twice") ++
  c.upstreams.flatMap (fun u => match u.tracker with
    | some a => unknownAgent s!"upstream {u.name}'s tracker" a
    | none => []) ++
  (if c.layers.macos && !c.layers.lasm then ["the macOS runner needs the Lasm layer"] else []) ++
  (if c.bounds.backoff.isEmpty then ["the backoff must allow at least one wake"] else []) ++
  (if c.bounds.runBudget == 0 then ["the run budget must allow at least one run"] else []) ++
  (match c.template.seedFrom with
   | some r => unknownRepo "the library template's seed" r
   | none => [])

end Config

/-! ## The repository contract

What the kit requires of a repository: checked when one is adopted, and met by onboarding pull
requests. -/

inductive Requirement
  /-- The CI workflow, which must succeed for the gatekeeper to approve. -/
  | ciWorkflow (path : String)
  /-- Code owners giving the repository the autonomy level its setup starts it at. -/
  | codeOwners (path : String) (level : Nat)
  /-- `API.lock` and the script that writes it: the Lean layer's record of the public API. -/
  | apiLock
  /-- `CHANGELOG.md`, whose newest heading names the next release. -/
  | changelog
  /-- Release tags of the form `vX.Y.Z`. -/
  | versionTags
  /-- A file or directory only the human may change. -/
  | humanOnly (path : String)
  deriving DecidableEq, Repr

def Config.contract (c : Config) (r : Repository) : List Requirement :=
  let releases := r.name != c.coordination
  (if releases then [.ciWorkflow s!"{c.forgeDir}workflows/checks.yml"] else []) ++
  [.codeOwners s!"{c.forgeDir}CODEOWNERS" r.level] ++
  (if releases then [.apiLock, .changelog, .versionTags] else []) ++
  c.humanOnlyFiles.map .humanOnly

/-- A configuration the kit can run: one with no errors, checked when the project compiles. If
the check fails, `#eval config.errors` names what is wrong. -/
structure Project where
  config : Config
  valid : config.errors = [] := by decide +kernel

end Guild
