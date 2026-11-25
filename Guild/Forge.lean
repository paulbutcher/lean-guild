/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
module

/-! Everything the kit does through a forge, as one account sees it: one `Forge` value per
account, since each service and agent acts with its own token. Each forge has an adapter, and the
tests a fake; the contract tests hold both to the same observations.

Times are the forge's own ISO 8601 strings in UTC, which order as text. -/

@[expose] public section

namespace Guild.Forge

inductive Error where
  /-- The forge answered, with a status the operation doesn't expect. -/
  | status (code : Nat) (message : String)
  /-- The request never got an answer. -/
  | transport (message : String)
  /-- The forge answered with something the adapter can't read. -/
  | decode (message : String)
  deriving Repr, BEq

def Error.toString : Error → String
  | .status code m => s!"the forge answered {code}: {m}"
  | .transport m => s!"the forge couldn't be reached: {m}"
  | .decode m => s!"the forge's answer couldn't be read: {m}"

instance : ToString Error := ⟨Error.toString⟩

abbrev M := ExceptT Error IO

/-- A repository, by its name in the project's organisation. -/
abbrev Repo := String

inductive Which where
  | «open» | closed | all
  deriving Repr, BEq, DecidableEq

inductive Kinds where
  | issues | pulls | all
  deriving Repr, BEq, DecidableEq

/-- Which issues to list. Every filter is applied exactly, by the adapter if the forge won't. -/
structure IssueQuery where
  which : Which := .open
  kinds : Kinds := .all
  /-- Items carrying all of these labels. -/
  labels : List String := []
  /-- Items updated at or after this time. -/
  since : Option String := none
  deriving Repr

/-- An issue, or a pull request seen as an issue. -/
structure Issue where
  number : Nat
  isPull : Bool
  isOpen : Bool
  title : String
  body : String
  author : String
  labels : List String
  assignees : List String
  createdAt : String
  updatedAt : String
  closedAt : Option String
  milestone : Option String
  deriving Repr, BEq

structure Pull where
  number : Nat
  isOpen : Bool
  merged : Bool
  title : String
  body : String
  author : String
  headSha : String
  headRef : String
  baseRef : String
  /-- `none` while the forge is still working it out. -/
  mergeable : Option Bool
  /-- Requested reviewers as the forge lists them. Forgejo also lists everyone who has approved,
  requested or not: the timeline's `reviewRequest` entries say who was asked. -/
  requestedReviewers : List String
  updatedAt : String
  deriving Repr, BEq

inductive Verdict where
  | approve | requestChanges | comment
  /-- A state the kit doesn't act on, such as a pending review. -/
  | other (name : String)
  deriving Repr, BEq, DecidableEq

structure Review where
  id : Nat
  author : String
  verdict : Verdict
  /-- The head commit it was given on. -/
  commit : String
  dismissed : Bool
  stale : Bool
  submittedAt : String
  body : String
  deriving Repr, BEq

structure Comment where
  id : Nat
  author : String
  body : String
  createdAt : String
  deriving Repr, BEq

/-- What happened to an issue or pull request, from its timeline. -/
inductive Event where
  | comment (id : Nat) (body : String)
  | label (name : String) (added : Bool)
  | closed
  | reopened
  | review
  | push
  | scheduleMerge
  | cancelScheduledMerge
  | reviewRequest (reviewer : String) (removed : Bool)
  | merged
  /-- Kept by its forge name, for anything the kit doesn't read. -/
  | other (kind : String)
  deriving Repr, BEq

structure Entry where
  time : String
  actor : String
  event : Event
  deriving Repr, BEq

inductive StatusState where
  | pending | success | failure | error | warning
  | other (name : String)
  deriving Repr, BEq, DecidableEq

/-- A commit status, as CI reports it. -/
structure Status where
  context : String
  state : StatusState
  updatedAt : String
  deriving Repr, BEq

inductive RunStatus where
  | waiting | running | success | failure | cancelled | skipped | blocked
  | other (name : String)
  deriving Repr, BEq, DecidableEq

def RunStatus.finished : RunStatus → Bool
  | .success | .failure | .cancelled | .skipped | .blocked => true
  | _ => false

/-- A CI run. Re-running it keeps the run, and raises its jobs' attempts. -/
structure Run where
  id : Nat
  workflow : String
  status : RunStatus
  sha : String
  event : String
  created : String
  deriving Repr, BEq

