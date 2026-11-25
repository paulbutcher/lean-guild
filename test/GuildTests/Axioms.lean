/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import GuildTests.States
import GuildTests.PullStates
import GuildTests.Obligation
import GuildTests.Waits
import GuildTests.Properties
import GuildTests.PullProperties

/-! Every theorem, the kit's and its tests', depends only on Lean's standard axioms: no `sorry`,
and no `native_decide`, whose axiom trusts the compiler. -/

open Lean Elab Command in
run_cmd do
  let standard := [``propext, ``Quot.sound, ``Classical.choice]
  let env ← getEnv
  let ours := env.constants.fold (init := #[]) fun acc n ci =>
    if ((`Guild).isPrefixOf n || (`GuildTests).isPrefixOf n) && ci matches .thmInfo _ then acc.push n
    else acc
  if ours.isEmpty then throwError "no theorems found"
  for n in ours do
    for a in ← liftCoreM (collectAxioms n) do
      unless standard.contains a do
        throwError "{n} depends on {a}"
