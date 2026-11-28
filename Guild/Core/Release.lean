/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
module

public import Guild.Core.State

@[expose] public section

namespace Guild.Release

/-- CI on main's head. -/
inductive Ci
  | success | failure | running | none
  deriving DecidableEq, Repr, Inhabited

/-- CHANGELOG.md's newest heading on main: `none` when it is not above the last tag. -/
inductive Heading
  | none | wrong | right
  deriving DecidableEq, Repr, Inhabited

structure Facts where
  mainCi : Ci := .success
  /-- CI on main none or running for longer than it should be. -/
  mainCiLate : Bool := false
  /-- Commits on main since its last release tag, other than changelog lines alone, or no tag yet. -/
  unreleased : Bool := true
  /-- An open issue labelled ready-for-release that no release has completed since. -/
  rfr : Bool := false
  heading : Heading := .none
  /-- A ready-for-release issue is itself held. -/
  held : Bool := false
  /-- The coordinator releases it; below level 3 the human does. -/
  level3 : Bool := false
  /-- An open `Release <repo>` decision. -/
  decision : Bool := false
  deriving DecidableEq, Repr, Inhabited

/-- Whether commits, given as the paths each changed, add changelog lines and nothing else, leaving
the tag before them holding all the work. A commit with no paths counts as code, since the forge may
not have said what it changed. -/
def changelogOnly (since : List (List String)) : Bool :=
  since.all fun ps => !ps.isEmpty && ps.all (· == "CHANGELOG.md")

/-- Whether a tag holds an item's work: the item has merged pull requests, and no merge commit of
them is on main after the tag. A merge commit the forge didn't name might be. -/
def holds (since : List String) (merges : List (Option String)) : Bool :=
  !merges.isEmpty && merges.all fun m => m.any (!since.contains ·)

def Facts.valid (f : Facts) : Bool :=
  !f.mainCiLate || f.mainCi == .running || f.mainCi == .none

inductive Name
  | mainFailing | upToDate | held | mainCiStuck | mainCiRunning | noEntry | wrongEntry
  | releasable | withHuman
  deriving DecidableEq, Repr, Inhabited

def Name.label : Name → String
  | .mainFailing => "main failing" | .upToDate => "up to date" | .held => "held"
  | .mainCiStuck => "main CI stuck" | .mainCiRunning => "main CI running"
  | .noEntry => "no entry" | .wrongEntry => "wrong entry" | .releasable => "releasable"
  | .withHuman => "with the human"

abbrev State := Guild.State Name

def state (f : Facts) : State :=
  if f.mainCi == .failure then
    { name := .mainFailing, holders := [.owner],
      step := "CI failed on main: fix it before anything else" }
  else if !f.unreleased || (!f.rfr && f.heading == .none) then { name := .upToDate }
  else if f.held then { name := .held, holders := [.held] }
  else if f.mainCi == .running || f.mainCi == .none then
    if f.mainCiLate then
      { name := .mainCiStuck, holders := [.owner],
        step := "CI on main hasn't finished: find out why" }
    else { name := .mainCiRunning, holders := [.timer] }
  else if f.heading == .none then
    { name := .noEntry, holders := [.owner],
      step := "work is ready for release, but CHANGELOG.md on main has no entry above the last \
        release: add the one `forge version` gives" }
  else if f.heading == .wrong then
    { name := .wrongEntry, holders := [.owner],
      step := "CHANGELOG.md's newest heading on main isn't the version the release will have: \
        make it the one `forge version` gives" }
  else if f.level3 then
    { name := .releasable, holders := [.coordinator],
      step := "release it with `forge release`, naming every ready-for-release issue it \
        completes" }
  else if f.decision then { name := .withHuman, holders := [.human], step := "release it" }
  else
    { name := .releasable, holders := [.coordinator],
      step := "it is below level 3: put the release to the human as a `Release <repo>` \
        decision" }

end Guild.Release
