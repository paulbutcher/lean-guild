/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
module

public import Guild.Forge
public import Guild.Core.Version

/-! The gatekeeper's rules. It approves a pull request into `main` once the forge's record of the
CI runs for its head commit shows the CI workflow, and every run for that commit, succeeded. It
never reads commit statuses, which any account with write access can post under CI's name. At
level 3 it also releases, when the coordinator asks. -/

@[expose] public section

namespace Guild.Gatekeeper

open Guild.Forge Guild.Version

/-! ## Levels -/

/-- The files the forge reads code owners from, in the order it looks: it reads the first that
exists. -/
def codeownersPaths : List String :=
  [".forgejo/CODEOWNERS", ".gitea/CODEOWNERS", "docs/CODEOWNERS", "CODEOWNERS"]

/-- Code owners as (pattern, owners) rules. -/
def rules (text : String) : List (String × List String) :=
  (text.splitOn "\n").filterMap fun line =>
    match (line.split Char.isWhitespace).toList.map (·.toString) |>.filter (· ≠ "") with
    | p :: who => if p.startsWith "#" then none else some (p, who)
    | [] => none

/-- A repository's autonomy level from its code owners on `main`: 2 or 3 name the gatekeeper, and
3 also gives `API.lock` to the coordinator. -/
def level (codeowners : Option String) (me coordinator : String) : Nat :=
  let rs := rules (codeowners.getD "")
  let gated := rs.any fun (_, who) => who.contains s!"@{me}"
  let apiToCoordinator := rs.any fun (p, who) =>
    (p == "API\\.lock" || p == "API.lock") && who.contains s!"@{coordinator}"
  if gated then (if apiToCoordinator then 3 else 2) else 1

/-! ## CI -/

inductive Ci where
  | none | running | success | failure
  deriving Repr, BEq, DecidableEq

def Ci.name : Ci → String
  | .none => "none" | .running => "running" | .success => "success" | .failure => "failure"

/-- CI for a commit, from its runs: none unless the CI workflow ran. -/
def ci (workflow : String) (runs : List Run) : Ci :=
  if !runs.any (·.workflow == workflow) then .none
  else if runs.all (·.status == .success) then .success
  else if runs.any (fun r => [RunStatus.failure, .cancelled, .skipped, .blocked].contains r.status) then .failure
  else .running

/-- Whether `me` has a live approval of `sha`. -/
def approved (me sha : String) (reviews : List Review) : Bool :=
  reviews.any fun r => r.author == me && r.verdict == .approve && r.commit == sha && !r.dismissed && !r.stale

/-! ## Webhooks -/

/-- Where a webhook says to look: a pull request, or with `none` every open pull request in the
repository. A new head, or a pull request opened, which may already have one whose run passed; a
finished run; or a push to `main`, which may change the repository's level. Not labels, comments
or reviews, which change no run. -/
def targets (org : String) (h : Hook) : List (Repo × Option Nat) :=
  if h.owner.toLower != org.toLower then []
  else match h.event with
    | .runFinished pull => [(h.repo, pull)]
    | .pullOpened n | .pullPushed n => [(h.repo, some n)]
    | .push ref => if ref == "refs/heads/main" then [(h.repo, none)] else []
    | .other _ _ => []

/-! ## Releases -/

def digits? (s : String) : Option Nat :=
  if s.isEmpty || (s.length > 1 && s.startsWith "0") then none else s.toNat?

/-- `vX.Y.Z`, with no leading zeros. -/
def tagVersion (name : String) : Option Version :=
  if !name.startsWith "v" then none
  else match (name.drop 1).toString.splitOn "." with
    | [x, y, z] => do return ⟨← digits? x, ← digits? y, ← digits? z⟩
    | _ => none

def Version.tag (v : Version) : String := s!"v{v.major}.{v.minor}.{v.patch}"

def Version.lt (a b : Version) : Bool :=
  a.major < b.major || (a.major == b.major && (a.minor < b.minor || (a.minor == b.minor && a.patch < b.patch)))

/-- The highest release tag, with its version and commit. -/
def lastTag (tags : List Tag) : Option (Tag × Version) :=
  tags.foldl (fun best t => match tagVersion t.name, best with
    | some v, none => some (t, v)
    | some v, some (b, bv) => if Version.lt bv v then some (t, v) else some (b, bv)
    | none, _ => best) none

/-- Why the next version is what it is, in the words of `Version.next`'s rule. -/
def reason (prev : Option Version) (old new : String) : String :=
  match prev with
  | none => "the first release"
  | some p =>
    let o := apiLines old
    let n := apiLines new
    let removed := (o.filter (· ∉ n)).length
    let added := n.any (· ∉ o)
    let since := Version.tag p
    if p.major == 0 then
      if removed > 0 || added then s!"API.lock changed since {since}: before 1.0, that's a minor release"
      else s!"API.lock is unchanged since {since}: a patch release"
    else if removed > 0 then s!"API.lock lost or changed {removed} line(s) since {since}: a major release"
    else if added then s!"API.lock only gained lines since {since}: a minor release"
    else s!"API.lock is unchanged since {since}: a patch release"

/-- Whether a line heads a version's entry: `## vX.Y.Z` or `## [X.Y.Z]`, then the end or a space. -/
def heads (v : Version) (line : String) : Bool :=
  if !line.startsWith "##" then false
  else
    let rest := (line.drop 2).toString
    let body := rest.trimAsciiStart.toString
    let body := if body.startsWith "[" then (body.drop 1).toString else body
    let body := if body.startsWith "v" then (body.drop 1).toString else body
    let n := s!"{v.major}.{v.minor}.{v.patch}"
    rest.length > body.length && body.startsWith n &&
      (let after := (body.drop n.length).toString
       let after := if after.startsWith "]" then (after.drop 1).toString else after
       after.isEmpty || after.startsWith " " || after.startsWith "\t")

/-- A version's CHANGELOG.md entry, without its heading, or `none` if it has none. -/
def changelogEntry (text : String) (v : Version) : Option String :=
  let lines := text.splitOn "\n"
  match lines.dropWhile (!heads v ·) with
  | [] => none
  | _ :: rest =>
    some ("\n".intercalate (rest.takeWhile (!·.startsWith "## "))).trimAscii.toString

/-- The CHANGELOG.md headings, to say what it has when it lacks the entry. -/
def headings (text : String) : List String :=
  (text.splitOn "\n").filter (·.startsWith "## ")

/-- The text that starts every comment and review the kit writes that asks nothing. -/
def noReply : String := "(no reply needed)"

end Guild.Gatekeeper
