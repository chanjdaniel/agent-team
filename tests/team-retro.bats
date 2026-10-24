#!/usr/bin/env bats
# team-retro: when the next retro is due, and the ledger's evidence for a retro's window, from the
# ledger alone.

load helpers/common

setup() {
  sandbox
}

# ledger_line [jq options...] <filter>: append the line jq builds, standing in for its writer.
ledger_line() {
  jq -cn "$@" >>"$TEAM_HOME/ledger.jsonl"
}

# event <ts> <task> <kind> [<jq object of more fields>]
event() {
  ledger_line --arg ts "$1" --arg t "$2" --arg e "$3" "{ts: \$ts, task: \$t, event: \$e} + (${4:-{\}})"
}

# opened <ts> <task> <path> [<title>]
opened() {
  event "$1" "$2" opened "{project: \"proj\", path: \"$3\", type: \"feat\", title: \"${4:-Work}\",
    branch: \"feat/$2-work\", base: \"main\", base_sha: \"0123456\", worktree: \"/w/1\"}"
}

closed() {
  event "$1" "$2" closed '{archive: [], returned: [], kept: []}'
}

# schedule <ts> <every_hours>
schedule() {
  event "$1" T26 retro-schedule "{every_hours: $2, discord_message: \"1563171945980370967\"}"
}

# ago <hours>: the UTC time that many hours before now.
ago() {
  date -u -d "$1 hours ago" +%FT%TZ
}

# plus <time> <hours>: the UTC time that many hours after <time>.
plus() {
  date -u -d "@$(($(date -u -d "$1" +%s) + $2 * 3600))" +%FT%TZ
}

# A day's time: at <HH:MM> on 2026-10-20.
at() {
  echo "2026-10-20T$1:00Z"
}

@test "--help prints the header" {
  run_bin -0 team-retro --help
  assert_equal "${lines[0]}" "$(sed -n '2s/^# //p' "$REPO_ROOT/bin/team-retro")"
  assert_contains "$output" "team-retro digest [T<n>] [--json]"
}

@test "status: not scheduled with no retro-schedule, and with every_hours 0" {
  run_bin -0 team-retro status
  assert_equal "$output" "Retros are not scheduled."
  run_bin -0 team-retro status --json
  assert_equal "$(jq -c . <<<"$output")" \
    '{"schema":"team-retro-status/1","schedule":null,"last":null,"running":null,"next":null,"due":false}'

  local opened
  opened=$(ago 100)
  schedule "$(ago 200)" 48
  opened "$opened" T2 retro
  closed "$(ago 99)" T2
  schedule "$(ago 50)" 0
  run_bin -0 team-retro status
  assert_equal "$output" "Retros are not scheduled. Last: T2, opened $opened, closed."
  run_bin -0 team-retro status --json
  assert_equal "$(jq -c '[.schedule, .last, .running, .next, .due]' <<<"$output")" \
    "[null,{\"task\":\"T2\",\"opened\":\"$opened\",\"status\":\"closed\"},null,null,false]"
}

@test "status: the next retro is due every_hours after the schedule when no retro has opened" {
  local since
  since=$(ago 10)
  schedule "$since" 48
  run_bin -0 team-retro status
  assert_equal "$output" \
    "Retros every 48h since $since (Discord 1563171945980370967). No retro yet. Next due $(plus "$since" 48)."
  run_bin -0 team-retro status --json
  assert_equal "$(jq -c . <<<"$output")" "$(jq -cn --arg since "$since" --arg next "$(plus "$since" 48)" '{
    schema: "team-retro-status/1",
    schedule: {every_hours: 48, since: $since, discord_message: "1563171945980370967", task: "T26"},
    last: null, running: null, next: $next, due: false}')"
}

@test "status: the next retro counts from the later of the latest retro's opening and the latest schedule" {
  local opened changed
  opened=$(ago 30)
  schedule "$(ago 100)" 48
  opened "$opened" T2 retro
  closed "$(ago 29)" T2
  run_bin -0 team-retro status
  assert_contains "$output" "Last: T2, opened $opened, closed. Next due $(plus "$opened" 48)."

  changed=$(ago 20)
  schedule "$changed" 24
  run_bin -0 team-retro status
  assert_equal "$output" \
    "Retros every 24h since $changed (Discord 1563171945980370967). Last: T2, opened $opened, closed. Next due $(plus "$changed" 24)."
}

