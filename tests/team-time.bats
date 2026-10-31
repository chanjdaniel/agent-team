#!/usr/bin/env bats
# team-time: where task time went, from the ledger, per task and per phase, with the counts.

load helpers/common

# fixtures/ledger-time.jsonl holds, with known hours:
# T60, a Conventioner feature closed in 13 h: planning 1, building 4, gate 2.5 (two runs' minutes
# taken from building, and a pause on a gate run), review 1.5, merging 0.5, unattributed 1.5,
# Daniel 1.5, the machine's load 0.5; three gate runs on one PR, two reviews.
# T61, an agent-team task still open from 10:00: building 3.55, a denial 0.25, another task 2,
# GitHub 1, the machine handed over 2, Daniel 1.4 (a question answered in 0.2, then an ask still
# open from 19:00), by 20:12.
# T62, a Conventioner bug of 3 h from 22:00 the day before, 2 minutes of it an ask answered; T63,
# opened at 21:00; T9, a legacy task with no opened event.
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
    '{"building":3.55,"wait:daniel":1.4,"wait:task":2,"wait:external":1,"wait:off":2,"wait:denial":0.25}'
  assert_equal "$(jq -c '.tasks[2].hours | with_entries(select(.value != 0))' <<<"$json")" '{"building":2.967,"wait:daniel":0.033}'
  assert_equal "$(jq -c '.tasks[0].hours | keys_unsorted' <<<"$json")" \
    '["planning","building","gate","review","merging","unattributed","wait:daniel","wait:task","wait:external","wait:machine","wait:limit","wait:off","wait:denial","wait:other"]'
}

@test "the phases are totalled for all tasks and per project, with each phase's share" {
  local json
  json=$(time_json --until "$until")
  assert_equal "$(jq -c '.phases.all | with_entries(select(.value != 0))' <<<"$json")" \
    '{"planning":1,"building":10.517,"gate":2.5,"review":1.5,"merging":0.5,"unattributed":1.5,"wait:daniel":2.933,"wait:task":2,"wait:external":1,"wait:machine":0.5,"wait:off":2,"wait:denial":0.25}'
  assert_equal "$(jq -c '[.phases.projects | to_entries[] | {(.key): .value.building}] | add' <<<"$json")" \
    '{"agent-team":3.55,"conventioner":6.967}'
  assert_equal "$(jq -c '[.wall, .phases.share.building, .phases.share.gate]' <<<"$json")" '[26.2,40.1,9.5]'
}

