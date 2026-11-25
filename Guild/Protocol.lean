/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Guild.Config
import Guild.Settings
import Guild.Template

/-! Each agent's instructions: its role, through its kind's template, then the protocol. The kit
supplies the protocol and every kind's text, the Lean and Lasm layers their blocks, and the
project its roles and its own blocks, inserted where the kit's text leaves room for them. -/

namespace Guild.Protocol

open Template

def protocol : String := include_str "Protocol/protocol.md"

def kindTemplate : Kind → String
  | .coordinator => include_str "Protocol/kinds/coordinator.md"
  | .library => include_str "Protocol/kinds/library.md"
  | .site => include_str "../layers/lasm/kinds/site.md"
  | .prReviewer => include_str "Protocol/kinds/prReviewer.md"
  | .milestoneReviewer => include_str "Protocol/kinds/milestoneReviewer.md"
  | .supervisor => include_str "Protocol/kinds/supervisor.md"

def leanBlocks : List (String × String) := (blocks (include_str "../layers/lean/protocol.md")).2
def lasmBlocks : List (String × String) := (blocks (include_str "../layers/lasm/protocol.md")).2

/-- The Playwright version the Lasm layer installs in the agents' and CI's images. -/
def playwright : String := "1.64.1"

/-- What the project writes: a role for each agent, and blocks for the protocol. Each role is
its text, then any blocks its kind's template has room for (`@@ name` lines start them). -/
structure Text where
  roles : List (String × String)
  /-- The project's blocks for the protocol, as `@@ name` blocks. -/
  sections : String := ""

/-! ## Words -/

def numberWord : Nat → String
  | 1 => "one" | 2 => "two" | 3 => "three" | 4 => "four" | 5 => "five" | 6 => "six"
  | 7 => "seven" | 8 => "eight" | 9 => "nine" | 10 => "ten" | n => toString n

/-- How many times: once, twice, three times. -/
def times : Nat → String
  | 1 => "once"
  | 2 => "twice"
  | n => s!"{numberWord n} times"

/-- `a`, `a and b`, `a, b and c`, or with another word in place of "and". -/
def listing (xs : List String) (conj : String := "and") : String :=
  match xs with
  | [] => ""
  | [a] => a
  | [a, b] => s!"{a} {conj} {b}"
  | a :: rest => s!"{a}, {listing rest conj}"

def code (s : String) : String := s!"`{s}`"

def duration (seconds : Nat) : String :=
  if seconds % 3600 == 0 then
    (if seconds == 3600 then "an hour" else s!"{seconds / 3600} hours")
  else if seconds % 60 == 0 then
    (if seconds == 60 then "a minute" else s!"{seconds / 60} minutes")
  else s!"{seconds} seconds"

/-- Runs of equal delays, in order. -/
def runs : List Nat → List (Nat × Nat)
  | [] => []
  | d :: ds => match runs ds with
    | (e, k) :: rest => if d == e then (d, k + 1) :: rest else (d, 1) :: (e, k) :: rest
    | [] => [(d, 1)]

/-- When an agent is woken again for what it still owes, from the backoff: "at once, then twice
more 15 minutes apart". -/
def wakes (backoff : List Nat) (afterRun : Bool := false) : String :=
  let first (d : Nat) :=
    if afterRun then (if d == 0 then "at once when your run ends" else s!"{duration d} after your run ends")
    else if d == 0 then "at once" else s!"after {duration d}"
  let more := fun ((d, k) : Nat × Nat) =>
    if k == 1 then s!"once more after {duration d}" else s!"{times k} more {duration d} apart"
  match backoff with
  | [] => ""
  | d :: ds => ", then ".intercalate (first d :: (runs ds).map more)

/-! ## Assembly -/

def humanOnly (c : Config) : String := listing (c.humanOnlyFiles.map code)

def ghOwner? (c : Config) : Option String :=
  match c.forge with
  | .forgejo (some m) _ => some m.owner
  | .forgejo none _ => none
  | .github owner => some owner

