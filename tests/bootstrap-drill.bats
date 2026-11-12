#!/usr/bin/env bats
# tests/bootstrap-drill on a stub team-bootstrap: the drill-record line it ends every run with,
# which team-drill import reads from the Bootstrap workflow's job logs. The drill runs from a
# checkout of the test's own, DRILL_ROOT, a repository holding the drill (a link to the run's
# shared copy) and the stub as bin/team-bootstrap; claude is the sandbox's stub, answering 2.1.321.
# The real drill installs real tools, so only the by-hand Bootstrap workflow runs it.

load helpers/common

DRILL_ROOT=''

setup() {
  sandbox
  DRILL_ROOT=$BATS_TEST_TMPDIR/root
  mkdir -p "$DRILL_ROOT/tests" "$DRILL_ROOT/bin"
  ln "$(shared bootstrap-drill "$REPO_ROOT/tests/bootstrap-drill")" "$DRILL_ROOT/tests/bootstrap-drill"
  stub_command team-bootstrap
  ln "$BATS_TEST_TMPDIR/stubs/team-bootstrap" "$DRILL_ROOT/bin/team-bootstrap"
  echo drill >"$DRILL_ROOT/README.md"
  git -C "$DRILL_ROOT" init -q
  git -C "$DRILL_ROOT" add README.md
  git -C "$DRILL_ROOT" commit -q -m "chore: start the drill's checkout"
  stub_reply claude '2.1.321 (Claude Code)'
}

# The drill's checkout's HEAD.
drill_head() {
  git -C "$DRILL_ROOT" rev-parse HEAD
}

# team-bootstrap prints <line> and exits 1, as it does at a step of Daniel's or on a failure of
# its own: bootstrap_ends <line>
bootstrap_ends() {
  stub_reply team-bootstrap "$1" 1
}

# Run the drill as the workflow's job does: drill [<args>...]
drill() {
  run "$DRILL_ROOT/tests/bootstrap-drill" "$@"
}

# PATH without the claude stub and any other directory holding a claude.
no_claude_path() {
  rm -f "$BATS_TEST_TMPDIR/stubs/claude"
  tr ':' '\n' <<<"$PATH" | while read -r dir; do [[ -x $dir/claude ]] || echo "$dir"; done | paste -sd ':'
}

@test "a bootstrap that ends at a step of Daniel's passes, and the last line records the machine, the checkout's HEAD and Claude Code's version" {
  bootstrap_ends "projects: Daniel: run gh auth login, which the project clones need"
  drill ci-arch
  assert_equal "$status" 0
  assert_equal "$(tail -n 1 <<<"$output")" "drill-record: machine=ci-arch verdict=pass commit=$(drill_head) claude=2.1.321"
  assert_equal "$(stub_calls team-bootstrap)" '["--name","ci-arch"]'
  assert_equal "$(stub_calls claude)" '["--version"]'
  # The summary of a machine set up passes too.
  bootstrap_ends "check: summary: set up, and this machine holds the lease"
  drill ci-macos
  assert_equal "$status" 0
  assert_equal "$(tail -n 1 <<<"$output")" "drill-record: machine=ci-macos verdict=pass commit=$(drill_head) claude=2.1.321"
}

@test "a bootstrap that stops at a step of Daniel's before the projects stage fails, since the runner plays every earlier one" {
  bootstrap_ends "machine: Daniel: clone the team home, then name it for this machine: git clone https://github.com/owner/records.git ~/agent-team-records"
  drill ci-arch
  assert_equal "$status" 1
  assert_equal "$(tail -n 2 <<<"$output")" "== it stopped at the machine stage, before the projects stage, which the drill reaches by playing Daniel's earlier steps
drill-record: machine=ci-arch verdict=fail commit=$(drill_head) claude=2.1.321"
  bootstrap_ends "tools: Daniel: install the 1Password CLI"
  drill ci-macos
  assert_equal "$status" 1
  assert_contains "$output" "== it stopped at the tools stage, before the projects stage"
  # A later stage's step of Daniel's passes.
  bootstrap_ends "config: Daniel: apply or capture the changed user settings"
  drill ci-macos
  assert_equal "$status" 0
}

@test "a bootstrap that fails on its own fails, and the last line says so" {
  bootstrap_ends "tools: the Claude Code install failed (exit 1)"
  drill ci-arch
  assert_equal "$status" 1
  assert_equal "$(tail -n 1 <<<"$output")" "drill-record: machine=ci-arch verdict=fail commit=$(drill_head) claude=2.1.321"
  assert_contains "$output" "== it ended with: tools: the Claude Code install failed (exit 1)"
  # So does one whose summary names failures besides Daniel's steps.
  bootstrap_ends "check: summary: not set up yet: besides Daniel's steps above, these failed: servers; fix them as their doctor lines say, then team-bootstrap again"
  drill ci-arch
  assert_equal "$status" 1
  assert_equal "$(tail -n 1 <<<"$output")" "drill-record: machine=ci-arch verdict=fail commit=$(drill_head) claude=2.1.321"
  bootstrap_ends "check: summary: not set up yet: only Daniel's steps above are left; then team-bootstrap again"
  drill ci-arch
  assert_equal "$status" 0
}

@test "Claude Code is looked for on PATH, then in ~/.local/bin, where the bootstrap installs it, and is none when neither has it or it does not answer" {
  local path
  path=$(no_claude_path)
  bootstrap_ends "check: summary: set up, and this machine holds the lease"
  PATH=$path drill ci-arch
  assert_equal "$status" 0
  assert_equal "$(tail -n 1 <<<"$output")" "drill-record: machine=ci-arch verdict=pass commit=$(drill_head) claude=none"
  mkdir -p "$HOME/.local/bin"
  ln "$(shared stub "$REPO_ROOT/tests/helpers/stub")" "$HOME/.local/bin/claude"
  PATH=$path drill ci-arch
  assert_equal "$(tail -n 1 <<<"$output")" "drill-record: machine=ci-arch verdict=pass commit=$(drill_head) claude=2.1.321"
  stub_reply claude '' 1
  PATH=$path drill ci-arch
  assert_equal "$(tail -n 1 <<<"$output")" "drill-record: machine=ci-arch verdict=pass commit=$(drill_head) claude=none"
}

@test "a checkout whose HEAD cannot be read records the commit as unknown" {
  rm -rf "$DRILL_ROOT/.git"
  bootstrap_ends "check: summary: set up, and this machine holds the lease"
  # git looks no further up than the drill's checkout, so the suite's own repository is not read.
  GIT_CEILING_DIRECTORIES=$BATS_TEST_TMPDIR drill ci-arch
  assert_equal "$status" 0
  assert_equal "$(tail -n 1 <<<"$output")" "drill-record: machine=ci-arch verdict=pass commit=unknown claude=2.1.321"
}

@test "a malformed command line ends with a failed record too, before any bootstrap" {
  drill
  assert_equal "$status" 2
  assert_equal "$output" "usage: tests/bootstrap-drill <machine name>
drill-record: machine= verdict=fail commit=$(drill_head) claude=2.1.321"
  assert_equal "$(stub_calls team-bootstrap)" ""
}
