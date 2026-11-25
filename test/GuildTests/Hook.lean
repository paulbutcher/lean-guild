/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Guild.Agent.Guard

/-! The guard on the human's sessions: the reference's `test_inkproof_hook.py`, case for case. -/

namespace GuildTests.Hook

open Guild.Agent

def repo := "/workspace/lib-demos"
def scratchDir := "/tmp/demos-95"

def g : Guard := {}

def bash (c : String) (cwd := repo) : Option String :=
  g.check "Bash" (fun k => if k == "command" then some c else none) cwd

def tool (name path cwd : String) : Option String :=
  g.check name (fun k => if k == "file_path" then some path else none) cwd

/-- Each case: a description, the commands, where they run, and whether they are refused. -/
def cases : List (String × List String × String × Bool) :=
  [("reading the checkout is allowed",
     ["git status", "git log --oneline -5", "git diff origin/main -- app", "git fetch origin",
      "git branch", "git branch --list 'agent/*'", "git stash list", "git worktree list",
      "git tag -l", "cat Lib/Demos/Frame.lean", "grep -rn scissor app | head",
      "lake env printenv LEAN_PATH", "ls -la .lake > /tmp/out.txt 2>&1",
      "git clone --shared /workspace/lib-demos /tmp/demos-95",
      "cp app/browser.test.mjs /tmp/x.mjs", "timeout 300 git log", "echo hi >/dev/null"], repo, false),
   ("anything in a scratch clone is allowed",
     ["git checkout -b try", "git commit -am wip", "lake build", "npm ci", "scripts/build-site.sh",
      "sed -i s/a/b/ x.lean", "echo x > notes.txt", "rm -rf _site"], scratchDir, false),
   ("cd into a scratch clone first", ["cd /tmp/demos-95 && lake build && git stash"], repo, false),
   ("git writes in the checkout are refused",
     ["git checkout -b agent/demos/x origin/main", "git switch main", "git stash", "git commit -m x",
      "git pull", "git reset --hard", "git add .", "git branch new", "git branch -D old",
      "git worktree add ../x", "git tag v1", "git -C /workspace/lib-demos checkout main"], repo, true),
   ("git writes named from elsewhere are refused",
     ["git -C /workspace/lib-web restore x", "cd /workspace/lib-demos && git checkout main"], scratchDir, true),
   ("push is refused anywhere", ["git push -u origin try"], scratchDir, true),
   ("builds in the checkout are refused",
     ["lake build", "lake update", "npm ci", "npm run build", "npx vite build", "scripts/build-site.sh",
      "bash scripts/build-site.sh", "env CI=1 lake build", "timeout 600 lake build Lib.Demos"], repo, true),
   ("file writes in the checkout are refused",
     ["echo x > notes.txt", "cat a >> app/web/index.html", "rm -rf _site", "touch x",
      "sed -i s/a/b/ Lib/Demos/Frame.lean", "perl -pi -e s/a/b/ x", "mv a b",
      "cp /tmp/x.lean Lib/Demos/x.lean", "printf x | tee app/x.txt", "bash -c 'git checkout main'",
      "echo $(git stash)"], repo, true),
   ("file writes into the checkout from elsewhere are refused",
     ["cp /tmp/a /workspace/lib-demos/a", "echo x > /workspace/lib-demos/a"], scratchDir, true),
   ("a heredoc's body is data", ["cat > /tmp/body.md <<'EOF'\ngit checkout main > x\nEOF\n"], repo, false),
   ("a newline separates commands, as in bash", ["cd /tmp/demos-95\ncd /workspace/lib-demos\nlake build"], repo, true),
   ("issues and comments are allowed",
     ["tea issues create --repo org/lib-demos --title 'Migrate' --description 'x'",
      "tea issue create --title t", "tea comment 95 'Still visible in Safari'",
      "tea issues ls --repo org/lib-web --state open", "tea issue 95 --comments",
      "tea pr --repo org/lib-demos 79 --comments", "tea pr ls", "tea labels ls",
      "tea issue --repo org/lib-web 95", "tea whoami"], scratchDir, false),
   ("other writes to the forge are refused",
     ["tea issues close 95", "tea issue reopen 95", "tea issues edit 95 --add-labels verified",
      "tea pr create --title x", "tea pr checkout 79", "tea pr close 79", "tea labels create x",
      "tea milestones create x", "tea issues --repo org/lib-web close 95"], scratchDir, true),
   ("forge only reads",
     ["forge ci lib-demos 79 --log", "forge reviews lib-demos 79", "forge ledger 2", "forge"], scratchDir, false),
   ("forge's writes are refused",
     ["forge pr automerge 5", "forge pr merge 5", "forge ci lib-demos main --rerun",
      "forge review lib-demos 5 f.json", "forge release lib-web note 95"], scratchDir, true)]

def toolCases : List (String × Bool) :=
  [("editing outside the checkouts is allowed", (tool "Write" "/tmp/demos-95/a.lean" repo).isNone),
   ("edit tools in the checkout are refused",
     ["Edit", "Write", "MultiEdit"].all fun t => (tool t s!"{repo}/Lib/Demos/Frame.lean" scratchDir).isSome),
   ("a build through the language server is refused", (g.check "mcp__lean-lsp__lean_build" (fun _ => none) repo).isSome),
   ("a command that doesn't parse goes through", (bash "echo 'unclosed").isNone),
   ("quoting joins words, and a quoted empty word is a word",
     tokens "a'b c'\"d\" '' x" == some [.word "ab cd", .word "", .word "x"]),
   ("operators group, and a comment ends the line",
     tokens "a&&b 2>&1 # c d\ne" == some [.word "a", .punct "&&", .word "b", .word "2", .punct ">&", .word "1", .punct ";", .word "e"])]

def check : IO Bool := do
  let mut ok := true
  for (name, commands, cwd, refused) in cases do
    let wrong := commands.filter fun c => (bash c cwd).isSome != refused
    if wrong.isEmpty then IO.println s!"PASS (hook): {name}"
    else IO.println s!"FAIL (hook): {name}: {wrong}"; ok := false
  for (name, good) in toolCases do
    if good then IO.println s!"PASS (hook): {name}" else IO.println s!"FAIL (hook): {name}"; ok := ok && good
  return ok

end GuildTests.Hook
