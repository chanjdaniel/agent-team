#!/usr/bin/env bats
# team-sweep: what the coordinator must not leave unattended (a task with no live worker, a
# worker waiting for input or idle without reporting, a team session outliving its task), from
# the ledger and the live session list alone.

load helpers/common

setup() {
  sandbox
  stub_reply claude '[]'
}

# ledger_line [jq options...] <filter>: append the line jq builds, standing in for its writer.
ledger_line() {
  jq -cn "$@" >>"$TEAM_HOME/ledger.jsonl"
}

# event <task> <kind> [<jq object of more fields>]
event() {
  ledger_line --arg t "$1" --arg e "$2" "{ts: \"2026-10-22T02:00:00Z\", task: \$t, event: \$e} + (${3:-{\}})"
}

opened() {
  event "$1" opened "{project: \"proj\", path: \"feature\", type: \"feat\", title: \"Work\",
    branch: \"feat/$1-work\", base: \"main\", base_sha: \"0123456\", worktree: \"/w/1\"}"
}

# launch <task> <role> <session>
launch() {
  ledger_line --arg t "$1" --arg r "$2" --arg s "$3" \
    '{ts: "2026-10-22T02:10:00Z", task: $t, event: "launch", role: $r, session: $s, worktree: "/w/1",
      toolkits: [], project: "proj", branch: "feat/\($t)-work"}'
}

# session <short id> <name> <status> [<state>]: one background session as claude agents --json
# lists it.
session() {
  jq -cn --arg id "$1" --arg name "$2" --arg status "$3" --arg state "${4:-}" \
    '{pid: 4242, cwd: "/w/1", kind: "background", startedAt: 1761098400000,
      sessionId: "\($id)-1111-4222-8333-444455556666", name: $name, status: $status, id: $id,
      state: (if $state == "" then null else $state end)}'
}

# sessions <session JSON>...: the live session list.
sessions() {
  stub_reply claude "$(jq -cs . <<<"$*")"
}

# The first <n> lines of a fixture ledger from the real one, as the sandbox ledger.
fixture_ledger() {
  head -n "$2" "$BATS_TEST_DIRNAME/fixtures/ledger-$1.jsonl" >"$TEAM_HOME/ledger.jsonl"
}

no_github() {
  assert_equal "$(stub_calls gh)$(stub_calls curl)" ""
}

# schedule <ts> <every_hours>: Daniel's retro schedule, logged on T26.
schedule() {
  ledger_line --arg ts "$1" --argjson every "$2" \
    '{ts: $ts, task: "T26", event: "retro-schedule", every_hours: $every, discord_message: "1563171945980370967"}'
}

# retro <ts> <task>: a retro task opened at <ts>.
retro() {
  ledger_line --arg ts "$1" --arg t "$2" \
    '{ts: $ts, task: $t, event: "opened", project: "agent-team", path: "retro", type: "research",
      title: "Retro", branch: "research/\($t)-retro", base: "dev", base_sha: "0123456", worktree: "/w/2"}'
}

# ago <hours>: the UTC time that many hours before now.
ago() {
  date -u -d "$1 hours ago" +%FT%TZ
}

# plus <time> <hours>: the UTC time that many hours after <time>.
plus() {
  date -u -d "@$(($(date -u -d "$1" +%s) + $2 * 3600))" +%FT%TZ
}

@test "nothing to find is exit 0 with nothing printed, and --json prints an empty list" {
  opened T3
  launch T3 builder 4f2a9c1e
  sessions "$(session 4f2a9c1e T3-builder busy working)"
  run_bin -0 --separate-stderr team-sweep
  assert_equal "$output$stderr" ""
  run_bin -0 team-sweep --json
  assert_equal "$(jq -c . <<<"$output")" "[]"
  assert_equal "$(stub_calls claude)" $'["agents","--json"]\n["agents","--json"]'
}

@test "an empty or absent ledger has nothing to find" {
  run_bin -0 team-sweep
  assert_equal "$output" ""
  rm "$TEAM_HOME/ledger.jsonl"
  run_bin -0 team-sweep
  assert_equal "$output" ""
}

