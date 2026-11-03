#!/usr/bin/env bats
# The test harness itself: the sandbox, its guard, the stubs and the git helper.

load helpers/common

setup() {
  sandbox
}

@test "the sandbox guard stops a test whose HOME or TEAM_HOME escapes its directory" {
  run -0 guard_sandbox
  HOME=/tmp/elsewhere run -1 guard_sandbox
  assert_contains "$output" "HOME=/tmp/elsewhere is outside"
  TEAM_HOME=$REPO_ROOT run -1 run_bin team-thread --help
  assert_contains "$output" "TEAM_HOME=$REPO_ROOT is outside"
}

@test "stubs log every call and answer from the test's fixtures" {
  run -127 gh pr view 4
  assert_contains "$output" "stub gh: no fixture for this call: pr view 4"
  stub_reply gh '{"state":"OPEN"}' 3
  run -3 gh pr view 4 --json state
  assert_equal "$output" '{"state":"OPEN"}'
  stub_script claude <<'FIXTURE'
[[ $1 == agents ]] && echo '[]'
FIXTURE
  run -0 claude agents --json
  assert_equal "$output" "[]"
  assert_equal "$(stub_calls gh)" $'["pr","view","4"]\n["pr","view","4","--json","state"]'
  assert_equal "$(stub_calls claude)" '["agents","--json"]'
  assert_equal "$(stub_calls curl)" ""
}

@test "the sandbox has an empty ledger and a fake Discord token" {
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" ""
  assert_equal "$(cat "$HOME/.claude/channels/discord/.env")" "DISCORD_BOT_TOKEN=$FAKE_DISCORD_TOKEN"
}

@test "make_repo builds a bare origin and a primary clone that tracks it" {
  run -0 make_repo shop dev
  assert_equal "$output" "$HOME/projects/shop"
  assert_equal "$(git -C "$output" rev-parse --abbrev-ref HEAD)" "dev"
  assert_equal "$(git -C "$output" rev-parse --abbrev-ref origin/HEAD)" "origin/dev"
  assert_equal "$(git -C "$output" rev-parse HEAD)" "$(git -C "$BATS_TEST_TMPDIR/origin/shop.git" rev-parse dev)"
  assert_equal "$(git -C "$output" log -1 --format='%an <%ae>')" "Team Test <team-test@example.invalid>"
}

@test "untraced returns its command's status, for a function and a command, with the trap lifted only inside" {
  local before status
  before=$(trap -p DEBUG)
  assert_contains "$before" bats_debug_trap
  probe() { PROBE_TRAP=$(trap -p DEBUG) && return 3; }
  status=0
  untraced probe || status=$?
  assert_equal "$status" 3
  assert_equal "$PROBE_TRAP" ""
  assert_equal "$(trap -p DEBUG)" "$before"
  status=0
  untraced bash -c 'exit 4' || status=$?
  assert_equal "$status" 4
  untraced true
  assert_equal "$(untraced printf '%s|' 'a b' c)" 'a b|c|'
  # Within untraced, untraced runs its command as it is, and the trap comes back only at the end.
  status=0
  untraced untraced probe || status=$?
  assert_equal "$status" 3
  assert_equal "$PROBE_TRAP" ""
  assert_equal "$(trap -p DEBUG)" "$before"
}

@test "a failure inside untraced fails the test at the line that called it, and a later failure at its own line" {
  local dir=$BATS_TEST_TMPDIR/fixture
  mkdir -p "$dir/tests"
  ln -s "$REPO_ROOT/bin" "$dir/bin"
  ln -s "$REPO_ROOT/tests/helpers" "$dir/tests/helpers"
  cat >"$dir/tests/fixture.bats" <<'FIXTURE'
load helpers/common
fails() { return 1; }
@test "inside" {
  true
  untraced fails
  true
}
@test "after" {
  untraced true
  untraced fails || true
  false
}
FIXTURE
  run -1 "$REPO_ROOT/tests/vendor/bats-core/bin/bats" "$dir/tests/fixture.bats"
  assert_equal "$(grep -E '^(not )?ok|line [0-9]+|failed' <<<"$output" | sed -E 's#[^ ]*/(tests/[^ ]*)#\1#; s#(common\.bash), line [0-9]+#\1#')" "$(cat <<'TAP'
not ok 1 inside
# (from function `untraced' in file tests/helpers/common.bash,
#  in test file tests/fixture.bats, line 5)
#   `untraced fails' failed
not ok 2 after
# (in test file tests/fixture.bats, line 11)
#   `false' failed
TAP
)"
}
