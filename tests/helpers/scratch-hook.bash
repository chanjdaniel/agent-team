# shellcheck shell=bash
# shellcheck disable=SC2154 # output and stderr are set by bats' run
# The helpers of the scratch-only-edits hook's tests (tests/scratch-only-edits*.bats), loaded after
# helpers/common: scratch_setup makes the worktree and runs the hook as Claude Code does, with a
# PreToolUse JSON on stdin; each helper asserts the exit and the whole message.

# scratch_setup: a worktree $wt with .scratch/task and src, $HOME/elsewhere, and a temporary
# directory $tmp and a job directory $job of the test's own (the sandbox's /tmp is under
# TEAM_SYSTEM_ROOT, since HOME itself lies under the machine's).
scratch_setup() {
  sandbox
  wt=$HOME/wt
  mkdir -p "$wt/.scratch/task" "$wt/src" "$HOME/elsewhere"
  tmp=$BATS_TEST_TMPDIR/tmpdir job=$BATS_TEST_TMPDIR/job
  # Claude Code runs hooks with the session's project directory set.
  export CLAUDE_PROJECT_DIR=$wt
}

# edit <status> <file_path> [cwd]: run the hook on an Edit call.
edit() {
  local status=$1
  run_bin "$status" --separate-stderr hooks/scratch-only-edits \
    <<<"$(jq -cn --arg p "$2" --arg cwd "${3:-$wt}" '{hook_event_name: "PreToolUse", cwd: $cwd,
      tool_name: "Edit", tool_input: {file_path: $p, old_string: "a", new_string: "b"}}')"
}

# shell <status> <command> [cwd]: run the hook on a Bash call, with TMPDIR=$tmp and
# CLAUDE_JOB_DIR=$job, or the values of hook_tmpdir and hook_job when the test sets them (to empty,
# say, which the hook reads as unset).
shell() {
  local status=$1
  TMPDIR=${hook_tmpdir-$tmp} CLAUDE_JOB_DIR=${hook_job-$job} \
    run_bin "$status" --separate-stderr hooks/scratch-only-edits \
    <<<"$(jq -cn --arg c "$2" --arg cwd "${3:-$wt}" '{hook_event_name: "PreToolUse", cwd: $cwd,
      tool_name: "Bash", tool_input: {command: $c}}')"
}

# passes <command>...: the hook allows each command, saying nothing.
passes() {
  local command
  for command in "$@"; do
    shell -0 "$command"
    assert_equal "$output$stderr" ""
  done
}

# blocked <command> <targets> [cwd]: the hook refuses the command, naming the targets outside.
blocked() {
  shell -2 "$1" "${3:-$wt}"
  assert_equal "$output" ""
  assert_equal "$stderr" "Blocked: this role may write files only under $wt/.scratch; write there with the Write tool, not a shell redirection or tee (tried $2)."
}

# unread <command> <form>: the hook refuses the command unread, naming the form it does not read.
unread() {
  shell -2 "$1"
  assert_equal "$output" ""
  assert_equal "$stderr" "Blocked: this command holds $2, which this hook does not read, so it cannot tell where the command writes; rewrite it without that, or write files under $wt/.scratch with the Write tool."
}

# unknown <command> <targets and reasons> [cwd]: the hook refuses the command, naming each target it
# cannot work out, as written, with its reason.
unknown() {
  shell -2 "$1" "${3:-$wt}"
  assert_equal "$output" ""
  assert_equal "$stderr" "Blocked: this hook cannot tell where these targets point: $2; spell each path out, or write files under $wt/.scratch with the Write tool."
}

# The reasons the unknown-target message gives, which the test files read.
# shellcheck disable=SC2034
expansion='it holds an expansion this hook does not follow' \
  moved='a cd before it may have left any directory' \
  failed='a cd before it may have failed; join them with &&'
