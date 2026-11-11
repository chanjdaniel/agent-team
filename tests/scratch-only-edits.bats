#!/usr/bin/env bats
# shellcheck disable=SC2154,SC2034,SC2088 # wt, tmp, job and the reasons are helpers/scratch-hook.bash's, hook_tmpdir and hook_job its shell's; a ~ is part of a command as an agent types it
# hooks/scratch-only-edits: the planner's and reviewer's PreToolUse hook lets file edits, and
# shell redirections and tee, write only inside the worktree's .scratch/ directory.
# This file holds the edit tools, the judge of a shell target, the commands planners and reviewers
# write most often, the messages and the settings; the grammar the hook reads is in
# scratch-only-edits-grammar.bats, and what it follows (cd and variables) in
# scratch-only-edits-follow.bats.

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

@test "with no team home named, an edit or a shell write is still judged" {
  homeless() {
    TMPDIR=$tmp run --separate-stderr env -u TEAM_HOME "$REPO_ROOT/bin/hooks/scratch-only-edits" <<<"$(jq -cn --arg cwd "$wt" \
      --arg tool "$1" --argjson input "$2" '{hook_event_name: "PreToolUse", cwd: $cwd, tool_name: $tool, tool_input: $input}')"
  }
  [[ ! -e $HOME/.config/agent-team/home ]]
  homeless Write '{"file_path": "src/main.sh", "content": "x"}'
  assert_equal "$status" 2
  assert_equal "$stderr" "Blocked: this role may edit files only under $wt/.scratch (tried $wt/src/main.sh)."
  homeless Write '{"file_path": ".scratch/task/notes.md", "content": "x"}'
  assert_equal "$status:$stderr" 0:
  homeless Bash '{"command": "echo x > src/a"}'
  assert_equal "$status" 2
  assert_equal "$stderr" "Blocked: this role may write files only under $wt/.scratch; write there with the Write tool, not a shell redirection or tee (tried $wt/src/a)."
  homeless Bash '{"command": "echo x > .scratch/a"}'
  assert_equal "$status:$stderr" 0:
}

@test "input it cannot read is refused, naming why" {
  local input
  for input in 'not json' '' '[]' '{"tool_input": {"file_path": "src/a"}}' '{"tool_name": 5}' '"Write"'; do
    run_bin -2 --separate-stderr hooks/scratch-only-edits <<<"$input"
    [[ $stderr == "Blocked: scratch-only-edits could not read the hook's input (JSON with a tool_name); a guard that cannot decide refuses, so report it as BLOCKED and do not reach it another way." ]] ||
      { printf 'input %s: stderr %s\n' "$input" "$stderr" >&2; return 1; }
  done
}

@test "a command failing inside it is a refusal that names the hook and the exit code" {
  # The read of the call's working directory fails, after its input was read.
  fails_on_call jq .cwd
  edit -2 "$wt/.scratch/task/notes.md"
  assert_equal "$output" ""
  assert_equal "$stderr" "Blocked by scratch-only-edits: it failed with exit 5 before it could decide, and a guard that cannot decide refuses; report it as BLOCKED and do not reach it another way."
  assert_equal "$(wc -l <"$STUB_CALLS/jq.failed")" 1
}

@test "a wrong argument on its command line refuses every call" {
  local arg
  for arg in --bogus '' /abs/answer.md .scratch/../answer.md ./.scratch/answer.md .scratch//answer.md \
    .scratch/answer.md/ .scratch/. '.scratch/a b.md' "$(printf '.scratch/a\nb')"; do
    run_bin -2 --separate-stderr hooks/scratch-only-edits "$arg" \
      <<<"$(jq -cn --arg cwd "$wt" '{cwd: $cwd, tool_name: "Write", tool_input: {file_path: ".scratch/answer.md"}}')"
    assert_equal "$stderr" "scratch-only-edits: usage: scratch-only-edits [<the one file a session may write, relative to the worktree>]   (the hook's input on stdin)"
  done
  run_bin -2 --separate-stderr hooks/scratch-only-edits .scratch/answer.md .scratch/other.md \
    <<<"$(jq -cn --arg cwd "$wt" '{cwd: $cwd, tool_name: "Write", tool_input: {file_path: ".scratch/answer.md"}}')"
  assert_contains "$stderr" "usage: scratch-only-edits ["
}