@test "the text form prints the per-task and per-phase tables" {
  run_bin -0 team-time --until "$until"
  assert_equal "${lines[0]}" "Task time to 2026-10-22T20:12:00Z: 3 tasks, 26.2 hours"
  grep -Eq '^task +project +path +closed +wall +plan +build +gate +review +merge +unattr +daniel +on-task +outside +load +limit +off +denial +other$' <<<"$output"
  grep -Eq '^T60 +conventioner +feature +y +13\.0 +1\.0 +4\.0 +2\.5 +1\.5 +0\.5 +1\.5 +1\.5 +0\.0 +0\.0 +0\.5 +0\.0 +0\.0 +0\.0 +0\.0$' <<<"$output"
  grep -Eq '^T61 +agent-team +small +open +10\.2 +0\.0 +3\.6 ' <<<"$output"
  grep -Eq '^phase +hours +share +agent-team +conventioner$' <<<"$output"
  grep -Eq '^building +10\.5 +40% +3\.6 +7\.0$' <<<"$output"
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

@test "a park ends at the next launch, resumed, or for a wait on Daniel merge-approved, never at an answered" {
  : >"$TEAM_HOME/ledger.jsonl"
  local d=2026-10-23T
  {
    echo '{"ts":"'$d'00:00:00Z","task":"T70","event":"opened","project":"p","path":"small","type":"fix","title":"x","branch":"fix/T70-x","base":"dev","base_sha":"0123456","worktree":"/w"}'
    echo '{"ts":"'$d'00:00:00Z","task":"T70","event":"launch","role":"builder","session":"s1","worktree":"/w","toolkits":[]}'
    # An answer does not end a wait on another task; the next launch does.
    echo '{"ts":"'$d'01:00:00Z","task":"T70","event":"blocked","reason":"waits for T69: its new key"}'
    echo '{"ts":"'$d'01:30:00Z","task":"T70","event":"answered","id":"q","answer":"y"}'
    echo '{"ts":"'$d'02:00:00Z","task":"T70","event":"launch","role":"builder","session":"s2","worktree":"/w","toolkits":[]}'
    # Nor a wait on Daniel: it stands until the next park.
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
    '{"building":2,"merging":0.5,"unattributed":1.5,"wait:daniel":2,"wait:task":1,"wait:machine":1,"wait:other":1}'
}

@test "a park's on decides before its reason, and a paused naming Daniel waits on Daniel" {
  : >"$TEAM_HOME/ledger.jsonl"
  local d=2026-10-23T
  {
    echo '{"ts":"'$d'00:00:00Z","task":"T80","event":"opened","project":"p","path":"small","type":"fix","title":"x","branch":"fix/T80-x","base":"dev","base_sha":"0123456","worktree":"/w"}'
    echo '{"ts":"'$d'00:00:00Z","task":"T80","event":"launch","role":"builder","session":"s1","worktree":"/w","toolkits":[]}'
    # A word of the machine's load in the reason loses to on=Daniel.
    echo '{"ts":"'$d'01:00:00Z","task":"T80","event":"waiting","on":"Daniel","reason":"ticket 16: the Docker cleanup and drills"}'
    echo '{"ts":"'$d'02:00:00Z","task":"T80","event":"launch","role":"builder","session":"s2","worktree":"/w","toolkits":[]}'
    # on is read in any case: github is an outside party, schedule another wait, coordinator its turn.
    echo '{"ts":"'$d'03:00:00Z","task":"T80","event":"waiting","on":"github","reason":"the Actions minutes"}'
    echo '{"ts":"'$d'04:00:00Z","task":"T80","event":"resumed"}'
    echo '{"ts":"'$d'05:00:00Z","task":"T80","event":"waiting","on":"schedule","reason":"the cutover at 06:00"}'
    echo '{"ts":"'$d'06:00:00Z","task":"T80","event":"resumed"}'
    echo '{"ts":"'$d'07:00:00Z","task":"T80","event":"waiting","on":"coordinator","reason":"its next brief"}'
    echo '{"ts":"'$d'08:00:00Z","task":"T80","event":"launch","role":"builder","session":"s3","worktree":"/w","toolkits":[]}'
    # A worker's paused has no on: a reason naming Daniel is a wait on Daniel.
    echo '{"ts":"'$d'09:00:00Z","task":"T80","event":"paused","reason":"waiting on Daniel'"'"'s phone-target answer"}'
    echo '{"ts":"'$d'10:00:00Z","task":"T80","event":"resumed"}'
    # The machine handed over still wins over on=Daniel.
    echo '{"ts":"'$d'11:00:00Z","task":"T80","event":"waiting","on":"Daniel","reason":"handoff to the laptop"}'
    echo '{"ts":"'$d'12:00:00Z","task":"T80","event":"launch","role":"builder","session":"s4","worktree":"/w","toolkits":[]}'
  } >>"$TEAM_HOME/ledger.jsonl"
  local json
  json=$(time_json --until 2026-10-23T13:00:00Z)
  assert_equal "$(jq -c '.tasks[0].hours | with_entries(select(.value != 0))' <<<"$json")" \
    '{"building":7,"unattributed":1,"wait:daniel":2,"wait:external":1,"wait:off":1,"wait:other":1}'
}

@test "an open ask is a wait on Daniel until every ask it noted is settled, by its answered or a merge-approved naming its URL" {
  : >"$TEAM_HOME/ledger.jsonl"
  local d=2026-10-23T url=https://github.com/chanjdaniel/agent-team/pull/30
  {
    echo '{"ts":"'$d'00:00:00Z","task":"T81","event":"opened","project":"p","path":"small","type":"fix","title":"x","branch":"fix/T81-x","base":"dev","base_sha":"0123456","worktree":"/w"}'
    echo '{"ts":"'$d'00:00:00Z","task":"T81","event":"launch","role":"builder","session":"s1","worktree":"/w","toolkits":[]}'
    echo '{"ts":"'$d'01:00:00Z","task":"T81","event":"done","role":"builder","session":"s1"}'
    echo '{"ts":"'$d'01:00:00Z","task":"T81","event":"launch","role":"reviewer","session":"s2","worktree":"/w","toolkits":[]}'
    echo '{"ts":"'$d'02:00:00Z","task":"T81","event":"done","role":"reviewer","session":"s2"}'
    # The merge ask has no answered: the merge-approved naming its URL settles it.
    echo '{"ts":"'$d'02:00:00Z","task":"T81","event":"asked","id":"merge","text":"merge it? '$url' at 0123456"}'
    echo '{"ts":"'$d'04:00:00Z","task":"T81","event":"merge-approved","url":"'$url'","discord_message":"1"}'
    echo '{"ts":"'$d'04:30:00Z","task":"T81","event":"merged","pr":30,"merge":"m","head":"h","by":"team-merge"}'
    echo '{"ts":"'$d'00:00:00Z","task":"T82","event":"opened","project":"p","path":"small","type":"fix","title":"x","branch":"fix/T82-x","base":"dev","base_sha":"0123456","worktree":"/w"}'
    echo '{"ts":"'$d'00:00:00Z","task":"T82","event":"launch","role":"builder","session":"s3","worktree":"/w","toolkits":[]}'
    # Two asks: the wait ends when both are answered.
    echo '{"ts":"'$d'01:00:00Z","task":"T82","event":"asked","id":"a","text":"which flag?"}'
    echo '{"ts":"'$d'01:30:00Z","task":"T82","event":"asked","id":"b","text":"which name?"}'
    echo '{"ts":"'$d'02:00:00Z","task":"T82","event":"answered","id":"a","answer":"--x"}'
    echo '{"ts":"'$d'03:00:00Z","task":"T82","event":"answered","id":"b","answer":"y"}'
    # An answered with another id leaves a waiting on Daniel standing until the next launch.
    echo '{"ts":"'$d'04:00:00Z","task":"T82","event":"waiting","on":"Daniel","reason":"item 7 needs Daniel at the PC"}'
    echo '{"ts":"'$d'05:00:00Z","task":"T82","event":"answered","id":"item-8","answer":"z"}'
    echo '{"ts":"'$d'06:00:00Z","task":"T82","event":"launch","role":"builder","session":"s4","worktree":"/w","toolkits":[]}'
  } >>"$TEAM_HOME/ledger.jsonl"
  local json
  json=$(time_json --until 2026-10-23T07:00:00Z)
  assert_equal "$(jq -c '.tasks[0].hours | with_entries(select(.value != 0))' <<<"$json")" \
    '{"building":1,"review":1,"merging":0.5,"unattributed":2.5,"wait:daniel":2}'
  assert_equal "$(jq -c '.tasks[1].hours | with_entries(select(.value != 0))' <<<"$json")" '{"building":3,"wait:daniel":4}'
  json=$(time_json --until 2026-10-23T07:00:00Z --task T81)
  assert_equal "$(jq -c '.answers' <<<"$json")" '{"answered":1,"unanswered":0,"median_minutes":120,"p90_minutes":120}'
}

# The ledger holds T90, opened at 00:00 with a builder's launch, then the lines given, each
# "<HH:MM> <event> [<jq object of more fields>]"; prints T90's hours to the last argument.
t90_hours() {
  local until=$1 d=2026-10-24T line at kind more
  shift
  {
    echo '{"ts":"'$d'00:00:00Z","task":"T90","event":"opened","project":"p","path":"small","type":"fix","title":"x","branch":"fix/T90-x","base":"dev","base_sha":"0123456","worktree":"/w"}'
    echo '{"ts":"'$d'00:00:00Z","task":"T90","event":"launch","role":"builder","session":"s1","worktree":"/w","toolkits":[]}'
    for line in "$@"; do
      read -r at kind more <<<"$line"
      jq -cn --arg ts "${d}$at:00Z" --arg e "$kind" "{ts: \$ts, task: \"T90\", event: \$e} + (${more:-{\}})"
    done
  } >"$TEAM_HOME/ledger.jsonl"
  time_json --until "${d}$until:00Z" | jq -c '.tasks[0].hours | with_entries(select(.value != 0))'
}

@test "a review's verdict ends the review phase: the hours after it are unattributed" {
  assert_equal "$(t90_hours 06:00 '01:00 done {role: "builder", session: "s1"}' \
    '01:00 launch {role: "reviewer", session: "s2", worktree: "/w", toolkits: []}' \
    '03:00 review {verdict: "pass", head: "aaaaaaa"}')" '{"building":1,"review":2,"unattributed":3}'
}

@test "a gate run after a review's verdict is gate time" {
  assert_equal "$(t90_hours 05:00 '01:00 done {role: "builder", session: "s1"}' \
    '01:00 launch {role: "reviewer", session: "s2", worktree: "/w", toolkits: []}' \
    '02:00 review {verdict: "findings", head: "aaaaaaa"}' \
    '03:00 gate-run {run: "R1", head: "bbbbbbb", outcome: "pushed", minutes: {review: 10, test: 20}}')" \
    '{"building":1,"gate":0.5,"review":1,"unattributed":2.5}'
}

@test "an ask still open when the worker's work ends is a wait on Daniel until its answer" {
  assert_equal "$(t90_hours 08:00 '00:30 asked {id: "setup", text: "the Discord values"}' \
    '01:00 launch {role: "builder", session: "s2", worktree: "/w", toolkits: []}' \
    '02:00 done {role: "builder", session: "s2"}' \
    '07:00 answered {id: "setup", answer: "set"}')" '{"building":1.5,"unattributed":1,"wait:daniel":5.5}'
}

@test "an ask answered before the work ends leaves the stretch after it unattributed" {
  assert_equal "$(t90_hours 08:00 '00:30 asked {id: "setup", text: "the Discord values"}' \
    '01:00 launch {role: "builder", session: "s2", worktree: "/w", toolkits: []}' \
    '01:30 answered {id: "setup", answer: "set"}' \
    '02:00 done {role: "builder", session: "s2"}')" '{"building":1.5,"unattributed":6,"wait:daniel":0.5}'
}

@test "a gate run inside a wait on Daniel is gate time" {
  assert_equal "$(t90_hours 04:00 '01:00 waiting {on: "Daniel", reason: "the merge word"}' \
    '02:00 gate-run {run: "R1", head: "bbbbbbb", outcome: "stopped-green", minutes: {review: 5, test: 15}}')" \
    '{"building":1,"gate":0.333,"wait:daniel":2.667}'
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

# fixtures/ledger-workers.jsonl holds these worker lifetimes, read to 2026-10-28T20:00 (all on
# 10-28 but where told), each from its launch:
# T98 (conventioner small): builder b0980001 10-27 20:00 to its done at 23:00 (180 min, before a
# window from 10-28 00:00); reviewer r0980001 10-27 23:00 to its done at 00:30 (90, review 90).
# T100 (agent-team feature): planner p1000001 01:00 to its done at 01:30 (30, planning 30);
# builder b1000001 02:00 to its third done at 07:00 (300, first done 60; building 60, review 60,
# gate 20 (a gate run's minutes from 04:10), unattributed 160); reviewer r1000001 03:00 to its
# review at 03:40, with no done (40), its done at 21:00 after the window; reviewer r1000002 05:00
# to its done at 05:20 (20); reviewer r1000003 on claude-sonnet-5-5, 07:00 to its done at 07:30
# (30).
# T101 (conventioner small): builder b1010001 on claude-sonnet-5-5, 10:00 replaced at 11:00
# (60); builder b1010002 11:00 to its done at 11:46 (46); builder b1010003 12:00 to the close at
# 13:00 (60).
# T99, legacy (no opened): builder b0990001 of agent-team, 12:00 to its done at 12:30 (30, path
# "-", phases null). T97, legacy: a launch with no session, no lifetime.
# T102 (agent-team bug): planner p1020001 14:00 to the stow at 15:00 (60); builder b1020001 from
# 16:00, running at 20:00 (240 so far, building), its done at 21:00 after the window.
# Minutes by role: builder 300, 60, 46, 60, 30; reviewer 90, 40, 20, 30; planner 30, 60.
workers_json() {
  cp "$BATS_TEST_DIRNAME/fixtures/ledger-workers.jsonl" "$TEAM_HOME/ledger.jsonl"
  time_json --until 2026-10-28T20:00:00Z "$@"
}

@test "each worker's lifetime runs from its launch to its last done, its review, its replacement, the stow or the close" {
  local json
  json=$(workers_json --since 2026-10-28T00:00:00Z)
  assert_equal "$(jq -r '.workers.lifetimes[] | [.task, .role, .session, .project, .path, .model, .start, .end, .ended, .minutes, .rounds, .first_done_minutes] | map(. // "null") | @tsv' <<<"$json")" "$(
    printf '%s\n' \
      $'T98\treviewer\tr0980001\tconventioner\tsmall\tdefault\t2026-10-27T23:00:00Z\t2026-10-28T00:30:00Z\tdone\t90\t1\t90' \
      $'T100\tplanner\tp1000001\tagent-team\tfeature\tdefault\t2026-10-28T01:00:00Z\t2026-10-28T01:30:00Z\tdone\t30\t1\t30' \
      $'T100\tbuilder\tb1000001\tagent-team\tfeature\tdefault\t2026-10-28T02:00:00Z\t2026-10-28T07:00:00Z\tdone\t300\t3\t60' \
      $'T100\treviewer\tr1000001\tagent-team\tfeature\tdefault\t2026-10-28T03:00:00Z\t2026-10-28T03:40:00Z\treview\t40\t0\tnull' \
      $'T100\treviewer\tr1000002\tagent-team\tfeature\tdefault\t2026-10-28T05:00:00Z\t2026-10-28T05:20:00Z\tdone\t20\t1\t20' \
      $'T100\treviewer\tr1000003\tagent-team\tfeature\tclaude-sonnet-5-5\t2026-10-28T07:00:00Z\t2026-10-28T07:30:00Z\tdone\t30\t1\t30' \
      $'T101\tbuilder\tb1010001\tconventioner\tsmall\tclaude-sonnet-5-5\t2026-10-28T10:00:00Z\t2026-10-28T11:00:00Z\treplaced\t60\t0\tnull' \
      $'T101\tbuilder\tb1010002\tconventioner\tsmall\tdefault\t2026-10-28T11:00:00Z\t2026-10-28T11:46:00Z\tdone\t46\t1\t46' \
      $'T101\tbuilder\tb1010003\tconventioner\tsmall\tdefault\t2026-10-28T12:00:00Z\t2026-10-28T13:00:00Z\tclosed\t60\t0\tnull' \
      $'T99\tbuilder\tb0990001\tagent-team\t-\tdefault\t2026-10-28T12:00:00Z\t2026-10-28T12:30:00Z\tdone\t30\t1\t30' \
      $'T102\tplanner\tp1020001\tagent-team\tbug\tdefault\t2026-10-28T14:00:00Z\t2026-10-28T15:00:00Z\tstowed\t60\t0\tnull'
  )"
  assert_equal "$(jq -c '[.workers.lifetimes[] | keys_unsorted] | unique' <<<"$json")" \
    '[["task","project","path","role","session","model","start","end","ended","minutes","rounds","first_done_minutes","phases","transcript"]]'
  # Without --since, the lifetime that ended before 10-28 is in the window too.
  json=$(workers_json)
  assert_equal "$(jq -c '[.workers.lifetimes[0] | .session, .minutes, .ended]' <<<"$json")" '["b0980001",180,"done"]'
}

@test "each lifetime's phases are its task's over its span, gate runs included, and null for a legacy task" {
  local json
  json=$(workers_json --since 2026-10-28T00:00:00Z)
  assert_equal "$(jq -c '[.workers.lifetimes[] | {(.session): .phases}] | add' <<<"$json")" "$(jq -c . <<<'{
    "r0980001": {"review": 90}, "p1000001": {"planning": 30},
    "b1000001": {"building": 60, "gate": 20, "review": 60, "unattributed": 160},
    "r1000001": {"review": 40}, "r1000002": {"review": 20}, "r1000003": {"review": 30},
    "b1010001": {"building": 60}, "b1010002": {"building": 46}, "b1010003": {"building": 60},
    "b0990001": null, "p1020001": {"planning": 60}}')"
  assert_equal "$(jq -c '.workers.lifetimes[] | select(.session == "b1000001") | [.minutes, ([.phases[]] | add)]' <<<"$json")" '[300,300]'
}

@test "the running workers are listed apart with their age at --until, and are in no average" {
  local json
  json=$(workers_json --since 2026-10-28T00:00:00Z)
  assert_equal "$(jq -c '.workers.running | map({task, role, session, start, end, ended, minutes, age_minutes, rounds, phases})' <<<"$json")" \
    '[{"task":"T102","role":"builder","session":"b1020001","start":"2026-10-28T16:00:00Z","end":null,"ended":"running","minutes":null,"age_minutes":240,"rounds":0,"phases":{"building":240}}]'
  assert_equal "$(jq -c '.workers.stats.by_role[] | select(.role == "builder") | .workers' <<<"$json")" '5'
}

@test "the averages are by role, role and path, role and project, and role and model, with the ten longest" {
  local json
  json=$(workers_json --since 2026-10-28T00:00:00Z)
  assert_equal "$(jq -r '.workers.stats.by_role[] | [.role, .workers, .mean, .median, .p90, .longest] | @tsv' <<<"$json")" "$(
    printf '%s\n' $'builder\t5\t99.2\t60\t300\t300' $'reviewer\t4\t45\t30\t90\t90' $'planner\t2\t45\t30\t60\t60'
  )"
  assert_equal "$(jq -r '.workers.stats.by_role_path[] | [.role, .path, .workers, .mean, .median, .p90, .longest] | @tsv' <<<"$json")" "$(
    printf '%s\n' $'builder\tsmall\t3\t55.3\t60\t60\t60' $'builder\t-\t1\t30\t30\t30\t30' $'builder\tfeature\t1\t300\t300\t300\t300' \
      $'reviewer\tfeature\t3\t30\t30\t40\t40' $'reviewer\tsmall\t1\t90\t90\t90\t90' \
      $'planner\tbug\t1\t60\t60\t60\t60' $'planner\tfeature\t1\t30\t30\t30\t30'
  )"
  assert_equal "$(jq -r '.workers.stats.by_role_project[] | [.role, .project, .workers, .mean, .median, .p90, .longest] | @tsv' <<<"$json")" "$(
    printf '%s\n' $'builder\tconventioner\t3\t55.3\t60\t60\t60' $'builder\tagent-team\t2\t165\t30\t300\t300' \
      $'reviewer\tagent-team\t3\t30\t30\t40\t40' $'reviewer\tconventioner\t1\t90\t90\t90\t90' \
      $'planner\tagent-team\t2\t45\t30\t60\t60'
  )"
  assert_equal "$(jq -r '.workers.stats.by_role_model[] | [.role, .model, .workers, .mean, .median, .p90, .longest] | @tsv' <<<"$json")" "$(
    printf '%s\n' $'builder\tdefault\t4\t109\t46\t300\t300' $'builder\tclaude-sonnet-5-5\t1\t60\t60\t60\t60' \
      $'reviewer\tdefault\t3\t50\t40\t90\t90' $'reviewer\tclaude-sonnet-5-5\t1\t30\t30\t30\t30' \
      $'planner\tdefault\t2\t45\t30\t60\t60'
  )"
  assert_equal "$(jq -c '.workers.longest' <<<"$json")" \
    '["b1000001","r0980001","b1010001","b1010003","p1020001","b1010002","r1000001","p1000001","r1000003","b0990001"]'
}

