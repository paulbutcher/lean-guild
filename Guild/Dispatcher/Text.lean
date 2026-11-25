/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
module

public import Guild.Core.Version

/-! What the rules read from the text of issues, comments and files: the lines agents and the human
write for the kit, and the headings it checks. -/

@[expose] public section

namespace Guild.Dispatcher.Text

open Guild.Version

/-- A character of an account or repository name. -/
def nameChar (c : Char) : Bool := c.isAlphanum || c == '_' || c == '.' || c == '-'

def wordChar (c : Char) : Bool := c.isAlphanum || c == '_'

def space (c : Char) : Bool := c == ' ' || c == '\t'

def lower (s : String) : String := s.toLower

/-- Whether `cs` starts with `p`, ignoring ASCII case. -/
def startsCI (cs : List Char) (p : String) : Bool :=
  (cs.take p.length).map Char.toLower == p.toList.map Char.toLower

def lines (s : String) : List String := s.splitOn "\n"

/-- The text that starts every comment the kit writes that asks nothing. -/
def noReply : String := "(no reply needed)"

def firstLine (text : String) : String :=
  ((lines text.trimAscii.toString).head?.getD "").trimAscii.toString

def wantsReply (body : String) : Bool := !(firstLine body).startsWith noReply

def wip (title : String) : Bool :=
  let t := lower title.trimAscii.toString
  t.startsWith "wip" || t.startsWith "[wip]" || t.startsWith "draft"

/-- A name at the start of `cs`, and what follows it. -/
def name (cs : List Char) : String × List Char :=
  (String.ofList (cs.takeWhile nameChar), cs.dropWhile nameChar)

def number (cs : List Char) : Option (Nat × List Char) :=
  let ds := cs.takeWhile Char.isDigit
  if ds.isEmpty then none else (String.ofList ds).toNat?.map (·, cs.dropWhile Char.isDigit)

/-- Every `Blocked-by: <org>/<repo>#<n>`, anywhere in the text. -/
def blockedBy (text : String) : List (String × String × Nat) :=
  go text.toList (text.length + 1)
where
  go (cs : List Char) : Nat → List (String × String × Nat)
    | 0 => []
    | fuel + 1 =>
      match cs with
      | [] => []
      | c :: rest =>
        if (c :: rest).take 11 == "Blocked-by:".toList then
          let after := ((c :: rest).drop 11).dropWhile space
          let (org, r1) := name after
          let found := match r1 with
            | '/' :: r2 =>
              let (repo, r3) := name r2
              match r3 with
              | '#' :: r4 => (number r4).bind fun (n, _) =>
                if org.isEmpty || repo.isEmpty then none else some (org, repo, n)
              | _ => none
            | _ => none
          found.toList ++ go rest fuel
        else go rest fuel

/-- The names of `Waiting-on: <name>` lines, in order: a leading `@` is allowed, and case is
ignored in the keyword. -/
def waitingOn (text : String) : List String :=
  (lines text).filterMap fun l =>
    let cs := l.toList.dropWhile space
    if startsCI cs "waiting-on:" then
      let after := (cs.drop 11).dropWhile space
      let after := if after.head? == some '@' then after.drop 1 else after
      let (n, _) := name after
      if n.isEmpty then none else some n
    else none

/-- A reference to an issue: `#n`, or `<org>/<repo>#n`. -/
structure Ref where
  org : Option String
  repo : Option String
  n : Nat
  deriving BEq, Repr

/-- Every reference in a text, each `#` followed by digits, with the `<org>/<repo>` right before
it if there is one. -/
def refsIn (text : String) : List Ref :=
  go [] text.toList (text.length + 1)