# one <status> <tool> <path> [cwd]: run the hook given the one file .scratch/answer.md on an edit
# tool's call.
one() {
  run_bin "$1" --separate-stderr hooks/scratch-only-edits .scratch/answer.md \
    <<<"$(jq -cn --arg tool "$2" --arg p "$3" --arg cwd "${4:-$wt}" '{hook_event_name: "PreToolUse", cwd: $cwd,
      tool_name: $tool, tool_input: (if $tool == "NotebookEdit" then {notebook_path: $p} else {file_path: $p, content: "x"} end)}')"
}

@test "given one file, an edit tool writes that file and nothing else, elsewhere under .scratch/ included" {
  local tool
  for tool in Write Edit MultiEdit NotebookEdit; do
    one -0 "$tool" "$wt/.scratch/answer.md"
    assert_equal "$output$stderr" ""
    one -0 "$tool" .scratch/answer.md
    one -0 "$tool" answer.md "$wt/.scratch"
    one -0 "$tool" "$wt/.scratch/task/../answer.md"
    one -2 "$tool" "$wt/.scratch/task/notes.md"
    assert_equal "$stderr" "Blocked: this session may edit one file only, $wt/.scratch/answer.md (tried $wt/.scratch/task/notes.md)."
    one -2 "$tool" "$wt/.scratch/answer.md.bak"
    assert_contains "$stderr" "(tried $wt/.scratch/answer.md.bak)"
    one -2 "$tool" "$wt/.scratch/answer.md/x"
    one -2 "$tool" "$wt/src/main.sh"
    assert_contains "$stderr" "only, $wt/.scratch/answer.md (tried $wt/src/main.sh)."
    one -2 "$tool" "$HOME/elsewhere/answer.md"
  done
  # The root is the project directory when set, as without the argument.
  mkdir -p "$HOME/project/.scratch"
  CLAUDE_PROJECT_DIR=$HOME/project one -0 Write "$HOME/project/.scratch/answer.md"
  CLAUDE_PROJECT_DIR=$HOME/project one -2 Write "$wt/.scratch/answer.md"
  assert_contains "$stderr" "only, $HOME/project/.scratch/answer.md (tried"
  # A call with no path passes, as without the argument.
  run_bin -0 hooks/scratch-only-edits .scratch/answer.md \
    <<<"$(jq -cn --arg cwd "$wt" '{cwd: $cwd, tool_name: "Write", tool_input: {}}')"
}

