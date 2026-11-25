/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Guild

/-! The scheduler over every infinite execution: at each step the environment chooses whether
the agent is busy and whether the unit moved on. -/

namespace GuildTests.Obligation

open Guild.Obligation

def run (b : Bounds) (quiet : Bool) (env : Nat → Env) : Nat → St
  | 0 => {}
  | n + 1 => step b quiet (run b quiet env n) (env n)

/-- What is left before it must settle: each step that doesn't settle it uses up at least one. -/
def budget (b : Bounds) (s : St) : Nat :=
  (b.tries - s.wakes) * (b.patience + 1) + (b.patience - s.waited)

/-! ## One step -/

-- Every case of a step: each flag, and each comparison the step makes.
set_option hygiene false in
macro "step_cases" : tactic => `(tactic|
  (obtain ⟨st, x, d, w, wt⟩ := s; obtain ⟨bz, dc⟩ := e
   cases st <;> cases x <;> cases d <;> cases dc <;> cases q <;> cases bz <;>
   by_cases h1 : wt < b.patience <;> by_cases h2 : b.tries ≤ w <;>
   simp only [step, h1, h2, decide_true, decide_false, Bool.not_true, Bool.not_false,
     Bool.and_true, Bool.and_false, Bool.false_eq_true, ↓reduceIte] <;>
   intros <;> simp_all [St.settled, woke, budget] <;>
   (try (have e1 : b.tries - w = (b.tries - (w + 1)) + 1 := by omega
         rw [e1, Nat.add_mul, Nat.one_mul])) <;> omega))

theorem step_settled (b q s e) : s.settled = true → (step b q s e).settled = true := by
  step_cases

theorem step_bounded (b q s e) : s.waited ≤ b.patience → s.wakes ≤ b.tries →
    (step b q s e).waited ≤ b.patience ∧ (step b q s e).wakes ≤ b.tries := by
  step_cases

/-- A step that leaves it unsettled spends some of what is left. -/
theorem step_spends (b q s e) : s.waited ≤ b.patience → s.wakes ≤ b.tries →
    (step b q s e).settled = false → budget b (step b q s e) < budget b s := by
  step_cases

theorem step_escalated (b q s e) : s.wakes ≤ b.tries → (s.escalated = true → s.wakes = b.tries) →
    (step b q s e).escalated = true → (step b q s e).wakes = b.tries := by
  step_cases

theorem step_decision (b q s e) : (s.decision = true → s.standing = true ∧ s.escalated = true) →
    (step b q s e).decision = true →
      (step b q s e).standing = true ∧ (step b q s e).escalated = true := by
  step_cases

/-- A step that neither wakes its agent nor settles it is a quiet one waiting, once more. -/
theorem step_waits (b q s e) : s.settled = false → (step b q s e).settled = false →
    woke s (step b q s e) = false → s.waited < b.patience ∧ (step b q s e).waited = s.waited + 1 := by
  step_cases

/-! ## Every execution -/

theorem bounded (b : Bounds) (q : Bool) (env : Nat → Env) :
    ∀ n, (run b q env n).waited ≤ b.patience ∧ (run b q env n).wakes ≤ b.tries
  | 0 => by simp [run]
  | n + 1 => step_bounded _ _ _ _ (bounded b q env n).1 (bounded b q env n).2

theorem progress (b : Bounds) (q : Bool) (env : Nat → Env) :
    ∀ n, (run b q env n).settled = true ∨
      budget b (run b q env n) + n ≤ (b.tries + 1) * (b.patience + 1) - 1
  | 0 => by
    right; simp only [run, budget, Nat.sub_zero, Nat.add_zero]
    rw [Nat.add_mul, Nat.one_mul]; omega
  | n + 1 => by
    cases h : (run b q env (n + 1)).settled
    · right
      rcases progress b q env n with h' | h'
      · have := step_settled b q _ (env n) h'
        simp only [run] at h; simp_all
      · have := step_spends b q _ (env n) (bounded b q env n).1 (bounded b q env n).2
          (by simpa [run] using h)
        simp only [run] at this ⊢
        omega
    · left; rfl

/-- However busy its agent is kept and whatever its runs do, an obligation, quiet or not, is
discharged or is the human's within `(tries + 1) * (patience + 1)` steps. -/
theorem settles (b : Bounds) (q : Bool) (env : Nat → Env) :
    (run b q env ((b.tries + 1) * (b.patience + 1))).settled = true := by
  rcases progress b q env ((b.tries + 1) * (b.patience + 1)) with h | h
  · exact h
  · have : 0 < (b.tries + 1) * (b.patience + 1) := Nat.mul_pos (by omega) (by omega)
    omega

/-- It reaches the human after exactly `tries` runs that left it standing, never more. -/
theorem escalates_after_tries (b : Bounds) (q : Bool) (env : Nat → Env) :
    ∀ n, (run b q env n).escalated = true → (run b q env n).wakes = b.tries
  | 0 => by simp [run]
  | n + 1 => step_escalated _ _ _ _ (bounded b q env n).2 (escalates_after_tries b q env n)

/-- While it stands, its agent is woken again within `patience + 1` steps, unless it settles
first: a quiet one waits for other work at most `patience` times in a row. -/
theorem woken_again (b : Bounds) (q : Bool) (env : Nat → Env) :
    ∀ j n, b.patience - (run b q env n).waited ≤ j → (run b q env n).settled = false →
      ∃ k ≤ j, woke (run b q env (n + k)) (run b q env (n + k + 1)) = true ∨
        (run b q env (n + k + 1)).settled = true := by
  intro j
  induction j with
  | zero =>
    intro n hj hs
    refine ⟨0, Nat.le_refl _, ?_⟩
    cases ht : (run b q env (n + 1)).settled
    · cases hw : woke (run b q env n) (run b q env (n + 1))
      · have := step_waits b q _ (env n) hs (by simpa [run] using ht) (by simpa [run] using hw)
        omega
      · simp
    · simp
  | succ j ih =>
    intro n hj hs
    cases ht : (run b q env (n + 1)).settled
    · cases hw : woke (run b q env n) (run b q env (n + 1))
      · have := step_waits b q _ (env n) hs (by simpa [run] using ht) (by simpa [run] using hw)
        obtain ⟨k, hk, h⟩ := ih (n + 1) (by simp only [run] at *; omega) ht
        exact ⟨k + 1, by omega, by simpa [Nat.add_assoc, Nat.add_comm 1 k] using h⟩
      · exact ⟨0, Nat.zero_le _, .inl hw⟩
    · exact ⟨0, Nat.zero_le _, .inr ht⟩

/-- A `Stalled:` decision is open only while the obligation it reports is the human's and still
stands: once the unit moves on, it closes. -/
theorem decision_has_cause (b : Bounds) (q : Bool) (env : Nat → Env) :
    ∀ n, (run b q env n).decision = true →
      (run b q env n).standing = true ∧ (run b q env n).escalated = true
  | 0 => by simp [run]
  | n + 1 => step_decision _ _ _ _ (decision_has_cause b q env n)

end GuildTests.Obligation
