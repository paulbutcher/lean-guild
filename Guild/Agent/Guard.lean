/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
module

/-! The guard on the human's sessions. Runs go on beside a session in the same checkouts, so a
session changes nothing there, and in the forge only files issues and comments. It catches the
usual ways a session would do otherwise; it is not a sandbox, and a determined command gets past
it. Each refusal says what to do instead. -/

@[expose] public section

namespace Guild.Agent

/-! ## Shell words

Bash commands split as a POSIX shell quotes them, with runs of `;&|()<>` as tokens of their own
and `#` starting a comment, as Python's `shlex` does with those settings. A newline outside quotes
separates commands, as it does in bash. -/

inductive Tok where
  | word (s : String)
  | punct (s : String)
  deriving Repr, BEq

def punctChars : List Char := [';', '&', '|', '(', ')', '<', '>']

inductive Lex where
  | space
  /-- In a word; `quoted` when part of it was quoted, so an empty `''` is still a word. -/
  | word (quoted : Bool)
  | punct
  | single
  | double
  /-- After a backslash, in the given state. -/
  | escape (inDouble : Bool)
  | comment

structure LexState where
  mode : Lex := .space
  cur : String := ""
  out : Array Tok := #[]

def LexState.emit (s : LexState) : LexState :=
  match s.mode with
  | .word quoted => if quoted || !s.cur.isEmpty then { s with out := s.out.push (.word s.cur), cur := "" } else s
  | .punct => { s with out := s.out.push (.punct s.cur), cur := "" }
  | _ => s

/-- One character more. -/
def LexState.step (s : LexState) (c : Char) : LexState :=
  let ws := c == ' ' || c == '\t' || c == '\r'
  let fresh (s : LexState) : LexState :=
    if c == '\n' then { s with mode := .space, out := s.out.push (.punct ";") }
    else if ws then { s with mode := .space }
    else if c == '#' then { s with mode := .comment }
    else if c == '\\' then { s with mode := .escape false, cur := "" }
    else if c == '\'' then { s with mode := .single, cur := "" }
    else if c == '"' then { s with mode := .double, cur := "" }
    else if punctChars.contains c then { s with mode := .punct, cur := String.singleton c }
    else { s with mode := .word false, cur := String.singleton c }
  match s.mode with
  | .space => fresh s
  | .comment => if c == '\n' then { s with mode := .space, out := s.out.push (.punct ";") } else s
  | .punct => if punctChars.contains c then { s with cur := s.cur.push c } else fresh s.emit
  | .word q =>
    if c == '\'' then { s with mode := .single }
    else if c == '"' then { s with mode := .double }
    else if c == '\\' then { s with mode := .escape false }
    else if ws || c == '\n' || c == '#' || punctChars.contains c then
      fresh { s.emit with mode := .space }
    else { s with cur := s.cur.push c, mode := .word q }
  | .single => if c == '\'' then { s with mode := .word true } else { s with cur := s.cur.push c }
  | .double =>
    if c == '"' then { s with mode := .word true }
    else if c == '\\' then { s with mode := .escape true }
    else { s with cur := s.cur.push c }
  | .escape inDouble =>
    if inDouble then
      { s with mode := .double, cur := if c == '"' || c == '\\' then s.cur.push c else (s.cur.push '\\').push c }
    -- A backslash before a newline joins the lines.
    else if c == '\n' then { s with mode := if s.cur.isEmpty then .space else .word true }
    else { s with mode := .word true, cur := s.cur.push c }

/-- The tokens, or `none` for an unclosed quote or a trailing backslash. -/
def tokens (command : String) : Option (List Tok) :=
  let s := command.toList.foldl LexState.step {}
  match s.mode with
  | .single | .double | .escape _ => none
  | _ => some s.emit.out.toList

/-- A heredoc's body is data, not commands: drop it. -/
def stripHeredocs (command : String) : String :=
  let delimiter (line : String) : Option String :=
    match line.splitOn "<<" with
    | _ :: rest :: _ =>
      let r := (if rest.startsWith "-" then (rest.drop 1).toString else rest).trimAsciiStart.toString
      let r := r.dropWhile (fun c => c == '\'' || c == '"') |>.toString
      let d := r.takeWhile (fun c => c.isAlphanum || c == '_') |>.toString
      if d.isEmpty || (d.front.isDigit) then none else some d
    | _ => none
  let (kept, _) := (command.splitOn "\n").foldl (fun (acc, endWord) line =>
    match endWord with
    | some e => (acc, if line.trimAscii.toString == e then none else some e)
    | none => (acc ++ [line], delimiter line)) (([] : List String), (none : Option String))
  "\n".intercalate kept

