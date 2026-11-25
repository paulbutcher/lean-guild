/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Guild.Forge.Forgejo
import GuildTests.Fuel

namespace GuildTests.Forge

open Guild.Forge Guild.Forge.Forgejo Plausible

theorem verdict_name : ∀ v ∈ [Verdict.approve, .requestChanges, .comment], verdict (verdictName v) = v := by
  decide +kernel

theorem fold_unreserved (l : List Char) (acc : String) (h : l.all unreserved = true) :
    l.foldl (fun acc c =>
      if unreserved c then acc.push c
      else (String.singleton c).toUTF8.foldl (fun a b =>
        (a.push '%').push (hexDigit (b.toNat / 16)) |>.push (hexDigit (b.toNat % 16))) acc) acc
      = acc ++ String.ofList l := by
  induction l generalizing acc with
  | nil => apply String.ext; simp
  | cons c l ih =>
    simp only [List.all_cons, Bool.and_eq_true] at h
    simp only [List.foldl_cons, h.1, ite_true]
    rw [ih _ h.2]
    apply String.ext
    simp

/-- A name or a ref that needs no escaping reaches the forge as it is. -/
theorem encode_unreserved (s : String) (h : s.toList.all unreserved = true) : encode s = s := by
  unfold encode
  rw [fold_unreserved _ _ h]
  apply String.ext
  simp

/-- What `encode` writes can't end a query value or a path segment early. A property, since the
escapes come from folding over the character's UTF-8 bytes, where `ByteArray.foldl` has too few
lemmas for a short proof. -/
def safe (s : String) : Bool :=
  (encode s).toList.all fun c => unreserved c || c == '%'

def check : IO Bool := do
  let r ← Fuel.checkIO (∀ s : String, safe s = true) { numInst := 2000 }
  match r with
  | .success _ => IO.println "PASS: percent-encoding leaves nothing that ends a value"; return true
  | _ => IO.println s!"FAIL: percent-encoding left a character that ends a value: {r}"; return false

end GuildTests.Forge
