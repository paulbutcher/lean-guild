/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Guild.Agent.RunnerIO
import Guild.Gatekeeper.Service
import GuildTests.Contract

/-! The agent runner: how it renders and judges a run, then whole runs against a stub `claude` and a
fake dispatcher that records what it is told. -/

namespace GuildTests.Runner

open Guild.Agent.Runner GuildTests.Contract Json

def has (s part : String) : Bool := (s.splitOn part).length > 1

def ev (s : String) : Json := (parse s).toOption.getD .null

def pureCases : List (String × Bool) :=
  [("text and a Bash call render as Markdown",
     let (md, r) := render (ev "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\" Looking. \"},{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"command\":\"git status\"}}]}}")
     r.isNone && md.startsWith "Looking.\n\n**Bash**\n" && has md "git status"),
   ("a failed tool call is marked an error",
     has (render (ev "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"is_error\":true,\"content\":[{\"type\":\"text\",\"text\":\"no\"}]}]}}")).1 "<summary>Error</summary>"),
   ("the result event is kept", (render (ev "{\"type\":\"result\"}")).2.isSome),
   ("outcomes", [outcome 240 true false none 0 == "timed out after 240 minutes",
      outcome 240 false true none 0 == "interrupted",
      outcome 240 false false (ev "{\"is_error\":false}") 0 == "completed",
      outcome 240 false false (ev "{\"is_error\":true,\"subtype\":\"success\",\"result\":\"Usage  limit\\nreached\"}") 0 == "failed: Usage limit reached",
      outcome 240 false false (ev "{\"is_error\":true,\"subtype\":\"error_max_turns\"}") 0 == "failed: error_max_turns",
      outcome 240 false false none 3 == "exited (status 3) before finishing a reply"].all id),
   ("the transcript is marked as the editor's",
     rewriteEntrypoint "{\"entrypoint\":\"sdk-cli\"}\n{\"entrypoint\":\"sdk-cli\"}" ==
       ("{\"entrypoint\":\"claude-vscode\"}\n{\"entrypoint\":\"claude-vscode\"}", 2)),
   ("a claim names its run and triggers",
     claimOf (ev "{\"run\": 7, \"triggers\": [\"a\", \"b\"]}") == some (7, ["a", "b"]))]

/-! ## Whole runs -/

def port : UInt16 := 18732

open Std Std.Async Std.Http Routing in
/-- A dispatcher that answers every request with `{}` and records its path and body. -/
def fakeDispatcher (seen : IO.Ref (Array (String × String))) : StatelessHandler .std :=
  StatelessHandler.ofFn fun req => do
    let body := match ← ServerEngine.readBody (e := .std) req.body 1000000 with
      | .ok b => (String.fromUTF8? b).getD ""
      | .tooLarge => ""
    seen.modify (·.push (toString req.line.uri, body))
    Guild.Gatekeeper.reply .ok (Json.mkObj [])

