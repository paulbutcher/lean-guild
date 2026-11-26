/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
module

public import Guild.Dispatcher.Hooks
public import Guild.Forge.Forgejo
public import RoutingStd

/-! The dispatcher as a service:

* `POST /hook`: the forge's webhooks, signed with the webhook secret.
* `POST /claim`, `/runs/<id>/start`, `/runs/<id>/end`, `/runs/abandon`, `/sessions`: the agents'
  runners, each with its runner key as a bearer token.
* `POST /admin/drop`, `/admin/reconcile`, `/admin/notices/<id>/seen`: the human's web UI and
  scripts, with the admin key.
* `GET /status`, `/activity`, `/reviews`, `/notices.txt`, `/healthz`: for the human's pages;
  `/ledger` for the supervisor and the milestone reviewers.

Every minute it closes runs no runner started, moves obligations on, checks CI where a webhook
marked it, and checks for a quiet kit; every `reconcile` seconds it sweeps; every few seconds it
evaluates the units whose timers have run out. -/

@[expose] public section

namespace Guild.Dispatcher

open Json Std Std.Async Std.Http Routing

def reply (status : Http.Status) (j : Json) : ContextAsync (Response Body.Any) :=
  ServerEngine.bytes (e := .std)
    ((Response.withStatus status).header Header.Name.contentType (.mk "application/json")) (j.pretty 1 ++ "\n").toUTF8

def replyText (text : String) : ContextAsync (Response Body.Any) :=
  ServerEngine.bytes (e := .std)
    ((Response.withStatus .ok).header Header.Name.contentType (.mk "text/plain; charset=utf-8")) text.toUTF8

def noContent : ContextAsync (Response Body.Any) :=
  ServerEngine.bytes (e := .std) (Response.withStatus .noContent) ByteArray.empty

def errorReply (status : Http.Status) (m : String) : ContextAsync (Response Body.Any) :=
  reply status (Json.mkObj [("error", toJson m)])

def header (req : Request Body.Stream) (name : String) : Option String :=
  (Header.Name.ofString? name).bind (req.line.headers.get? ·) |>.map toString

def bearer (req : Request Body.Stream) : String :=
  (((header req "authorization").getD "").dropPrefix "Bearer ").toString.trimAscii.toString

/-- A query parameter, undecoded: the dispatcher's are numbers. -/
def queryParam (req : Request Body.Stream) (name : String) : Option String :=
  match (toString req.line.uri).splitOn "?" with
  | [_, qs] => (qs.splitOn "&").findSome? fun kv => match kv.splitOn "=" with
    | [k, v] => if k == name then some v else none
    | _ => none
  | _ => none

def readSecret (path : System.FilePath) : IO String := do
  try return (← IO.FS.readFile path).trimAscii.toString
  catch _ => return ""

def maxBody : Nat := 25 * 1024 * 1024

def bodyJson (req : Request Body.Stream) : ContextAsync (Option Json) := do
  let .ok body ← ServerEngine.readBody (e := .std) req.body maxBody | return none
  let text := (String.fromUTF8? body).getD ""
  if text.trimAscii.isEmpty then return some (Json.mkObj [])
  return (parse text).toOption

structure Keys where
  webhookSecret : System.FilePath
  adminKey : System.FilePath

/-- Runs a dispatcher action for a request, logging its error and answering 500. -/
def act (e : Env) (what : String) (k : D (ContextAsync (Response Body.Any))) : ContextAsync (Response Body.Any) := do
  match ← (k.run e).toBaseIO with
  | .ok r => r
  | .error err =>
    e.log s!"error handling {what}: {err}"
    errorReply .internalServerError "internal error"

