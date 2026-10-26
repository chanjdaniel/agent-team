#!/usr/bin/env bats
# team-time: where task time went, from the ledger, per task and per phase, with the counts.

load helpers/common

# fixtures/ledger-time.jsonl holds, with known hours:
# T60, a Conventioner feature closed in 13 h: planning 1, building 4, gate 2.5 (two runs' minutes
# taken from building, and a pause on a gate run), review 1.5, merging 0.5, unattributed 1.5,
# Daniel 1.5, the machine's load 0.5; three gate runs on one PR, two reviews.
# T61, an agent-team task still open from 10:00: building 4.75, a denial 0.25, another task 2,
# GitHub 1, the machine handed over 2, Daniel 0.2, by 20:12.
# T62, a Conventioner bug of 3 h of building from 22:00 the day before; T63, opened at 21:00; T9,
# a legacy task with no opened event.
setup() {
  sandbox
  cp "$BATS_TEST_DIRNAME/fixtures/ledger-time.jsonl" "$TEAM_HOME/ledger.jsonl"
  until=2026-10-22T20:12:00Z
}

# The JSON report for the window the arguments give.
time_json() {
  run_bin -0 team-time --json "$@"
  printf '%s\n' "$output"
}

@test "--help prints the header" {
  run_bin -0 team-time --help
  assert_equal "${lines[0]}" "$(sed -n '2s/^# //p' "$REPO_ROOT/bin/team-time")"
  assert_contains "$output" "Usage: team-time [--since <ISO>] [--until <ISO>] [--task T<n>] [--json]"
}

@test "each task's hours are split by phase, legacy tasks and tasks opened after the window left out" {
  local json
  json=$(time_json --until "$until")
  assert_equal "$(jq -c '[.schema, .since, .until]' <<<"$json")" '["team-time/1",null,"2026-10-22T20:12:00Z"]'
  assert_equal "$(jq -r '.tasks[] | [.task, .project, .path, .closed, .wall] | @tsv' <<<"$json")" "$(
    printf '%s\n' $'T60\tconventioner\tfeature\ttrue\t13' $'T61\tagent-team\tsmall\tfalse\t10.2' $'T62\tconventioner\tbug\ttrue\t3'
  )"
  assert_equal "$(jq -c '.tasks[0].hours | with_entries(select(.value != 0))' <<<"$json")" \
    '{"planning":1,"building":4,"gate":2.5,"review":1.5,"merging":0.5,"unattributed":1.5,"wait:daniel":1.5,"wait:machine":0.5}'
  assert_equal "$(jq -c '.tasks[1].hours | with_entries(select(.value != 0))' <<<"$json")" \
    '{"building":4.75,"wait:daniel":0.2,"wait:task":2,"wait:external":1,"wait:off":2,"wait:denial":0.25}'
  assert_equal "$(jq -c '.tasks[2].hours | with_entries(select(.value != 0))' <<<"$json")" '{"building":3}'
  assert_equal "$(jq -c '.tasks[0].hours | keys_unsorted' <<<"$json")" \
    '["planning","building","gate","review","merging","unattributed","wait:daniel","wait:task","wait:external","wait:machine","wait:limit","wait:off","wait:denial","wait:other"]'
}

@test "the phases are totalled for all tasks and per project, with each phase's share" {
  local json
  json=$(time_json --until "$until")
  assert_equal "$(jq -c '.phases.all | with_entries(select(.value != 0))' <<<"$json")" \
    '{"planning":1,"building":11.75,"gate":2.5,"review":1.5,"merging":0.5,"unattributed":1.5,"wait:daniel":1.7,"wait:task":2,"wait:external":1,"wait:machine":0.5,"wait:off":2,"wait:denial":0.25}'
  assert_equal "$(jq -c '[.phases.projects | to_entries[] | {(.key): .value.building}] | add' <<<"$json")" \
    '{"agent-team":4.75,"conventioner":7}'
  assert_equal "$(jq -c '[.wall, .phases.share.building, .phases.share.gate]' <<<"$json")" '[26.2,44.8,9.5]'
}