def stub (dir : System.FilePath) (claudeDir : System.FilePath) (pause : Bool) : IO System.FilePath := do
  let path := dir / (if pause then "claude-slow" else "claude")
  IO.FS.writeFile path (String.intercalate "\n" [
    "#!/bin/sh",
    "session=\"\"",
    "while [ $# -gt 0 ]; do [ \"$1\" = --session-id ] && session=\"$2\"; shift; done",
    s!"mkdir -p '{claudeDir}/projects/p'",
    s!"printf '\{\"type\":\"x\",\"entrypoint\":\"sdk-cli\"}\\n' > '{claudeDir}/projects/p/'\"$session\".jsonl",
    "echo '{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"Looking.\"},{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"command\":\"git status\"}}]}}'",
    "echo '{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"content\":\"clean\"}]}}'",
    if pause then "exec sleep 60" else "",
    "echo '{\"type\":\"result\",\"is_error\":false,\"total_cost_usd\":0.12,\"num_turns\":3,\"permission_denials\":[{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"curl x\"}}]}'",
    ""])
  discard <| IO.Process.output { cmd := "chmod", args := #["+x", path.toString] }
  return path

def envAt (dir : System.FilePath) (claude : String) : IO Guild.Agent.Runner.Env := do
  IO.FS.writeFile (dir / "runner-key") "k\n"
  for d in ["workspace", "state", "archive", "claude-config"] do IO.FS.createDirAll (dir / d)
  return { agent := "lib-owner", claude, workspace := dir / "workspace", state := dir / "state",
           logs := dir / "workspace" / ".guild", archive := dir / "archive", claudeDir := dir / "claude-config",
           dispatcher := { url := s!"http://127.0.0.1:{port}", keyFile := dir / "runner-key" },
           maxMinutes := 5, tick := 1, control := dir / "control" }

def ended (seen : Array (String × String)) : Option Json :=
  (seen.toList.find? (·.1.endsWith "/end")).bind fun (_, b) => (parse b).toOption

def runCases (seen : IO.Ref (Array (String × String))) : List (String × T Unit) :=
  [("a run is started, logged, archived and reported", do
      let dir := (← IO.currentDir) / ".lake" / "runner-test" / toString (← IO.monoNanosNow)
      IO.FS.createDirAll dir
      let e ← envAt dir (← stub dir (dir / "claude-config") false).toString
      seen.set #[]
      run e 7 ["owe:lib:1:1 a review"]
      let s ← seen.get
      ensure ((s.toList.map (·.1)) == ["/runs/7/start", "/runs/7/end"]) s!"the dispatcher saw {s.toList.map (·.1)}"
      let some r := ended s | throw "no report"
      ensure ((r.getObjVal? "outcome").toOption == some (toJson "completed")) r.compress
      ensure ((r.getObjVal? "in_extension").toOption == some (toJson true)) "the transcript wasn't rewritten"
      ensure (match r.getObjVal? "denied" with | .ok (.arr xs) => xs.size == 1 | _ => false) "the denial wasn't reported"
      let logFile := ((r.getObjVal? "archived_log").toOption.bind (·.getStr?.toOption)).getD ""
      ensure (!logFile.isEmpty) "the log wasn't archived"
      let text ← IO.FS.readFile logFile
      ensure (has text "**Bash**" && has text "git status" && has text "Ended" && has text ": completed.") text
      ensure (has (← IO.FS.readFile (dir / "workspace" / ".guild" / "current.md")) "Looking.") "current.md doesn't follow the run"),
   ("guild-runner stop interrupts a run", do
      let dir := (← IO.currentDir) / ".lake" / "runner-test" / toString (← IO.monoNanosNow)
      IO.FS.createDirAll dir
      let e ← envAt dir (← stub dir (dir / "claude-config") true).toString
      seen.set #[]
      let stopper ← IO.asTask do IO.sleep 2000; IO.FS.writeFile (dir / "state" / "stop-run") ""
      run e 8 ["a long one"]
      discard <| IO.wait stopper
      let some r := ended (← seen.get) | throw "no report"
      ensure ((r.getObjVal? "outcome").toOption == some (toJson "interrupted")) r.compress),
   ("a run stops when the web UI asks, by its id", do
      let dir := (← IO.currentDir) / ".lake" / "runner-test" / toString (← IO.monoNanosNow)
      IO.FS.createDirAll (dir / "control")
      let e ← envAt dir (← stub dir (dir / "claude-config") true).toString
      seen.set #[]
      let stopper ← IO.asTask do IO.sleep 2000; IO.FS.writeFile (dir / "control" / "stop-run-9") ""
      run e 9 ["a long one"]
      discard <| IO.wait stopper
      let some r := ended (← seen.get) | throw "no report"
      ensure ((r.getObjVal? "outcome").toOption == some (toJson "interrupted")) r.compress),
   ("the human's sessions are reported once each", do
      let dir := (← IO.currentDir) / ".lake" / "runner-test" / toString (← IO.monoNanosNow)
      IO.FS.createDirAll dir
      let e ← envAt dir "claude"
      IO.FS.writeFile (dir / "state" / "sessions.jsonl")
        "{\"event\":\"start\",\"session\":\"s1\",\"transcript\":\"\",\"at\":1}\n{\"event\":\"end\",\"session\":\"s1\",\"transcript\":\"\",\"at\":2}\n"
      seen.set #[]
      syncSessions e
      syncSessions e
      let posted := (← seen.get).toList.filter (·.1 == "/sessions")
      ensure (posted.length == 2) s!"{posted.length} reports")]

def check : IO Bool := do
  let mut ok := true
  for (name, good) in pureCases do
    if good then IO.println s!"PASS (runner): {name}" else IO.println s!"FAIL (runner): {name}"; ok := ok && good
  let seen ← IO.mkRef #[]
  let addr : Std.Net.SocketAddress := .v4 { addr := Std.Net.IPv4Addr.ofParts 127 0 0 1, port }
  let server ← (Std.Http.Server.serve addr (fakeDispatcher seen)).block
  try
    for (name, t) in runCases seen do
      match ← t.run with
      | .ok () => IO.println s!"PASS (runner): {name}"
      | .error m => IO.println s!"FAIL (runner): {name}: {m}"; ok := false
  finally
    server.shutdownAndWait.block
  return ok

end GuildTests.Runner
