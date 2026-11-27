/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import GuildTests.Projects
import GuildTests.Fuel

/-! The project interface: configurations, settings, and each agent's assembled instructions. -/

namespace GuildTests.Interface

open Guild GuildTests.Projects

def contains (s part : String) : Bool := (s.splitOn part).length > 1

/-- Every agent's instructions, or the errors assembling them. -/
def all (p : Project) (t : Protocol.Text) : List (String × Except String String) :=
  p.config.agents.map (fun a => (a.name, Protocol.assemble p settings t a.name))

def rendersCleanly (p : Project) (t : Protocol.Text) : Bool :=
  Protocol.check p settings t == [] &&
    (all p t).all (fun (_, r) => match r with
      | .ok s => !contains s "{{" && !contains s "}}"
      | .error _ => false)

def mentions (p : Project) (t : Protocol.Text) (agent word : String) : Bool :=
  match Protocol.assemble p settings t agent with
  | .ok s => contains s word
  | .error _ => false

def reports (errors : List String) (part : String) : Bool := errors.any (contains · part)

def withConfig (p : Project) (f : Config → Config) : Config := f p.config

def editRepo (c : Config) (name : String) (f : Repository → Repository) : Config :=
  { c with repositories := c.repositories.map (fun r => if r.name == name then f r else r) }

def editAgent (c : Config) (name : String) (f : Agent → Agent) : Config :=
  { c with agents := c.agents.map (fun a => if a.name == name then f a else a) }

def editRole (t : Protocol.Text) (name : String) (f : String → String) : Protocol.Text :=
  { t with roles := t.roles.map (fun (n, r) => if n == name then (n, f r) else (n, r)) }

def cases : List (String × Bool) :=
  [("the plain project's instructions render", rendersCleanly plain plainText),
   ("the browser project's instructions render", rendersCleanly browser browserText),
   ("without the Lasm layer, no agent hears of Lasm",
     (all plain plainText).all (fun (a, _) => !mentions plain plainText a "Lasm")),
   ("with it, a library's agent does", mentions browser browserText "widgets" "under Lasm"),
   ("a site is told how it is deployed", mentions browser browserText "site" "build-site.sh"),
   ("an agent that tracks an upstream project is woken for its blocking issues",
     mentions browser browserText "lasm" "upstream:lasm"),
   ("imported history is never instructions, only where there is some",
     mentions browser browserText "widgets" "`Ghost`" && !mentions plain plainText "base" "`Ghost`"),
   ("a project block nothing uses is reported",
     reports (Protocol.check plain settings { plainText with sections := plainText.sections ++ "@@ nowhere\nlost\n" }) "nowhere"),
   ("a role block its kind has no room for is reported",
     reports (Protocol.check plain settings (editRole plainText "base" (· ++ "@@ extra\nlost\n"))) "extra"),
   ("an agent without a role is reported",
     reports (Protocol.check plain settings { plainText with roles := plainText.roles.filter (·.1 != "app") }) "app has no role"),
   ("a dependency on an unlisted repository is an error",
     reports (editRepo plain.config "testbed-app" fun r => { r with dependsOn := ["testbed-gone"] }).errors "testbed-gone"),
   ("a library whose recommendations the human decides is an error",
     reports (editAgent plain.config "base" fun a => { a with humanDecides := true }).errors "base"),
   ("a site without the Lasm layer is an error",
     reports (withConfig browser fun c => { c with layers := {} }).errors "needs the Lasm layer"),
   ("an upstream tracked by no agent is an error",
     reports (withConfig browser fun c => { c with upstreams := [{ name := "x", title := "X", tracker := some "nobody" }] }).errors "nobody"),
   ("the coordination repository stays at level 1",
     reports (editRepo plain.config "testbed-coordination" fun r => { r with level := 3 }).errors "level 1"),
   ("an agent named after one of the kit's services is an error",
     reports (editAgent plain.config "base" fun a => { a with name := "ui" }).errors "kit's own services"),
   ("a repository no agent owns is an error",
     reports (withConfig plain fun c => { c with repositories := c.repositories ++ [{ name := "testbed-orphan" }] }).errors "no owner"),
   ("missing settings are named, not defaulted",
     match Settings.read (fun _ => none) with
     | .error es => reports es "FORGE_ORG" && reports es "HUMAN_USER" && reports es "FORGE_WEB_URL"
     | .ok _ => false),
   ("a malformed MACOS_RUNNER is an error, not off",
     match Settings.read (fun n => if n == "MACOS_RUNNER" then some "yes" else some "x") with
     | .error es => reports es "MACOS_RUNNER"
     | .ok _ => false),
   ("a malformed mirrors setting is an error",
     match Settings.read (fun n => if n == "MIRRORS" then some "maybe" else some "x") with
     | .error es => reports es "MIRRORS"
     | .ok _ => false),
   ("mirrors can be turned off",
     match Settings.read (fun n => if n == "MIRRORS" then some "off" else if n == "MACOS_RUNNER" then none else some "x") with
     | .ok s => !s.mirrors
     | .error _ => false),
   ("the coordination repository needs no CI, API.lock or releases",
     match plain.config.repository? "testbed-coordination" with
     | some r => (plain.config.contract r).all (fun q => match q with
         | .ciWorkflow _ | .apiLock | .changelog | .versionTags => false
         | _ => true)
     | none => false),
   ("a library's code owners give it the level its setup starts it at",
     match plain.config.repository? "testbed-app" with
     | some r => (plain.config.contract r).contains (.codeOwners ".forgejo/CODEOWNERS" 3)
     | none => false),
   ("a new library's seed keeps only the placeholders the tools fill, and its module under the root",
     let t := { browser.config.template with
       namespaceRoot := "Webbed.Libs", leanOptions := [("autoImplicit", "false")] }
     match Kit.librarySeed t with
     | .ok fs =>
       fs.all (fun (_, t) => !contains (((t.replace "{{REPO}}" "").replace "{{NAME}}" "").replace "{{HEADER}}" "") "{{") &&
         fs.any (·.1 == "templates/library/Webbed/Libs/NAME.lean")
     | .error _ => false),
   ("only a project with the macOS runner has the macos job, and it runs only where a runner serves it",
     match Kit.checksYml browser.config settings, Kit.checksYml { browser.config with layers := { lasm := true } } settings with
     | .ok on, .ok off => contains on "runs-on: macos" && contains on "if: vars.MACOS_RUNNER == 'on'" &&
         !contains off "runs-on: macos"
     | _, _ => false),
   ("only a project with the macOS runner tells its agents how Chromium reaches the Mac's GPU",
     mentions browser browserText "widgets" "--use-angle=metal" &&
       !mentions { browser with config := { browser.config with layers := { lasm := true } } } browserText "widgets" "--use-angle=metal" &&
       mentions { browser with config := { browser.config with layers := { lasm := true } } } browserText "widgets" "Headless Chromium" &&
       !mentions { browser with config := { browser.config with layers := { lasm := true } } } browserText "widgets" "be downloaded.\n\n"),
   ("both jobs check out the same way",
     match Kit.checksYml browser.config settings with
     | .ok y => (y.splitOn "git checkout -q --detach").length == 3
     | .error _ => false),
   ("a deployment's macOS runner without the configuration's is an error",
     match Kit.checksYml plain.config { settings with macosRunner := true } with
     | .error e => contains e "MACOS_RUNNER"
     | .ok _ => false),
   ("the backoff reads as the agents are told it",
     Protocol.wakes [0, 900, 900] == "at once, then twice more 15 minutes apart" &&
       Protocol.wakes [300, 3600] == "after 5 minutes, then once more after an hour")]

