/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import GuildTests.Dispatch.Harness

/-! What is asked of an agent on an item, owed until it acts there, and notices, each something to
look at once: the reference's tests, ported. -/

namespace GuildTests.Dispatch.Asks

open Guild Guild.Forge Guild.Dispatcher GuildTests.Dispatch Json

def withSupervisor : Guild.Config :=
  { config with agents := config.agents ++ [{ name := "process", kind := .supervisor, filesOn := .all }] }

def asks : List (String × (T → Check)) := [
  ("2: a comment wanting a reply, newer than the owner's last action", fun t => do
    let held (evs : List Ev) : IO (List Ev) := do return (← t.label "needs-human" true 400) :: evs
    t.issue core 1 "core" ["needs-human"] (events := ← held [← t.comment "scale" 300 (id := some 1)])
    t.issue core 2 "core" ["needs-human"] (events := ← held [← t.comment "scale" 300, ← t.comment "core" 200 "Answered."])
    t.issue core 3 "core" ["needs-human"] (events := ← held [← t.comment "scale" 300 "(no reply needed)\n\nThanks."])
    t.issue core 4 "core" ["needs-human"] (events := ← held [← t.comment "stranger" 300])
    for n in [1, 2, 3, 4] do t.evaluate core n
    same (← t.descriptions "core") [s!"comment on issue {core}#1 from scale: http://forge/org/{core}/issues/1#issuecomment-1"]),
  ("2: in the same second, the timeline's order decides", fun t => do
    t.issue core 1 "core" ["needs-human"] (events := [← t.comment "core" 100 "Mine.", ← t.comment "scale" 100 (id := some 1)])
    t.issue core 2 "core" ["needs-human"] (events := [← t.comment "scale" 100, ← t.comment "core" 100 "Answered."])
    t.evaluate core 1
    t.evaluate core 2
    same (← t.owing) [("core", "reply")]
    same ((← t.io (q "SELECT unit FROM obligations")).toList.map (·.str "unit")) [s!"{core}#1"]),
  ("2: the newest ask is the one owed, so a burst is one", fun t => do
    t.issue core 1 "core" ["needs-human"] (events := [← t.comment "scale" 300, ← t.comment "scale" 200, ← t.comment "scale" 100])
    t.evaluate core 1
    same (← t.queued "core") ["reply"]
    t.handled
    t.add core 1 (← t.comment "scale" 10)
    t.evaluate core 1
    same (← t.queued "core") ["reply"] "the newer one replaces it"
    same (← t.io (q "SELECT 1 FROM obligations")).size 1),
  ("2: not answered by a run that started before it", fun t => do
    t.issue core 1 "core" ["needs-human"] (events :=
      [← t.comment human 300 "Follow the latest release.", ← t.comment "core" 200 "Shortened the bullets."])
    let now ← t.env.now
    let rows ← t.io (q "INSERT INTO runs (agent, triggers, claimed) VALUES ('core', '[]', ?) RETURNING id" [(now - 360 : Float)])
    let run : Nat := (rows[0]?.map (·.nat "id")).getD 0
    t.evaluate core 1
    same (← t.owing) [("core", "reply")]
    t.io (exec "UPDATE runs SET ended=? WHERE id=?" [(now - 150 : Float), run])
    t.io (exec "INSERT INTO runs (agent, triggers, claimed, ended) VALUES ('core', '[]', ?, ?)" [(now - 100 : Float), (now - 40 : Float)])
    t.add core 1 (← t.comment "core" 50 "Reworded to follow the latest release.")
    t.evaluate core 1
    same (← t.owing) []),
  ("2: reviews that ask, and one that doesn't", fun t => do
    t.pull core 7 "core" (reviews := [← t.review "conformance" .requestChanges 300 (body := "(no reply needed)")])
    t.pull core 8 "core" (reviews := [← t.review human .comment 300 (body := "Why?")])
    t.pull core 9 "core" (reviews := [← t.review "coordinator" .approve 300 (body := "Checked the scope.")])
    for n in [7, 8, 9] do t.evaluate core n
    let ds ← t.descriptions "core"
    ensure (ds.contains s!"changes requested on pull request {core}#7 by conformance (`forge reviews {core} 7`)") "the request for changes"
    ensure (ds.contains s!"review on pull request {core}#8 by human (`forge reviews {core} 8`)") "the human's question"
    ensure (!ds.any fun x => has x s!"{core}#9" && has x "review") "an approval asks nothing"),
  ("26: the human's mention wakes that agent", fun t => do
    let ask ← t.comment human 300 s!"@coordinator {core} is at level 3; decide. cc @scale @core @stranger (not mail@example.org)" (id := some 26)
    t.pull core 9 "core" (events := [ask, ← t.comment "scale" 200 "(no reply needed)\nSeen."])
    t.pull core 10 "core" (sha := "b") (events := [← t.comment "scale" 100 "@coordinator please look"])
    t.evaluate core 9
    t.evaluate core 10
    same ((← t.owing).filter (·.2 == "mention")) [("coordinator", "mention")]
      "scale has acted since; core is the owner, whom any comment reaches; an agent's mention reaches no one"
    ensure ((← t.descriptions "coordinator").contains
      s!"the human mentioned you on pull request {core}#9: http://forge/org/{core}/issues/9#issuecomment-26") "the description"
    let rows ← t.io (q "SELECT id, key FROM triggers WHERE agent='coordinator' AND key LIKE 'owe:%'")
    t.add core 9 (← t.comment "coordinator" 50 "(no reply needed)\nApproved.")
    same (← t.io (noLongerOwed rows.toList)) [(rows[0]?.map (·.nat "id")).getD 0] "a claim drops it once it has acted"),
  ("26: the owner's mention wakes its requester", fun t => do
    t.issue core 9 "scale" ["request", "accepted"] (events :=
      [← t.comment "core" 300 "I can't reproduce it. @scale, can you attach the frame? @gpu might know too." (id := some 59),
       ← t.comment "core" 250 "(no reply needed)\n\n@scale, merged."])
    t.issue core 10 "scale" (events := [← t.comment "core" 300 "@scale, what's this?"])
    t.issue core 11 "scale" ["request", "accepted"] (events := [← t.comment "core" 300 "@scale, the frame?", ← t.comment "scale" 200 "Attached."])
    for n in [9, 10, 11] do t.evaluate core n
    same ((← t.owing).filter (·.2 == "mention")) [("scale", "mention")]
    ensure ((← t.descriptions "scale").contains
      s!"core, its owner, mentioned you on issue {core}#9: http://forge/org/{core}/issues/9#issuecomment-59") "the description"),
  ("30: Waiting-on holds it for the agent it names", fun t => do
    let waits (n : Nat) (evs : List Ev) (author := "scale") : IO String := do
      t.issue core n author ["request", "accepted"] (events := evs)
      t.evaluate core n
      t.stateName s!"{core}#{n}"
    t.issue core 1 "scale" ["request", "accepted"] (events := [← t.comment "core" 300 "(no reply needed)\nI need your frame.\n\nWaiting-on: scale"])
    t.evaluate core 1
    same (← t.state s!"{core}#1") (some ("waiting", ["scale"]))
    ensure ((← t.descriptions "scale").contains s!"issue {core}#1 (waiting): answer, or do what it waits for") "the step"
    -- Answered: scale has acted since.
    same (← waits 2 [← t.comment "core" 300 "(no reply needed)\nWaiting-on: scale", ← t.comment "scale" 200 "(no reply needed)\n\nAttached."]) "to do"
    -- A later line decides: none, the human (needs-human reaches them), or the writer itself.
    same (← waits 3 [← t.comment "core" 300 "(no reply needed)\nWaiting-on: scale", ← t.comment "core" 200 "(no reply needed)\nWaiting-on: none"]) "to do"
    same (← waits 4 [← t.comment "core" 300 "(no reply needed)\nWaiting-on: human"]) "to do"
    same (← waits 5 [← t.comment "scale" 300 "(no reply needed)\n\nWaiting-on: scale"]) "to do"
    same (← waits 6 [← t.comment "stranger" 300 "Waiting-on: scale"]) "to do"
    -- On a closed request too, where the talk after its verification goes on: there, an ask.
    t.issue core 9 "scale" ["request", "verified"] (isOpen := false) (events :=
      [← t.comment "coordinator" 300 "Fix your changelog first.\n\nWaiting-on: scale"])
    t.evaluate core 9
    same (← t.owing (some s!"{core}#9")) [("scale", "waiting")]),
  ("26: the supervisor's mention reaches the owner, at most its nudges a day", fun _ => do
    let t ← T.new withSupervisor
    let nudges ← (List.range 4).mapM fun i => t.comment "process" (500 - 10 * i) s!"(no reply needed)\n\n@core Move this on ({i})."
    t.issue core 4 "core" ["needs-human"] (events := nudges)
    t.evaluate core 4
    let id := match nudges[2]?.map (·.entry.event) with | some (.comment i _) => i | _ => 0
    same ((← t.io (q "SELECT what FROM obligations WHERE agent='core'")).toList.map (·.str "what")) [s!"mention:{id}"]
      "one, for the newest of the three it may send that day; the fourth reaches no one"),
  ("answered by acting, not by time", fun t => do
    t.issue core 1 "core" ["needs-human"] (events := [← t.comment human 300 "Which?"])
    t.evaluate core 1
    t.add core 1 (← t.label "priority" true 100 "core")
    t.evaluate core 1
    same (← t.owing) [] "any action of the owner's there answers it")]

