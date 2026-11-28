/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
module

public import Guild.Forge
public import Json
public import Leancurl
import JsonDeriving
public import Leancrypto.Codec.Base64
public import Leancrypto.Codec.Hex
public import Leancrypto.Hmac
public import Leancrypto.Compare

/-! The Forgejo adapter, over its HTTP API. -/

@[expose] public section

namespace Guild.Forge.Forgejo

open Json

structure Conn where
  /-- Forgejo's base URL, such as `http://forgejo:3000`. -/
  url : String
  org : String
  account : String
  token : String

/-! ## Forgejo's JSON, as far as the kit reads it -/

structure RawUser where
  login : String
  deriving FromJson

structure RawLabel where
  id : Nat
  name : String
  deriving FromJson

structure RawTitle where
  title : String
  deriving FromJson

structure RawIssue where
  number : Nat
  title : String
  body : Option String
  user : RawUser
  labels : Option (Array RawLabel)
  assignees : Option (Array RawUser)
  state : String
  created_at : String
  updated_at : String
  closed_at : Option String
  pull_request : Option Json
  milestone : Option RawTitle
  deriving FromJson

structure RawRef where
  ref : String
  sha : String
  deriving FromJson

structure RawPull where
  number : Nat
  title : String
  body : Option String
  user : RawUser
  state : String
  merged : Bool
  head : RawRef
  base : RawRef
  mergeable : Option Bool
  requested_reviewers : Option (Array RawUser)
  created_at : String
  updated_at : String
  merged_at : Option String
  merge_commit_sha : Option String
  deriving FromJson

structure RawReview where
  id : Nat
  user : Option RawUser
  state : String
  commit_id : String
  dismissed : Option Bool
  stale : Option Bool
  submitted_at : String
  body : Option String
  deriving FromJson

structure RawComment where
  id : Nat
  user : Option RawUser
  body : String
  created_at : String
  deriving FromJson

structure RawEntry where
  type : String
  id : Nat
  user : Option RawUser
  created_at : String
  body : Option String
  label : Option RawLabel
  assignee : Option RawUser
  removed_assignee : Option Bool
  deriving FromJson

structure RawStatus where
  context : String
  status : String
  updated_at : String
  deriving FromJson

structure RawCombined where
  statuses : Option (Array RawStatus)
  deriving FromJson

structure RawRun where
  id : Nat
  workflow_id : String
  status : String
  commit_sha : String
  event : String
  created : String
  deriving FromJson

structure RawJob where
  id : Nat
  name : String
  status : String
  attempt : Nat
  deriving FromJson

structure RawRelease where
  tag_name : String
  draft : Bool
  published_at : Option String
  deriving FromJson

structure RawSha where
  sha : String
  deriving FromJson

structure RawTag where
  name : String
  commit : RawSha
  deriving FromJson

structure RawMilestone where
  title : String
  state : String
  open_issues : Nat
  closed_issues : Nat
  deriving FromJson

structure RawBranchCommit where
  id : String
  timestamp : String
  deriving FromJson

structure RawBranch where
  commit : RawBranchCommit
  deriving FromJson

structure RawContent where
  type : String
  content : Option String
  sha : String
  deriving FromJson

structure RawRepo where
  name : String
  archived : Bool
  deriving FromJson

structure RawNumber where
  number : Nat
  deriving FromJson

structure RawCommitted where
  commit : RawSha
  deriving FromJson

structure RawMessage where
  message : String
  deriving FromJson

structure RawPullCommit where
  commit : RawMessage
  deriving FromJson

structure RawFile where
  filename : String
  deriving FromJson

structure RawCompared where
  sha : String
  files : Option (Array RawFile)
  deriving FromJson

structure RawCompare where
  commits : Option (Array RawCompared)
  deriving FromJson

structure RawUrl where
  html_url : String
  deriving FromJson

structure RawError where
  message : Option String
  deriving FromJson

/-! ## Conversions -/

def login (u : Option RawUser) : String := (u.map (·.login)).getD ""

