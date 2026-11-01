#!/usr/bin/env bats
# hooks/scratch-only-edits: the planner's and reviewer's PreToolUse hook lets file edits, and
# shell redirections and tee, write only inside the worktree's .scratch/ directory.

load helpers/common

setup() {
  sandbox
  wt=$HOME/wt
  mkdir -p "$wt/.scratch/task" "$wt/src" "$HOME/elsewhere"
  tmp=$BATS_TEST_TMPDIR/tmpdir job=$BATS_TEST_TMPDIR/job
  # Claude Code runs hooks with the session's project directory set.
  export CLAUDE_PROJECT_DIR=$wt
}

# edit <file_path> [cwd]: run the hook on an Edit call, as Claude Code sends it.
edit() {
  local status=$1
  run_bin "$status" --separate-stderr hooks/scratch-only-edits \
    <<<"$(jq -cn --arg p "$2" --arg cwd "${3:-$wt}" '{hook_event_name: "PreToolUse", cwd: $cwd,
      tool_name: "Edit", tool_input: {file_path: $p, old_string: "a", new_string: "b"}}')"
}

# shell <status> <command> [cwd]: run the hook on a Bash call, as Claude Code sends it, with a
# temporary directory and a job directory of the test's own (the sandbox's /tmp is under
# TEAM_SYSTEM_ROOT, since HOME itself lies under the machine's).
shell() {
  local status=$1
  TMPDIR=$tmp CLAUDE_JOB_DIR=$job run_bin "$status" --separate-stderr hooks/scratch-only-edits \
    <<<"$(jq -cn --arg c "$2" --arg cwd "${3:-$wt}" '{hook_event_name: "PreToolUse", cwd: $cwd,
      tool_name: "Bash", tool_input: {command: $c}}')"
}