def notices : List (String × (T → Check)) := [
  ("12: a request filed", fun t => do
    t.issue core 1 "scale" ["request", "new"]
    t.issue core 2 "coordinator" ["request", "new"]
    t.evaluate core 1
    t.evaluate core 2
    same ((← t.descriptions "coordinator").filter (·.startsWith "request filed")) [s!"request filed: {core}#1"]),
  ("once per version", fun t => do
    t.issue core 1 "scale" ["request", "new"]
    t.evaluate core 1
    t.handled
    t.evaluate core 1
    same (← t.queued "coordinator") []),
  ("13: a pull request opened is held until CI finishes", fun t => do
    t.pull core 7 "core" (created := 60) (events := [← t.event .scheduleMerge "core" 50])
    t.evaluate core 7
    let held := ((← t.io (q "SELECT not_before FROM triggers WHERE key LIKE 'pr-opened:%'"))[0]?.bind (·.real? "not_before")).getD 0
    ensure (held > (← t.env.now) + 400) "held"
    t.status core defaultSha .success
    t.evaluate core 7
    ensure ((← t.io (q "SELECT not_before FROM triggers WHERE key LIKE 'pr-opened:%'"))[0]?.any (·.get "not_before" |>.isNull)) "released"),
  ("13: not for the human's, or a changelog-only, pull request", fun t => do
    t.pull core 7 human (title := "Set up for autonomy level 3") (files := [".forgejo/CODEOWNERS"]) (ci := .success)
    t.pull core 8 "core" (title := "Changelog for 0.3.0") (files := ["CHANGELOG.md"]) (sha := "b") (ci := .success)
    t.pull core 9 "core" (files := ["CHANGELOG.md", "Test/Core.lean"]) (sha := "c") (ci := .success)
    for n in [7, 8, 9] do t.evaluate core n
    same ((← t.descriptions "coordinator").filter (has · "opened")) [s!"pull request opened: {core}#9"]),
  ("13: a changelog-only pull request that grows", fun t => do
    t.pull core 8 "core" (files := ["CHANGELOG.md"]) (ci := .success)
    t.evaluate core 8
    ensure (!(← t.queued "coordinator").contains "pr-opened") "not yet"
    t.item core 8 fun i => { i with pull := i.pull.map fun p => { p with files := some ["CHANGELOG.md", "Test/Core.lean"] } }
    t.evaluate core 8
    ensure ((← t.queued "coordinator").contains "pr-opened") "once it grows"),
  ("11: rejected", fun t => do
    t.issue core 2 "scale" ["request"] (isOpen := false) (events := [← t.event .closed "core" 100])
    t.issue core 3 "scale" ["request"] (isOpen := false) (events := [← t.event .closed "scale" 100])
    t.issue core 4 "scale" ["request", "verified"] (isOpen := false) (events := [← t.event .closed "core" 100])
    for n in [2, 3, 4] do t.evaluate core n
    same (← t.descriptions "scale") [s!"your request {core}#2 was closed without being verified"]),
  ("16: needs-human added, but not once refused", fun t => do
    t.issue core 4 "core" ["needs-human"] (events := [← t.label "needs-human" true 100])
    t.issue core 5 "core" [] (events := [← t.label "needs-human" true 100, ← t.label "needs-human" false 90 "dispatcher"])
    t.evaluate core 4
    t.evaluate core 5
    same ((← t.descriptions "coordinator").filter (has · "needs-human")) [s!"needs-human added to issue {core}#4"]),
  ("16: not on a recommendation the human decides", fun t => do
    for (n, review) in [(107, "review:engineer"), (120, "review:architecture")] do
      t.issue coord n "engineer" ["needs-human", "recommendation", review] (events := [← t.label "needs-human" true 100 "engineer"])
      t.evaluate coord n
    same ((← t.descriptions "coordinator").filter (has · "needs-human")) [s!"needs-human added to issue {coord}#120"]),
  ("8: the human's comment on an upstream issue", fun t => do
    t.issue coord 9 "core" ["upstream"] (events := [← t.comment human 100 "Fixed in the next toolchain."])
    t.issue core 3 "core" ["blocked"] (created := 5000) (body := line coord 9)
    t.evaluate core 3
    same (← t.descriptions "core") [s!"human commented on upstream issue {coord}#9; {core}#3 is blocked on it"]),
  ("8: an upstream issue an agent waits on is blocking", fun t => do
    t.issue coord 116 "core" ["upstream", "upstream:engine"]
    t.issue core 2 "coordinator" ["request", "accepted"] (body := line coord 116)
    t.evaluate core 2
    ensure ((← t.labelsOf coord 116).contains "blocking") "labelled blocking"
    t.close core 2
    t.evaluate core 2
    ensure (!(← t.labelsOf coord 116).contains "blocking") "unlabelled once nothing waits on it"),
  ("8: blocking follows the lines, not who set it", fun t => do
    t.issue coord 9 "core" ["upstream", "blocking"]
    t.issue scale 4 "scale" ["request"]
    t.issue core 3 "core" ["request", "accepted"] (body := line scale 4)
    discard <| t.io (sweep)
    ensure (!(← t.labelsOf coord 9).contains "blocking") "nothing names it"),
  ("22: a blocking issue on an upstream project wakes its tracker", fun t => do
    t.issue coord 31 "core" ["upstream", "upstream:engine", "blocking"]
    t.evaluate coord 31
    same (← t.queued "engineer") ["upstream-blocking"]
    same (← t.state s!"{coord}#31") (some ("upstream", ["world"]))),
  ("28: the owner is told when someone else makes it a priority", fun t => do
    t.issue core 2 "scale" ["request", "accepted", "priority"] (events := [← t.label "priority" true 100 human])
    t.issue core 3 "scale" ["request", "accepted", "priority"] (events := [← t.label "priority" true 100 "core"])
    t.evaluate core 2
    t.evaluate core 3
    same ((← t.descriptions "core").filter (has · "priority")) [s!"{core}#2 is now a priority: it comes before anything new (Protocol: Priority)"]),
  ("18: a release the coordinator didn't ask for", fun t => do
    for by_ in ["gatekeeper", human] do
      t.handle "release" (Json.mkObj [("action", toJson "published"),
        ("repository", Json.mkObj [("name", toJson scale), ("owner", Json.mkObj [("login", toJson "org")])]),
        ("sender", Json.mkObj [("login", toJson by_)]), ("release", Json.mkObj [("tag_name", toJson s!"v1.0.{by_.length}")])])
    same (← t.descriptions "coordinator") [s!"{scale} released v1.0.5"])]

def check : IO Bool := do
  let a ← runCases "dispatcher asks" asks
  let n ← runCases "dispatcher notices" notices
  return a && n

end GuildTests.Dispatch.Asks
