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
# T96, legacy, of agent-team, on 10-27, before any window from 10-28: builder b0960001 08:00 to
# its ticket-done and done, both at 08:30 (30, 1 round); builder b0960002 09:00 to its done at
# 09:30 and the task's pr 60 s later, one delivery (31, 1 round, first at 30, ended done).
# T95, legacy, of agent-team, on 10-27, the round window's edges: builder b0950001 10:00 to its
# done at 10:30 and the task's pr at 10:40, past 5 minutes (40, 2 rounds, first at 30, ended pr);
# b0950002 11:00 to its dones at 11:30 and 11:33, within 5 minutes (33, 2 rounds); b0950003 12:00
# to a ticket-done at 12:20 and its done at 12:30, then a ticket-done at 12:40, past 5 minutes,
# and its done at 12:50 (50, 2 rounds, first at 30); b0950004 13:00 to its done at 13:30, the
# ticket-done at 13:45 a late log with no report after it (30, 1 round, ended done); b0950005
# 14:00 to ticket-dones at 14:20 and 14:50 with no report at all, one round at its last (50, 1
# round, first at 50).
# T98 (conventioner small): builder b0980001 10-27 20:00 to its done at 23:00 (180 min, before a
# window from 10-28 00:00); reviewer r0980001 10-27 23:00 to its done at 00:30 (90, review 90).
# T100 (agent-team feature): planner p1000001 01:00 to its done at 01:30 (30, planning 30);
# builder b1000001 02:00 to its third done at 07:00 (300, first done 60; building 60, review 60,
# gate 20 (a gate run's minutes from 04:10), unattributed 160); reviewer r1000001 03:00 to its
# review at 03:40, with no done (40), its done at 21:00 after the window; reviewer r1000002 05:00
# to its done at 05:20 (20); reviewer r1000003 on claude-sonnet-5-5, 07:00 to its done at 07:30
# (30).
# T101 (conventioner small): builder b1010001 on claude-sonnet-5-5, 10:00 replaced at 11:00
# (60); builder b1010002 11:00 to its done at 11:46 (46), the task's ticket-done at 11:20 part of
# that one round; builder b1010003 12:00 to the task's pr at 12:40 (40, 1 round), not to the
# close at 13:00.
# T99, legacy (no opened): builder b0990001 of agent-team, 12:00 to its done at 12:30 (30, path
# "-", phases null). T97, legacy: a launch with no session, no lifetime.
# T102 (agent-team bug): planner p1020001 14:00 to the stow at 15:00 (60); builder b1020001 from
# 16:00, running at 20:00 (240 so far, building), its done at 21:00 after the window.
# Minutes by role: builder 300, 60, 46, 40, 30; reviewer 90, 40, 20, 30; planner 30, 60.
workers_json() {
  cp "$BATS_TEST_DIRNAME/fixtures/ledger-workers.jsonl" "$TEAM_HOME/ledger.jsonl"
  time_json --until 2026-10-28T20:00:00Z "$@"
}

@test "each worker's lifetime runs from its launch to its last done, pr or ticket-done, its review, its replacement, the stow or the close" {
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
      $'T101\tbuilder\tb1010003\tconventioner\tsmall\tdefault\t2026-10-28T12:00:00Z\t2026-10-28T12:40:00Z\tpr\t40\t1\t40' \
      $'T99\tbuilder\tb0990001\tagent-team\t-\tdefault\t2026-10-28T12:00:00Z\t2026-10-28T12:30:00Z\tdone\t30\t1\t30' \
      $'T102\tplanner\tp1020001\tagent-team\tbug\tdefault\t2026-10-28T14:00:00Z\t2026-10-28T15:00:00Z\tstowed\t60\t0\tnull'
  )"
  assert_equal "$(jq -c '[.workers.lifetimes[] | keys_unsorted] | unique' <<<"$json")" \
    '[["task","project","path","role","session","model","start","end","ended","minutes","rounds","first_done_minutes","phases","transcript"]]'
  # Without --since, the lifetimes that ended before 10-28 are in the window too; a done and its
  # ticket-done or pr are one round.
  json=$(workers_json)
  assert_equal "$(jq -c '[.workers.lifetimes[] | select(.task == "T96" or .task == "T98") | [.session, .end, .ended, .minutes, .rounds, .first_done_minutes]]' <<<"$json")" \
    '[["b0960001","2026-10-27T08:30:00Z","done",30,1,30],["b0960002","2026-10-27T09:31:00Z","done",31,1,30],["b0980001","2026-10-27T23:00:00Z","done",180,1,180],["r0980001","2026-10-28T00:30:00Z","done",90,1,90]]'
}

