/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import GuildTests.Finite
import GuildTests.Steps

/-! The reference's completeness checks, over every combination of every unit's facts:
1. a state is finished exactly when it is one of the finished states listed here, and every
   state that isn't finished has holders, and says what to do to any agent among them;
2. every holder's step moves the unit to another state or other holders, so a holder that does
   its step is never woken for the same thing again;
3. from every combination, a finished state can be reached by holders doing their steps and the
   world doing what it does. -/

namespace GuildTests

open Guild

/-- Finished within `n` steps, by some path. -/
def canFinish {F N} (state : F → State N) (steps : F → List F) : Nat → F → Bool
  | 0, f => (state f).terminal
  | n + 1, f => (state f).terminal || (steps f).any (canFinish state steps n)

/-- More steps never hurt. -/
theorem canFinish_succ {F N} (state : F → State N) (steps : F → List F) :
    ∀ n f, canFinish state steps n f = true → canFinish state steps (n + 1) f = true
  | 0, f, h => by simp [canFinish] at h ⊢; simp [h]
  | n + 1, f, h => by
    rw [canFinish.eq_2] at h ⊢
    simp only [Bool.or_eq_true, List.any_eq_true] at h ⊢
    rcases h with h | ⟨g, hg, h⟩
    · exact .inl h
    · exact .inr ⟨g, hg, canFinish_succ state steps n g h⟩

/-- Check 1, for one combination. -/
def told {F N} (state : F → State N) (finished : N → Bool) (f : F) : Bool :=
  (state f).terminal == finished (state f).name &&
  (!(state f).holders.any Role.isAgent || (state f).step != "")

/-- Check 2, for one combination: each step stays among the facts the space allows. -/
def movesOn {F N} [DecidableEq N] (valid : F → Bool) (state : F → State N) (steps : F → List F)
    (f : F) : Bool :=
  (state f).terminal || (steps f).all (fun g => valid g && (state g).key != (state f).key)

end GuildTests
