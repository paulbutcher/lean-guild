/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
module

public import Std.Http.Server
public import RoutingStd
public import Middleware
public import Leancurl
public import Leancrypto
public import Guild.Ui.Views
public import Guild.Ui.Style
public import Guild.Ui.Actions

/-! The human's web UI. It reads what it shows from the dispatcher's JSON, never from the forge,
and changes the kit only through `control/` and, for pause and resume, the forge in the human's
name. Every page also answers with its data as JSON, for a client that asks for it in `Accept`.

Every request goes through a session kept in a sealed cookie, and every route but the stylesheet
and signing in needs that session signed in, with the key in `secrets/ui/key`, which agents never
see. Every request that could change anything carries the anti-forgery token as well:
`changes_guarded` proves it of the route table. -/

@[expose] public section

namespace Guild.Ui

open Std Std.Async Http Server Routing Middleware Json Routes

structure Env where
  site : Site
  /-- The dispatcher's base URL, on a network agents aren't on. -/
  dispatcher : String
  adminKey : System.FilePath
  signInKey : System.FilePath
  brakes : Brakes
  /-- What the last action did, until a page has shown it. -/
  report : IO.Ref (List String)

def readKey (path : System.FilePath) : IO String := do
  try return (← IO.FS.readFile path).trimAscii.toString
  catch _ => return ""

/-- A request to the dispatcher, and its answer's JSON. -/
def Env.call (u : Env) (method : Leancurl.Method) (path : String) (admin := false) : IO Json := do
  let key ← readKey u.adminKey
  let auth := if admin then [("Authorization", s!"Bearer {key}")] else []
  let req : Leancurl.Request :=
    { url := u.dispatcher ++ path, method, headers := auth ++ [("Content-Type", "application/json")],
      body := if method == .get then none else some "{}".toUTF8, timeoutMs := some 60000 }
  match ← Leancurl.Curl.send req with
  | .error e => throw (IO.userError s!"the dispatcher didn't answer {path}: {e.message}")
  | .ok r =>
    unless r.status.toNat < 300 do
      throw (IO.userError s!"the dispatcher answered {path} with {r.status}")
    match parse ((String.fromUTF8? r.body).getD "") with
    | .ok j => return j
    | .error e => throw (IO.userError s!"the dispatcher's answer to {path} isn't JSON: {e}")

def signedInKey : String := "signed-in"

def withHeader (response : Response Body.Any) (name : Header.Name) (value : String) : Response Body.Any :=
  { response with line := { response.line with
      headers := response.line.headers.insert name (Header.Value.ofStringSanitized value) } }

/-- Sends the browser to `path`. A request HTMX made is told to go there itself; HTMX would
otherwise follow the redirect and swap the whole page into the part it asked for. -/
def goTo (req : Request Body.Stream) (path : String) : ContextAsync (Response Body.Any) := do
  if (req.line.headers.get? (Header.Name.mk "hx-request")).isSome then
    pure (withHeader (← Response.ok.html "") (Header.Name.mk "hx-redirect") path)
  else
    pure (withHeader (← Response.withStatus .seeOther |>.html "") (Header.Name.mk "location") path)

def wantsJson (req : Request Body.Stream) : Bool :=
  match req.line.headers.get? Header.Name.accept with
  | some v => (v.value.splitOn "application/json").length > 1
  | none => false

def token (req : Request Body.Stream) : Option String :=
  (req.extensions.get AntiForgeryToken).map (·.value)

def param (req : Request Body.Stream) (name : String) : Option String :=
  (req.extensions.get Params).bind (·.get name)

/-- A page drawn from the dispatcher's answer to `path`, or that answer itself for a client that
asks for JSON. -/
def page (u : Env) (which : Page) (path : String) (req : Request Body.Stream)
    (draw : Json → Float → IO (List (Html.Node .flow))) : ContextAsync (Response Body.Any) := do
  let j ← (u.call .get path : IO Json)
  if wantsJson req then return ← Response.ok.json j.compress
  let status ← if path == "/status" then pure j else (u.call .get "/status" : IO Json)
  let now ← (Guild.Dispatcher.Time.unixNow : IO Float)
  let unseen := ((Status.ofJson status).notices.filter (·.seen.isNone)).length
  -- What the last action did, shown once, on the page it came back to.
  let report ← (u.report.modifyGet fun r => (r, []) : IO (List String))
  let said : List (Html.Node .flow) := if report.isEmpty then [] else
    [Html.div (report.map fun l => (Html.p [Html.Node.text l] : Html.Node .flow)) { class_ := "report" }]
  Response.ok.html (layout which (token req) unseen (said ++ (← draw j now)))

def kitPage (u : Env) (req : Request Body.Stream) : ContextAsync (Response Body.Any) :=
  page u .kit "/status" req fun j now => do
    let st := Status.ofJson j
    tidyStops u.brakes.control (st.runs.filter (·.ended.isSome) |>.map (·.id))
    return kitView u.site now st

def agentsPage (u : Env) (req : Request Body.Stream) : ContextAsync (Response Body.Any) :=
  page u .agents "/status" req fun j now => return agentsView now (Status.ofJson j)

def noticesPage (u : Env) (req : Request Body.Stream) : ContextAsync (Response Body.Any) :=
  page u .notices "/status" req fun j now => return noticesView u.site now (Status.ofJson j)

def activityPage (u : Env) (req : Request Body.Stream) : ContextAsync (Response Body.Any) :=
  let filter := (param req "q").getD ""
  page u .activity "/activity?limit=400" req fun j now => return activityView now filter (events j)

