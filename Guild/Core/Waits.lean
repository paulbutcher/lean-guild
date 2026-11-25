/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
module

public import Guild.Core.Issue
public import Guild.Core.Pull
public import Guild.Core.Release
public import Guild.Core.Milestone
public import Guild.Core.Kit

/-! The waits between units. A unit held by other units waits on them: an issue in progress on
its pull requests, a ready one on its repository's release, a held release on the issues that
hold it, a milestone on its issues, the kit on its milestones and planning, and an item on what
its `Blocked-by:` lines name. Every wait but `Blocked-by:` goes down a rank, so a loop of waits
must pass through a `Blocked-by:` line, and a line that closes one is invalid. -/

@[expose] public section

namespace Guild.Waits

def Issue.rank : Issue.Name → Nat
  | .inProgress | .ready => 2
  | _ => 0

def Pull.rank : Pull.Name → Nat := fun _ => 0

def Release.rank : Release.Name → Nat
  | .held => 1
  | _ => 0

def Milestone.rank : Milestone.Name → Nat
  | .inProgress => 3
  | _ => 0

def Kit.rank : Kit.Name → Nat
  | .inProgress | .planning => 4
  | _ => 0

/-- One unit waiting on another. -/
structure Edge (α : Type) where
  src : α
  dst : α
  /-- From a `Blocked-by:` line, rather than from the units' states. -/
  blockedBy : Bool
  deriving DecidableEq, Repr

/-- The units reached by one more wait, added to those already reached. -/
def grow {α} [BEq α] (edges : List (Edge α)) (reached : List α) : List α :=
  reached ++ ((edges.filter (fun e => reached.contains e.src && !reached.contains e.dst)).map (·.dst))

/-- The units reached from `a` by following at most `fuel` waits. -/
def reachedFrom {α} [BEq α] (edges : List (Edge α)) : Nat → α → List α
  | 0, a => [a]
  | fuel + 1, a => grow edges (reachedFrom edges fuel a)

/-- Whether `b` is reached from `a` by following waits, in at most `fuel` of them. -/
def reaches {α} [BEq α] (edges : List (Edge α)) (fuel : Nat) (a b : α) : Bool :=
  (reachedFrom edges fuel a).contains b

/-- A unit whose `Blocked-by:` line closes a loop of waits: what the line names waits, however
indirectly, on the unit itself. Such a line is invalid, and held by whoever wrote it, so the
unit waits on nothing. No path without repeats is longer than the list of waits. -/
def invalid {α} [BEq α] (edges : List (Edge α)) (u : α) : Bool :=
  edges.any (fun e => e.blockedBy && e.src == u && reaches edges edges.length e.dst u)

end Guild.Waits