@test "the text form prints the per-task and per-phase tables" {
  run_bin -0 team-time --until "$until"
  assert_equal "${lines[0]}" "Task time to 2026-10-22T20:12:00Z: 3 tasks, 26.2 hours"
  grep -Eq '^task +project +path +closed +wall +plan +build +gate +review +merge +unattr +daniel +on-task +outside +load +limit +off +denial +other$' <<<"$output"
  grep -Eq '^T60 +conventioner +feature +y +13\.0 +1\.0 +4\.0 +2\.5 +1\.5 +0\.5 +1\.5 +1\.5 +0\.0 +0\.0 +0\.5 +0\.0 +0\.0 +0\.0 +0\.0$' <<<"$output"
  grep -Eq '^T61 +agent-team +small +open +10\.2 +0\.0 +4\.8 ' <<<"$output"
  grep -Eq '^phase +hours +share +agent-team +conventioner$' <<<"$output"
  grep -Eq '^building +11\.8 +45% +4\.8 +7\.0$' <<<"$output"
  grep -Eq '^waiting on another task +2\.0 +8% +2\.0 +0\.0$' <<<"$output"
  grep -Eq '^all +26\.2 +100% +10\.2 +16\.0$' <<<"$output"
}

@test "gate runs are counted per PR, by cause and by outcome, with each step's median minutes" {
  local json
  json=$(time_json --until "$until")
  assert_equal "$(jq -c '.gate_runs.per_pr' <<<"$json")" \
    '[{"task":"T60","pr":"https://github.com/chanjdaniel/Conventioner/pull/7","runs":3,"causes":{"none":1,"load":1,"review":1}}]'
  assert_equal "$(jq -c '.gate_runs.by_cause' <<<"$json")" '{"none":1,"load":1,"review":1}'
  assert_equal "$(jq -c '.gate_runs.by_outcome' <<<"$json")" '{"red":1,"pushed":1,"stopped-green":1}'
  assert_equal "$(jq -c '.gate_runs.step_minutes' <<<"$json")" '{"review":5,"test":25,"document":1,"push":1,"ci":28}'

  run_bin -0 team-time --until "$until"
  grep -Eq '^T60 +https://github.com/chanjdaniel/Conventioner/pull/7 +3 +none 1, load 1, review 1$' <<<"$output"
  assert_contains "$output" "Gate runs by cause: none 1, load 1, review 1"
  assert_contains "$output" "Gate runs by outcome: red 1, pushed 1, stopped-green 1"
  assert_contains "$output" "Gate minutes per step (median): review 5, test 25, document 1, push 1, ci 28"
}

@test "reviews and findings per PR, builders per ticket and denials are counted" {
  local json
  json=$(time_json --until "$until")
  assert_equal "$(jq -c '.reviews' <<<"$json")" \
    '[{"task":"T60","pr":"https://github.com/chanjdaniel/Conventioner/pull/7","reviews":2,"findings":1}]'
  assert_equal "$(jq -c '.builders' <<<"$json")" \
    '[{"task":"T60","builders":3,"tickets":1},{"task":"T61","builders":2,"tickets":0},{"task":"T62","builders":1,"tickets":0}]'
  assert_equal "$(jq -c '.denials' <<<"$json")" '1'

  run_bin -0 team-time --until "$until"
  grep -Eq '^T60 +https://github.com/chanjdaniel/Conventioner/pull/7 +2 +1$' <<<"$output"
  grep -Eq '^T60 +3 +1$' <<<"$output"
  assert_contains "$output" "Denials: 1"
}

@test "Daniel's answers are matched to the asks by id, with the median and 90th percentile latency" {
  local json
  json=$(time_json --until "$until")
  assert_equal "$(jq -c '.answers' <<<"$json")" '{"answered":3,"unanswered":1,"median_minutes":12,"p90_minutes":30}'
  run_bin -0 team-time --until "$until"
  assert_contains "$output" "Daniel's answers: 3 (1 unanswered), median 12.0 min, 90th percentile 30.0 min"
}

@test "each DONE is timed to its task's next event" {
  local json
  json=$(time_json --until "$until")
  assert_equal "$(jq -c '.done_to_next' <<<"$json")" '{"count":7,"median_seconds":0,"p90_seconds":1200,"within_minute":6}'
  run_bin -0 team-time --until "$until"
  assert_contains "$output" "DONE to the task's next event: 7, median 0 s, 90th percentile 1200 s, 6 within a minute"
}