where
  go (before : List Char) (cs : List Char) : Nat → List Ref
    | 0 => []
    | fuel + 1 =>
      match cs with
      | [] => []
      | c :: rest =>
        if c == '#' then
          match number rest with
          | some (n, _) =>
            let repo := String.ofList (before.takeWhile nameChar).reverse
            let back := before.dropWhile nameChar
            let org := if !repo.isEmpty && back.head? == some '/' then
                String.ofList ((back.drop 1).takeWhile nameChar).reverse else ""
            let r : Ref := if org.isEmpty then ⟨none, none, n⟩ else ⟨some org, some repo, n⟩
            r :: go (c :: before) rest fuel
          | none => go (c :: before) rest fuel
        else go (c :: before) rest fuel

/-- One reference at the start of `cs`, and what follows it. -/
def oneRef (cs : List Char) : Option (List Char) :=
  match cs with
  | '#' :: r => (number r).map (·.2)
  | _ =>
    let (a, r1) := name cs
    match r1 with
    | '/' :: r2 =>
      let (b, r3) := name r2
      match r3 with
      | '#' :: r4 => if a.isEmpty || b.isEmpty then none else (number r4).map (·.2)
      | _ => none
    | _ => none

/-- The separators an inline `Refs` list allows before its next reference, in the order tried. -/
def separators (cs : List Char) : List (List Char) :=
  let s1 := cs.dropWhile Char.isWhitespace
  let spaced := cs.head?.any Char.isWhitespace
  (if s1.head? == some ',' then [(s1.drop 1).dropWhile Char.isWhitespace] else []) ++
  (if spaced && startsCI s1 "and" && (s1.drop 3).head?.any Char.isWhitespace
   then [(s1.drop 3).dropWhile Char.isWhitespace] else []) ++
  (if spaced then [s1] else [])

/-- The text of a run of references at the start of `cs`, separated by commas, `and` or spaces. -/
def refList (cs : List Char) : List Char :=
  match oneRef cs with
  | none => []
  | some r => cs.take (cs.length - (more r (cs.length + 1)).length)
where
  /-- What follows the last reference of the run. -/
  more (cs : List Char) : Nat → List Char
    | 0 => cs
    | fuel + 1 =>
      match (separators cs).findSome? oneRef with
      | some r => more r fuel
      | none => cs

/-- The references a pull request makes with `Refs` or "part of": a line starting `Refs`, an
inline `Refs` followed by a list of references, or "part of" one. -/
def prRefs (text : String) : List Ref :=
  let lineRefs := (lines text).flatMap fun l =>
    let cs := l.toList.dropWhile Char.isWhitespace
    if startsCI cs "refs" then
      let r := cs.drop 4
      let r := if r.head? == some ':' then r.drop 1 else r
      if r.head?.any Char.isWhitespace && !(r.dropWhile Char.isWhitespace).isEmpty
      then refsIn (String.ofList r) else []
    else []
  lineRefs ++ inline [] text.toList (text.length + 1)
where
  inline (before : List Char) (cs : List Char) : Nat → List Ref
    | 0 => []
    | fuel + 1 =>
      match cs with
      | [] => []
      | c :: rest =>
        let free := !(before.head?.any fun b => wordChar b || b == '/' || b == '-')
        let wordFree := !(before.head?.any wordChar)
        let fromRefs :=
          if free && startsCI cs "refs" then
            let r := cs.drop 4
            let r := if r.head? == some ':' then r.drop 1 else r
            if r.head?.any Char.isWhitespace then refsIn (String.ofList (refList (r.dropWhile Char.isWhitespace)))
            else []
          else []
        let fromPartOf :=
          if wordFree && startsCI cs "part of" then
            let r := cs.drop 7
            if r.head?.any Char.isWhitespace then (refsIn (String.ofList (refList (r.dropWhile Char.isWhitespace)))).take 1
            else []
          else []
        fromRefs ++ fromPartOf ++ inline (c :: before) rest fuel

/-- The names `@`-mentioned in a text, in order, each once: an `@` not inside a word, an address or
a path. -/
def mentions (text : String) : List String :=
  (go [] text.toList (text.length + 1)).eraseDups
