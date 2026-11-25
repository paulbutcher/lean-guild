/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Guild.Core.State

namespace Guild.Milestone

/-- The milestone's issue on the coordination repository. -/
inductive Issue
  | none | isOpen | closed
  deriving DecidableEq, Repr, Inhabited

/-- A milestone and its namesakes on every repository. -/
structure Facts where
  /-- Closed on every repository. -/
  closed : Bool := false
  /-- An open issue on any of them, its milestone issue included. -/
  openWork : Bool := false
  /-- A closed issue on any of them. -/
  hadWork : Bool := false
  issue : Issue := .none
  deriving DecidableEq, Repr, Inhabited

/-- An open milestone issue is open work of its own. -/
def Facts.valid (f : Facts) : Bool := f.issue != .isOpen || f.openWork

inductive Name
  | closed | inProgress | empty | finished | accepted
  deriving DecidableEq, Repr, Inhabited

def Name.label : Name → String
  | .closed => "closed" | .inProgress => "in progress" | .empty => "empty"
  | .finished => "finished" | .accepted => "accepted"

abbrev State := Guild.State Name

def state (f : Facts) : State :=
  if f.closed then { name := .closed }
  else if f.openWork then { name := .inProgress, holders := [.issues] }
  else if !f.hadWork then { name := .empty }
  else match f.issue with
  | .none =>
    { name := .finished, holders := [.coordinator],
      step := "its last open issue closed on every repository it spans: open its milestone issue \
        and add milestone-review" }
  | .closed =>
    { name := .accepted, holders := [.coordinator],
      step := "it is accepted: close it on every repository it spans" }
  | .isOpen => { name := .inProgress, holders := [.issues] }

end Guild.Milestone