structure Simple where
  words : List String
  /-- Where its output is redirected. -/
  targets : List String
  deriving Repr, BEq

def redirects : List String := [">", ">>", ">|", "&>", "&>>"]

/-- A command's simple commands in order, or `none` if it doesn't parse. -/
def simpleCommands (command : String) : Option (List Simple) := do
  let toks ← tokens (stripHeredocs command)
  let close (acc : List Simple) (cur : Simple) : List Simple :=
    if cur.words.isEmpty && cur.targets.isEmpty then acc else acc ++ [cur]
  let (acc, cur, _) := toks.foldl (fun (acc, cur, redirect) t =>
    match t, redirect with
    | .word w, true => (acc, { cur with targets := cur.targets ++ [w] }, false)
    | .word w, false => (acc, { cur with words := cur.words ++ [w] }, false)
    | .punct p, _ =>
      if redirects.contains p then
        let ws := match cur.words.getLast? with
          | some w => if !w.isEmpty && w.all Char.isDigit then cur.words.dropLast else cur.words
          | none => cur.words
        (acc, { cur with words := ws }, true)
      else (close acc cur, { words := [], targets := [] }, false))
    (([] : List Simple), ({ words := [], targets := [] } : Simple), false)
  return close acc cur

/-! ## Paths -/

/-- `.` and `..` resolved, and repeated slashes collapsed, as `os.path.normpath` does for an
absolute path. -/
def normalize (path : String) : String :=
  let parts := (path.splitOn "/").filter (fun p => !p.isEmpty && p != ".")
  let kept := parts.foldl (fun acc p => if p == ".." then acc.dropLast else acc ++ [p]) []
  "/" ++ "/".intercalate kept

/-- A path as a command in `cwd` names it, with `~` as `home`. -/
def resolve (home cwd path : String) : String :=
  let path := if path == "~" then home else if path.startsWith "~/" then home ++ (path.drop 1).toString else path
  normalize (if path.startsWith "/" then path else cwd ++ "/" ++ path)

/-! ## The guard -/

structure Guard where
  /-- Where every checkout runs use is. -/
  shared : String := "/workspace"
  home : String := "/home/agent"

def Guard.isShared (g : Guard) (path : String) : Bool :=
  let p := normalize path
  p == g.shared || p.startsWith (g.shared ++ "/")

def scratch : String :=
  "Make your own clone outside /workspace and work there: " ++
  "`git clone --shared /workspace/<repo> /tmp/<name>`, then `cd` into it."

def notHere : String :=
  "This is a session with the human, and your runs use the checkouts under /workspace while it lasts. "

def gitWrites : List String :=
  ["add", "am", "apply", "bisect", "checkout", "cherry-pick", "clean", "commit", "filter-branch", "gc",
   "merge", "mv", "notes", "prune", "pull", "rebase", "replace", "reset", "restore", "revert", "rm",
   "sparse-checkout", "stash", "submodule", "switch", "update-index", "update-ref", "worktree"]

def lakeWrites : List String :=
  ["build", "update", "upgrade", "exe", "test", "lint", "clean", "run", "script", "pack", "unpack",
   "cache", "new", "init"]

def npmWrites : List String :=
  ["install", "i", "ci", "run", "run-script", "test", "t", "exec", "x", "rebuild", "update", "up",
   "uninstall", "rm", "link", "prune", "dedupe"]

def fileWriters : List String :=
  ["rm", "rmdir", "mv", "touch", "mkdir", "ln", "chmod", "chown", "truncate", "tee", "install", "unlink"]

def wrappers : List String := ["env", "time", "nohup", "nice", "timeout", "command", "exec", "xargs"]

def teaIssues : List String := ["issue", "issues", "i"]
def teaComment : List String := ["comment", "comments", "c"]
def teaReads : List String := ["ls", "list", "search"]
def teaHarmless : List String := ["whoami", "open", "o", "help", "h", "--help", "-h", "--version", "-v"]

