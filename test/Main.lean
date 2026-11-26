/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import GuildTests

def main : IO UInt32 := do
  let results := [← GuildTests.Fuel.check, ← GuildTests.Interface.check, ← GuildTests.Contract.checkFake, ← GuildTests.Forge.check, ← GuildTests.Gatekeeper.check, ← GuildTests.Hook.check, ← GuildTests.Tools.check, ← GuildTests.Runner.check, ← GuildTests.Dispatch.Issues.check, ← GuildTests.Dispatch.Asks.check, ← GuildTests.Dispatch.Units.check, ← GuildTests.Dispatch.Obligations.check, ← GuildTests.Dispatch.Runs.check, ← GuildTests.Dispatch.Properties.check, ← GuildTests.Dispatch.Runs.checkAdditions, ← GuildTests.Ui.check, ← GuildTests.World.check]
  pure (if results.all id then 0 else 1)
