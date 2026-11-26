/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
module

public import Htmx
public import Guild.Ui.Data
public import Guild.Ui.Links

/-! The pages, as functions of what the dispatcher reports. Each action is a button that posts
with HTMX and draws the page again; the anti-forgery token rides on `<body>` as `hx-headers`, which
every request under it inherits. -/

@[expose] public section

namespace Guild.Ui

open Html Routes

/-- Where links into the forge go. -/
structure Site where
  forgeWeb : String
  org : String

/-- An item's page in the forge, for a unit named `repo#n`. -/
def Site.itemUrl (s : Site) (unit : String) : Option String :=
  match unit.splitOn "#" with
  | [repo, n] => if n.all Char.isDigit && !n.isEmpty then some s!"{s.forgeWeb}/{s.org}/{repo}/issues/{n}" else none
  | _ => none

def unitLink (s : Site) (unit : String) : Node .phrasing :=
  match s.itemUrl unit with
  | some href => a { href } [unit]
  | none => unit

def htmxScript : ScriptAttrs :=
  { src := "https://cdn.jsdelivr.net/npm/htmx.org@2.0.10/dist/htmx.min.js"
    integrity := "sha384-H5SrcfygHmAuTDZphMHqBJLc3FhssKjG7w/CeCpFReSfwBWDTKpkzPP8c+cLsK+V"
    crossorigin := "anonymous" }

def csrfAttrs : Option String → List (String × String)
  | none => []
  | some token => [("hx-headers", "{\"X-CSRF-Token\": \"" ++ token ++ "\"}")]

inductive Page where
  | kit | agents | notices | activity | reviews
  deriving BEq

def Page.title : Page → String
  | .kit => "The kit" | .agents => "Agents" | .notices => "Notices" | .activity => "Activity"
  | .reviews => "Reviews"

def Page.link : Page → String
  | .kit => links.kit | .agents => links.agents | .notices => links.notices
  | .activity => links.activity | .reviews => links.reviews

def pages : List Page := [.kit, .agents, .notices, .activity, .reviews]

/-- A button that posts to `path` and draws the page again. -/
def action (path label : String) (confirm : Option String := none) : Node .phrasing :=
  Htmx.button [label]
    { type := "button", hxPost := path, hxTarget := "#page", hxSelect := "#page",
      hxSwap := some .outerHTML, hxConfirm := confirm }

/-- The newest notice, for the script that shows each new one as a browser notification. -/
def newest : Option Notice → List (Node .flow)
  | none => []
  | some n => [Html.span [] { id := "latest-notice" }
      [("hidden", "hidden"), ("data-id", toString n.id), ("data-text", s!"{n.kind}: {n.text}")]]

/-- How often a page asks for itself again. -/
def refreshEvery : String := "15s"

/-- The page around `content`, which is drawn again every `refreshEvery` while it is open, as the
reference's `watch.sh` redrew the status. `unseen` counts the notices waiting. -/
def layout (page : Page) (token : Option String) (unseen : Nat) (content : List (Node .flow))
    (latest : Option Notice := none) : String :=
  let nav := Html.nav (pages.map fun p =>
    let label := if p == .notices && unseen > 0 then s!"{p.title} ({unseen})" else p.title
    (a { href := p.link, class_ := if p == page then some "here" else none } [label] : Node .flow))
  document
    (head (title s!"{page.title}: the guild")
      [meta_ [("charset", "utf-8")],
       meta_ [("name", "viewport"), ("content", "width=device-width, initial-scale=1")],
       link { rel := "stylesheet", href := links.style },
       script htmxScript, script { src := links.script }])
    (body
      [header [nav, Html.p [action links.signOut "Sign out", Html.button ["Show notices as browser notifications"]
          { type := "button", id := "notify-on" } [("hidden", "hidden")]]],
       Html.main [Htmx.div (content ++ newest latest)
         { id := "page", hxGet := page.link, hxTrigger := s!"every {refreshEvery}",
           hxSelect := "#page", hxSwap := some .outerHTML }]]
      (rawAttrs := csrfAttrs token))
    (lang := "en")

/-- Text built from pieces: `++` alone would be read at the node type. -/
def txt (s : String) : Node .phrasing := s