@test "no-worker: an open task with no live session among its launches" {
  opened T3
  opened T4
  launch T4 planner 11111111
  launch T4 builder 22222222
  # T5 is legacy: a launch and no opened.
  launch T5 builder 33333333
  run_bin -1 --separate-stderr team-sweep
  assert_equal "$stderr" ""
  assert_equal "$output" "T3 no-worker: opened with no worker launched; next: launch one with team-worker, or log what is known with team-log
T4 no-worker: no live session among its 2 launches (latest T4-builder 22222222); next: read claude logs 22222222 for how it ended, then launch the next worker with team-worker or log what is known with team-log
T5 no-worker: no live session among its 1 launch (latest T5-builder 33333333); next: read claude logs 33333333 for how it ended, then launch the next worker with team-worker or log what is known with team-log"
  # One live session among the launches is enough, whichever it is.
  sessions "$(session 11111111 T4-planner busy working)"
  run_bin -1 team-sweep
  assert_equal "${#lines[@]}" 2
  assert_contains "$output" "T3 no-worker"
  assert_contains "$output" "T5 no-worker"
  no_github
}

@test "no-worker needs an opened or launch event, and a merged task is told to close" {
  event T6 thread '{discord_thread: "1563"}'
  event T6 plan-approved '{by: "daniel"}'
  run_bin -0 team-sweep
  opened T7
  launch T7 builder 22222222
  event T7 merged '{pr: 5, merge: "abcdef0", head: "1234567", by: "daniel"}'
  run_bin -1 team-sweep
  assert_equal "$output" "T7 no-worker: merged and not closed, with no live worker (latest T7-builder 22222222); next: close it with team-close T7"
}

@test "no-worker: every live worker idle since a report leaves the next step to the coordinator" {
  opened T8
  launch T8 planner 11111111
  sessions "$(session 11111111 T8-planner idle working)"
  event T8 "done" '{role: "planner", session: "11111111"}'
  run_bin -1 --separate-stderr team-sweep
  assert_equal "$output" "T8 no-worker: every live worker is idle with a ledger event since its launch (latest T8-planner 11111111); next: send it its next step or launch the next worker with team-worker, or log why the task waits with team-log"
  # The next worker at work, busy or not yet reporting, is enough.
  launch T8 builder 22222222
  sessions "$(session 11111111 T8-planner idle working)" "$(session 22222222 T8-builder busy working)"
  run_bin -0 team-sweep
  event T8 ticket-done '{ticket: "01", commits: ["abc1234"]}'
  run_bin -0 team-sweep
  # Once it is idle after its report, the coordinator owes the next step again.
  sessions "$(session 11111111 T8-planner idle working)" "$(session 22222222 T8-builder idle working)"
  run_bin -1 team-sweep
  assert_contains "$output" "T8 no-worker: every live worker is idle with a ledger event since its launch (latest T8-builder 22222222)"
  # Merged with idle workers is told to close, as with none.
  event T8 merged '{pr: 5, merge: "abcdef0", head: "1234567", by: "daniel"}'
  run_bin -1 team-sweep
  assert_equal "$output" "T8 no-worker: merged and not closed, with every live worker idle (latest T8-builder 22222222); next: close it with team-close T8"
  # A parked task waits for what it is parked on instead.
  event T8 waiting '{on: "Daniel", reason: "the walkthrough"}'
  run_bin -0 team-sweep
  no_github
}

@test "waiting-input: a live session of an open task that is blocked on input" {
  opened T12
  launch T12 builder 5fcd3daf
  event T12 ticket-done '{ticket: "1", commits: ["abc1234"]}'
  sessions "$(session 5fcd3daf T12-builder idle blocked)"
  run_bin -1 team-sweep
  assert_equal "$output" "T12 waiting-input: T12-builder 5fcd3daf is waiting for input; next: read claude logs 5fcd3daf, then answer it in one line or put the question to Daniel with team-log T12 asked"
  # With no event since its launch it is also idle and quiet, but it is one line, not two.
  sed -i '$d' "$TEAM_HOME/ledger.jsonl"
  run_bin -1 team-sweep
  assert_equal "${#lines[@]}" 1
  assert_contains "$output" "T12 waiting-input: T12-builder 5fcd3daf"
}

@test "silent: a live, idle session with no ledger event for its task since its launch" {
  opened T8
  launch T8 builder 4f2a9c1e
  sessions "$(session 4f2a9c1e T8-builder idle)"
  run_bin -1 team-sweep
  assert_equal "$output" "T8 silent: T8-builder 4f2a9c1e is idle with no ledger event since its launch at 2026-10-22T02:10:00Z; next: read claude logs 4f2a9c1e, then send it one line or log what is known with team-log"
  # Busy is not silent.
  sessions "$(session 4f2a9c1e T8-builder busy working)"
  run_bin -0 team-sweep
  # Any event of the task after the launch is a report; another task's event is not.
  sessions "$(session 4f2a9c1e T8-builder idle)"
  opened T9
  launch T9 builder 99999999
  sessions "$(session 4f2a9c1e T8-builder idle)" "$(session 99999999 T9-builder busy working)"
  run_bin -1 team-sweep
  assert_contains "$output" "T8 silent"
  event T8 ticket-done '{ticket: "1", commits: ["abc1234"]}'
  run_bin -1 team-sweep
  assert_equal "${#lines[@]}" 1
  assert_contains "$output" "T8 no-worker: every live worker is idle with a ledger event since its launch"
}

