/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
module

public import Guild.Dispatcher.Facts

/-! What an item asks of agents beyond its state: notices, each something to look at once, and
asks, each owed until the agent acts on the item. The numbers are the reference's DESIGN.md's. -/

@[expose] public section

namespace Guild.Dispatcher

open Guild.Forge Text

/-- The kinds of notice, which a claim checks are still owed. -/
def ruleKinds : List String :=
  ["upstream-comment", "rejected", "filed", "pr-opened", "nh", "upstream-blocking", "priority"]

def labelAdds (it : Item) (label : String) : List Entry :=
  it.events.filter fun e => match e.event with | .label l true => l == label | _ => false

def labelChanges (it : Item) (label : String) : List Entry :=
  it.events.filter fun e => match e.event with | .label l _ => l == label | _ => false

/-- What an item asks agents to look at, once. -/
def notices (it : Item) : D (List Owed) := do
  let e ← read
  let at_ := it.at_
  let mut o : List Owed := []
  -- 28. Made a priority by someone else: before anything new.
  if let some owner := it.owner then
    if let some added := (labelAdds it "priority").getLast? then
      if it.isOpen && !it.isPull && it.has "priority" && added.actor != owner then
        o := o ++ [{ agent := owner, key := s!"priority:{at_}:{added.time}",
                     description := s!"{at_} is now a priority: it comes before anything new (Protocol: Priority)" }]
  -- 11. A request closed without being verified, by someone else: rejected.
  let req := it.author
  if !it.isPull && !it.isOpen && it.has "request" && !it.has "verified" &&
      ((e.agent? req).bind (·.owns)).isSome && some req != it.owner then
    let closes := it.events.filter fun ev => match ev.event with | .closed => true | _ => false
    if let some c := closes.getLast? then
      if c.actor != req then
        o := o ++ [{ agent := req, key := s!"rejected:{at_}:{c.time}",
                     description := s!"your request {at_} was closed without being verified" }]
  if let some c := e.coordinator? then
    -- 12. A request filed by someone else: check it's well formed and placed.
    if it.isOpen && !it.isPull && it.has "request" && e.trusted it.author && it.author != c then
      o := o ++ [{ agent := c, key := s!"filed:{at_}:", description := s!"request filed: {at_}" }]
    -- 13. A pull request opened by an agent: check its scope, once CI has finished or a while
    --     has passed, so that a review asked of the coordinator shares the run. Not the human's,
    --     nor one that changes only CHANGELOG.md, which the coordinator checks when it releases.
    if it.isPull && e.trusted it.author && it.author != c && it.author != e.human &&
        (it.isOpen || it.pull.merged) then
      if (← it.files) != ["CHANGELOG.md"] then
        let settled ← if !it.isOpen || !e.hasCi it.repo then pure true else do
          let ci ← it.ci
          pure (ci == .success || ci == .failure)
        o := o ++ [{ agent := c, key := s!"pr-opened:{at_}:", description := s!"pull request opened: {at_}",
                     notBefore := if settled then none else some (Time.when it.pull.createdAt + e.timings.openedHold) }]
    -- 16. needs-human added or removed by someone else, and the coordinator hasn't looked since.
    --     Not on a recommendation the human decides, which the coordinator never takes on.
    let theirs := it.has "recommendation" && e.config.humanDecidesLabels.any it.has
    if let some nh := (labelChanges it "needs-human").getLast? then
      let added := match nh.event with | .label _ a => a | _ => false
      if !theirs && nh.actor != c && nh.actor != e.me &&
          it.by_ c (fun ev => Item.isComment ev || Item.isLabel ev) < Time.when nh.time then
        o := o ++ [{ agent := c, key := s!"nh:{at_}:{nh.time}",
                     description := s!"needs-human {if added then "added to" else "removed from"} {it.kind} {at_}" }]
  -- 22. An upstream issue that blocks an agent, for whoever tracks that upstream project.
  if it.repo == e.coordination && !it.isPull && it.isOpen && it.has "upstream" && it.has "blocking" then
    for u in e.config.upstreams do
      if let some t := u.tracker then
        if it.has s!"upstream:{u.name}" then
          o := o ++ [{ agent := t, key := s!"upstream-blocking:{at_}:", description := s!"blocking {u.title} issue {at_}" }]
  return o.filter (e.isAgent ·.agent)

/-- Whether the agent's action at `acted` came from a run that started before `asked`: a run under
way when a comment arrived was briefed without it, so what it did afterwards doesn't answer it. -/
def actedInEarlierRun (agent : String) (asked acted : Float) : D Bool := do
  return !(← q "SELECT 1 FROM runs WHERE agent=? AND claimed<=? AND (ended IS NULL OR ended>=?)"
    [agent, asked, acted]).isEmpty

