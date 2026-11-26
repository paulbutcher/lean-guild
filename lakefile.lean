/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Lake
open Lake DSL

package guild where
  version := v!"0.9.0"
  leanOptions := #[⟨`warningAsError, true⟩]

require leancurl from git "https://github.com/paulbutcher/leancurl" @ "v0.4.0"
require leansqlite from git "https://github.com/leanprover/leansqlite" @ "v4.36.0"
require json from git "https://github.com/paulbutcher/lean-json" @ "v0.4.0"
require jsonDeriving from git "https://github.com/paulbutcher/lean-json" @ "v0.4.0" / "deriving"
require leancrypto from git "https://github.com/paulbutcher/leancrypto" @ "v0.5.0"
require html from git "https://github.com/paulbutcher/lean-html" @ "v0.15.3"
require htmx from git "https://github.com/paulbutcher/lean-htmx" @ "v0.9.3"
require css from git "https://github.com/paulbutcher/lean-css" @ "v0.3.0"
require routing from git "https://github.com/paulbutcher/lean-routing" @ "v0.16.0"
require «routing-std» from git "https://github.com/paulbutcher/lean-routing" @ "v0.16.0" / "std"
require middleware from git "https://github.com/paulbutcher/lean-middleware" @ "v0.22.1"
require «middleware-cookiestore» from git "https://github.com/paulbutcher/lean-middleware" @ "v0.22.1" / "cookiestore"

input_dir protocolText where
  path := "Guild/Protocol"
  text := true

input_dir leanLayer where
  path := "layers/lean"
  text := true

input_dir lasmLayer where
  path := "layers/lasm"
  text := true

input_dir kitTemplates where
  path := "templates"
  text := true

input_dir kitProxy where
  path := "docker/proxy"
  text := true

input_file uiScript where
  path := "Guild/Ui/notify.js"
  text := true

@[default_target]
lean_lib Guild where
  needs := #[protocolText, leanLayer, lasmLayer, kitTemplates, kitProxy, uiScript]

@[test_driver]
script tests do
  let child ← IO.Process.spawn
    { cmd := "lake", args := #["test"], cwd := __dir__ / "test" }
  child.wait

/-- The gatekeeper: approvals on CI, and releases at level 3. -/
lean_exe «guild-gatekeeper» where
  root := `Guild.Gatekeeper.Main

/-- Claude Code's hooks in an agent's container. -/
lean_exe «guild-hook» where
  root := `Guild.Agent.HookMain

/-- The agents' `forge` command. -/
lean_exe forge where
  root := `Guild.Agent.ForgeMain

/-- The agent runner, for the life of an agent's container. -/
lean_exe «guild-runner» where
  root := `Guild.Agent.RunnerMain

/-- The dispatcher: who is woken for what, the run ledger, and what the human's pages show. -/
lean_exe «guild-dispatcher» where
  root := `Guild.Dispatcher.Main

/-- The human's web UI. -/
lean_exe «guild-ui» where
  root := `Guild.Ui.Main
