#!/usr/bin/env bats
# shellcheck disable=SC2154,SC2034,SC2088 # wt, tmp, job and the reasons are helpers/scratch-hook.bash's, hook_tmpdir and hook_job its shell's; a ~ is part of a command as an agent types it
# hooks/scratch-only-edits: the planner's and reviewer's PreToolUse hook lets file edits, and
# shell redirections and tee, write only inside the worktree's .scratch/ directory.
# This file holds the edit tools, the judge of a shell target, the messages and the settings; the
# grammar the hook reads is in scratch-only-edits-grammar.bats, and what it follows (cd and
# variables) in scratch-only-edits-follow.bats.

load helpers/common
load helpers/scratch-hook

setup() {
  scratch_setup
}

@test "an edit inside .scratch/ passes" {
  edit -0 "$wt/.scratch/task/notes.md"
  assert_equal "$output$stderr" ""
  edit -0 "$wt/.scratch/new-dir/new-file.md"
  edit -0 .scratch/task/notes.md
  # Relative to the session's working directory, which may have moved into .scratch/.
  edit -0 task/notes.md "$wt/.scratch"
}

@test "an edit outside .scratch/ is blocked with the reason on stderr" {
  edit -2 "$wt/src/main.sh"
  assert_equal "$output" ""
  assert_equal "$stderr" "Blocked: this role may edit files only under $wt/.scratch (tried $wt/src/main.sh)."
  edit -2 "$HOME/elsewhere/x"
  edit -2 "$wt/.scratch"-other/x
  assert_contains "$stderr" "(tried $wt/.scratch-other/x)"
}

@test "relative paths and .. escapes are resolved before the check" {
  edit -2 src/main.sh
  assert_contains "$stderr" "(tried $wt/src/main.sh)"
  edit -2 "$wt/.scratch/../src/main.sh"
  assert_contains "$stderr" "(tried $wt/src/main.sh)"
  edit -2 .scratch/task/../../README.md
  assert_contains "$stderr" "(tried $wt/README.md)"
}

@test "a symlink from .scratch/ to outside it is blocked" {
  ln -s "$wt/src" "$wt/.scratch/src"
  edit -2 "$wt/.scratch/src/main.sh"
  assert_contains "$stderr" "(tried $wt/src/main.sh)"
  ln -s "$HOME/elsewhere/target.md" "$wt/.scratch/file.md"
  edit -2 "$wt/.scratch/file.md"
  assert_contains "$stderr" "(tried $HOME/elsewhere/target.md)"
}

@test "the root is the project directory, or the session's working directory without one" {
  mkdir -p "$HOME/project/.scratch"
  CLAUDE_PROJECT_DIR=$HOME/project edit -0 "$HOME/project/.scratch/x"
  CLAUDE_PROJECT_DIR=$HOME/project edit -2 "$wt/.scratch/x"
  assert_contains "$stderr" "only under $HOME/project/.scratch"
  unset CLAUDE_PROJECT_DIR
  edit -0 "$HOME/project/.scratch/x" "$HOME/project"
  edit -2 "$wt/.scratch/x" "$HOME/project"
  assert_contains "$stderr" "only under $HOME/project/.scratch"
}

@test "a notebook edit is checked by its notebook path" {
  run_bin -2 --separate-stderr hooks/scratch-only-edits \
    <<<"$(jq -cn --arg cwd "$wt" '{cwd: $cwd, tool_name: "NotebookEdit", tool_input: {notebook_path: "src/a.ipynb"}}')"
  assert_contains "$stderr" "(tried $wt/src/a.ipynb)"
}

@test "a tool call without a path passes" {
  run_bin -0 hooks/scratch-only-edits \
    <<<"$(jq -cn --arg cwd "$wt" '{cwd: $cwd, tool_name: "Bash", tool_input: {command: "touch src/x"}}')"
  assert_equal "$output" ""
}

@test "a shell append to the team home's records is blocked" {
  blocked 'echo x >> ~/agent-team-records/memory/p/MEMORY.md' "$HOME/agent-team-records/memory/p/MEMORY.md"
}

@test "a shell redirection or tee outside .scratch/ is blocked, naming its target" {
  blocked 'printf x > /home/me/repo/src/a.js' /home/me/repo/src/a.js
  blocked 'cmd 2> notes.txt' "$wt/notes.txt"
  blocked 'cmd | tee -a $HOME/x' "$HOME/x"
  blocked 'cmd &> out.log' "$wt/out.log"
  blocked 'cmd &>> out.log' "$wt/out.log"
  blocked 'cmd >| out.log' "$wt/out.log"
  blocked 'cmd >& out.log' "$wt/out.log"
  blocked 'cmd >out.log' "$wt/out.log"
  blocked 'cmd 1>>${HOME}/x' "$HOME/x"
  blocked 'cmd > "$HOME"/x' "$HOME/x"
  blocked 'cmd > .scratch/../src/x' "$wt/src/x"
  blocked 'cmd > x; echo ok' "$wt/x"
  blocked 'true && cmd > x' "$wt/x"
  blocked 'echo a>x' "$wt/x"
  blocked 'cmd > ../file' "$HOME/file"
  # A relative target is taken from the session's working directory.
  blocked 'cmd > x' "$wt/src/x" "$wt/src"
  # Quoted, a tilde is a file name.
  blocked 'cmd > "~/x"' "$wt/~/x"
}