@test "--since clips each task's time to the window and counts only the events in it" {
  local json
  json=$(time_json --since 2026-10-22T00:00:00Z --until "$until")
  assert_equal "$(jq -c '[.since, .wall]' <<<"$json")" '["2026-10-22T00:00:00Z",24.2]'
  assert_equal "$(jq -c '.tasks[] | select(.task == "T62") | [.wall, .hours.building]' <<<"$json")" '[1,1]'
  assert_equal "$(jq -c '.answers' <<<"$json")" '{"answered":2,"unanswered":1,"median_minutes":12,"p90_minutes":30}'
  assert_equal "$(jq -c '.builders | map(select(.task == "T62"))' <<<"$json")" '[{"task":"T62","builders":0,"tickets":0}]'
  run_bin -0 team-time --since 2026-10-22T00:00:00Z --until "$until"
  assert_equal "${lines[0]}" "Task time from 2026-10-22T00:00:00Z to 2026-10-22T20:12:00Z: 3 tasks, 24.2 hours"
}

@test "a park ends at the next launch, resumed, merge-approved, or for a wait on Daniel answered" {
  : >"$TEAM_HOME/ledger.jsonl"
  local d=2026-10-23T
  {
    echo '{"ts":"'$d'00:00:00Z","task":"T70","event":"opened","project":"p","path":"small","type":"fix","title":"x","branch":"fix/T70-x","base":"dev","base_sha":"0123456","worktree":"/w"}'
    echo '{"ts":"'$d'00:00:00Z","task":"T70","event":"launch","role":"builder","session":"s1","worktree":"/w","toolkits":[]}'
    # An answer does not end a wait on another task; the next launch does.
    echo '{"ts":"'$d'01:00:00Z","task":"T70","event":"blocked","reason":"waits for T69: its new key"}'
    echo '{"ts":"'$d'01:30:00Z","task":"T70","event":"answered","id":"q","answer":"y"}'
    echo '{"ts":"'$d'02:00:00Z","task":"T70","event":"launch","role":"builder","session":"s2","worktree":"/w","toolkits":[]}'
    # An answer ends a wait on Daniel.
    echo '{"ts":"'$d'03:00:00Z","task":"T70","event":"waiting","on":"Daniel","reason":"question q2"}'
    echo '{"ts":"'$d'03:30:00Z","task":"T70","event":"answered","id":"q2","answer":"y"}'
    # resumed ends a wait on the machine.
    echo '{"ts":"'$d'04:00:00Z","task":"T70","event":"paused","reason":"Docker daemon restart"}'
    echo '{"ts":"'$d'05:00:00Z","task":"T70","event":"resumed"}'
    echo '{"ts":"'$d'05:00:00Z","task":"T70","event":"done","role":"builder","session":"s2"}'
    # merge-approved ends a wait on Daniel and starts merging; an unknown park reason is another wait.
    echo '{"ts":"'$d'06:00:00Z","task":"T70","event":"waiting","on":"Daniel","reason":"merge-it"}'
    echo '{"ts":"'$d'07:00:00Z","task":"T70","event":"merge-approved","url":"u","discord_message":"1"}'
    echo '{"ts":"'$d'07:30:00Z","task":"T70","event":"merged","pr":1,"merge":"m","head":"h","by":"team-merge"}'
    echo '{"ts":"'$d'08:00:00Z","task":"T70","event":"held","reason":"something odd"}'
  } >>"$TEAM_HOME/ledger.jsonl"
  local json
  json=$(time_json --until 2026-10-23T09:00:00Z)
  assert_equal "$(jq -c '.tasks[0].hours | with_entries(select(.value != 0))' <<<"$json")" \
    '{"building":2.5,"merging":0.5,"unattributed":1.5,"wait:daniel":1.5,"wait:task":1,"wait:machine":1,"wait:other":1}'
}

