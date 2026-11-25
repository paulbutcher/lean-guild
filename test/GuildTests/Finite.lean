/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Guild

/-! A type with finitely many values, listed, so that the kernel decides a statement about every
one of them. -/

namespace GuildTests

class Finite (α : Type) where
  all : List α
  complete : ∀ a, a ∈ all

instance {α} [Finite α] {P : α → Prop} [DecidablePred P] : Decidable (∀ a, P a) :=
  decidable_of_iff (∀ a ∈ (Finite.all : List α), P a)
    ⟨fun h a => h a (Finite.complete a), fun h a _ => h a⟩

instance : Finite Bool := ⟨[false, true], by decide⟩

open Guild in
instance : Finite Hold :=
  ⟨[.none, .human, .upstream, .waiting, .invalid, .blocked, .bareLabel], by intro a; cases a <;> decide⟩

open Guild.Issue in
instance : Finite Kind :=
  ⟨[.request, .task, .milestone, .recommendation, .kitDecision, .releaseDecision],
   by intro a; cases a <;> decide⟩

open Guild.Pull in
instance : Finite Ci := ⟨[.none, .running, .failure, .success, .unused], by intro a; cases a <;> decide⟩
open Guild.Pull in
instance : Finite Mergeable := ⟨[.yes, .no, .unknown], by intro a; cases a <;> decide⟩
open Guild.Pull in
instance : Finite Changes := ⟨[.none, .atHead, .replied, .older], by intro a; cases a <;> decide⟩
open Guild.Pull in
instance : Finite Conformance := ⟨[.reviewed, .settling, .due], by intro a; cases a <;> decide⟩

open Guild.Release in
instance : Finite Ci := ⟨[.success, .failure, .running, .none], by intro a; cases a <;> decide⟩
open Guild.Release in
instance : Finite Heading := ⟨[.none, .wrong, .right], by intro a; cases a <;> decide⟩

open Guild.Milestone in
instance : Finite Issue := ⟨[.none, .isOpen, .closed], by intro a; cases a <;> decide⟩

open Guild.Kit in
instance : Finite Milestones := ⟨[.noneEver, .openWork, .done], by intro a; cases a <;> decide⟩

end GuildTests