@test "given one file, a symlink to it or from it is blocked" {
  # The file itself a link, to outside or inside .scratch/: the write would land elsewhere.
  ln -s "$HOME/elsewhere/target.md" "$wt/.scratch/answer.md"
  one -2 Write "$wt/.scratch/answer.md"
  assert_equal "$stderr" "Blocked: this session may edit one file only, $wt/.scratch/answer.md (tried $HOME/elsewhere/target.md)."
  rm "$wt/.scratch/answer.md"
  ln -s "$wt/.scratch/task/notes.md" "$wt/.scratch/answer.md"
  one -2 Write "$wt/.scratch/answer.md"
  rm "$wt/.scratch/answer.md"
  # A .scratch/ that is a link.
  mkdir -p "$HOME/wt2"
  ln -s "$wt/.scratch" "$HOME/wt2/.scratch"
  CLAUDE_PROJECT_DIR=$HOME/wt2 one -2 Write "$HOME/wt2/.scratch/answer.md"
  assert_equal "$stderr" "Blocked: this session may edit one file only, $HOME/wt2/.scratch/answer.md (tried $wt/.scratch/answer.md)."
  # A path that links to the one file writes that file.
  ln -s "$wt/.scratch/answer.md" "$wt/.scratch/alias.md"
  one -0 Write "$wt/.scratch/alias.md"
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

@test "the commands planners and reviewers write most often pass" {
  mkdir -p "$job/tmp"
  local commands=()
  # The shapes a replay of their sessions found most often, with fixture paths and names.
  mapfile -t -d '' commands < <(printf '%s\0' \
    'git fetch origin 2>&1 | tail -2; git log --oneline origin/dev..HEAD 2>/dev/null | head' \
    'cmd >/dev/null 2>&1; echo "exit $?"' \
    'tests/run > .scratch/task/run.log 2>&1; echo "exit $?"; tail -25 .scratch/task/run.log' \
    "cd $wt && tests/run > .scratch/task/run.log 2>&1" \
    'cmd 2>&1 | tee .scratch/task/out.txt | tail -5' \
    "cat > .scratch/task/review.md <<'EOF'"$'\n# Review\n\n1. **blocking** - `cmd > out` writes outside.\nEOF' \
    "cat >> .scratch/task/review.md <<'EOF'"$'\n## Re-review\n\nThe `while IFS= read -r f` loop leaks `f`.\nEOF' \
    "cd .scratch/task && cat > review.md <<'EOF'"$'\n# Review\nEOF' \
    "cd $wt/.scratch/task && cat > review.md <<'EOF'"$'\n# Review\nEOF' \
    "mkdir -p .scratch/task/tickets && cd .scratch/task/tickets && cat > 01-x.md <<'EOF'"$'\n# 01\nEOF' \
    '{ printf "\n"; sed "1s/^# /## /" .scratch/task/rereview.md; } >> .scratch/task/review.md' \
    'git show origin/dev:src/a.sh > $CLAUDE_JOB_DIR/tmp/a.sh; diff $CLAUDE_JOB_DIR/tmp/a.sh src/a.sh' \
    'T=$CLAUDE_JOB_DIR/tmp/probe; mkdir -p $T; cmd > $T/out.log 2>&1; tail $T/out.log' \
    'T="$CLAUDE_JOB_DIR/tmp"; for f in a b; do cmd "$f" > "$T/$f.log"; done' \
    'd=$(mktemp -d) && cmd > "$d/out" && cat "$d/out"' \
    'd=$(mktemp -d -p "$CLAUDE_JOB_DIR/tmp") && git archive HEAD | tar -x -C "$d" && cmd > $d/run.log 2>&1' \
    'cmd > "$TMPDIR/x"; cmd 2>/dev/null >> $TMPDIR/y' \
    'for f in src/a src/b; do echo "== $f"; cmd "$f" 2>&1 | tail -3; done > .scratch/task/all.log' \
    'diff <(git show origin/dev:src/a) <(cat src/a) > .scratch/task/a.diff' \
    'git commit -m "$(cat <<'"'EOF'"$'\nfix: read a > in a message\n\nThe body.\nEOF\n)"' \
    'gh pr create --title "x" --body "$(cat <<'"'EOF'"$'\n## Summary\n\n- a > b\nEOF\n)" 2>&1 | tail -1' \
    'eval "$(~/agent-team/bin/team-stack env)"; ./scripts/seed.sh 2>&1 | tail -5' \
    'eval "$(~/agent-team/bin/team-stack env)" && npx playwright test > .scratch/task/e2e.log 2>&1; echo EXIT=$?' \
    'while IFS= read -r line; do echo "$line"; done < src/list > .scratch/task/list' \
    'n=$(grep -c x src/a); [[ $n -gt 0 ]] && echo "$n" > .scratch/task/count')
  passes "${commands[@]}"
}

@test "a target with an empty value writes nothing" {
  passes "cmd > ''" 'cmd | tee "" .scratch/x'
}

@test "\$TMPDIR and \$CLAUDE_JOB_DIR are unknown when the hook's environment has none, and a mktemp there uses the machine's /tmp" {
  hook_tmpdir='' hook_job=''
  unknown 'cmd > $TMPDIR/x' "\$TMPDIR/x ($expansion)"
  unknown 'cmd > $CLAUDE_JOB_DIR/x' "\$CLAUDE_JOB_DIR/x ($expansion)"
  passes "cmd > $TEAM_SYSTEM_ROOT/tmp/x" 'd=$(mktemp -d) && cmd > $d/x'
}

@test "a target the hook cannot work out is refused, named as written with why" {
  unknown 'cmd > "$out"' "\"\$out\" ($expansion)"
  unknown 'cmd > $HOMEDIR/x' "\$HOMEDIR/x ($expansion)"
  unknown 'cmd | tee -- .scratch/$x/y "$z"' ".scratch/\$x/y ($expansion), \"\$z\" ($expansion)"
}

@test "a command with targets of both kinds gives the unknown-target message first, then the outside one" {
  shell -2 'cmd > "$out" 2> x'
  assert_equal "$stderr" "Blocked: this hook cannot tell where these targets point: \"\$out\" ($expansion); spell each path out, or write files under $wt/.scratch with the Write tool.
Blocked: this role may write files only under $wt/.scratch; write there with the Write tool, not a shell redirection or tee (tried $wt/x)."
}

@test "a target the hook cannot work out after a cd says whether the cd may have failed or left any directory" {
  shell -2 'cd .scratch/task; cmd > a; cd "$x" && cmd > b; cd /etc && cmd > c'
  assert_equal "$output" ""
  assert_equal "$stderr" "Blocked: this hook cannot tell where these targets point: a (a cd before it may have failed; join them with &&), b (a cd before it may have left any directory); spell each path out, or write files under $wt/.scratch with the Write tool.
Blocked: this role may write files only under $wt/.scratch; write there with the Write tool, not a shell redirection or tee (tried /etc/c)."
}

@test "a target through a variable says the variable is not followed there, or that a mktemp may leave it empty" {
  shell -2 'x=a; x=src; d=$(mktemp -d); cmd > $x/y 2> "$d/z" | tee -- "$out"'
  assert_equal "$output" ""
  assert_equal "$stderr" "Blocked: this hook cannot tell where these targets point: \$x/y (\$x is not followed here), \"\$d/z\" (\$d may be empty when mktemp fails; join them with &&), \"\$out\" ($expansion); spell each path out, or write files under $wt/.scratch with the Write tool."
}

@test "a refusal unread comes first, whatever else the command writes" {
  unread 'cmd > out; x=`y`' 'a backtick substitution'
  unread 'cmd > "$out"; select x in a; do :; done' 'a select command'
}

# The CPU seconds the shell's waited-for children have used so far, in CPU: cpu_now. Read with the
# times builtin in this shell (a subshell would read its own), so a bound on a hook's CPU holds on a
# loaded machine, where its wall time does not.
cpu_now() {
  times >"$BATS_TEST_TMPDIR/times"
  CPU=$(awk 'NR == 2 { split($1, u, /[ms]/); split($2, s, /[ms]/); print u[1] * 60 + u[2] + s[1] * 60 + s[2] }' \
    "$BATS_TEST_TMPDIR/times")
}

# Succeed when the children have used under <seconds> of CPU since <before>: cpu_under <before> <seconds>
cpu_under() {
  cpu_now
  awk -v before="$1" -v now="$CPU" -v max="$2" 'BEGIN { exit !(now - before < max) }' ||
    { echo "used $(awk -v before="$1" -v now="$CPU" 'BEGIN { print now - before }') CPU seconds, not under $2" >&2; return 1; }
}

# <text> once for each i from 1 to <n>, one per line, each @ in it replaced by i, untraced since
# it loops: numbered_lines <n> <text>
numbered_lines() {
  [[ -n ${UNTRACED_DEBUG+set} ]] || { untraced numbered_lines "$@"; return; }
  local i
  for ((i = 1; i <= $1; i++)); do echo "${2//@/$i}"; done
}

@test "a long here-document is judged quickly" {
  local body before
  body=$(numbered_lines 3000 'line @ with a > and a | tee x')
  cpu_now
  before=$CPU
  passes "cat > .scratch/task/big.txt <<'EOF'
$body
EOF"
  cpu_under "$before" 5
  # Inside a substitution too, as a commit message is written.
  cpu_now
  before=$CPU
  passes "git commit -m \"\$(cat <<'EOF'
$body
EOF
)\" > .scratch/task/out"
  cpu_under "$before" 5
  # And with its delimiter unquoted, whose body's expansions are read.
  body=$(numbered_lines 1000 'line @ with ${HOME}, $(echo @) and a > and a | tee x')
  cpu_now
  before=$CPU
  passes "cat > .scratch/task/big.txt <<EOF
$body
EOF"
  cpu_under "$before" 5
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
