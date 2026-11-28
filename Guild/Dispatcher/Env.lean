/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
module

public import Guild.Config
public import Guild.Forge
public import Guild.Dispatcher.Db
public import Guild.Dispatcher.Time
public import Std.Data.HashMap
public import Guild.Core.Version

/-! What the dispatcher works with: the project's configuration, its deployment's timings, the
ledger, the forge as the dispatcher's account sees it, and the clock, which tests set. -/

@[expose] public section

namespace Guild.Dispatcher

open Guild.Forge

/-- How long things may take, in seconds: deployment settings, with the reference's defaults. -/
structure Timings where
  /-- How long the newest trigger settles before a claim, so a burst of events is one run. -/
  debounce : Float := 60
  /-- How long the oldest may wait however busy the item is. -/
  maxDelay : Float := 900
  reconcile : Float := 900
  /-- How long a pushed head settles before conformance reviews it. -/
  settle : Float := 600
  /-- How long a scheduled merge may sit once nothing stands in its way. -/
  stuck : Float := 600
  /-- How long a head may go with no CI run before its author is woken. -/
  noCi : Float := 600
  /-- How long CI may run without a change. -/
  ciLate : Float := 3600
  /-- How long the coordinator's "pull request opened" waits for CI. -/
  openedHold : Float := 600
  retries : Nat := 2
  retryDelay : Float := 300
  /-- Delays for work whose run failed before it got going, in turn, then the last. -/
  envDelays : List Float := [300, 900, 3600]
  /-- How long after a usage limit resets its work is retried. -/
  limitMargin : Float := 120
  /-- How long the kit is quiet before the coordinator summarises what waits on the human. -/
  idle : Float := 1200
  /-- How long a claimed run may go unstarted before it is closed. -/
  claimStart : Float := 900
  itemMaxAge : Float := 3600
  /-- How long a runner may go without calling in while work waits for it. -/
  runnerSilent : Float := 180
  deriving Repr, Inhabited

/-- An issue or pull request as the rules read it, kept until it changes. -/
structure ItemRead where
  readAt : Float
  updated : String
  issue : Issue
  pull : Option Pull
  timeline : List Entry
  reviews : List Review
  /-- The paths a pull request changes, by head commit, read when a rule first asks. -/
  files : List (String × List String) := []

/-- A short-lived read of something other than an item. -/
inductive Cached where
  | branch (b : Option Branch)
  | release (r : Option Release)
  | tag (t : Option (String × Version.Version))
  | text (s : Option String)
  | flag (b : Bool)
  | nats (ns : List Nat)
  | names (ns : List String)
  | prs (ps : List (Pull × List Nat))
  | issue (i : Option Issue)
  | since (s : Option (String × List Changed))

/-- What the dispatcher remembers between calls that isn't in the ledger. -/
structure Caches where
  /-- Items as last read, by `repo#n`. -/
  items : IO.Ref (Std.HashMap String ItemRead)
  /-- Bumped each time an item is forgotten, so a read under way when it was isn't kept. -/
  gens : IO.Ref (Std.HashMap String Nat)
  /-- Short-lived reads of anything else, by key, with when they were read. -/
  reads : IO.Ref (Std.HashMap String (Float × Cached))
  /-- Repositories a webhook marked as possibly running CI, with when. -/
  ciMarked : IO.Ref (Std.HashMap String Float)
  /-- Repositories whose last check found CI under way. -/
  ciBusy : IO.Ref (List String)
  /-- Units with a timer, and when it runs out. -/
  rechecks : IO.Ref (Std.HashMap String Float)
  lock : Std.Mutex Unit

def Caches.new : IO Caches := do
  return { items := ← IO.mkRef {}, gens := ← IO.mkRef {}, reads := ← IO.mkRef {},
           ciMarked := ← IO.mkRef {}, ciBusy := ← IO.mkRef [], rechecks := ← IO.mkRef {},
           lock := ← Std.Mutex.new () }

structure Env where
  config : Config
  org : String
  human : String
  /-- The forge as the human's browser reaches it, for links in what the kit writes. -/
  forgeWeb : String
  /-- The forge's accounts for the gatekeeper and the dispatcher itself, which are trusted. -/
  gatekeeper : String := "gatekeeper"
  me : String := "dispatcher"
  forge : Guild.Forge.Forge
  db : Db
  control : System.FilePath
  stateDir : System.FilePath
  /-- Each agent's runner key, a file named for the agent. -/
  keysDir : System.FilePath
  /-- The admin key, if there is one. -/
  adminKeyFile : System.FilePath
  timings : Timings := {}
  caches : Caches
  now : IO Float
  log : String → IO Unit
  /-- Runs an action after a delay, on its own thread: tests run none. -/
  later : Float → IO Unit → IO Unit
  /-- When this dispatcher started, which counts as activity. -/
  started : Float := 0

namespace Env

def agents (e : Env) : List Agent := e.config.agents
def isAgent (e : Env) (name : String) : Bool := e.config.agentNames.contains name
def agent? (e : Env) (name : String) : Option Agent := e.config.agent? name
def coordinator? (e : Env) : Option String := e.config.coordinator?.map (·.name)
def supervisor? (e : Env) : Option String := e.config.supervisor?.map (·.name)
def reviewer? (e : Env) : Option String := e.config.reviewer?.map (·.name)
def coordination (e : Env) : String := e.config.coordination
def milestoneReviewers (e : Env) : List String := e.config.milestoneReviewers.map (·.name)

/-- The project's repositories that someone owns, as the reference's `OWNER_OF` keys. -/
def repos (e : Env) : List String :=
  e.config.repoNames.filter fun r => (e.config.owner? r).isSome

def project (e : Env) (repo : String) : Bool := e.config.repoNames.contains repo

/-- The agent that owns a repository. -/
def owner? (e : Env) (repo : String) : Option String := (e.config.owner? repo).map (·.name)

/-- Every account whose actions start work: the agents, the kit's own and the human. -/
def trusted (e : Env) (who : String) : Bool :=
  e.isAgent who || who == e.gatekeeper || who == e.me || who == e.human

/-- Repositories with CI, which release: all but the coordination repository. -/
def hasCi (e : Env) (repo : String) : Bool := repo != e.coordination

def bounds (e : Env) : Bounds := e.config.bounds

def tries (e : Env) : Nat := e.bounds.backoff.length

def capOf (e : Env) (agent : String) : Nat :=
  if e.coordinator? == some agent then e.bounds.maxCoordinatorRunsPerDay else e.bounds.maxRunsPerDay

def capSetting (e : Env) (agent : String) : String :=
  if e.coordinator? == some agent then "maxCoordinatorRunsPerDay" else "maxRunsPerDay"

def link (e : Env) (repo : String) (n : Nat) : String := s!"{e.forgeWeb}/{e.org}/{repo}/issues/{n}"

end Env

end Guild.Dispatcher