def context (p : Project) (s : Settings) (text : Text) (a : Agent) : Context :=
  let c := p.config
  let role := ((text.roles.lookup a.name).map blocks).getD ("", [])
  let opt (n : String) (v : Option String) := match v with | some x => [(n, x)] | none => []
  let tracked := c.tracks? a.name
  { vars :=
      [("AGENT", a.name), ("ORG", s.forgeOrg), ("HUMAN", s.human), ("FORGE_WEB_URL", s.forgeWebUrl),
       ("PROJECT", c.name), ("COORDINATION", c.coordination),
       ("REPOS", listing (c.repoNames.map code)),
       ("LIBRARIES", listing ((c.repoNames.filter (· != c.coordination)).map code)),
       ("HUMAN_ONLY", humanOnly c), ("HUMAN_ONLY_OR", listing (c.humanOnlyFiles.map code) "or"),
       ("WAKES", wakes c.bounds.backoff),
       ("WAKES_AFTER_RUN", wakes c.bounds.backoff true), ("TRIES", times c.bounds.backoff.length),
       ("ROUNDS", numberWord c.bounds.reviewRounds),
       ("RERUNS", if c.bounds.rerunLimit == 1 then "one re-run" else s!"{numberWord c.bounds.rerunLimit} re-runs"),
       ("NUDGES", numberWord c.bounds.supervisorNudges),
       ("WORKSPACE_STATE", s.workspaceState), ("FORGE_DIR", c.forgeDir),
       ("UPSTREAM_EXAMPLES", listing (c.upstreams.map (·.title) ++ ["Lean", "Mathlib", "any other"]) "or"),
       ("MILESTONE_REVIEWERS", listing (c.milestoneReviewers.map (code ·.name))),
       ("PLAYWRIGHT", playwright)] ++
      opt "COORDINATOR" (c.coordinator?.map (·.name)) ++
      opt "REVIEWER" (c.reviewer?.map (·.name)) ++
      opt "SUPERVISOR" (c.supervisor?.map (·.name)) ++
      opt "REPO" a.owns ++ opt "GH_OWNER" (ghOwner? c) ++ opt "UPSTREAM" (tracked.map (·.name))
    flags :=
      [("lasm", c.layers.lasm), ("macos", c.layers.macos),
       ("mirrored", match c.forge with | .forgejo (some _) _ => true | _ => false),
       ("imported", match c.forge with | .forgejo _ i => i | _ => false),
       ("reviewer", c.reviewer?.isSome), ("supervisor", c.supervisor?.isSome),
       ("milestoneReviews", !c.milestoneReviewers.isEmpty),
       ("tracks", tracked.isSome), ("owns", a.owns.isSome)]
    inserts :=
      [("role", role.1)] ++ role.2.map (fun (n, b) => (s!"role:{n}", b)) ++
      (blocks text.sections).2.map (fun (n, b) => (s!"project:{n}", b)) ++
      leanBlocks.map (fun (n, b) => (s!"lean:{n}", b)) ++
      (if c.layers.lasm then lasmBlocks.map (fun (n, b) => (s!"lasm:{n}", b)) else []) }

/-- An agent's instructions, and the blocks they used. -/
def assembleUsing (p : Project) (s : Settings) (text : Text) (a : Agent) :
    Except String (String × List String) := do
  if let .github _ := p.config.forge then throw "the protocol for GitHub mode isn't written yet"
  let ctx := context p s text a
  let (role, used) ← render ctx (kindTemplate a.kind)
  let (rest, used') ← render ctx protocol
  return (role ++ "\n" ++ rest, used ++ used')

def assemble (p : Project) (s : Settings) (text : Text) (agent : String) : Except String String := do
  match p.config.agent? agent with
  | none => throw s!"{agent} is not an agent"
  | some a => return (← assembleUsing p s text a).1

/-- What is wrong with the project's text: an agent without a role, a role for no agent, an
instruction that doesn't render, or a block nothing uses, which would otherwise vanish. -/
def check (p : Project) (s : Settings) (text : Text) : List String :=
  let c := p.config
  let missing := c.agents.filterMap (fun a =>
    if (text.roles.lookup a.name).isNone then some s!"agent {a.name} has no role" else none)
  let extra := text.roles.filterMap (fun (n, _) =>
    if (c.agent? n).isNone then some s!"there is a role for {n}, which is not an agent" else none)
  let results := c.agents.map (fun a => (a, assembleUsing p s text a))
  let failures := results.filterMap (fun (a, r) => match r with
    | .error e => some s!"{a.name}'s instructions: {e}"
    | .ok _ => none)
  let used := results.flatMap (fun (_, r) => match r with | .ok (_, u) => u | .error _ => [])
  let roleBlocks := text.roles.flatMap (fun (n, src) =>
    (blocks src).2.filterMap (fun (b, _) =>
      let usedHere := results.any (fun (a, r) => a.name == n && match r with
        | .ok (_, u) => u.contains s!"role:{b}"
        | .error _ => true)
      if usedHere then none else some s!"{n}'s role has a block {b} that its kind has no room for"))
  let projectBlocks := (blocks text.sections).2.filterMap (fun (b, _) =>
    if used.contains s!"project:{b}" || !failures.isEmpty then none
    else some s!"the project's block {b} is used nowhere")
  missing ++ extra ++ failures ++ roleBlocks ++ projectBlocks

end Guild.Protocol