@test "silent judges each live session by its own latest launch" {
  opened T8
  launch T8 planner 11111111
  event T8 plan-approved '{by: "daniel"}'
  launch T8 builder 22222222
  sessions "$(session 11111111 T8-planner idle)" "$(session 22222222 T8-builder idle)"
  run_bin -1 team-sweep
  assert_equal "$output" "T8 silent: T8-builder 22222222 is idle with no ledger event since its launch at 2026-10-22T02:10:00Z; next: read claude logs 22222222, then send it one line or log what is known with team-log"
  # An interactive session has no short id: it is matched by the start of its full session id.
  stub_reply claude "$(jq -cn '[{kind: "interactive", sessionId: "22222222-aaaa-4bbb-8ccc-dddddddddddd",
    name: "T8-builder", status: "idle", cwd: "/w/1"}]')"
  run_bin -1 team-sweep
  assert_contains "$output" "T8 silent: T8-builder 22222222 is idle"
}

@test "a session launched again is judged by its latest launch" {
  opened T8
  launch T8 builder 22222222
  event T8 ticket-done '{ticket: "1", commits: ["abc1234"]}'
  launch T8 builder 22222222
  sessions "$(session 22222222 T8-builder idle)"
  run_bin -1 team-sweep
  assert_contains "$output" "T8 silent: T8-builder 22222222 is idle"
}

@test "findings come in task number order" {
  opened T10
  opened T9
  launch T9 reviewer 88888888
  launch T9 builder 99999999
  opened T2
  sessions "$(session 33333333 T3-builder idle)" "$(session 99999999 T9-builder idle)" \
    "$(session 88888888 T9-reviewer idle blocked)"
  run_bin -1 team-sweep --json
  assert_equal "$(jq -c 'map([.task, .kind])' <<<"$output")" \
    '[["T2","no-worker"],["T3","stray"],["T9","waiting-input"],["T9","silent"],["T10","no-worker"]]'
}

@test "stray: a live team session whose task is closed or not in the ledger" {
  opened T7
  launch T7 builder 77777777
  event T7 closed '{archive: [], returned: [], kept: []}'
  sessions "$(session 77777777 T7-builder idle)" "$(session 88888888 T42-reviewer busy working)" \
    "$(session 3169fcbd coordinator busy working)" "$(session 12345678 T7 idle)" \
    "$(session 23456789 conventioner-2b idle)"
  run_bin -1 team-sweep
  assert_equal "$output" "T7 stray: T7-builder 77777777 is live but T7 is closed; next: read claude logs 77777777 for anything left to log, then stop it with claude stop 77777777
T42 stray: T42-reviewer 88888888 is live but T42 is not in the ledger; next: read claude logs 88888888 for anything left to log, then stop it with claude stop 88888888"
}

@test "a closed task finds nothing but its stray sessions" {
  opened T7
  event T7 closed '{archive: [], returned: [], kept: []}'
  run_bin -0 team-sweep
}

@test "parked tasks never find no-worker, waiting-input or silent" {
  local kind
  for kind in held blocked paused; do
    : >"$TEAM_HOME/ledger.jsonl"
    opened T3
    launch T3 builder 11111111
    event T3 "$kind" '{reason: "waiting on Daniel"}'
    opened T4
    launch T4 builder 22222222
    launch T4 reviewer 33333333
    event T4 "$kind" '{reason: "waiting on Daniel"}'
    sessions "$(session 22222222 T4-builder idle blocked)" "$(session 33333333 T4-reviewer idle)"
    run_bin -0 team-sweep
  done
}

@test "a pending ask parks a task until it is answered" {
  opened T3
  launch T3 builder 11111111
  event T3 asked '{id: "q1", text: "Which bot?"}'
  event T3 asked '{id: "q2", text: "Which channel?"}'
  run_bin -0 team-sweep
  event T3 answered '{id: "q1", answer: "Hub"}'
  run_bin -0 team-sweep
  event T3 answered '{id: "q2", answer: "general"}'
  run_bin -1 team-sweep
  assert_contains "$output" "T3 no-worker"
}