/-- Keeps a webhook's payload, the newest 500, and a line about it in `events.jsonl`. -/
def save (dir : System.FilePath) (delivery : String) (body : ByteArray) (entry : Json) : IO Unit := do
  let payloads := dir / "payloads"
  IO.FS.createDirAll payloads
  IO.FS.writeBinFile (payloads / s!"{delivery}.json") body
  let files ← payloads.readDir
  if files.size > 500 then
    let dated ← files.mapM fun f => do return (f.path, (← f.path.metadata).modified.sec)
    for (p, _) in (dated.toList.mergeSort (·.2 ≤ ·.2)).take (files.size - 500) do
      try IO.FS.removeFile p catch _ => pure ()
  let h ← IO.FS.Handle.mk (dir / "events.jsonl") .append
  h.putStrLn entry.compress

def onHook (e : Env) (keys : Keys) (req : Request Body.Stream) : ContextAsync (Response Body.Any) := do
  let .ok body ← ServerEngine.readBody (e := .std) req.body maxBody | errorReply .payloadTooLarge "too large"
  let secret ← readSecret keys.webhookSecret
  unless Guild.Forge.Forgejo.signed secret body ((header req "x-forgejo-signature").getD "") do
    e.log "refused a delivery with a bad signature"
    return ← errorReply .forbidden "bad signature"
  let .ok payload := parse ((String.fromUTF8? body).getD "") | errorReply .badRequest "not JSON"
  let event := (header req "x-forgejo-event").getD "?"
  let eventType := (header req "x-forgejo-event-type").getD event
  -- A CI run carries its repository inside the run, and has no sender.
  let payload := match path? payload ["run"], payload with
    | some run, .obj fs =>
      let fs := if fs.any (·.1 == "repository") then fs else fs.push ("repository", (path? run ["repository"]).getD (Json.mkObj []))
      .obj (if fs.any (·.1 == "sender") then fs else fs.push ("sender", Json.mkObj [("login", toJson "ci")]))
    | _, p => p
  let t ← e.now
  let delivery := String.ofList (((header req "x-forgejo-delivery").getD (toString (← IO.monoNanosNow))).toList.filter
    fun c => c.isAlphanum || c == '-')
  let repo := str? payload ["repository", "name"]
  let sender := str? payload ["sender", "login"]
  let number := nat? (itemOfPayload payload) ["number"]
  let action := str? payload ["action"]
  let detail ← match ← ((eventDetail eventType payload ((repo).getD "") number).run e).toBaseIO with
    | .ok d => pure (some d.compress)
    | .error err => do e.log s!"couldn't summarise a {eventType} event: {err}"; pure none
  e.db.exec "INSERT INTO events (at, event, type, action, repo, sender, number, delivery, detail) VALUES (?,?,?,?,?,?,?,?,?)"
    [t, event, eventType, Val.opt action, Val.opt repo, Val.opt sender, Val.opt number, delivery, Val.opt detail]
  try save e.stateDir delivery body (Json.mkObj [("at", toJson (Time.iso t)), ("event", toJson event),
      ("type", toJson eventType), ("delivery", toJson delivery), ("repo", toJson repo), ("action", toJson action),
      ("sender", toJson sender), ("number", toJson number)])
  catch err => e.log s!"couldn't keep delivery {delivery}: {err}"
  -- Reviews arrive as pull_request events typed by verdict; a review request is a pull_request
  -- event of its own. Handled after the answer, since handling may call the forge, which waits.
  let review := eventType.startsWith "pull_request_review" && eventType != "pull_request_review_request"
  discard <| IO.asTask do
    try (handle (if review then eventType else event) payload).run e
    catch err => e.log s!"error handling a {eventType} event: {err}"
  reply .ok (Json.mkObj [])

/-- A runner's request, as the agent its key belongs to. -/
def asRunner (e : Env) (req : Request Body.Stream) (k : String → Json → D (ContextAsync (Response Body.Any))) :
    ContextAsync (Response Body.Any) := do
  let some agent ← (agentForKey (bearer req)).run e | errorReply .forbidden "unknown runner key"
  unless e.isAgent agent do return ← errorReply .forbidden "unknown runner key"
  let some data ← bodyJson req | errorReply .badRequest "not JSON"
  act e (toString req.line.uri) do
    runnerSeen agent
    k agent data