@test "a blocked shell target is named as written, its symlinks kept, and a symlink out of .scratch/ is still blocked" {
  # On macOS /home resolves to /System/Volumes/Data/home, so a resolved name would not be the
  # one the agent wrote.
  ln -s "$HOME/elsewhere" "$HOME/linked"
  blocked 'cmd > ~/linked/x' "$HOME/linked/x"
  blocked 'cmd > ~/linked/../src/x' "$HOME/src/x"
  ln -s "$HOME/elsewhere" "$wt/.scratch/out"
  blocked 'cmd > .scratch/out/x' "$wt/.scratch/out/x"
}

@test "every blocked target of one command is named" {
  blocked 'cmd > a 2> .scratch/ok | tee b c' "$wt/a, $wt/b, $wt/c"
}

@test "a shell write into .scratch/, a temporary directory or a device passes" {
  mkdir -p "$tmp" "$job/tmp"
  local commands=()
  mapfile -t commands <<'EOF'
tests/run > .scratch/task/run.log 2>&1
cmd > /dev/null
cmd 2>/dev/null
cmd &>/dev/null
cmd > /dev/stdout
cmd > /dev/stderr
cmd > /dev/fd/3
cmd 2>&1 | tee .scratch/task/out.txt
cmd | tee -a "$HOME/wt/.scratch/task/out.txt" >/dev/null
cmd > "$TMPDIR/x"
cmd > $TMPDIR/x
cmd > ${TMPDIR}/x
cmd > "${TMPDIR}"/x
cmd > "$CLAUDE_JOB_DIR/tmp/x"
cmd > $CLAUDE_JOB_DIR/tmp/x
cmd > ${CLAUDE_JOB_DIR}/tmp/x
cmd > ~/wt/.scratch/x
cmd > $HOME/wt/.scratch/x
cmd > "${HOME}/wt/.scratch/x"
cmd < src/input.txt
cmd > .scratch/task/a\ b.log
cmd > ".scratch/task/a b.log"
EOF
  passes "${commands[@]}"
  # The sandbox's /tmp, which stands for the machine's.
  passes "cmd > $TEAM_SYSTEM_ROOT/tmp/x" "cmd > $tmp/x" "cmd > $job/x"
  # From inside .scratch/, a relative target stays in it.
  shell -0 'cmd > notes.txt' "$wt/.scratch/task"
}

@test "a target with an empty value writes nothing" {
  passes "cmd > ''" 'cmd | tee "" .scratch/x'
}

@test "\$TMPDIR is the machine's /tmp when the hook's environment has none, and \$CLAUDE_JOB_DIR unknown" {
  hook_tmpdir='' hook_job=''
  passes 'cmd > $TMPDIR/x'
  blocked 'cmd > $TMPDIR/../x' "$TEAM_SYSTEM_ROOT/x"
  unknown 'cmd > $CLAUDE_JOB_DIR/x' "\$CLAUDE_JOB_DIR/x ($expansion)"
}

@test "a target the hook cannot work out is refused, named as written with why" {
  unknown 'cmd > "$out"' "\"\$out\" ($expansion)"
  unknown 'cmd > $HOMEDIR/x' "\$HOMEDIR/x ($expansion)"
  unknown 'cmd | tee .scratch/$x/y "$z"' ".scratch/\$x/y ($expansion), \"\$z\" ($expansion)"
}

@test "a command with targets of both kinds gives the unknown-target message first, then the outside one" {
  shell -2 'cmd > "$out" 2> x'
  assert_equal "$stderr" "Blocked: this hook cannot tell where these targets point: \"\$out\" ($expansion); spell each path out, or write files under $wt/.scratch with the Write tool.
Blocked: this role may write files only under $wt/.scratch; write there with the Write tool, not a shell redirection or tee (tried $wt/x)."
}

@test "a refusal unread comes first, whatever else the command writes" {
  unread 'cmd > out; x=`y`' 'a backtick substitution'
  unread 'cmd > "$out"; select x in a; do :; done' 'a select command'
}

@test "a long command is judged quickly" {
  local body
  body=$(for i in $(seq 1 3000); do echo "line $i with a > and a | tee x"; done)
  SECONDS=0
  passes "git commit -m \"$body\" > .scratch/task/out"
  ((SECONDS < 5))
  SECONDS=0
  passes "printf '%s' '$body' | tee .scratch/task/out"
  ((SECONDS < 5))
}

@test "the planner's and reviewer's settings run the hook on Bash and the edit tools; the ops role's on the edit tools only" {
  local role
  for role in planner reviewer; do
    assert_equal "$(jq -r '.hooks.PreToolUse[] | select(.hooks[].command | endswith("/scratch-only-edits")) | .matcher' \
      "$REPO_ROOT/settings/$role.json")" "Edit|Write|MultiEdit|NotebookEdit|Bash"
  done
  assert_equal "$(jq -r '.hooks.PreToolUse[] | select(.hooks[].command | endswith("/scratch-only-edits")) | .matcher' \
    "$REPO_ROOT/settings/ops.json")" "Edit|Write|MultiEdit|NotebookEdit"
}
