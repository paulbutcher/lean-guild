/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Guild.Protocol

/-! The kit's executable, which a project builds with its configuration and text:
`def main := Guild.Kit.main project text`. The kit's shell scripts run its `export` command for
what they need to know of the configuration, as files. -/

namespace Guild.Kit

open Template

def Kind.label : Kind → String
  | .coordinator => "coordinator" | .library => "library" | .site => "site"
  | .prReviewer => "pr-reviewer" | .milestoneReviewer => "milestone-reviewer"
  | .supervisor => "supervisor"

/-- Labels on every repository, as name, colour and description. -/
def labels : List (String × String × String) :=
  [("request", "0e8a16", "A capability another library or consumer needs"),
   ("new", "fbca04", "Not yet triaged by the owner"),
   ("accepted", "0e8a16", "The owner will do it"),
   ("counter-proposal", "c5def5", "The owner proposes something else"),
   ("needs-human", "d93f0b", "Waiting for the human"),
   ("blocked", "b60205", "Waiting on another issue (Blocked-by: line)"),
   ("ready-for-release", "5319e7", "Merged and in CHANGELOG.md; waiting for a release"),
   ("verified", "0e8a16", "The requester checked the release"),
   ("not-verified", "d93f0b", "The requester checked the latest release, and it falls short"),
   ("priority", "e11d21", "Before anything new: set by the human or the coordinator")]

/-- Labels on the coordination repository besides: the upstream tracker, milestone reviews and
their recommendations. -/
def coordinationLabels (c : Config) : List (String × String × String) :=
  [("upstream", "bfdadc", "A bug or limitation in a dependency outside this project"),
   ("blocking", "b60205", "An upstream issue that stops an agent working"),
   ("milestone-review", "1d76db", "Start the end-of-milestone reviews"),
   ("milestone", "1d76db", "A milestone issue"),
   ("recommendation", "5319e7", "A recommendation from a review, for the human to decide"),
   ("declined", "cccccc", "A recommendation the human rejected; not raised again without new evidence")] ++
  c.upstreams.map (fun u => (s!"upstream:{u.name}", "bfdadc", s!"An upstream issue in {u.title}")) ++
  c.milestoneReviewers.map (fun a => (s!"review:{a.name}", "c5def5", s!"From {a.name}'s review"))

/-- A path as a code owner's pattern: Forgejo matches Go regular expressions against whole
paths. -/
def pattern (path : String) : String :=
  let escaped := path.replace "." "\\."
  if path.endsWith "/" then escaped ++ ".*" else escaped

/-- The code owners an autonomy level needs. Every matching line adds owners, and each owner's
review request blocks the merge until they approve. -/
def codeowners (c : Config) (s : Settings) (level : Nat) : String :=
  let human := "@" ++ s.human
  let coordinator := (c.coordinator?.map (fun a => "@" ++ a.name)).getD human
  let (catchall, api) := match level with
    | 1 => (human, human)
    | 2 => ("@gatekeeper", human)
    | _ => ("@gatekeeper", coordinator)
  let reviewer := match c.reviewer? with | some a => s!" @{a.name}" | none => ""
  let humanOnly := (c.humanOnlyFiles ++ (if c.forgeDir == ".github/" then [] else [".github/"])).eraseDups
  "\n".intercalate
    ([s!"# Code owners for autonomy level {level}, which the kit's repository setup checks.",
      "# Each line is a Go regular expression matched against a whole path, without a leading",
      "# slash; every matching line adds its owners, and each owner's review request blocks the",
      "# merge until they approve.",
      s!".* {catchall}{reviewer}",
      s!"API\\.lock {api}"] ++
     humanOnly.map (fun f => s!"{pattern f} {human}")) ++ "\n"

def runner (s : Settings) : String := s!"# Forgejo runner configuration, which the kit writes.
log:
  level: info

