/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import GuildTests.Checks

namespace GuildTests

namespace Release
open Guild.Release

def finished : Name → Bool | .upToDate => true | _ => false

theorem told : ∀ f : Facts, f.valid → GuildTests.told state finished f := by
  intro ⟨a, b, c, d, e, g, h⟩; revert a b c d e g h; decide +kernel

theorem movesOn : ∀ f : Facts, f.valid → GuildTests.movesOn Facts.valid state steps f := by
  intro ⟨a, b, c, d, e, g, h⟩; revert a b c d e g h; decide +kernel

theorem canFinish : ∀ f : Facts, f.valid → GuildTests.canFinish state steps 12 f := by
  intro ⟨a, b, c, d, e, g, h⟩; revert a b c d e g h; decide +kernel

end Release

namespace Issue
open Guild.Issue

def finished : Name → Bool | .closed => true | _ => false

theorem told : ∀ f : Facts, f.valid → GuildTests.told state finished f := by
  intro ⟨a, b, c, d, e, g, h, i, j, k, l, m, n⟩; revert a b c d e g h i j k l m n; decide +kernel

theorem movesOn : ∀ f : Facts, f.valid → GuildTests.movesOn Facts.valid state steps f := by
  intro ⟨a, b, c, d, e, g, h, i, j, k, l, m, n⟩; revert a b c d e g h i j k l m n; decide +kernel

theorem canFinish : ∀ f : Facts, f.valid → GuildTests.canFinish state steps 12 f := by
  intro ⟨a, b, c, d, e, g, h, i, j, k, l, m, n⟩; revert a b c d e g h i j k l m n; decide +kernel

end Issue

namespace Milestone
open Guild.Milestone

def finished : Name → Bool | .closed | .empty => true | _ => false

theorem told : ∀ f : Facts, f.valid → GuildTests.told state finished f := by
  intro ⟨a, b, c, d⟩; revert a b c d; decide +kernel

theorem movesOn : ∀ f : Facts, f.valid → GuildTests.movesOn Facts.valid state steps f := by
  intro ⟨a, b, c, d⟩; revert a b c d; decide +kernel

theorem canFinish : ∀ f : Facts, f.valid → GuildTests.canFinish state steps 12 f := by
  intro ⟨a, b, c, d⟩; revert a b c d; decide +kernel

end Milestone

namespace Kit
open Guild.Kit

def finished : Name → Bool | .finished | .notStarted => true | _ => false

theorem told : ∀ f : Facts, f.valid → GuildTests.told state finished f := by
  intro ⟨a, b, c, d⟩; revert a b c d; decide +kernel

theorem movesOn : ∀ f : Facts, f.valid → GuildTests.movesOn Facts.valid state steps f := by
  intro ⟨a, b, c, d⟩; revert a b c d; decide +kernel

theorem canFinish : ∀ f : Facts, f.valid → GuildTests.canFinish state steps 12 f := by
  intro ⟨a, b, c, d⟩; revert a b c d; decide +kernel

end Kit

end GuildTests
