/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
module

public import Guild.Forge
public import Json

/-! The human's brakes, as files in `control/` with the reference's names and meanings, so either
kit sees the other's; and what pausing and resuming do in the forge, in the human's name, as the
reference's `pause.sh` and `resume.sh` did. Each action returns what it did, for the page. -/

@[expose] public section

namespace Guild.Ui

open Guild.Forge Json

structure Brakes where
  control : System.FilePath
  /-- The forge as the human. -/
  forge : Forge
  human : String
  repos : List String

def Brakes.pausedMerges (b : Brakes) : System.FilePath := b.control / "paused-merges.json"

def touch (path : System.FilePath) : IO Unit := IO.FS.writeFile path ""

def removeIfThere (path : System.FilePath) : IO Unit := do
  if ← path.pathExists then IO.FS.removeFile path

def attempt {α} (what : String) (m : M α) (log : IO.Ref (List String)) : IO (Option α) := do
  match ← m.run with
  | .ok a => return some a
  | .error e => log.modify (· ++ [s!"couldn't {what}: {e}"]); return none

/-- Who scheduled the pull request's merge, if it is scheduled: the last scheduling in its
timeline not cancelled since. -/
def scheduledBy (f : Forge) (repo : Repo) (n : Nat) : M (Option String) := do
  let marks := (← f.timeline repo n).filter fun e => match e.event with
    | .scheduleMerge | .cancelScheduledMerge => true
    | _ => false
  return match marks.getLast? with
    | some { event := .scheduleMerge, actor, .. } => some actor
    | _ => none

structure Paused where
  repo : String
  number : Nat
  scheduledBy : String

def Paused.encode (p : Paused) : Json :=
  Json.mkObj [("repo", toJson p.repo), ("number", toJson p.number), ("scheduled_by", toJson p.scheduledBy)]

def Paused.ofJson (j : Json) : Option Paused := do
  return { repo := ← (j.getObjVal? "repo" >>= (·.getStr?)).toOption,
           number := ← (j.getObjVal? "number" >>= (·.getNat?)).toOption,
           scheduledBy := ((j.getObjVal? "scheduled_by" >>= (·.getStr?)).toOption).getD "" }

def Brakes.recorded (b : Brakes) : IO (List Paused) := do
  unless ← b.pausedMerges.pathExists do return []
  match parse (← IO.FS.readFile b.pausedMerges) with
  | .ok (.arr xs) => return xs.toList.filterMap Paused.ofJson
  | _ => return []

/-- Nothing changes in the forge but by the human: the brake first, so it holds whatever the
forge says; then every scheduled merge is cancelled and recorded for `resume`, and only the human
may merge into each `main`. -/
def Brakes.pause (b : Brakes) : IO (List String) := do
  touch (b.control / "paused")
  let log ← IO.mkRef ["Paused: no run starts, and runs under way stop at their next step."]
  let mut recorded ← b.recorded
  for repo in b.repos do
    for p in ((← attempt s!"list {repo}'s pull requests" (b.forge.pulls repo .open) log).getD []) do
      let some (some who) ← attempt s!"read {repo}#{p.number}'s timeline" (scheduledBy b.forge repo p.number) log
        | continue
      if (← attempt s!"cancel {repo}#{p.number}'s scheduled merge" (b.forge.cancelMerge repo p.number) log).isSome then
        recorded := (recorded.filter fun r => !(r.repo == repo && r.number == p.number)) ++
          [{ repo, number := p.number, scheduledBy := who }]
        log.modify (· ++ [s!"Cancelled the scheduled merge of {repo}#{p.number}, scheduled by {who}."])
    discard <| attempt s!"narrow who may merge into {repo}" (b.forge.mergers repo (some [b.human])) log
  IO.FS.writeFile b.pausedMerges ((Json.arr (recorded.map Paused.encode).toArray).pretty ++ "\n")
  log.modify (· ++ [s!"Only {b.human} may merge; {recorded.length} cancelled merge(s) recorded for resuming."])
  log.get

def Brakes.drain (b : Brakes) : IO (List String) := do
  touch (b.control / "draining")
  return ["Draining: runs under way finish, and no run starts until you resume."]

/-- The brakes off. After a pause, every merge list is restored, and each cancelled merge is made,
or scheduled again where it can't go ahead yet, in the human's name. -/
def Brakes.resume (b : Brakes) : IO (List String) := do
  unless ← (b.control / "paused").pathExists do
    removeIfThere (b.control / "draining")
    return ["Resumed: agents start work again."]
  let log ← IO.mkRef []
  for repo in b.repos do
    discard <| attempt s!"restore who may merge into {repo}" (b.forge.mergers repo none) log
  for r in ← b.recorded do
    let some (some p) ← attempt s!"read {r.repo}#{r.number}" (b.forge.pull r.repo r.number) log | continue
    unless p.isOpen do
      log.modify (· ++ [s!"{r.repo}#{r.number} is no longer open; not merging it."])
      continue
    -- Forgejo acts on a scheduled merge only when a review or a status arrives after it, so one
    -- that could go ahead now is merged rather than scheduled.
    match ← attempt s!"merge {r.repo}#{r.number}" (b.forge.merge r.repo r.number false) log with
    | some .merged => log.modify (· ++ [s!"Merged {r.repo}#{r.number}, in {b.human}'s name."])
    | _ =>
      match ← attempt s!"schedule {r.repo}#{r.number}'s merge" (b.forge.merge r.repo r.number true) log with
      | some .scheduled => log.modify (· ++ [s!"Scheduled the merge of {r.repo}#{r.number} again, in {b.human}'s name."])
      | some other => log.modify (· ++ [s!"Couldn't schedule {r.repo}#{r.number}'s merge: {repr other}."])
      | none => pure ()
  removeIfThere b.pausedMerges
  removeIfThere (b.control / "paused")
  removeIfThere (b.control / "draining")
  log.modify (· ++ ["Resumed: agents start work again."])
  log.get

def stopAgent (control : System.FilePath) (agent : String) : IO Unit := touch (control / s!"stopped-{agent}")
def startAgent (control : System.FilePath) (agent : String) : IO Unit := removeIfThere (control / s!"stopped-{agent}")
def stopRun (control : System.FilePath) (run : Nat) : IO Unit := touch (control / s!"stop-run-{run}")

/-- Requests to stop runs that have ended, which nothing would read again. -/
def tidyStops (control : System.FilePath) (ended : List Nat) : IO Unit := do
  for run in ended do removeIfThere (control / s!"stop-run-{run}")

end Guild.Ui
