/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import GuildTests.Finite
import GuildTests.Steps

namespace GuildTests

open Guild

/-! ## Every role names someone -/

/-- So every state that isn't finished, whose holders are never empty, has someone woken. -/
theorem resolve_nonempty (who : Role → List Holder) (r : Role) : resolve who r ≠ [] := by
  unfold resolve
  split
  · split
    · split <;> simp_all
    · simp_all
  · split <;> simp

/-! ## Deadlines

Every state that the forge or CI holds has a deadline, after which its facts hand it to someone
who can act. -/

/-- Someone can act on it: an agent or the human, and no timer. -/
def actionable {N} (s : State N) : Bool :=
  !s.holders.contains .timer && s.holders.any (fun r => r.isAgent || r == .human)

/-- An agent hands the unit to the world or a timer: nobody else holds what its step leads to. -/
def handOff {N} (s t : State N) : Bool :=
  s.holders.any Role.isAgent && !t.terminal && t.holders.all (fun r => r == .timer || r == .world)

namespace Release
open Guild.Release

theorem deadline : ∀ f : Facts, f.valid → (state f).holders.contains .timer →
    (expire f).valid && actionable (state (expire f)) := by
  intro ⟨a, b, c, d, e, g, h, i⟩; revert a b c d e g h i; decide +kernel

/-- An agent hands the release to CI only by starting a run on main: a push, or a re-run, which
`Rerun` counts. -/
theorem handOffs : ∀ f : Facts, f.valid →
    (steps f).all (fun g => !handOff (state f) (state g) || g.mainCi == .running) := by
  intro ⟨a, b, c, d, e, g, h, i⟩; revert a b c d e g h i; decide +kernel

end Release

/-- An issue is handed to the world only when it was already labelled upstream, which a state
ranked above the holds hid: a milestone issue whose reviews report, or a release decision a
release overtook, which its update makes a task. -/
theorem Issue.handOffs : ∀ f : Guild.Issue.Facts, f.valid →
    (Issue.steps f).all (fun g =>
      !handOff (Guild.Issue.state f) (Guild.Issue.state g) ||
        (f.hold == .upstream && (f.kind == .milestone || f.kind == .releaseDecision) &&
          (g.kind == .milestone && !g.unreported || g.kind == .task))) := by
  intro ⟨a, b, c, d, e, g, h, i, j, k, l, m, n⟩
  revert a b c d e g h i j k l m n; decide +kernel

/-- Neither hand-off repeats: no step owes a milestone review again, or makes an issue a release
decision. -/
theorem Issue.handOffsOnce : ∀ f : Guild.Issue.Facts, f.valid →
    (Issue.steps f).all (fun g =>
      (!g.unreported || f.unreported) &&
        (g.kind != .releaseDecision || f.kind == .releaseDecision)) := by
  intro ⟨a, b, c, d, e, g, h, i, j, k, l, m, n⟩
  revert a b c d e g h i j k l m n; decide +kernel

/-! ## Re-runs -/

namespace Rerun
open Guild.Rerun

/-- An agent asks for a re-run every time CI fails, which it always does; the tool runs one
only while it is allowed. -/
def attempts (limit : Nat) : Nat → Nat
  | 0 => 1
  | n + 1 => let a := attempts limit n; if allowed limit a then a + 1 else a

theorem bounded (limit : Nat) : ∀ n, attempts limit n ≤ limit + 1
  | 0 => by simp [attempts]
  | n + 1 => by
    have := bounded limit n
    simp only [attempts, allowed]
    by_cases h : attempts limit n ≤ limit <;> simp [h] <;> omega

/-- However often it asks, it runs at most `limit` re-runs on the head, and once they are spent
the human is told. -/
theorem spent_after (limit : Nat) : spent limit (attempts limit limit) = true := by
  suffices h : ∀ n, n ≤ limit → attempts limit n = n + 1 by simp [spent, h limit (Nat.le_refl _)]
  intro n
  induction n with
  | zero => intro; rfl
  | succ n ih => intro hn; simp [attempts, allowed, ih (by omega)]; omega

end Rerun

/-! ## The run budget -/

namespace Budget
open Guild.Budget

inductive Event
  | run
  | seen

def apply (budget : Nat) (s : St) : Event → St
  | .run => (run budget s).1
  | .seen => seen s

def after (budget : Nat) (es : List Event) : St := es.foldl (apply budget) {}

/-- Whatever the agents and the world do, a unit never has a budget of runs without the human
being told since they last looked. -/
theorem told (budget : Nat) (hb : 0 < budget) :
    ∀ es, budget ≤ (after budget es).runs → (after budget es).noticed = true := by
  suffices h : ∀ (es : List Event) (s : St), (budget ≤ s.runs → s.noticed = true) →
      budget ≤ (es.foldl (apply budget) s).runs → (es.foldl (apply budget) s).noticed = true by
    intro es; exact h es {} (by simp; omega)
  intro es
  induction es with
  | nil => intro s h; exact h
  | cons e es ih =>
    intro s h
    apply ih
    cases e <;> simp only [apply, run, seen]
    · split
      · simp
      · rename_i hc; intro hr; simp_all
    · intro hr; simp at hr; omega

/-- A notice goes out only while none is waiting to be seen: one per budget, not one per run. -/
theorem once (budget : Nat) (s : St) (h : (run budget s).2 = true) :
    s.noticed = false ∧ (run budget s).1.noticed = true := by
  simp only [run] at h ⊢; split at h <;> simp_all

end Budget

/-! ## Versions -/

namespace Version
open Guild.Version

theorem first : next none "" "" = ⟨0, 1, 0⟩ := rfl

/-- Before 1.0 every release stays before 1.0: only the human makes 1.0. -/
theorem stays_before_1 (v : Version) (old new : String) (h : v.major = 0) :
    (next (some v) old new).major = 0 := by
  obtain ⟨x, y, z⟩ := v; simp at h; subst h
  simp only [next, BEq.rfl, ite_true]; split <;> rfl

/-- An unchanged API is a patch. -/
theorem unchanged (v : Version) (api : String) :
    next (some v) api api = ⟨v.major, v.minor, v.patch + 1⟩ := by
  obtain ⟨x, y, z⟩ := v
  simp only [next, List.any_eq_true, decide_eq_true_eq]
  have : ¬∃ l ∈ apiLines api, l ∉ apiLines api := fun ⟨_, h, h'⟩ => h' h
  simp only [this, Bool.or_self]
  split <;> simp_all

end Version

end GuildTests
