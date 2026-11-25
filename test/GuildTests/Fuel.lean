/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Guild
import Plausible

namespace GuildTests.Fuel

open Guild.Waits Plausible

/-- Waits among a handful of units, so that chains and loops are common. -/
def edges (es : List (Nat × Nat × Bool)) : List (Edge Nat) :=
  es.map fun (s, d, b) => ⟨s % 5, d % 5, b⟩

/-- More fuel than there are waits finds nothing more: with `reaches_complete`, the dispatcher's
search finds every chain of waits. -/
def enough (es : List (Nat × Nat × Bool)) (a b k : Nat) : Bool :=
  let E := edges es
  reaches E (E.length + k) (a % 5) (b % 5) == reaches E E.length (a % 5) (b % 5)

open Decorations in
/-- `Testable.checkIO`, with the binders named as `Testable.check` names them. -/
def checkIO (p : Prop) (cfg : Configuration := {}) (p' : DecorationsOf p := by mk_decorations)
    [Testable p'] : IO (TestResult p') :=
  Testable.checkIO p' cfg

def check : IO Bool := do
  let r ← checkIO (∀ es a b k, enough es a b k = true) { numInst := 2000 }
  match r with
  | .success _ => pure true
  | _ => IO.eprintln s!"Waits: {r}"; pure false

end GuildTests.Fuel
