/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
module

public import Htmx
public import Guild.Ui.Data
public import Guild.Ui.Links
public import Guild.Dispatcher.Time

/-! The pages, as functions of what the dispatcher reports and the time now. Each action is a
button that posts with HTMX and draws the page again; the anti-forgery token rides on `<body>` as
`hx-headers`, which every request under it inherits. -/

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

/-- How often a page asks for itself again. -/
def refreshEvery : String := "15s"

/-- The page around `content`, which is drawn again every `refreshEvery` while it is open, as the
reference's `watch.sh` redrew the status. `unseen` counts the notices waiting; the title carries
it too, so that a pinned tab shows it, and HTMX takes the title from each redraw. -/
def layout (page : Page) (token : Option String) (unseen : Nat) (content : List (Node .flow)) : String :=
  let nav := Html.nav (pages.map fun p =>
    let label := if p == .notices && unseen > 0 then s!"{p.title} ({unseen})" else p.title
    (a { href := p.link, class_ := if p == page then some "here" else none } [label] : Node .flow))
  let count := if unseen > 0 then s!"({unseen}) " else ""
  document
    (head (title s!"{count}{page.title}: the guild")
      [meta_ [("charset", "utf-8")],
       meta_ [("name", "viewport"), ("content", "width=device-width, initial-scale=1")],
       link { rel := "stylesheet", href := links.style },
       script htmxScript])
    (body
      [header [nav, Html.p [action links.signOut "Sign out"]],
       Html.main [Htmx.div content
         { id := "page", hxGet := page.link, hxTrigger := s!"every {refreshEvery}",
           hxSelect := "#page", hxSwap := some .outerHTML }]]
      (rawAttrs := csrfAttrs token))
    (lang := "en")

/-- Text built from pieces: `++` alone would be read at the node type. -/
def txt (s : String) : Node .phrasing := s

def plural (n : Nat) (one many : String) : String := if n == 1 then one else many

/-! ## Times -/

/-- A span of time to the unit that matters: `40 s`, `12 min`, `3 h 5 min`, `2 d 4 h`. -/
def duration (secs : Float) : String :=
  let s := secs.abs.round.toUInt64.toNat
  if s < 60 then s!"{s} s"
  else if s < 3600 then s!"{s / 60} min"
  else if s < 86400 then s!"{s / 3600} h" ++ (if s / 60 % 60 == 0 then "" else s!" {s / 60 % 60} min")
  else s!"{s / 86400} d" ++ (if s / 3600 % 24 == 0 then "" else s!" {s / 3600 % 24} h")

/-- `t` as seen from `now`: `12 min ago`, `in 3 h`. -/
def relative (now t : Float) : String :=
  let d := now - t
  if d.abs < 45 then "just now" else if d > 0 then s!"{duration d} ago" else s!"in {duration d}"

/-- A time from the dispatcher or the forge, relative to `now`, with the time itself as its
tooltip; as it came, if it can't be read. -/
def at_ (now : Float) (iso : String) : Node .phrasing :=
  match Guild.Dispatcher.Time.parse? iso with
  | some t =>
    let abs := ((Guild.Dispatcher.Time.iso t).replace "T" " ").replace "Z" " UTC"
    time [relative now t] { datetime := iso, title := abs }
  | none => if iso.isEmpty then "-" else iso

/-- How long a run took, or has taken so far. -/
def took (now : Float) (started ended : Option String) : String :=
  match started.bind Guild.Dispatcher.Time.parse?, ended.bind Guild.Dispatcher.Time.parse? with
  | some s, some e => duration (e - s)
  | some s, none => s!"{duration (now - s)} so far"
  | none, _ => "-"

/-! ## Badges and tables -/

/-- How a state reads at a glance. Every badge says its state in words too. -/
inductive Tone where
  | go | hold | stop | quiet

def Tone.cls : Tone → String
  | .go => "go" | .hold => "hold" | .stop => "stop" | .quiet => "quiet"

def badge (label : String) (tone : Tone) : Node .phrasing :=
  span [label] { class_ := s!"badge {tone.cls}" }

def agentBadge (state : String) : Node .phrasing :=
  badge state (match state with
    | "running" => .go | "idle" => .quiet | "stopped" => .stop | _ => .hold)