def onClaim (e : Env) (req : Request Body.Stream) : ContextAsync (Response Body.Any) :=
  asRunner e req fun agent _ => do
    match ← claim agent with
    | some c => return reply .ok c.json
    | none => return noContent

def onAbandon (e : Env) (req : Request Body.Stream) : ContextAsync (Response Body.Any) :=
  asRunner e req fun agent _ => do
    for r in ← q "SELECT id FROM runs WHERE agent=? AND ended IS NULL" [agent] do
      exec "UPDATE runs SET ended=?, outcome=? WHERE id=?" [← now, "abandoned: the runner restarted", r.get "id"]
      requeue (r.nat "id")
    return reply .ok (Json.mkObj [])

def onStart (e : Env) (id : Nat) (req : Request Body.Stream) : ContextAsync (Response Body.Any) :=
  asRunner e req fun agent data => do
    exec "UPDATE runs SET started=?, session_id=?, log=? WHERE id=? AND agent=?"
      [← now, Val.opt (jsonStr data "session_id"), Val.opt (jsonStr data "log"), id, agent]
    return reply .ok (Json.mkObj [])

def onEnd (e : Env) (id : Nat) (req : Request Body.Stream) : ContextAsync (Response Body.Any) :=
  asRunner e req fun agent data => do
    let ok ← endRun agent id data
    return reply (if ok then .ok else .notFound) (Json.mkObj [])

def onSession (e : Env) (req : Request Body.Stream) : ContextAsync (Response Body.Any) :=
  asRunner e req fun agent data => do
    let at_ := ((jsonNum data "at").map (·.toFloat)).getD (← now)
    let session := Val.opt (jsonStr data "session")
    let transcript := Val.opt (jsonStr data "transcript")
    if jsonStr data "event" == some "start" then
      exec "INSERT INTO sessions (agent, session_id, started, transcript) VALUES (?,?,?,?)" [agent, session, at_, transcript]
    else
      if (← q "SELECT 1 FROM sessions WHERE agent=? AND session_id=? AND ended IS NULL" [agent, session]).isEmpty then
        exec "INSERT INTO sessions (agent, session_id, transcript) VALUES (?,?,?)" [agent, session, transcript]
      exec "UPDATE sessions SET ended=?, transcript=? WHERE agent=? AND session_id=? AND ended IS NULL"
        [at_, transcript, agent, session]
    return reply .ok (Json.mkObj [])

def asAdmin (e : Env) (keys : Keys) (req : Request Body.Stream) (k : Json → D (ContextAsync (Response Body.Any))) :
    ContextAsync (Response Body.Any) := do
  let want ← readSecret keys.adminKey
  if want.isEmpty then return ← errorReply .forbidden "no admin key"
  unless Leancrypto.bytesEqual (bearer req).toUTF8 want.toUTF8 do return ← errorReply .forbidden "bad admin key"
  let some data ← bodyJson req | errorReply .badRequest "not JSON"
  act e (toString req.line.uri) (k data)

def onDrop (e : Env) (keys : Keys) (req : Request Body.Stream) : ContextAsync (Response Body.Any) :=
  asAdmin e keys req fun data => do
    let agent := (jsonStr data "agent").getD ""
    let n := ((← q "SELECT COUNT(*) AS n FROM triggers WHERE agent=? AND run_id IS NULL" [agent])[0]?.map (·.nat "n")).getD 0
    exec "UPDATE triggers SET run_id=-1 WHERE agent=? AND run_id IS NULL" [agent]
    log s!"dropped {n} pending trigger(s) for {agent}"
    return reply .ok (Json.mkObj [("dropped", toJson n)])

def onReconcile (e : Env) (keys : Keys) (req : Request Body.Stream) : ContextAsync (Response Body.Any) :=
  asAdmin e keys req fun _ => do
    reconcile
    return reply .ok (Json.mkObj [])

