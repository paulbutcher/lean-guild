/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
module

@[expose] public section

namespace Guild

/-- Who holds a state: roles the dispatcher resolves for each unit to agents or the human, or a
holder outside the agents (the world, a timer, other units). -/
inductive Role
  /-- The repository's owner. -/
  | owner
  /-- Whoever filed the request: an agent, the human or an outsider. -/
  | requester
  /-- A pull request's author. -/
  | author
  | coordinator
  /-- The pull request reviewer. -/
  | conformance
  /-- Milestone reviewers that haven't reported. -/
  | reviewers
  /-- The agent a `Waiting-on:` line names. -/
  | waited
  /-- Whoever wrote an invalid `Blocked-by:` line. -/
  | writer
  /-- Whoever requested changes on a pull request. -/
  | changesBy
  /-- Agents whose review is requested and not given. -/
  | pending
  | human
  /-- Outside the kit: an upstream project. -/
  | world
  /-- The forge or CI, with a deadline the facts carry. -/
  | timer
  /-- The items a unit's `Blocked-by:` lines name. -/
  | blockers
  /-- The open pull requests that refer to an issue. -/
  | pr
  /-- An issue's repository's release. -/
  | release
  /-- The ready-for-release issues that hold a release. -/
  | held
  /-- A milestone's open issues. -/
  | issues
  /-- The milestones with open work. -/
  | milestones
  /-- The open pull requests on the coordination repository. -/
  | planning
  deriving DecidableEq, Repr, Inhabited

namespace Role

/-- The roles that name agents, which the dispatcher wakes. -/
def isAgent : Role → Bool
  | owner | requester | author | coordinator | conformance | reviewers | waited | writer
  | changesBy | pending => true
  | _ => false

/-- The roles that are other units, whose own holders owe what this unit waits on. -/
def isUnit : Role → Bool
  | blockers | pr | release | held | issues | milestones | planning => true
  | _ => false

/-- The name the ledger records. -/
def label : Role → String
  | owner => "owner" | requester => "requester" | author => "author"
  | coordinator => "coordinator" | conformance => "conformance" | reviewers => "reviewers"
  | waited => "waited" | writer => "writer" | changesBy => "changes-by" | pending => "pending"
  | human => "human" | world => "world" | timer => "timer"
  | blockers => "unit:blockers" | pr => "unit:pr" | release => "unit:release"
  | held => "unit:held" | issues => "unit:issues" | milestones => "unit:milestones"
  | planning => "unit:planning"

end Role

end Guild
