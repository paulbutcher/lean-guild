/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
module

public import Guild.Dispatcher.Status

/-! Webhooks: the kit's own side effects (notices, the human's assignments, refusals), then the
units an event touched evaluated again. What anyone owes comes from the units as they are now,
never from the event itself, so a missed or late event loses nothing. Each event is also kept
for the activity stream, with what it says beyond its type read from the payload on arrival. -/

@[expose] public section

namespace Guild.Dispatcher

open Json Text

def path? (j : Json) (ks : List String) : Option Json := j.get? (ks.map .field)
def str? (j : Json) (ks : List String) : Option String := (path? j ks).bind (·.getStr?.toOption)
def nat? (j : Json) (ks : List String) : Option Nat := (path? j ks).bind (·.getNat?.toOption)
def bool? (j : Json) (ks : List String) : Option Bool := (path? j ks).bind (·.getBool?.toOption)

def names (j : Option Json) (field : String) : List String :=
  match j with
  | some (.arr xs) => xs.toList.filterMap fun x => str? x [field]
  | _ => []

/-- The issue or pull request an event is about. -/
def itemOfPayload (payload : Json) : Json :=
  (path? payload ["issue"] <|> path? payload ["pull_request"]).getD (Json.mkObj [])

def labelsOf (item : Json) : List String := names (path? item ["labels"]) "name"

/-- Labels added and removed since the item was last seen, the record updated. -/
def labelsChanged (repo : String) (n : Nat) (labels : List String) : D (List String × List String) := do
  let encoded := (toJson (labels.mergeSort (· ≤ ·))).compress
  let before ← (← db).atomically fun q => do
    let row ← q "SELECT labels FROM labels WHERE repo=? AND number=?" [repo, n]
    discard <| q "INSERT OR REPLACE INTO labels (repo, number, labels) VALUES (?,?,?)" [repo, n, encoded]
    return (row[0]?.bind fun r => (parse (r.str "labels")).toOption.bind fun j => (fromJson? (α := List String) j).toOption)
  let before := before.getD []
  return (labels.filter (!before.contains ·), before.filter (!labels.contains ·))

/-- needs-human added without the decision written out: take it off, say why, and wake the agent
that added it. Whether it was refused. -/
def refuseNeedsHuman (repo : String) (n : Nat) (body sender : String) : D Bool := do
  let e ← read
  if sender == e.human || sender == e.me then return false
  let texts := body :: (← fg (e.forge.comments repo n)).map (·.body)
  let some best := (texts.map missingSections).foldl (fun (m : Option (List String)) s => match m with
    | none => some s
    | some b => if s.length < b.length then some s else some b) none | return false
  if best.isEmpty then return false
  fg (e.forge.removeLabel repo n "needs-human")
  fg (e.forge.comment repo n
    s!"{noReply}\n\n`needs-human` is off again: a decision for the human states it so they can answer as it stands, under the headings {", ".intercalate (decisionSections.map (s!"`## {·}`"))}, in the description or one comment (Protocol: Escalate). Missing here: {", ".intercalate best}. Write them, then add the label.")
  if e.isAgent sender then
    discard <| addTrigger sender s!"nh-refused:{repo}#{n}:{(← now).floor.toUInt64}"
      s!"needs-human taken off {repo}#{n}: the decision lacks the sections your protocol asks for"
  log s!"took needs-human off {repo}#{n}, added by {sender}: missing {", ".intercalate best}"
  return true

