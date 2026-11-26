/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import WebbedUi

/-- The browser tests, which Node runs in each browser this machine offers. -/
def main : IO UInt32 := do
  let child ← IO.Process.spawn
    { cmd := "node", args := #["test/browser.mjs", ",".intercalate (colour.map toString)] }
  child.wait