/-- Order in the timeline: time, then position, since times are to the second. -/
def before (a b : Float × Int) : Bool := a.1 < b.1 || (a.1 == b.1 && a.2 < b.2)

/-- What is asked of agents on an item, as (agent, what, description): each owes an answer until
it acts there. -/
def asks (it : Item) : D (List (String × String × String)) := do
  let e ← read
  let at_ := it.at_
  let link (id : Nat) := s!"{e.link it.repo it.n}#issuecomment-{id}"
  let mut o : List (String × String × String) := []
  let indexed := it.events.zipIdx
  -- 2. A comment or review from someone else that wants a reply, newer than anything the owner
  --    has done here, or answered only by a run that started before it. An approval asks
  --    nothing; a request for changes always asks. It names who asked and links the comment.
  if let some owner := it.owner then
    if it.isOpen then
      let placed (r : Review) : Float × Int :=
        (Time.when r.submittedAt, ((indexed.find? fun (ev, _) => match ev.event with
          | .review => ev.actor == r.author && ev.time == r.submittedAt
          | _ => false).map (fun (_, i) => (i : Int))).getD (-1))
      let fromComments := indexed.filterMap fun (ev, i) => match ev.event with
        | .comment id body =>
          if e.trusted ev.actor && ev.actor != owner && Text.asks body then
            some ((Time.when ev.time, (i : Int)), s!"reply:{id}", s!"comment on {it.kind} {at_} from {ev.actor}: {link id}")
          else none
        | _ => none
      let fromReviews := it.reviews.filterMap fun r =>
        if e.trusted r.author && r.author != owner && !r.submittedAt.isEmpty &&
            (r.verdict == .requestChanges || (r.verdict == .comment && Text.asks r.body)) then
          some (placed r, s!"reply:review-{r.id}",
            s!"{if r.verdict == .requestChanges then "changes requested on" else "review on"} pull request {at_} by {r.author} (`forge reviews {it.repo} {it.n}`)")
        else none
      let found := fromComments ++ fromReviews
      let latest := found.foldl (fun (m : Option ((Float × Int) × String × String)) x => match m with
        | none => some x
        | some y => if before y.1 x.1 || (y.1 == x.1 && y.2.1 < x.2.1) then some x else some y) none
      if let some (t, what, desc) := latest then
        let acts := (indexed.filter fun (ev, _) => ev.actor == owner).map (fun (ev, i) => (Time.when ev.time, (i : Int))) ++
          (it.reviews.filter fun r => r.author == owner && !r.submittedAt.isEmpty).map placed
        let acted := acts.foldl (fun m x => if before m x then x else m) (0, 0)
        if before acted t || (← actedInEarlierRun owner t.1 acted.1) then
          o := o ++ [(owner, what, desc)]
  -- 26. A comment by the human that mentions an agent which hasn't acted since: the human's way
  --     to reach an agent other than the owner. The supervisor's mentions reach the owner too, at
  --     most `supervisorNudges` of its comments a day on one item. The owner's mention of a
  --     request's requester reaches the requester, if it wants a reply. Others' reach no one.
  let sup := e.supervisor?
  let mine := it.comments.filter fun (_, who, _, _) => some who == sup
  let requester := if !it.isPull && it.has "request" && some it.author != it.owner then some it.author else none
  let mut mentioned : List (String × String × String × String) := []
  for (id, who, body, time) in it.comments do
    let t := Time.when time
    let counts : Bool :=
      if some who == sup then
        let day := mine.filter fun (_, _, _, m) => t - 86400 < Time.when m && Time.when m ≤ t
        decide (day.length ≤ e.bounds.supervisorNudges)
      else if some who == it.owner && requester.isSome && who != e.human then wantsReply body
      else who == e.human
    unless counts do continue
    let by_ := if who == e.human then "the human" else if some who == sup then "the supervisor"
      else s!"{who}, its owner,"
    for name in mentions body do
      if who != e.human && some who != sup && some name != requester then continue
      if e.isAgent name && name != who && (some name != it.owner || some who == sup) && it.by_ name < t then
        mentioned := (mentioned.filter (·.1 != name)) ++
          [(name, s!"mention:{id}", s!"{by_} mentioned you on {it.kind} {at_}: {link id}", "")]
  o := o ++ mentioned.map fun (a, w, d, _) => (a, w, d)
  -- 30. A closed item's latest `Waiting-on: <agent>` line, which that agent hasn't acted on since.
  --     On an open item it is a hold.
  if !it.isOpen then
    if let some (who, (id, writer, _, _)) := it.waitingOn e then
      o := o ++ [(who, s!"waiting:{id}", s!"{writer} is waiting on you on {it.kind} {at_}: {link id}")]
  return o.filter fun (a, _, _) => e.isAgent a

end Guild.Dispatcher
