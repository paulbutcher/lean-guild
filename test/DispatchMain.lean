/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import GuildTests

/-- The dispatcher's tests alone, which `lake test` also runs. -/
def main : IO UInt32 := do
  let results := [← GuildTests.Dispatch.Issues.check, ← GuildTests.Dispatch.Asks.check, ← GuildTests.Dispatch.Units.check, ← GuildTests.Dispatch.Obligations.check, ← GuildTests.Dispatch.Runs.check, ← GuildTests.Dispatch.Properties.check, ← GuildTests.Dispatch.Runs.checkAdditions]
  pure (if results.all id then 0 else 1)