@test "status: a retro is due once its time is past, and running while a retro task is open" {
  local opened
  opened=$(ago 60)
  schedule "$(ago 100)" 48
  opened "$opened" T2 retro
  closed "$(ago 59)" T2
  run_bin -0 team-retro status
  assert_contains "$output" "Last: T2, opened $opened, closed. Due since $(plus "$opened" 48)."
  run_bin -0 team-retro status --json
  assert_equal "$(jq -c '[.running, .next, .due]' <<<"$output")" "[null,\"$(plus "$opened" 48)\",true]"

  opened=$(ago 1)
  opened "$opened" T3 retro
  run_bin -0 team-retro status
  assert_contains "$output" "Last: T3, opened $opened, open. Running T3."
  run_bin -0 team-retro status --json
  assert_equal "$(jq -c '[.last.status, .running, .next, .due]' <<<"$output")" "[\"open\",\"T3\",\"$(plus "$opened" 48)\",false]"
}

@test "status: tasks of other paths are not retros, and legacy and non-JSON lines are read past" {
  schedule "$(ago 100)" 48
  echo 'not json' >>"$TEAM_HOME/ledger.jsonl"
  event "$(ago 90)" T1 plan-ready
  opened "$(ago 1)" T4 research
  echo '{"ts": "2026-10-20T00:00:00Z", "event": "launch"}' >>"$TEAM_HOME/ledger.jsonl"
  run_bin -0 team-retro status --json
  assert_equal "$(jq -c '[.last, .running, .due]' <<<"$output")" "[null,null,true]"
}

@test "digest: a retro task's window runs from the previous retro's opening to its own" {
  opened "$(at 00:00)" T1 feature
  event "$(at 01:00)" T1 blocked '{reason: "one"}'
  opened "$(at 02:00)" T2 retro
  event "$(at 03:00)" T1 failed '{reason: "two"}'
  opened "$(at 04:00)" T3 retro
  event "$(at 05:00)" T1 blocked '{reason: "three"}'

  run_bin -0 team-retro digest T2 --json
  assert_equal "$(jq -c '.schema, .window, [.blocks[].reason]' <<<"$output")" "$(
    cat <<'JSON'
"team-retro-digest/1"
{"task":"T2","previous":null,"since":"2026-10-20T00:00:00Z","until":"2026-10-20T02:00:00Z","events":3,"kinds":{"blocked":1,"opened":2}}
["one"]
JSON
  )"
  run_bin -0 team-retro digest --json T3
  assert_equal "$(jq -c '.window, [.blocks[].reason]' <<<"$output")" "$(
    cat <<'JSON'
{"task":"T3","previous":"T2","since":"2026-10-20T02:00:00Z","until":"2026-10-20T04:00:00Z","events":2,"kinds":{"failed":1,"opened":1}}
["two"]
JSON
  )"

  local before after
  before=$(date -u +%FT%TZ)
  run_bin -0 team-retro digest --json
  after=$(date -u +%FT%TZ)
  assert_equal "$(jq -c '.window | del(.until)' <<<"$output")" \
    '{"task":null,"previous":"T3","since":"2026-10-20T04:00:00Z","events":1,"kinds":{"blocked":1}}'
  local until
  until=$(jq -r .window.until <<<"$output")
  [[ ! $until < $before && ! $until > $after ]]
}

@test "digest: with no retro yet, a dry run reads the whole ledger" {
  opened "$(at 00:00)" T1 feature
  event "$(at 01:00)" T1 blocked '{reason: "one"}'
  run_bin -0 team-retro digest --json
  assert_equal "$(jq -c '.window | [.task, .previous, .since, .events]' <<<"$output")" '[null,null,"2026-10-20T00:00:00Z",2]'
  : >"$TEAM_HOME/ledger.jsonl"
  run_bin -0 team-retro digest --json
  assert_equal "$(jq -c '(.window | [.since, .events, .kinds]), .blocks, .waits, .tasks' <<<"$output")" \
    $'[null,0,{}]\n[]\n{"spans":[],"totals":[]}\n[]'
  rm "$TEAM_HOME/ledger.jsonl"
  run_bin -0 team-retro digest
  assert_contains "$output" "Blocks: none"
}

@test "digest: a task that is not a retro task is a usage error" {
  opened "$(at 00:00)" T1 feature
  event "$(at 01:00)" T5 plan-ready
  run_bin -2 --separate-stderr team-retro digest T1
  assert_equal "$output" ""
  assert_equal "$stderr" "team-retro: T1 is not a retro task: it has no opened event with the path retro"
  run_bin -2 team-retro digest T5
  run_bin -2 team-retro digest T9 --json
}

