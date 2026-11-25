/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
module

/-! The human's brakes, as files in `control/` under `STATE_DIR`, with the reference's names and
meanings, so either kit sees the other's. Each is read afresh whenever it matters, so a brake
takes effect without a restart. -/

@[expose] public section

namespace Guild.Control

/-- Nothing changes in the forge but by the human: no run starts, a run under way stops, and the
gatekeeper approves and releases nothing. -/
def paused (dir : System.FilePath) : IO Bool := (dir / "paused").pathExists

/-- Runs under way finish, and none starts. -/
def draining (dir : System.FilePath) : IO Bool := (dir / "draining").pathExists

end Guild.Control