where
  go (before : List Char) (cs : List Char) : Nat → List String
    | 0 => []
    | fuel + 1 =>
      match cs with
      | [] => []
      | c :: rest =>
        let free := !(before.head?.any fun b => wordChar b || b == '@' || b == '/' || b == '.' || b == '-')
        if c == '@' && free then
          -- A sentence may end with a mention.
          let n := String.ofList ((name rest).1.toList.reverse.dropWhile (· == '.')).reverse
          (if n.isEmpty then [] else [n]) ++ go (c :: before) rest fuel
        else go (c :: before) rest fuel

/-- The headings a decision for the human states, so it can be answered as it stands. -/
def decisionSections : List String :=
  ["Question", "Options", "Recommendation", "If you say go ahead", "Blocked on this"]

/-- Whether a line is a Markdown heading naming `s`, ignoring case and a trailing colon. -/
def headingOf (s line : String) : Bool :=
  let cs := line.toList
  !cs.isEmpty && cs.head? == some '#' &&
    let t := (cs.dropWhile (· == '#')).dropWhile Char.isWhitespace
    let t := (String.ofList t).trimAsciiEnd.toString
    let t := if t.endsWith ":" then (t.dropEnd 1).trimAsciiEnd.toString else t
    lower t == lower s

def missingSections (text : String) : List String :=
  decisionSections.filter fun s => !(lines text).any (headingOf s)

/-- The tag of a `Released in vX.Y.Z` line, the first in the text. -/
def releasedIn (text : String) : Option String :=
  (lines text).findSome? fun l =>
    if l.startsWith "Released in v" then do
      let (x, r1) ← number (l.drop 13).toString.toList
      guard (r1.head? == some '.')
      let (y, r2) ← number (r1.drop 1)
      guard (r2.head? == some '.')
      let (z, r3) ← number (r2.drop 1)
      guard !(r3.head?.any wordChar)
      return s!"v{x}.{y}.{z}"
    else none

/-- A CHANGELOG.md version heading: `## vX.Y.Z`, `## X.Y.Z` or `## [X.Y.Z]`. -/
def changelogHeading (line : String) : Option Version := do
  guard (line.startsWith "##")
  let rest := (line.drop 2).toString.toList
  guard (rest.head?.any space)
  let rest := rest.dropWhile space
  let rest := if rest.head? == some '[' then rest.drop 1 else rest
  let rest := if rest.head? == some 'v' then rest.drop 1 else rest
  let (x, r1) ← Text.number rest
  guard (r1.head? == some '.')
  let (y, r2) ← Text.number (r1.drop 1)
  guard (r2.head? == some '.')
  let (z, _) ← Text.number (r2.drop 1)
  return ⟨x, y, z⟩

/-- CHANGELOG.md's newest version heading. -/
def changelogTop (text : String) : Option Version := (lines text).findSome? changelogHeading

/-- The newest version's section, from its heading to the next level-two heading. -/
def topSection (text : String) : Option String :=
  match (lines text).dropWhile (fun l => (changelogHeading l).isNone) with
  | [] => none
  | h :: rest =>
    let body := rest.takeWhile fun l => !(l.startsWith "##" && (l.drop 2).toString.toList.head?.any space)
    some ("\n".intercalate (h :: body)).trimAscii.toString

/-- ROADMAP.md says the project is finished. -/
def roadmapFinished (text : String) : Bool :=
  (lines text).any fun l =>
    let cs := l.toList.dropWhile space
    startsCI cs "status:" &&
      let r := (cs.drop 7).dropWhile space
      startsCI r "finished" && !((r.drop 8).head?.any wordChar)

/-- Whether code owners give `API.lock` to the coordinator: level 3. -/
def level3 (codeowners coordinator : String) : Bool :=
  (lines codeowners).any fun l =>
    match (l.splitToList Char.isWhitespace).filter (!·.isEmpty) with
    | p :: owners => p == "API\\.lock" && owners.contains s!"@{coordinator}"
    | [] => false

end Guild.Dispatcher.Text