/-- `tea`'s flags that take a value, so the value isn't taken for a subcommand. -/
def teaValueFlags : List String :=
  ["--repo", "-r", "--remote", "-R", "--login", "-l", "--output", "-o", "--limit", "--lm", "--page", "-p",
   "--state", "--labels", "-L", "--title", "-t", "--description", "-d", "--body", "--assignees", "-a",
   "--milestone", "-m", "--fields", "-f", "--kind", "-K", "--keyword", "-k", "--author", "-A",
   "--mentions", "-M", "--base", "-b", "--head", "--owner", "-O", "--deadline", "-D",
   "--referenced-version"]

def forgeReads : List String := ["reviews", "ledger", "version"]

def checkTea (args : List String) : Option String := Id.run do
  let mut words : List String := []
  let mut skip := false
  for a in args do
    if skip then skip := false
    else if a.startsWith "-" then
      skip := teaValueFlags.contains a
      if teaHarmless.contains a && words.isEmpty then return none
    else words := words ++ [a]
  match words with
  | [] => return none
  | first :: rest =>
    if teaHarmless.contains first || teaComment.contains first then return none
    match rest with
    | [] => return none
    | second :: _ =>
      if second.all Char.isDigit || teaReads.contains second then return none
      if teaIssues.contains first && (second == "create" || second == "c") then return none
      return some (s!"In a session with the human you may file issues and comment, nothing else in the forge " ++
        s!"(`tea {first} {second}` refused). Your own comments wake no one: draft what the human should " ++
        "post, or file an issue for your runs to act on.")

def checkForge (args : List String) : Option String :=
  match args.filter (!·.startsWith "-") with
  | [] => none
  | w :: _ =>
    if forgeReads.contains w || (w == "ci" && !args.contains "--rerun") then none
    else some (s!"In a session with the human, `forge {w}` is refused: only `forge ci` (without `--rerun`), " ++
      "`forge reviews`, `forge ledger` and `forge version`, which read. File an issue for your runs instead.")

def assignment (w : String) : Bool :=
  match w.splitOn "=" with
  | name :: _ :: _ =>
    !name.isEmpty && !name.front.isDigit && name.all (fun c => c.isAlphanum || c == '_')
  | _ => false

/-- A wrapper's own options: flags, and durations such as `timeout`'s. -/
def wrapperOption (w : String) : Bool :=
  w.startsWith "-" ||
    (let body := if w.endsWith "s" || w.endsWith "m" || w.endsWith "h" || w.endsWith "d" then w.dropEnd 1 else w.toSlice
     let body := body.toString
     !body.isEmpty && (body.splitOn ".").length ≤ 2 && (body.splitOn ".").all (fun p => !p.isEmpty && p.all Char.isDigit))

def baseName (p : String) : String := (p.splitOn "/").getLastD p

def branchWrites : List String :=
  ["-d", "-D", "--delete", "-m", "-M", "--move", "-c", "-C", "--copy", "-f", "--force", "-u",
   "--set-upstream-to", "--unset-upstream"]

def branchLists : List String :=
  ["-l", "--list", "-a", "--all", "-r", "--remotes", "--contains", "--no-contains", "--merged",
   "--no-merged", "--points-at", "--show-current", "-v", "-vv"]

/-- `git`'s refusal, if any, in `cwd`. -/
def Guard.checkGit (g : Guard) (args : List String) (cwd : String) : Option String := Id.run do
  let mut whereAt := cwd
  let mut rest := args
  repeat
    match rest with
    | flag :: more =>
      if !flag.startsWith "-" then break
      if flag == "-C" then
        match more with
        | d :: more' => whereAt := resolve g.home whereAt d; rest := more'
        | [] => rest := more
      else if (flag == "-c" || flag == "--git-dir" || flag == "--work-tree") then
        rest := more.drop 1
      else rest := more
    | [] => break
  let sub := rest.headD ""
  if sub == "push" then
    return some "In a session with the human nothing is pushed: what should change goes to your runs as an issue."
  if !g.isShared whereAt then return none
  let after := rest.drop 1
  let second := (after.find? (!·.startsWith "-")).getD ""
  if ["stash", "worktree", "submodule", "notes", "bisect"].contains sub &&
      ["list", "show", "status", "log"].contains second then return none
  let writes :=
    gitWrites.contains sub ||
    (sub == "branch" && (after.any branchWrites.contains ||
      (!second.isEmpty && !after.any branchLists.contains))) ||
    (sub == "tag" && after.any (!·.startsWith "-") && !(after.contains "-l" || after.contains "--list"))
  if writes then return some (notHere ++ s!"`git {sub}` there would change their checkout. " ++ scratch)
  return none

