/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
module

public import Guild.Dispatcher.Env

/-! The run ledger. Its schema is the reference's, so either kit reads the other's ledger: tables
and columns may be added, never renamed or moved. -/

@[expose] public section

namespace Guild.Dispatcher

/-- The dispatcher's work: errors from the forge, the ledger and the files alike are `IO` errors. -/
abbrev D := ReaderT Env IO

def now : D Float := do (← read).now
def log (m : String) : D Unit := do (← read).log m
def db : D Db := do return (← read).db

def q (sql : String) (args : List Val := []) : D (Array Row) := do (← db).q sql args
def exec (sql : String) (args : List Val := []) : D Unit := do (← db).exec sql args

/-- A forge call, whose error is an `IO` error. -/
def fg {α} (m : Forge.M α) : D α := do
  match ← m.run with
  | .ok a => return a
  | .error err => throw (IO.userError (toString err))

def forge : D Guild.Forge.Forge := do return (← read).forge

def schema : String := "
PRAGMA journal_mode = WAL;
CREATE TABLE IF NOT EXISTS triggers (
  id INTEGER PRIMARY KEY, agent TEXT, key TEXT, description TEXT,
  created REAL, run_id INTEGER);
CREATE TABLE IF NOT EXISTS runs (
  id INTEGER PRIMARY KEY, agent TEXT, triggers TEXT, claimed REAL, started REAL,
  ended REAL, outcome TEXT, cost REAL, turns INTEGER, denied TEXT, session_id TEXT,
  log TEXT, transcript TEXT, in_extension INTEGER, forge_changes INTEGER,
  archived_log TEXT, archived_transcript TEXT);
CREATE TABLE IF NOT EXISTS sessions (
  id INTEGER PRIMARY KEY, agent TEXT, session_id TEXT, started REAL, ended REAL,
  transcript TEXT);
CREATE TABLE IF NOT EXISTS events (
  id INTEGER PRIMARY KEY, at REAL, event TEXT, type TEXT, action TEXT, repo TEXT,
  sender TEXT, number INTEGER, delivery TEXT);
CREATE TABLE IF NOT EXISTS labels (
  repo TEXT, number INTEGER, labels TEXT, PRIMARY KEY (repo, number));
CREATE TABLE IF NOT EXISTS notices (
  id INTEGER PRIMARY KEY, at REAL, key TEXT UNIQUE, kind TEXT, repo TEXT,
  number INTEGER, text TEXT, posted INTEGER);
CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT);
CREATE INDEX IF NOT EXISTS triggers_pending ON triggers (agent, run_id);
CREATE INDEX IF NOT EXISTS triggers_key ON triggers (agent, key);
CREATE INDEX IF NOT EXISTS events_sender ON events (sender, at);
CREATE TABLE IF NOT EXISTS blocked_by (repo TEXT, number INTEGER, on_repo TEXT, on_number INTEGER);
CREATE INDEX IF NOT EXISTS blocked_by_on ON blocked_by (on_repo, on_number);
CREATE TABLE IF NOT EXISTS units (
  unit TEXT PRIMARY KEY, kind TEXT, state TEXT, holders TEXT, step TEXT, since REAL, seen REAL);
CREATE TABLE IF NOT EXISTS shadow (
  id INTEGER PRIMARY KEY, unit TEXT, agent TEXT, side TEXT, state TEXT, rules TEXT,
  first REAL, last REAL, resolved REAL);
CREATE INDEX IF NOT EXISTS shadow_unit ON shadow (unit, resolved);
CREATE TABLE IF NOT EXISTS human_waits (repo TEXT, number INTEGER, PRIMARY KEY (repo, number));
CREATE TABLE IF NOT EXISTS obligations (
  id INTEGER PRIMARY KEY, agent TEXT, unit TEXT, what TEXT, description TEXT, quiet INTEGER,
  since REAL, wakes INTEGER NOT NULL DEFAULT 0, trigger INTEGER, next_at REAL, escalated INTEGER NOT NULL DEFAULT 0);
CREATE UNIQUE INDEX IF NOT EXISTS obligations_key ON obligations (unit, agent, what);
CREATE TABLE IF NOT EXISTS waits (unit TEXT, on_unit TEXT);
CREATE INDEX IF NOT EXISTS waits_unit ON waits (unit);
"