/-- What the activity stream says about an event beyond its type. -/
def eventDetail (eventType : String) (payload : Json) (repo : String) (number : Option Nat) : D Json := do
  let item := itemOfPayload payload
  let mut d : List (String × Json) := []
  if let some title := str? item ["title"] then
    if !title.isEmpty then
      d := d ++ [("title", toJson (clipWords title 80))]
  if (eventType == "issue_label" || eventType == "pull_request_label") then
    if let some n := number then
      let labels := labelsOf item
      let row ← q "SELECT labels FROM labels WHERE repo=? AND number=?" [repo, n]
      match row[0]?.bind fun r => (parse (r.str "labels")).toOption.bind fun j => (fromJson? (α := List String) j).toOption with
      | some before =>
        d := d ++ [("added", toJson ((labels.filter (!before.contains ·)).mergeSort (· ≤ ·))),
                   ("removed", toJson ((before.filter (!labels.contains ·)).mergeSort (· ≤ ·)))]
      | none => d := d ++ [("labels", toJson (labels.mergeSort (· ≤ ·)))]
  if (path? payload ["pull_request"]).isSome && str? payload ["action"] == some "closed" then
    d := d ++ [("merged", toJson ((bool? payload ["pull_request", "merged"]).getD false))]
  if let some r := str? payload ["requested_reviewer", "login"] then d := d ++ [("reviewer", toJson r)]
  if let some c := str? payload ["comment", "body"] then d := d ++ [("no_reply", toJson !(wantsReply c))]
  if eventType.startsWith "pull_request_review" then
    if let some c := str? payload ["review", "content"] then d := d ++ [("no_reply", toJson !(wantsReply c))]
  if let some ref := str? payload ["ref"] then
    let ref := ((ref.dropPrefix "refs/heads/").toString.dropPrefix "refs/tags/").toString
    d := d ++ [("ref", toJson ref)]
    if let some t := str? payload ["ref_type"] then d := d ++ [("ref_type", toJson t)]
    match nat? payload ["total_commits"], path? payload ["commits"] with
    | some c, _ => d := d ++ [("commits", toJson c)]
    | none, some (.arr cs) => d := d ++ [("commits", toJson cs.size)]
    | _, _ => pure ()
  if let some tag := str? payload ["release", "tag_name"] then d := d ++ [("tag", toJson tag)]
  if let some run := path? payload ["run"] then
    d := d ++ [("sha", toJson (((str? run ["commit_sha"]).getD "").take 12).toString),
               ("workflow", (path? run ["workflow_id"]).getD .null)]
    let pr := (str? run ["event_payload"]).bind fun s => (parse s).toOption.bind (nat? · ["pull_request", "number"])
    match pr with
    | some p => d := d ++ [("pr", toJson p)]
    | none => d := d ++ [("ref", toJson ((str? run ["prettyref"]).getD ""))]
  return Json.mkObj d
where
  clipWords (s : String) (n : Nat) : String :=
    (" ".intercalate ((s.splitToList Char.isWhitespace).filter (!·.isEmpty)) |>.take n).toString

/-- A webhook, after it has been recorded. -/
def handle (event : String) (payload : Json) : D Unit := do
  let e ← read
  let repo := (str? payload ["repository", "name"]).getD ""
  let sender := (str? payload ["sender", "login"]).getD ""
  if ((str? payload ["repository", "owner", "login"]).getD e.org).toLower != e.org.toLower then return
  unless e.project repo do return
  -- What can start a CI run, and a run's end: whether CI runs there is checked again.
  if event == "push" || event == "create" || event == "pull_request" || event.startsWith "action_run" then
    ciMayRun repo
  let trusted := e.trusted sender
  let action := (str? payload ["action"]).getD ""
  let item := itemOfPayload payload
  let n := nat? item ["number"]
  if event == "issues" || (event == "pull_request" && action == "label_updated") then
    if let some k := n then
      let labels := labelsOf item
      let (added, removed) ← labelsChanged repo k labels
      if trusted then
        let mut labels := labels
        let mut added := added
        if added.contains "needs-human" then
          if ← refuseNeedsHuman repo k ((str? item ["body"]).getD "") sender then
            added := added.erase "needs-human"
            labels := labels.erase "needs-human"
        if (added ++ removed).any (["needs-human", "blocking", "upstream"].contains ·) && str? item ["state"] == some "open" then
          setAssigned repo k (names (path? item ["assignees"]) "login") (waitsOnHuman labels)
        if added.contains "blocking" && labels.contains "upstream" then
          notify s!"blocking:{repo}#{k}" "blocking" repo k
            "this upstream issue is marked `blocking`: an agent can't continue until it's resolved upstream. Close it or comment on it once a fix is available."
        -- A recommendation's needs-human is grouped into its review's report notice.
        if added.contains "needs-human" && sender != e.me && !labels.contains "recommendation" then
          notify s!"needs-human:{repo}#{k}:{(← now).floor.toUInt64}" "needs-human" repo k "this needs your decision (`needs-human`)."
  else if event == "issue_comment" && action == "created" && trusted then
    if let some k := n then
      let labels := labelsOf item
      -- A milestone reviewer's report: one notice per report, not per recommendation.
      if e.milestoneReviewers.contains sender &&
          (labels.contains "milestone-review" || e.config.upstreamLabels.any labels.contains) then
        notify s!"report:{sender}:{repo}#{k}" "report" repo k
          s!"the `{sender}` review has reported here. Its recommendations are issues labelled `recommendation` and `review:{sender}`: close each as accepted, or label it `declined`, say why and close it."
  else if event == "release" && action == "published" then
    -- The one notice that is an event, not a state: the coordinator hears of a release it didn't
    -- ask the gatekeeper for.
    let tag := (str? payload ["release", "tag_name"]).getD ""
    if let some c := e.coordinator? then
      if trusted && sender != e.gatekeeper && sender != c then
        discard <| addTrigger c s!"released:{repo}:{tag}" s!"{repo} released {tag}" (once := true)
    uncache s!"release:{repo}"
    if (← kvGet "rules-seeded").isSome then
      evaluateLabelled repo "needs-human"
      evaluateRelease repo
    return
  -- Until the first sweep has run, which sees every item anyway.
  if (← kvGet "rules-seeded").isNone then return
  if event == "push" then
    if str? payload ["ref"] == some "refs/heads/main" then
      uncache s!"main:{repo}"
      evaluateRepo repo (items := true)
    return
  if event.startsWith "action_run" then
    -- The rules read CI from commit statuses, which may lag the run's own event: look again later.
    let env := e
    if str? payload ["run", "event"] == some "push" then
      evaluateRelease repo
      e.later 30 do try (evaluateRelease repo).run env catch err => env.log s!"evaluating {repo}'s release again failed: {err}"
      return
    let pr := (str? payload ["run", "event_payload"]).bind fun s => (parse s).toOption.bind (nat? · ["pull_request", "number"])
    if let some p := pr then
      e.later 30 do try (evaluate repo p).run env catch err => env.log s!"evaluating {repo}#{p} again failed: {err}"
  if let some k := n then evaluate repo k
  if event == "issues" then
    if (labelsOf item).contains "ready-for-release" ||
        ["closed", "reopened", "label_updated", "label_cleared"].contains action then
      evaluateRelease repo
    if ["opened", "closed", "reopened", "milestoned", "demilestoned"].contains action then
      evaluateMilestones