runner:
  file: /data/.runner
  # Jobs at once. Each is a Lean build.
  capacity: 3
  timeout: 3h
  # Every job reaches the outside only through ci-proxy, and Forgejo directly.
  envs:
    HTTP_PROXY: http://ci-proxy:3128
    HTTPS_PROXY: http://ci-proxy:3128
    http_proxy: http://ci-proxy:3128
    https_proxy: http://ci-proxy:3128
    NO_PROXY: forgejo,localhost,127.0.0.1
    no_proxy: forgejo,localhost,127.0.0.1
    FORGE_URL: http://forgejo:3000
  labels:
    - \"docker:docker://{s.ciImage}\"

cache:
  enabled: false

container:
  # Jobs share ci-docker's network namespace, so they resolve and reach forgejo and
  # ci-proxy, and have no other route.
  network: host
  privileged: false
  # Never give jobs a Docker socket.
  docker_host: \"-\"
  # The CI image is loaded into ci-docker by the kit, never pulled.
  force_pull: false
  # Lean toolchains, kept between jobs.
  valid_volumes:
    - {s.toolchainVolume}
"

/-! ## Files -/

def checks : String := include_str "../layers/lean/templates/repo/.forgejo/workflows/checks.yml"
def checkPins : String := include_str "../layers/lean/templates/repo/scripts/check-pins.sh"
def request : String := include_str "../templates/repo/.forgejo/issue_template/request.md"
def pages : String := include_str "../layers/lasm/templates/site/.github/workflows/pages.yml"
def lasmChecks : List (String × String) := (blocks (include_str "../layers/lasm/templates/checks.md")).2

/-- A new library's seed, by its path in the library with `MODULE` for the module's own. -/
def library : List (String × String) :=
  [("lakefile.lean", include_str "../layers/lean/templates/library/lakefile.lean"),
   ("MODULE.lean", include_str "../layers/lean/templates/library/MODULE.lean"),
   ("README.md", include_str "../layers/lean/templates/library/README.md"),
   ("CHANGELOG.md", include_str "../layers/lean/templates/library/CHANGELOG.md"),
   ("DESIGN.md", include_str "../layers/lean/templates/library/DESIGN.md"),
   (".gitignore", include_str "../layers/lean/templates/library/.gitignore"),
   ("test/lakefile.lean", include_str "../layers/lean/templates/library/test/lakefile.lean"),
   ("test/Main.lean", include_str "../layers/lean/templates/library/test/Main.lean")]

/-- The seed with the configuration's values filled in. `{{REPO}}`, `{{NAME}}` and `{{HEADER}}`
stay, for the tools to fill when a library is made, and `NAME` in a path. -/
def librarySeed (t : LibraryTemplate) : Except String (List (String × String)) :=
  let options := match t.leanOptions with
    | [] => ""
    | os => String.join (os.map fun (n, v) => s!"\n    ⟨`{n}, {v}⟩,") ++ "\n  "
  let ctx : Context :=
    { vars := [("REPO", "{{REPO}}"), ("NAME", "{{NAME}}"), ("HEADER", "{{HEADER}}"),
               ("MODULE", s!"{t.namespaceRoot}.\{\{NAME}}"),
               ("LIB", s!"{t.namespaceRoot.replace "." ""}\{\{NAME}}"),
               ("README_LINE", t.readmeLine), ("LEAN_OPTIONS", options)]
      flags := [], inserts := [] }
  library.mapM fun (path, src) => do
    let path := if path == "MODULE.lean" then s!"{t.namespaceRoot.replace "." "/"}/NAME.lean" else path
    return (s!"templates/library/{path}", (← render ctx src).1)

/-- Each proxy's lists: the kit's, then each layer's the project uses. -/
def allowlists (c : Config) : List (String × List (String × String)) :=
  let lasm (xs : List (String × String)) := if c.layers.lasm then xs else []
  [("agents", [("kit", include_str "../docker/proxy/allow-agents.txt"),
               ("lean", include_str "../layers/lean/proxy/allow-agents.txt")] ++
              lasm [("lasm", include_str "../layers/lasm/proxy/allow-agents.txt")] ++
              [("project", "\n".intercalate c.allowAgents ++ "\n")]),
   ("ci", [("kit", include_str "../docker/proxy/allow-ci.txt"),
           ("lean", include_str "../layers/lean/proxy/allow-ci.txt")] ++
          lasm [("lasm", include_str "../layers/lasm/proxy/allow-ci.txt")] ++
          [("project", "\n".intercalate c.allowCi ++ "\n")]),
   ("forge", [("kit", include_str "../docker/proxy/allow-forge.txt")])]

