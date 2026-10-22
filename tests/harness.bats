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
