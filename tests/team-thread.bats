#!/usr/bin/env bats
# team-thread: opening a task's Discord thread and recording it in the ledger.

load helpers/common

setup() {
  sandbox
}

@test "a wrong number of arguments is a usage error" {
  run_bin -2 team-thread T7 conventioner
  assert_contains "$output" "usage: team-thread <task> <project> <title>"
  assert_equal "$(stub_calls curl)" ""
}

@test "a task id that is not T<n> is a usage error" {
  run_bin -2 team-thread 7 conventioner "Sign-in limits"
  assert_contains "$output" "task must look like T<n>, got '7'"
  run_bin -2 team-thread T0 conventioner "Sign-in limits"
  assert_equal "$(stub_calls curl)" ""
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" ""
}

@test "an existing thread is printed without calling Discord" {
  cat >"$TEAM_HOME/ledger.jsonl" <<'LEDGER'
{"ts":"2026-10-01T10:00:00Z","task":"T7","event":"thread","discord_thread":"1111"}
{"ts":"2026-10-01T10:00:01Z","task":"T17","event":"thread","discord_thread":"9999"}
LEDGER
  run_bin -0 team-thread T7 conventioner "Sign-in limits"
  assert_equal "$output" "1111"
  assert_equal "$(stub_calls curl)" ""
  assert_equal "$(wc -l <"$TEAM_HOME/ledger.jsonl")" "2"
}

@test "a new thread is created under #coordinator and recorded once" {
  stub_reply curl '{"id":"1563000000000000001","name":"T7"}'
  run_bin -0 --separate-stderr team-thread T7 conventioner "Sign-in limits"
  assert_equal "$output" "1563000000000000001"

  assert_equal "$(stub_calls curl | wc -l)" "1"
  assert_contains "$(stub_calls curl)" '"https://discord.com/api/v10/channels/1562486564871995482/threads"'
  assert_equal "$(stub_calls curl | jq -r 'index("-d") as $i | .[$i + 1]')" \
    '{"name":"T7 · conventioner · Sign-in limits","type":11,"auto_archive_duration":4320}'

  assert_equal "$(wc -l <"$TEAM_HOME/ledger.jsonl")" "1"
  assert_equal "$(jq -c 'del(.ts)' "$TEAM_HOME/ledger.jsonl")" \
    '{"task":"T7","event":"thread","discord_thread":"1563000000000000001"}'
  jq -e '.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")' "$TEAM_HOME/ledger.jsonl"

  run_bin -0 team-thread T7 conventioner "Sign-in limits"
  assert_equal "$output" "1563000000000000001"
  assert_equal "$(stub_calls curl | wc -l)" "1"
  assert_equal "$(wc -l <"$TEAM_HOME/ledger.jsonl")" "1"
}

@test "the thread name is cut to 100 characters" {
  stub_reply curl '{"id":"42"}'
  run_bin -0 team-thread T7 conventioner "$(printf '%0150d' 0)"
  name=$(stub_calls curl | jq -r 'index("-d") as $i | .[$i + 1] | fromjson | .name')
  assert_equal "$name" "T7 · conventioner · $(printf '%080d' 0)"
}

@test "the token reaches curl on stdin, never its command line or the output" {
  stub_script curl <<'EOF'
cat >"$STUB_CALLS/curl.stdin"
echo '{"id":"42"}'
EOF
  run_bin -0 team-thread T7 conventioner "Sign-in limits"
  [[ $output != *"$FAKE_DISCORD_TOKEN"* ]]
  [[ $(stub_calls curl) != *"$FAKE_DISCORD_TOKEN"* ]]
  assert_equal "$(stub_calls curl | jq -r '.[1:3] | join(" ")')" "-H @-"
  assert_equal "$(cat "$STUB_CALLS/curl.stdin")" "Authorization: Bot $FAKE_DISCORD_TOKEN"
}

@test "a missing token is refused with nothing appended" {
  : >"$HOME/.claude/channels/discord/.env"
  run_bin -1 team-thread T7 conventioner "Sign-in limits"
  assert_contains "$output" "no DISCORD_BOT_TOKEN"
  rm "$HOME/.claude/channels/discord/.env"
  run_bin -1 team-thread T7 conventioner "Sign-in limits"
  assert_contains "$output" "no DISCORD_BOT_TOKEN"
  assert_equal "$(stub_calls curl)" ""
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" ""
}

@test "a reply without a numeric thread id is refused with nothing appended" {
  local reply
  for reply in '{"message":"Missing Access","code":50001}' '{"id":"abc"}' 'not json'; do
    stub_reply curl "$reply"
    run_bin -1 team-thread T7 conventioner "Sign-in limits"
    assert_contains "$output" "Discord did not return a thread id"
  done
  stub_reply curl '' 22
  run_bin -1 team-thread T7 conventioner "Sign-in limits"
  assert_contains "$output" "Discord did not return a thread id"
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" ""
}
