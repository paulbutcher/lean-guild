/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import GuildTests

def main : IO UInt32 := do
  let ok ← GuildTests.Fuel.check
  pure (if ok then 0 else 1)
