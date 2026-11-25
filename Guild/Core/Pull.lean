/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Guild.Core.State

namespace Guild.Pull

/-- CI on the head: `unused` for a repository without CI. -/
inductive Ci
  | none | running | failure | success | unused
  deriving DecidableEq, Repr, Inhabited

/-- Whether Forgejo finds it merges cleanly: `unknown` while it is still checking. -/
inductive Mergeable
  | yes | no | unknown
  deriving DecidableEq, Repr, Inhabited

/-- A standing request for changes: at the head, replied to by the author since, or on an older
head. -/
inductive Changes
  | none | atHead | replied | older
  deriving DecidableEq, Repr, Inhabited

/-- Conformance's review of the head: given (or no reviewer), the head still settling, or due. -/
inductive Conformance
  | reviewed | settling | due
  deriving DecidableEq, Repr, Inhabited

structure Facts where
  isOpen : Bool := true
  /-- Never `upstream`. -/
  hold : Hold := .none
  wip : Bool := false
  ci : Ci := .success
  /-- CI none or running for longer than it should be. -/
  ciLate : Bool := false
  mergeable : Mergeable := .yes
  /-- Mergeability unknown for longer than Forgejo should take to work it out. -/
  checkLate : Bool := false
  changes : Changes := .none
  conformance : Conformance := .reviewed
  /-- Reviews requested at the head and not given, by kind of reviewer. -/
  pendingCoordinator : Bool := false
  pendingAgent : Bool := false
  pendingHuman : Bool := false
  /-- Someone approved the head. -/
  approved : Bool := true
  /-- A merge is scheduled. -/
  scheduled : Bool := false
  /-- Scheduled and ready for longer than a merge takes, without merging. -/
  stuck : Bool := false
  deriving DecidableEq, Repr, Inhabited

def Facts.valid (f : Facts) : Bool :=
  f.hold != .upstream &&
  (!f.ciLate || f.ci == .none || f.ci == .running) &&
  (!f.checkLate || f.mergeable == .unknown) &&
  (!f.stuck || f.scheduled)

inductive Name
  | closed | withHuman | upstream | waiting | invalid | blocked | blockedWithoutReason
  | inDraft | conflicting | ciFailing | noCi | ciStuck | changesRequested | authorReplied
  | ciRunning | inReview | settling | unapproved | checking | checkStuck | unscheduled | stuck
  | merging
  deriving DecidableEq, Repr, Inhabited

instance : HoldNames Name :=
  ⟨.withHuman, .upstream, .waiting, .invalid, .blocked, .blockedWithoutReason⟩

def Name.label : Name → String
  | .closed => "closed" | .withHuman => "with the human" | .upstream => "upstream"
  | .waiting => "waiting" | .invalid => "invalid" | .blocked => "blocked"
  | .blockedWithoutReason => "blocked without a reason" | .inDraft => "in draft"
  | .conflicting => "conflicting" | .ciFailing => "CI failing" | .noCi => "no CI"
  | .ciStuck => "CI stuck" | .changesRequested => "changes requested"
  | .authorReplied => "author replied" | .ciRunning => "CI running" | .inReview => "in review"
  | .settling => "settling" | .unapproved => "unapproved" | .checking => "checking"
  | .checkStuck => "check stuck" | .unscheduled => "unscheduled" | .stuck => "stuck"
  | .merging => "merging"

abbrev State := Guild.State Name

/-- Every reviewer owed at once: conformance once the head has settled, a reviewer that asked
for changes on an older head, and everyone whose review is requested. -/
def reviewers (f : Facts) : List Role :=
  (if f.conformance == .due then [.conformance] else []) ++
  (if f.changes == .older then [.changesBy] else []) ++
  (if f.pendingCoordinator then [.coordinator] else []) ++
  (if f.pendingAgent then [.pending] else []) ++
  (if f.pendingHuman then [.human] else [])

/-- What its author must fix comes first, since nothing else moves until they do; then the
reviewer the author answered; then CI and the reviews, all the reviewers at once; then a merge to
schedule, once nothing else stands in its way. -/
def state (f : Facts) : State :=
  if !f.isOpen then { name := .closed }
  else match (f.hold.state : Option State) with
  | some s => s
  | none =>
    if f.wip then
      { name := .inDraft, holders := [.author], quiet := true,
        step := "finish it and take WIP off its title, or close it" }
    else if f.mergeable == .no then
      { name := .conflicting, holders := [.author],
        step := "it conflicts with main: merge main into it and resolve them" }
    else if f.ci == .failure then
      { name := .ciFailing, holders := [.author], step := "fix CI on its head" }
    else if f.ci == .none && f.ciLate then
      { name := .noCi, holders := [.author],
        step := "CI has never run on its head: its branch probably lacks the CI workflow. Merge \
          main into it and push" }
    else if f.ci == .running && f.ciLate then
      { name := .ciStuck, holders := [.author],
        step := "CI has been running on its head for too long: find out why" }
    else if f.changes == .atHead then
      { name := .changesRequested, holders := [.author],
        step := "make the changes and push, or answer the reviewer" }
    else if f.changes == .replied then
      { name := .authorReplied, holders := [.changesBy],
        step := "its author answered your request for changes: answer them" }
    else if f.ci == .none || f.ci == .running then { name := .ciRunning, holders := [.timer] }
    else
      let owed := reviewers f
      if !owed.isEmpty then
        { name := .inReview, step := "review its head",
          holders := owed ++ (if f.conformance == .settling then [.timer] else []) }
      else if f.conformance == .settling then { name := .settling, holders := [.timer] }
      else if !f.approved then
        { name := .unapproved, holders := [.author],
          step := "nothing has approved its head and no review is pending: request one" }
      else if f.mergeable == .unknown then
        if f.checkLate then
          { name := .checkStuck, holders := [.author],
            step := "the forge hasn't worked out whether it conflicts with main: merge main into \
              it and push, which makes it check again" }
        else { name := .checking, holders := [.timer] }
      else if !f.scheduled then
        { name := .unscheduled, holders := [.author], quiet := true,
          step := "schedule its merge (`forge pr automerge`), or close it if it's no longer \
            wanted" }
      else if f.stuck then
        { name := .stuck, holders := [.author],
          step := "everything passed but its scheduled merge hasn't gone through: merge it now \
            (`forge pr merge`)" }
      else { name := .merging, holders := [.timer] }

end Guild.Pull
