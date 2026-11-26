/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
module

public import Guild.Core.State

@[expose] public section

namespace Guild.Issue

/-- `request`: filed by someone other than the owner, labelled `request`. `task`: any other issue
the owner should finish. `milestone`: a milestone issue. `recommendation`, `kitDecision` (the
dispatcher's own) and `releaseDecision` (the coordinator's `Release <repo>`) are the human's to
close. -/
inductive Kind
  | request | task | milestone | recommendation | kitDecision | releaseDecision
  deriving DecidableEq, Repr, Inhabited

structure Facts where
  isOpen : Bool := true
  kind : Kind := .task
  /-- A request labelled `new` or with no triage label; a task that is someone else's, which the
  owner has never touched. -/
  untriaged : Bool := false
  /-- `counter-proposal`. -/
  counter : Bool := false
  hold : Hold := .none
  /-- An open pull request refers to it. -/
  openPr : Bool := false
  /-- Work for it merged since it was last unblocked, accepted or released. -/
  merged : Bool := false
  /-- `ready-for-release`, on a repository that releases, and no release since it was added. -/
  rfr : Bool := false
  /-- A `Released in vX.Y.Z` comment, or, for an issue labelled ready-for-release, a release tag
  at main's head, which must hold its work. -/
  released : Bool := false
  verified : Bool := false
  /-- `not-verified` added since its latest release. -/
  notVerified : Bool := false
  /-- A release-decision with a release published since it last acted. -/
  overtaken : Bool := false
  /-- A milestone issue with a review requested and not reported since. -/
  unreported : Bool := false
  deriving DecidableEq, Repr, Inhabited

/-- Facts that only one kind reads are left at their default for the others, and `not-verified`
only follows a release. -/
def Facts.valid (f : Facts) : Bool :=
  (f.kind == .request || !(f.counter || f.verified || f.notVerified)) &&
  (f.kind == .releaseDecision || !f.overtaken) &&
  (f.kind == .milestone || !f.unreported) &&
  (f.released || !f.notVerified)

inductive Name
  | inReview | closedUnreleased | closed | overtaken | withHuman
  | upstream | waiting | invalid | blocked | blockedWithoutReason
  | reviewed | untriaged | counterProposed | verified | inProgress | ready | released | merged
  | toDo
  deriving DecidableEq, Repr, Inhabited

instance : HoldNames Name :=
  ⟨.withHuman, .upstream, .waiting, .invalid, .blocked, .blockedWithoutReason⟩

def Name.label : Name → String
  | .inReview => "in review" | .closedUnreleased => "closed unreleased" | .closed => "closed"
  | .overtaken => "overtaken" | .withHuman => "with the human" | .upstream => "upstream"
  | .waiting => "waiting" | .invalid => "invalid" | .blocked => "blocked"
  | .blockedWithoutReason => "blocked without a reason" | .reviewed => "reviewed"
  | .untriaged => "untriaged" | .counterProposed => "counter-proposed" | .verified => "verified"
  | .inProgress => "in progress" | .ready => "ready" | .released => "released"
  | .merged => "merged" | .toDo => "to do"

abbrev State := Guild.State Name

def state (f : Facts) : State :=
  -- Reviews run whether it's open or closed: the coordinator may accept a milestone before they
  -- report.
  if f.kind == .milestone && f.unreported then
    { name := .inReview, holders := [.reviewers],
      step := "review the milestone and report on its issue" }
  else if !f.isOpen then
    if f.rfr && !f.released && (f.kind == .request || f.kind == .task) then
      { name := .closedUnreleased, holders := [.coordinator],
        -- Reopening an upstream issue hands it back to the world, which may close it again.
        step := if f.hold == .upstream then
            "it was closed while labelled ready-for-release and never released, and it is \
              upstream, so reopening it would only hand it back: take the label off and say on \
              it where its work is released"
          else "it was closed while labelled ready-for-release and never released: reopen it and \
            release it, or, if its work truly isn't wanted, take the label off and say why on it" }
    else { name := .closed }
  else if f.kind == .releaseDecision then
    if f.overtaken then
      { name := .overtaken, holders := [.coordinator],
        step := "a release overtook it: close it if that release covers it, or update it for \
          what's left" }
    else { name := .withHuman, holders := [.human], step := "release it" }
  else if f.kind == .recommendation || f.kind == .kitDecision then
    { name := .withHuman, holders := [.human], step := "decide, and close it" }
  else match (f.hold.state : Option State) with
  | some s => s
  | none =>
    let request := f.kind == .request
    if f.kind == .milestone then
      { name := .reviewed, holders := [.coordinator],
        step := "accept the milestone (say what you checked, close the issue and its milestones, \
          record it in ROADMAP.md), or say on it what it waits for" }
    else if f.untriaged then
      { name := .untriaged, holders := [.owner],
        step := if request then "accept it, counter-propose, or close it saying why"
          else "if it's a request, add `request` and `new` and handle it as one; otherwise take it \
            on, answer it or close it" }
    else if request && f.counter then
      { name := .counterProposed, holders := [.requester],
        step := "answer the counter-proposal: take `counter-proposal` off if you accept it, or put \
          it to the human" }
    else if request && f.verified then
      { name := .verified, holders := [.requester], step := "close it" }
    else if f.openPr then { name := .inProgress, holders := [.pr] }
    else if f.rfr then { name := .ready, holders := [.release] }
    else if f.released && !f.notVerified then
      if request then
        { name := .released, holders := [.requester],
          step := "verify it against the release (verified, and close it), or add `not-verified` \
            saying what falls short, or a Blocked-by: line naming what you must do first" }
      else { name := .released, holders := [.owner], step := "its release is out: close it" }
    else if f.merged then
      { name := .merged, holders := [.owner],
        step := "label it ready-for-release, with its CHANGELOG.md entry" }
    else
      { name := .toDo, holders := [.owner], quiet := true,
        step := "work on it: a pull request with a Refs line, or say what it waits for (a \
          Blocked-by: line, Waiting-on:, or needs-human with a decision)" }

end Guild.Issue