open Plausible

/-- Text with no tags is left as it is. A proof would have to follow the tokenizer through
`splitOn`, whose lemmas don't yet say enough about strings without the separator. -/
def plainTextUnchanged (s : String) : Bool :=
  let s := s.replace "{" "("
  match Template.render { vars := [], flags := [], inserts := [] } s with
  | .ok (out, _) => out == s
  | .error _ => false

/-- A section on a block's last lines leaves nothing behind when it is off, as if it weren't there.
Not proven for the same reason as `plainTextUnchanged`. -/
def sectionAtEnd (a b : String) : Bool :=
  let a := (a.replace "{" "(").replace "}" ")"
  let b := (b.replace "{" "(").replace "}" ")"
  let at_ (on : Bool) := Template.render { vars := [], flags := [("f", on)], inserts := [] }
    (a ++ "\n{{#f}}\n" ++ b ++ "\n{{/f}}")
  match at_ false, at_ true with
  | .ok (off, _), .ok (on, _) => off == a && on == a ++ "\n" ++ b
  | _, _ => false

/-- Exporting into an earlier export leaves its unchanged files alone, which containers have
mounted, and removes what it no longer writes. -/
def exportsAgain : IO Bool := do
  let dir := (← IO.currentDir) / ".lake" / "export-test" / toString (← IO.monoNanosNow)
  let s : Settings := { settings with forgeWebUrl := "http://localhost:3000" }
  unless (← Kit.exportTo plain s plainText dir) == 0 do return false
  let kept := dir / "gitconfig"
  let before := (← kept.metadata).modified
  IO.FS.writeFile (dir / "stale.txt") "left by an earlier configuration"
  IO.sleep 20
  unless (← Kit.exportTo plain s plainText dir) == 0 do return false
  let unchanged := (← kept.metadata).modified == before
  let removed := !(← (dir / "stale.txt").pathExists)
  IO.FS.removeDirAll dir
  return unchanged && removed

/-- The services `compose.yaml` defines, which `Config.kitServices` must name. -/
def composeServices : IO (List String) := do
  let lines := (← IO.FS.readFile ((← IO.currentDir) / ".." / "compose.yaml")).splitOn "\n"
  let body := (lines.dropWhile (· != "services:")).drop 1 |>.takeWhile fun l => l.isEmpty || l.startsWith " " || l.startsWith "#"
  return body.filterMap fun l =>
    if l.startsWith "  " && !l.startsWith "   " && l.endsWith ":" then some ((l.drop 2).dropEnd 1).toString else none

def check : IO Bool := do
  let mut ok := true
  for (name, passed) in cases do
    unless passed do
      IO.eprintln s!"Interface: {name}"
      ok := false
  let services ← composeServices
  unless !services.isEmpty && services.all Config.kitServices.contains do
    IO.eprintln s!"Interface: compose.yaml has services Config.kitServices doesn't name: {services.filter (!Config.kitServices.contains ·)}"
    ok := false
  unless ← exportsAgain do
    IO.eprintln "Interface: an export again rewrote an unchanged file, or kept a stale one"
    ok := false
  let r ← Fuel.checkIO (∀ s, plainTextUnchanged s = true) { numInst := 500 }
  unless r matches .success _ do
    IO.eprintln s!"Interface: plain text: {r}"
    ok := false
  let r ← Fuel.checkIO (∀ a b, sectionAtEnd a b = true) { numInst := 500 }
  unless sectionAtEnd "a" "b" && r matches .success _ do
    IO.eprintln s!"Interface: a section at a block's end: {r}"
    ok := false
  pure ok

end GuildTests.Interface
