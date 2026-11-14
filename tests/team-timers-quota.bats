#!/usr/bin/env bats
# team-timers' quota step: on the holder after the uptime step, team-quota status --json, each
# window past a threshold a notice of the quota source (bin/lib/notice.jq), posted once to
# #coordinator and closed with no post once its window resets. The heartbeat suite's setup:
# home-pc holds the lease on a bare origin, the stub claude lists the coordinator, the service
# managers are fakes, and Discord is the inbox helper's fake, which keeps each alert's body. A
# reading is this machine's quota state file, as team-quota line writes it; its resets are in 2036,
# so it never rots, and a reset window is one whose resets_at has passed.

load helpers/common
load helpers/inbox

setup() {
  sandbox
  cp "$BATS_TEST_DIRNAME/fixtures/projects.toml" "$TEAM_HOME/projects.toml"
  stub_reply claude '[{"id": "c0ffee00", "name": "coordinator", "status": "idle"}]'
  hold_lease home-pc >/dev/null
  fake_service_managers
  stub_command uname
  stub_reply uname Linux
  state=$HOME/.local/state/agent-team
  log=$state/heartbeat.log
  inbox_discord alerts
  inbox_guild_kept
  # The posts' times are this machine's local time: a zone off UTC by a half hour shows it.
  export TZ=Asia/Kolkata
}

WEEK_RESETS=2036-11-17T09:00:00Z
HOUR_RESETS=2036-11-14T18:00:00Z

# Write this machine's reading: reading <week used> [<5-hour used> [<Fable's used>]], read now,
# the week resetting at $WEEK_RESETS (or $week_resets when set) and the 5-hour window at
# $HOUR_RESETS.
reading() {
  mkdir -p "$state"
  jq -cn --arg at "$(date -u +%FT%TZ)" --argjson week "$1" --argjson hour "${2:-10}" --arg fable "${3:-}" \
    --arg week_resets "${week_resets:-$WEEK_RESETS}" --arg hour_resets "$HOUR_RESETS" \
    '{at: $at, machine: "home-pc",
      windows: {five_hour: {used: $hour, resets_at: $hour_resets}, seven_day: {used: $week, resets_at: $week_resets}},
      models: (if $fable == "" then [] else [{name: "Fable", used: ($fable | tonumber), resets_at: $week_resets}] end)}' \
    >"$state/quota.json"
}

# The texts of the alerts the fake Discord was sent, one per line, in order.
alerts_posted() {
  local id
  [[ -f $STUB_FIXTURES/inbox/alerts ]] || return 0
  while read -r id; do jq -r .content "$STUB_FIXTURES/inbox/$id.json"; done <"$STUB_FIXTURES/inbox/alerts"
}

# A reset time as the posts show it: this machine's local day and time.
local_clock() {
  LC_ALL=C date -d "$1" '+%a %H:%M'
}

# The quota notices the record holds, their keys sorted.
quota_keys() {
  jq -c '[.notices[] | select(.source == "quota") | .key] | sort' "$state/notices.json"
}

# Replace team-quota with the bash read from stdin, in a code checkout of the test's own.
fake_quota() {
  CODE_CHECKOUT=$BATS_TEST_TMPDIR/code
  if [[ ! -d $CODE_CHECKOUT/bin ]]; then
    mkdir -p "$CODE_CHECKOUT"
    copy_bin "$CODE_CHECKOUT/bin"
  fi
  rm "$CODE_CHECKOUT/bin/team-quota"
  { echo '#!/usr/bin/env bash'; cat; } >"$CODE_CHECKOUT/bin/team-quota"
  chmod +x "$CODE_CHECKOUT/bin/team-quota"
}

@test "notice.jq's table has the quota source: its open post retried, no end action, never reminded" {
  run -0 jq -cn -L "$REPO_ROOT/bin/lib" 'include "notice"; notice_sources.quota'
  assert_equal "$output" '{"retry_open":true,"end":null,"unposted_end":false,"retry_end":false}'
}

@test "with no reading the step posts nothing, logs nothing and passes" {
  run_bin -0 team-timers run
  assert_equal "$(alerts_posted)" ""
  run grep ' quota: ' "$log"
  assert_equal "$status" 1
}

@test "the week past 70% posts once with its local reset time; the same or a higher reading below 90% posts nothing more" {
  reading 72
  run_bin -0 team-timers run
  local text
  text="Claude usage: the week is at 72%, past 70%; it resets $(local_clock "$WEEK_RESETS")."
  assert_equal "$(alerts_posted)" "$text"
  assert_equal "$(quota_keys)" "[\"seven_day/70/$WEEK_RESETS\"]"
  grep -E "^[0-9T:-]+Z quota: seven_day/70/$WEEK_RESETS: posted to #coordinator \(message [0-9]+\)$" "$log"

  run_bin -0 team-timers run
  reading 85
  run_bin -0 team-timers run
  assert_equal "$(alerts_posted)" "$text"

  # A lease taken again is a new holding, which posts a crossing of the same window no more.
  run -0 "$REPO_ROOT/bin/team-lease" release
  run -0 "$REPO_ROOT/bin/team-lease" take
  run_bin -0 team-timers run
  assert_equal "$(alerts_posted)" "$text"
}

