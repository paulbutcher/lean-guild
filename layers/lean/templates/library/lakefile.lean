{{HEADER}}
import Lake
open Lake DSL

package «{{REPO}}» where
  leanOptions := #[{{LEAN_OPTIONS}}]

@[default_target]
lean_lib {{LIB}} where
  roots := #[`{{MODULE}}]

@[test_driver]
script tests do
  let child ← IO.Process.spawn
    { cmd := "lake", args := #["test"], cwd := __dir__ / "test" }
  child.wait
