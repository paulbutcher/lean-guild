/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import TestbedApp

def main : IO UInt32 := pure (if message == "hello, app" then 0 else 1)
