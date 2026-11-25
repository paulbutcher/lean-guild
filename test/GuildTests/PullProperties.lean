/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import GuildTests.Properties
import GuildTests.PullCore

namespace GuildTests.Pull

open Guild Guild.Pull

/-- The waits on the world still to come on this code: CI, the head settling, the forge
checking mergeability, the scheduled merge, and the pull request still open. -/
def clock (f : Facts) : Nat :=
  (if f.isOpen then 1 else 0) +
  (if (f.ci == .none || f.ci == .running) && !f.ciLate then 1 else 0) +
  (if f.conformance == .settling then 1 else 0) +
  (if f.mergeable == .unknown && !f.checkLate then 1 else 0) +
  (if f.stuck then 0 else 1)

/-- Only a push winds the clock back, and every step the world alone may take moves it on. So
on the same code each wait on the world happens once; only a re-run, which `Rerun` counts,
repeats one. -/
def onceEach (f g : Facts) : Bool :=
  g == pushed f ||
    (clock g ≤ clock f && (!(state f).holders.all (fun r => r == .timer || r == .world) ||
      clock g < clock f))

theorem deadline_core : ∀ a b c d e g h i j k l m n,
    (core a b c d e g h i j k l m n).valid →
    (state (core a b c d e g h i j k l m n)).holders.contains .timer →
      (expire (core a b c d e g h i j k l m n)).valid &&
        actionable (state (expire (core a b c d e g h i j k l m n))) := by
  decide +kernel

theorem onceEach_core : ∀ a b c d e g h i j k l m n,
    (core a b c d e g h i j k l m n).valid →
      (steps (core a b c d e g h i j k l m n)).all (onceEach (core a b c d e g h i j k l m n)) := by
  decide +kernel

/-- Every state the forge or CI holds has a deadline, after which someone who can act holds it. -/
theorem deadline : ∀ f : Facts, f.valid → (state f).holders.contains .timer →
    (expire f).valid && actionable (state (expire f)) := by
  intro ⟨o, h, a, b, c, d, e, g, i, j, k, l, m, n, p⟩ hv ht
  cases o
  · simp [state] at ht
  cases h
  case none => exact deadline_core a b c d e g i j k l m n p hv ht
  all_goals simp [state, Hold.state] at ht

/-- Every cycle through the world on the same code is bounded. -/
theorem worldBounded : ∀ f : Facts, f.valid → (steps f).all (onceEach f) := by
  intro ⟨o, h, a, b, c, d, e, g, i, j, k, l, m, n, p⟩ hv
  cases o
  · simp [steps, state]
  cases h
  case none => exact onceEach_core a b c d e g i j k l m n p hv
  case upstream => simp [Facts.valid] at hv
  all_goals
    simp only [List.all_eq_true]
    intro g' hg
    simp [steps, state, Hold.state, holdSteps, HoldNames.withHuman,
      HoldNames.waiting, HoldNames.invalid, HoldNames.blocked, HoldNames.blockedWithoutReason] at hg
    rcases hg with rfl | rfl <;> simp [onceEach, clock, state, Hold.state]

end GuildTests.Pull