def kitView (s : Site) (st : Status) : List (Node .flow) :=
  let brake := if st.paused then "Paused: no run starts, and runs under way stop at their next step."
    else if st.draining then
      if st.drained then "Draining, and nothing is under way: it is safe to stop the kit."
      else s!"Draining: waiting for {", ".intercalate (st.underWay.getD [])}."
    else "Running."
  [h1 ["The kit"],
   -- The summary's first line says how the kit is; each line after it, one thing behind that.
   p [txt ((st.summary.splitOn "\n").headD "")] { class_ := "summary" },
   ul ((st.summary.splitOn "\n").drop 1 |>.filter (!·.trimAscii.isEmpty) |>.map fun l =>
     (li [p [txt (l.trimAscii.toString.dropPrefix "- ").toString]] : Node .listItemOrScript)),
   p [brake] { id := "brake" },
   p ((if st.paused || st.draining then [action links.resume "Resume"] else
       [action links.pause "Pause" (some "Pause every agent and cancel every scheduled merge?"),
        action links.drain "Drain"]) : List (Node .phrasing)),
   h2 ["Waiting on you"],
   if st.waitingOnYou.isEmpty then p ["Nothing."]
   else ul (st.waitingOnYou.map fun u => (li [p [unitLink s u]] : Node .listItemOrScript)),
   h2 ["Work in progress"],
   ul (st.units.filter (!·.holders.isEmpty) |>.map fun u =>
     (li [p [unitLink s u.unit, s!" ({u.kind}, {u.state}): {", ".intercalate u.holders}"]] : Node .listItemOrScript)),
   p [txt (if st.ci.isEmpty then "CI: nothing running." else s!"CI: may be running on {", ".intercalate st.ci}.")],
   p [s!"Reconciled with the forge: {st.reconciled.getD "not yet"}."]]

def money (x : Float) : String := s!"${(x * 100).round / 100}"

def runView (r : Run) : Node .listItemOrScript :=
  li [p [txt <| s!"Run {r.id}: {r.started.getD "claimed"} to {r.ended.getD "now"}, {r.outcome.getD "under way"}" ++
        (match r.cost with | some c => s!", {money c}" | none => "") ++
        (match r.turns with | some t => s!", {t} turns" | none => "") ++
        (if r.denied > 0 then s!", {r.denied} denied" else "")],
      p [small ["; ".intercalate r.triggers]],
      p [small [s!"Session {r.sessionId.getD "-"}; log {r.log.getD "-"}"]]]

def agentView (st : Status) (ag : Agent) : Node .flow :=
  let runs := (st.runs.filter (·.agent == ag.name)).take 5
  let current := runs.find? (·.ended.isNone)
  let owed := st.obligations.filter (·.agent == ag.name)
  section_
    [h2 [ag.name, " ", span [ag.state] { class_ := s!"state {ag.state}" }],
     p [txt <| s!"{ag.runsToday} of {ag.cap} runs today, {money ag.spendToday} spent" ++
         (match ag.spendCap with | some c => s!" of ${c}" | none => "") ++ "."],
     p ((match current with
        | some r => [action (links.stopRun r.id) "Stop its run" (some s!"Interrupt {ag.name}'s run {r.id}?")]
        | none => []) ++
        [if ag.state == "stopped" then action (links.startAgent ag.name) "Start"
         else action (links.stopAgent ag.name) "Stop"] : List (Node .phrasing)),
     h3 ["Queued"],
     if ag.pending.isEmpty then p ["Nothing."]
     else ul (ag.pending.map fun w => (li [p [txt <| s!"{w.trigger} (since {w.since}" ++
       (match w.after with | some t => s!", not before {t})" | none => ")")]] : Node .listItemOrScript)),
     h3 ["Owed"],
     if owed.isEmpty then p ["Nothing."]
     else ul (owed.map fun o => (li [p [txt <| s!"{o.unit}: {o.description}, woken {o.wakes} time" ++
       (if o.wakes == 1 then "" else "s") ++ (if o.escalated then ", now yours" else "")]] : Node .listItemOrScript)),
     h3 ["Recent runs"],
     if runs.isEmpty then p ["None."] else ul (runs.map runView)]
    { id := s!"agent-{ag.name}" }

