#!/usr/bin/env bats
# team-load-check: team-doctor runs first, and a FAIL there stops the load check before it
# touches its scratch repo or launches a worker. The worker launch itself is checked by hand
# (it needs a real claude); see the script's header.

load helpers/common

setup() {
  sandbox
  hold_lease home-pc >/dev/null
  export TEAM_LOAD_CHECK_DIR=$BATS_TEST_TMPDIR/load-check
}

@test "a FAIL from team-doctor stops the load check, launching nothing" {
  # An OS the team does not run on is a FAIL whatever this machine's tools are.
  cp "$REPO_ROOT/tests/helpers/stub" "$BATS_TEST_TMPDIR/stubs/uname"
  stub_reply uname Linux
  export TEAM_OS_RELEASE=$BATS_TEST_TMPDIR/os-release
  printf '%s\n' 'PRETTY_NAME="Ubuntu 24.04.3 LTS"' 'ID=ubuntu' >"$TEAM_OS_RELEASE"
  stub_reply claude '{"loggedIn": true, "authMethod": "claude.ai"}'
  stub_reply gh ''
  stub_reply curl ''

  run_bin -1 --separate-stderr team-load-check
  assert_equal "${lines[0]}" "FAIL os: Ubuntu 24.04.3 LTS is neither Arch Linux nor macOS, so no tool is checked; fix: run the team on Arch Linux or macOS"
  assert_equal "$stderr" "load check: team-doctor reports a FAIL above; fix it, then run the load check again"
  [[ ! -e $TEAM_LOAD_CHECK_DIR ]]
  # claude was asked only for its login.
  assert_equal "$(stub_calls claude)" '["auth","status","--json"]'
}
