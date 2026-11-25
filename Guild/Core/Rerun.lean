/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

/-! Re-runs of CI on one head commit, counted from the forge's attempt count rather than from an
agent's memory: a fresh run doesn't know what the last one tried. A new head starts again from
one attempt, since it is new code. -/

namespace Guild.Rerun

/-- Whether another run may be asked for, after `attempts` runs of the head's CI (the first
included), with at most `limit` re-runs. -/
def allowed (limit attempts : Nat) : Bool := attempts ≤ limit

/-- Whether the human is told: the head failed with every re-run spent. -/
def spent (limit attempts : Nat) : Bool := limit < attempts

end Guild.Rerun