@test "--task keeps that task's workers alone" {
  local json
  json=$(workers_json --task T101)
  assert_equal "$(jq -c '[.workers.lifetimes[].session, .workers.running, [.workers.stats.by_role[].role]]' <<<"$json")" \
    '["b1010001","b1010002","b1010003",[],["builder"]]'
  json=$(workers_json --task T102)
  assert_equal "$(jq -c '[.workers.lifetimes[].session, .workers.running[].session]' <<<"$json")" '["p1020001","b1020001"]'
}

@test "the text form prints the lifetimes, the averages, the longest and the running after the task tables" {
  cp "$BATS_TEST_DIRNAME/fixtures/ledger-workers.jsonl" "$TEAM_HOME/ledger.jsonl"
  run_bin -0 team-time --since 2026-10-28T00:00:00Z --until 2026-10-28T20:00:00Z
  assert_contains "$output" "Worker lifetimes ended in the window: 11 (5 builders, 4 reviewers, 2 planners), 1 running"
  grep -Eq '^role +path +workers +mean +median +p90 +longest$' <<<"$output"
  grep -Eq '^builder +all +5 +99\.2 +60\.0 +300\.0 +300\.0$' <<<"$output"
  grep -Eq '^builder +small +3 +55\.3 +60\.0 +60\.0 +60\.0$' <<<"$output"
  grep -Eq '^role +project +workers +mean +median +p90 +longest$' <<<"$output"
  grep -Eq '^builder +agent-team +2 +165\.0 +30\.0 +300\.0 +300\.0$' <<<"$output"
  grep -Eq '^role +model +workers +mean +median +p90 +longest$' <<<"$output"
  grep -Eq '^reviewer +claude-sonnet-5-5 +1 +30\.0 +30\.0 +30\.0 +30\.0$' <<<"$output"
  grep -Eq '^task +role +session +path +project +minutes +ended +rounds +first done$' <<<"$output"
  grep -Eq '^T100 +builder +b1000001 +feature +agent-team +300\.0 +done +3 +60\.0$' <<<"$output"
  grep -Eq '^T100 +reviewer +r1000001 +feature +agent-team +40\.0 +review +0 +-$' <<<"$output"
  grep -Eq '^task +role +session +minutes so far$' <<<"$output"
  grep -Eq '^T102 +builder +b1020001 +240\.0$' <<<"$output"
  # The task tables come first, unchanged.
  assert_equal "${lines[0]}" "Task time from 2026-10-28T00:00:00Z to 2026-10-28T20:00:00Z: 4 tasks, 18.2 hours"
  [[ ${output%%Worker lifetimes*} == *"DONE to the task's next event"* ]]
  run_bin -0 team-time --task T102 --until 2026-10-28T20:00:00Z
  assert_contains "$output" "Worker lifetimes ended in the window: 1 (1 planner), 1 running"
}

@test "with no worker lifetimes the report says so" {
  : >"$TEAM_HOME/ledger.jsonl"
  run_bin -0 team-time --until "$until"
  assert_contains "$output" "Worker lifetimes ended in the window: 0, 0 running"
  [[ $output != *"Longest lifetimes"* ]]
  assert_equal "$(time_json --until "$until" | jq -c '.workers | [.lifetimes, .running, .stats.by_role, .longest]')" '[[],[],[],[]]'
}