@test "a round's window is 5 minutes after its last event, two dones are two rounds, and a late lone ticket-done is no round" {
  local json
  json=$(workers_json --task T95)
  assert_equal "$(jq -r '.workers.lifetimes[] | [.session, .end, .ended, .minutes, .rounds, .first_done_minutes] | @tsv' <<<"$json")" "$(
    printf '%s\n' \
      $'b0950001\t2026-10-27T10:40:00Z\tpr\t40\t2\t30' \
      $'b0950002\t2026-10-27T11:33:00Z\tdone\t33\t2\t30' \
      $'b0950003\t2026-10-27T12:50:00Z\tdone\t50\t2\t30' \
      $'b0950004\t2026-10-27T13:30:00Z\tdone\t30\t1\t30' \
      $'b0950005\t2026-10-27T14:50:00Z\tticket-done\t50\t1\t50'
  )"
}

@test "each lifetime's phases are its task's over its span, gate runs included, and null for a legacy task" {
  local json
  json=$(workers_json --since 2026-10-28T00:00:00Z)
  assert_equal "$(jq -c '[.workers.lifetimes[] | {(.session): .phases}] | add' <<<"$json")" "$(jq -c . <<<'{
    "r0980001": {"review": 90}, "p1000001": {"planning": 30},
    "b1000001": {"building": 60, "gate": 20, "review": 60, "unattributed": 160},
    "r1000001": {"review": 40}, "r1000002": {"review": 20}, "r1000003": {"review": 30},
    "b1010001": {"building": 60}, "b1010002": {"building": 46}, "b1010003": {"building": 40},
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
    printf '%s\n' $'builder\t5\t95.2\t46\t300\t300' $'reviewer\t4\t45\t30\t90\t90' $'planner\t2\t45\t30\t60\t60'
  )"
  assert_equal "$(jq -r '.workers.stats.by_role_path[] | [.role, .path, .workers, .mean, .median, .p90, .longest] | @tsv' <<<"$json")" "$(
    printf '%s\n' $'builder\tsmall\t3\t48.7\t46\t60\t60' $'builder\t-\t1\t30\t30\t30\t30' $'builder\tfeature\t1\t300\t300\t300\t300' \
      $'reviewer\tfeature\t3\t30\t30\t40\t40' $'reviewer\tsmall\t1\t90\t90\t90\t90' \
      $'planner\tbug\t1\t60\t60\t60\t60' $'planner\tfeature\t1\t30\t30\t30\t30'
  )"
  assert_equal "$(jq -r '.workers.stats.by_role_project[] | [.role, .project, .workers, .mean, .median, .p90, .longest] | @tsv' <<<"$json")" "$(
    printf '%s\n' $'builder\tconventioner\t3\t48.7\t46\t60\t60' $'builder\tagent-team\t2\t165\t30\t300\t300' \
      $'reviewer\tagent-team\t3\t30\t30\t40\t40' $'reviewer\tconventioner\t1\t90\t90\t90\t90' \
      $'planner\tagent-team\t2\t45\t30\t60\t60'
  )"
  assert_equal "$(jq -r '.workers.stats.by_role_model[] | [.role, .model, .workers, .mean, .median, .p90, .longest] | @tsv' <<<"$json")" "$(
    printf '%s\n' $'builder\tdefault\t4\t104\t40\t300\t300' $'builder\tclaude-sonnet-5-5\t1\t60\t60\t60\t60' \
      $'reviewer\tdefault\t3\t50\t40\t90\t90' $'reviewer\tclaude-sonnet-5-5\t1\t30\t30\t30\t30' \
      $'planner\tdefault\t2\t45\t30\t60\t60'
  )"
  assert_equal "$(jq -c '.workers.longest' <<<"$json")" \
    '["b1000001","r0980001","b1010001","p1020001","b1010002","r1000001","b1010003","p1000001","r1000003","b0990001"]'
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
  grep -Eq '^builder +all +5 +95\.2 +46\.0 +300\.0 +300\.0$' <<<"$output"
  grep -Eq '^builder +small +3 +48\.7 +46\.0 +60\.0 +60\.0$' <<<"$output"
  grep -Eq '^role +project +workers +mean +median +p90 +longest$' <<<"$output"
  grep -Eq '^builder +agent-team +2 +165\.0 +30\.0 +300\.0 +300\.0$' <<<"$output"
  grep -Eq '^role +model +workers +mean +median +p90 +longest$' <<<"$output"
  grep -Eq '^reviewer +claude-sonnet-5-5 +1 +30\.0 +30\.0 +30\.0 +30\.0$' <<<"$output"
  grep -Eq '^task +role +session +path +project +minutes +ended +rounds +first done +top sinks$' <<<"$output"
  grep -Eq '^T100 +builder +b1000001 +feature +agent-team +300\.0 +done +3 +60\.0 +-$' <<<"$output"
  grep -Eq '^T100 +reviewer +r1000001 +feature +agent-team +40\.0 +review +0 +- +-$' <<<"$output"
  grep -Eq '^T101 +builder +b1010003 +small +conventioner +40\.0 +pr +1 +40\.0 +-$' <<<"$output"
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

