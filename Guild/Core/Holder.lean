/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Guild.Core.Role

namespace Guild

/-- Who a role names on a unit: an agent, the human, or a holder that stands for itself (the
world, a timer, other units). -/
inductive Holder
  | agent (name : String)
  | human
  | other (role : Role)
  deriving DecidableEq, Repr

/-- The holders a role names, given who each agent role is on the unit. A role that names no one
falls to the owner, then to the human, so every role names someone. -/
def resolve (who : Role → List Holder) (r : Role) : List Holder :=
  if r.isAgent then
    match who r with
    | [] => match who .owner with
      | [] => [.human]
      | os => os
    | hs => hs
  else if r == .human then [.human]
  else [.other r]

end Guild