/-- A value a shell script can source. -/
def quote (s : String) : String := "'" ++ s.replace "'" "'\\''" ++ "'"

def owners (c : Config) : List String :=
  match c.forge with
  | .forgejo (some m) _ => m.owner :: m.formerOwners
  | .forgejo none _ => []
  | .github owner => [owner]

def projectEnv (c : Config) (s : Settings) : String :=
  let mirror := match c.forge with | .forgejo (some m) _ => some m | _ => none
  let v (n x : String) := s!"{n}={quote x}"
  "\n".intercalate
    [v "PROJECT_NAME" c.name, v "COORDINATION" c.coordination,
     v "TOP_LAYER" (if c.layers.lasm then "lasm" else "lean"),
     v "REPOSITORIES" (" ".intercalate c.repoNames),
     v "GH_OWNERS" (" ".intercalate (owners c)),
     v "MIRROR_OWNER" ((mirror.map (·.owner)).getD ""),
     v "MIRROR_BRANCHES" ((mirror.map (",".intercalate ·.branches)).getD ""),
     v "COORDINATOR" ((c.coordinator?.map (·.name)).getD ""),
     v "REVIEWER" ((c.reviewer?.map (·.name)).getD ""),
     v "SUPERVISOR" ((c.supervisor?.map (·.name)).getD ""),
     v "MILESTONE_REVIEWERS" (" ".intercalate (c.milestoneReviewers.map (·.name))),
     v "LIBRARIES" (" ".intercalate (c.agents.filterMap fun a =>
       if a.kind == .library || a.kind == .site then a.owns else none)),
     v "SEED_FROM" (c.template.seedFrom.getD ""),
     v "RERUN_LIMIT" (toString c.bounds.rerunLimit), v "REVIEW_ROUNDS" (toString c.bounds.reviewRounds),
     v "MAX_RUN_MINUTES" (toString c.bounds.maxRunMinutes),
     v "CI_IMAGE" s.ciImage, v "TOOLCHAIN_VOLUME" s.toolchainVolume] ++ "\n"

/-- The agents' git rules: the project's repositories keep their GitHub URLs in lakefiles and manifests,
under every owner they have had, and are fetched from the forge. -/
def gitconfig (c : Config) (s : Settings) : String :=
  String.join (c.repoNames.map fun r =>
    s!"[url \"http://forgejo:3000/{s.forgeOrg}/{r}\"]\n" ++
      String.join ((owners c).map fun o => s!"\tinsteadOf = https://github.com/{o}/{r}\n"))

/-- Each agent's service, with the volumes they share: compose reads it beside `compose.yaml`.
The volumes keep the reference's names, so a switch finds each agent's workspace, Claude
configuration and run archive. -/
def composeAgents (c : Config) : String :=
  let names := " ".intercalate c.agentNames
  let head := s!"# Generated by the kit from the project's configuration: don't edit.