# fixtures/team-time/usage/ holds time rows (team-tokens --help) of these sessions of
# fixtures/ledger-workers.jsonl, on home-pc but where told, each in minutes:
# b0980001 on 10-27, model 180 (its lifetime ended before 10-28).
# r0980001 on 10-27 (23:00 to 00:00) model 30, tool Read 10 and a wait for a message 23:40 to
# 00:00 (20, all in T98's review), and on 10-28 (00:00 to 00:25) model 15 and bash gh pr view 10:
# 85 of its 90, unseen 5.
# b1000001 on 10-28, 02:00 to 06:50 (290 of its 300, unseen 10): model 88, waits for a message
# 03:00 to 04:00 and 05:00 to 06:00 (120: review 03:00 to 03:40 and 05:00 to 05:20, 60;
# unattributed 60), bash no-mistakes axi run 20, bash tests/run 15, background bash gh pr checks
# 10, bash team-stack up 10, tool Agent 10, bash team-checks 5, tool Read 5, bash python3 3, bash
# git push no-mistakes 2 and compaction 2.
# b0990001 (legacy) on 10-28, 12:00 to 12:40, past its end at 12:30: model 20 and a wait for a
# message 12:20 to 12:40 (20, of which 10 in its span, under "-"); unseen 0.
# b1020001, running, on 10-28: model 120, in no breakdown.
# r1000003 on work-mac on 10-28, 07:00 to 07:31 (31 of its 30, unseen 0): model 20, background
# tool Agent 5, a Chrome DevTools screenshot 5 and bash curl 1.
# So builders have model 108, waiting for a message 140, gate 22, tests 15, ci 10, stacks 10,
# subagents 10, checks 5, files 5, other 3, compaction 2 and unseen 10 (340); reviewers model 65,
# waiting for a message 20, files 10, git 10, browser 5, subagents 5, other 1 and unseen 5 (121).
time_rows() {
  cp -R "$BATS_TEST_DIRNAME/fixtures/team-time/usage" "$TEAM_HOME/usage"
  mkdir -p "$HOME/.config/agent-team"
  echo home-pc >"$HOME/.config/agent-team/machine"
}