@test "digest: blocks are every blocked and failed, denials picked out by their reason" {
  opened "$(at 00:00)" T1 feature
  local reason
  for reason in "git reset --hard denied by auto mode" "Auto Mode said no" "it REFUSES" "timer refused 3x" \
    "the classifier denies it" "docker daemons not restarted"; do
    event "$(at 01:00)" T1 blocked "{reason: \"$reason\"}"
  done
  event "$(at 02:00)" T1 failed '{reason: "the suite broke"}'
  run_bin -0 team-retro digest --json
  assert_equal "$(jq -c '.blocks[] | [.ts, .task, .kind, .denial]' <<<"$output" | uniq -c | sed 's/^ *//')" "$(
    cat <<'LINES'
5 ["2026-10-20T01:00:00Z","T1","blocked",true]
1 ["2026-10-20T01:00:00Z","T1","blocked",false]
1 ["2026-10-20T02:00:00Z","T1","failed",false]
LINES
  )"
  assert_equal "$(jq -r '.blocks[0].reason' <<<"$output")" "git reset --hard denied by auto mode"
}

@test "digest: questions per task, repeated with two or more in the window" {
  opened "$(at 00:00)" T1 feature
  event "$(at 00:30)" T1 asked '{id: "before", text: "outside the window"}'
  opened "$(at 01:00)" T9 retro
  event "$(at 02:00)" T1 question '{role: "builder", text: "which flag?"}'
  event "$(at 03:00)" T2 asked '{id: "plan", text: "go?"}'
  event "$(at 04:00)" T1 asked '{id: "scope", text: "drop 04?"}'
  opened "$(at 05:00)" T10 retro
  run_bin -0 team-retro digest T10 --json
  assert_equal "$(jq -c '.questions[]' <<<"$output")" "$(
    cat <<'LINES'
{"task":"T1","repeated":true,"events":[{"ts":"2026-10-20T02:00:00Z","kind":"question","text":"which flag?","role":"builder"},{"ts":"2026-10-20T04:00:00Z","kind":"asked","text":"drop 04?","id":"scope"}]}
{"task":"T2","repeated":false,"events":[{"ts":"2026-10-20T03:00:00Z","kind":"asked","text":"go?","id":"plan"}]}
LINES
  )"
}

@test "digest: reviews per task, reopened when findings are followed by another review" {
  opened "$(at 00:00)" T1 feature
  event "$(at 01:00)" T1 review '{verdict: "findings", head: "aaaaaaa"}'
  event "$(at 02:00)" T2 review '{verdict: "pass", head: "bbbbbbb"}'
  event "$(at 03:00)" T1 review '{verdict: "pass", head: "ccccccc"}'
  event "$(at 04:00)" T2 review '{verdict: "findings", head: "ddddddd"}'
  event "$(at 05:00)" T3 review '{verdict: "findings", head: "eeeeeee"}'
  event "$(at 06:00)" T3 review '{verdict: "findings", head: "fffffff"}'
  run_bin -0 team-retro digest --json
  assert_equal "$(jq -c '.reviews[] | [.task, .reopened, (.verdicts | map(.verdict + " " + .head) | join(", "))]' <<<"$output")" "$(
    cat <<'LINES'
["T1",true,"findings aaaaaaa, pass ccccccc"]
["T2",false,"pass bbbbbbb, findings ddddddd"]
["T3",true,"findings eeeeeee, findings fffffff"]
LINES
  )"
}

# A day of waits for T1 and T2, then retros T9 and T10.
waits_ledger() {
  opened "$(at 00:00)" T1 feature
  event "$(at 01:00)" T1 waiting '{on: "Daniel", reason: "plan"}'
  event "$(at 02:00)" T1 paused '{reason: "night"}'
  event "$(at 03:00)" T1 launch '{role: "builder", session: "11111111", worktree: "/w/1", toolkits: []}'
  event "$(at 04:00)" T1 blocked '{reason: "denied"}'
  event "$(at 05:00)" T1 launch '{role: "builder", session: "22222222", worktree: "/w/1", toolkits: []}'
  event "$(at 06:00)" T1 held '{reason: "gate"}'
  event "$(at 07:00)" T1 resumed
  event "$(at 08:00)" T1 asked '{id: "a", text: "scope?"}'
  event "$(at 08:30)" T1 asked '{id: "b", text: "name?"}'
  event "$(at 09:00)" T1 answered '{id: "b", answer: "x"}'
  event "$(at 10:00)" T1 answered '{id: "a", answer: "y"}'
  opened "$(at 11:00)" T2 feature
  event "$(at 11:00)" T2 blocked '{reason: "docker"}'
  closed "$(at 12:30)" T2
  event "$(at 13:00)" T1 waiting '{on: "daniel", reason: "walkthrough"}'
  opened "$(at 14:00)" T9 retro
  event "$(at 15:00)" T1 resumed
  event "$(at 16:00)" T1 waiting '{on: "restart", reason: "reboot"}'
  opened "$(at 20:00)" T10 retro
}

