/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
module

public import Guild.Gatekeeper
public import Guild.Forge.Forgejo
import JsonDeriving

/-! `forge`: what agents do on the forge that `tea` lacks, or that must follow a rule `tea` can't
enforce. It acts with the agent's own token. -/

@[expose] public section

namespace Guild.Agent

open Guild.Forge Guild.Gatekeeper Guild.Version Json

def usage : String := "usage:
  forge pr automerge <n>          merge your pull request #n now if nothing stands in its way, else
                                  schedule \"merge when checks succeed\": it waits for the approvals
                                  your repository's autonomy level requires
  forge pr merge <n>              merge your pull request #n now, or say why the forge won't
  forge ci <repo> <pr|main>       CI for the pull request's head commit (or main's): success,
                                  failure, running or none, and how many times it was re-run
  forge ci <repo> <pr|main> --log [all]
                                  the log of each failed job in that run (each job's, if none
                                  failed): its last 200 lines, or all of them
  forge ci <repo> <pr|main> --rerun
                                  run that run again, if it failed: only when its log shows the
                                  failure is the runner's, not the code's, and within the limit
  forge pr approve <repo> <n> <message>
                                  (the coordinator) approve, only if CI for the head succeeded
  forge review <repo> <n> <findings.json>
                                  (the reviewer) review the pull request's head: approves if no
                                  finding is open (new, kept or agreed), requests changes otherwise,
                                  and past the rounds limit puts the findings the author disputes
                                  (kept) to the human instead, once per head. The file is
                                  {\"summary\": \"...\", \"findings\": [{\"section\": \"<CLAUDE.md or
                                  protocol section>\", \"finding\": \"...\", \"status\":
                                  \"new|kept|agreed|fixed|withdrawn\"}]}
  forge reviews <repo> <n>        the pull request's reviews: who, verdict, commit and text
  forge ledger [days]             (the supervisor) the run ledger for the last days (default 30)
  forge version                   in your checkout: the next release's version, from API.lock in
                                  your working tree against the last vX.Y.Z tag, as the gatekeeper
                                  computes it. Head your CHANGELOG.md entry with it
  forge release <repo> <note> [<issue>...]
                                  (the coordinator, level 3) ask the gatekeeper to release <repo>

<repo> is a repository name; pull requests are numbers."

structure Cli where
  forge : Forge
  /-- The agent's own repository, if it owns one. -/
  own : Option Repo
  coordinator : Option String
  reviewer : Option String
  supervisor : Option String
  rerunLimit : Nat
  reviewRounds : Nat
  /-- Waits out the forge's short spells of checking mergeability. -/
  pause : Nat → IO Unit

/-- What a command prints, or why it refuses. -/
abbrev Out := ExceptT String M

def refuse (m : String) : Out α := throw m

def liftM' (x : M α) : Out α := ExceptT.lift x

/-! ## CI -/

/-- CI for a commit, from all its runs. -/
def ciState (runs : List Run) : Ci :=
  if runs.isEmpty then .none
  else if runs.any (fun r => [RunStatus.failure, .cancelled, .skipped, .blocked].contains r.status) then .failure
  else if runs.all (·.status == .success) then .success
  else .running

def Cli.headOf (c : Cli) (repo : Repo) (target : Option Nat) : Out String := do
  match target with
  | none =>
    let some b ← liftM' (c.forge.branch repo "main") | refuse s!"{repo} has no main branch"
    return b.sha
  | some n =>
    let some p ← liftM' (c.forge.pull repo n) | refuse s!"{repo}#{n} isn't a pull request"
    return p.headSha

def Cli.ci (c : Cli) (repo : Repo) (target : Option Nat) : Out (String × Ci) := do
  let sha ← c.headOf repo target
  return (sha, ciState (← liftM' (c.forge.runs repo sha)))

def times (n : Nat) : String := if n == 1 then "once" else if n == 2 then "twice" else s!"{n} times"

def Cli.ciReport (c : Cli) (repo : Repo) (target : Option Nat) : Out (String × Bool) := do
  let (sha, state) ← c.ci repo target
  let reruns ← liftM' (c.forge.reruns repo sha)
  let note := if reruns == 0 then "" else s!"; re-run {times reruns} of the {c.rerunLimit} allowed"
  return (s!"{state.name} ({sha.take 12}){note}", state == .success)

/-- A log line without the runner's timestamp. -/
def unstamp (line : String) : String :=
  match line.splitOn " " with
  | first :: rest =>
    if first.length ≥ 20 && first.endsWith "Z" && (first.take 4).all Char.isDigit && (first.drop 4).startsWith "-" then
      " ".intercalate rest
    else line
  | [] => line

def logLines : Nat := 200

def Cli.ciLogs (c : Cli) (repo : Repo) (target : Option Nat) (everything : Bool) : Out String := do
  let sha ← c.headOf repo target
  let some run := (← liftM' (c.forge.runs repo sha)).head? | refuse s!"no CI run for {sha.take 12} in {repo}"
  let jobs ← liftM' (c.forge.jobs repo run.id)
  let failed := jobs.filter (·.status == .failure)
  let mut out := ""
  for j in if failed.isEmpty then jobs else failed do
    let lines := ((← liftM' (c.forge.jobLog repo j.id)).splitOn "\n").map unstamp
    let lines := if !lines.isEmpty && lines.getLast? == some "" then lines.dropLast else lines
    out := out ++ s!"=== {repo} run {run.id}, job {j.name}: {j.status.name} ({sha.take 12})\n"
    let shown := if !everything && lines.length > logLines then
        s!"(the first {lines.length - logLines} lines are left out; --log all shows them)" :: lines.drop (lines.length - logLines)
      else lines
    out := out ++ "\n".intercalate shown ++ "\n"
  return out

/-- Runs the newest run for the head again, if it failed, and if the head's re-runs, counted from
the forge, are within the limit. -/
def Cli.rerun (c : Cli) (repo : Repo) (target : Option Nat) : Out String := do
  let sha ← c.headOf repo target
  let some run := (← liftM' (c.forge.runs repo sha)).head? | refuse s!"no CI run for {sha.take 12} in {repo}"
  unless run.status == .failure || run.status == .cancelled do
    refuse s!"run {run.id} for {sha.take 12} is {run.status.name}: only a failed run is run again"
  let reruns ← liftM' (c.forge.reruns repo sha)
  if reruns ≥ c.rerunLimit then
    refuse (s!"{sha.take 12} has been re-run {times reruns}, the limit: a run that fails the same way again " ++
      "isn't the runner. Fix the cause, or say on an issue what's wrong; the human is told.")
  liftM' (c.forge.rerun repo run.id)
  return s!"Running {repo}'s run {run.id} for {sha.take 12} again ({reruns + 1} of the {c.rerunLimit} re-runs allowed)."

/-! ## Merging -/

def mergeWaits : List Nat := [2, 4, 8, 15, 30]

/-- A merge through the forge's short spells of checking mergeability, for about a minute. -/
def Cli.mergeCall (c : Cli) (repo : Repo) (n : Nat) (schedule : Bool) : Out MergeResult := do
  for w in mergeWaits do
    match ← liftM' (c.forge.merge repo n schedule) with
    | .tryLater => c.pause w
    | r => return r
  liftM' (c.forge.merge repo n schedule)

/-- A direct merge first: the forge acts on a scheduled merge only when a review or a status
arrives after it, so one scheduled once everything passed would never fire. -/
def Cli.merge (c : Cli) (n : Nat) (schedule : Bool) : Out String := do
  let some repo := c.own | refuse "you own no repository to merge into"
  match ← c.mergeCall repo n false with
  | .merged => return s!"#{n} merged."
  | r =>
    if !schedule then
      match r with
      | .refused m => refuse s!"#{n} didn't merge: {m}"
      | _ => refuse s!"#{n} didn't merge: the forge is still checking it; try again"
    match ← c.mergeCall repo n true with
    | .scheduled | .merged => return s!"#{n} will merge once its checks succeed and it has the approvals it needs."
    | .refused m => refuse s!"couldn't schedule the merge of #{n}: {m}"
    | .tryLater => refuse s!"couldn't schedule the merge of #{n}: the forge is still checking it; try again"

/-! ## Reviews -/

inductive Status where
  | new | kept | agreed | fixed | withdrawn | escalated
  deriving BEq, Repr

def Status.ofString : String → Option Status
  | "new" => some .new | "kept" => some .kept | "agreed" => some .agreed
  | "fixed" => some .fixed | "withdrawn" => some .withdrawn | _ => none

def Status.name : Status → String
  | .new => "new" | .kept => "kept" | .agreed => "agreed" | .fixed => "fixed"
  | .withdrawn => "withdrawn" | .escalated => "escalated"

/-- `kept`: the author disputes it; `agreed`: the author accepts it and hasn't fixed it yet. Both
stay open, but only a dispute is the human's to decide. -/
def Status.isOpen (s : Status) : Bool := s == .new || s == .kept || s == .agreed

structure Finding where
  /-- The section of `CLAUDE.md` or the protocol it breaks. -/
  rule : String
  finding : String
  status : Status

structure RawFinding where
  «section» : String
  finding : String
  status : String
  deriving FromJson

structure RawFindings where
  summary : String
  findings : Option (List RawFinding)
  deriving FromJson

def findingsOf (text : String) : Except String (String × List Finding) := do
  let j ← (parse text).mapError toString
  let r : RawFindings ← fromJson? j
  let fs ← (r.findings.getD []).mapM fun f => do
    let some status := Status.ofString f.status
      | throw "each finding needs a section, a finding and a status: new, kept, agreed, fixed or withdrawn"
    if f.«section».isEmpty || f.finding.isEmpty then
      throw "each finding needs a section, a finding and a status: new, kept, agreed, fixed or withdrawn"
    return { rule := f.«section», finding := f.finding, status }
  return (r.summary, fs)

def marker : String := "conformance-findings"

def render (summary : String) (findings : List Finding) (round rounds : Nat) (escalated : Bool := false)
    (commit : Option String := none) : String :=
  let numbered := (List.range findings.length).zip findings |>.map fun (i, f) =>
    s!"{i + 1}. **{f.rule}**: {f.finding.trimAscii} *({f.status.name})*"
  let body := if findings.isEmpty then ["No findings: this follows `CLAUDE.md` and the protocol."]
    else s!"**Findings** (round {round} of {rounds}):" :: numbered
  let record := Json.mkObj ([("round", toJson round), ("escalated", toJson escalated),
    ("findings", Json.arr (findings.map fun f => Json.mkObj [("section", toJson f.rule),
      ("status", toJson f.status.name)]).toArray)] ++ (match commit with | some c => [("commit", toJson c)] | none => []))
  "\n".intercalate ([summary.trimAscii.toString, ""] ++ body ++ ["", s!"<!-- {marker}: {record.compress} -->"])

/-- The records in a comment's markers. -/
def records (body : String) : List Json :=
  ((body.splitOn s!"<!-- {marker}: ").drop 1).filterMap fun rest =>
    (parse ((rest.splitOn " -->").headD "")).toOption

/-- Whether the reviewer already put this head to the human. -/
def escalatedAt (me sha : String) (comments : List Comment) : Bool :=
  comments.any fun c => c.author == me && (records c.body).any fun r =>
    (r.getObjVal? "escalated").toOption == some (toJson true) && (r.getObjVal? "commit").toOption == some (toJson sha)

def escalation (summary : String) (findings disputed : List Finding) (round rounds : Nat) (sha : String) : String :=
  let listed := "\n".intercalate (disputed.map fun f => s!"- **{f.rule}**: {f.finding.trimAscii}")
  s!"{noReply}\n\n" ++ render summary findings round rounds true (some sha) ++
  s!"\n\nAfter {rounds} rounds these findings are still open, so you decide them.\n\n" ++
  "## Question\n\nDo these findings stand? The author disputes each:\n\n" ++ listed ++
  "\n\n## Options\n\n- Uphold them: say which, and the author fixes them.\n" ++
  "- Overrule them: say so, and approve the pull request.\n" ++
  "\n## Recommendation\n\nUphold them: each names the rule it breaks. Read the author's replies " ++
  "on this pull request first.\n\n## If you say go ahead\n\nThe findings stand and the author " ++
  "fixes them; I review again once they have.\n\n## Blocked on this\n\nThis pull request's merge."

/-- The reviewer's review of a pull request's head, with its rules in code: approve only when CI
succeeded and no finding is open; past the rounds limit, hand the disputed findings to the human
instead of reviewing again. -/
def Cli.review (c : Cli) (repo : Repo) (n : Nat) (spec : String) : Out String := do
  unless c.reviewer == some c.forge.account do refuse "only the reviewer reviews with forge review"
  let (summary, findings) ← match findingsOf spec with
    | .ok r => pure r
    | .error m => refuse m
  let (sha, state) ← c.ci repo (some n)
  -- A repository without CI, such as the coordination one, has nothing to wait for.
  let hasCi := (← liftM' (c.forge.file repo ".forgejo/workflows/checks.yml" "main")).isSome
  if hasCi && state != .success then
    refuse s!"not reviewing {repo}#{n}: CI for {sha.take 12} is {state.name}; you'll be woken when it succeeds"
  let asked := ((← liftM' (c.forge.reviews repo n)).filter fun r =>
    r.author == c.forge.account && r.verdict == .requestChanges).length
  -- Past the rounds limit only a dispute goes to the human: a finding the author agreed with, or
  -- hasn't seen yet, is theirs to fix. And a dispute goes once per head.
  let disputed := findings.filter (·.status == .kept)
  if !disputed.isEmpty && asked ≥ c.reviewRounds then
    if escalatedAt c.forge.account sha (← liftM' (c.forge.comments repo n)) then
      return s!"Already put to the human at {sha.take 12}; nothing new to review until the head changes."
    let marked := findings.map fun f => if f.status == .kept then { f with status := .escalated } else f
    let disputed := disputed.map fun f => { f with status := .escalated }
    -- The decision first, then the label: the dispatcher takes needs-human off anything that
    -- doesn't state its decision.
    liftM' (c.forge.comment repo n (escalation summary marked disputed (asked + 1) c.reviewRounds sha))
    liftM' (c.forge.addLabel repo n "needs-human")
    return s!"After {c.reviewRounds} rounds, {repo}#{n} is labelled needs-human for the human to decide."
  let opened := findings.any (·.status.isOpen)
  liftM' (c.forge.review repo n (if opened then .requestChanges else .approve)
    (render summary findings (asked + 1) c.reviewRounds) sha)
  return s!"{if opened then "Requested changes on" else "Approved"} {repo}#{n} at {sha.take 12}."

def Cli.approve (c : Cli) (repo : Repo) (n : Nat) (message : String) : Out String := do
  unless c.coordinator == some c.forge.account do
    refuse "only the coordinator approves pull requests this way; the reviewer uses forge review"
  let (sha, state) ← c.ci repo (some n)
  if state != .success then refuse s!"not approving {repo}#{n}: CI for {sha.take 12} is {state.name}"
  liftM' (c.forge.review repo n .approve message sha)
  return s!"Approved {repo}#{n} at {sha.take 12}."

def verdictName : Verdict → String
  | .approve => "APPROVED" | .requestChanges => "REQUEST_CHANGES" | .comment => "COMMENT" | .other s => s

def Cli.reviews (c : Cli) (repo : Repo) (n : Nat) : Out String := do
  let rs ← liftM' (c.forge.reviews repo n)
  return "\n".intercalate (rs.map fun r =>
    s!"--- {r.author}: {verdictName r.verdict} at {r.commit.take 12}, {r.submittedAt}\n{r.body.trimAscii}\n")

/-! ## Versions -/

/-- The next release's version and why, from the tags, `API.lock` at the highest release tag, and
`API.lock` in the working tree: the gatekeeper's own rule. -/
def nextRelease (tagNames : List String) (lockAt : String → Option String) (working : String) :
    Version × String :=
  let prev := lastTag (tagNames.map fun t => ({ name := t, sha := "" } : Tag))
  let old := (prev.bind fun (t, _) => lockAt t.name).getD ""
  let pv := prev.map (·.2)
  (next pv old working, reason pv old working)

def versionLine (tagNames : List String) (lockAt : String → Option String) (working : String) : String :=
  let (v, why) := nextRelease tagNames lockAt working
  s!"{Gatekeeper.Version.tag v}: {why} (API.lock in your working tree)"

def number? (s : String) : Option Nat := if !s.isEmpty && s.all Char.isDigit then s.toNat? else none

def repoName? (s : String) : Option String :=
  let s := (s.splitOn "/").getLastD s
  if !s.isEmpty && s.all (fun c => c.isAlphanum || c == '-' || c == '_' || c == '.') then some s else none

end Guild.Agent
