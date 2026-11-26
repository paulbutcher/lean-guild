/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Lake
open Lake DSL

package «guild-test» where
  leanOptions := #[⟨`warningAsError, true⟩]
  testDriver := "tests"

require guild from ".."
require plausible from git "https://github.com/leanprover-community/plausible" @ "v4.36.0"

lean_lib GuildTests

@[default_target]
lean_exe tests where
  root := `Main

/-- The kit, built with each of the test projects' configuration, for the stage tests. -/
lean_exe «kit-plain» where
  root := `KitPlain

lean_exe «kit-browser» where
  root := `KitBrowser

/-- The contract tests, against a real Forgejo. -/
lean_exe contract where
  root := `ContractMain

/-- The dispatcher's tests alone. -/
lean_exe dispatch where
  root := `DispatchMain

/-- The randomised world test alone. -/
lean_exe world where
  root := `WorldMain
