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
