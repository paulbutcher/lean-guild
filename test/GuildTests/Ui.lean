/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Guild.Ui.App
import Middleware.Test.Browser
import GuildTests.Fake

/-! The web UI: its views from the dispatcher's data, and the whole server driven as a browser
drives it, against a stand-in dispatcher and the fake forge as the human. -/

namespace GuildTests.Ui

open Guild.Ui Guild.Ui.Routes Guild.Forge Json Std Std.Async Std.Http Routing Std.Http.Internal.Test Middleware.Test

def has (s part : String) : Bool := (s.splitOn part).length > 1

def text (nodes : List (Html.Node .flow)) : String :=
  String.join (nodes.map Html.Node.render)

def site : Site := { forgeWeb := "http://forge.test", org := "org" }

def unit (u state : String) (holders : List String) : Json :=
  Json.mkObj [("unit", toJson u), ("kind", toJson "issue"), ("state", toJson state),
    ("holders", toJson holders), ("step", toJson "do it"), ("since", toJson "2026-11-25T10:00:00Z")]

/-- What the dispatcher reports: base running run 7, with notice 3 waiting, 2 seen, and 5 newer than
the page that marks all seen up to 3. -/
def statusJson (paused : Bool) : Json := Json.mkObj [
  ("paused", toJson paused), ("draining", toJson false), ("drained", toJson false),
  ("under_way", .null), ("reconciled", toJson "2026-11-25T10:00:00Z"), ("stopped", toJson ([] : List String)),
  ("waiting_on_you", toJson ["lib#4"]),
  ("agents", Json.mkObj [("base", Json.mkObj [("state", toJson "running"), ("runs_today", toJson 2),
    ("cap", toJson 20), ("spend_today", toJson 1.5), ("spend_cap", .null),
    ("pending", Json.arr #[Json.mkObj [("trigger", toJson "a comment on lib#5"), ("since", toJson "t"), ("after", .null)]])])]),
  ("runs", Json.arr #[Json.mkObj [("id", toJson 7), ("agent", toJson "base"), ("triggers", toJson ["lib#5"]),
    ("claimed", toJson "t"), ("started", toJson "t"), ("ended", .null), ("outcome", .null)]]),
  ("notices", Json.arr #[Json.mkObj [("id", toJson 3), ("at", toJson "t"), ("kind", toJson "needs-human"),
    ("repo", toJson "lib"), ("number", toJson 4), ("text", toJson "decide"), ("posted", toJson 1), ("seen", .null)],
    Json.mkObj [("id", toJson 2), ("at", toJson "t"), ("kind", toJson "budget"), ("repo", .null), ("number", .null),
      ("text", toJson "spent"), ("posted", toJson 0), ("seen", toJson "t")],
    Json.mkObj [("id", toJson 5), ("at", toJson "t"), ("kind", toJson "needs-human"), ("repo", toJson "lib"),
      ("number", toJson 5), ("text", toJson "later"), ("posted", toJson 1), ("seen", .null)]]),
  ("obligations", Json.arr #[]),
  ("units", Json.arr #[unit "lib#4" "waiting on you" [], unit "lib#5" "to do" ["base"]]),
  ("summary", toJson "Kit: working.")]

/-! ## Views -/

/-- The time the pages are drawn at. -/
def now : Float := Guild.Dispatcher.Time.when "2026-11-25T12:00:00Z"

def viewCases : List (String × Bool) :=
  let st := Status.ofJson (statusJson false)
  let paused := Status.ofJson (statusJson true)
  [("a running kit offers pause and drain, and a paused one only resume",
     has (text (kitView site now st)) links.pause && !has (text (kitView site now st)) links.resume &&
     has (text (kitView site now paused)) links.resume && !has (text (kitView site now paused)) links.pause),
   ("what waits on the human links into the forge",
     has (text (kitView site now st)) ((site.itemUrl "lib#4").getD "?")),
   ("only units someone holds are work in progress",
     let none_ := { st with waitingOnYou := [], notices := [] }
     has (text (kitView site now none_)) "lib#5" && !has (text (kitView site now none_)) "lib#4"),
   ("an agent's run under way can be stopped", has (text (agentsView now st)) (links.stopRun 7)),
   ("a stopped agent is offered start, a running one stop",
     has (text (agentsView now st)) (links.stopAgent "base") &&
     has (text (agentsView now { st with agents := st.agents.map ({ · with state := "stopped" }) })) (links.startAgent "base")),
   ("an unseen notice can be marked seen, a seen one not",
     has (text (noticesView site now st)) (links.seen 3) &&
     !has (text (noticesView site now { st with notices := st.notices.map ({ · with seen := some "t" }) })) (links.seen 3)),
   ("the activity filter keeps only entries that mention it",
     let es := [{ at_ := "1", who := "base", text := "queued: x" }, { at_ := "2", who := "app", text := "run 4 started" }]
     has (text (activityView now "BASE" es)) "queued: x" && !has (text (activityView now "BASE" es)) "run 4 started"),
   ("times read relative to now, before and after it",
     relative now (now - 720) == "12 min ago" && relative now (now + 3 * 3600) == "in 3 h" &&
     relative now (now - 10) == "just now" && relative now (now - 2 * 86400 - 4 * 3600) == "2 d 4 h ago"),
   ("a run's duration stands for its start and end, and runs on while it is under way",
     took now (some "2026-11-25T10:00:00Z") (some "2026-11-25T11:05:00Z") == "1 h 5 min" &&
     took now (some "2026-11-25T11:59:00Z") none == "1 min so far"),
   ("each time on a page carries the time itself for its tooltip",
     has (text (kitView site now st)) "2026-11-25 10:00:00 UTC"),
   ("the kit page shows a backup's failure only when it is newer than the last success",
     let at_ (ok failed : String) := { st with backups :=
       { okAt := some ok, folder := some "/backups/x", failedAt := some failed, log := some "/state/backup.log" } }
     has (text (kitView site now (at_ "2026-11-27T03:30:00Z" "2026-11-28T03:30:00Z"))) "/state/backup.log" &&
     !has (text (kitView site now (at_ "2026-11-28T03:30:00Z" "2026-11-27T03:30:00Z"))) "/state/backup.log"),
   ("the layout carries the anti-forgery token for HTMX",
     has (layout .kit (some "tok") 0 []) "X-CSRF-Token&quot;: &quot;tok")]

/-! ## The server -/

def port : UInt16 := 18733

/-- A dispatcher that answers `/status` and records every request, with its authorization. -/
def fakeDispatcher (paused : IO.Ref Bool) (seen : IO.Ref (Array (String × String))) : StatelessHandler .std :=
  StatelessHandler.ofFn fun req => do
    let auth := ((req.line.headers.get? Header.Name.authorization).map (·.value)).getD ""
    seen.modify (·.push (toString req.line.uri, auth))
    let path := toString req.line.uri
    let p ← paused.get
    let body := if path.startsWith "/status" then statusJson p else Json.mkObj []
    ServerEngine.bytes (e := .std)
      ((Response.withStatus .ok).header Header.Name.contentType (.mk "application/json")) body.compress.toUTF8

def world : Fake.World :=
  { admins := ["tester"],
    repos := [{ name := "lib", labels := [], writers := ["base", "tester"],
                protection := some { approvals := 0, approvers := [], contexts := [] } }] }

structure Rig where
  browser : Browser
  handler : TestHandler
  control : System.FilePath
  forge : IO.Ref Fake.World
  seen : IO.Ref (Array (String × String))
  /-- base's pull request, its merge scheduled. -/
  pr : Nat

def tokenFrom (body : String) : Option String :=
  (tokenAfter "name=\"__anti-forgery-token\" value=\"" body).orElse fun _ =>
    tokenBetween "X-CSRF-Token&quot;: &quot;" "&quot;" body

def rig (dispatcherPaused : IO.Ref Bool) (seen : IO.Ref (Array (String × String))) : IO Rig := do
  let dir := (← IO.currentDir) / ".lake" / "ui-test" / toString (← IO.monoNanosNow)
  let control := dir / "control"
  IO.FS.createDirAll control
  IO.FS.writeFile (dir / "key") "the-key\n"
  IO.FS.writeFile (dir / "admin-key") "admin\n"
  let ref ← IO.mkRef world
  let base := Fake.as ref "base"
  let pr ← match ← (do
      discard <| base.commit "lib" { branch := "main", message := "start", files := [("README.md", "x")] }
      discard <| base.commit "lib" { branch := "change", start := some "main", message := "a change", files := [("a.txt", "a")] }
      let n ← base.createPull "lib" { head := "change", title := "A change" }
      discard <| base.merge "lib" n true
      return n : M Nat).run with
    | .ok n => pure n
    | .error e => throw (IO.userError s!"setting up the fake forge: {e}")
  let u : Env :=
    { site, dispatcher := s!"http://127.0.0.1:{port}", adminKey := dir / "admin-key", signInKey := dir / "key",
      brakes := { control, forge := Fake.as ref "tester", human := "tester", repos := ["lib"] },
      report := ← IO.mkRef [] }
  let .ok h := server u (← Middleware.MemoryStore.new) | throw (IO.userError "the routes don't dispatch")
  discard <| dispatcherPaused.get
  return { browser := ← Browser.new h.onRequest (tokenFrom := tokenFrom), handler := h.onRequest, control,
           forge := ref, seen, pr }

def signIn (r : Rig) : IO Unit := do
  discard <| r.browser.get links.signIn
  assertStatus (← r.browser.post links.signIn [("key", "the-key")]) "HTTP/1.1 303"
  discard <| r.browser.get links.kit

def mergers (r : Rig) : IO (Option (List String)) := do
  return ((← r.forge.get).repos.find? (·.name == "lib")).bind (·.protection) |>.bind (·.mergers)

def pullState (r : Rig) : IO (Option Pull) := do
  match ← ((Fake.as r.forge "tester").pull "lib" r.pr).run with
  | .ok p => return p
  | .error e => throw (IO.userError s!"{e}")

def bodyOf (response : ByteArray) : String :=
  let s := (String.fromUTF8? response).getD ""
  ((s.splitOn "\r\n\r\n").drop 1 |> "\r\n\r\n".intercalate)

def ensure (cond : Bool) (m : String) : IO Unit := unless cond do throw (IO.userError m)

def absent (path : System.FilePath) (m : String) : IO Unit := do
  if ← path.pathExists then throw (IO.userError m)

def serverCases (paused : IO.Ref Bool) (seen : IO.Ref (Array (String × String))) : List (String × IO Unit) :=
  [("a page without a session is sent to sign in", do
      let r ← rig paused seen
      let resp ← r.browser.get links.kit
      assertStatus resp "HTTP/1.1 303"
      assertContains resp links.signIn),
   ("the wrong key doesn't sign in", do
      let r ← rig paused seen
      discard <| r.browser.get links.signIn
      assertStatus (← r.browser.post links.signIn [("key", "a-guess")]) "HTTP/1.1 403"
      assertStatus (← r.browser.get links.kit) "HTTP/1.1 303"),
   ("without a session, an action is refused and changes nothing", do
      let r ← rig paused seen
      discard <| r.browser.get links.signIn
      let resp ← r.browser.post links.pause [] (placement := .header)
      absent (r.control / "paused") "paused without a session"
      assertAbsent resp "HTTP/1.1 2"),
   ("signed in, an action without the token is refused and changes nothing", do
      let r ← rig paused seen
      signIn r
      let cookie := (← r.browser.cookies.get).map (fun (n, v) => s!"{n}={v}") |> "; ".intercalate
      check "POST pause with no token" (mkPost links.pause "" s!"Cookie: {cookie}\x0d\nConnection: close\x0d\n") r.handler
        fun resp => assertStatus resp "HTTP/1.1 403"
      absent (r.control / "paused") "paused without a token"),
   ("pause cancels and records scheduled merges and narrows who may merge; resume undoes it in the human's name", do
      let r ← rig paused seen
      signIn r
      discard <| r.browser.post links.pause [] (placement := .header)
      ensure (← (r.control / "paused").pathExists) "control/paused is missing"
      let recorded ← IO.FS.readFile (r.control / "paused-merges.json")
      ensure (has recorded "\"base\"" && has recorded s!"\"number\": {r.pr}") s!"recorded: {recorded}"
      ensure ((← pullState r).any (!·.merged)) "the pull request merged while pausing"
      ensure ((← mergers r) == some ["tester"]) s!"mergers while paused: {← mergers r}"
      paused.set true
      discard <| r.browser.get links.kit
      discard <| r.browser.post links.resume [] (placement := .header)
      absent (r.control / "paused") "control/paused is still there"
      absent (r.control / "paused-merges.json") "the recorded merges are still there"
      ensure ((← mergers r) == none) s!"mergers after resuming: {← mergers r}"
      ensure ((← pullState r).any (·.merged)) "the cancelled merge wasn't made on resuming"
      paused.set false),
   ("an agent is stopped and started, and a run asked to stop", do
      let r ← rig paused seen
      signIn r
      discard <| r.browser.post (links.stopAgent "base") [] (placement := .header)
      ensure (← (r.control / "stopped-base").pathExists) "no stopped-base"
      discard <| r.browser.post (links.startAgent "base") [] (placement := .header)
      absent (r.control / "stopped-base") "stopped-base is still there"
      discard <| r.browser.post (links.stopRun 7) [] (placement := .header)
      ensure (← (r.control / "stop-run-7").pathExists) "no stop-run-7"),
   ("a notice is marked seen at the dispatcher, with its admin key", do
      let r ← rig paused seen
      signIn r
      seen.set #[]
      discard <| r.browser.post (links.seen 3) [] (placement := .header)
      ensure ((← seen.get).any (· == ("/admin/notices/3/seen", "Bearer admin"))) s!"the dispatcher saw {← seen.get}"),
   ("marking all seen marks only the unseen notices up to the newest the page showed", do
      let r ← rig paused seen
      signIn r
      seen.set #[]
      discard <| r.browser.post (links.seenTo 3) [] (placement := .header)
      let marked := (← seen.get).toList.filter (·.1.endsWith "/seen")
      ensure (marked == [("/admin/notices/3/seen", "Bearer admin")]) s!"the dispatcher saw {marked}"),
   ("the stylesheet is served as CSS alone, which a browser refusing to sniff needs", do
      let r ← rig paused seen
      let resp ← r.browser.get links.style
      let types := (((String.fromUTF8? resp).getD "").splitOn "\r\n").filter fun l => l.toLower.startsWith "content-type:"
      ensure (types == ["Content-Type: text/css; charset=utf-8"]) s!"its content types: {types}"),
   ("a page answers with its data as JSON when asked", do
      let r ← rig paused seen
      signIn r
      let resp ← r.browser.get links.kit "Accept: application/json\x0d\n"
      ensure ((Status.ofJson ((parse (bodyOf resp)).toOption.getD .null)).waitingOnYou == ["lib#4"])
        s!"the kit page's JSON: {bodyOf resp}")]

def check : IO Bool := do
  let mut ok := true
  for (name, good) in viewCases do
    if good then IO.println s!"PASS (ui): {name}" else IO.println s!"FAIL (ui): {name}"; ok := ok && good
  let paused ← IO.mkRef false
  let seen ← IO.mkRef #[]
  let addr : Std.Net.SocketAddress := .v4 { addr := Std.Net.IPv4Addr.ofParts 127 0 0 1, port }
  let server ← (Std.Http.Server.serve addr (fakeDispatcher paused seen)).block
  try
    for (name, t) in serverCases paused seen do
      match ← t.toBaseIO with
      | .ok () => IO.println s!"PASS (ui): {name}"
      | .error err => IO.println s!"FAIL (ui): {name}: {err}"; ok := false
  finally
    server.shutdownAndWait.block
  return ok

end GuildTests.Ui
