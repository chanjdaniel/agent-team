#!/usr/bin/env bats
# hooks/scratch-only-edits: the planner's and reviewer's PreToolUse hook lets file edits through
# only inside the worktree's .scratch/ directory.

load helpers/common

setup() {
  sandbox
  wt=$HOME/wt
  mkdir -p "$wt/.scratch/task" "$wt/src" "$HOME/elsewhere"
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
