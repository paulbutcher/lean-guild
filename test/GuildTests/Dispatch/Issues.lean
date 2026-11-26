/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import GuildTests.Dispatch.Harness

/-! An issue's state, and who owes its next step: the reference's tests, ported. -/

namespace GuildTests.Dispatch.Issues

open Guild Guild.Forge Guild.Dispatcher GuildTests.Dispatch Json

def cases : List (String × (T → Check)) := [
  ("a job skipped for want of a runner leaves CI passed", fun t => do
    t.pull core 9 "core" (ci := .success)
    let time ← t.at 0
    t.repo core fun r => { r with statuses := (defaultSha,
      { context := "checks / macos (pull_request)", state := .other "skipped", updatedAt := time }) :: r.statuses }
    same (← t.io (ciState core defaultSha)) .success),
  ("the way back names the lines the reference would still read, where they still block", fun t => do
    t.issue scale 1 "core" ["request"]
    t.issue scale 2 "core" ["request"] (isOpen := false) (closed := some 100)
    t.issue core 3 "core" (events := [← t.comment "core" 3000 (line scale 1), ← t.comment "core" 2000 "Blocked-by: none"])
    t.issue core 4 "core" (events := [← t.comment "core" 3000 (line scale 1), ← t.comment "core" 2000 (line scale 2)])
    t.issue core 5 "core" (events := [← t.comment "core" 3000 (line scale 1)])
    let found ← t.io readDifferently
    same (found.map fun l => (l.splitOn " ").headD "") [s!"{core}#3", s!"{core}#4"]
    ensure (found.all fun l => has l s!"{scale}#1" && has l "issuecomment-") s!"names the line: {found}"),
  ("an untriaged request from someone else is its owner's", fun t => do
    t.issue core 1 "scale" ["request", "new"]
    t.issue core 2 "core" ["request", "new"]  -- its own: a task, filing it accepted it
    t.issue core 3 "stranger" ["request", "new"]  -- an outsider's, which no one else answers
    for n in [1, 2, 3] do t.evaluate core n
    same (← t.owing) [("core", "to do"), ("core", "untriaged"), ("core", "untriaged")]
    same ((← t.descriptions "core").head?)
      (some s!"issue {core}#1 (untriaged): accept it, counter-propose, or close it saying why")
    same (← t.state s!"{core}#2") (some ("to do", ["core"]))),
  ("a site owns its repository as a library does", fun t => do
    t.issue site 1 "core" ["request", "new"]
    t.evaluate site 1
    same (← t.queued "web") ["untriaged"]),
  ("an issue filed without labels is untriaged until its owner looks", fun t => do
    t.issue core 9 "scale"  -- its labels dropped, as the forge does for anyone without write access
    t.issue core 10 "scale" (events := [← t.comment "core" 100 "(no reply needed) On it."])
    for n in [9, 10] do t.evaluate core n
    same (← t.stateName s!"{core}#9") "untriaged"
    ensure (((← t.descriptions "core").head?.getD "") |> (has · "if it's a request, add `request` and `new`")) "the step"
    same (← t.stateName s!"{core}#10") "to do"
    let rows ← t.io (q "SELECT id, key FROM triggers WHERE run_id IS NULL")
    t.setLabels core 9 ["request", "accepted"]
    same (← t.io (noLongerOwed rows.toList)) [(rows[0]?.map (·.nat "id")).getD 0] "a claim drops it once triaged"
    same (← t.stateName s!"{core}#9") "to do"),
  ("counter-proposed", fun t => do
    t.issue core 1 "scale" ["request", "counter-proposal"] (events := [← t.label "counter-proposal" true 100])
    t.evaluate core 1
    same (← t.owing) [("scale", "counter-proposed")]),
  ("merged work still to finish", fun t => do
    t.issue core 5 "scale" ["request", "accepted"]
    t.pull core 7 "core" (body := "Refs org/t-core#5") (isOpen := false) (merged := some 100)
    t.evaluate core 5
    same (← t.descriptions "core") [s!"issue {core}#5 (merged): label it ready-for-release, with its CHANGELOG.md entry"]),
  ("an owner's own issue is finished as a request is", fun t => do
    t.issue core 5 "core"
    t.issue core 6 "core" ["ready-for-release"]
    t.issue core 8 "scale"  -- someone else's, untriaged
    t.pull core 7 "core" (body := "Refs #5\nRefs #6\nRefs #8") (isOpen := false) (merged := some 100)
    for n in [5, 6, 8] do t.evaluate core n
    same (← [5, 6, 8].mapM fun n => t.stateName s!"{core}#{n}") ["merged", "ready", "untriaged"]
    -- The coordinator's own issues are its decisions and records, never released.
    t.issue coord 3 "coordinator"
    t.pull coord 4 "coordinator" (body := "Refs #3") (isOpen := false) (merged := some 100)
    t.evaluate coord 3
    same (← t.stateName s!"{coord}#3") "to do"),
  ("part of, and Refs in a line, count", fun t => do
    t.issue core 2 "coordinator" ["request", "accepted"]
    t.pull core 28 "core" (title := "Tile build from real files (part of #2)") (isOpen := false) (merged := some 100)
    t.issue core 3 "coordinator" ["request", "accepted"]
    t.pull core 18 "core" (body := "Not done yet for #3: performance gates. Refs org/t-core#3.") (isOpen := false)
      (merged := some 100)
    t.evaluate core 2
    t.evaluate core 3
    same (← t.owing) [("core", "merged"), ("core", "merged")]
    same ((Text.prRefs "Done. Refs #2, #3 and org/x#4. Not #5; prefs #6").map (·.n)) [2, 3, 4]),
  ("labelled ready or released, it isn't the owner's", fun t => do
    t.issue core 5 "scale" ["request", "accepted", "ready-for-release"]
    t.issue core 6 "scale" ["request", "accepted"] (events := [← t.comment "gatekeeper" 50 (released "v0.2.0")])
    t.pull core 7 "core" (body := "Refs #5\nRefs #6") (isOpen := false) (merged := some 100)
    t.evaluate core 5
    t.evaluate core 6
    same (← t.state s!"{core}#5") (some ("ready", ["unit:release"]))
    same (← t.owing) [("scale", "released")]),
  ("released wakes the requester to verify", fun t => do
    t.issue core 9 "scale" ["request", "accepted"] (events := [← t.comment "gatekeeper" 100 (released "v1.2.3")])
    t.evaluate core 9
    same (← t.queued "scale") ["released"]
    ensure (has ((← t.descriptions "scale").headD "") "(released in v1.2.3)") "names the release"
    t.addLabel core 9 "verified"
    t.evaluate core 9
    same (← t.owing) [("scale", "verified")] "and then to close it"),
  ("not-verified sends it back to its owner", fun t => do
    t.issue core 6 "scale" ["request", "accepted", "not-verified"] (events :=
      [← t.comment "gatekeeper" 5000 (released "v0.2.0"), ← t.comment "scale" 4000 "The README names the wrong function.",
       ← t.label "not-verified" true 4000 "scale"])
    t.evaluate core 6
    same (← t.stateName s!"{core}#6") "to do"
    t.pull core 7 "core" (body := "Refs #6") (isOpen := false) (merged := some 6000)  -- the released work
    t.pull core 8 "core" (body := "Refs #6") (isOpen := false) (merged := some 100)
    t.clearCache
    t.evaluate core 6
    same (← t.stateName s!"{core}#6") "merged"
    -- Released again: the label is from before, so it is the requester's again.
    t.add core 6 (← t.comment "gatekeeper" 50 "(no reply needed)\n\nReleased in v0.2.1.")
    t.evaluate core 6
    same (← t.state s!"{core}#6") (some ("released", ["scale"]))),
  ("a fix merged after the release waits for not-verified", fun t => do
    t.issue core 6 "scale" ["request", "accepted"] (events :=
      [← t.comment "gatekeeper" 5000 (released "v0.2.0"),
       ← t.comment "scale" 300 s!"I'll switch once it's released.\n\n{line core 8}"])
    t.pull core 8 "core" (body := "Refs #6") (isOpen := false) (merged := some 100)
    t.close core 8 100
    t.evaluate core 6
    same (← t.state s!"{core}#6") (some ("released", ["scale"]))
    t.addLabel core 6 "not-verified"
    t.add core 6 (← t.label "not-verified" true 50 "scale")
    t.evaluate core 6
    same (← t.state s!"{core}#6") (some ("merged", ["core"]))),
  ("a released request labelled again waits for its release", fun t => do
    t.issue core 6 "scale" ["request", "accepted", "ready-for-release"] (events := [← t.comment "gatekeeper" 5000 (released "v0.2.0"), ← t.label "ready-for-release" true 1000])
    t.evaluate core 6
    same (← t.state s!"{core}#6") (some ("ready", ["unit:release"]))),
  ("work merged before it was unblocked isn't its work", fun t => do
    t.issue core 4 "coordinator" ["request"] (isOpen := false) (closed := some 1000)
    t.issue core 38 "coordinator" ["request", "accepted"] (body := line core 4)
    t.pull core 42 "core" (body := "Refs #38") (isOpen := false) (merged := some 2000)  -- the part it could do
    t.evaluate core 38
    same (← t.owing) [("core", "to do")]),
  ("an owner's own issue", fun t => do
    t.issue core 74 "core" (created := 600)
    t.issue core 75 "core" ["blocked"] (body := line scale 93)
    t.issue scale 93 "core" ["request", "new"]
    t.issue core 76 "core"
    t.pull core 77 "core" (body := "Refs #76") (ci := .success)  -- under way
    for n in [74, 75, 76] do t.evaluate core n
    same (← [74, 75, 76].mapM fun n => t.stateName s!"{core}#{n}") ["to do", "blocked", "in progress"]
    same (← t.descriptions "core")
      [s!"issue {core}#74 (to do): work on it: a pull request with a Refs line, or say what it waits for (a Blocked-by: line, Waiting-on:, or needs-human with a decision)"]),
  ("to do waits while its owner is busy", fun t => do
    t.issue core 5 "coordinator" ["request", "accepted"]
    let run ← t.running "core"
    t.evaluate core 5
    same (← t.owing) [("core", "to do")]
    same (← t.queued "core") [] "quiet: not while it runs"
    t.io (exec "UPDATE runs SET ended=? WHERE id=?" [← t.env.now, run])
    t.wakeDue
    same (← t.queued "core") ["to do"]),
  ("it waits for every blocker", fun t => do
    t.issue core 51 "coordinator" ["request"] (isOpen := false) (closed := some 3000)
    t.issue scale 38 "coordinator" ["request"]
    t.issue core 12 "coordinator" ["request", "accepted"] (events :=
      [← t.comment "core" 7000 s!"(no reply needed)\n{line core 51}\n{line scale 38}"])
    t.evaluate core 12
    same (← t.state s!"{core}#12") (some ("blocked", ["unit:blockers"]))
    ensure ((← t.labelsOf core 12).contains "blocked") "the dispatcher labels it blocked"
    -- scale#38's release unblocks it.
    t.add scale 38 (← t.comment "gatekeeper" 100 (released "v0.5.3"))
    t.evaluate core 12
    same (← t.stateName s!"{core}#12") "to do"),
  ("a line may name a pull request", fun t => do
    t.pull core 13 "core" (ci := .success)
    t.issue core 19 "scale" ["request", "accepted"] (events := [← t.comment "core" 7000 s!"(no reply needed)\n{line core 13}"])
    t.evaluate core 19
    same (← t.stateName s!"{core}#19") "blocked"
    t.close core 13 100
    t.item core 13 fun i => { i with pull := i.pull.map fun p => { p with merged := true, mergedAt := some i.updatedAt } }
    t.evaluate core 19
    same (← t.stateName s!"{core}#19") "to do"),
  ("closed but never released, it still blocks", fun t => do
    t.issue scale 62 "core" ["request", "accepted", "ready-for-release"] (isOpen := false) (closed := some 3000)
    t.issue core 57 "coordinator" ["request", "accepted", "blocked"] (events := [← t.comment "core" 7000 s!"(no reply needed)\n{line scale 62}"])
    t.evaluate core 57
    same (← t.stateName s!"{core}#57") "blocked"
    t.add scale 62 (← t.comment "gatekeeper" 100 (released "v0.22.0"))
    t.evaluate core 57
    same (← t.stateName s!"{core}#57") "to do"),
  ("a requester's own line on its released request", fun t => do
    t.pull scale 59 "scale" (isOpen := false) (merged := some 100)
    t.issue core 51 "scale" ["request", "accepted"] (events :=
      [← t.comment "gatekeeper" 5000 (released "v0.18.0"), ← t.comment "scale" 4000 s!"(no reply needed) Not yet.\n\n{line scale 59}"])
    t.evaluate core 51
    same (← t.owing) [("scale", "released")]),
  ("the dispatcher's label comes off with its last line", fun t => do
    t.issue core 74 "core" ["blocked"] (created := 600) (events := [← t.label "blocked" true 500 "dispatcher"])
    -- The human's own label, with no lines, stays, and asks for a line.
    t.issue core 75 "core" ["blocked"] (created := 600) (events := [← t.label "blocked" true 500 human])
    t.evaluate core 74
    t.evaluate core 75
    ensure (!(← t.labelsOf core 74).contains "blocked") "the dispatcher's label comes off"
    ensure ((← t.labelsOf core 75).contains "blocked") "the human's stays"
    same (← t.stateName s!"{core}#74") "to do"
    same (← t.state s!"{core}#75") (some ("blocked without a reason", ["core"]))),
  ("a loop of Blocked-by lines is its writer's", fun t => do
    t.issue core 1 "core" (events := [← t.comment "core" 600 s!"(no reply needed)\n{line core 2}"])
    t.issue core 2 "core" (events := [← t.comment "core" 500 s!"(no reply needed)\n{line core 1}"])
    for n in [1, 2, 1] do discard <| t.io (evaluateOne core n)
    same (← t.state s!"{core}#1") (some ("invalid", ["core"]))),
  ("a line naming the item itself is invalid while it is the newest", fun t => do
    t.issue core 4 "core"
    t.issue core 3 "scale" ["request", "accepted"] (events :=
      [← t.comment "gatekeeper" 900 "(no reply needed)\nReleased in v0.2.0.",
       ← t.comment "scale" 600 s!"(no reply needed)\nWaiting for the next release.\n\n{line core 3}"])
    t.evaluate core 3
    same (← t.state s!"{core}#3") (some ("invalid", ["scale"]))
    t.add core 3 (← t.comment "scale" 300 s!"(no reply needed)\n{line core 4}")
    t.evaluate core 3
    same (← t.stateName s!"{core}#3") "blocked"),
  ("with the human until they answer", fun t => do
    t.issue core 4 "core" ["needs-human"] (events := [← t.label "needs-human" true 500])
    t.evaluate core 4
    same (← t.state s!"{core}#4") (some ("with the human", ["human"]))
    t.add core 4 (← t.comment human 100 "Do the first.")
    t.evaluate core 4
    same (← t.owing) [("core", "reply"), ("core", "to do")]),
  ("closed while ready for release", fun t => do
    t.issue scale 62 "web" ["request", "accepted", "ready-for-release"] (isOpen := false) (closed := some 100)
      (events := [← t.event .closed "web" 100])
    t.issue scale 63 "web" ["request", "accepted", "ready-for-release"] (isOpen := false) (closed := some 100)
      (events := [← t.comment "gatekeeper" 200 (released "v0.22.0"), ← t.event .closed "web" 100])
    t.evaluate scale 62
    t.evaluate scale 63
    same (← t.owing) [("coordinator", "closed unreleased")]),
  ("a release overtakes its decision", fun t => do
    t.issue core 27 "coordinator" ["needs-human"] (title := s!"Release {core}") (created := 5000) (events :=
      [← t.label "needs-human" true 5000 "coordinator", ← t.comment human 100 "Go ahead"])
    t.release core "v0.6.0" 9000  -- before the decision
    t.evaluate core 27
    same (← t.stateName s!"{core}#27") "with the human"
    t.release core "v0.6.1" 3000
    t.release core "v0.6.2" 2000 (draft := true)
    t.clearCache
    t.evaluate core 27
    same (← t.state s!"{core}#27") (some ("overtaken", ["coordinator"]))
    -- Once it has acted since, the human holds it again.
    t.add core 27 (← t.comment "coordinator" 50 "(no reply needed)\nUpdated.")
    t.evaluate core 27
    same (← t.stateName s!"{core}#27") "with the human"),
  ("a release published evaluates the decision", fun t => do
    t.issue core 27 "coordinator" ["needs-human"] (title := s!"Release {core}") (created := 5000)
    t.release core "v0.6.1" 10
    t.handle "release" (Json.mkObj [("action", toJson "published"),
      ("repository", Json.mkObj [("name", toJson core), ("owner", Json.mkObj [("login", toJson "org")])]),
      ("sender", Json.mkObj [("login", toJson "gatekeeper")]), ("release", Json.mkObj [("tag_name", toJson "v0.6.1")])])
    same (← t.queued "coordinator") ["overtaken"]),
  ("the human's issues and recommendations are theirs", fun t => do
    t.issue coord 107 "engineer" ["needs-human", "recommendation", "review:engineer"] (events :=
      [← t.label "needs-human" true 100 "engineer", ← t.comment human 50 "Why?"])
    t.issue coord 108 "dispatcher" ["needs-human"] (title := "Stalled: x")
    t.evaluate coord 107
    t.evaluate coord 108
    same (← t.stateName s!"{coord}#107") "with the human"
    same (← t.stateName s!"{coord}#108") "with the human"
    same (← t.owing) [("coordinator", "reply")] "the coordinator answers the human's question")]

def check : IO Bool := runCases "dispatcher issues" cases

end GuildTests.Dispatch.Issues
