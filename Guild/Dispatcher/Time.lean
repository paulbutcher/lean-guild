/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
module

public import Std.Time.DateTime.Timestamp

/-! Times as the ledger keeps them, seconds since the epoch, and as the forge writes them, ISO 8601.
The ledger's are floats, as the reference's are, since both kits share it. -/

@[expose] public section

namespace Guild.Dispatcher.Time

/-- Days since 1970-01-01 of a civil date (Howard Hinnant's `days_from_civil`). -/
def daysFromCivil (y m d : Int) : Int :=
  let y := if m ≤ 2 then y - 1 else y
  let era := (if y ≥ 0 then y else y - 399) / 400
  let yoe := y - era * 400
  let mp := (m + 9) % 12
  let doy := (153 * mp + 2) / 5 + d - 1
  let doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
  era * 146097 + doe - 719468

/-- The civil date of a day since 1970-01-01. -/
def civilFromDays (z : Int) : Int × Int × Int :=
  let z := z + 719468
  let era := (if z ≥ 0 then z else z - 146096) / 146097
  let doe := z - era * 146097
  let yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
  let y := yoe + era * 400
  let doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
  let mp := (5 * doy + 2) / 153
  let d := doy - (153 * mp + 2) / 5 + 1
  let m := if mp < 10 then mp + 3 else mp - 9
  (if m ≤ 2 then y + 1 else y, m, d)

def digits (s : String) : Option Int :=
  if !s.isEmpty && s.all Char.isDigit then s.toNat?.map Int.ofNat else none

/-- An ISO 8601 time with a date, as the forge writes it: `2026-11-24T10:00:00Z`, with optional
fractional seconds and a `Z` or `±hh:mm` offset. -/
def parse? (s : String) : Option Float := do
  let cs := s.toList
  let part (i n : Nat) : Option Int := digits (String.ofList ((cs.drop i).take n))
  guard (cs.length ≥ 19 && cs[4]? == some '-' && cs[7]? == some '-' && cs[13]? == some ':' &&
    cs[16]? == some ':' && (cs[10]? == some 'T' || cs[10]? == some ' '))
  let y ← part 0 4
  let mo ← part 5 2
  let d ← part 8 2
  let h ← part 11 2
  let mi ← part 14 2
  let se ← part 17 2
  let rest := cs.drop 19
  let (ds, rest) :=
    if rest.head? == some '.' then ((rest.drop 1).takeWhile Char.isDigit, (rest.drop 1).dropWhile Char.isDigit)
    else ([], rest)
  let fracSecs := ((String.ofList ds).toNat?.getD 0).toFloat / (10 ^ ds.length).toFloat
  let offset ← match rest with
    | [] | ['Z'] | ['z'] => some (0 : Int)
    | [sign, a, b, ':', c, e] =>
      let hh ← digits (String.ofList [a, b])
      let mm ← digits (String.ofList [c, e])
      if sign == '+' then some ((hh * 60 + mm) * 60)
      else if sign == '-' then some (-(hh * 60 + mm) * 60)
      else none
    | _ => none
  let secs := daysFromCivil y mo d * 86400 + h * 3600 + mi * 60 + se - offset
  return Float.ofInt secs + fracSecs

def pad (n : Int) (w : Nat) : String :=
  let s := toString n.toNat
  String.ofList (List.replicate (w - s.length) '0') ++ s

/-- A time as `YYYY-MM-DDTHH:MM:SSZ`, to the second. -/
def iso (t : Float) : String :=
  let secs : Int := t.floor.toInt64.toInt
  let days := if secs ≥ 0 then secs / 86400 else (secs - 86399) / 86400
  let r := secs - days * 86400
  let (y, m, d) := civilFromDays days
  s!"{pad y 4}-{pad m 2}-{pad d 2}T{pad (r / 3600) 2}:{pad (r / 60 % 60) 2}:{pad (r % 60) 2}Z"

/-- A forge time in seconds, or 0 for none or one that can't be read, which sorts before any
other. -/
def when (s : String) : Float := (parse? s).getD 0

/-- The wall clock, in seconds since the epoch. -/
def unixNow : IO Float := do
  return (← Std.Time.Timestamp.now).toNanosecondsSinceUnixEpoch.val.toNat.toFloat / 1e9

end Guild.Dispatcher.Time