def verdictBadge (verdict : String) : Node .phrasing :=
  badge verdict (match verdict with
    | "approved" => .go | "changes requested" => .stop | _ => .quiet)

def outcomeBadge : Option String → Node .phrasing
  | none => badge "under way" .go
  | some "completed" => badge "completed" .go
  | some "interrupted" => badge "interrupted" .hold
  | some o => badge o .stop

def cell (content : List (Node .flow)) : Node .tableCellOrScript := td content

/-- A cell of prose, which wraps where the others don't. -/
def wide (content : List (Node .flow)) : Node .tableCellOrScript := td content { class_ := "wide" }

def num (n : String) : Node .tableCellOrScript := td [n] { class_ := "num" }

def row (cells : List (Node .tableCellOrScript)) (cls : Option String := none) : Node .tableRowOrScript :=
  tr cells { class_ := cls }

/-- A table under `heads`, which scrolls sideways on a narrow window rather than wrap. -/
def grid (heads : List String) (rows : List (Node .tableRowOrScript)) : Node .flow :=
  div [table (.rows rows)
      (thead := some (thead [tr (heads.map fun h => (th [(txt h : Node .flow)] { scope := "col" } : Node .tableCellOrScript))]))]
    { class_ := "scroll" }

/-- A heading with its count, and the table only when there is something in it. -/
def counted (heading : String → Node .flow) (name : String) (n : Nat) (body : List (Node .flow)) :
    List (Node .flow) :=
  heading s!"{name} ({n})" :: if n == 0 then [] else body

def h2_ (s : String) : Node .flow := h2 [txt s]
def h3_ (s : String) : Node .flow := h3 [txt s]

/-- Secondary detail: small and muted. -/
def aside_ (s : String) : Node .flow := div [small [s]] { class_ := "secondary" }

def money (x : Float) : String := s!"${(x * 100).round / 100}"

/-! ## The kit -/

def brake (st : Status) : String × Tone × String :=
  if st.paused then ("paused", .stop, "No run starts, and runs under way stop at their next step.")
  else if st.draining then
    if st.drained then ("drained", .quiet, "Nothing is under way: it is safe to stop the kit.")
    else ("draining", .hold, s!"Waiting for {", ".intercalate (st.underWay.getD [])}.")
  else ("running", .go, "Agents take work as it comes.")

def noticeRows (s : Site) (now : Float) (ns : List Notice) : List (Node .tableRowOrScript) :=
  ns.map fun n =>
    row [cell [at_ now n.at_], cell [n.kind],
         cell [match n.where_ with | some w => unitLink s w | none => "-"],
         wide [n.text],
         cell [match n.seen with
           | some t => small ["seen ", at_ now t]
           | none => action (links.seen n.id) "Mark seen"]]
      (if n.seen.isNone then some "unseen" else none)

def noticeHeads : List String := ["When", "Kind", "About", "Notice", ""]

/-- Marks seen every unseen notice up to the newest shown, so that one arriving after the page was
drawn isn't marked unread. -/
def seenAll (ns : List Notice) : List (Node .flow) :=
  match ((ns.filter (·.seen.isNone)).map (·.id)).max? with
  | some newest => [p [action (links.seenTo newest) "Mark all seen"]]
  | none => []

