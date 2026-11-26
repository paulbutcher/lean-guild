/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Guild

/-! What each state's holders, and the world, may do next, as changes to the facts: the model
the checks explore, ported from the reference's `test_states.py`. -/

namespace GuildTests

open Guild

namespace Issue
open Guild.Issue

/-- What frees an issue from what holds it. -/
def holdSteps (f : Facts) : Name → List Facts
  | .upstream => [{ f with isOpen := false }, { f with hold := .none }]
  | .invalid | .blockedWithoutReason => [{ f with hold := .none }, { f with hold := .blocked }]
  | _ => [{ f with hold := .none }]

def steps (f : Facts) : List Facts :=
  match (state f).name with
  | .inReview => [{ f with unreported := false }]
  | .closedUnreleased =>
    if f.hold == .upstream then [{ f with rfr := false }]
    else [{ f with isOpen := true }, { f with rfr := false }]
  | .overtaken => [{ f with isOpen := false }, { f with overtaken := false, kind := .task }]
  | .withHuman =>
    if f.kind == .releaseDecision then [{ f with overtaken := true }, { f with isOpen := false }]
    else if f.kind == .recommendation || f.kind == .kitDecision then [{ f with isOpen := false }]
    else holdSteps f .withHuman
  | n@.upstream | n@.waiting | n@.invalid | n@.blocked | n@.blockedWithoutReason => holdSteps f n
  | .reviewed =>
    [{ f with isOpen := false }, { f with hold := .blocked }, { f with hold := .human },
     { f with hold := .waiting }]
  | .untriaged =>
    [{ f with untriaged := false }, { f with isOpen := false }] ++
      (if f.kind == .request then [{ f with untriaged := false, counter := true }] else [])
  | .counterProposed =>
    [{ f with counter := false, untriaged := true }, { f with hold := .human },
     { f with isOpen := false }]
  | .verified => [{ f with isOpen := false }]
  | .inProgress => [{ f with openPr := false, merged := true }, { f with openPr := false }]
  | .ready => [{ f with rfr := false, released := true, merged := false, notVerified := false }]
  | .released =>
    if f.kind == .request then
      [{ f with verified := true }, { f with notVerified := true }, { f with hold := .blocked }]
    else [{ f with isOpen := false }]
  | .merged => [{ f with rfr := true }]
  | .toDo =>
    [{ f with isOpen := false }, { f with openPr := true }, { f with hold := .blocked },
     { f with hold := .waiting }, { f with hold := .human }]
  | .closed => []

end Issue

namespace Pull
open Guild.Pull

def holdSteps (f : Facts) : Name → List Facts
  | .invalid | .blockedWithoutReason => [{ f with hold := .none }, { f with hold := .blocked }]
  | _ => [{ f with hold := .none }]

/-- A push: a new head, which CI and conformance look at afresh, and which a standing request
for changes was made on an older head of. -/
def pushed (f : Facts) : Facts :=
  { f with ci := if f.ci == .unused then .unused else .running, ciLate := false,
           conformance := .settling, approved := false, stuck := false, mergeable := .yes,
           checkLate := false, changes := if f.changes == .none then .none else .older }

def steps (f : Facts) : List Facts :=
  match (state f).name with
  | n@.withHuman | n@.upstream | n@.waiting | n@.invalid | n@.blocked
  | n@.blockedWithoutReason => holdSteps f n
  | .inDraft => [{ f with isOpen := false }, { f with wip := false }]
  | .ciFailing | .noCi | .ciStuck | .conflicting | .checkStuck =>
    [{ f with isOpen := false }, pushed f]
  | .ciRunning =>
    [{ f with ci := .success, ciLate := false }, { f with ci := .failure, ciLate := false },
     { f with ciLate := true }]
  | .changesRequested => [pushed f, { f with changes := .replied }]
  | .authorReplied => [{ f with changes := .none }, { f with changes := .atHead }]
  | .settling => [{ f with conformance := .due }]
  | .inReview =>
    -- Any one of its reviewers approves or asks for changes; a settling head settles.
    (if f.conformance == .due then
      [{ f with conformance := .reviewed, approved := true },
       { f with conformance := .reviewed, changes := .atHead }] else []) ++
    (if f.conformance == .settling then [{ f with conformance := .due }] else []) ++
    (if f.changes == .older then
      [{ f with changes := .none, approved := true }, { f with changes := .atHead }] else []) ++
    (if f.pendingCoordinator then
      [{ f with pendingCoordinator := false, approved := true }, { f with changes := .atHead }]
      else []) ++
    (if f.pendingAgent then
      [{ f with pendingAgent := false, approved := true }, { f with changes := .atHead }]
      else []) ++
    (if f.pendingHuman then
      [{ f with pendingHuman := false, approved := true }, { f with changes := .atHead }]
      else [])
  | .unapproved => [{ f with pendingAgent := true }]
  | .checking =>
    [{ f with mergeable := .yes }, { f with mergeable := .no }, { f with checkLate := true }]
  | .unscheduled => [{ f with isOpen := false }, { f with scheduled := true }]
  | .stuck => [{ f with isOpen := false }]
  | .merging => [{ f with isOpen := false }, { f with stuck := true }]
  | .closed => []

end Pull

namespace Release
open Guild.Release

def steps (f : Facts) : List Facts :=
  let released := { f with unreleased := false, rfr := false, heading := .none, mainCi := .success, mainCiLate := false }
  match (state f).name with
  | .mainFailing | .mainCiStuck => [{ f with mainCi := .running, mainCiLate := false }]
  | .held => [{ f with held := false }]
  | .mainCiRunning =>
    [{ f with mainCi := .success, mainCiLate := false },
     { f with mainCi := .failure, mainCiLate := false }, { f with mainCiLate := true }]
  | .noEntry | .wrongEntry => [{ f with heading := .right, mainCi := .running, mainCiLate := false }]
  | .releasable => if f.level3 then [released] else [{ f with decision := true }]
  | .withHuman => [released]
  | .upToDate => []

end Release

namespace Milestone
open Guild.Milestone

def steps (f : Facts) : List Facts :=
  match (state f).name with
  | .inProgress =>
    [{ f with openWork := false, hadWork := true,
              issue := if f.issue == .isOpen then .closed else f.issue }]
  | .finished => [{ f with closed := true }, { f with issue := .isOpen, openWork := true }]
  | .accepted => [{ f with closed := true }]
  | .closed | .empty => []

end Milestone

namespace Kit
open Guild.Kit

def steps (f : Facts) : List Facts :=
  match (state f).name with
  | .inProgress => [{ f with milestones := .done }]
  | .planning => [{ f with planning := false }, { f with planning := false, finished := true }]
  | .withHuman => [{ f with decision := false }]
  | .whatNext =>
    [{ f with milestones := .openWork }, { f with decision := true }, { f with planning := true }]
  | .finished | .notStarted => []

end Kit

end GuildTests
