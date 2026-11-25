/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

/-! Deployment settings, read from the environment at run time, never compiled in. A setting
with no default must be set: a kit that guessed would run against the wrong organisation or
account without saying so. -/

namespace Guild

structure Settings where
  /-- The forge organisation that holds the project's repositories. -/
  forgeOrg : String
  /-- The human's account on the forge. -/
  human : String
  /-- The forge as the human's browser reaches it, for links agents write. -/
  forgeWebUrl : String
  /-- The compose project, which names every volume. -/
  composeProject : String := "guild"
  /-- Where `secrets/`, `control/` and `backups/` live. -/
  stateDir : String := "."
  /-- Names in repositories' code-owned CI files and agents' workspaces, which a switch from
  another kit keeps. -/
  ciImage : String := "guild-ci:1"
  toolchainVolume : String := "guild-elan"
  requireLasmVar : String := "GUILD_REQUIRE_LASM"
  workspaceState : String := ".guild"
  /-- Whether this deployment keeps push mirrors: off for a test deployment of a project that
  mirrors in production. -/
  mirrors : Bool := true
  /-- Where push mirrors go: each repository is mirrored to `<base>/<owner>/<repo>.git`. A test
  deployment points it at a second organisation in its own forge. -/
  mirrorBase : String := "https://github.com"
  deriving DecidableEq, Repr

namespace Settings

/-- The settings from a lookup of the environment, or what is missing or malformed. -/
def read (env : String → Option String) : Except (List String) Settings :=
  let need (n : String) : Except (List String) String := match env n with
    | some v => if v.isEmpty then Except.error [s!"{n} is empty"] else .ok v
    | none => .error [s!"{n} is not set"]
  let opt (n d : String) := (env n).getD d
  let flag (n : String) (d : Bool) : Except (List String) Bool := match env n with
    | none => .ok d
    | some "on" => .ok true
    | some "off" => .ok false
    | some v => .error [s!"{n} is {v}, not on or off"]
  let errs {α} (r : Except (List String) α) : List String := match r with
    | .error e => e
    | .ok _ => []
  match need "FORGE_ORG", need "HUMAN_USER", need "FORGE_WEB_URL", flag "MIRRORS" true with
  | .ok org, .ok human, .ok web, .ok mirrors =>
    .ok { forgeOrg := org, human, forgeWebUrl := web,
          composeProject := opt "COMPOSE_PROJECT_NAME" "guild", stateDir := opt "STATE_DIR" ".",
          ciImage := opt "CI_IMAGE" "guild-ci:1", toolchainVolume := opt "TOOLCHAIN_VOLUME" "guild-elan",
          requireLasmVar := opt "REQUIRE_LASM_VAR" "GUILD_REQUIRE_LASM",
          workspaceState := opt "WORKSPACE_STATE" ".guild", mirrors,
          mirrorBase := opt "MIRROR_BASE" "https://github.com" }
  | org, human, web, mirrors => .error (errs org ++ errs human ++ errs web ++ errs mirrors)

def fromEnv : IO (Except (List String) Settings) := do
  let names := ["FORGE_ORG", "HUMAN_USER", "FORGE_WEB_URL", "COMPOSE_PROJECT_NAME", "STATE_DIR",
    "CI_IMAGE", "TOOLCHAIN_VOLUME", "REQUIRE_LASM_VAR", "WORKSPACE_STATE", "MIRRORS", "MIRROR_BASE"]
  let vals ← names.mapM (fun n => do return (n, ← IO.getEnv n))
  return read (fun n => (vals.lookup n).join)

end Settings

end Guild