structure Job where
  id : Nat
  name : String
  status : RunStatus
  /-- 1 for the first attempt, one more for each re-run. -/
  attempt : Nat
  deriving Repr, BEq

structure Release where
  tag : String
  draft : Bool
  publishedAt : Option String
  deriving Repr, BEq

structure Tag where
  name : String
  sha : String
  deriving Repr, BEq

structure Milestone where
  title : String
  isOpen : Bool
  openIssues : Nat
  closedIssues : Nat
  deriving Repr, BEq

structure Branch where
  sha : String
  timestamp : String
  deriving Repr, BEq

structure RepoInfo where
  name : String
  archived : Bool
  deriving Repr, BEq

inductive MergeResult where
  | merged
  /-- Scheduled to merge once checks succeed. Forgejo acts on a schedule only when a review or a
  status arrives after it, so one made when everything has already passed never fires. -/
  | scheduled
  /-- The forge is still checking that it merges cleanly. -/
  | tryLater
  | refused (message : String)
  deriving Repr, BEq

structure NewIssue where
  title : String
  body : String := ""
  /-- Dropped by the forge unless the account may write to the repository's issues. -/
  labels : List String := []
  assignees : List String := []

structure NewPull where
  head : String
  base : String := "main"
  title : String
  body : String := ""

structure NewRelease where
  tag : String
  target : String
  name : String
  body : String

/-- A commit of whole files to a branch, made through the API. -/
structure NewCommit where
  branch : String
  /-- Where a new branch starts; `none` to commit to an existing one. -/
  start : Option String := none
  message : String
  files : List (String × String)

structure Forge where
  account : String
  repos : M (List RepoInfo)
  repoExists : Repo → M Bool
  branch : Repo → String → M (Option Branch)
  /-- A file's text at a ref (branch, tag or commit), or `none` if it isn't there. -/
  file : Repo → (path ref : String) → M (Option String)
  issue : Repo → Nat → M (Option Issue)
  issues : Repo → IssueQuery → M (List Issue)
  labels : Repo → M (List String)
  comments : Repo → Nat → M (List Comment)
  timeline : Repo → Nat → M (List Entry)
  pull : Repo → Nat → M (Option Pull)
  pulls : Repo → Which → M (List Pull)
  /-- The messages of a pull request's commits. -/
  pullCommits : Repo → Nat → M (List String)
  pullFiles : Repo → Nat → M (List String)
  reviews : Repo → Nat → M (List Review)
  statuses : Repo → (sha : String) → M (List Status)
  /-- Runs for a commit, newest first. -/
  runs : Repo → (sha : String) → M (List Run)
  /-- Runs not yet finished, newest first. -/
  activeRuns : Repo → M (List Run)
  jobs : Repo → (run : Nat) → M (List Job)
  jobLog : Repo → (job : Nat) → M String
  releases : Repo → M (List Release)
  tags : Repo → M (List Tag)
  milestones : Repo → M (List Milestone)
  createIssue : Repo → NewIssue → M Nat
  setAssignees : Repo → Nat → List String → M Unit
  close : Repo → Nat → M Unit
  /-- Adds a label the repository has, by name. -/
  addLabel : Repo → Nat → String → M Unit
  removeLabel : Repo → Nat → String → M Unit
  comment : Repo → Nat → String → M Unit
  createPull : Repo → NewPull → M Nat
  requestReviewers : Repo → Nat → List String → M Unit
  review : Repo → Nat → Verdict → (body commit : String) → M Unit
  /-- A squash merge that deletes its branch, or with `schedule`, one when checks succeed. -/
  merge : Repo → Nat → (schedule : Bool) → M MergeResult
  cancelMerge : Repo → Nat → M Unit
  rerun : Repo → (run : Nat) → M Unit
  createRelease : Repo → NewRelease → M Unit
  /-- The new commit's sha. -/
  commit : Repo → NewCommit → M String

namespace Forge

/-- CI re-runs of a commit, counted from the forge: each run's attempts beyond its first. -/
def reruns (f : Forge) (repo : Repo) (sha : String) : M Nat := do
  let mut n := 0
  for r in ← f.runs repo sha do
    let top := (← f.jobs repo r.id).foldl (fun m j => max m j.attempt) 1
    n := n + (top - 1)
  return n

end Forge

end Guild.Forge
