/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import GuildTests

/-- The randomised world test alone, which `lake test` also runs. -/
def main : IO UInt32 := do
  pure (if ← GuildTests.World.check then 0 else 1)