@test "team-time reads the time rows through team-tokens time once, from the earliest lifetime's start" {
  local code=$BATS_TEST_TMPDIR/code
  mkdir "$code"
  copy_bin "$code/bin"
  rm "$code/bin/team-tokens"
  printf '%s\n' '#!/usr/bin/env bash' \
    "jq -cn '\$ARGS.positional' --args -- \"\$@\" >>\"\$STUB_CALLS/team-tokens.log\"" \
    "exec \"$REPO_ROOT/bin/team-tokens\" \"\$@\"" >"$code/bin/team-tokens"
  chmod +x "$code/bin/team-tokens"
  cp "$BATS_TEST_DIRNAME/fixtures/ledger-workers.jsonl" "$TEAM_HOME/ledger.jsonl"
  time_rows
  guard_sandbox
  run -0 "$code/bin/team-time" --json --since 2026-10-28T00:00:00Z --until 2026-10-28T20:00:00Z
  assert_equal "$(stub_calls team-tokens)" '["time","--since","2026-10-27T23:00:00Z","--until","2026-10-28T20:00:00Z"]'
  rm "$STUB_CALLS/team-tokens.log"
  run -0 "$code/bin/team-time" --until 2026-10-28T20:00:00Z
  assert_equal "$(stub_calls team-tokens)" '["time","--since","2026-10-27T08:00:00Z","--until","2026-10-28T20:00:00Z"]'
  rm "$STUB_CALLS/team-tokens.log"
  # With no lifetime to report, team-tokens is never run.
  run -0 "$code/bin/team-time" --json --task T102 --since 2026-10-28T16:00:00Z --until 2026-10-28T20:00:00Z
  assert_equal "$(stub_calls team-tokens)" ''
  assert_equal "$(jq -c '.workers | [.lifetimes, .running[].session, .transcripts]' <<<"$output")" '[[],"b1020001",{"rows":0,"error":null}]'
}

@test "each lifetime is joined to its sessions' time rows, over days and machines" {
  time_rows
  local json
  json=$(workers_json --since 2026-10-28T00:00:00Z)
  assert_equal "$(jq -c '.workers.transcripts' <<<"$json")" '{"rows":7,"error":null}'
  assert_equal "$(jq -c '[.workers.lifetimes[] | select(.transcript == null) | .session]' <<<"$json")" \
    '["p1000001","r1000001","r1000002","b1010001","b1010002","b1010003","p1020001"]'
  assert_equal "$(jq -c '.workers.running[] | [.session, .transcript]' <<<"$json")" '["b1020001",null]'
  assert_equal "$(jq -c '.workers.lifetimes[] | select(.session == "b1000001") | .transcript' <<<"$json")" "$(jq -c . <<<'{
    "minutes": 290, "first": "2026-10-28T02:00:00.000Z", "last": "2026-10-28T06:50:00.000Z",
    "classes": {"model": 88, "compaction": 2, "wait:message": 120, "checks": 5, "gate": 22, "ci": 10, "tests": 15,
      "stacks": 10, "subagents": 10, "files": 5, "other": 3},
    "top": [{"key": "wait message", "minutes": 120, "calls": 2, "longest": 60},
      {"key": "model", "minutes": 88, "calls": 40, "longest": 2},
      {"key": "bash no-mistakes axi run", "minutes": 20, "calls": 2, "longest": 15}],
    "unseen": 10, "waits": {"wait:message": {"review": 60, "unattributed": 60}}}')"
  assert_equal "$(jq -c '.workers.lifetimes[] | select(.session == "r0980001") | .transcript' <<<"$json")" "$(jq -c . <<<'{
    "minutes": 85, "first": "2026-10-27T23:00:00.000Z", "last": "2026-10-28T00:25:00.000Z",
    "classes": {"model": 45, "wait:message": 20, "files": 10, "git": 10},
    "top": [{"key": "model", "minutes": 45, "calls": 15, "longest": 5},
      {"key": "wait message", "minutes": 20, "calls": 1, "longest": 20},
      {"key": "bash gh pr view", "minutes": 10, "calls": 2, "longest": 6.7}],
    "unseen": 5, "waits": {"wait:message": {"review": 20}}}')"
  # A transcript past the lifetime's end is reported whole; its waits are cut to the span.
  assert_equal "$(jq -c '.workers.lifetimes[] | select(.session == "b0990001") | .transcript | [.minutes, .unseen, .waits]' <<<"$json")" \
    '[40,0,{"wait:message":{"-":10}}]'
  assert_equal "$(jq -c '.workers.lifetimes[] | select(.session == "r1000003") | .transcript | [.minutes, .last, .classes, .unseen]' <<<"$json")" \
    '[31,"2026-10-28T07:31:00.000Z",{"model":20,"browser":5,"subagents":5,"other":1},0]'
  # Without --since, the lifetime that ended on 10-27 is joined too.
  json=$(workers_json)
  assert_equal "$(jq -c '.workers.lifetimes[] | select(.session == "b0980001") | [.session, .transcript.minutes, .transcript.classes]' <<<"$json")" '["b0980001",180,{"model":180}]'
}

