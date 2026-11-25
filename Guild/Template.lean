/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

/-! Templates for the agents' instructions: `{{NAME}}` is a value, `{{#flag}}…{{/flag}}` is kept
only when the flag is on (`{{^flag}}` only when it is off), and `{{>name}}` is a block of text
supplied by a layer or the project, itself a template, and empty when nothing supplies it. A
section tag, or an insert that comes out empty, alone on its line takes the line with it. -/

namespace Guild.Template

inductive Tag
  | var (name : String)
  | insert (name : String)
  | section (flag : String) (inverted : Bool)
  | close (flag : String)
  deriving DecidableEq, Repr

inductive Piece
  | text (s : String)
  /-- A tag alone on its line. -/
  | tag (t : Tag) (alone : Bool)
  deriving DecidableEq, Repr

def Tag.parse (s : String) : Except String Tag :=
  let body := (s.drop 1).toString
  match s.front with
  | '>' => .ok (.insert body)
  | '#' => .ok (.section body false)
  | '^' => .ok (.section body true)
  | '/' => .ok (.close body)
  | _ =>
    if !s.isEmpty && s.all (fun c => c.isUpper || c == '_') then .ok (.var s)
    else .error s!"not a tag: \{\{{s}}}"

/-- The text before each tag and the tags, in order. -/
def tokens (src : String) : Except String (List Piece) := do
  match src.splitOn "{{" with
  | [] => return []
  | first :: rest =>
    let mut out := [Piece.text first]
    for part in rest do
      match part.splitOn "}}" with
      | t :: after@(_ :: _) =>
        out := .text ("}}".intercalate after) :: .tag (← Tag.parse t) false :: out
      | _ => throw s!"an unclosed tag: \{\{{(part.take 20).toString}"
    return out.reverse

/-- Marks the tags alone on their lines; such a section tag takes its line's newline with it. -/
def standalone : List Piece → List Piece
  | .text a :: .tag t _ :: .text b :: rest =>
    let before := a.isEmpty || a.endsWith "\n"
    let after := b.isEmpty || b.startsWith "\n"
    let isTag := match t with | .var _ => false | _ => true
    if before && after && isTag then
      let sectionTag := match t with | .section .. | .close _ => true | _ => false
      -- On the template's last line, the line to take is the one before it.
      let last := b.isEmpty && rest.isEmpty
      let a' := if sectionTag && last && a.endsWith "\n" then (a.dropEnd 1).toString else a
      let b' := if sectionTag && !last then (b.drop 1).toString else b
      .text a' :: .tag t true :: standalone (.text b' :: rest)
    else .text a :: .tag t false :: standalone (.text b :: rest)
  | p :: rest => p :: standalone rest
  | [] => []
termination_by ps => ps.length

inductive Node
  | text (s : String)
  | var (name : String)
  | insert (name : String) (alone : Bool)
  | section (flag : String) (inverted : Bool) (body : List Node)
  deriving Repr, Inhabited

/-- The pieces as a tree of sections. -/
def tree (ps : List Piece) : Except String (List Node) := do
  -- Each open section: its flag, whether inverted, and the nodes so far inside it.
  let mut stack : List (String × Bool × List Node) := []
  let mut top : List Node := []
  for p in ps do
    match p with
    | .text s => top := .text s :: top
    | .tag (.var n) _ => top := .var n :: top
    | .tag (.insert n) alone => top := .insert n alone :: top
    | .tag (.section f inv) _ =>
      stack := (f, inv, top) :: stack
      top := []
    | .tag (.close f) _ =>
      match stack with
      | (g, inv, outer) :: rest =>
        if f != g then throw s!"\{\{/{f}}} closes \{\{#{g}}}"
        top := .section g inv top.reverse :: outer
        stack := rest
      | [] => throw s!"\{\{/{f}}} closes nothing"
  if let (g, _, _) :: _ := stack then throw s!"\{\{#{g}}} is never closed"
  return top.reverse

def parse (src : String) : Except String (List Node) := do
  tree (standalone (← tokens src))

/-- What a template is rendered with. -/
structure Context where
  vars : List (String × String)
  flags : List (String × Bool)
  inserts : List (String × String)

/-- The rendered text, and the inserts it used. -/
abbrev Out := StateT (List String) (Except String)

mutual
/-- How deep inserts may nest: an insert that includes itself is an error, not a loop. -/
def renderNodes (ctx : Context) : (depth : Nat) → (nodes : List Node) → String → Out String
  | _, [], acc => pure acc
  | depth, n :: ns, acc => do
    let s ← renderNode ctx depth n
    let empty := match n with | .insert _ true => s.isEmpty | _ => false
    if empty then
      match ns with
      | .text t :: ns' =>
        -- An insert alone on its line that comes out empty takes its line, and one of the blank
        -- lines around it if there is one on each side.
        let t := if t.startsWith "\n" then (t.drop 1).toString else t
        let t := if acc.endsWith "\n\n" && t.startsWith "\n" then (t.drop 1).toString else t
        renderNodes ctx depth ns' (acc ++ t)
      | other => renderNodes ctx depth other acc
    else renderNodes ctx depth ns (acc ++ s)
termination_by depth nodes _ => (depth, sizeOf nodes)

def renderNode (ctx : Context) : (depth : Nat) → (node : Node) → Out String
  | _, .text s => pure s
  | _, .var n => match ctx.vars.lookup n with
    | some v => pure v
    | none => throw s!"no value for \{\{{n}}}"
  | 0, .insert n _ => throw s!"\{\{>{n}}} nests too deeply"
  | depth + 1, .insert n _ => do
    match ctx.inserts.lookup n with
    | none => pure ""
    | some src =>
      modify (n :: ·)
      renderNodes ctx depth (← (parse src : Except String _)) ""
  | depth, .section f inv body => do
    match ctx.flags.lookup f with
    | none => throw s!"no flag \{\{#{f}}}"
    | some on => if on != inv then renderNodes ctx depth body "" else pure ""
termination_by depth node => (depth, sizeOf node)
end

/-- The rendered template, and the names of the inserts it used. -/
def render (ctx : Context) (src : String) : Except String (String × List String) := do
  let nodes ← parse src
  (renderNodes ctx 16 nodes "").run []

/-- A file of blocks: the text before the first `@@ name` line, then each named block, up to
the next such line. Each loses its trailing newlines, so an insert can sit mid-line. -/
def blocks (src : String) : String × List (String × String) :=
  let lines := src.splitOn "\n"
  let trim (ls : List String) := ((("\n".intercalate ls).dropEndWhile (· == '\n')).toString)
  let rec go (name : Option String) (acc : List String) (main : String)
      (out : List (String × String)) : List String → String × List (String × String)
    | [] =>
      match name with
      | none => (trim acc.reverse, out.reverse)
      | some n => (main, ((n, trim acc.reverse) :: out).reverse)
    | l :: ls =>
      if l.startsWith "@@ " then
        let n := (l.drop 3).toString.trimAscii.toString
        match name with
        | none => go (some n) [] (trim acc.reverse) out ls
        | some m => go (some n) [] main ((m, trim acc.reverse) :: out) ls
      else go name (l :: acc) main out ls
  go none [] "" [] lines

end Guild.Template