# blocked <command> <target> [cwd]: the hook refuses the command, naming the target.
blocked() {
  shell -2 "$1" "${3:-$wt}"
  assert_equal "$output" ""
  assert_equal "$stderr" "Blocked: this role may write files only under $wt/.scratch; write there with the Write tool, not a shell redirection or tee (tried $2)."
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

@test "a shell append to the team home's records is blocked, as T113's reviewer's got through" {
  blocked 'echo x >> ~/agent-team-records/memory/p/MEMORY.md' "$HOME/agent-team-records/memory/p/MEMORY.md"
}

@test "a shell redirection or tee outside .scratch/ is blocked, naming its target" {
  blocked 'printf x > /home/me/repo/src/a.js' /home/me/repo/src/a.js
  blocked 'cmd 2> notes.txt' "$wt/notes.txt"
  blocked 'cmd | tee -a $HOME/x' "$HOME/x"
  blocked "cat > ../file <<'EOF'
a > b
EOF" "$HOME/file"
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
  shell -2 'cmd > a 2> .scratch/ok | tee b c'
  assert_contains "$stderr" "(tried $wt/a, $wt/b, $wt/c)."
}

@test "a tee's every file is a target, after its options and after --" {
  blocked 'cmd | tee --append -p x' "$wt/x"
  blocked 'cmd | /usr/bin/tee x' "$wt/x"
  blocked 'cmd | tee -- -x' "$wt/-x"
  blocked 'cmd | tee .scratch/a x' "$wt/x"
  blocked 'cmd | (tee x)' "$wt/x"
  blocked 'cmd | sudo tee x' "$wt/x"
  blocked 'cmd | X=1 tee x' "$wt/x"
  blocked 'if true; then cmd | tee x; fi' "$wt/x"
  shell -0 'cmd | tee'
  shell -0 'cmd | tee -a .scratch/task/log /dev/null'
  shell -0 'echo tee x'
  shell -0 'grep tee x'
}

@test "a shell write into .scratch/, a temporary directory or a device passes" {
  mkdir -p "$tmp" "$job/tmp"
  local command
  while IFS= read -r command; do
    shell -0 "$command"
    assert_equal "$output$stderr" ""
  done <<'EOF'
tests/run > .scratch/task/run.log 2>&1
cmd > /dev/null
cmd 2>/dev/null
cmd &>/dev/null
cmd > /dev/stdout
cmd > /dev/stderr
cmd > /dev/fd/3
cmd 2>&1 | tee .scratch/task/out.txt
cmd | tee -a "$wt/.scratch/task/out.txt" >/dev/null
cmd > "$TMPDIR/x"
cmd > ${TMPDIR}/x
cmd > "$CLAUDE_JOB_DIR/tmp/x"
cmd > ${CLAUDE_JOB_DIR}/tmp/x
cmd >&2
cmd 2>&1
cmd 1>&2-
cmd >&-
cmd 3>&1 1>&2 2>&3
cmd 2>& 1
cmd > "$out"
cmd > $(mktemp)
cmd > `mktemp`
cmd > ${out:-x}
cmd > $HOMEDIR/x
cmd < src/input.txt
cmd <<< "a > b"
cmd > .scratch/task/a\ b.log
cmd > ".scratch/task/a b.log"
EOF
  # The sandbox's /tmp, which stands for the machine's.
  shell -0 "cmd > $TEAM_SYSTEM_ROOT/tmp/x"
  shell -0 "cmd > $tmp/x"
  shell -0 "cmd > $job/x"
  # From inside .scratch/, a relative target stays in it.
  shell -0 'cmd > notes.txt' "$wt/.scratch/task"
}

@test "quoted text, heredoc bodies, comments and comparisons are not redirections" {
  local command
  while IFS= read -r -d '' command; do
    shell -0 "$command"
    assert_equal "$output$stderr" ""
  done < <(printf '%s\0' \
    'echo "a > b"' \
    "grep -n '>>' file" \
    'echo a\>b' \
    'echo "a \" > b"' \
    "git commit -F - <<'EOF'
title > body
x >> y | tee z
EOF" \
    "cat <<-EOF >/dev/null
	a > b
	EOF
echo done" \
    "cat <<A <<B
a > x
A
b > y
B" \
    'echo ok # > x' \
    '[[ $a > b ]] && echo yes' \
    '(( a > b )) && echo yes' \
    'echo $(( a > b ? 1 : 2 ))' \
    'echo ${x:->}' \
    'diff <(sort a) <(sort b)' \
    "echo 'it''s > fine'")
  # A heredoc body ends at its delimiter: what follows it is judged again.
  blocked "cat <<EOF
a > x
EOF
echo b > y" "$wt/y"
  blocked 'echo "a > b" > c' "$wt/c"
}

@test "a redirection inside a command or process substitution is still judged" {
  blocked 'x=$(cmd > out)' "$wt/out"
  blocked 'cmd | tee >(gzip > out.gz)' "$wt/out.gz"
  blocked '( cmd ) > out' "$wt/out"
  blocked '{ cmd; } > out' "$wt/out"
  # Inside double quotes and backticks too, at any depth.
  blocked 'x="$(cmd > out)"' "$wt/out"
  blocked 'x=`cmd > out`' "$wt/out"
  blocked 'echo "$(printf x | tee out)"' "$wt/out"
  blocked 'echo "a $(echo "$(cmd >> out)") b"' "$wt/out"
  blocked 'x=`echo \`cmd > out\``' "$wt/out"
  blocked 'echo "`cmd > out`"' "$wt/out"
  blocked 'x="$(cmd "a)b" > out)"' "$wt/out"
  # Its target is judged against the outer command's working directory.
  blocked 'x="$(cmd > out)"' "$wt/src/out" "$wt/src"
  # A refused target holding a substitution is named with it as written.
  blocked 'cmd | tee "out-$(date).log"' "$wt/out-\$(date).log"
  blocked 'cmd > "out-$(( 1 + 2 )).log"' "$wt/out-\$(( 1 + 2 )).log"
  blocked 'cmd > out-`date`' "$wt/out-\`date\`"
  blocked 'cmd > "out-`date`.log"' "$wt/out-\`date\`.log"
  # What is fine outside a substitution is fine inside it.
  shell -0 'x="$(cmd 2>/dev/null)"'
  shell -0 'x="$(cmd > .scratch/task/out)" && echo "$x"'
  shell -0 'x=`cmd 2>&1`'
  shell -0 'echo "$(( a > b ))"'
  shell -0 'echo "it is \$(cmd > out)"'
}

@test "an ANSI-C string and an old arithmetic expansion are read whole, so what follows them is judged" {
  blocked "echo \$'a\\'b' > out" "$wt/out"
  blocked "echo \$'a > b' > out" "$wt/out"
  shell -0 "echo \$'a > b'"
  blocked 'echo $[1<<2]
echo x > out' "$wt/out"
  shell -0 'echo $[1 > 2]'
}

@test "a tee is found behind the wrappers, their options and their option values" {
  blocked 'cmd | timeout 60 tee out' "$wt/out"
  blocked 'cmd | timeout -s KILL -k 5 10s tee out' "$wt/out"
  blocked 'cmd | nice tee out' "$wt/out"
  blocked 'cmd | nice -n 5 tee out' "$wt/out"
  blocked 'cmd | sudo -u me tee out' "$wt/out"
  blocked 'cmd | sudo --user me -E tee out' "$wt/out"
  blocked 'cmd | stdbuf -oL tee out' "$wt/out"
  blocked 'cmd | stdbuf -o L tee out' "$wt/out"
  blocked 'cmd | env -u X A=1 tee out' "$wt/out"
  blocked 'cmd | exec -a name tee out' "$wt/out"
  blocked 'cmd | builtin command nohup tee out' "$wt/out"
  blocked 'cmd | time -p tee out' "$wt/out"
  # A lookup runs nothing, and a wrapper's own arguments are no tee's files.
  shell -0 'command -v tee out'
  shell -0 'timeout 60 cmd out'
  shell -0 'sudo -u tee cmd x'
}

@test "a long heredoc is judged quickly" {
  local body
  body=$(for i in $(seq 1 3000); do echo "line $i with a > and a | tee x"; done)
  SECONDS=0
  shell -0 "cat > .scratch/task/big.txt <<'EOF'
$body
EOF"
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