@test "each key is classed when the report runs, first match wins, looking through background and the kind" {
  mkdir -p "$HOME/.config/agent-team" "$TEAM_HOME/usage/home-pc/time"
  echo home-pc >"$HOME/.config/agent-team/machine"
  # One row for b1010002 whose keys take 15 minutes down to 1, one key per class; and one for
  # b1010003 whose keys take 4 seconds to 52, less than any of those (its ci: gh run watch 24,
  # gh-axi pr checks 40, team-ci-wait 48 and in the background 52).
  jq -cn '[["model"], ["compaction"], ["wait message"], ["wait other"], ["background bash team-checks no-mistakes"],
      ["monitor npx eslint"], ["bash git push no-mistakes"], ["background bash gh pr checks"],
      ["bash npm run test:e2e"], ["bash docker compose"], ["tool mcp__chrome-devtools__take_screenshot"],
      ["tool Agent"], ["tool Edit"], ["bash gh pr create"], ["bash curl"]] as $keys
    | {day: "2026-10-28", machine: "home-pc", session: "b1010002-0000-4000-8000-000000000001",
       first: "2026-10-28T11:00:00.000Z", last: "2026-10-28T13:00:00.000Z",
       keys: ([range($keys | length) as $i | {($keys[$i][0]): {seconds: ((15 - $i) * 60), calls: 1, longest: ((15 - $i) * 60)}}] | add),
       waits: []},
    (["monitor npx eslint", "bash gofmt", "bash ./scripts/run-tests.sh", "bash chrome-devtools-axi screenshot",
      "bash team-stack up", "bash gh run watch", "bash no-mistakes axi run", "tool Read", "wait error",
      "bash gh-axi pr checks", "bash gh-axi pr view", "bash team-ci-wait", "background bash team-ci-wait"] as $keys
    | {day: "2026-10-28", machine: "home-pc", session: "b1010003-0000-4000-8000-000000000001",
       first: "2026-10-28T12:00:00.000Z", last: "2026-10-28T12:06:04.000Z",
       keys: ([range($keys | length) as $i | {($keys[$i]): {seconds: (($i + 1) * 4), calls: 1, longest: (($i + 1) * 4)}}] | add),
       waits: []})' >"$TEAM_HOME/usage/home-pc/time/2026-10-28.jsonl"
  local json
  json=$(workers_json --task T101)
  assert_equal "$(jq -r '.workers.breakdown.top[] | [.key, .class] | @tsv' <<<"$json")" "$(
    printf '%s\n' $'model\tmodel' $'compaction\tcompaction' $'wait message\twait:message' $'wait other\twait:other' \
      $'background bash team-checks no-mistakes\tchecks' $'monitor npx eslint\tchecks' $'bash git push no-mistakes\tgate' \
      $'background bash gh pr checks\tci' $'bash npm run test:e2e\ttests' $'bash docker compose\tstacks' \
      $'tool mcp__chrome-devtools__take_screenshot\tbrowser' $'tool Agent\tsubagents' $'tool Edit\tfiles' \
      $'bash gh pr create\tgit' $'bash curl\tother'
  )"
  assert_equal "$(jq -c '.workers.lifetimes[] | select(.session == "b1010003") | .transcript.classes' <<<"$json")" \
    '{"wait:error":0.6,"checks":0.2,"gate":0.5,"ci":2.7,"tests":0.2,"stacks":0.3,"browser":0.3,"files":0.5,"git":0.7}'
  # Its 120 minutes of transcript are past its 46 of lifetime: none unseen.
  assert_equal "$(jq -c '.workers.lifetimes[] | select(.session == "b1010002") | .transcript | [.minutes, .unseen]' <<<"$json")" '[120,0]'
}