@test "digest: each wait runs to the event that clears it, and totals hours and wall-clock hours per whom" {
  waits_ledger
  run_bin -0 team-retro digest T9 --json
  assert_equal "$(jq -r '.waits.spans[] | [.task, .kind, .on, .from[11:16], .to[11:16], .hours, .open, .clipped, .reason] | join(" ")' <<<"$output")" "$(
    cat <<'LINES'
T1 waiting Daniel 01:00 03:00 2 false false plan
T1 paused paused 02:00 03:00 1 false false night
T1 blocked blocked 04:00 05:00 1 false false denied
T1 held held 06:00 07:00 1 false false gate
T1 asked Daniel 08:00 10:00 2 false false scope?
T1 asked Daniel 08:30 09:00 0.5 false false name?
T2 blocked blocked 11:00 12:30 1.5 false false docker
T1 waiting daniel 13:00 14:00 1 true false walkthrough
LINES
  )"
  assert_equal "$(jq -c '.waits.totals[]' <<<"$output")" "$(
    cat <<'LINES'
{"on":"Daniel","hours":5.5,"wall_hours":5,"spans":4}
{"on":"blocked","hours":2.5,"wall_hours":2.5,"spans":2}
{"on":"held","hours":1,"wall_hours":1,"spans":1}
{"on":"paused","hours":1,"wall_hours":1,"spans":1}
LINES
  )"
}

@test "digest: a wait from before the window is clipped to it, and one open at its end ends there" {
  waits_ledger
  run_bin -0 team-retro digest T10 --json
  assert_equal "$(jq -r '.waits.spans[] | [.task, .kind, .on, .from[11:16], .to[11:16], .hours, .open, .clipped] | join(" ")' <<<"$output")" "$(
    cat <<'LINES'
T1 waiting daniel 14:00 15:00 1 false true
T1 waiting restart 16:00 20:00 4 true false
LINES
  )"
  assert_equal "$(jq -c '.waits.totals' <<<"$output")" '[{"on":"restart","hours":4,"wall_hours":4,"spans":1},{"on":"daniel","hours":1,"wall_hours":1,"spans":1}]'

  run_bin -0 team-retro digest T10
  assert_contains "$output" "  T1 waiting on daniel, 2026-10-20T14:00:00Z to 2026-10-20T15:00:00Z, 1h, clipped to the window's start: walkthrough"
  assert_contains "$output" "  T1 waiting on restart, 2026-10-20T16:00:00Z to 2026-10-20T20:00:00Z, 4h, open at the window's end: reboot"
  assert_contains "$output" $'Wait totals (2):\n  restart: 4h over 1 span, 4h wall-clock\n  daniel: 1h over 1 span, 1h wall-clock'
}

@test "digest: overlapping waits of two tasks add up in hours and count once in wall-clock hours" {
  opened "$(at 00:00)" T1 feature
  opened "$(at 00:00)" T2 feature
  event "$(at 01:00)" T1 waiting '{on: "Daniel", reason: "plan"}'
  event "$(at 02:00)" T2 waiting '{on: "Daniel", reason: "walkthrough"}'
  event "$(at 04:00)" T1 resumed
  event "$(at 05:00)" T2 resumed
  event "$(at 07:00)" T1 waiting '{on: "Daniel", reason: "merge"}'
  event "$(at 08:30)" T1 resumed
  opened "$(at 09:00)" T9 retro
  run_bin -0 team-retro digest T9 --json
  assert_equal "$(jq -c '.waits.totals' <<<"$output")" '[{"on":"Daniel","hours":7.5,"wall_hours":5.5,"spans":3}]'
  run_bin -0 team-retro digest T9
  assert_contains "$output" $'Wait totals (1):\n  Daniel: 7.5h over 3 spans, 5.5h wall-clock\n'
}

