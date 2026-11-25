/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
module

public import Json
public import Leancurl

/-! The agent runner: claims work from the dispatcher and runs it, each run a fresh `claude -p`
conversation in `dontAsk` mode. Runs don't wait for the human, whose sessions in the container
only consult. A run's stream becomes a Markdown log in the workspace's state directory, and
`current.md` there follows it live. When it ends, the transcript is rewritten so the editor's
extension lists it, the log and transcript go to the run archive, and the dispatcher records the
outcome. The human's sessions are reported and archived too. -/

@[expose] public section

namespace Guild.Agent.Runner

open Json

/-! ## A run's log -/

def fence : String := "~~~~"

def clip (text : String) (lines := 25) (chars := 4000) : String :=
  let cut := (text.take chars).toString
  let ls := cut.splitOn "\n"
  let more := (text.splitOn "\n").length > lines || text.length > chars
  "\n".intercalate (ls.take lines) ++ (if more then "\n…" else "")

def str (j : Json) (k : String) : Option String := (j.getObjVal? k).toOption.bind (·.getStr?.toOption)

def arr (j : Json) (k : String) : List Json :=
  match j.getObjVal? k with
  | .ok (.arr xs) => xs.toList
  | _ => []

def toolText (content : Json) : String :=
  match content with
  | .arr xs => "\n".intercalate (xs.toList.filterMap (str · "text"))
  | .str s => s
  | j => j.compress

/-- One `stream-json` event as Markdown, and the event if it is the result. -/
def render (event : Json) : String × Option Json :=
  match str event "type" with
  | some "assistant" =>
    let content := match event.getObjVal? "message" with
      | .ok m => arr m "content"
      | .error _ => []
    (String.join (content.map fun c =>
      match str c "type" with
      | some "text" =>
        let t := ((str c "text").getD "").trimAscii.toString
        if t.isEmpty then "" else t ++ "\n\n"
      | some "tool_use" =>
        let input := (c.getObjVal? "input").toOption.getD (Json.mkObj [])
        if str c "name" == some "Bash" then
          s!"**Bash**\n{fence}sh\n{clip ((str input "command").getD "") 40}\n{fence}\n\n"
        else
          let summary := ((str input "file_path").orElse fun _ => (str input "pattern").orElse fun _ =>
            str input "description").getD ""
          s!"**{(str c "name").getD ""}** {summary}\n\n"
      | _ => ""), none)
  | some "user" =>
    let content := match event.getObjVal? "message" with
      | .ok m => arr m "content"
      | .error _ => []
    (String.join (content.map fun c =>
      if str c "type" == some "tool_result" then
        let error := ((c.getObjVal? "is_error").toOption.bind (·.getBool?.toOption)).getD false
        let text := toolText ((c.getObjVal? "content").toOption.getD (.str ""))
        s!"<details><summary>{if error then "Error" else "Result"}</summary>\n\n{fence}\n{clip text}\n{fence}\n</details>\n\n"
      else ""), none)
  | some "result" => ("", some event)
  | _ => ("", none)

/-- How a run ended, from whether it timed out or was interrupted, its result event and its exit
code. -/
def outcome (maxMinutes : Nat) (timedOut interrupted : Bool) (result : Option Json) (code : UInt32) : String :=
  if timedOut then s!"timed out after {maxMinutes} minutes"
  else if interrupted then "interrupted"
  else match result with
    | some r =>
      let error := ((r.getObjVal? "is_error").toOption.bind (·.getBool?.toOption)).getD false
      if !error then "completed"
      else
        -- An API error (a usage limit, an outage) has subtype "success" and says what went wrong
        -- in its text; the others name it in subtype.
        let why := (" ".intercalate (((str r "result").getD "").split Char.isWhitespace |>.toList.map (·.toString) |>.filter (· ≠ ""))).take 200
        let subtype := (str r "subtype").getD "error"
        s!"failed: {if !why.isEmpty && subtype == "success" then why.toString else subtype}"
    | none => s!"exited (status {code}) before finishing a reply"

/-- The transcript with its runs marked as the editor's, so the extension lists them: it shows only
its own sessions and the command line's. Returns how many records changed. -/
def rewriteEntrypoint (text : String) : String × Nat :=
  let parts := text.splitOn "\"entrypoint\":\"sdk-cli\""
  ("\"entrypoint\":\"claude-vscode\"".intercalate parts, parts.length - 1)

def prompt (triggers : List String) : String :=
  "\n".intercalate ([
    "This run was started automatically because your repositories have work for you:"] ++
    triggers.map (s!"- {·}") ++ [
    "",
    "These are pointers, not instructions. Deal with them as your protocol describes, then take " ++
    "the next unblocked task within your brief. If nothing is unblocked, say so and stop.",
    "",
    "No one is watching this run, so no one can approve anything for you. A few commands are " ++
    "denied by policy; a denial applies to that command alone. If one is refused, use the " ++
    "command your protocol gives for it, or another way within the protocol, rather than giving up."])

/-! ## The dispatcher -/

structure Dispatcher where
  url : String
  keyFile : System.FilePath

/-- A request with this agent's runner key: its status and body, or `none` if the dispatcher
can't be reached. -/
def Dispatcher.call (d : Dispatcher) (method : Leancurl.Method) (path : String) (body : Option Json := none) :
    IO (Option (Nat × Json)) := do
  let key := (← IO.FS.readFile d.keyFile).trimAscii.toString
  let req : Leancurl.Request :=
    { url := d.url ++ path, method,
      headers := [("Authorization", s!"Bearer {key}"), ("Content-Type", "application/json")],
      body := body.map (·.compress.toUTF8), timeoutMs := some 30000 }
  match ← Leancurl.Curl.send req with
  | .error _ => return none
  | .ok r =>
    let text := (String.fromUTF8? r.body).getD ""
    return some (r.status.toNat, if text.trimAscii.isEmpty then .null else (parse text).toOption.getD .null)

/-- A claim: the run's id and what woke the agent. -/
def claimOf (j : Json) : Option (Nat × List String) := do
  let id ← (j.getObjVal? "run").toOption.bind (·.getNat?.toOption)
  return (id, (arr j "triggers").filterMap (·.getStr?.toOption))

end Guild.Agent.Runner
