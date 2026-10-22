#!/usr/bin/env bats
# The library's ledger_append: every script's event is checked against the ledger contract,
# including that the script appending it is the kind's writer.

load helpers/common

setup() {
  sandbox
  mkdir -p "$BATS_TEST_TMPDIR/bin"
}

# Run a script named <name> that sources this checkout's library and appends <event>.
append_as() {
  local script=$BATS_TEST_TMPDIR/bin/$1
  cat >"$script" <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail
source "$REPO_ROOT/bin/lib/team.sh" "\$@"
ledger_append "\$1"
SCRIPT
  chmod +x "$script"
  guard_sandbox
  run "$script" "$2"
}

@test "an event that meets the contract is appended by its writer" {
  append_as team-thread '{"ts":"2026-10-22T02:00:00Z","task":"T7","event":"thread","discord_thread":"1563"}'
  assert_equal "$status" "0"
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" '{"ts":"2026-10-22T02:00:00Z","task":"T7","event":"thread","discord_thread":"1563"}'
}

@test "an event is refused, with nothing appended, when it breaks the contract" {
  append_as team-thread '{"ts":"2026-10-22T02:00:00Z","task":"T7","event":"thread"}'
  assert_equal "$status" "1"
  assert_contains "$output" "team-thread: refusing a ledger event: thread needs discord_thread"
  append_as team-thread '{"ts":"2026-10-22T02:00:00Z","task":"T7","event":"thread","discord_thread":1563}'
  assert_contains "$output" "discord_thread must be a string, got a number"
  append_as team-thread '{"task":"T7","event":"thread","discord_thread":"1563"}'
  assert_contains "$output" "missing ts"
  append_as team-thread '{"ts":"2026-10-22T02:00:00Z","task":"T7","event":"thred","discord_thread":"1563"}'
  assert_contains "$output" "unknown event kind 'thred'"
  append_as team-thread '["not", "an object"]'
  assert_contains "$output" "not a JSON object for the ledger"
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" ""
}

@test "legacy shapes are refused at append time, whatever their ts" {
  append_as team-close '{"ts":"2026-10-01T00:00:00Z","task":"T1","event":"closed"}'
  assert_equal "$status" "1"
  assert_contains "$output" "closed needs archive"
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" ""
}

@test "an event is refused when the appending script is not the kind's writer" {
  append_as team-log '{"ts":"2026-10-22T02:00:00Z","task":"T7","event":"thread","discord_thread":"1563"}'
  assert_equal "$status" "1"
  assert_contains "$output" "thread events are written by team-thread, not team-log"
  append_as team-thread '{"ts":"2026-10-22T02:00:00Z","task":"T7","event":"resumed"}'
  assert_contains "$output" "resumed events are written by team-log, not team-thread"
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" ""
}

@test "team-thread's event passes the strict check" {
  stub_reply curl '{"id":"1563000000000000001"}'
  run_bin -0 team-thread T7 conventioner "Sign-in limits"
  run_bin -0 team-log --check
}
