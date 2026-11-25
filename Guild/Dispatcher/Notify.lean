/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
module

public import Guild.Dispatcher.Item

/-! What the kit tells the human: a notice once per key, as a comment that mentions them or as a
decision of the kit's own, and the daily caps that hold an agent's work back. -/

@[expose] public section

namespace Guild.Dispatcher

open Text

/-- A comment as the dispatcher, mentioning the human, so it shows in their notifications. -/
def commentHuman (repo : String) (n : Nat) (text : String) : D Unit := do
  let e ← read
  fg (e.forge.comment repo n s!"{noReply}\n\n@{e.human} {text}")

/-- Once per key: a notice, and a comment on the item that mentions the human. -/
def notify (key kind repo : String) (n : Nat) (text : String) : D Unit := do
  unless ← addNotice key kind repo n text do return
  try
    commentHuman repo n text
    exec "UPDATE notices SET posted=1 WHERE key=?" [key]
    log s!"notified {(← read).human}: {repo}#{n}: {kind}"
  catch err => log s!"couldn't post the notice for {repo}#{n}: {err}"

/-- A decision for the human from the kit itself: once per key, an issue labelled needs-human
and assigned to them, with a decision's sections. -/
def decisionIssue (repo key kind title : String) (sections : List (String × String)) : D Unit := do
  let e ← read
  unless ← addNotice key kind repo none title do return
  try
    let body := s!"{noReply}\n\n" ++ "\n\n".intercalate (decisionSections.map fun h =>
      s!"## {h}\n\n{((sections.lookup h).getD "").trimAscii}")
    let n ← fg (e.forge.createIssue repo { title, body, labels := ["needs-human"], assignees := [e.human] })
    exec "UPDATE notices SET posted=1, number=? WHERE key=?" [n, key]
    log s!"asked {e.human} to decide {repo}#{n}: {title}"
  catch err => log s!"couldn't open the decision '{title}' on {repo}: {err}"

/-- A decision about an agent rather than an item: on the agent's repository, or the coordination
repository for one that owns none. -/
def notifyAgent (agent key kind title : String) (sections : List (String × String)) : D Unit := do
  let e ← read
  decisionIssue (((e.agent? agent).bind (·.owns)).getD e.coordination) key kind title sections

/-! ## Caps -/

/-- Midnight UTC today: caps are per UTC day. -/
def dayStart : D Float := do return ((← now) / 86400).floor * 86400

/-- Runs claimed today, except those that never got going: retrying through an outage mustn't
use up the agent's day. -/
def runsToday (agent : String) : D Nat := do
  let rows ← q "SELECT COUNT(*) AS n FROM runs WHERE agent=? AND claimed>=?
    AND NOT (ended IS NOT NULL AND turns IS NOT NULL AND turns<=1 AND COALESCE(cost, 0)=0
             AND COALESCE(forge_changes, 0)=0 AND outcome NOT IN ('completed', 'interrupted'))" [agent, ← dayStart]
  return (rows[0]?.map (·.nat "n")).getD 0

def spendToday (agent : String) : D Float := do
  let rows ← q "SELECT COALESCE(SUM(cost), 0) AS s FROM runs WHERE agent=? AND claimed>=?" [agent, ← dayStart]
  return (rows[0]?.map (·.real "s")).getD 0

def money (x : Float) : String :=
  let cents := (x * 100).round.toUInt64.toNat
  s!"${cents / 100}.{if cents % 100 < 10 then "0" else ""}{cents % 100}"

/-- Why the agent can't start another run today, if it can't. -/
def capped (agent : String) : D (Option String) := do
  let e ← read
  if (← runsToday agent) ≥ e.capOf agent then return some s!"its daily cap of {e.capOf agent} runs"
  if let some cap := e.bounds.maxSpendPerDay then
    if cap > 0 && (← spendToday agent) ≥ cap.toFloat then
      return some s!"its daily spending cap of {money cap.toFloat}"
  return none

end Guild.Dispatcher