def inplace (name : String) (args : List String) : Bool :=
  (name == "sed" && args.any (fun a => a.startsWith "-i" || a == "--in-place")) ||
  (name == "perl" && args.any (fun a => a.startsWith "-" && !a.startsWith "--" && ((a.drop 1).toString.takeWhile Char.isAlpha).toString.contains 'i'))

mutual

/-- One simple command's refusal, if any, and the directory it leaves the shell in. -/
def Guard.checkSimple (g : Guard) (fuel : Nat) (c : Simple) (cwd : String) : Option String × String :=
  match c.targets.find? (fun t => !t.startsWith "/dev/" && !t.startsWith "&" && g.isShared (resolve g.home cwd t)) with
  | some t => (some (notHere ++ s!"Don't write to `{t}` there. " ++ scratch), cwd)
  | none =>
  let rec unwrap (ws : List String) (wrapped : Bool) : List String :=
    match ws with
    | w :: rest =>
      if assignment w || wrappers.contains w || (wrapped && wrapperOption w) then unwrap rest (wrapped || wrappers.contains w)
      else ws
    | [] => []
  match unwrap c.words false with
  | [] => (none, cwd)
  | w :: args =>
  let name := baseName w
  if name == "cd" || name == "pushd" then
    (none, resolve g.home cwd ((args.find? (!·.startsWith "-")).getD g.home))
  else if (name == "bash" || name == "sh") then
    match args.dropWhile (· != "-c") with
    | _ :: script :: _ => (g.checkCommand fuel script cwd, cwd)
    | _ =>
      match args.dropWhile (·.startsWith "-") with
      | script :: rest => (g.checkProgram (baseName script) rest cwd, cwd)
      | [] => (none, cwd)
  else (g.checkProgram name args cwd, cwd)

/-- A program's refusal, if any. -/
def Guard.checkProgram (g : Guard) (name : String) (args : List String) (cwd : String) : Option String :=
  if name == "tea" then checkTea args
  else if name == "forge" then checkForge args
  else if name == "git" then g.checkGit args cwd
  else
    let builds :=
      (name == "lake" && (args.take 1).any lakeWrites.contains) ||
      (["npm", "pnpm", "yarn"].contains name && (args.take 1).any npmWrites.contains) ||
      name == "npx" || name == "make" || name.endsWith "build-site.sh"
    if builds && g.isShared cwd then some (notHere ++ "A build there writes its shared build output. " ++ scratch)
    else if inplace name args && (g.isShared cwd || args.any (·.startsWith (g.shared ++ "/"))) then
      some (notHere ++ "Don't edit files there. " ++ scratch)
    else
      let paths := args.filter (!·.startsWith "-")
      let paths := if name == "cp" || name == "rsync" then paths.getLast?.toList else paths
      if (fileWriters.contains name || name == "cp" || name == "rsync") &&
          paths.any (fun p => g.isShared (resolve g.home cwd p)) then
        some (notHere ++ s!"`{name}` there would change their files. " ++ scratch)
      else none

/-- A Bash command's refusal, if any. `fuel` bounds `bash -c` within `bash -c`. One that doesn't
parse goes through, rather than be guessed at. -/
def Guard.checkCommand (g : Guard) (fuel : Nat) (command : String) (cwd : String) : Option String :=
  match fuel with
  | 0 => none
  | fuel + 1 =>
    match simpleCommands command with
    | none => none
    | some cmds =>
      (cmds.foldl (fun (r, cwd) c => match r with
        | some _ => (r, cwd)
        | none => g.checkSimple fuel c cwd) (none, cwd)).1

end

def nestingLimit : Nat := 8

/-- Why the human's session may not make a tool call, or `none`. -/
def Guard.check (g : Guard) (tool : String) (input : String → Option String) (cwd : String) : Option String :=
  if ["Edit", "Write", "MultiEdit", "NotebookEdit"].contains tool then
    let path := ((input "file_path").orElse fun _ => input "notebook_path").getD ""
    if !path.isEmpty && g.isShared (resolve g.home cwd path) then some (notHere ++ "Don't edit files there. " ++ scratch)
    else none
  else if tool == "mcp__lean-lsp__lean_build" then some (notHere ++ "A build there writes its shared build output. " ++ scratch)
  else if tool == "Bash" then g.checkCommand nestingLimit ((input "command").getD "") cwd
  else none

end Guild.Agent
