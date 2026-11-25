/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import GuildTests.PullCore

/-! The checks for pull requests, from the core's: what holds or closes one doesn't depend on its
other facts. -/

namespace GuildTests.Pull

open Guild Guild.Pull

theorem told : ∀ f : Facts, f.valid → GuildTests.told state finished f := by
  intro ⟨o, h, a, b, c, d, e, g, i, j, k, l, m, n, p⟩ hv
  cases o
  · simp [GuildTests.told, state, finished, State.terminal]
  cases h
  case none => exact told_core a b c d e g i j k l m n p hv
  all_goals simp [GuildTests.told, state, Hold.state, finished, State.terminal, Role.isAgent,
    HoldNames.withHuman, HoldNames.upstream, HoldNames.waiting, HoldNames.invalid,
    HoldNames.blocked, HoldNames.blockedWithoutReason]

theorem state_of_held (f : Facts) (ho : f.isOpen = true) (s : State)
    (hs : (f.hold.state : Option State) = some s) : state f = s := by
  simp [state, ho, hs]

theorem movesOn : ∀ f : Facts, f.valid → GuildTests.movesOn Facts.valid state steps f := by
  intro ⟨o, h, a, b, c, d, e, g, i, j, k, l, m, n, p⟩ hv
  cases o
  · simp [GuildTests.movesOn, state, State.terminal]
  cases h
  case none => exact movesOn_core a b c d e g i j k l m n p hv
  all_goals
    have hc := core_not_held a b c d e g i j k l m n p
    have hvc : (core a b c d e g i j k l m n p).valid = true := by simp_all [core, Facts.valid]
    simp only [core] at hc hvc
    simp only [GuildTests.movesOn, steps]
    rw [state_of_held _ rfl _ rfl]
    have hb : state ⟨true, .blocked, a, b, c, d, e, g, i, j, k, l, m, n, p⟩ =
        { name := .blocked, holders := [.blockers] } := rfl
    simp only [holdSteps, HoldNames.withHuman, HoldNames.upstream, HoldNames.waiting,
      HoldNames.invalid, HoldNames.blocked, HoldNames.blockedWithoutReason, State.terminal,
      State.key, List.isEmpty, List.all_cons, List.all_nil, Bool.false_or, Bool.and_true, hvc,
      Bool.true_and, hb]
    generalize state ⟨true, .none, a, b, c, d, e, g, i, j, k, l, m, n, p⟩ = s at hc ⊢
    rcases s with ⟨nm, _, _, _⟩
    cases nm <;> simp_all [isHoldName, Facts.valid]

theorem canFinish : ∀ f : Facts, f.valid → GuildTests.canFinish state steps 15 f := by
  intro ⟨o, h, a, b, c, d, e, g, i, j, k, l, m, n, p⟩ hv
  cases o
  · simp [GuildTests.canFinish, state, State.terminal]
  cases h
  case none =>
    exact canFinish_succ _ _ _ _ (canFinish_core a b c d e g i j k l m n p hv)
  all_goals
    have hc := canFinish_core a b c d e g i j k l m n p
    simp only [core, Facts.valid] at hc hv
    unfold GuildTests.canFinish
    simp_all [steps, holdSteps, state, Hold.state, State.terminal, HoldNames.withHuman,
      HoldNames.waiting, HoldNames.invalid, HoldNames.blocked,
      HoldNames.blockedWithoutReason]

end GuildTests.Pull