def agentsView (st : Status) : List (Node .flow) :=
  h1 ["Agents"] :: st.agents.map (agentView st)

def noticesView (s : Site) (st : Status) : List (Node .flow) :=
  [h1 ["Notices"],
   if st.notices.isEmpty then p ["None."]
   else ul (st.notices.map fun n =>
     (li [p ([txt s!"{n.at_}, {n.kind}"] ++
            (match n.where_ with | some w => [(", " : Node .phrasing), unitLink s w] | none => []) ++
            [txt (": " ++ n.text)]),
          p (match n.seen with
            | some t => [small [s!"Seen {t}."]]
            | none => [action (links.seen n.id) "Mark seen"])]
       { class_ := if n.seen.isNone then some "unseen" else none } : Node .listItemOrScript))]

def activityView (filter : String) (es : List Event) : List (Node .flow) :=
  let shown := if filter.isEmpty then es else es.filter fun e =>
    ((e.who ++ " " ++ e.text).toLower.splitOn filter.toLower).length > 1
  [h1 ["Activity"],
   form [input { type := "search", name := "q", value := filter, placeholder := "Only entries mentioning…" }]
     { method := "get", action := links.activity },
   if shown.isEmpty then p ["Nothing yet."]
   else ul (shown.reverse.map fun e => (li [p [s!"{e.at_} {e.who}: {e.text}"]] : Node .listItemOrScript))]

def reviewsView (s : Site) (changes : Bool) (r : Reviews) : List (Node .flow) :=
  let pulls := if changes then r.pulls.filter (·.reviews.any (·.verdict == "changes requested")) else r.pulls
  let milestones := if changes then r.milestones.filter fun m =>
      r.recommendations.any fun c => m.reports.any fun (who, _) => c.review == some who
    else r.milestones
  [h1 ["Reviews"],
   p [s!"Pull requests updated in the last {r.days} days, and milestone reviews. ",
      a { href := if changes then links.reviews else links.reviews ++ "?changes=1" }
        [if changes then "Show every review." else "Show only reviews asking for more work."]],
   h2 ["Pull requests"],
   if pulls.isEmpty then p ["None."]
   else ul (pulls.map fun pr => (li
     [p [unitLink s pr.unit, txt (s!" {pr.title}, by {pr.author}" ++ (if pr.isOpen then "" else " (closed)"))],
      ul (pr.reviews.map fun v => (li [p [txt (s!"{v.by_}: {v.verdict}, {v.at_}" ++
        (if v.current then "" else " (on an earlier head)"))]] : Node .listItemOrScript))] : Node .listItemOrScript)),
   h2 ["Milestones"],
   if milestones.isEmpty then p ["None."]
   else ul (milestones.map fun m => (li
     [p [unitLink s m.unit, txt (s!" {m.title}" ++ (if m.isOpen then "" else " (closed)"))],
      ul (m.reports.map fun (who, at_) =>
        let recs := r.recommendations.filter (·.review == some who)
        (li [p [txt (s!"{who} reported {at_}: {recs.length} recommendation" ++ (if recs.length == 1 then "" else "s") ++
              (if recs.isEmpty then "" else ", " ++ ", ".intercalate (recs.map fun c => s!"{c.unit} {c.outcome}")))]]
          : Node .listItemOrScript))] : Node .listItemOrScript))]

def signInView (token : Option String) (failed : Bool) : String :=
  document
    (head (title "Sign in: the guild")
      [meta_ [("charset", "utf-8")], link { rel := "stylesheet", href := links.style }])
    (body
      [Html.main
        (([h1 ["Sign in"]] : List (Node .flow)) ++
         ((if failed then [p ["That isn't the kit's sign-in key."] { class_ := "error" }] else []) : List (Node .flow)) ++
         [form
           [label ["The sign-in key, from ", code ["secrets/ui/key"], " under the kit's state directory"]
              { for_ := "key" },
            input { type := "password", name := "key", id := "key", required := true },
            input { type := "hidden", name := "__anti-forgery-token", value := token },
            button ["Sign in"]]
           { method := "post", action := links.signIn }])])
    (lang := "en")

end Guild.Ui
