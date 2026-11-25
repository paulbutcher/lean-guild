/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
module

public import SQLite.LowLevel
public import Std.Sync.Mutex

/-! SQLite as the ledger uses it: statements with positional parameters, rows read by column name,
and one connection shared by every thread, each statement under a lock. Values keep SQLite's own
types, since the ledger's file is shared with the reference's kit. -/

@[expose] public section

namespace Guild.Dispatcher

inductive Val where
  | null
  | int (i : Int)
  | real (f : Float)
  | text (s : String)
  deriving Inhabited, Repr, BEq

instance : Coe String Val := ⟨.text⟩
instance : Coe Float Val := ⟨.real⟩
instance : Coe Int Val := ⟨.int⟩
instance : Coe Nat Val := ⟨fun n => .int n⟩
instance : Coe Bool Val := ⟨fun b => .int (if b then 1 else 0)⟩

def Val.opt {α} [Coe α Val] : Option α → Val
  | some a => a
  | none => .null

def Val.isNull : Val → Bool
  | .null => true
  | _ => false

def Val.int? : Val → Option Int
  | .int i => some i
  | .real f => some f.toInt64.toInt
  | .text s => s.toInt?
  | .null => none

/-- A decimal number, as Python writes a float: digits, optionally a point and more digits. -/
def parseFloat? (s : String) : Option Float :=
  let (neg, body) := if s.startsWith "-" then (true, (s.drop 1).toString) else (false, s)
  let x : Option Float := match body.splitOn "." with
    | [i] => i.toNat?.map (·.toFloat)
    | [i, f] =>
      if (i.isEmpty && f.isEmpty) || !f.all Char.isDigit then none
      else do
        let w ← if i.isEmpty then some 0 else i.toNat?
        return w.toFloat + (f.toNat?.getD 0).toFloat / (10 ^ f.length).toFloat
    | _ => none
  x.map fun v => if neg then -v else v

def Val.real? : Val → Option Float
  | .int i => some (Float.ofInt i)
  | .real f => some f
  | .text s => parseFloat? s
  | .null => none

def Val.str? : Val → Option String
  | .text s => some s
  | .int i => some (toString i)
  | .real f => some (toString f)
  | .null => none

structure Row where
  cols : Array (String × Val)
  deriving Inhabited, Repr

namespace Row

def get (r : Row) (name : String) : Val :=
  ((r.cols.find? (·.1 == name)).map (·.2)).getD .null

def int? (r : Row) (name : String) : Option Int := (r.get name).int?
def nat? (r : Row) (name : String) : Option Nat := (r.int? name).map Int.toNat
def real? (r : Row) (name : String) : Option Float := (r.get name).real?
def str? (r : Row) (name : String) : Option String := (r.get name).str?

def int (r : Row) (name : String) : Int := (r.int? name).getD 0
def nat (r : Row) (name : String) : Nat := (r.nat? name).getD 0
def real (r : Row) (name : String) : Float := (r.real? name).getD 0
def str (r : Row) (name : String) : String := (r.str? name).getD ""

end Row

/-- Runs one statement on a connection with no lock held: for `Db.q` and `Db.atomically`. -/
def run (conn : SQLite) (sql : String) (args : List Val) : IO (Array Row) := do
  let stmt ← conn.prepare sql
  for (a, i) in args.zipIdx do
    let ix := (i + 1).toInt32
    match a with
    | .null => stmt.bindNull ix
    | .int n => stmt.bindInt64 ix n.toInt64
    | .real f => stmt.bindFloat ix f
    | .text s => stmt.bindText ix s
  let n := stmt.columnCount.toNat
  let names ← (List.range n).mapM fun c => stmt.columnName c.toInt32
  let mut rows := #[]
  while ← stmt.step do
    let mut cols := #[]
    for (name, c) in names.zipIdx do
      let ix := c.toInt32
      let v ← match ← stmt.columnType ix with
        | .integer => do pure (Val.int (← stmt.columnInt64 ix).toInt)
        | .float => do pure (Val.real (← stmt.columnDouble ix))
        | .text | .blob => do pure (Val.text (← stmt.columnText ix))
        | .null => pure Val.null
      cols := cols.push (name, v)
    rows := rows.push ⟨cols⟩
  return rows

/-- A statement runner, within `Db.atomically`. -/
abbrev Q := String → List Val → IO (Array Row)

structure Db where
  conn : SQLite
  lock : Std.Mutex Unit

namespace Db

def «open» (path : System.FilePath) : IO Db := do
  return { conn := ← SQLite.open path (busyTimeoutMs := 5000), lock := ← Std.Mutex.new () }

def q (db : Db) (sql : String) (args : List Val := []) : IO (Array Row) :=
  db.lock.atomically (run db.conn sql args)

def exec (db : Db) (sql : String) (args : List Val := []) : IO Unit := discard <| db.q sql args

/-- Several statements without parameters, as a schema is. -/
def script (db : Db) (sql : String) : IO Unit := db.lock.atomically (db.conn.exec sql)

/-- Statements that must not interleave with another thread's. -/
def atomically {α} (db : Db) (f : Q → IO α) : IO α :=
  db.lock.atomically (f (run db.conn))

/-- The first row's value of a column, if there is a row. -/
def one (db : Db) (sql : String) (args : List Val) (col : String) : IO Val := do
  return ((← db.q sql args)[0]?.map (·.get col)).getD .null

end Db

end Guild.Dispatcher
