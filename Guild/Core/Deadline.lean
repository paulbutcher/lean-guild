/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Guild.Core.Pull
import Guild.Core.Release

/-! What the facts become when the deadline of a state the forge or CI holds runs out. The
dispatcher evaluates such a unit again at that time. -/

namespace Guild.Pull

def expire (f : Facts) : Facts :=
  match (state f).name with
  | .ciRunning => { f with ciLate := true }
  | .settling => { f with conformance := .due }
  | .inReview => if f.conformance == .settling then { f with conformance := .due } else f
  | .checking => { f with checkLate := true }
  | .merging => { f with stuck := true }
  | _ => f

end Guild.Pull

namespace Guild.Release

def expire (f : Facts) : Facts :=
  match (state f).name with
  | .mainCiRunning => { f with mainCiLate := true }
  | _ => f

end Guild.Release
