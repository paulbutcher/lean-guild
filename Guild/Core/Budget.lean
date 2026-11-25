/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

/-! A budget of agent runs per unit, as a backstop for loops the states don't describe, such as
an author pushing attempted fixes indefinitely. Every run woken for the unit counts, by any
holder, whether it acted or not. -/

namespace Guild.Budget

structure St where
  /-- Runs since the human last marked its notice seen. -/
  runs : Nat := 0
  /-- A notice is out and not yet seen. -/
  noticed : Bool := false
  deriving DecidableEq, Repr, Inhabited

/-- A run for the unit, and whether it gives the human a notice: the run that reaches the
budget, once until the notice is seen. -/
def run (budget : Nat) (s : St) : St × Bool :=
  let runs := s.runs + 1
  if budget ≤ runs && !s.noticed then ({ runs, noticed := true }, true)
  else ({ s with runs }, false)

/-- The human marked its notice seen: the count starts again. -/
def seen (_ : St) : St := {}

end Guild.Budget