@test "the breakdown gives the coverage, each role's class minutes and shares, the top fifteen keys and the waits by phase" {
  time_rows
  local json
  json=$(workers_json --since 2026-10-28T00:00:00Z)
  assert_equal "$(jq -c '.workers.breakdown | keys_unsorted' <<<"$json")" '["coverage","classes","share","top","waits"]'
  assert_equal "$(jq -c '.workers.breakdown.coverage' <<<"$json")" \
    '{"lifetimes":11,"transcripts":4,"roles":[{"role":"builder","lifetimes":5,"transcripts":2},{"role":"reviewer","lifetimes":4,"transcripts":2},{"role":"planner","lifetimes":2,"transcripts":0}]}'
  assert_equal "$(jq -c '.workers.breakdown.classes' <<<"$json")" "$(jq -c . <<<'{
    "builder": {"model": 108, "compaction": 2, "wait:message": 140, "checks": 5, "gate": 22, "ci": 10, "tests": 15,
      "stacks": 10, "subagents": 10, "files": 5, "other": 3, "unseen": 10},
    "reviewer": {"model": 65, "wait:message": 20, "browser": 5, "subagents": 5, "files": 10, "git": 10, "other": 1, "unseen": 5},
    "all": {"model": 173, "compaction": 2, "wait:message": 160, "checks": 5, "gate": 22, "ci": 10, "tests": 15,
      "stacks": 10, "browser": 5, "subagents": 15, "files": 15, "git": 10, "other": 4, "unseen": 15}}')"
  # Shares: of the builders' 340, the reviewers' 121 and all 461 minutes.
  assert_equal "$(jq -c '.workers.breakdown.share' <<<"$json")" "$(jq -c . <<<'{
    "builder": {"model": 31.8, "compaction": 0.6, "wait:message": 41.2, "checks": 1.5, "gate": 6.5, "ci": 2.9, "tests": 4.4,
      "stacks": 2.9, "subagents": 2.9, "files": 1.5, "other": 0.9, "unseen": 2.9},
    "reviewer": {"model": 53.7, "wait:message": 16.5, "browser": 4.1, "subagents": 4.1, "files": 8.3, "git": 8.3, "other": 0.8, "unseen": 4.1},
    "all": {"model": 37.5, "compaction": 0.4, "wait:message": 34.7, "checks": 1.1, "gate": 4.8, "ci": 2.2, "tests": 3.3,
      "stacks": 2.2, "browser": 1.1, "subagents": 3.3, "files": 3.3, "git": 2.2, "other": 0.9, "unseen": 3.3}}')"
  jq -e '.workers.breakdown.share[] | [.[]] | add | . >= 99.5 and . <= 100.5' <<<"$json" >/dev/null
  # Sixteen keys, the fifteen with the most minutes kept: bash curl's one minute is left out.
  assert_equal "$(jq -r '.workers.breakdown.top[] | [.key, .class, .minutes, .calls, .longest, .lifetimes] | @tsv' <<<"$json")" "$(
    printf '%s\n' $'model\tmodel\t173\t75\t5\t4' $'wait message\twait:message\t160\t4\t60\t3' \
      $'bash no-mistakes axi run\tgate\t20\t2\t15\t1' $'bash tests/run\ttests\t15\t3\t6.7\t1' $'tool Read\tfiles\t15\t42\t1\t2' \
      $'background bash gh pr checks\tci\t10\t1\t10\t1' $'bash gh pr view\tgit\t10\t2\t6.7\t1' \
      $'bash team-stack up\tstacks\t10\t1\t10\t1' $'tool Agent\tsubagents\t10\t1\t10\t1' \
      $'background tool Agent\tsubagents\t5\t1\t5\t1' $'bash team-checks\tchecks\t5\t1\t5\t1' \
      $'tool mcp__plugin_browser_chrome-devtools__take_screenshot\tbrowser\t5\t3\t2.5\t1' \
      $'bash python3\tother\t3\t2\t2\t1' $'bash git push no-mistakes\tgate\t2\t1\t2\t1' $'compaction\tcompaction\t2\t1\t2\t1'
  )"
  assert_equal "$(jq -c '.workers.breakdown.waits' <<<"$json")" '{"builder":{"review":60,"unattributed":60,"-":10},"reviewer":{"review":20}}'
  # --task keeps that task's workers alone.
  json=$(workers_json --task T100)
  assert_equal "$(jq -c '.workers.breakdown | [.coverage.lifetimes, .coverage.transcripts, .classes.all.model, .waits]' <<<"$json")" \
    '[5,2,108,{"builder":{"review":60,"unattributed":60},"reviewer":{}}]'
}

