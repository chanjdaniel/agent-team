#!/usr/bin/env bats
# team-capacity status: its last line is the newest quota reading's, team-quota status's, and its
# JSON carries that object, with or without --stored; a team-quota that fails leaves the rest
# whole, the line saying it could not be read.

load helpers/common

setup() {
  sandbox
  mkdir -p "$HOME/.config/agent-team"
  echo home-pc >"$HOME/.config/agent-team/machine"
  # The reading's resets are shown in the machine's local time: UTC here.
  export TZ=UTC
}

# ago <minutes>: the UTC time that many minutes before now.
ago() {
  date -u -d "@$(($(date +%s) - $1 * 60))" +%FT%TZ
}

# A reading on laptop, read <minutes> ago, of the windows <json> ({<name>: {used, resets_at}}):
# reading <minutes> <json>
reading() {
  local at
  at=$(ago "$1")
  mkdir -p "$TEAM_HOME/usage/laptop/quota"
  jq -cn --arg at "$at" --argjson w "$2" '{at: $at, machine: "laptop", windows: $w, models: []}' \
    >>"$TEAM_HOME/usage/laptop/quota/${at%%T*}.jsonl"
}

WEEK='{"seven_day": {"used": 72.4, "resets_at": "2036-11-17T09:00:00Z"}, "five_hour": {"used": 23.9, "resets_at": "2036-11-10T14:00:00Z"}}'

# Make team-quota, in a code checkout of the test's own, the shared script <name> of <text>:
# fake_quota <name> <text>
fake_quota() {
  CODE_CHECKOUT=$BATS_TEST_TMPDIR/code
  [[ -d $CODE_CHECKOUT/bin ]] || { mkdir -p "$CODE_CHECKOUT"; copy_bin "$CODE_CHECKOUT/bin"; ln -s "$REPO_ROOT/roles" "$CODE_CHECKOUT/roles"; }
  ln -f "$(shared "$1" <<<"$2")" "$CODE_CHECKOUT/bin/team-quota"
}

@test "status ends with the quota line: the week's use and reset, the 5-hour window's use and the reading's age" {
  reading 12 "$WEEK"
  run_bin -0 --separate-stderr team-capacity status --stored
  assert_equal "$stderr" ""
  assert_equal "$output" "$(printf '%s\n' "home-pc: no reading of the machine's load yet" \
    "quota: week 72% (resets Mon 09:00), 5h 23%, read 12 min ago")"
}

@test "status takes a reading of the load first and still ends with the quota line" {
  cp "$BATS_TEST_DIRNAME/fixtures/projects.toml" "$TEAM_HOME/projects.toml"
  reading 12 "$WEEK"
  run_bin -0 --separate-stderr team-capacity status
  assert_equal "$stderr" ""
  assert_contains "${lines[0]}" "home-pc at "
  assert_equal "${lines[-1]}" "quota: week 72% (resets Mon 09:00), 5h 23%, read 12 min ago"
}

@test "a window left out of the reading is left out of the line, and a week that reset since says so" {
  reading 30 '{"seven_day": {"used": 95, "resets_at": "2020-01-06T09:00:00Z"}}'
  run_bin -0 team-capacity status --stored
  assert_equal "${lines[-1]}" "quota: week 95% (reset at Mon 09:00, since this reading), read 30 min ago"
}

@test "with no reading anywhere the line says so" {
  run_bin -0 team-capacity status --stored
  assert_equal "${lines[-1]}" "quota: no reading"
  run_bin -0 team-capacity status --stored --json
  assert_equal "$(jq -c '[.quota.schema, .quota.reading, .quota_error]' <<<"$output")" '["team-quota/1",null,null]'
}

@test "--json has quota, team-quota status --json's object, with and without --stored" {
  reading 12 "$WEEK"
  run_bin -0 team-quota status --json
  local want
  want=$(jq -c 'del(.age_minutes)' <<<"$output")
  run_bin -0 team-capacity status --stored --json
  assert_equal "$(jq -c '.quota | del(.age_minutes)' <<<"$output")" "$want"
  assert_equal "$(jq -c '[.schema, .quota_error, .quota.reading.machine]' <<<"$output")" '["team-capacity/1",null,"laptop"]'
  cp "$BATS_TEST_DIRNAME/fixtures/projects.toml" "$TEAM_HOME/projects.toml"
  run_bin -0 team-capacity status --json
  assert_equal "$(jq -c '.quota | del(.age_minutes)' <<<"$output")" "$want"
}

@test "a team-quota that fails leaves status whole, the line saying it could not be read" {
  reading 12 "$WEEK"
  fake_quota capacity-quota-fails $'#!/usr/bin/env bash\necho "team-quota: cannot read the readings" >&2\necho more >&2\nexit 1'
  run_bin -0 --separate-stderr team-capacity status --stored
  assert_equal "$stderr" ""
  assert_equal "$output" "$(printf '%s\n' "home-pc: no reading of the machine's load yet" \
    "quota: could not be read (cannot read the readings)")"
  run_bin -0 team-capacity status --stored --json
  assert_equal "$(jq -c '[.schema, .quota, .quota_error]' <<<"$output")" \
    '["team-capacity/1",null,"cannot read the readings"]'
  fake_quota capacity-quota-says-nothing $'#!/usr/bin/env bash\necho "{}"'
  run_bin -0 team-capacity status --stored
  assert_equal "${lines[-1]}" "quota: could not be read (team-quota status printed no team-quota/1 object)"
  fake_quota capacity-quota-fails-silently $'#!/usr/bin/env bash\nexit 3'
  run_bin -0 team-capacity status --stored
  assert_equal "${lines[-1]}" "quota: could not be read (team-quota status exited 3 with no message)"
}