@test "a park logged after the fact with since is counted from since, and the usage limit is its own phase" {
  : >"$TEAM_HOME/ledger.jsonl"
  local d1=2026-10-25T d2=2026-10-26T task
  for task in T71 T72; do
    echo '{"ts":"'$d1'10:00:00Z","task":"'$task'","event":"opened","project":"p","path":"small","type":"fix","title":"x","branch":"fix/'$task'-x","base":"dev","base_sha":"0123456","worktree":"/w"}'
    echo '{"ts":"'$d1'10:00:00Z","task":"'$task'","event":"launch","role":"builder","session":"s1","worktree":"/w","toolkits":[]}'
  done >>"$TEAM_HOME/ledger.jsonl"
  {
    echo '{"ts":"'$d2'10:00:00Z","task":"T71","event":"blocked","reason":"usage limit: the weekly limit ended its session","since":"'$d1'11:00:00Z"}'
    echo '{"ts":"'$d2'10:00:00Z","task":"T72","event":"blocked","reason":"usage limit: the weekly limit ended its session"}'
    echo '{"ts":"'$d2'10:01:12Z","task":"T71","event":"launch","role":"builder","session":"s2","worktree":"/w","toolkits":[]}'
    echo '{"ts":"'$d2'10:01:12Z","task":"T72","event":"launch","role":"builder","session":"s2","worktree":"/w","toolkits":[]}'
  } >>"$TEAM_HOME/ledger.jsonl"
  local json
  json=$(time_json --until 2026-10-26T10:01:12Z)
  assert_equal "$(jq -c '.tasks[0].hours | with_entries(select(.value != 0))' <<<"$json")" '{"building":1,"wait:limit":23.02}'
  assert_equal "$(jq -c '.tasks[1].hours | with_entries(select(.value != 0))' <<<"$json")" '{"building":24,"wait:limit":0.02}'
  assert_equal "$(jq -c '.tasks[0].hours | keys_unsorted | .[10:12]' <<<"$json")" '["wait:limit","wait:off"]'
  # A window from since on sees the stop alone.
  json=$(time_json --since 2026-10-25T12:00:00Z --until 2026-10-26T10:00:00Z --task T71)
  assert_equal "$(jq -c '.tasks[0].hours | with_entries(select(.value != 0))' <<<"$json")" '{"wait:limit":22}'
  run_bin -0 team-time --until 2026-10-26T10:01:12Z
  grep -Eq '^task +project +path +closed +wall +.* +load +limit +off +denial +other$' <<<"$output"
  grep -Eq '^the usage limit +23\.0 +' <<<"$output"
}

@test "the usage limit, the token limit and a session limit are classed as the limit before the machine off" {
  : >"$TEAM_HOME/ledger.jsonl"
  local d=2026-10-23T
  {
    echo '{"ts":"'$d'00:00:00Z","task":"T73","event":"opened","project":"p","path":"small","type":"fix","title":"x","branch":"fix/T73-x","base":"dev","base_sha":"0123456","worktree":"/w"}'
    echo '{"ts":"'$d'01:00:00Z","task":"T73","event":"paused","reason":"Token limit hit, then the handoff"}'
    echo '{"ts":"'$d'02:00:00Z","task":"T73","event":"resumed"}'
    echo '{"ts":"'$d'02:00:00Z","task":"T73","event":"held","reason":"session limit"}'
    echo '{"ts":"'$d'03:00:00Z","task":"T73","event":"resumed"}'
    echo '{"ts":"'$d'03:00:00Z","task":"T73","event":"waiting","on":"Daniel","reason":"the weekly limit resets on Monday"}'
  } >>"$TEAM_HOME/ledger.jsonl"
  local json
  json=$(time_json --until 2026-10-23T04:00:00Z)
  assert_equal "$(jq -c '.tasks[0].hours | with_entries(select(.value != 0))' <<<"$json")" '{"unattributed":1,"wait:limit":3}'
}

@test "an open task is measured to now when no --until is given" {
  local before after json
  before=$(date -u +%s)
  json=$(time_json --task T61)
  after=$(date -u +%s)
  local opened
  opened=$(date -u -d 2026-10-22T10:00:00Z +%s)
  jq -e --argjson lo "$(((before - opened) / 36))" --argjson hi "$(((after - opened) / 36 + 1))" \
    '.tasks | length == 1 and (.[0].wall * 100 | floor) >= $lo and (.[0].wall * 100 | floor) <= $hi' <<<"$json"
  jq -e '(.until | fromdate) >= ($before | tonumber)' --arg before "$before" <<<"$json"
}

@test "--task reports one task, and its counts alone" {
  local json
  json=$(time_json --task T61 --until "$until")
  assert_equal "$(jq -c '[.tasks[].task, .wall, .denials, .answers.answered, .gate_runs.per_pr]' <<<"$json")" '["T61",10.2,1,1,[]]'
}

@test "a malformed command line is a usage error, and a missing ledger reports nothing" {
  run_bin -2 team-time --since yesterday
  assert_contains "$output" "--since must be a UTC time like 2026-10-22T01:00:00Z"
  run_bin -2 team-time --task 61
  assert_contains "$output" "task must look like T<n>, got '61'"
  run_bin -2 team-time --until
  run_bin -2 team-time extra
  run_bin -2 team-time --since 2026-10-23T00:00:00Z --until 2026-10-22T00:00:00Z
  assert_contains "$output" "--since must come before --until"
  rm "$TEAM_HOME/ledger.jsonl"
  run_bin -1 team-time
  assert_contains "$output" "no ledger at $TEAM_HOME/ledger.jsonl"
}
