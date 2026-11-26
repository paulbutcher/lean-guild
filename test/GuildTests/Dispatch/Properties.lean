/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Guild.Dispatcher.Text
import Guild.Dispatcher.Time
import GuildTests.Fuel

/-! What the dispatcher reads from text and times, as properties. The calendar arithmetic and the
parsers are total, but their divisions and character scans have too few lemmas for short proofs:
a time that read back wrong would wake an agent at the wrong time, and a line that didn't would
leave work unowed, so each is checked over many inputs. -/

namespace GuildTests.Dispatch.Properties

open Guild.Dispatcher Plausible

/-- A time to the second, as the ledger writes it and the forge reads it, reads back the same:
any second from 1970 to 2200. -/
def isoRoundTrip (n : Nat) : Bool :=
  let t := (n % 7258118400).toFloat
  Time.parse? (Time.iso t) == some t

/-- A release comment names its tag, however the sentence goes on. -/
def releasedTag (x y z : Nat) (rest : String) : Bool :=
  let rest := if rest.toList.head?.any Text.wordChar then " " ++ rest else rest
  Text.releasedIn s!"(no reply needed)\n\nReleased in v{x}.{y}.{z}{rest}" == some s!"v{x}.{y}.{z}"

/-- A Blocked-by: line anywhere in a comment names what it waits on. -/
def blockedByLine (k n : Nat) (before : String) : Bool :=
  let before := if before.toList.getLast?.any (· != '\n') then before ++ "\n" else before
  Text.blockedBy s!"{before}Blocked-by: org/repo-{k}#{n}\nThanks." |>.getLast? == some ("org", s!"repo-{k}", n)

/-- A Waiting-on: line names the agent, with or without an `@`. -/
def waitingOnLine (k : Nat) (at_ : Bool) : Bool :=
  Text.waitingOn s!"I need your frame.\n\n  Waiting-on: {if at_ then "@" else ""}agent-{k}" == [s!"agent-{k}"]

/-- A comment made only of lines the kit reads asks no one anything; one more line in words does. -/
def markersAskNothing (ms : List (Nat × Nat)) (words : Bool) : Bool :=
  let marker (m : Nat × Nat) : String := match m.1 % 4 with
    | 0 => s!"Blocked-by: org/repo-{m.2}#{m.2}"
    | 1 => s!"  Waiting-on: @agent-{m.2}"
    | 2 => s!"Released in v0.{m.2}.0"
    | _ => ""
  let text := "\n".intercalate (ms.map marker ++ (if words then ["Can you look at this?"] else []))
  Text.asks text == words

/-- `Blocked-by: none` is read as clearing, never as an item. -/
def noneClears (before : String) : Bool :=
  let text := s!"{before}\nBlocked-by: none\n"
  Text.blockedByNone text && Text.blockedBy text == Text.blockedBy before

def check : IO Bool := do
  let mut ok := true
  for (name, r) in [
      ("a ledger time reads back as the same second", toString (← Fuel.checkIO (∀ n, isoRoundTrip n = true) { numInst := 2000 })),
      ("a release comment names its tag", toString (← Fuel.checkIO (∀ x y z rest, releasedTag x y z rest = true) { numInst := 1000 })),
      ("a Blocked-by: line names what it waits on", toString (← Fuel.checkIO (∀ k n before, blockedByLine k n before = true) { numInst := 1000 })),
      ("a Waiting-on: line names the agent", toString (← Fuel.checkIO (∀ k b, waitingOnLine k b = true) { numInst := 500 })),
      ("a comment of markers only asks nothing", toString (← Fuel.checkIO (∀ ms w, markersAskNothing ms w = true) { numInst := 1000 })),
      ("Blocked-by: none clears, and names nothing", toString (← Fuel.checkIO (∀ b, noneClears b = true) { numInst := 1000 }))] do
    if r.startsWith "Success" || r.startsWith "success" then IO.println s!"PASS (dispatcher text): {name}"
    else
      IO.println s!"FAIL (dispatcher text): {name}: {r}"
      ok := false
  return ok

end GuildTests.Dispatch.Properties