@test "crossing 90% posts once more, and the 5-hour window and Fable's week at 90% each post their own text" {
  reading 72
  run_bin -0 team-timers run
  reading 91 95 90
  run_bin -0 team-timers run
  local week hour
  week=$(local_clock "$WEEK_RESETS") hour=$(local_clock "$HOUR_RESETS")
  assert_equal "$(alerts_posted)" "Claude usage: the week is at 72%, past 70%; it resets $week.
Claude usage: the 5-hour window is at 95%, past 90%; it resets $hour.
Claude usage: the week is at 91%, past 90%; it resets $week.
Claude usage: Fable's week is at 90%, past 90%; it resets $week."
  # The week's 70% notice stays beside its 90% one until the week resets.
  assert_equal "$(quota_keys)" "[\"five_hour/90/$HOUR_RESETS\",\"model:Fable/90/$WEEK_RESETS\",\"seven_day/70/$WEEK_RESETS\",\"seven_day/90/$WEEK_RESETS\"]"

  run_bin -0 team-timers run
  assert_equal "$(alerts_posted | wc -l)" 4
}

@test "a first reading already past 90% posts the one crossing, not 70% as well" {
  reading 93
  run_bin -0 team-timers run
  assert_equal "$(alerts_posted)" "Claude usage: the week is at 93%, past 90%; it resets $(local_clock "$WEEK_RESETS")."
}

@test "a lower reading after a higher one in the same window posts nothing: a crossing posted stays until its window resets" {
  reading 91
  run_bin -0 team-timers run
  # A newer reading below 90%, as another machine whose clock runs behind can give.
  reading 89
  run_bin -0 team-timers run
  reading 91
  run_bin -0 team-timers run
  assert_equal "$(alerts_posted)" "Claude usage: the week is at 91%, past 90%; it resets $(local_clock "$WEEK_RESETS")."
  assert_equal "$(quota_keys)" "[\"seven_day/90/$WEEK_RESETS\"]"
  run grep ' quota: .*closed with no post' "$log"
  assert_equal "$status" 1
}

@test "a crossing whose post failed is dropped with no post once a higher one of its window is wanted" {
  reading 72
  echo "1 503" >"$STUB_FIXTURES/inbox/fail-post"
  run_bin -1 team-timers run
  rm "$STUB_FIXTURES/inbox/fail-post"
  reading 92
  run_bin -0 team-timers run
  assert_equal "$(alerts_posted)" "Claude usage: the week is at 92%, past 90%; it resets $(local_clock "$WEEK_RESETS")."
  assert_equal "$(quota_keys)" "[\"seven_day/90/$WEEK_RESETS\"]"
  grep -E "quota: seven_day/70/$WEEK_RESETS: closed with no post \(a higher threshold of its window was crossed before it was posted\)$" "$log"
}

@test "a reading whose window has reset closes the old notice with no post, and the new week posts afresh" {
  reading 75
  run_bin -0 team-timers run
  # Its reset comes: the record's notice now names a time that has passed, as the reading does.
  sed -i "s/$WEEK_RESETS/2026-01-05T09:00:00Z/g" "$state/notices.json"
  week_resets=2026-01-05T09:00:00Z reading 75
  run_bin -0 team-timers run
  assert_equal "$(alerts_posted | wc -l)" 1
  assert_equal "$(quota_keys)" "[]"
  grep -E "quota: seven_day/70/2026-01-05T09:00:00Z: closed with no post \(its window reset\)$" "$log"
  assert_equal "$(grep -c '^PATCH ' "$STUB_FIXTURES/inbox/calls" || true)" 0

  # The next week's crossing is a new key, so it posts again.
  week_resets=2036-11-24T09:00:00Z reading 71
  run_bin -0 team-timers run
  assert_equal "$(alerts_posted | wc -l)" 2
  assert_equal "$(alerts_posted | tail -n 1)" "Claude usage: the week is at 71%, past 70%; it resets $(local_clock 2036-11-24T09:00:00Z)."
}

@test "a post Discord refuses fails the step and is tried again at the next run" {
  reading 72
  echo "1 503" >"$STUB_FIXTURES/inbox/fail-post"
  run_bin -1 team-timers run
  grep -E "quota: seven_day/70/$WEEK_RESETS: the post to #coordinator failed \(.*\); it is tried again next run$" "$log"
  rm "$STUB_FIXTURES/inbox/fail-post"
  run_bin -0 team-timers run
  assert_equal "$(alerts_posted)" "Claude usage: the week is at 72%, past 70%; it resets $(local_clock "$WEEK_RESETS")."
}

@test "a failing team-quota is the step failing, and 12 runs in a row raise step-quota in the health view" {
  fake_quota <<'EOF'
echo "team-quota: the team home cannot be read" >&2
exit 1
EOF
  run_bin -1 team-timers run
  grep -E "^[0-9T:-]+Z quota: failed: the team home cannot be read$" "$log"
  run_bin -1 team-timers health --json
  jq -e '.problems | map(select(.key == "step-quota")) | length == 1 and (.[0].text | test("^quota failing since .* \\(1 run\\): the team home cannot be read$")) and (.[0].alerting | not)' <<<"$output"

  jq '.steps.quota.runs = 10' "$state/health.json" >"$state/health.json.new"
  mv "$state/health.json.new" "$state/health.json"
  run_bin -1 team-timers run
  run_bin -1 team-timers run
  run_bin -1 team-timers health --json
  jq -e 'first(.problems[] | select(.key == "step-quota")) | .alerting and .sweep == "health" and (.text | contains("(12 runs)"))' <<<"$output"
  assert_contains "$(alerts_posted)" "The heartbeat's quota step has failed 12 runs in a row on home-pc"
}

@test "a team-quota that hangs is stopped after the step's limit, and one that prints no status fails the step" {
  fake_quota <<'EOF'
exec sleep 30
EOF
  TEAM_TIMERS_QUOTA_SECONDS=1 TEAM_TIMERS_KILL_SECONDS=1 run_bin -1 team-timers run
  grep -E "quota: failed: team-quota status timed out after 1 s$" "$log"

  fake_quota <<'EOF'
echo "not json"
EOF
  run_bin -1 team-timers run
  grep -E "quota: failed: team-quota status printed no team-quota/1 object$" "$log"
}
