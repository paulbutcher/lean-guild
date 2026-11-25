/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Guild.Core.Role

namespace Guild

/-- A unit's state: its name, who holds it, and what they do next. No holders means it is
finished: nothing is owed until its facts change. A quiet state wakes its agent holders only
when they have nothing else. -/
structure State (N : Type) where
  name : N
  holders : List Role := []
  step : String := ""
  quiet : Bool := false
  deriving Repr

namespace State

def terminal {N} (s : State N) : Bool := s.holders.isEmpty

/-- What check and wake compare: a step that leaves both as they were has moved nothing. -/
def key {N} (s : State N) : N × List Role := (s.name, s.holders)

end State

/-- What holds an issue or pull request, whatever its kind, the first that applies:
`needs-human` the human hasn't answered, or assigned to them by hand; an upstream issue; an
unanswered `Waiting-on:`; a `Blocked-by:` line that is invalid (naming the item itself, or
closing a loop of waits); a `Blocked-by:` line naming an open, unreleased item; the `blocked`
label with no such line. -/
inductive Hold
  | none | human | upstream | waiting | invalid | blocked | bareLabel
  deriving DecidableEq, Repr, Inhabited

/-- The names of the states a hold gives, which issues and pull requests share. -/
class HoldNames (N : Type) where
  withHuman : N
  upstream : N
  waiting : N
  invalid : N
  blocked : N
  blockedWithoutReason : N

/-- The state a hold gives, if anything holds the item. -/
def Hold.state {N} [HoldNames N] : Hold → Option (State N)
  | .none => Option.none
  | .human => some { name := HoldNames.withHuman, holders := [.human], step := "decide" }
  | .upstream => some { name := HoldNames.upstream, holders := [.world] }
  | .waiting => some { name := HoldNames.waiting, holders := [.waited],
                       step := "answer, or do what it waits for" }
  | .invalid => some { name := HoldNames.invalid, holders := [.writer],
                       step := "a Blocked-by: line names this item itself, or closes a loop of                          waits: fix it" }
  | .blocked => some { name := HoldNames.blocked, holders := [.blockers] }
  | .bareLabel => some { name := HoldNames.blockedWithoutReason, holders := [.owner],
                         step := "it is labelled blocked, but no Blocked-by: line names what it                            waits for: add one, or take the label off" }

end Guild