@test "awaiting merge parks a task; a later findings review on the same head does not" {
  opened T3
  launch T3 reviewer 11111111
  event T3 pr '{url: "https://github.com/owner/proj/pull/5", head: "a1b2c3d"}'
  event T3 review '{verdict: "pass", head: "a1b2c3d4e5"}'
  run_bin -0 team-sweep
  event T3 review '{verdict: "findings", head: "a1b2c3d"}'
  run_bin -1 team-sweep
  assert_contains "$output" "T3 no-worker"
  no_github
}

@test "a resumed or a later launch ends a pause or a block, and resumed ends a hold" {
  opened T3
  launch T3 builder 11111111
  event T3 paused '{reason: "rate limit"}'
  run_bin -0 team-sweep
  launch T3 builder 22222222
  run_bin -1 team-sweep
  assert_contains "$output" "T3 no-worker: no live session among its 2 launches (latest T3-builder 22222222)"
  event T3 paused '{reason: "rate limit"}'
  run_bin -0 team-sweep
  event T3 resumed
  run_bin -1 team-sweep
  for kind in held blocked; do
    event T3 "$kind" '{reason: "OS update"}'
    run_bin -0 team-sweep
    event T3 resumed
    run_bin -1 team-sweep
  done
  # A later launch ends a block: the relaunched task with no live session has no worker.
  event T3 blocked '{reason: "a denied push"}'
  run_bin -0 team-sweep
  launch T3 builder 33333333
  run_bin -1 team-sweep
  assert_contains "$output" "T3 no-worker: no live session among its 3 launches (latest T3-builder 33333333)"
  # A later launch does not end a hold.
  event T3 held '{reason: "OS update"}'
  launch T3 builder 44444444
  run_bin -0 team-sweep
}

@test "waiting parks a task with no worker until the next launch or resumed" {
  opened T5
  launch T5 builder 11111111
  run_bin -1 team-sweep
  event T5 waiting '{on: "Daniel", reason: "restart the Docker daemons"}'
  run_bin -0 team-sweep
  event T5 "done" '{role: "builder", session: "11111111"}'
  run_bin -0 team-sweep
  launch T5 builder 22222222
  run_bin -1 team-sweep
  assert_contains "$output" "T5 no-worker"
  event T5 waiting '{on: "Daniel", reason: "walkthrough"}'
  run_bin -0 team-sweep
  event T5 resumed
  run_bin -1 team-sweep
  assert_contains "$output" "T5 no-worker"
}

@test "T4's real history: held finds nothing, resumed with no live reviewer is no-worker, merged is told to close, closed only strays" {
  fixture_ledger T4 57
  run_bin -0 team-sweep
  fixture_ledger T4 59
  run_bin -1 team-sweep
  assert_equal "$output" "T4 no-worker: no live session among its 30 launches (latest T4-reviewer 3c409a5e); next: read claude logs 3c409a5e for how it ended, then launch the next worker with team-worker or log what is known with team-log"
  sessions "$(session 3c409a5e T4-reviewer busy working)"
  run_bin -0 team-sweep
  # Merged with its reviewer idle, it is told to close.
  sessions "$(session 3c409a5e T4-reviewer idle)"
  fixture_ledger T4 60
  run_bin -1 team-sweep
  assert_equal "$output" "T4 no-worker: merged and not closed, with every live worker idle (latest T4-reviewer 3c409a5e); next: close it with team-close T4"
  # Closed with its reviewer still live, the reviewer is stray.
  fixture_ledger T4 61
  run_bin -1 team-sweep
  assert_equal "$output" "T4 stray: T4-reviewer 3c409a5e is live but T4 is closed; next: read claude logs 3c409a5e for anything left to log, then stop it with claude stop 3c409a5e"
  sessions
  run_bin -0 team-sweep
  no_github
}

@test "--json prints the findings as a list, each with its task, kind, session, name and next step" {
  opened T3
  opened T8
  launch T8 builder 4f2a9c1e
  sessions "$(session 4f2a9c1e T8-builder idle)" "$(session 88888888 T42-reviewer idle)"
  run_bin -1 --separate-stderr team-sweep --json
  assert_equal "$stderr" ""
  assert_equal "$(jq -c 'map([.task, .kind, .session, .name])' <<<"$output")" \
    '[["T3","no-worker",null,null],["T8","silent","4f2a9c1e","T8-builder"],["T42","stray","88888888","T42-reviewer"]]'
  assert_equal "$(jq -r '.[1].next' <<<"$output")" "read claude logs 4f2a9c1e, then send it one line or log what is known with team-log"
  local texts
  texts=$(jq -r '.[].text' <<<"$output")
  run_bin -1 team-sweep
  assert_equal "$texts" "$output"
}