def RawIssue.toIssue (r : RawIssue) : Issue :=
  { number := r.number, isPull := r.pull_request.isSome, isOpen := r.state == "open",
    title := r.title, body := r.body.getD "", author := r.user.login,
    labels := ((r.labels.getD #[]).map (·.name)).toList,
    assignees := ((r.assignees.getD #[]).map (·.login)).toList,
    createdAt := r.created_at, updatedAt := r.updated_at, closedAt := r.closed_at,
    milestone := r.milestone.map (·.title) }

def RawPull.toPull (r : RawPull) : Pull :=
  { number := r.number, isOpen := r.state == "open", merged := r.merged, title := r.title,
    body := r.body.getD "", author := r.user.login, headSha := r.head.sha, headRef := r.head.ref,
    baseRef := r.base.ref, mergeable := r.mergeable,
    requestedReviewers := ((r.requested_reviewers.getD #[]).map (·.login)).toList,
    createdAt := r.created_at, updatedAt := r.updated_at, mergedAt := r.merged_at,
    mergeSha := r.merge_commit_sha }

def verdict : String → Verdict
  | "APPROVED" => .approve
  | "REQUEST_CHANGES" => .requestChanges
  | "COMMENT" => .comment
  | s => .other s

def verdictName : Verdict → String
  | .approve => "APPROVED"
  | .requestChanges => "REQUEST_CHANGES"
  | .comment => "COMMENT"
  | .other s => s

def RawReview.toReview (r : RawReview) : Review :=
  { id := r.id, author := login r.user, verdict := verdict r.state, commit := r.commit_id,
    dismissed := r.dismissed.getD false, stale := r.stale.getD false,
    submittedAt := r.submitted_at, body := r.body.getD "" }

def RawEntry.toEntry (r : RawEntry) : Entry :=
  let event : Event := match r.type with
    | "comment" => .comment r.id (r.body.getD "")
    -- Forgejo marks an addition with the body "1".
    | "label" => match r.label with
      | some l => .label l.name (r.body == some "1")
      | none => .other "label"
    | "close" => .closed
    | "reopen" => .reopened
    | "review" => .review
    | "pull_push" => .push
    | "pull_scheduled_merge" => .scheduleMerge
    | "pull_cancel_scheduled_merge" => .cancelScheduledMerge
    | "review_request" => match r.assignee with
      | some a => .reviewRequest a.login (r.removed_assignee.getD false)
      | none => .other "review_request"
    | "merge_pull" => .merged
    | t => .other t
  { time := r.created_at, actor := login r.user, event }

def statusState : String → StatusState
  | "pending" => .pending | "success" => .success | "failure" => .failure
  | "error" => .error | "warning" => .warning | s => .other s

def runStatus : String → RunStatus
  | "waiting" => .waiting | "running" => .running | "success" => .success
  | "failure" => .failure | "cancelled" => .cancelled | "skipped" => .skipped
  | "blocked" => .blocked | s => .other s

def RawRun.toRun (r : RawRun) : Run :=
  { id := r.id, workflow := r.workflow_id, status := runStatus r.status, sha := r.commit_sha,
    event := r.event, created := r.created }

/-! ## HTTP -/

def unreserved (c : Char) : Bool :=
  c.isAlphanum || c == '-' || c == '.' || c == '_' || c == '~'

def hexDigit (n : Nat) : Char :=
  if n < 10 then Char.ofNat (48 + n) else Char.ofNat (55 + n)

/-- Percent-encoding of a query value or a path segment. -/
def encode (s : String) : String :=
  s.toList.foldl (fun acc c =>
    if unreserved c then acc.push c
    else (String.singleton c).toUTF8.foldl (fun a b =>
      (a.push '%').push (hexDigit (b.toNat / 16)) |>.push (hexDigit (b.toNat % 16))) acc) ""

def encodePath (path : String) : String := "/".intercalate ((path.splitOn "/").map encode)

def query (params : List (String × String)) : String :=
  if params.isEmpty then "" else "?" ++ "&".intercalate (params.map fun (k, v) => s!"{k}={encode v}")

/-- A request, and the status and body of its answer. -/
def send (c : Conn) (method : Leancurl.Method) (path : String)
    (params : List (String × String) := []) (body : Option Json := none) : M (Nat × String) := do
  let headers := [("Authorization", s!"token {c.token}"), ("Accept", "application/json")] ++
    (if body.isSome then [("Content-Type", "application/json")] else [])
  let req : Leancurl.Request :=
    { url := c.url ++ "/api/v1" ++ path ++ query params, method, headers,
      body := body.map (·.compress.toUTF8), timeoutMs := some 60000 }
  match ← Leancurl.Curl.send req with
  | .error e => throw (.transport e.message)
  | .ok r => match String.fromUTF8? r.body with
    | some text => return (r.status.toNat, text)
    | none => throw (.decode s!"{method.toVerb} {path}: the answer isn't UTF-8")

def message (text : String) : String :=
  match parse text with
  | .ok j => match (fromJson? j : Except String RawError) with
    | .ok { message := some m } => m
    | _ => text
  | .error _ => text

/-- The body of an answer with one of the expected statuses. -/
def expect (ok : List Nat) (r : Nat × String) : M String :=
  if ok.contains r.1 then pure r.2 else throw (.status r.1 (message r.2))

def json (text : String) : M Json :=
  match parse text with
  | .ok j => pure j
  | .error e => throw (.decode (toString e))

def decode (α : Type) [FromJson α] (j : Json) : M α :=
  match fromJson? j with
  | .ok a => pure a
  | .error e => throw (.decode e)

def get (c : Conn) (α : Type) [FromJson α] (path : String) (params : List (String × String) := []) :
    M α := do
  decode α (← json (← expect [200] (← send c .get path params)))

/-- `none` for a 404. -/
def find (c : Conn) (α : Type) [FromJson α] (path : String) (params : List (String × String) := []) :
    M (Option α) := do
  let r ← send c .get path params
  if r.1 == 404 then return none
  return some (← decode α (← json (← expect [200] r)))

def pageSize : Nat := 50
def maxPages : Nat := 200

/-- Every item of a paged list, read page by page. Forgejo ignores `page` on some lists and serves
the same page again; that ends the list rather than looping on it. -/
def pages (c : Conn) (α : Type) [FromJson α] (path : String) (params : List (String × String) := [])
    (items : Json → M (Array Json) := fun j => match j with
      | .arr xs => pure xs
      -- An empty list, as Forgejo answers for a new issue's timeline.
      | .null => pure #[]
      | _ => throw (.decode s!"{path}: not a list")) : M (List α) := do
  let mut out : Array Json := #[]
  let mut last : Option (Array Json) := none
  for page in List.range maxPages do
    let j ← json (← expect [200] (← send c .get path
      (params ++ [("limit", toString pageSize), ("page", toString (page + 1))])))
    let batch ← items j
    if last == some batch then break
    out := out ++ batch
    if batch.size < pageSize then break
    last := some batch
  out.toList.mapM (decode α)

def repoPath (c : Conn) (repo : Repo) : String := s!"/repos/{c.org}/{encode repo}"

def which : Which → String
  | .open => "open" | .closed => "closed" | .all => "all"

def labelIds (c : Conn) (repo : Repo) (names : List String) : M (List Nat) := do
  let all ← pages c RawLabel (repoPath c repo ++ "/labels")
  names.mapM fun n => match all.find? (·.name == n) with
    | some l => pure l.id
    | none => throw (.status 422 s!"{repo} has no label {n}")

def write (c : Conn) (method : Leancurl.Method) (path : String) (body : Option Json) (ok : List Nat) :
    M String := do
  expect ok (← send c method path [] body)

def runsOf (j : Json) : M (Array Json) :=
  match j.getObjVal? "workflow_runs" with
  | .ok (.arr xs) => pure xs
  | .ok .null => pure #[]
  | _ => match j with
    | .arr xs => pure xs
    | _ => throw (.decode "actions/runs: no workflow_runs")

def newestFirst (rs : List Run) : List Run :=
  (rs.toArray.qsort (fun a b => a.id > b.id)).toList

def fileText (r : RawContent) : M (Option String) :=
  match r.type, r.content with
  | "file", some content => match Leancrypto.Codec.Base64.decodeString content with
    | some bytes => match String.fromUTF8? bytes with
      | some t => pure (some t)
      | none => throw (.decode "the file isn't UTF-8")
    | none => throw (.decode "the file's content isn't base64")
  | _, _ => pure none

/-- A file at a ref. For a directory Forgejo answers with a list, and for any path in an empty
repository with an empty one. -/
def content (c : Conn) (repo : Repo) (path ref : String) : M (Option RawContent) := do
  match ← find c Json (repoPath c repo ++ "/contents/" ++ encodePath path) [("ref", ref)] with
  | some (.arr _) | none => return none
  | some j => return some (← decode RawContent j)

/-! ## The adapter -/

def connect (c : Conn) : Forge where
  account := c.account
  repos := do
    let rs ← pages c RawRepo s!"/orgs/{c.org}/repos"
    return rs.map fun r => { name := r.name, archived := r.archived }
  repoExists repo := do return (← find c RawRepo (repoPath c repo)).isSome
  branch repo name := do
    let b ← find c RawBranch (repoPath c repo ++ "/branches/" ++ encode name)
    return b.map fun b => { sha := b.commit.id, timestamp := b.commit.timestamp }
  file repo path ref := do
    match ← content c repo path ref with
    | some r => fileText r
    | none => return none
  issue repo n := do
    return (← find c RawIssue (repoPath c repo ++ s!"/issues/{n}")).map (·.toIssue)
  issues repo q := do
    let kinds := match q.kinds with
      | .issues => [("type", "issues")] | .pulls => [("type", "pulls")] | .all => []
    let params := [("state", which q.which)] ++ kinds ++
      (if q.labels.isEmpty then [] else [("labels", ",".intercalate q.labels)]) ++
      (match q.since with | some s => [("since", s)] | none => [])
    let all ← pages c RawIssue (repoPath c repo ++ "/issues") params
    -- Forgejo ignores a label filter naming a label the repository lacks.
    return (all.map (·.toIssue)).filter fun i =>
      q.labels.all i.labels.contains &&
      (match q.since with | some s => decide (s ≤ i.updatedAt) | none => true)
  labels repo := do
    return (← pages c RawLabel (repoPath c repo ++ "/labels")).map (·.name)
  -- Forgejo serves every comment at once and ignores paging.
  comments repo n := do
    let cs ← get c (Array RawComment) (repoPath c repo ++ s!"/issues/{n}/comments")
    return cs.toList.map fun r =>
      { id := r.id, author := login r.user, body := r.body, createdAt := r.created_at }
  timeline repo n := do
    return (← pages c RawEntry (repoPath c repo ++ s!"/issues/{n}/timeline")).map (·.toEntry)
  pull repo n := do
    return (← find c RawPull (repoPath c repo ++ s!"/pulls/{n}")).map (·.toPull)
  pulls repo w := do
    -- An empty repository answers 404, though it exists: it has no pull requests.
    try return (← pages c RawPull (repoPath c repo ++ "/pulls") [("state", which w)]).map (·.toPull)
    catch
      | .status 404 m => if (← find c RawRepo (repoPath c repo)).isSome then return [] else throw (.status 404 m)
      | err => throw err
  pullCommits repo n := do
    return (← pages c RawPullCommit (repoPath c repo ++ s!"/pulls/{n}/commits")).map (·.commit.message)
  pullFiles repo n := do
    return (← pages c RawFile (repoPath c repo ++ s!"/pulls/{n}/files")).map (·.filename)
  reviews repo n := do
    let rs ← pages c RawReview (repoPath c repo ++ s!"/pulls/{n}/reviews")
    return (rs.map (·.toReview)).mergeSort (fun a b => a.id ≤ b.id)
  statuses repo sha := do
    let r ← get c RawCombined (repoPath c repo ++ s!"/commits/{encode sha}/status")
    return (r.statuses.getD #[]).toList.map fun s =>
      { context := s.context, state := statusState s.status, updatedAt := s.updated_at }
  runs repo sha := do
    let rs ← pages c RawRun (repoPath c repo ++ "/actions/runs") [("head_sha", sha)] runsOf
    return newestFirst ((rs.map (·.toRun)).filter (·.sha == sha))
  activeRuns repo := do
    let running ← pages c RawRun (repoPath c repo ++ "/actions/runs") [("status", "running")] runsOf
    let waiting ← pages c RawRun (repoPath c repo ++ "/actions/runs") [("status", "waiting")] runsOf
    let all := (running ++ waiting).map (·.toRun)
    return newestFirst (all.filter (!·.status.finished))
  jobs repo run := do
    let js ← pages c RawJob (repoPath c repo ++ s!"/actions/runs/{run}/jobs") []
      (fun j => match j with
        | .arr xs => pure xs
        | _ => match j.getObjVal? "jobs" with
          | .ok (.arr xs) => pure xs
          | _ => throw (.decode "actions jobs: not a list"))
    return js.map fun j => { id := j.id, name := j.name, status := runStatus j.status, attempt := j.attempt }
  jobLog repo job := do
    expect [200] (← send c .get (repoPath c repo ++ s!"/actions/jobs/{job}/logs"))
  releases repo := do
    let rs ← pages c RawRelease (repoPath c repo ++ "/releases")
    return rs.map fun r => { tag := r.tag_name, draft := r.draft, publishedAt := r.published_at }
  tags repo := do
    return (← pages c RawTag (repoPath c repo ++ "/tags")).map fun t => { name := t.name, sha := t.commit.sha }
  compare repo base head := do
    let r ← find c RawCompare (repoPath c repo ++ s!"/compare/{encode base}...{encode head}") [("files", "true")]
    return r.map fun r => (r.commits.getD #[]).toList.map fun k =>
      { sha := k.sha, paths := ((k.files.getD #[]).map (·.filename)).toList }
  milestones repo := do
    let ms ← pages c RawMilestone (repoPath c repo ++ "/milestones") [("state", "all")]
    return ms.map fun m =>
      { title := m.title, isOpen := m.state == "open", openIssues := m.open_issues,
        closedIssues := m.closed_issues }
  createIssue repo i := do
    let ids ← labelIds c repo i.labels
    let body := Json.mkObj [("title", i.title), ("body", i.body),
      ("labels", toJson ids),
      ("assignees", toJson i.assignees)]
    let r ← decode RawNumber (← json (← write c .post (repoPath c repo ++ "/issues") body [201]))
    return r.number
  setAssignees repo n as := do
    let body := Json.mkObj [("assignees", toJson as)]
    discard <| write c .patch (repoPath c repo ++ s!"/issues/{n}") body [201]
  close repo n := do
    discard <| write c .patch (repoPath c repo ++ s!"/issues/{n}") (Json.mkObj [("state", "closed")]) [201]
  addLabel repo n name := do
    let ids ← labelIds c repo [name]
    let body := Json.mkObj [("labels", toJson ids)]
    discard <| write c .post (repoPath c repo ++ s!"/issues/{n}/labels") body [200]
  removeLabel repo n name := do
    for id in ← labelIds c repo [name] do
      discard <| write c .delete (repoPath c repo ++ s!"/issues/{n}/labels/{id}") none [204]
  comment repo n text := do
    discard <| write c .post (repoPath c repo ++ s!"/issues/{n}/comments") (Json.mkObj [("body", text)]) [201]
  createPull repo p := do
    let body := Json.mkObj [("head", p.head), ("base", p.base), ("title", p.title), ("body", p.body)]
    let r ← decode RawNumber (← json (← write c .post (repoPath c repo ++ "/pulls") body [201]))
    return r.number
  requestReviewers repo n who := do
    let body := Json.mkObj [("reviewers", toJson who)]
    discard <| write c .post (repoPath c repo ++ s!"/pulls/{n}/requested_reviewers") body [201]
  review repo n v text commit := do
    let body := Json.mkObj [("event", verdictName v), ("body", text), ("commit_id", commit)]
    discard <| write c .post (repoPath c repo ++ s!"/pulls/{n}/reviews") body [200]
  merge repo n schedule := do
    let body := Json.mkObj ([("Do", toJson "squash"), ("delete_branch_after_merge", toJson true)] ++
      (if schedule then [("merge_when_checks_succeed", toJson true)] else []))
    let (status, text) ← send c .post (repoPath c repo ++ s!"/pulls/{n}/merge") [] (some body)
    -- Forgejo answers 201 when it schedules, and 405 while it is still checking mergeability.
    return match status with
      | 200 => .merged
      | 201 => .scheduled
      | 405 => if ((message text).toLower.splitOn "try again later").length > 1 then .tryLater
               else .refused (message text)
      | _ => .refused (message text)
  cancelMerge repo n := do
    discard <| write c .delete (repoPath c repo ++ s!"/pulls/{n}/merge") none [204]
  mergers repo who := do
    let path := repoPath c repo ++ "/branch_protections/main"
    if (← find c Json path).isNone then return
    let body := Json.mkObj [("enable_merge_whitelist", toJson who.isSome),
      ("merge_whitelist_usernames", toJson (who.getD []))]
    discard <| write c .patch path body [200]
  rerun repo run := do
    discard <| write c .post (repoPath c repo ++ s!"/actions/runs/{run}/rerun") none [200, 201, 204]
  createRelease repo r := do
    let body := Json.mkObj [("tag_name", r.tag), ("target_commitish", r.target), ("name", r.name),
      ("body", r.body)]
    let r ← decode RawUrl (← json (← write c .post (repoPath c repo ++ "/releases") body [201]))
    return r.html_url
  commit repo k := do
    let ref := k.start.getD k.branch
    let files ← k.files.mapM fun (path, text) => do
      let existing ← content c repo path ref
      let content : Json := Leancrypto.Codec.Base64.encodeString text.toUTF8
      return match existing with
        | some e => Json.mkObj [("operation", "update"), ("path", path), ("content", content), ("sha", e.sha)]
        | none => Json.mkObj [("operation", "create"), ("path", path), ("content", content)]
    let target := match k.start with
      | some s => [("branch", (s : Json)), ("new_branch", (k.branch : Json))]
      | none => [("branch", (k.branch : Json))]
    let body := Json.mkObj (target ++ [("message", toJson k.message), ("files", toJson files)])
    let r ← decode RawCommitted (← json (← write c .post (repoPath c repo ++ "/contents") body [201]))
    return r.commit.sha

/-! ## Webhooks -/

/-- Whether a webhook's `X-Forgejo-Signature`, the hex HMAC-SHA256 of its body under the hook's
secret, is right. An empty secret accepts nothing. -/
def signed (secret : String) (body : ByteArray) (signature : String) : Bool :=
  !secret.isEmpty &&
    Leancrypto.bytesEqual
      (Leancrypto.Codec.Hex.encodeString (Leancrypto.hmac .sha256 secret.toUTF8 body)).toUTF8
      signature.toLower.toUTF8

def field (j : Json) (path : List String) : Option Json :=
  path.foldlM (fun j k => (j.getObjVal? k).toOption) j

def text? (j : Json) (path : List String) : Option String :=
  (field j path).bind fun v => v.getStr?.toOption

def nat? (j : Json) (path : List String) : Option Nat :=
  (field j path).bind fun v => v.getNat?.toOption

/-- A webhook, from its kind (`X-Forgejo-Event-Type`, or `X-Forgejo-Event` without it) and its
payload. `none` when it names no repository. -/
def hook (kind : String) (payload : Json) : Option Hook := do
  -- An Actions run carries its repository inside the run.
  let repoJson ← (field payload ["repository"]).orElse fun _ => field payload ["run", "repository"]
  let repo ← text? repoJson ["name"]
  let owner := (text? repoJson ["owner", "login"]).getD ""
  let action := (text? payload ["action"]).getD ""
  let event : HookEvent :=
    if kind.startsWith "action_run" then
      -- The run's event payload is a JSON string of its own.
      let inner := (text? payload ["run", "event_payload"]).bind fun s => (parse s).toOption
      .runFinished (inner.bind fun j => nat? j ["pull_request", "number"])
    else match kind, nat? payload ["pull_request", "number"] with
      | "pull_request_sync", some n => .pullPushed n
      | "pull_request", some n =>
        if action == "opened" || action == "reopened" then .pullOpened n else .other kind action
      | "push", _ => .push ((text? payload ["ref"]).getD "")
      | _, _ => .other kind action
  return { owner, repo, event }

end Guild.Forge.Forgejo
