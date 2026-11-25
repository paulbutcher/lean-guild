/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import GuildTests.Finite

/-! The waits between units have no loops once every `Blocked-by:` line that closes one is
invalid. -/

namespace GuildTests.Waits

open Guild Guild.Waits

/-! ## The ranks

Every wait other than `Blocked-by:` goes down a rank: the kit (4) waits on milestones (at most
3) and on pull requests (0); a milestone (3) on issues (at most 2); an issue in progress or ready
(2) on pull requests (0) and its release (at most 1); a held release (1) on issues that something
holds, which are never in progress or ready (0). -/

theorem issue_rank_le : ∀ n, Issue.rank n ≤ 2 := by intro n; cases n <;> decide
theorem release_rank_le : ∀ n, Release.rank n ≤ 1 := by intro n; cases n <;> decide
theorem milestone_rank_le : ∀ n, Milestone.rank n ≤ 3 := by intro n; cases n <;> decide

/-- What holds a release is an issue something holds, which waits on no release. -/
theorem held_issue_rank : ∀ f : Guild.Issue.Facts, f.valid → f.isOpen → f.hold ≠ .none →
    Issue.rank (Guild.Issue.state f).name = 0 := by
  intro ⟨a, b, c, d, e, g, h, i, j, k, l, m, n⟩
  revert a b c d e g h i j k l m n; decide +kernel

/-! ## The loop rule -/

variable {α : Type}

/-- A chain of waits, each an edge `P` allows. -/
inductive Path (P : Edge α → Prop) : α → α → Prop
  | refl (a) : Path P a a
  | cons {c} (e : Edge α) : P e → Path P e.dst c → Path P e.src c

theorem Path.mono {P Q : Edge α → Prop} (h : ∀ e, P e → Q e) {a b} :
    Path P a b → Path Q a b
  | .refl _ => .refl _
  | .cons e he p => .cons e (h e he) (p.mono h)

theorem Path.trans {P : Edge α → Prop} {a b c} : Path P a b → Path P b c → Path P a c
  | .refl _, q => q
  | .cons e he p, q => .cons e he (p.trans q)

/-- A `Blocked-by:` line on `u` that closes a loop of waits. -/
def Invalid (E : List (Edge α)) (u : α) : Prop :=
  ∃ e ∈ E, e.blockedBy = true ∧ e.src = u ∧ Path (· ∈ E) e.dst u

/-- The waits left once every unit with an invalid line waits on nothing. -/
def Kept (E : List (Edge α)) (e : Edge α) : Prop := e ∈ E ∧ ¬Invalid E e.src

/-- A chain that never passes through a `Blocked-by:` line goes down in rank. -/
theorem descends (E : List (Edge α)) (rank : α → Nat)
    (hr : ∀ e ∈ E, e.blockedBy = false → rank e.dst < rank e.src) {a b}
    (p : Path (Kept E) a b) :
    rank b ≤ rank a ∨
      ∃ x, Kept E x ∧ x.blockedBy = true ∧ Path (Kept E) a x.src ∧ Path (Kept E) x.dst b := by
  induction p with
  | refl => exact .inl (Nat.le_refl _)
  | cons e he p ih =>
    cases hb : e.blockedBy
    · have := hr e he.1 hb
      rcases ih with h | ⟨x, hx, hxb, p1, p2⟩
      · exact .inl (by omega)
      · exact .inr ⟨x, hx, hxb, .cons e he p1, p2⟩
    · exact .inr ⟨e, he, hb, .refl _, p⟩

/-- Once the lines that close loops are invalid, no wait is part of a loop. -/
theorem no_loop (E : List (Edge α)) (rank : α → Nat)
    (hr : ∀ e ∈ E, e.blockedBy = false → rank e.dst < rank e.src) :
    ∀ e, Kept E e → ¬Path (Kept E) e.dst e.src := by
  intro e he p
  have closes : ∀ x, Kept E x → x.blockedBy = true → Path (Kept E) x.dst x.src → False :=
    fun x hx hb q => hx.2 ⟨x, hx.1, hb, rfl, q.mono (fun _ h => h.1)⟩
  cases hb : e.blockedBy
  · rcases descends E rank hr p with h | ⟨x, hx, hxb, p1, p2⟩
    · have := hr e he.1 hb; omega
    · exact closes x hx hxb (p2.trans (.cons e he p1))
  · exact closes e he hb p

/-! ## The dispatcher's search -/

/-- What the search finds is a chain of waits. -/
theorem reachedFrom_sound [DecidableEq α] (E : List (Edge α)) :
    ∀ fuel a y, y ∈ reachedFrom E fuel a → Path (· ∈ E) a y
  | 0, a, y, h => by simp [reachedFrom] at h; subst h; exact .refl _
  | fuel + 1, a, y, h => by
    simp only [reachedFrom, grow, List.mem_append, List.mem_map, List.mem_filter,
      Bool.and_eq_true, List.contains_iff_mem] at h
    rcases h with h | ⟨e, ⟨he, hs, _⟩, rfl⟩
    · exact reachedFrom_sound E fuel a y h
    · exact (reachedFrom_sound E fuel a e.src hs).trans (.cons e he (.refl _))

theorem reaches_sound [DecidableEq α] (E : List (Edge α)) (fuel : Nat) (a b : α)
    (h : reaches E fuel a b = true) : Path (· ∈ E) a b :=
  reachedFrom_sound E fuel a b (by simpa [reaches] using h)

theorem reachedFrom_step [DecidableEq α] (E : List (Edge α)) (fuel : Nat) (a : α) (e : Edge α)
    (he : e ∈ E) (hs : e.src ∈ reachedFrom E fuel a) : e.dst ∈ reachedFrom E (fuel + 1) a := by
  simp only [reachedFrom, grow, List.mem_append, List.mem_map, List.mem_filter, Bool.and_eq_true,
    List.contains_iff_mem]
  by_cases hd : e.dst ∈ reachedFrom E fuel a
  · exact .inl hd
  · exact .inr ⟨e, ⟨he, hs, by simpa using hd⟩, rfl⟩

/-- Every chain of waits is found, given enough fuel. That the length of the list of waits is
enough is checked as a property in the test runner: a proof needs a shortest-path argument, and
the property, that more fuel never finds more, settles the same thing. -/
theorem reaches_complete [DecidableEq α] (E : List (Edge α)) {a b} (p : Path (· ∈ E) a b) :
    ∃ fuel, reaches E fuel a b = true := by
  suffices h : ∀ {x c}, Path (· ∈ E) x c → ∀ k, x ∈ reachedFrom E k a →
      ∃ m, c ∈ reachedFrom E (k + m) a by
    obtain ⟨m, hm⟩ := h p 0 (by simp [reachedFrom])
    exact ⟨0 + m, by simpa [reaches] using hm⟩
  intro x c p
  induction p with
  | refl => intro k hk; exact ⟨0, hk⟩
  | cons e he _ ih =>
    intro k hk
    obtain ⟨m, hm⟩ := ih (k + 1) (reachedFrom_step E k a e he hk)
    exact ⟨m + 1, by simpa [Nat.add_assoc, Nat.add_comm 1 m] using hm⟩

end GuildTests.Waits
