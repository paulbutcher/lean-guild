/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import GuildTests.Checks

namespace GuildTests

namespace Pull
open Guild.Pull

def finished : Name → Bool | .closed => true | _ => false

/-- An open pull request with nothing holding it: the part of the space whose state depends on
every other fact, so the part the kernel enumerates. -/
def core (wip : Bool) (ci : Ci) (ciLate : Bool) (mergeable : Mergeable) (checkLate : Bool)
    (changes : Changes) (conformance : Conformance) (pc pa ph approved scheduled stuck : Bool) :
    Facts :=
  ⟨true, .none, wip, ci, ciLate, mergeable, checkLate, changes, conformance, pc, pa, ph, approved,
   scheduled, stuck⟩

def isHoldName : Name → Bool
  | .withHuman | .upstream | .waiting | .invalid | .blocked | .blockedWithoutReason => true
  | _ => false

theorem told_core : ∀ a b c d e g h i j k l m n,
    (core a b c d e g h i j k l m n).valid → GuildTests.told state finished (core a b c d e g h i j k l m n) := by
  decide +kernel

theorem movesOn_core : ∀ a b c d e g h i j k l m n,
    (core a b c d e g h i j k l m n).valid →
      GuildTests.movesOn Facts.valid state steps (core a b c d e g h i j k l m n) := by
  decide +kernel

theorem canFinish_core : ∀ a b c d e g h i j k l m n,
    (core a b c d e g h i j k l m n).valid →
      GuildTests.canFinish state steps 14 (core a b c d e g h i j k l m n) := by
  decide +kernel

theorem core_not_held : ∀ a b c d e g h i j k l m n,
    !isHoldName (state (core a b c d e g h i j k l m n)).name ∧
      (state (core a b c d e g h i j k l m n)).name ≠ .closed := by
  decide +kernel

end Pull

end GuildTests