/-- Columns added since the tables were first made, the reference's and then the guild's own. -/
def additions : List String :=
  ["triggers ADD COLUMN not_before REAL",
   "events ADD COLUMN detail TEXT",
   "triggers ADD COLUMN attempts INTEGER NOT NULL DEFAULT 0",
   "triggers ADD COLUMN env_held INTEGER NOT NULL DEFAULT 0",
   -- Runs of its busy agent a quiet obligation has let go ahead of it, and since when it waits.
   "obligations ADD COLUMN waited INTEGER NOT NULL DEFAULT 0",
   "obligations ADD COLUMN waited_since REAL",
   -- When the human marked a notice seen.
   "notices ADD COLUMN seen REAL"]

/-- The ledger at `path`, made or brought up to date. -/
def openLedger (path : System.FilePath) : IO Db := do
  let db ← Db.open path
  db.script schema
  for a in additions do
    try db.exec s!"ALTER TABLE {a}" catch _ => pure ()
  return db

def kvGet (key : String) : D (Option String) := do
  return ((← q "SELECT value FROM kv WHERE key=?" [key])[0]?).bind (·.str? "value")

def kvSet (key value : String) : D Unit :=
  exec "INSERT OR REPLACE INTO kv (key, value) VALUES (?,?)" [key, value]

def kvFloat (key : String) : D Float := do return ((← kvGet key).bind parseFloat?).getD 0

/-- Queue work for an agent, unless the same key is already waiting; with `once`, unless it was
ever queued. With `notBefore`, it waits until then to be claimed. Queued again without one while
it waits, it waits no longer (a pull request whose CI has finished), unless it waits to be retried
or for its environment. The new trigger's id, if there is one. -/
def addTrigger (agent key description : String) (once := false) (notBefore : Option Float := none) :
    D (Option Nat) := do
  let e ← read
  unless e.isAgent agent do return none
  let t ← now
  let id ← e.db.atomically fun q => do
    let dup ← q ("SELECT id, run_id, not_before, attempts, env_held FROM triggers WHERE agent=? AND key=? " ++
      (if once then "" else "AND run_id IS NULL ") ++ "ORDER BY id DESC") [agent, key]
    match dup[0]? with
    | some d =>
      if (d.get "run_id").isNull && !(d.get "not_before").isNull && notBefore.isNone &&
          d.int "attempts" == 0 && d.int "env_held" == 0 then
        discard <| q "UPDATE triggers SET not_before=NULL WHERE id=?" [d.get "id"]
      return none
    | none =>
      let r ← q "INSERT INTO triggers (agent, key, description, created, not_before) VALUES (?,?,?,?,?) RETURNING id"
        [agent, key, description, t, Val.opt notBefore]
      return (r[0]?.bind (·.nat? "id"))
  if id.isSome then log s!"queued for {agent}: {description}"
  return id

/-- Record a notice once per key. Whether it is new. -/
def addNotice (key kind : String) (repo : Option String) (number : Option Nat) (text : String) : D Bool := do
  let t ← now
  (← db).atomically fun q => do
    if !(← q "SELECT 1 FROM notices WHERE key=?" [key]).isEmpty then return false
    discard <| q "INSERT INTO notices (at, key, kind, repo, number, text, posted) VALUES (?,?,?,?,?,?,0)"
      [t, key, kind, Val.opt repo, Val.opt number, text]
    return true

/-- A run under way: the agent could still push. -/
def mayPush (agent : String) : D Bool := do
  return !(← q "SELECT 1 FROM runs WHERE agent=? AND ended IS NULL" [agent]).isEmpty

/-- Running, or with work queued: what it leaves undone may yet be done. -/
def busy (agent : String) : D Bool := do
  return (← mayPush agent) || !(← q "SELECT 1 FROM triggers WHERE agent=? AND run_id IS NULL" [agent]).isEmpty

def paused : D Bool := do return ← ((← read).control / "paused").pathExists
def draining : D Bool := do return ← ((← read).control / "draining").pathExists

/-- An agent the human has stopped: no run of its starts until they start it again. -/
def stopped (agent : String) : D Bool := do return ← ((← read).control / s!"stopped-{agent}").pathExists

/-- A unit's name: `repo#n` for an item. -/
def itemUnit (repo : String) (n : Nat) : String := s!"{repo}#{n}"

end Guild.Dispatcher