def reviewsPage (u : Env) (req : Request Body.Stream) : ContextAsync (Response Body.Any) :=
  let days := ((param req "days").bind String.toNat?).getD 7
  let changes := (param req "changes").isSome
  page u .reviews s!"/reviews?days={days}" req fun j now => return reviewsView u.site now changes (Reviews.ofJson j)

/-- Runs an action, keeps what it says for the kit page, and draws `back` again. -/
def act (u : Env) (req : Request Body.Stream) (back : String) (k : IO (List String)) :
    ContextAsync (Response Body.Any) := do
  let said ← (try k catch err => pure [s!"That failed: {err}"] : IO (List String))
  u.report.set said
  goTo req back

def signInPage (req : Request Body.Stream) : ContextAsync (Response Body.Any) :=
  Response.ok.html (signInView (token req) false)

def signIn (u : Env) (req : Request Body.Stream) : ContextAsync (Response Body.Any) := do
  let want ← (readKey u.signInKey : IO String)
  let given := (param req "key").getD ""
  if want.isEmpty || !Leancrypto.bytesEqual given.toUTF8 want.toUTF8 then
    return ← Response.withStatus .forbidden |>.html (signInView (token req) true)
  let data := ((req.extensions.get SessionData).map (·.data)).getD []
  let session := SessionUpdate.write (Session.set data signedInKey "1")
  pure (withHeader (← Response.withStatus .seeOther |>.extension session |>.html "")
    (Header.Name.mk "location") links.kit)

def signOut (req : Request Body.Stream) : ContextAsync (Response Body.Any) := do
  let r ← goTo req links.signIn
  pure { r with extensions := r.extensions.insert SessionUpdate.delete }

/-- What stands in front of a group of routes. -/
inductive Guard where
  | antiForgery
  | signedIn
  deriving DecidableEq

/-- No route behind it is reached without a signed-in session: anything else is sent to sign in. -/
def requireSignedIn : StatelessHandler .std → StatelessHandler .std := fun h =>
  { h with onRequest := fun req => do
      let data := ((req.extensions.get SessionData).map (·.data)).getD []
      if Session.get data signedInKey == some "1" then h.onRequest req else goTo req links.signIn }

def Guard.middleware : Guard → StatelessHandler .std → StatelessHandler .std
  | .antiForgery => Middleware.antiForgery
  | .signedIn => requireSignedIn

structure Group where
  guards : List Guard
  routes : List (Route (Result .std))

/-- Methods the anti-forgery middleware lets through without a token, as it decides it. -/
def safeMethod : Method → Bool
  | .get | .head | .options => true
  | _ => false

def groups (u : Env) : List Group :=
  [ { guards := [.antiForgery],
      routes := [
        .get patterns.style (fun _ => do
          let r ← Response.ok.html stylesheet.render
          pure (withHeader r Header.Name.contentType "text/css; charset=utf-8")),
        .get patterns.signIn signInPage,
        .post patterns.signIn (signIn u)] },
    { guards := [.antiForgery, .signedIn],
      routes := [
        .get patterns.kit (kitPage u),
        .get patterns.agents (agentsPage u),
        .get patterns.notices (noticesPage u),
        .get patterns.activity (activityPage u),
        .get patterns.reviews (reviewsPage u),
        .post patterns.signOut signOut,
        .post patterns.pause (fun req => act u req links.kit u.brakes.pause),
        .post patterns.drain (fun req => act u req links.kit u.brakes.drain),
        .post patterns.resume (fun req => act u req links.kit u.brakes.resume),
        .post patterns.stopRun (fun id req => act u req links.agents do
          stopRun u.brakes.control id
          return [s!"Asked for run {id} to stop."]),
        .post patterns.stopAgent (fun name req => act u req links.agents do
          stopAgent u.brakes.control name
          return [s!"Stopped {name}: it takes no more work until you start it."]),
        .post patterns.startAgent (fun name req => act u req links.agents do
          startAgent u.brakes.control name
          return [s!"Started {name} again."]),
        .post patterns.seen (fun id req => act u req links.notices do
          discard <| u.call .post s!"/admin/notices/{id}/seen" (admin := true)
          return [s!"Marked notice {id} seen."])] } ]

/-- No route that could change anything is reached without an anti-forgery token, nor, but for
signing in itself, without a signed-in session.

Every route the server answers is in some group of `groups u`, behind that group's guards, the
first outermost (`server`). For each route whose method the anti-forgery middleware doesn't let
through untouched (`safeMethod` false), its group's guards include `antiForgery`, and include
`signedIn` unless the route is the sign-in form's. That a guard refuses what it should is the
middleware's, and `lake test` drives it. -/
theorem changes_guarded (u : Env) : ∀ g ∈ groups u, ∀ r ∈ g.routes, safeMethod r.method = false →
    Guard.antiForgery ∈ g.guards ∧ (Guard.signedIn ∈ g.guards ∨ r.segs = patterns.signIn) := by
  simp [groups, safeMethod, Route.get, Route.post, route]

/-- The web UI: the site's middleware, with sessions in `sessions`, then each group behind its
guards; or why its routes can't all be reached. -/
def server [SessionStore σ] (u : Env) (sessions : σ) : Except String (StatelessHandler .std) :=
  Router.toHandlerChecked
    { middlewares := [defaults { siteDefaults sessions with antiForgery := none }],
      routers := (groups u).map fun g =>
        { middlewares := g.guards.map Guard.middleware, routes := g.routes.map .route } }

end Guild.Ui