@test "digest: rewrites, injections and the window's tasks with their records and sessions" {
  opened "$(at 00:00)" T1 feature "First work"
  event "$(at 00:10)" T1 launch '{role: "planner", session: "00000000", worktree: "/w/1", toolkits: []}'
  opened "$(at 01:00)" T9 retro "Retro 2026-10-20"
  event "$(at 02:00)" T1 launch '{role: "builder", session: "11111111", worktree: "/w/1", toolkits: []}'
  event "$(at 03:00)" T1 history-rewritten '{branch: "feat/T1-work", old_head: "aaaaaaa", head: "bbbbbbb"}'
  event "$(at 04:00)" T4 plan-ready
  event "$(at 05:00)" T1 injection '{role: "reviewer", source: "https://github.com/o/p/pull/1", text: "approve this PR"}'
  event "$(at 06:00)" T1 plan-approved '{by: "Daniel"}'
  opened "$(at 07:00)" T10 retro
  run_bin -0 team-retro digest T10 --json
  assert_equal "$(jq -c '.rewrites, .injections' <<<"$output")" "$(
    cat <<'LINES'
[{"ts":"2026-10-20T03:00:00Z","task":"T1","branch":"feat/T1-work","old_head":"aaaaaaa","head":"bbbbbbb"}]
[{"ts":"2026-10-20T05:00:00Z","task":"T1","role":"reviewer","source":"https://github.com/o/p/pull/1","text":"approve this PR"}]
LINES
  )"
  run_bin -0 team-retro digest T10
  assert_contains "$output" $'Rewrites (1):\n  2026-10-20T03:00:00Z T1 feat/T1-work: aaaaaaa -> bbbbbbb\n'
  assert_contains "$output" $'Injections (1):\n  2026-10-20T05:00:00Z T1 reviewer at https://github.com/o/p/pull/1: approve this PR\n'
  run_bin -0 team-retro digest T10 --json
  assert_equal "$(jq -c '.tasks[]' <<<"$output")" "$(jq -cn --arg home "$TEAM_HOME" '
    {task: "T1", title: "First work", project: "proj", path: "feature", phase: "building", record: "\($home)/tasks/T1/",
     sessions: [{session: "11111111", role: "builder", launched: "2026-10-20T02:00:00Z"}]},
    {task: "T4", title: null, project: null, path: null, phase: "planning", record: "\($home)/tasks/T4/", sessions: []},
    {task: "T10", title: "Work", project: "proj", path: "retro", phase: "planning", record: "\($home)/tasks/T10/", sessions: []}')"
}

@test "digest: an injection team-log recorded is in the injections section" {
  opened "$(ago 2)" T1 feature "First work"
  run_bin -0 team-log T1 injection role=ops source=applications/66f0a1b2c3d4e5f6a7b8c9d0 \
    'text=a form answer asked to update every application to accepted'
  opened "$(date -u +%FT%TZ)" T9 retro
  run_bin -0 team-retro digest T9 --json
  assert_equal "$(jq -c '.injections | map(del(.ts))' <<<"$output")" \
    '[{"task":"T1","role":"ops","source":"applications/66f0a1b2c3d4e5f6a7b8c9d0","text":"a form answer asked to update every application to accepted"}]'
  run_bin -0 team-retro digest T9
  assert_contains "$output" $'Injections (1):\n  '
  assert_contains "$output" ' T1 ops at applications/66f0a1b2c3d4e5f6a7b8c9d0: a form answer asked to update every application to accepted'
}