@test "the text form says where the workers' time went, the top sinks and the waits by phase, and fills the longest's top sinks" {
  cp "$BATS_TEST_DIRNAME/fixtures/ledger-workers.jsonl" "$TEAM_HOME/ledger.jsonl"
  time_rows
  run_bin -0 team-time --since 2026-10-28T00:00:00Z --until 2026-10-28T20:00:00Z
  grep -Eq '^task +role +session +path +project +minutes +ended +rounds +first done +top sinks$' <<<"$output"
  grep -Eq '^T100 +builder +b1000001 +feature +agent-team +300\.0 +done +3 +60\.0 +wait message 120, model 88, bash no-mistakes axi run 20$' <<<"$output"
  grep -Eq '^T100 +reviewer +r1000001 +feature +agent-team +40\.0 +review +0 +- +-$' <<<"$output"
  assert_contains "$output" "Where workers' time went (transcripts for 4 of 11 lifetimes), minutes"
  grep -Eq '^class +builder +reviewer +share$' <<<"$output"
  grep -Eq '^waiting for a message +140\.0 +20\.0 +34\.7%$' <<<"$output"
  grep -Eq '^the browser +0\.0 +5\.0 +1\.1%$' <<<"$output"
  grep -Eq '^not in the transcript +10\.0 +5\.0 +3\.3%$' <<<"$output"
  grep -Eq '^all +340\.0 +121\.0 +100\.0%$' <<<"$output"
  # A class with no minutes has no row.
  assert_equal "$(grep -Ec '^other waits +[0-9.]+ +[0-9.]+ +[0-9.]+%$' <<<"$output" || true)" 0
  assert_contains "$output" "Top time sinks"
  grep -Eq '^key +class +minutes +calls +longest +lifetimes$' <<<"$output"
  grep -Eq '^bash no-mistakes axi run +gate +20\.0 +2 +15\.0 +1$' <<<"$output"
  assert_contains "$output" "Waiting for a message, by what the task was doing, minutes"
  grep -Eq '^phase +builder +reviewer$' <<<"$output"
  grep -Eq '^review +60\.0 +20\.0$' <<<"$output"
  grep -Eq '^no phases \(a legacy task\) +10\.0 +0\.0$' <<<"$output"
  # The breakdown comes between the longest and the running.
  [[ $output == *"Longest lifetimes"*"Where workers' time went"*"Top time sinks"*"Waiting for a message"*"Running at the window's end"* ]]
  # With rows for none of the lifetimes, it says so.
  run_bin -0 team-time --task T101 --until 2026-10-28T20:00:00Z
  assert_contains "$output" "Where workers' time went: no transcript for any of the 3 lifetimes"
  [[ $output != *"Top time sinks"* ]]
}

@test "with no machine name, the ledger part prints and the breakdown says why it is unavailable" {
  cp "$BATS_TEST_DIRNAME/fixtures/ledger-workers.jsonl" "$TEAM_HOME/ledger.jsonl"
  cp -R "$BATS_TEST_DIRNAME/fixtures/team-time/usage" "$TEAM_HOME/usage"
  local reason="team-tokens: this machine has no team name; write one with: echo <name> > ~/.config/agent-team/machine"
  run_bin -0 team-time --since 2026-10-28T00:00:00Z --until 2026-10-28T20:00:00Z
  assert_contains "$output" "Worker lifetimes ended in the window: 11 (5 builders, 4 reviewers, 2 planners), 1 running"
  grep -Eq '^T100 +builder +b1000001 +feature +agent-team +300\.0 +done +3 +60\.0 +-$' <<<"$output"
  assert_contains "$output" "Where workers' time went: unavailable: $reason"
  [[ $output != *"Top time sinks"* ]]
  assert_contains "$output" "Running at the window's end"
  local json
  json=$(workers_json --since 2026-10-28T00:00:00Z)
  assert_equal "$(jq -c '.workers | [.transcripts, .breakdown, ([.lifetimes[].transcript] | unique)]' <<<"$json")" \
    "$(jq -cn --arg reason "$reason" '[{rows: null, error: $reason}, null, [null]]')"
  assert_equal "$(jq -c '.workers.stats.by_role[0] | [.role, .workers]' <<<"$json")" '["builder",5]'
}
