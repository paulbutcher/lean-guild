/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
module

public import Guild.Gatekeeper
public import Guild.Control
public import Guild.Forge.Forgejo
public import RoutingStd

/-! The gatekeeper as a service. Webhooks (`POST /hook`, signed with the hook's secret) say which
pull request to look at; every `sweep` seconds, on start and when the kit is resumed, it looks at
every open pull request, so a missed webhook delays an approval rather than losing it. The
coordinator asks for a release with `POST /release` and a key only its container holds. While the
kit is paused it approves and releases nothing. -/

@[expose] public section

namespace Guild.Gatekeeper

open Guild.Forge Guild.Version Json

structure Env where
  forge : Forge
  org : String
  /-- The gatekeeper's own account. -/
  me : String
  coordinator : String
  /-- The CI workflow whose run must succeed, by its file name. -/
  workflow : String
  control : System.FilePath
  log : String → IO Unit

inductive Job where
  | sweep
  /-- A pull request, or with `none` every open one in the repository. -/
  | look (repo : Repo) (n : Option Nat)
  deriving BEq, Repr

structure State where
  /-- Each repository's level, with the commit of `main` it was read at. -/
  levels : IO.Ref (List (Repo × String × Nat))
  /-- What was last logged of each pull request, to log each change once. -/
  seen : IO.Ref (List ((Repo × Nat) × String × Ci))
  /-- Waiting work, in order; a job already waiting isn't queued again. -/
  queue : Std.Mutex (Array Job)
  releasing : Std.Mutex Unit

def State.new : BaseIO State := do
  return { levels := ← IO.mkRef [], seen := ← IO.mkRef [], queue := ← Std.Mutex.new #[],
           releasing := ← Std.Mutex.new () }

def paused (e : Env) : IO Bool := Control.paused e.control

/-! ## Approvals -/

/-- The first of the code owners files that exists at a commit. -/
def codeowners (e : Env) (repo : Repo) (sha : String) : M (Option String) := do
  for path in codeownersPaths do
    if let some text ← e.forge.file repo path sha then return some text
  return none

/-- A repository's level, from its code owners on `main`; 0 without a `main`. -/
def levelOf (e : Env) (st : State) (repo : Repo) : M Nat := do
  let some main ← e.forge.branch repo "main" | return 0
  if let some (_, sha, l) := (← st.levels.get).find? (·.1 == repo) then
    if sha == main.sha then return l
  let l := level (← codeowners e repo main.sha) e.me e.coordinator
  st.levels.modify fun ls => (repo, main.sha, l) :: ls.filter (·.1 != repo)
  return l

def ciOf (e : Env) (repo : Repo) (sha : String) : M Ci := do
  return ci e.workflow (← e.forge.runs repo sha)

def consider (e : Env) (st : State) (repo : Repo) (p : Pull) : M Unit := do
  if p.baseRef != "main" then return
  if approved e.me p.headSha (← e.forge.reviews repo p.number) then return
  let state ← ciOf e repo p.headSha
  let seen ← st.seen.get
  if seen.lookup (repo, p.number) != some (p.headSha, state) then
    st.seen.set (((repo, p.number), p.headSha, state) :: seen.filter (·.1 != (repo, p.number)))
    e.log s!"{repo}#{p.number} at {p.headSha.take 12}: the CI run is {state.name}"
  if state != .success then return
  -- Again, just before approving.
  if ← paused e then return
  let body := s!"{noReply}\n\nThe CI run for {p.headSha.take 12} succeeded (`{e.workflow}`). " ++
    "Approved by the gatekeeper; this pull request still needs every other review its code owners require."
  e.forge.review repo p.number .approve body p.headSha
  e.log s!"approved {repo}#{p.number} at {p.headSha.take 12}"

/-- A pull request, or every open one, if the repository is at level 2 or 3. -/
def check (e : Env) (st : State) (repo : Repo) (n : Option Nat) : M Unit := do
  if (← levelOf e st repo) < 2 then return
  let pulls ← match n with
    | some n => do pure ((← e.forge.pull repo n).filter (·.isOpen)).toList
    | none => e.forge.pulls repo .open
  for p in pulls do
    if ← paused e then return
    consider e st repo p

def sweep (e : Env) (st : State) : M Unit := do
  for r in ← e.forge.repos do
    if r.archived then continue
    if ← paused e then return
    try check e st r.name none
    catch err => e.log s!"{r.name}: {err}"

def enqueue (st : State) (job : Job) : IO Unit :=
  st.queue.atomically do modify fun q => if q.contains job then q else q.push job

def take (st : State) : IO (Option Job) :=
  st.queue.atomically do
    let q ← get
    if h : 0 < q.size then
      set (q.extract 1 q.size)
      return some q[0]
    return none

/-- One job, if any is waiting. While paused, a job is dropped: resuming sweeps everything. -/
def work (e : Env) (st : State) : IO Bool := do
  let some job ← take st | return false
  if ← paused e then return true
  let r ← match job with
    | .sweep => (sweep e st).run
    | .look repo n => (check e st repo n).run
  if let .error err := r then
    e.log s!"{match job with | .sweep => "sweep" | .look repo n => s!"{repo}#{n.getD 0}"} failed: {err}"
  return true

def worker (e : Env) (st : State) : IO Unit := do
  repeat
    unless ← work e st do IO.sleep 500

/-- A sweep on start, every `every` seconds, and on resuming. Watching the pause file reads
nothing from the forge. -/
def scheduler (e : Env) (st : State) (every : Nat) : IO Unit := do
  e.log s!"approving on {e.workflow} for {e.org}'s level 2 and 3 repositories, on webhooks, and sweeping every {every}s"
  let mut was : Option Bool := none
  let mut next := 0
  repeat
    let now ← IO.monoMsNow
    let p ← paused e
    if was != some p then
      e.log (if p then "paused: approving and releasing nothing" else "running")
      if was == some true then next := 0
      was := some p
    if !p && now ≥ next then
      enqueue st .sweep
      next := now + every * 1000
    IO.sleep 5000

/-! ## Releases -/

structure Plan where
  repo : Repo
  sha : String
  previous : Option String
  version : Version
  reason : String
  changelog : Option String
  ci : Ci

def Plan.json (p : Plan) : Json :=
  Json.mkObj [("repo", toJson p.repo), ("sha", toJson p.sha), ("previous", toJson p.previous),
    ("version", toJson (Version.tag p.version)), ("reason", toJson p.reason),
    ("changelog", toJson p.changelog), ("ci", toJson p.ci.name)]

/-- What a release of a repository would be, or why there can't be one. -/
def plan (e : Env) (repo : Repo) : M (Except String Plan) := do
  let some main ← e.forge.branch repo "main" | return .error s!"{repo} has no main branch"
  let prev := lastTag (← e.forge.tags repo)
  if let some (t, _) := prev then
    if t.sha == main.sha then return .error s!"main is already released as {t.name}: nothing to release"
  let some lock ← e.forge.file repo "API.lock" main.sha
    | return .error s!"{repo} has no API.lock on main, so the version can't be computed"
  let old ← match prev with
    | some (t, _) => e.forge.file repo "API.lock" t.name
    | none => pure none
  let pv := prev.map (·.2)
  let version := next pv (old.getD "") lock
  let changelog := (← e.forge.file repo "CHANGELOG.md" main.sha).bind (changelogEntry · version)
  return .ok { repo, sha := main.sha, previous := prev.map (·.1.name), version,
               reason := reason pv (old.getD "") lock, changelog, ci := ← ciOf e repo main.sha }

structure Released where
  plan : Plan
  url : String
  issues : List Nat

def Released.json (r : Released) : Json :=
  match r.plan.json with
  | .obj fields => .obj (fields ++ #[("url", toJson r.url), ("issues", toJson r.issues)])
  | j => j

def capitalise (s : String) : String :=
  match s.toList with
  | c :: rest => String.ofList (c.toUpper :: rest)
  | [] => s

/-- Tags `main`'s head with the computed version and publishes the release, or says why not. The
human's own release (`byHuman`) is at any level and while paused. -/
def release (e : Env) (st : State) (repo : Repo) (note : String) (issues : List Nat) (byHuman : Bool) :
    M (Except String Released) := do
  st.releasing.atomically do
    -- First, so a short name isn't refused as below level 3, which its missing code owners
    -- would otherwise say.
    unless ← e.forge.repoExists repo do
      let like := (← e.forge.repos).filter (·.name.endsWith s!"-{repo}") |>.map (·.name)
      return .error (s!"there is no repository {e.org}/{repo}" ++
        if like.isEmpty then "" else s!": did you mean {" or ".intercalate like}?")
    if !byHuman then
      if ← paused e then return .error "the kit is paused: nothing is released until the human resumes it"
      if (← levelOf e st repo) < 3 then return .error s!"{repo} isn't at autonomy level 3: the human releases it"
    let p ← match ← plan e repo with
      | .ok p => pure p
      | .error m => return .error m
    let tag := Version.tag p.version
    let some entry := p.changelog | do
      let hs := headings (((← e.forge.file repo "CHANGELOG.md" p.sha).getD ""))
      return .error (s!"CHANGELOG.md on main has no entry for {tag} ({p.reason}); its headings: " ++
        if hs.isEmpty then "none" else ", ".intercalate (hs.take 5))
    if p.ci != .success then
      return .error s!"the CI run for main's head ({p.sha.take 12}) is {p.ci.name}"
    let mut found : List Issue := []
    for n in issues do
      let some i ← e.forge.issue repo n | return .error s!"{repo}#{n} isn't an issue"
      if i.isPull then return .error s!"{repo}#{n} isn't an issue"
      if !i.isOpen || !i.labels.contains "ready-for-release" then
        return .error s!"{repo}#{n} isn't an open issue labelled ready-for-release"
      found := found ++ [i]
    let body := note.trimAscii.toString ++ "\n\n" ++ entry ++
      (if found.isEmpty then "" else "\n\nIssues: " ++ ", ".intercalate (found.map (s!"#{·.number}"))) ++
      s!"\n\n{capitalise p.reason}."
    let url ← e.forge.createRelease repo { tag, target := p.sha, name := tag, body }
    for i in found do
      e.forge.comment repo i.number s!"{noReply}\n\nReleased in {tag}: {url}"
      e.forge.removeLabel repo i.number "ready-for-release"
      -- An issue that isn't a request, such as an owner's task for itself, has no requester to
      -- verify it: the release ends it.
      unless i.labels.contains "request" do e.forge.close repo i.number
    e.log s!"released {repo} {tag} at {p.sha.take 12} ({if byHuman then "the human" else "the coordinator"}): {p.reason}"
    return .ok { plan := p, url, issues := found.map (·.number) }

/-! ## HTTP -/

open Std Std.Async Std.Http Routing

def reply (status : Http.Status) (j : Json) : ContextAsync (Response Body.Any) :=
  ServerEngine.bytes (e := .std)
    ((Response.withStatus status).header Header.Name.contentType (.mk "application/json")) j.compress.toUTF8

def errorReply (status : Http.Status) (m : String) : ContextAsync (Response Body.Any) :=
  reply status (Json.mkObj [("error", toJson m)])

def header (req : Request Body.Stream) (name : String) : Option String :=
  (Header.Name.ofString? name).bind (req.line.headers.get? ·) |>.map toString

def readSecret (path : System.FilePath) : IO String := do
  try return (← IO.FS.readFile path).trimAscii.toString
  catch _ => return ""

structure Keys where
  webhookSecret : System.FilePath
  coordinatorKey : System.FilePath

def maxHook : Nat := 4 * 1024 * 1024

/-- A webhook: where to look, queued. A finished run is looked at again a little later, in case
the runs API lags its event. -/
def onHook (e : Env) (st : State) (keys : Keys) (req : Request Body.Stream) :
    ContextAsync (Response Body.Any) := do
  let .ok body ← ServerEngine.readBody (e := .std) req.body maxHook
    | errorReply .payloadTooLarge "too large"
  let secret ← readSecret keys.webhookSecret
  unless Forgejo.signed secret body ((header req "x-forgejo-signature").getD "") do
    e.log "refused a webhook with a bad signature"
    return ← errorReply .forbidden "bad signature"
  let some text := String.fromUTF8? body | errorReply .badRequest "not UTF-8"
  let .ok payload := parse text | errorReply .badRequest "not JSON"
  let kind := ((header req "x-forgejo-event-type").orElse fun _ => header req "x-forgejo-event").getD ""
  let jobs := ((Forgejo.hook kind payload).map (targets e.org)).getD []
  for (repo, n) in jobs do
    enqueue st (.look repo n)
    if kind.startsWith "action_run" then
      discard <| IO.asTask (do IO.sleep 30000; enqueue st (.look repo n))
  reply .ok (Json.mkObj [])

def validName (repo : String) : Bool :=
  !repo.isEmpty && repo.all fun c => c.isAlphanum || c == '-' || c == '_' || c == '.'

def onRelease (e : Env) (st : State) (keys : Keys) (req : Request Body.Stream) :
    ContextAsync (Response Body.Any) := do
  let given := (((header req "authorization").getD "").dropPrefix "Bearer ").toString.trimAscii.toString
  let want ← readSecret keys.coordinatorKey
  if want.isEmpty || !Leancrypto.bytesEqual given.toUTF8 want.toUTF8 then
    return ← errorReply .forbidden "only the coordinator asks the gatekeeper for releases"
  let .ok body ← ServerEngine.readBody (e := .std) req.body 65536 | errorReply .payloadTooLarge "too large"
  let request : Except String (String × String × List Nat) := do
    let j ← (parse ((String.fromUTF8? body).getD "")).mapError toString
    let repo ← (j.getObjVal? "repo").bind (·.getStr?)
    let note := ((j.getObjVal? "note").bind (·.getStr?)).toOption.getD ""
    let issues ← match j.getObjVal? "issues" with
      | .ok .null | .error _ => pure []
      | .ok v => fromJson? (α := List Nat) v
    if !validName repo || note.trimAscii.isEmpty then throw "a repository name and a note are required"
    return (repo, note, issues)
  let (repo, note, issues) ← match request with
    | .ok r => pure r
    | .error m => return ← errorReply .badRequest s!"bad request: {m}"
  match ← (release e st repo note issues false).run with
  | .ok (.ok r) => reply .ok r.json
  | .ok (.error m) =>
    e.log s!"refused to release {repo}: {m}"
    errorReply .conflict m
  | .error err =>
    e.log s!"releasing {repo} failed: {err}"
    errorReply .badGateway s!"the forge: {err}"

route_table Routes
  [ health := "/healthz",
    hook := "/hook",
    release := "/release" ]

def app (e : Env) (st : State) (keys : Keys) : StatelessHandler .std :=
  toHandler (h := by routes_unshadowed +kernel)
    [ .get Routes.patterns.health (fun _ => reply .ok (Json.mkObj [("ok", toJson true)])),
      .post Routes.patterns.hook (onHook e st keys),
      .post Routes.patterns.release (onRelease e st keys) ]

end Guild.Gatekeeper