/-! ## Activity -/

def describeEvent (e : Env) (r : Row) : String :=
  let d := (parse (r.str "detail")).toOption.getD (Json.mkObj [])
  let t := r.str "type"
  let a := r.str "action"
  let repo := (r.str? "repo").getD "?"
  let where_ := match r.nat? "number" with | some k => if k > 0 then s!"{repo}#{k}" else repo | none => repo
  let title := match str? d ["title"] with | some s => s!" “{s}”" | none => ""
  let quiet := if bool? d ["no_reply"] == some true then " (no reply needed)" else ""
  let ref := (str? d ["ref"]).getD ""
  if t == "push" then
    match nat? d ["commits"] with
    | some c => s!"pushed {c} commit{plural c "" "s"} to {repo} {ref}"
    | none => s!"pushed to {repo}"
  else if t == "create" || t == "delete" then
    if ref.isEmpty then s!"{t}d a branch or tag in {repo}" else s!"{t}d {(str? d ["ref_type"]).getD "ref"} {repo} {ref}"
  else if t == "issues" then s!"{a} issue {where_}{if a == "opened" then title else ""}"
  else if t == "issue_label" || t == "pull_request_label" then
    match path? d ["labels"] with
    | some ls => s!"labels on {where_}: {match fromJson? (α := List String) ls with | .ok l => if l.isEmpty then "none" else ", ".intercalate l | _ => "none"}"
    | none =>
      let get (k : String) := ((path? d [k]).bind fun j => (fromJson? (α := List String) j).toOption).getD []
      let changes := (get "added").map ("+" ++ ·) ++ (get "removed").map ("-" ++ ·)
      if changes.isEmpty then s!"labelled {where_}" else s!"labelled {where_}: {" ".intercalate changes}"
  else if t == "pull_request_review_request" then
    match str? d ["reviewer"] with
    | some w => s!"asked {if w == e.human then "you" else w} to review {where_}"
    | none => s!"requested a review on {where_}"
  else if t == "pull_request_sync" then s!"pushed to pull request {where_}"
  else if t == "pull_request" then
    if a == "closed" then
      match bool? d ["merged"] with
      | some true => s!"merged pull request {where_}{title}"
      | some false => s!"closed pull request {where_} unmerged"
      | none => s!"closed pull request {where_}"
    else s!"{a} pull request {where_}{if a == "opened" then title else ""}"
  else if t == "pull_request_review_approved" then s!"approved {where_}{quiet}"
  else if t == "pull_request_review_rejected" then s!"requested changes on {where_}"
  else if ["pull_request_review_comment", "pull_request_comment", "issue_comment"].contains t then s!"commented on {where_}{quiet}"
  else if t == "action_run_success" || t == "action_run_failure" then
    let on := match nat? d ["pr"] with
      | some p => s!"{repo}#{p}"
      | none => s!"{repo} {ref}".trimAscii.toString
    let on := if (r.str? "repo").isSome then s!" on {on}" else ""
    let sha := match str? d ["sha"] with | some s => if s.isEmpty then "" else s!" at {s}" | none => ""
    s!"CI {if t.endsWith "success" then "passed" else "failed"}{on}{sha}"
  else if t == "release" then
    match str? d ["tag"] with | some tag => s!"released {repo} {tag}" | none => s!"published a release of {repo}"
  else if t == "issue_assign" || t == "pull_request_assign" then s!"{a} {where_}"
  else s!"{t} {a} {where_}".replace "  " " "

