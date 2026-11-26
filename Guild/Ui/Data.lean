/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
module

public import Json

/-! What the pages show, read from the dispatcher's JSON. A field that is missing or of another
type reads as its default, so a dispatcher a version behind still draws a page. -/

@[expose] public section

namespace Guild.Ui

open Json

def field {α} [FromJson α] (j : Json) (k : String) (d : α) : α :=
  ((j.getObjVal? k).toOption.bind fun v => (fromJson? v).toOption).getD d

def field? {α} [FromJson α] (j : Json) (k : String) : Option α :=
  (j.getObjVal? k).toOption.bind fun v => (fromJson? v).toOption

def list (j : Json) (k : String) : List Json :=
  match j.getObjVal? k with
  | .ok (.arr xs) => xs.toList
  | _ => []

/-- The ledger keeps flags as integers. -/
def flag (j : Json) (k : String) : Bool :=
  field? (α := Bool) j k |>.getD (field (α := Nat) j k 0 != 0)

structure Pending where
  trigger : String
  since : String
  after : Option String

structure Agent where
  name : String
  state : String
  runsToday : Nat
  cap : Nat
  spendToday : Float
  spendCap : Option Nat
  pending : List Pending

structure Run where
  id : Nat
  agent : String
  triggers : List String
  claimed : Option String
  started : Option String
  ended : Option String
  outcome : Option String
  cost : Option Float
  turns : Option Nat
  sessionId : Option String
  log : Option String
  inExtension : Bool
  forgeChanges : Option Nat
  denied : Nat

structure Notice where
  id : Nat
  at_ : String
  kind : String
  repo : Option String
  number : Option Nat
  text : String
  posted : Bool
  seen : Option String

/-- `repo#n`, or the repository alone, or nothing, for where a notice is about. -/
def Notice.where_ (n : Notice) : Option String :=
  match n.repo, n.number with
  | some r, some k => if k > 0 then some s!"{r}#{k}" else some r
  | some r, none => some r
  | none, _ => none

structure Owed where
  unit : String
  agent : String
  description : String
  since : String
  wakes : Nat
  escalated : Bool

structure UnitState where
  unit : String
  kind : String
  state : String
  holders : List String
  step : String
  since : String

structure Status where
  paused : Bool
  draining : Bool
  drained : Bool
  underWay : Option (List String)
  reconciled : Option String
  stopped : List String
  waitingOnYou : List String
  /-- Repositories where CI may be running. -/
  ci : List String
  agents : List Agent
  runs : List Run
  notices : List Notice
  obligations : List Owed
  units : List UnitState
  summary : String

def Status.ofJson (j : Json) : Status :=
  let agents := match j.getObjVal? "agents" with
    | .ok (.obj fields) => fields.toList.map fun (name, a) =>
      { name, state := field a "state" "", runsToday := field a "runs_today" 0, cap := field a "cap" 0,
        spendToday := field a "spend_today" 0, spendCap := field? a "spend_cap",
        pending := (list a "pending").map fun p =>
          { trigger := field p "trigger" "", since := field p "since" "", after := field? p "after" } }
    | _ => []
  { paused := flag j "paused", draining := flag j "draining", drained := flag j "drained",
    underWay := field? j "under_way", reconciled := field? j "reconciled",
    stopped := field j "stopped" [], waitingOnYou := field j "waiting_on_you" [], ci := field j "ci" [],
    agents,
    runs := (list j "runs").map fun r =>
      { id := field r "id" 0, agent := field r "agent" "", triggers := field r "triggers" [],
        claimed := field? r "claimed", started := field? r "started", ended := field? r "ended",
        outcome := field? r "outcome", cost := field? r "cost", turns := field? r "turns",
        sessionId := field? r "session_id", log := field? r "log", inExtension := flag r "in_extension",
        forgeChanges := field? r "forge_changes", denied := (list r "denied").length },
    notices := (list j "notices").map fun n =>
      { id := field n "id" 0, at_ := field n "at" "", kind := field n "kind" "", repo := field? n "repo",
        number := field? n "number", text := field n "text" "", posted := flag n "posted",
        seen := field? n "seen" },
    obligations := (list j "obligations").map fun o =>
      { unit := field o "unit" "", agent := field o "agent" "", description := field o "description" "",
        since := field o "since" "", wakes := field o "wakes" 0, escalated := flag o "escalated" },
    units := (list j "units").map fun u =>
      { unit := field u "unit" "", kind := field u "kind" "", state := field u "state" "",
        holders := field u "holders" [], step := field u "step" "", since := field u "since" "" },
    summary := field j "summary" "" }

structure Event where
  at_ : String
  who : String
  text : String

def events (j : Json) : List Event :=
  match j with
  | .arr xs => xs.toList.map fun e => { at_ := field e "at" "", who := field e "who" "", text := field e "text" "" }
  | _ => []

structure Verdict where
  by_ : String
  verdict : String
  at_ : String
  current : Bool

structure PullReviews where
  unit : String
  title : String
  author : String
  isOpen : Bool
  reviews : List Verdict

structure Milestone where
  unit : String
  title : String
  isOpen : Bool
  /-- Who reported, and when. -/
  reports : List (String × String)

structure Recommendation where
  unit : String
  title : String
  review : Option String
  outcome : String

structure Reviews where
  days : Nat
  pulls : List PullReviews
  milestones : List Milestone
  recommendations : List Recommendation

def Reviews.ofJson (j : Json) : Reviews :=
  { days := field j "days" 7,
    pulls := (list j "pulls").map fun p =>
      { unit := field p "unit" "", title := field p "title" "", author := field p "author" "",
        isOpen := flag p "open",
        reviews := (list p "reviews").map fun v =>
          { by_ := field v "by" "", verdict := field v "verdict" "", at_ := field v "at" "",
            current := flag v "current" } },
    milestones := (list j "milestones").map fun m =>
      { unit := field m "unit" "", title := field m "title" "", isOpen := flag m "open",
        reports := (list m "reports").map fun r => (field r "by" "", field r "at" "") },
    recommendations := (list j "recommendations").map fun r =>
      { unit := field r "unit" "", title := field r "title" "", review := field? r "review",
        outcome := field r "outcome" "" } }

end Guild.Ui