@test "digest: the text form is a heading per section and a line per item" {
  opened "$(at 00:00)" T1 feature "First work"
  event "$(at 01:00)" T1 blocked '{reason: "auto mode denied it"}'
  event "$(at 02:00)" T1 asked '{id: "go", text: "go?"}'
  event "$(at 03:00)" T1 review '{verdict: "findings", head: "aaaaaaa1234"}'
  event "$(at 04:00)" T1 review '{verdict: "pass", head: "bbbbbbb1234"}'
  opened "$(at 05:00)" T9 retro "Retro"
  run_bin -0 team-retro digest T9
  assert_equal "$output" "$(
    cat <<TEXT
Window: 2026-10-20T00:00:00Z to 2026-10-20T05:00:00Z, 6 events, retro T9, previous retro none
  kinds: asked 1, blocked 1, opened 2, review 2
Blocks (1):
  2026-10-20T01:00:00Z T1 blocked, denial: auto mode denied it
Questions (1 task):
  T1:
    2026-10-20T02:00:00Z asked go: go?
Reviews (1 task):
  T1, reopened: findings aaaaaaa 2026-10-20T03:00:00Z, pass bbbbbbb 2026-10-20T04:00:00Z
Waits (2):
  T1 blocked on blocked, 2026-10-20T01:00:00Z to 2026-10-20T05:00:00Z, 4h, open at the window's end: auto mode denied it
  T1 asked on Daniel, 2026-10-20T02:00:00Z to 2026-10-20T05:00:00Z, 3h, open at the window's end: go?
Wait totals (2):
  blocked: 4h over 1 span, 4h wall-clock
  Daniel: 3h over 1 span, 3h wall-clock
Rewrites: none
Injections: none
Tasks (2):
  T1 proj feature blocked: First work; record $TEAM_HOME/tasks/T1/; sessions none
  T9 proj retro planning: Retro; record $TEAM_HOME/tasks/T9/; sessions none
TEXT
  )"
}

@test "the ledger as the planner read it: eleven blocks, nine denials, twelve waits, four reopened reviews" {
  cp "$BATS_TEST_DIRNAME/fixtures/ledger-2026-10-23.jsonl" "$TEAM_HOME/ledger.jsonl"
  assert_equal "$(wc -l <"$TEAM_HOME/ledger.jsonl")" 436
  run_bin -0 team-retro digest --json
  assert_equal "$(jq -c '[.blocks[] | select(.kind == "blocked")] | [length, map(select(.denial)) | length]' <<<"$output")" "[11,9]"
  assert_equal "$(jq -c '[.waits.spans[] | select(.kind == "waiting")] | length' <<<"$output")" 12
  # Each block ends at the task's next launch or resumed, so none is open at the ledger's end.
  assert_equal "$(jq -c '.waits.totals[] | select(.on == "blocked")' <<<"$output")" \
    '{"on":"blocked","hours":31.47,"wall_hours":31.27,"spans":11}'
  assert_equal "$(jq -c '[.reviews[] | select(.reopened) | .task] | sort' <<<"$output")" '["T15","T20","T21","T5"]'
  assert_equal "$(jq -c '[.window.since, .window.events, .window.previous, (.rewrites | length)]' <<<"$output")" \
    '["2026-10-21T12:16:13Z",436,null,1]'
  run_bin -0 team-retro digest
  assert_contains "$output" $'Rewrites (1):\n  2026-10-21T22:56:15Z T4: to 9ce2bfd3 (messages only, diff empty; pushed with force-with-lease on Daniel OK)'
  run_bin -0 team-retro status
  assert_equal "$output" "Retros are not scheduled."
}

@test "status and digest write nothing" {
  cp "$BATS_TEST_DIRNAME/fixtures/ledger-2026-10-23.jsonl" "$TEAM_HOME/ledger.jsonl"
  schedule "$(ago 100)" 48
  opened "$(ago 60)" T30 retro
  local sum files
  sum=$(sha256sum "$TEAM_HOME/ledger.jsonl")
  files=$(find "$TEAM_HOME" -printf '%P\n' | sort)
  run_bin -0 team-retro status
  run_bin -0 team-retro status --json
  run_bin -0 team-retro digest
  run_bin -0 team-retro digest --json
  run_bin -0 team-retro digest T30
  run_bin -0 team-retro digest T30 --json
  assert_equal "$(sha256sum "$TEAM_HOME/ledger.jsonl")" "$sum"
  assert_equal "$(find "$TEAM_HOME" -printf '%P\n' | sort)" "$files"
  assert_equal "$(stub_calls claude)$(stub_calls gh)$(stub_calls curl)" ""
}

@test "malformed command lines are usage errors" {
  run_bin -2 team-retro
  assert_contains "$output" "usage: team-retro status [--json] | team-retro digest [T<n>] [--json]"
  run_bin -2 team-retro report
  run_bin -2 team-retro status T3
  run_bin -2 team-retro status --all
  run_bin -2 team-retro status --json --json
  run_bin -2 team-retro digest T3 T4
  run_bin -2 team-retro digest T0
  run_bin -2 team-retro digest t3
  run_bin -2 team-retro digest --all
  run_bin -2 team-retro --json status
}
