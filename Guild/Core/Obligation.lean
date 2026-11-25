/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

/-! What an agent owes on a unit, a state it holds or an ask it hasn't answered, and how the
dispatcher moves it on each time it is due: it wakes the agent, and once `tries` runs have ended
with it still standing, it becomes the human's as a `Stalled:` decision. -/

namespace Guild.Obligation

structure St where
  /-- The unit still owes it. -/
  standing : Bool := true
  /-- The human's: its tries are spent. -/
  escalated : Bool := false
  /-- The `Stalled:` decision for it is open. -/
  decision : Bool := false
  /-- Runs it woke that ended with it standing. -/
  wakes : Nat := 0
  /-- Times in a row a quiet one has waited for its busy agent. -/
  waited : Nat := 0
  deriving DecidableEq, Repr, Inhabited

/-- What the rest of the kit does by the time it is due: whether its agent has other work queued
or running, and whether the unit no longer owes it, whoever moved it on. -/
structure Env where
  busy : Bool
  discharged : Bool
  deriving DecidableEq, Repr

/-- Nothing more happens to it: discharged, or the human's. -/
def St.settled (s : St) : Bool := !s.standing || s.escalated

/-- How many runs may end with it standing before it is the human's, and how many times in a
row a quiet one waits for its agent's other work: a wait is a run of that agent, since a quiet
one that waited is due again only when the run ends. Without the second bound, an agent kept busy
would never be woken for a quiet obligation, and no one would be told. -/
structure Bounds where
  tries : Nat
  patience : Nat
  deriving DecidableEq, Repr

/-- One call when it is due. Once discharged it is gone, and its decision, if any, is closed. -/
def step (b : Bounds) (quiet : Bool) (s : St) (e : Env) : St :=
  if !s.standing then s
  else if e.discharged then { s with standing := false, decision := false }
  else if s.escalated then s
  else if quiet && e.busy && decide (s.waited < b.patience) then { s with waited := s.waited + 1 }
  else if b.tries ≤ s.wakes then { s with escalated := true, decision := true }
  else { s with wakes := s.wakes + 1, waited := 0 }

/-- Whether a step woke its agent. -/
def woke (s t : St) : Bool := s.wakes < t.wakes

end Guild.Obligation