def onLedger (e : Env) (req : Request Body.Stream) : ContextAsync (Response Body.Any) := do
  let who ← (agentForKey (bearer req)).run e
  let allowed := e.supervisor?.toList ++ e.milestoneReviewers
  unless who.any allowed.contains do
    return ← errorReply .forbidden "only the supervisor and the milestone reviewers read the ledger"
  let since := ((queryParam req "since").bind parseFloat?).getD 0
  act e "/ledger" do
    let runs ← q "SELECT * FROM runs WHERE claimed>=? ORDER BY id" [since]
    let sessions ← q "SELECT * FROM sessions WHERE COALESCE(started, ended)>=? ORDER BY id" [since]
    let notices ← q "SELECT * FROM notices WHERE at>=? ORDER BY id" [since]
    return reply .ok (Json.mkObj [
      ("runs", Json.arr (runs.map (rowJson · ["claimed", "started", "ended"] ["triggers", "denied"]))),
      ("sessions", Json.arr (sessions.map (rowJson · ["started", "ended"]))),
      ("notices", Json.arr (notices.map (rowJson · ["at"])))])

route_table Routes
  [ health := "/healthz",
    hook := "/hook",
    claim := "/claim",
    abandon := "/runs/abandon",
    start := "/runs/:id:Nat/start",
    end_ := "/runs/:id:Nat/end",
    sessions := "/sessions",
    drop := "/admin/drop",
    reconcile := "/admin/reconcile",
    seen := "/admin/notices/:id:Nat/seen",
    reviews := "/reviews",
    status := "/status",
    activity := "/activity",
    notices := "/notices.txt",
    ledger := "/ledger" ]

def app (e : Env) (keys : Keys) : StatelessHandler .std :=
  toHandler (h := by routes_unshadowed +kernel)
    [ .get Routes.patterns.health (fun _ => reply .ok (Json.mkObj [("ok", toJson true)])),
      .post Routes.patterns.hook (onHook e keys),
      .post Routes.patterns.claim (onClaim e),
      .post Routes.patterns.abandon (onAbandon e),
      .post Routes.patterns.start (fun id req => onStart e id req),
      .post Routes.patterns.end_ (fun id req => onEnd e id req),
      .post Routes.patterns.sessions (onSession e),
      .post Routes.patterns.drop (onDrop e keys),
      .post Routes.patterns.reconcile (onReconcile e keys),
      .post Routes.patterns.seen (fun id req => asAdmin e keys req fun _ => do
        return if ← markSeen id then reply .ok (Json.mkObj []) else errorReply .notFound "no such notice"),
      .get Routes.patterns.status (fun _ => act e "/status" do return reply .ok (← status)),
      .get Routes.patterns.activity (fun req => act e "/activity" do
        let after := ((queryParam req "after").bind parseFloat?).getD 0
        let limit := ((queryParam req "limit").bind String.toNat?).getD 40
        return reply .ok (← activity after limit)),
      .get Routes.patterns.reviews (fun req => act e "/reviews" do
        return reply .ok (← reviews (((queryParam req "days").bind String.toNat?).getD 7))),
      .get Routes.patterns.notices (fun req => act e "/notices.txt" do
        return replyText (← noticesText (((queryParam req "after").bind String.toNat?).getD 0))),
      .get Routes.patterns.ledger (onLedger e) ]

/-! ## Loops -/

def every (e : Env) (seconds : Float) (what : String) (k : D Unit) : IO Unit := do
  repeat
    try k.run e catch err => e.log s!"{what} failed: {err}"
    IO.sleep (seconds * 1000).toUInt32

def idler : D Unit := do
  for (what, k) in [("closing unstarted runs", abandonUnstarted), ("moving obligations on", wakeDue),
                    ("checking CI", refreshCi), ("checking for idleness", checkIdle)] do
    try k catch err => log s!"{what} failed: {err}"

def reconciler : D Unit := do
  try reconcile catch err => log s!"reconciliation failed: {err}"
  try refreshCi (every := true) catch err => log s!"checking CI everywhere failed: {err}"

def rechecker : D Unit := do
  for u in ← dueRechecks do
    try evaluateUnit u catch err => log s!"evaluating {u} again failed: {err}"

end Guild.Dispatcher
