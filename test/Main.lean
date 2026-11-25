/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import GuildTests

def main : IO UInt32 := do
  let results := [← GuildTests.Fuel.check, ← GuildTests.Interface.check, ← GuildTests.Contract.checkFake, ← GuildTests.Forge.check]
  pure (if results.all id then 0 else 1)
