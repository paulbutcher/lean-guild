/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
module

public import Guild.Core.State

@[expose] public section

namespace Guild.Kit

inductive Milestones
  /-- No milestone has ever had work. -/
  | noneEver
  /-- A milestone has open work. -/
  | openWork
  | done
  deriving DecidableEq, Repr, Inhabited

/-- The kit as a unit: the project as a whole. -/
structure Facts where
  milestones : Milestones := .noneEver
  /-- ROADMAP.md on the coordination repository says `Status: finished`. -/
  finished : Bool := false
  /-- An open pull request on the coordination repository. -/
  planning : Bool := false
  /-- An open decision for the human that the coordinator filed there. -/
  decision : Bool := false
  deriving DecidableEq, Repr, Inhabited

def Facts.valid (_ : Facts) : Bool := true

inductive Name
  | inProgress | finished | notStarted | planning | withHuman | whatNext
  deriving DecidableEq, Repr, Inhabited

def Name.label : Name → String
  | .inProgress => "in progress" | .finished => "finished" | .notStarted => "not started"
  | .planning => "planning" | .withHuman => "with the human" | .whatNext => "what next"

abbrev State := Guild.State Name

def state (f : Facts) : State :=
  if f.milestones == .openWork then { name := .inProgress, holders := [.milestones] }
  else if f.finished then { name := .finished }
  else if f.milestones == .noneEver then { name := .notStarted }
  else if f.planning then { name := .planning, holders := [.planning] }
  else if f.decision then
    { name := .withHuman, holders := [.human], step := "decide what the next milestone needs" }
  else
    { name := .whatNext, holders := [.coordinator], quiet := true,
      step := "no milestone has open work: close out any left open, then draft the next one, put \
        to the human what it needs, or record in ROADMAP.md that the project is finished \
        (`Status: finished`)" }

end Guild.Kit
