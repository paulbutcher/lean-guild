/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

/-! The next release's version, from the lines of `API.lock` removed and added since the last
release: the gatekeeper's rule, which the release states use to tell a CHANGELOG.md heading the
gatekeeper would refuse. Before 1.0, a change to the API is a minor bump. -/

namespace Guild.Version

structure Version where
  major : Nat
  minor : Nat
  patch : Nat
  deriving DecidableEq, Repr, Inhabited

/-- The non-blank lines, without trailing whitespace. -/
def apiLines (text : String) : List String :=
  ((text.splitOn "\n").map (fun l => l.trimAsciiEnd.toString)).filter (· ≠ "")

def next (prev : Option Version) (old new : String) : Version :=
  match prev with
  | none => ⟨0, 1, 0⟩
  | some ⟨x, y, z⟩ =>
    let o := apiLines old
    let n := apiLines new
    let removed := o.any (· ∉ n)
    let added := n.any (· ∉ o)
    if x == 0 then (if removed || added then ⟨0, y + 1, 0⟩ else ⟨0, y, z + 1⟩)
    else if removed then ⟨x + 1, 0, 0⟩
    else if added then ⟨x, y + 1, 0⟩
    else ⟨x, y, z + 1⟩

end Guild.Version