x-agent: &agent
  image: $\{COMPOSE_PROJECT_NAME:-guild}-agent-$\{TOP_LAYER:-lean}:1
  init: true
  # The image's agent user, whose IDs are the host user's: with every capability dropped, root
  # couldn't write the agent's own files.
  user: \"$\{HOST_UID:-1000}:$\{HOST_GID:-1000}\"
  restart: unless-stopped
  networks: [agents]
  depends_on:
    archive-init: \{ condition: service_completed_successfully }
    proxy: \{ condition: service_started }
    dispatcher: \{ condition: service_started }
  cap_drop: [ALL]
  security_opt: [\"no-new-privileges:true\"]
  # A run that runs away fails in its own container, not in the forge or the host.
  mem_limit: $\{AGENT_MEMORY:-16g}
  memswap_limit: $\{AGENT_MEMORY:-16g}
  pids_limit: $\{AGENT_PIDS:-4096}
  cpus: $\{AGENT_CPUS:-6}
  oom_score_adj: 500
  working_dir: /workspace
  # The Claude credential, which scripts/up.sh writes from secrets/claude/oauth-token.
  env_file:
    - path: $\{STATE_DIR:-.}/secrets/claude/agent.env
      required: false

x-agent-env: &agent-env
  HTTPS_PROXY: http://proxy:3128
  HTTP_PROXY: http://proxy:3128
  https_proxy: http://proxy:3128
  http_proxy: http://proxy:3128
  NO_PROXY: forgejo,dispatcher,gatekeeper,localhost,127.0.0.1
  no_proxy: forgejo,dispatcher,gatekeeper,localhost,127.0.0.1
  NODE_USE_ENV_PROXY: \"1\"
  FORGE_ORG: $\{FORGE_ORG}
  HUMAN_USER: $\{HUMAN_USER}
  TRUSTED_AUTHORS: $\{HUMAN_USER} {names} gatekeeper dispatcher
  COORDINATOR: $\{COORDINATOR:-}
  REVIEWER: $\{REVIEWER:-}
  SUPERVISOR: $\{SUPERVISOR:-}
  RERUN_LIMIT: $\{RERUN_LIMIT:-1}
  REVIEW_ROUNDS: $\{REVIEW_ROUNDS:-3}
  MAX_RUN_MINUTES: $\{MAX_RUN_MINUTES:-240}
  WORKSPACE_STATE: $\{WORKSPACE_STATE:-.guild}
  CONTROL_DIR: /etc/guild/control

services:
  # Each agent's folder in the run archive, owned by the agents' user, before any agent starts.
  archive-init:
    image: alpine:3.24
    network_mode: none
    entrypoint: [\"sh\", \"-c\", \"for a in {names}; do mkdir -p /archive/$$a; chown $\{HOST_UID:-1000}:$\{HOST_GID:-1000} /archive/$$a; done\"]
    volumes:
      - run-archive:/archive
"
  let service (a : Agent) : String :=
    let own := a.owns.getD ""
    s!"
  {a.name}:
    <<: *agent
    hostname: {a.name}
" ++ (if a.kind == .coordinator then "    # It alone shares a network with the gatekeeper, which it asks for releases.\n    networks: [agents, gate-coord]\n" else "") ++
    s!"    environment:
      <<: *agent-env
      AGENT_NAME: {a.name}
      AGENT_REPO: \"{own}\"
" ++ (if a.owns.isNone then s!"      AGENT_WORKSPACE: /workspace/{a.name}\n" else "") ++
    s!"      GIT_AUTHOR_NAME: {a.name}
      GIT_AUTHOR_EMAIL: {a.name}@noreply.localhost
      GIT_COMMITTER_NAME: {a.name}
      GIT_COMMITTER_EMAIL: {a.name}@noreply.localhost
    volumes:
      - $\{STATE_DIR:-.}/secrets/{a.name}/token:/run/secrets/forgejo_token:ro
      - $\{STATE_DIR:-.}/secrets/runner-keys/{a.name}:/run/secrets/runner_key:ro
" ++ (if a.kind == .coordinator then "      - ${STATE_DIR:-.}/secrets/gatekeeper/coordinator-key:/run/secrets/gatekeeper_key:ro\n" else "") ++
    s!"      - $\{STATE_DIR:-.}/control:/etc/guild/control:ro
      - $\{KIT_CONFIG:?}/instructions/{a.name}.md:/etc/claude-code/CLAUDE.md:ro
      - $\{KIT_CONFIG:?}/gitconfig:/etc/guild/gitconfig:ro
      - work-{a.name}:/workspace
      - claude-{a.name}:/home/agent/.claude
      - agent-elan:/home/agent/.elan
      - type: volume
        source: run-archive
        target: /var/lib/guild/archive
        volume: \{ subpath: {a.name} }
" ++ (if a.kind == .supervisor then "      # Every agent's runs and the human's sessions, for supervision.\n      - type: volume\n        source: run-archive\n        target: /var/lib/guild/archive-all\n        read_only: true\n" else "")
  head ++ String.join (c.agents.map service) ++ "\nvolumes:\n  run-archive:\n  agent-elan:\n" ++
    String.join (c.agents.map fun a => s!"  work-{a.name}:\n  claude-{a.name}:\n")

def tsv (rows : List (List String)) : String :=
  String.join (rows.map (fun r => "\t".intercalate r ++ "\n"))

def checksYml (c : Config) (s : Settings) : Except String String := do
  let ctx : Context :=
    { vars := [("CI_IMAGE", s.ciImage), ("TOOLCHAIN_VOLUME", s.toolchainVolume),
               ("REQUIRE_LASM", s.requireLasmVar)]
      flags := []
      inserts := if c.layers.lasm then lasmChecks.map (fun (n, b) => (s!"lasm:{n}", b)) else [] }
  return (← render ctx checks).1

/-- Every file the kit's scripts read, as its path within the export and its content. -/
def files (p : Project) (s : Settings) (text : Protocol.Text) : Except String (List (String × String)) := do
  let c := p.config
  let isSite (r : String) := (c.owner? r).any (·.kind == .site)
  let instructions ← c.agents.mapM (fun a => do
    return (s!"instructions/{a.name}.md", ← Protocol.assemble p s text a.name))
  return (
    [("project.env", projectEnv c s),
     ("config.json", (Json.toJson c).pretty),
     ("compose.agents.yaml", composeAgents c),
     ("agents.tsv", tsv (c.agents.map (fun a =>
       [a.name, Kind.label a.kind, a.owns.getD "-",
        match a.filesOn with | .all => "*" | .only rs => ",".intercalate rs]))),
     ("repos.tsv", tsv (c.repositories.map (fun r =>
       [r.name, toString r.level, if r.name == c.coordination then "0" else "1",
        if isSite r.name then "1" else "0"]))),
     ("runner.yml", runner s),
     ("gitconfig", gitconfig c s),
     ("templates/repo/.forgejo/workflows/checks.yml", ← checksYml c s),
     ("templates/repo/scripts/check-pins.sh", checkPins),
     ("templates/repo/.forgejo/issue_template/request.md", request),
     ("templates/site/.github/workflows/pages.yml", pages)] ++
    c.repositories.map (fun r => (s!"labels/{r.name}.tsv",
      tsv ((labels ++ if r.name == c.coordination then coordinationLabels c else []).map
        (fun (n, col, d) => [n, col, d])))) ++
    (← librarySeed c.template) ++
    [1, 2, 3].map (fun l => (s!"codeowners/{l}", codeowners c s l)) ++
    (allowlists c).flatMap (fun (proxy, lists) =>
      lists.map (fun (layer, body) => (s!"allow/{proxy}/{layer}.txt", body))) ++
    instructions)

def exportTo (p : Project) (s : Settings) (text : Protocol.Text) (dir : System.FilePath) :
    IO UInt32 := do
  match files p s text with
  | .error e => IO.eprintln s!"kit: {e}"; return 1
  | .ok fs =>
    -- Running containers bind-mount these files, and every script exports again: a file
    -- replaced rather than rewritten in place would vanish from under them.
    let paths := fs.map fun (path, _) => dir / path
    if ← dir.pathExists then
      for f in ← dir.walkDir do
        if !(← f.isDir) && !paths.contains f then IO.FS.removeFile f
    for (path, body) in fs do
      let f := dir / path
      if let some d := f.parent then IO.FS.createDirAll d
      let same ← if ← f.pathExists then pure ((← IO.FS.readFile f) == body) else pure false
      unless same do IO.FS.writeFile f body
    return 0

/-- The kit's command line, for a project's `main`. -/
def main (p : Project) (text : Protocol.Text) (args : List String) : IO UInt32 := do
  let s ← match ← Settings.fromEnv with
    | .ok s => pure s
    | .error es => do
      for e in es do IO.eprintln s!"kit: {e}"
      return 1
  match args with
  | ["check"] =>
    let errs := Protocol.check p s text
    for e in errs do IO.eprintln s!"kit: {e}"
    return if errs.isEmpty then 0 else 1
  | ["export", dir] =>
    let errs := Protocol.check p s text
    if !errs.isEmpty then
      for e in errs do IO.eprintln s!"kit: {e}"
      return 1
    exportTo p s text dir
  | _ =>
    IO.eprintln "usage: kit check | kit export DIR"
    return 2

end Guild.Kit