/-- The kit's activity, oldest first: forge events, queued work, runs, the human's sessions and
notices, after `after`, at most `limit`, the newest kept. -/
def activity (after : Float) (limit : Nat) : D Json := do
  let e ← read
  let you (who : String) := if who == e.human then "you" else if who.isEmpty then "?" else who
  let mut out : List (Float × Json) := []
  let entry (id : String) (at_ : Float) (who text : String) : Float × Json :=
    (at_, Json.mkObj [("id", toJson id), ("at", toJson (Time.iso at_)), ("who", toJson who), ("text", toJson text)])
  for r in ← q "SELECT * FROM events WHERE at>? ORDER BY at DESC LIMIT ?" [after, limit] do
    let who := if (r.str "type").startsWith "action_run" then "ci" else you (r.str "sender")
    out := entry s!"e{r.nat "id"}" (r.real "at") who (describeEvent e r) :: out
  for r in ← q "SELECT * FROM triggers WHERE created>? ORDER BY created DESC LIMIT ?" [after, limit] do
    let wait := match r.real? "not_before" with
      | some nb => if nb > r.real "created" + 1 then s!" (from {(Time.iso nb).drop 11 |>.take 5})" else ""
      | none => ""
    out := entry s!"t{r.nat "id"}" (r.real "created") (r.str "agent") s!"queued: {r.str "description"}{wait}" :: out
  for r in ← q "SELECT * FROM runs WHERE claimed>? OR ended>? ORDER BY id DESC LIMIT ?" [after, after, limit] do
    if (r.real? "claimed").any (· > after) then
      let ts := ((parse (r.str "triggers")).toOption.bind fun j => (fromJson? (α := List String) j).toOption).getD []
      out := entry s!"r{r.nat "id"}s" (r.real "claimed") (r.str "agent") s!"run {r.nat "id"} started: {"; ".intercalate ts}" :: out
    if let some ended := r.real? "ended" then
      if ended > after then
        let denied := match parse (r.str "denied") with | .ok (.arr xs) => xs.size | _ => 0
        let bits := [(r.str? "outcome").getD "ended"] ++
          ((r.real? "cost").map money).toList ++
          ((r.nat? "forge_changes").map fun c => s!"{c} forge change{plural c "" "s"}").toList ++
          (if denied > 0 then [s!"{denied} denied"] else [])
        out := entry s!"r{r.nat "id"}e" ended (r.str "agent") s!"run {r.nat "id"} ended: {", ".intercalate bits}" :: out
  for s in ← q "SELECT * FROM sessions WHERE started>? OR ended>? ORDER BY id DESC LIMIT ?" [after, after, limit] do
    if (s.real? "started").any (· > after) then
      out := entry s!"s{s.nat "id"}s" (s.real "started") "you" s!"session started in {s.str "agent"}'s container" :: out
    if (s.real? "ended").any (· > after) then
      out := entry s!"s{s.nat "id"}e" (s.real "ended") "you" s!"session ended in {s.str "agent"}'s container" :: out
  for n in ← q "SELECT * FROM notices WHERE at>? ORDER BY id DESC LIMIT ?" [after, limit] do
    let where_ := match n.nat? "number" with | some k => if k > 0 then s!"{n.str "repo"}#{k}" else n.str "repo" | none => n.str "repo"
    out := entry s!"n{n.nat "id"}" (n.real "at") "kit" s!"notice for you ({n.str "kind"}): {where_}" :: out
  let sorted := out.mergeSort (·.1 ≤ ·.1)
  return Json.arr ((sorted.drop (sorted.length - limit)).map (·.2)).toArray

end Guild.Dispatcher
