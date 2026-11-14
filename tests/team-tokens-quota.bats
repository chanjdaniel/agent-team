#!/usr/bin/env bats
# team-tokens: the last seven days end with the newest quota reading, team-quota status's, in its
# text and its JSON, and a team-quota that fails leaves the rest of the report whole; and the
# status-report skill sends the coordinator to both for usage.

load helpers/common

setup() {
  sandbox
  mkdir -p "$HOME/.config/agent-team"
  echo home-pc >"$HOME/.config/agent-team/machine"
  echo agent-team-records >"$HOME/.config/agent-team/home"
  # The reading's resets are shown in the machine's local time: UTC here.
  export TZ=UTC
}

# ago <minutes>: the UTC time that many minutes before now.
ago() {
  date -u -d "@$(($(date +%s) - $1 * 60))" +%FT%TZ
}

# A reading on laptop, read <minutes> ago: the week at 72.4% resetting Mon 2036-11-17 09:00, the
# 5-hour window at 23% resetting Mon 2036-11-10 14:00, and Fable's week at 91%: reading <minutes>
reading() {
  local at
  at=$(ago "$1")
  mkdir -p "$TEAM_HOME/usage/laptop/quota"
  jq -cn --arg at "$at" '{at: $at, machine: "laptop",
      windows: {seven_day: {used: 72.4, resets_at: "2036-11-17T09:00:00Z"}, five_hour: {used: 23, resets_at: "2036-11-10T14:00:00Z"}},
      models: [{name: "Fable", used: 91, resets_at: "2036-11-17T09:00:00Z"}]}' >>"$TEAM_HOME/usage/laptop/quota/${at%%T*}.jsonl"
}

# The section from "## The last seven days" to the next heading, from the report on stdin.
seven_days() {
  sed -n '/^## The last seven days$/,/^## Coordinator turns$/p' | sed '$d'
}

@test "the last seven days end with the newest reading's windows, their use and reset, and its age" {
  reading 12
  run_bin -0 --separate-stderr team-tokens
  assert_equal "$stderr" ""
  local section
  section=$(seven_days <<<"$output")
  assert_contains "$section" "a rolling seven days; the quota reading below is the week Claude counts."
  assert_contains "$section" "The newest quota reading (team-quota status), read on laptop 12 min ago:"
  assert_contains "$section" "| five_hour | 23% | resets Mon 14:00 |"
  assert_contains "$section" "| seven_day | 72% | resets Mon 09:00 |"
  assert_contains "$section" "| model:Fable | 91% | resets Mon 09:00 |"
  [[ $output != *"in no data"* ]]
}

@test "a stale reading says so, and a window that reset since it says that" {
  reading 600
  jq -c '.windows.five_hour.resets_at = "2020-01-06T14:00:00Z"' "$TEAM_HOME"/usage/laptop/quota/*.jsonl >"$BATS_TEST_TMPDIR/r"
  cat "$BATS_TEST_TMPDIR/r" >"$(echo "$TEAM_HOME"/usage/laptop/quota/*.jsonl)"
  run_bin -0 team-tokens
  assert_contains "$output" "The newest quota reading (team-quota status), read on laptop 600 min ago; it is stale:"
  assert_contains "$output" "| five_hour | 23% | reset at Mon 14:00, since this reading |"
}

@test "with no reading the last seven days say there is none yet" {
  run_bin -0 team-tokens
  assert_contains "$(seven_days <<<"$output")" \
    "No quota reading yet: no session has shown a status line since team-quota was set up."
  run_bin -0 team-tokens --json
  assert_equal "$(jq -c '[.quota.schema, .quota.reading, .quota_error]' <<<"$output")" '["team-quota/1",null,null]'
}

@test "--json has quota, team-quota status --json's object, whatever --until, --task and --machine say" {
  reading 12
  run_bin -0 team-quota status --json
  local want=$output
  run_bin -0 team-tokens --json
  assert_equal "$(jq -c '.quota | del(.age_minutes)' <<<"$output")" "$(jq -c 'del(.age_minutes)' <<<"$want")"
  assert_equal "$(jq -c '[.quota.reading.machine, .quota.fresh, .quota_error]' <<<"$output")" '["laptop",true,null]'
  run_bin -0 team-tokens --until 2026-10-21T16:00Z --task T1 --machine laptop --json
  assert_equal "$(jq -c '[.quota.reading.machine, (.quota.windows | map(.name))]' <<<"$output")" \
    '["laptop",["five_hour","seven_day","model:Fable"]]'
}

@test "a team-quota that fails leaves the report whole, the quota saying it could not be read" {
  reading 12
  CODE_CHECKOUT=$BATS_TEST_TMPDIR/code
  mkdir -p "$CODE_CHECKOUT"
  copy_bin "$CODE_CHECKOUT/bin"
  ln -f "$(shared quota-fails <<<$'#!/usr/bin/env bash\necho "team-quota: cannot read the readings" >&2\nexit 1')" "$CODE_CHECKOUT/bin/team-quota"
  run_bin -0 --separate-stderr team-tokens
  assert_equal "$stderr" ""
  assert_contains "$output" "## Coordinator turns"
  assert_contains "$(seven_days <<<"$output")" \
    "The quota reading could not be read: cannot read the readings."
  run_bin -0 team-tokens --json
  assert_equal "$(jq -c '[.quota, .quota_error, .seven_days.all.replies]' <<<"$output")" \
    '[null,"cannot read the readings",0]'
  # Output that is no team-quota/1 object is a failure too.
  ln -f "$(shared quota-says-nothing <<<$'#!/usr/bin/env bash\necho "{}"')" "$CODE_CHECKOUT/bin/team-quota"
  run_bin -0 team-tokens --json
  assert_equal "$(jq -c '[.quota, .quota_error]' <<<"$output")" '[null,"team-quota status printed no team-quota/1 object"]'
}

@test "the header says the last seven days end with the quota reading, and no longer that the reset is in no data" {
  run_bin -0 team-tokens --help
  assert_contains "$output" "team-quota status --json"
  [[ $output != *"in no data"* ]]
}

@test "the status-report skill names team-quota status beside team-tokens for usage" {
  grep -qE 'usage.*`team-quota status`.*`team-tokens`' "$REPO_ROOT/plugins/coordinator-skills/skills/status-report/SKILL.md"
}