@test "lines that are not JSON are skipped, and other kinds of events are read as they are" {
  opened T3
  echo 'not json' >>"$TEAM_HOME/ledger.jsonl"
  event T3 plan-ready
  launch T3 builder 11111111
  sessions "$(session 11111111 T3-builder idle)"
  run_bin -1 team-sweep
  assert_contains "$output" "T3 silent"
}

@test "a session list that cannot be read is exit 1 with the reason and nothing on stdout" {
  opened T3
  stub_reply claude "boom" 1
  run_bin -1 --separate-stderr team-sweep --json
  assert_equal "$output" ""
  assert_equal "$stderr" "team-sweep: cannot read the live session list (claude agents --json)"
}

@test "an unknown option or argument is a usage error" {
  run_bin -2 team-sweep --all
  assert_contains "$output" "usage: team-sweep [--json]"
  run_bin -2 team-sweep T3
}

@test "retro-due: none without a schedule, with every_hours 0, or before the due time" {
  retro "$(ago 200)" T2
  event T2 closed '{archive: [], returned: [], kept: []}'
  run_bin -0 team-sweep
  schedule "$(ago 150)" 48
  schedule "$(ago 100)" 0
  run_bin -0 team-sweep
  schedule "$(ago 47)" 48
  run_bin -0 team-sweep
  assert_equal "$output" ""
}

@test "retro-due: once due, one line after every task finding, alone still exit 1" {
  local since
  since=$(ago 50)
  schedule "$since" 48
  run_bin -1 --separate-stderr team-sweep
  assert_equal "$stderr" ""
  assert_equal "$output" "retro due since $(plus "$since" 48) (every 48h, last retro none): run the retro skill"

  local opened
  opened=$(ago 30)
  retro "$opened" T30
  event T30 closed '{archive: [], returned: [], kept: []}'
  schedule "$(ago 40)" 24
  opened T3
  sessions "$(session 88888888 T42-reviewer idle)"
  run_bin -1 team-sweep
  assert_equal "$output" "T3 no-worker: opened with no worker launched; next: launch one with team-worker, or log what is known with team-log
T42 stray: T42-reviewer 88888888 is live but T42 is not in the ledger; next: read claude logs 88888888 for anything left to log, then stop it with claude stop 88888888
retro due since $(plus "$opened" 24) (every 24h, last retro T30): run the retro skill"
}

@test "retro-due: none while a retro task is open" {
  schedule "$(ago 100)" 48
  retro "$(ago 60)" T31
  launch T31 planner 31313131
  sessions "$(session 31313131 T31-planner busy working)"
  run_bin -0 team-sweep
  # Its own no-worker finding still comes, with no retro-due after it.
  sessions
  run_bin -1 team-sweep --json
  assert_equal "$(jq -c 'map([.task, .kind])' <<<"$output")" '[["T31","no-worker"]]'
}

@test "retro-due in --json: task, session and name null, the retro skill as its next step" {
  local since
  since=$(ago 50)
  schedule "$since" 48
  opened T3
  run_bin -1 team-sweep --json
  assert_equal "$(jq -c '.[1]' <<<"$output")" "$(jq -cn --arg next "$(plus "$since" 48)" '{
    task: null, kind: "retro-due", session: null, name: null, next: "run the retro skill",
    text: "retro due since \($next) (every 48h, last retro none): run the retro skill"}')"
  assert_equal "$(jq -r '.[0].kind' <<<"$output")" "no-worker"
  no_github
}

@test "a ledger of 1,000 events sweeps in under two seconds" {
  jq -cn '
    range(1000) as $i | ($i % 50 + 1) as $n | "T\($n)" as $t
    | {ts: "2026-10-22T02:00:00Z", task: $t}
      + if $i < 50 then {event: "opened", project: "proj", path: "feature", type: "feat", title: "W",
          branch: "feat/\($t)-w", base: "main", base_sha: "0123456", worktree: "/w/\($n)"}
        elif $i % 7 == 0 then {event: "launch", role: "builder", session: "\($i + 10000000)",
          worktree: "/w/\($n)", toolkits: []}
        elif $i % 11 == 0 then {event: "pr", url: "https://github.com/o/p/pull/\($n)", head: "a1b2c3d"}
        else {event: "ticket-done", ticket: "\($i)", commits: ["abc1234"]} end' >"$TEAM_HOME/ledger.jsonl"
  assert_equal "$(wc -l <"$TEAM_HOME/ledger.jsonl")" 1000
  sessions "$(session 10000007 T8-builder idle)" "$(session 10000014 T15-builder idle blocked)"
  local start end
  start=$(date +%s%N)
  run_bin -1 team-sweep
  end=$(date +%s%N)
  ((${#lines[@]} > 40))
  (((end - start) < 2000000000))
}