def kitView (s : Site) (now : Float) (st : Status) : List (Node .flow) :=
  let (label, tone, says) := brake st
  let unseen := st.notices.filter (·.seen.isNone)
  let held := st.units.filter (!·.holders.isEmpty)
  let summaryLines := (st.summary.splitOn "\n").drop 1 |>.filter (!·.trimAscii.isEmpty)
  let since (unit : String) : Node .flow := match st.units.find? (·.unit == unit) with
    | some u => at_ now u.since
    | none => "-"
  let stateOf (unit : String) : String := ((st.units.find? (·.unit == unit)).map (·.state)).getD "-"
  let ok := match st.backups.okAt, st.backups.folder with
    | some t, some f => [p [txt "Last backup ", at_ now t, txt ", into ", code [f], txt "."]]
    | _, _ => [p ["No backup has succeeded yet."]]
  -- ISO times in one zone order as text does.
  let failed := (st.backups.failedAt.filter (fun t => st.backups.okAt.all (· < t))).toList.map fun t =>
    (p [txt "The backup ", at_ now t, txt s!" failed: see {(st.backups.log.filter (!·.isEmpty)).getD "scripts/backup.sh's output"}."]
      { class_ := "failed" } : Node .flow)
  ([h1 ["The kit"],
    div
      [p [badge label tone, txt " ", txt says] { id := "brake" },
       p ((if st.paused || st.draining then [action links.resume "Resume"] else
           [action links.pause "Pause" (some "Pause every agent and cancel every scheduled merge?"),
            action links.drain "Drain"]) : List (Node .phrasing)),
       -- The summary's first line says how the kit is; each line after it, one thing behind that.
       p [txt ((st.summary.splitOn "\n").headD "")] { class_ := "summary" },
       ul (summaryLines.map fun l => (li [txt (l.trimAscii.toString.dropPrefix "- ").toString] : Node .listItemOrScript))]
      { class_ := "brake" }] : List (Node .flow)) ++
  counted h2_ "Waiting on you" st.waitingOnYou.length
    [grid ["Item", "State", "Since"] (st.waitingOnYou.map fun u =>
      row [cell [unitLink s u], cell [stateOf u], cell [since u]])] ++
  counted h2_ "Unseen notices" unseen.length (grid noticeHeads (noticeRows s now unseen) :: seenAll unseen) ++
  counted h2_ "Work in progress" held.length
    [grid ["Item", "Kind", "State", "Held by", "Since"] (held.map fun u =>
      row [cell [unitLink s u.unit], cell [u.kind], cell [u.state], cell [", ".intercalate u.holders],
           cell [at_ now u.since]])] ++
  ([h2 ["CI, the forge and backups"],
   p [txt (if st.ci.isEmpty then "CI: nothing running." else s!"CI: may be running on {", ".intercalate st.ci}.")],
   p (match st.reconciled with
     | some t => [txt "Last reconciled with the forge ", at_ now t, txt "."]
     | none => ["Not yet reconciled with the forge."])] : List (Node .flow)) ++ ok ++ failed

/-! ## Agents -/

def runRows (now : Float) (runs : List Run) : List (Node .tableRowOrScript) :=
  runs.map fun r =>
    row [num (toString r.id), cell [at_ now (r.started.getD (r.claimed.getD ""))],
         cell [took now r.started r.ended], cell [outcomeBadge r.outcome],
         num ((r.cost.map money).getD "-"), num ((r.turns.map toString).getD "-"),
         num (if r.denied > 0 then toString r.denied else "-"),
         wide [aside_ ("; ".intercalate r.triggers),
               aside_ s!"session {r.sessionId.getD "-"} · log {r.log.getD "-"}"]]

def agentView (now : Float) (st : Status) (ag : Agent) : Node .flow :=
  let runs := (st.runs.filter (·.agent == ag.name)).take 5
  let owed := st.obligations.filter (·.agent == ag.name)
  section_
    (([h2 [ag.name, " ", agentBadge ag.state]] : List (Node .flow)) ++
     counted h3_ "Queued" ag.pending.length
       [grid ["Work", "Since", "Not before"] (ag.pending.map fun w =>
         row [wide [w.trigger], cell [at_ now w.since], cell [match w.after with | some t => at_ now t | none => "-"]])] ++
     counted h3_ "Owed" owed.length
       [grid ["Item", "What", "Woken", "Since", ""] (owed.map fun o =>
         row [cell [o.unit], wide [o.description], num (toString o.wakes), cell [at_ now o.since],
              cell [if o.escalated then badge "yours now" .hold else ""]])] ++
     counted h3_ "Recent runs" runs.length
       [grid ["Run", "Started", "Took", "Outcome", "Cost", "Turns", "Denied", "For"] (runRows now runs)])
    { id := s!"agent-{ag.name}" }

def agentsView (now : Float) (st : Status) : List (Node .flow) :=
  let current (ag : Agent) := st.runs.find? fun r => r.agent == ag.name && r.ended.isNone
  ([h1 ["Agents"],
   grid ["Agent", "State", "Runs today", "Spend today", "Queued", "Owed", ""] (st.agents.map fun ag =>
     row [cell [a { href := s!"#agent-{ag.name}" } [ag.name]], cell [agentBadge ag.state],
          num s!"{ag.runsToday} / {ag.cap}",
          num (money ag.spendToday ++ (match ag.spendCap with | some c => s!" / ${c}" | none => "")),
          num (toString ag.pending.length),
          num (toString (st.obligations.filter (·.agent == ag.name)).length),
          cell [p ((match current ag with
              | some r => [action (links.stopRun r.id) "Stop its run" (some s!"Interrupt {ag.name}'s run {r.id}?")]
              | none => []) ++
            [if ag.state == "stopped" then action (links.startAgent ag.name) "Start"
             else action (links.stopAgent ag.name) "Stop"] : List (Node .phrasing))]])] : List (Node .flow)) ++
  st.agents.map (agentView now st)

/-! ## Notices, activity and reviews -/

def noticesView (s : Site) (now : Float) (st : Status) : List (Node .flow) :=
  let unseen := (st.notices.filter (·.seen.isNone)).length
  ([h1 [s!"Notices ({unseen} unseen)"],
   if st.notices.isEmpty then p ["None."] else grid noticeHeads (noticeRows s now st.notices)] : List (Node .flow)) ++
  seenAll st.notices

def activityView (now : Float) (filter : String) (es : List Event) : List (Node .flow) :=
  let shown := if filter.isEmpty then es else es.filter fun e =>
    ((e.who ++ " " ++ e.text).toLower.splitOn filter.toLower).length > 1
  [h1 ["Activity"],
   form [input { type := "search", name := "q", value := filter, placeholder := "Only entries mentioning…" }]
     { method := "get", action := links.activity },
   if shown.isEmpty then p ["Nothing yet."]
   else grid ["When", "Who", "What"] (shown.reverse.map fun e =>
     row [cell [at_ now e.at_], cell [e.who], wide [e.text]])]

def reviewsView (s : Site) (now : Float) (changes : Bool) (r : Reviews) : List (Node .flow) :=
  let pulls := if changes then r.pulls.filter (·.reviews.any (·.verdict == "changes requested")) else r.pulls
  let milestones := if changes then r.milestones.filter fun m =>
      r.recommendations.any fun c => m.reports.any fun (who, _) => c.review == some who
    else r.milestones
  ([h1 ["Reviews"],
   p [s!"Pull requests updated in the last {r.days} days, and milestone reviews. ",
      a { href := if changes then links.reviews else links.reviews ++ "?changes=1" }
        [if changes then "Show every review." else "Show only reviews asking for more work."]]] : List (Node .flow)) ++
  counted h2_ "Pull requests" pulls.length
    [grid ["Pull request", "Title", "By", "", "Reviews"] (pulls.map fun pr =>
      row [cell [unitLink s pr.unit], wide [pr.title], cell [pr.author],
           cell [if pr.isOpen then badge "open" .go else badge "closed" .quiet],
           cell (pr.reviews.map fun v =>
             (p (([txt s!"{v.by_} ", verdictBadge v.verdict, txt " ", at_ now v.at_] : List (Node .phrasing)) ++
                (if v.current then [] else [small [" on an earlier head"]])) : Node .flow))])] ++
  counted h2_ "Milestones" milestones.length
    [grid ["Milestone", "Title", "", "Reports"] (milestones.map fun m =>
      row [cell [unitLink s m.unit], wide [m.title],
           cell [if m.isOpen then badge "open" .go else badge "closed" .quiet],
           cell (m.reports.map fun (who, when_) =>
             let recs := r.recommendations.filter (·.review == some who)
             (p (([txt s!"{who}, ", at_ now when_, txt s!": {recs.length} recommendation{plural recs.length "" "s"}"] : List (Node .phrasing)) ++
                (if recs.isEmpty then [] else
                  [small [txt (" (" ++ ", ".intercalate (recs.map fun c => s!"{c.unit} {c.outcome}") ++ ")")]])) : Node .flow))])]

def signInView (token : Option String) (failed : Bool) : String :=
  document
    (head (title "Sign in: the guild")
      [meta_ [("charset", "utf-8")],
       meta_ [("name", "viewport"), ("content", "width=device-width, initial-scale=1")],
       link { rel := "stylesheet", href := links.style }])
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
