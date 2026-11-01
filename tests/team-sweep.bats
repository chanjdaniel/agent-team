#!/usr/bin/env bats
# team-sweep: what the coordinator must not leave unattended (a task with no live worker, a
# worker waiting for input or idle without reporting, a busy worker whose transcripts have gone
# unwritten past its limit, a team session outliving its task, the machine's slots, a retro due),
# from the ledger, the live session list, the stored slot readings and the transcripts' times.

load helpers/common

setup() {
  sandbox
  stub_reply claude '[]'
  printf '%s\n' '[proj]' 'repo = "owner/proj"' 'path = "projects/proj"' 'base = "main"' 'delivery = "direct-pr"' \
    'merge_method = "merge"' 'required_checks = []' 'task_dir = ".scratch/task"' 'docs = []' 'toolkits = []' \
    '[proj.pool]' 'provider = "git"' 'slots = ["slots/proj/1"]' >"$TEAM_HOME/projects.toml"
  # The machine has a task slot for every task a test opens, so only the slots tests find slots.
  SETTINGS=$HOME/.config/agent-team/slots.json
  READINGS=$HOME/.local/state/agent-team/slots/readings.jsonl
  mkdir -p "${SETTINGS%/*}"
  echo '{"cap": 100}' >"$SETTINGS"
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

# session <short id> <name> <status> [<state>] [<startedAt>]: one background session as claude
# agents --json lists it, started at <startedAt> (a JSON value; epoch milliseconds, 2025-10-22
# by default).
session() {
  jq -cn --arg id "$1" --arg name "$2" --arg status "$3" --arg state "${4:-}" --argjson started "${5:-1761098400000}" \
    '{pid: 4242, cwd: "/w/1", kind: "background", startedAt: $started,
      sessionId: "\($id)-1111-4222-8333-444455556666", name: $name, status: $status, id: $id,
      state: (if $state == "" then null else $state end)}'
}

# Transcript lines in Claude Code's shapes, at <minutes> ago, each holding a marker string where
# a tool's output, a message's text or a notification's summary goes, which no finding may carry.
# call <id> <minutes> <tool> [<command>] [background]: an assistant line starting a tool call.
call() {
  jq -cn --arg id "$1" --argjson m "$2" --arg tool "$3" --arg command "${4:-}" --arg bg "${5:-}" '
    {type: "assistant", timestamp: ((now | floor) - $m * 60 | strftime("%Y-%m-%dT%H:%M:%S.000Z")),
     message: {role: "assistant", content: [{type: "text", text: "TEXT-MARKER-1"},
       {type: "tool_use", id: $id, name: $tool,
        input: (if $command == "" then {url: "https://example.com/TEXT-MARKER-2"}
          else {command: $command, description: "TEXT-MARKER-3"} + (if $bg == "" then {} else {run_in_background: true} end) end)}]}}'
}

# result <id> <minutes> [background]: the user line with the call's result; with background, it
# carries a background task id, as for a call run in the background or moved there at its cap.
result() {
  jq -cn --arg id "$1" --argjson m "$2" --arg bg "${3:-}" '
    {type: "user", timestamp: ((now | floor) - $m * 60 | strftime("%Y-%m-%dT%H:%M:%S.000Z")),
     message: {role: "user", content: [{type: "tool_result", tool_use_id: $id, content: "OUTPUT-MARKER-1", is_error: false}]},
     toolUseResult: ({stdout: "OUTPUT-MARKER-2", stderr: "", interrupted: false}
       + if $bg == "" then {} else {backgroundTaskId: "b8k2m4q1", timedOutAfterMs: 600000} end)}'
}

# notified <id> <minutes> [user]: the task notification for a background call, as a queue
# operation, or with user as a user message.
notified() {
  jq -cn --arg id "$1" --argjson m "$2" --arg how "${3:-}" '
    ((now | floor) - $m * 60 | strftime("%Y-%m-%dT%H:%M:%S.000Z")) as $ts
    | "<task-notification>\n<task-id>b8k2m4q1</task-id>\n<tool-use-id>\($id)</tool-use-id>\n<status>completed</status>\n<summary>SUMMARY-MARKER</summary>\n</task-notification>" as $text
    | if $how == "user" then {type: "user", timestamp: $ts, message: {role: "user", content: $text}}
      else {type: "queue-operation", operation: "enqueue", timestamp: $ts, content: $text} end'
}

# no_markers: no marker string reached the output.
no_markers() {
  [[ $output != *MARKER* ]]
}

# sessions <session JSON>...: the live session list.
sessions() {
  stub_reply claude "$(jq -cs . <<<"$*")"
}

# transcript [-] <short id> <minutes> [<agent id>]: the transcript of the session that session
# gives <short id>, or of its subagent <agent id>, under the sandbox HOME as Claude Code keeps
# them, last written <minutes> ago: with -, the lines on stdin, else one user line and one reply.
transcript() {
  local lines=''
  if [[ $1 == - ]]; then
    lines=1
    shift
  fi
  local file=$HOME/.claude/projects/-w-1/$1-1111-4222-8333-444455556666
  if [[ -n ${3:-} ]]; then file=$file/subagents/agent-$3.jsonl; else file=$file.jsonl; fi
  mkdir -p "${file%/*}"
  if [[ -n $lines ]]; then
    cat >"$file"
  else
    jq -cn --arg s "$1-1111-4222-8333-444455556666" '
      {type: "user", timestamp: "2026-10-22T02:10:05Z", sessionId: $s, message: {role: "user", content: "Read your brief"}},
      {type: "assistant", timestamp: "2026-10-22T02:10:09Z", sessionId: $s,
       message: {role: "assistant", content: [{type: "text", text: "Reading it."}]}}' >"$file"
  fi
  touch -d "@$(($(date +%s) - $2 * 60))" "$file"
}

# The first <n> lines of a fixture ledger from the real one, as the sandbox ledger.
fixture_ledger() {
  head -n "$2" "$BATS_TEST_DIRNAME/fixtures/ledger-$1.jsonl" >"$TEAM_HOME/ledger.jsonl"
}

no_github() {
  assert_equal "$(stub_calls gh)$(stub_calls curl)" ""
}

# looks <list>...: the session list claude agents --json gives at each look of --wait, the last
# one kept from then on; the list "fail" is the command failing. The stub sleep moves on to the
# next look and, after 40 looks (20 minutes; LOOK_LIMIT sets another number), stops the watch
# with exit 99, so a watch that never ends shows as that exit. The uname stub keeps the stub sleep ahead of Homebrew's GNU sleep on
# macOS. A script $BATS_TEST_TMPDIR/at-look.<n> runs just before look <n>.
looks() {
  local i=0 list
  for list; do
    printf '%s\n' "$list" >"$BATS_TEST_TMPDIR/look.$i"
    i=$((i + 1))
  done
  echo 0 >"$BATS_TEST_TMPDIR/look"
  stub_script claude <<EOF
n=\$(cat "$BATS_TEST_TMPDIR/look")
((n < $i)) || n=$((i - 1))
list=\$(cat "$BATS_TEST_TMPDIR/look.\$n")
if [[ \$list == fail ]]; then
  echo "cannot reach the daemon" >&2
  exit 1
fi
printf '%s\n' "\$list"
EOF
  stub_command sleep uname
  stub_reply uname Linux
  stub_script sleep <<EOF
n=\$(cat "$BATS_TEST_TMPDIR/look")
((n < ${LOOK_LIMIT:-40})) || exit 99
echo \$((n + 1)) >"$BATS_TEST_TMPDIR/look"
if [[ -f "$BATS_TEST_TMPDIR/at-look.\$((n + 1))" ]]; then source "$BATS_TEST_TMPDIR/at-look.\$((n + 1))"; fi
EOF
}

# The number of waits --wait took, after checking each was 30 s.
waits() {
  local calls
  calls=$(stub_calls sleep)
  [[ -z $calls ]] || assert_equal "$(sort -u <<<"$calls")" '["30"]'
  grep -c . <<<"$calls" || true
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

# reserve_agent_team: home-pc, with agent-team registered with the code checkout as its primary,
# so it is the project the machine's slots keep one for.
reserve_agent_team() {
  code_checkout
  mkdir -p "$HOME/projects"
  ln -s "$CODE_CHECKOUT" "$HOME/projects/agent-team"
  printf '%s\n' '[agent-team]' 'repo = "owner/agent-team"' 'path = "projects/agent-team"' 'base = "dev"' \
    'delivery = "direct-pr"' 'merge_method = "merge"' 'required_checks = []' 'task_dir = ".scratch/task"' 'docs = []' \
    'toolkits = []' '[agent-team.pool]' 'provider = "git"' 'slots = ["slots/agent-team/1"]' >>"$TEAM_HOME/projects.toml"
  echo home-pc >"$HOME/.config/agent-team/machine"
}

# slots_reading <minutes> <others GiB>: append to READINGS a reading of the machine's load taken
# <minutes> ago on a machine shaped like home-pc (30.6 GiB, 12 cores), other programs using
# <others GiB>, the CPU not read.
slots_reading() {
  mkdir -p "${READINGS%/*}"
  jq -cn --arg at "$(date -u -d "@$(($(date +%s) - $1 * 60))" +%FT%TZ)" --argjson others "$2" '
    (30.6 * 1073741824 | floor) as $total | ($others * 1073741824 | floor) as $others
    | {at: $at, os: "linux", docker: true, cpu: null,
       memory: {total: $total, available: ($total - $others - 1073741824), team: 1073741824, others: $others}}' >>"$READINGS"
}

# reading_times <n>: the local HH:MM of the last <n> stored readings, joined by " and ".
reading_times() {
  tail -n "$1" "$READINGS" | jq -rs 'map(.at | fromdateiso8601 | strflocaltime("%H:%M")) | join(" and ")'
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
  # Blocked after the merge, a later part is still to come: the task is parked, not to be closed.
  event T7 blocked '{reason: "the second half waits on T31"}'
  run_bin -0 team-sweep
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

@test "stalled: a busy session of an open task whose transcript has not been written for 50 minutes" {
  opened T8
  launch T8 builder 4f2a9c1e
  sessions "$(session 4f2a9c1e T8-builder busy working)"
  transcript 4f2a9c1e 40
  run_bin -0 team-sweep
  transcript 4f2a9c1e 55
  run_bin -1 --separate-stderr team-sweep
  assert_equal "$stderr" ""
  assert_equal "$output" "T8 stalled: T8-builder 4f2a9c1e has written nothing for 55m with no tool call running; next: read claude logs 4f2a9c1e, then follow the recover-worker skill's stalled rung"
  transcript 4f2a9c1e 425
  run_bin -1 team-sweep
  assert_contains "$output" "T8-builder 4f2a9c1e has written nothing for 7h05m with no tool call running; next:"
}

@test "stalled: a subagent's transcript written since counts as the session's progress" {
  opened T8
  launch T8 builder 4f2a9c1e
  sessions "$(session 4f2a9c1e T8-builder busy working)"
  transcript 4f2a9c1e 120
  transcript 4f2a9c1e 5 a1b2c3d4e5f60718
  run_bin -0 team-sweep
  transcript 4f2a9c1e 60 a1b2c3d4e5f60718
  run_bin -1 team-sweep
  assert_contains "$output" "T8 stalled: T8-builder 4f2a9c1e has written nothing for 1h00m with no tool call running; next:"
}

@test "stalled: never for an idle or blocked session, a parked task, or a session with no transcript" {
  opened T8
  launch T8 builder 4f2a9c1e
  transcript 4f2a9c1e 120
  sessions "$(session 4f2a9c1e T8-builder idle)"
  run_bin -1 team-sweep
  assert_equal "${#lines[@]}" 1
  assert_contains "$output" "T8 silent: T8-builder 4f2a9c1e"
  sessions "$(session 4f2a9c1e T8-builder busy blocked)"
  run_bin -1 team-sweep
  assert_equal "${#lines[@]}" 1
  assert_contains "$output" "T8 waiting-input: T8-builder 4f2a9c1e"
  event T8 ticket-done '{ticket: "1", commits: ["abc1234"]}'
  sessions "$(session 4f2a9c1e T8-builder idle)"
  run_bin -1 team-sweep
  assert_equal "${#lines[@]}" 1
  assert_contains "$output" "T8 no-worker: every live worker is idle"
  sessions "$(session 4f2a9c1e T8-builder busy working)"
  event T8 held '{reason: "waiting on Daniel"}'
  run_bin -0 team-sweep
  # Not held, it is stalled; without its transcript, which cannot be found, it is not.
  event T8 resumed
  run_bin -1 team-sweep
  assert_contains "$output" "T8 stalled"
  rm "$HOME/.claude/projects/-w-1/4f2a9c1e-1111-4222-8333-444455556666.jsonl"
  run_bin -0 --separate-stderr team-sweep
  assert_equal "$stderr" ""
}

@test "stalled: --json carries it with its task, kind, session, name and next step" {
  opened T8
  launch T8 builder 4f2a9c1e
  sessions "$(session 4f2a9c1e T8-builder busy working)"
  transcript 4f2a9c1e 55
  run_bin -1 team-sweep --json
  assert_equal "$(jq -c 'map(del(.text))' <<<"$output")" \
    "[{\"task\":\"T8\",\"kind\":\"stalled\",\"session\":\"4f2a9c1e\",\"name\":\"T8-builder\",\"next\":\"read claude logs 4f2a9c1e, then follow the recover-worker skill's stalled rung\"}]"
  assert_equal "$(jq -r '.[0].text' <<<"$output")" \
    "T8 stalled: T8-builder 4f2a9c1e has written nothing for 55m with no tool call running; next: read claude logs 4f2a9c1e, then follow the recover-worker skill's stalled rung"
}

@test "stalled: --wait ends on a new one once it has stood for three minutes" {
  opened T8
  launch T8 builder 4f2a9c1e
  transcript 4f2a9c1e 1
  looks "[$(session 4f2a9c1e T8-builder busy working)]"
  # Written a minute before the first look, it has been quiet for 55 minutes at the second (0:30).
  echo "touch -d @\$((\$(date +%s) - 55 * 60)) '$HOME/.claude/projects/-w-1/4f2a9c1e-1111-4222-8333-444455556666.jsonl'" \
    >"$BATS_TEST_TMPDIR/at-look.1"
  run_bin -0 --separate-stderr team-sweep --wait
  assert_equal "$stderr" ""
  assert_contains "$output" "T8 stalled: T8-builder 4f2a9c1e has written nothing for 55m with no tool call running; next:"
  # Seen at the second look (0:30), it has stood three minutes at the eighth (3:30).
  assert_equal "$(waits)" 7
}

@test "stalled: a transcript quieter than the limit is never opened, so a malformed one changes nothing" {
  opened T8
  launch T8 builder 4f2a9c1e
  opened T9
  launch T9 builder 9a8b7c6d
  sessions "$(session 4f2a9c1e T8-builder busy working)" "$(session 9a8b7c6d T9-builder busy working)"
  printf 'not json\n\xff\xfe{"type":\n' | transcript - 4f2a9c1e 40
  printf '{"type":"user","timestamp":\n\xff\n' | transcript - 9a8b7c6d 40
  chmod 000 "$HOME/.claude/projects/-w-1/9a8b7c6d-1111-4222-8333-444455556666.jsonl"
  run_bin -0 --separate-stderr team-sweep
  assert_equal "$stderr" ""
  # Past it, a line that is not JSON is skipped.
  printf 'not json\n\xff\xfe{"type":\n' | transcript - 4f2a9c1e 55
  run_bin -1 --separate-stderr team-sweep
  assert_equal "$stderr" ""
  assert_equal "${#lines[@]}" 1
  assert_contains "$output" "T8 stalled: T8-builder 4f2a9c1e has written nothing for 55m with no tool call running; next:"
}

@test "stalled: T121's watch, moved to the background at its cap 7 hours ago, is named with both times and none of the transcript's content" {
  opened T121
  launch T121 builder 21de9a86
  sessions "$(session 21de9a86 T121-builder busy working)"
  { call toolu_01 435 Bash $'cd /w/1 && gh pr checks 217 --watch\necho done'; result toolu_01 425 background; } |
    transcript - 21de9a86 425
  run_bin -1 --separate-stderr team-sweep
  assert_equal "$stderr" ""
  assert_equal "$output" "T121 stalled: T121-builder 21de9a86 has written nothing for 7h05m, waiting on \"gh pr checks 217 --watch\" (Bash, in the background, running 7h15m); next: read claude logs 21de9a86, then follow the recover-worker skill's stalled rung"
  no_markers
  run_bin -1 team-sweep --json
  assert_equal "$(jq -r '.[0].kind' <<<"$output")" stalled
  no_markers
}

@test "stalled: a long test run in the background passes at 40 minutes, and is named at 55" {
  opened T8
  launch T8 builder 4f2a9c1e
  opened T9
  launch T9 builder 9a8b7c6d
  sessions "$(session 4f2a9c1e T8-builder busy working)" "$(session 9a8b7c6d T9-builder busy working)"
  { call toolu_01 41 Bash "npx playwright test" background; result toolu_01 41 background; } | transcript - 4f2a9c1e 40
  call toolu_02 40 Bash "tests/run" | transcript - 9a8b7c6d 40
  run_bin -0 team-sweep
  { call toolu_01 56 Bash "npx playwright test" background; result toolu_01 56 background; } | transcript - 4f2a9c1e 55
  call toolu_02 61 Bash "cd /w/1; tests/run" | transcript - 9a8b7c6d 55
  run_bin -1 team-sweep
  assert_equal "$output" "T8 stalled: T8-builder 4f2a9c1e has written nothing for 55m, waiting on \"npx playwright test\" (Bash, in the background, running 56m); next: read claude logs 4f2a9c1e, then follow the recover-worker skill's stalled rung
T9 stalled: T9-builder 9a8b7c6d has written nothing for 55m, waiting on \"tests/run\" (Bash, running 1h01m); next: read claude logs 9a8b7c6d, then follow the recover-worker skill's stalled rung"
}

@test "stalled: a gate run passes at 2 hours, and is named at 3 hours 10 minutes" {
  opened T8
  launch T8 builder 4f2a9c1e
  sessions "$(session 4f2a9c1e T8-builder busy working)"
  local gate='no-mistakes axi run --intent "the wait always ends"'
  { call toolu_01 121 Bash "$gate" background; result toolu_01 121 background; } | transcript - 4f2a9c1e 120
  run_bin -0 team-sweep
  { call toolu_01 191 Bash "$gate" background; result toolu_01 191 background; } | transcript - 4f2a9c1e 190
  run_bin -1 team-sweep
  assert_contains "$output" "T8-builder 4f2a9c1e has written nothing for 3h10m, waiting on \"$gate\" (Bash, in the background, running 3h11m); next:"
  # A word that only contains it is not the gate.
  { call toolu_01 191 Bash "grep -r no-mistakes-config ." background; result toolu_01 191 background; } |
    transcript - 4f2a9c1e 120
  run_bin -1 team-sweep
  assert_contains "$output" "T8-builder 4f2a9c1e has written nothing for 2h00m, waiting on \"grep -r no-mistakes-config .\""
}

@test "stalled: a wait on a PR's checks passes past 50 minutes, ending at 90, and is named at 1 hour 45 minutes" {
  opened T8
  launch T8 builder 4f2a9c1e
  sessions "$(session 4f2a9c1e T8-builder busy working)"
  local wait='/home/x/agent-team/bin/team-ci-wait https://github.com/owner/proj/pull/217 a1b2c3d'
  { call toolu_01 96 Bash "$wait" background; result toolu_01 96 background; } | transcript - 4f2a9c1e 95
  run_bin -0 team-sweep
  { call toolu_01 106 Bash "$wait" background; result toolu_01 106 background; } | transcript - 4f2a9c1e 105
  run_bin -1 team-sweep
  assert_contains "$output" "T8-builder 4f2a9c1e has written nothing for 1h45m, waiting on \"$wait\" (Bash, in the background, running 1h46m); next:"
}

@test "stalled: the gate, team-thread wait and team-ci-wait limits read the whole command, though only its first line is named" {
  opened T8
  launch T8 builder 4f2a9c1e
  sessions "$(session 4f2a9c1e T8-builder busy working)"
  call toolu_01 121 Bash $'export A=1\nno-mistakes run' | transcript - 4f2a9c1e 120
  run_bin -0 team-sweep
  call toolu_01 121 Bash "$(printf 'x%.0s' {1..100}) && no-mistakes run" | transcript - 4f2a9c1e 120
  run_bin -0 team-sweep
  call toolu_01 361 Bash $'set -e\nteam-thread wait T8 1563171945980370967' | transcript - 4f2a9c1e 360
  run_bin -0 team-sweep
  call toolu_01 96 Bash $'cd /w/1\nteam-ci-wait https://github.com/owner/proj/pull/217' | transcript - 4f2a9c1e 95
  run_bin -0 team-sweep
  call toolu_01 191 Bash $'export A=1\nno-mistakes run' | transcript - 4f2a9c1e 190
  run_bin -1 team-sweep
  assert_contains "$output" "T8-builder 4f2a9c1e has written nothing for 3h10m, waiting on \"export A=1\" (Bash, running 3h11m); next:"
}

@test "stalled: never while a call waits on Daniel with team-thread wait, whatever else runs" {
  opened T8
  launch T8 planner 4f2a9c1e
  sessions "$(session 4f2a9c1e T8-planner busy working)"
  { call toolu_01 400 Bash "npx playwright test" background; result toolu_01 400 background
    call toolu_02 361 Bash '/home/x/agent-team/bin/team-thread wait T8 1563171945980370967'; } | transcript - 4f2a9c1e 360
  run_bin -0 team-sweep
}

@test "stalled: a session with nothing running says so, and a call that ended is not running" {
  opened T8
  launch T8 builder 4f2a9c1e
  sessions "$(session 4f2a9c1e T8-builder busy working)"
  { call toolu_01 60 Bash "tests/run bats"; result toolu_01 56
    call toolu_02 58 Bash "npx playwright test" background; result toolu_02 58 background; notified toolu_02 57
    call toolu_03 57 Bash "team-checks" background; result toolu_03 57 background; notified toolu_03 56 user
    call toolu_04 56 WebFetch; result toolu_04 55; } | transcript - 4f2a9c1e 55
  run_bin -1 team-sweep
  assert_equal "$output" "T8 stalled: T8-builder 4f2a9c1e has written nothing for 55m with no tool call running; next: read claude logs 4f2a9c1e, then follow the recover-worker skill's stalled rung"
  no_markers
}

@test "stalled: a call started before the session's process is not running" {
  opened T8
  launch T8 builder 4f2a9c1e
  # Relaunched 30 minutes ago: the watch an hour ago belongs to the session's earlier process.
  sessions "$(session 4f2a9c1e T8-builder busy working "$((($(date +%s) - 30 * 60) * 1000))")"
  { call toolu_01 60 Bash "gh pr checks 217 --watch" background; result toolu_01 60 background
    call toolu_02 56 Read; } | transcript - 4f2a9c1e 55
  run_bin -1 team-sweep
  assert_contains "$output" "has written nothing for 55m with no tool call running; next:"
}

@test "stalled: a subagent's hung call is named as a subagent's, before the Agent call waiting on it, and other tools by name" {
  opened T8
  launch T8 builder 4f2a9c1e
  sessions "$(session 4f2a9c1e T8-builder busy working)"
  call toolu_01 70 Agent | transcript - 4f2a9c1e 70
  call toolu_02 65 Bash "cd /w/1 && npm test -- --watch" | transcript - 4f2a9c1e 60 a1b2c3d4e5f60718
  run_bin -1 team-sweep
  assert_contains "$output" "has written nothing for 1h00m, waiting on \"npm test -- --watch\" (Bash in a subagent, running 1h05m), and 1 more running; next:"
  call toolu_02 65 WebFetch | transcript - 4f2a9c1e 60 a1b2c3d4e5f60718
  run_bin -1 team-sweep
  assert_contains "$output" "has written nothing for 1h00m, waiting on WebFetch (in a subagent, running 1h05m), and 1 more running; next:"
  rm "$HOME/.claude/projects/-w-1/4f2a9c1e-1111-4222-8333-444455556666/subagents/agent-a1b2c3d4e5f60718.jsonl"
  run_bin -1 team-sweep
  assert_contains "$output" "has written nothing for 1h10m, waiting on Agent (running 1h10m); next:"
}

@test "stalled: of two running calls the foreground one, which holds the turn, is named" {
  opened T8
  launch T8 builder 4f2a9c1e
  sessions "$(session 4f2a9c1e T8-builder busy working)"
  { call toolu_01 90 Bash "npx playwright test" background; result toolu_01 90 background
    call toolu_02 60 Bash "$(printf 'x%.0s' {1..120})"; } | transcript - 4f2a9c1e 55
  run_bin -1 team-sweep
  assert_contains "$output" "has written nothing for 55m, waiting on \"$(printf 'x%.0s' {1..100})\" (Bash, running 1h00m), and 1 more running; next:"
}

@test "stalled: the reader prints only times, tool names, ids, commands, their limits and the background marks" {
  sessions_json=$(jq -cs . <<<"$(session 4f2a9c1e T8-builder busy working)")
  { call toolu_01 90 Bash "npx playwright test" background; result toolu_01 90 background; notified toolu_01 80
    call toolu_02 70 Bash "tests/run" background; result toolu_02 70 background; notified toolu_02 65 user
    call toolu_03 60 WebFetch; result toolu_03 59
    call toolu_04 58 Bash "gh pr checks 217 --watch" background; result toolu_04 58 background
    call toolu_05 57 Bash $'export A=1\nno-mistakes run' background; result toolu_05 57 background
    call toolu_06 56 Read; } | transcript - 4f2a9c1e 55
  run --separate-stderr "$REPO_ROOT/bin/lib/session-activity" --parse-after 3000 <<<"$sessions_json"
  assert_equal "$status" 0
  assert_equal "$stderr" ""
  no_markers
  assert_equal "$(jq -c '.[] | {quiet: (.quiet / 60 | floor), running: [.running[] | del(.since, .seconds)]}' <<<"$output")" \
    '{"quiet":55,"running":[{"tool":"Bash","command":"gh pr checks 217 --watch","limit":null,"background":true,"subagent":false},{"tool":"Bash","command":"export A=1","limit":"gate","background":true,"subagent":false},{"tool":"Read","command":null,"limit":null,"background":false,"subagent":false}]}'
  assert_equal "$(jq -r '.[].running[0] | "\(.since | test("^[0-9-]+T[0-9:.]+Z$")) \(.seconds / 60 | floor)"' <<<"$output")" "true 58"
}

@test "activity: a reader that fails is a finding naming its reason, and the other findings still come" {
  opened T3
  opened T8
  launch T8 builder 4f2a9c1e
  sessions "$(session 4f2a9c1e T8-builder busy working)"
  transcript 4f2a9c1e 55
  # python3 runs the reader as Python 3.9 would, and every other script (team-slots) as itself.
  local python
  python=$(command -v python3)
  stub_command python3
  stub_script python3 <<EOF
if [[ \${2:-} == */session-activity ]]; then
  echo "session-activity: needs Python 3.11 or later, but runs under Python 3.9.6 ($HOME/.pyenv/bin/python3)" >&2
  exit 1
fi
exec "$python" "\$@"
EOF
  run_bin -1 --separate-stderr team-sweep
  assert_equal "$stderr" ""
  assert_equal "$output" "T3 no-worker: opened with no worker launched; next: launch one with team-worker, or log what is known with team-log
activity: session-activity: needs Python 3.11 or later, but runs under Python 3.9.6 (~/.pyenv/bin/python3), so no busy worker is found stalled: fix what session-activity names"
  run_bin -1 team-sweep --json
  assert_equal "$(jq -c '.[1] | del(.text)' <<<"$output")" \
    '{"task":null,"kind":"activity","session":null,"name":null,"next":"fix what session-activity names"}'
  # A reader that prints no JSON object is as one that fails.
  stub_script python3 <<EOF
if [[ \${2:-} == */session-activity ]]; then
  echo '[]'
  exit 0
fi
exec "$python" "\$@"
EOF
  run_bin -1 --separate-stderr team-sweep
  assert_equal "$stderr" ""
  assert_equal "${lines[1]}" "activity: session-activity printed no JSON object, so no busy worker is found stalled: fix what session-activity names"
}

@test "activity: a session with a transcript and no startedAt in epoch milliseconds fails the reader closed" {
  opened T8
  launch T8 builder 4f2a9c1e
  transcript 4f2a9c1e 1
  transcript 9a8b7c6d 1
  local started
  for started in null '"2026-10-22T02:00:00Z"' 1761098400000.5 true -1; do
    sessions "$(session 4f2a9c1e T8-builder busy working)" "$(session 9a8b7c6d other idle '' "$started")"
    run_bin -1 --separate-stderr team-sweep
    assert_equal "$stderr" ""
    assert_equal "$output" "activity: session-activity: session 9a8b7c6d has no startedAt in epoch milliseconds in the session list, which tells its running tool calls from an earlier process's, so no busy worker is found stalled: fix what session-activity names"
  done
  # Missing, it fails the same; a session with no transcript is never read, so it does not matter.
  sessions "$(session 4f2a9c1e T8-builder busy working)" "$(session 9a8b7c6d other idle | jq -c 'del(.startedAt)')"
  run_bin -1 team-sweep
  assert_contains "$output" "activity: session-activity: session 9a8b7c6d has no startedAt"
  rm "$HOME/.claude/projects/-w-1/9a8b7c6d-1111-4222-8333-444455556666.jsonl"
  run_bin -0 team-sweep
}

@test "activity: --wait ends on a reader that starts failing once it has stood for three minutes" {
  opened T8
  launch T8 builder 4f2a9c1e
  transcript 4f2a9c1e 1
  looks "[$(session 4f2a9c1e T8-builder busy working)]" "[$(session 4f2a9c1e T8-builder busy working null)]"
  run_bin -0 --separate-stderr team-sweep --wait
  assert_equal "$stderr" ""
  assert_contains "$output" "activity: session-activity: session 4f2a9c1e has no startedAt"
  # Seen at the second look (0:30), it has stood three minutes at the eighth (3:30).
  assert_equal "$(waits)" 7
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

@test "the load check's T0 sessions are never stray: T0 is the load check, not a task" {
  sessions "$(session 6f93fe38 T0-ops busy blocked)" "$(session 4f2a9c1e T0-planner idle)"
  run_bin -0 team-sweep
  assert_equal "$output" ""
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

@test "a merge ask settled by a merge-approved naming its URL no longer parks the task" {
  opened T3
  launch T3 builder 11111111
  event T3 asked '{id: "merge", text: "merge it? https://github.com/o/r/pull/5 at 0123456"}'
  run_bin -0 team-sweep
  event T3 merge-approved '{url: "https://github.com/o/r/pull/5", discord_message: "1563000000000000001"}'
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

# Task <task>'s PR 5 of proj reviewed and passed at its head, with Daniel's plan-time word on proj
# logged, answering the plan ask.
preapproved_pr() {
  event "$1" asked '{id: "plan", text: "Approve the plan, and its merge?"}'
  event "$1" merge-preapproved '{project: "proj", ask: "plan", discord_message: "1563000000000000001", scope: ["src/"]}'
  event "$1" plan-approved '{by: "Daniel"}'
  event "$1" pr '{url: "https://github.com/owner/proj/pull/5", head: "a1b2c3d"}'
  event "$1" review '{verdict: "pass", head: "a1b2c3d4e5", findings: {blocking: 0, correctness: 0, security: 0, "real-data": 0, "note-change": 0, "note-before": 0}, guarded: []}'
}

@test "merge-due: an awaiting-merge task with Daniel's standing plan-time word and nothing else parking it" {
  opened T3
  launch T3 reviewer 11111111
  preapproved_pr T3
  sessions "$(session 11111111 T3-reviewer idle)"
  run_bin -1 team-sweep
  assert_equal "$output" "T3 merge-due: awaiting the merge of https://github.com/owner/proj/pull/5 on Daniel's plan-time word on proj, with no ask open; next: run team-merge T3; on a refusal, ask Daniel for the per-head word with team-ask"
  run_bin -1 team-sweep --json
  assert_equal "$(jq -c 'map([.task, .kind, .session, .name, .next])' <<<"$output")" \
    '[["T3","merge-due",null,null,"run team-merge T3; on a refusal, ask Daniel for the per-head word with team-ask"]]'
  no_github

  # The per-head ask naming the PR's URL parks it again, until the merge-approved settles it.
  event T3 asked '{id: "merge", text: "Merge https://github.com/owner/proj/pull/5 at a1b2c3d?"}'
  run_bin -0 team-sweep
  event T3 merge-approved '{url: "https://github.com/owner/proj/pull/5", discord_message: "1563000000000000002", head: "a1b2c3d"}'
  run_bin -1 team-sweep
  assert_contains "$output" "T3 merge-due"

  # Merged, it is told to close.
  event T3 merged '{pr: 5, merge: "9999999", head: "a1b2c3d", by: "1563000000000000002", url: "https://github.com/owner/proj/pull/5"}'
  run_bin -1 team-sweep
  assert_contains "$output" "T3 no-worker: merged and not closed"
}

@test "merge-due: none once the word is withdrawn, while another park stands, or before the review passed" {
  opened T3
  launch T3 builder 11111111
  preapproved_pr T3
  run_bin -1 team-sweep
  assert_contains "$output" "T3 merge-due"

  # A withdrawn word leaves the task awaiting Daniel's per-head word: parked.
  event T3 merge-preapproval-withdrawn '{project: "proj", discord_message: "1563000000000000002"}'
  run_bin -0 team-sweep
  event T3 merge-preapproved '{project: "proj", ask: "plan", discord_message: "1563000000000000003", scope: ["src/"]}'
  run_bin -1 team-sweep
  assert_contains "$output" "T3 merge-due"

  # A pause, a wait, an open ask, a hold or a block parks it.
  event T3 paused '{reason: "rate limit"}'
  run_bin -0 team-sweep
  event T3 resumed
  event T3 waiting '{on: "Daniel", reason: "a word on the release"}'
  run_bin -0 team-sweep
  event T3 resumed
  event T3 asked '{id: "q1", text: "Which name?"}'
  run_bin -0 team-sweep
  event T3 answered '{id: "q1", answer: "Kim"}'
  for kind in held blocked; do
    event T3 "$kind" '{reason: "OS update"}'
    run_bin -0 team-sweep
    event T3 resumed
  done
  run_bin -1 team-sweep
  assert_equal "$output" "T3 merge-due: awaiting the merge of https://github.com/owner/proj/pull/5 on Daniel's plan-time word on proj, with no ask open; next: run team-merge T3; on a refusal, ask Daniel for the per-head word with team-ask"

  # A new head under review is no merge yet: the task's worker findings come back.
  event T3 pr '{url: "https://github.com/owner/proj/pull/5", head: "b2c3d4e"}'
  run_bin -1 team-sweep
  assert_equal "$output" "T3 no-worker: no live session among its 1 launch (latest T3-builder 11111111); next: read claude logs 11111111 for how it ended, then launch the next worker with team-worker or log what is known with team-log"
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
  assert_contains "$output" "usage: team-sweep [--json | --wait]"
  run_bin -2 team-sweep T3
  run_bin -2 team-sweep --wait --json
  run_bin -2 team-sweep --wait --wait
}

@test "--wait ends once a new finding has stood for three minutes, printing every finding and exiting 0" {
  opened T3
  launch T3 builder 4f2a9c1e
  # T42's stray is there at the first look; T3's builder ends right after it.
  local stray
  stray=$(session 88888888 T42-reviewer idle)
  looks "[$(session 4f2a9c1e T3-builder busy working),$stray]" "[$stray]"
  run_bin -0 --separate-stderr team-sweep --wait
  assert_equal "$stderr" ""
  assert_equal "$output" "T3 no-worker: no live session among its 1 launch (latest T3-builder 4f2a9c1e); next: read claude logs 4f2a9c1e for how it ended, then launch the next worker with team-worker or log what is known with team-log
T42 stray: T42-reviewer 88888888 is live but T42 is not in the ledger; next: read claude logs 88888888 for anything left to log, then stop it with claude stop 88888888"
  # Seen at the second look (0:30), it has stood three minutes at the eighth (3:30).
  assert_equal "$(waits)" 7
  assert_equal "$(stub_calls claude | grep -c .)" 8
  no_github
}

@test "--wait never ends within 20 minutes on a finding there at its first look, and one that clears and comes back is new" {
  opened T3
  launch T3 builder 4f2a9c1e
  looks '[]'
  run_bin -99 team-sweep --wait
  assert_equal "$output" ""
  assert_equal "$(waits)" 41

  # Gone at the third look, back at the fourth (1:30): it ends three minutes later.
  : >"$STUB_CALLS/sleep.log"
  looks '[]' '[]' "[$(session 4f2a9c1e T3-builder busy working)]" '[]'
  run_bin -0 team-sweep --wait
  assert_contains "$output" "T3 no-worker: no live session among its 1 launch"
  assert_equal "$(waits)" 9
}

@test "--wait ends on a finding there at its first look once it has stood for 30 minutes" {
  opened T3
  launch T3 builder 4f2a9c1e
  opened T4
  launch T4 builder 5a5a5a5a
  # T3 has no worker from the first look on, as one the coordinator just acted on; T4's goes at
  # 0:30, a new finding, which clears again before it has stood three minutes.
  local t4
  t4=$(session 5a5a5a5a T4-builder busy working)
  export LOOK_LIMIT=80
  looks "[$t4]" '[]' '[]' "[$t4]"
  run_bin -0 team-sweep --wait
  assert_equal "$output" "T3 no-worker: no live session among its 1 launch (latest T3-builder 4f2a9c1e); next: read claude logs 4f2a9c1e for how it ended, then launch the next worker with team-worker or log what is known with team-log"
  assert_equal "$(waits)" 60

  # Cleared at 10:00 and back at 10:30, it is new from then: three minutes later, it ends.
  : >"$STUB_CALLS/sleep.log"
  local -a lists=()
  for _ in $(seq 20); do lists+=("[$t4]"); done
  lists+=("[$t4,$(session 4f2a9c1e T3-builder busy working)]" "[$t4]")
  looks "${lists[@]}"
  run_bin -0 team-sweep --wait
  assert_contains "$output" "T3 no-worker:"
  assert_equal "$(waits)" 27
}

@test "--wait never ends on a finding that clears within three minutes" {
  opened T3
  launch T3 builder 4f2a9c1e
  local busy
  busy=$(session 4f2a9c1e T3-builder busy working)
  # No worker from 0:30 to 3:00, as between a DONE and the next launch, then one again.
  looks "[$busy]" '[]' '[]' '[]' '[]' '[]' '[]' "[$busy]"
  run_bin -99 team-sweep --wait
  assert_equal "$output" ""
  assert_equal "$(waits)" 41
}

@test "--wait counts a retro coming due like any other finding" {
  local opened
  opened=$(ago 60)
  schedule "$(ago 100)" 48
  retro "$opened" T31
  launch T31 planner 31313131
  looks "[$(session 31313131 T31-planner busy working)]" '[]'
  # The retro task closes just before the second look, its planner gone, and the next retro is due.
  cat >"$BATS_TEST_TMPDIR/at-look.1" <<EOF
echo '{"ts": "$(ago 1)", "task": "T31", "event": "closed", "archive": [], "returned": [], "kept": []}' \
  >>"$TEAM_HOME/ledger.jsonl"
EOF
  run_bin -0 team-sweep --wait
  assert_equal "$output" "retro due since $(plus "$opened" 48) (every 48h, last retro T31): run the retro skill"
  assert_equal "$(waits)" 7
}

@test "--wait exits 1 with the reason once the session list has been unreadable for five minutes running" {
  opened T3
  launch T3 builder 4f2a9c1e
  # Unreadable for 4:30, read once, then unreadable from 5:00: it gives up at 10:00.
  looks fail fail fail fail fail fail fail fail fail "[$(session 4f2a9c1e T3-builder busy working)]" fail
  run_bin -1 --separate-stderr team-sweep --wait
  assert_equal "$output" ""
  assert_equal "$stderr" "team-sweep: cannot read the live session list (claude agents --json), for 5 minutes running"
  assert_equal "$(waits)" 20
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

@test "slots: none while the effective cap is the cap and no more slots are held than it" {
  reserve_agent_team
  echo '{"cap": 2}' >"$SETTINGS"
  opened T3
  launch T3 builder 4f2a9c1e
  opened T4
  launch T4 builder 5a5a5a5a
  sessions "$(session 4f2a9c1e T3-builder busy working)" "$(session 5a5a5a5a T4-builder busy working)"
  slots_reading 5 8
  slots_reading 0 8
  run_bin -0 --separate-stderr team-sweep
  assert_equal "$output$stderr" ""
}

@test "slots: an effective cap below the cap is one line after every task finding and before retro-due" {
  reserve_agent_team
  echo '{"cap": 10}' >"$SETTINGS"
  slots_reading 5 18
  slots_reading 0 18
  run_bin -1 --separate-stderr team-sweep
  assert_equal "$stderr" ""
  local line
  line="slots: home-pc: 0 of 10 task slots held, 1 kept for agent-team (agent-team holds 0); effective 5; lowered by memory: other programs use 18.0 GiB of 30.6 GiB, leaving room for 5 tasks of 1.25 GiB after 6 GiB kept (the readings of $(reading_times 2)): new tasks wait; tell Daniel which wait"
  assert_equal "$output" "$line"

  local since
  since=$(ago 50)
  schedule "$since" 48
  opened T3
  sessions "$(session 88888888 T42-reviewer idle)"
  line=${line/0 of 10/1 of 10}
  run_bin -1 team-sweep
  assert_equal "$output" "T3 no-worker: opened with no worker launched; next: launch one with team-worker, or log what is known with team-log
T42 stray: T42-reviewer 88888888 is live but T42 is not in the ledger; next: read claude logs 88888888 for anything left to log, then stop it with claude stop 88888888
$line
retro due since $(plus "$since" 48) (every 48h, last retro none): run the retro skill"
  run_bin -1 team-sweep --json
  assert_equal "$(jq -c '.[2]' <<<"$output")" "$(jq -cn --arg text "$line" '{
    task: null, kind: "slots", session: null, name: null, next: "tell Daniel which wait", text: $text}')"
  no_github
}

@test "slots: more slots held than the effective cap is a finding, after the lowering when both" {
  reserve_agent_team
  echo '{"cap": 2}' >"$SETTINGS"
  local n
  for n in 3 4 5; do
    opened "T$n"
    launch "T$n" builder "${n}0000000"
  done
  sessions "$(session 30000000 T3-builder busy working)" "$(session 40000000 T4-builder busy working)" \
    "$(session 50000000 T5-builder busy working)"
  run_bin -1 team-sweep
  assert_equal "$output" "slots: home-pc: 3 of 2 task slots held, 1 kept for agent-team (agent-team holds 0); effective 2; 3 held, over the effective cap of 2: new tasks wait; tell Daniel which wait"

  echo '{"cap": 10}' >"$SETTINGS"
  slots_reading 5 24
  slots_reading 0 24
  run_bin -1 team-sweep
  assert_equal "$output" "slots: home-pc: 3 of 10 task slots held, 1 kept for agent-team (agent-team holds 0); effective 1; lowered by memory: other programs use 24.0 GiB of 30.6 GiB, leaving room for 0 tasks of 1.25 GiB after 6 GiB kept (the readings of $(reading_times 2)), and never below the 1 kept for agent-team; 3 held, over the effective cap of 1: new tasks wait; tell Daniel which wait"
}

@test "slots: the sweep never takes a reading of the machine's load, however old the stored ones" {
  reserve_agent_team
  opened T3
  run_bin -1 team-sweep
  [[ ! -e ${READINGS%/*} ]]
  slots_reading 40 18
  slots_reading 35 18
  local before
  before=$(cat "$READINGS")
  run_bin -1 team-sweep --json
  assert_equal "$(jq -c 'map(.kind)' <<<"$output")" '["no-worker"]'
  assert_equal "$(cat "$READINGS")" "$before"
  [[ ! -e ${READINGS%/*}/procs.tsv ]]
}

@test "slots: a team-slots that fails is a finding naming its reason, and the task findings still come" {
  echo '{"cap": 0}' >"$SETTINGS"
  opened T3
  run_bin -1 --separate-stderr team-slots status --stored
  local error=${stderr/"$HOME/"/"~/"}
  assert_contains "$error" "team-slots: ~/.config/agent-team/slots.json"
  run_bin -1 --separate-stderr team-sweep
  assert_equal "$stderr" ""
  assert_equal "$output" "T3 no-worker: opened with no worker launched; next: launch one with team-worker, or log what is known with team-log
slots: $error: fix what team-slots names"
  run_bin -1 team-sweep --json
  assert_equal "$(jq -c '.[1] | del(.text)' <<<"$output")" \
    '{"task":null,"kind":"slots","session":null,"name":null,"next":"fix what team-slots names"}'
}

@test "--wait counts the slots finding like any other: three minutes when new, 30 when there at the first look" {
  reserve_agent_team
  echo '{"cap": 10}' >"$SETTINGS"
  looks '[]'
  # A high reading, then two low ones that come just before the third look (1:00).
  slots_reading 5 8
  READINGS=$BATS_TEST_TMPDIR/low slots_reading 0 18
  READINGS=$BATS_TEST_TMPDIR/low slots_reading 0 18
  echo "cat '$BATS_TEST_TMPDIR/low' >>'$READINGS'" >"$BATS_TEST_TMPDIR/at-look.2"
  run_bin -0 --separate-stderr team-sweep --wait
  assert_equal "$stderr" ""
  assert_equal "$output" "slots: home-pc: 0 of 10 task slots held, 1 kept for agent-team (agent-team holds 0); effective 5; lowered by memory: other programs use 18.0 GiB of 30.6 GiB, leaving room for 5 tasks of 1.25 GiB after 6 GiB kept (the readings of $(reading_times 2)): new tasks wait; tell Daniel which wait"
  # Seen at the third look (1:00), it has stood three minutes at the ninth (4:00).
  assert_equal "$(waits)" 8

  # Lowered at the first look, as one the coordinator just told Daniel of, it ends at 30 minutes.
  : >"$STUB_CALLS/sleep.log"
  rm "$BATS_TEST_TMPDIR/at-look.2"
  LOOK_LIMIT=80 looks '[]'
  run_bin -0 team-sweep --wait
  assert_contains "$output" "slots: home-pc: 0 of 10 task slots held"
  assert_equal "$(waits)" 60
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
  # Ten busy builders, each with a transcript of 20,000 lines (about 6 MB) written a minute ago.
  local busy=() i line
  for i in 56 63 70 77 84 91 98 105 112 119; do
    busy+=("$(session $((i + 10000000)) "T$((i % 50 + 1))-builder" busy working)")
    line=$(jq -cn --arg s "$((i + 10000000))-1111-4222-8333-444455556666" '{type: "assistant",
      timestamp: "2026-10-22T02:10:09Z", sessionId: $s, message: {role: "assistant", content: [{type: "tool_use",
      id: "toolu_01", name: "Bash", input: {command: "tests/run bats"}}, {type: "text", text: ("x" * 60)}]}}')
    yes "$line" | head -n 20000 | transcript - $((i + 10000000)) 1
  done
  sessions "$(session 10000007 T8-builder idle)" "$(session 10000014 T15-builder idle blocked)" "${busy[@]}"
  local start end
  start=$(date +%s%N)
  run_bin -1 team-sweep
  end=$(date +%s%N)
  # Every task but the ten busy builders' finds something.
  assert_equal "${#lines[@]}" 40
  (((end - start) < 2000000000))
}

# level_task <task> <opened at HH:MM> [<role>:<session>]: <task> opened at that time on
# 2026-10-22 in /w/<n>, with its worker launched a minute later.
level_task() {
  ledger_line --arg t "$1" --arg ts "2026-10-22T$2:00Z" '{ts: $ts, task: $t, event: "opened", project: "proj",
    path: "feature", type: "feat", title: "Work", branch: "feat/\($t)-work", base: "main", base_sha: "0123456",
    worktree: "/w/\($t[1:])"}'
  [[ -z ${3:-} ]] || ledger_line --arg t "$1" --arg ts "2026-10-22T${2%:*}:59:00Z" --arg r "${3%%:*}" --arg s "${3#*:}" \
    '{ts: $ts, task: $t, event: "launch", role: $r, session: $s, worktree: "/w/\($t[1:])", toolkits: []}'
}

# capacity_reading <minutes ago> <others GiB> [<task>:<role>:<id>:<GiB>...]: a stored reading of
# the team's capacity, taken that long ago on a 32 GiB machine whose other programs use <others
# GiB>, with each session live.
capacity_reading() {
  local file=$HOME/.local/state/agent-team/capacity/readings.jsonl
  mkdir -p "${file%/*}"
  printf '%s\n' "${@:3}" | jq -Rnc --arg at "$(date -u -d "@$(($(date +%s) - $1 * 60))" +%FT%TZ)" --argjson others "$2" '
    1073741824 as $gib
    | [inputs | select(. != "") | split(":") | {task: .[0], role: .[1], id: .[2], memory: (.[3] | tonumber * $gib | round)}] as $s
    | {at: $at, os: "linux", docker: true, cpu: null, systemd: true, sessions: true,
       memory: {total: (32 * $gib), available: ((32 - $others) * $gib | round), team: ([$s[].memory] | add // 0),
                others: ($others * $gib | round)},
       tasks: [$s | group_by(.task)[] | {task: .[0].task, memory: ([.[].memory] | add), cpu: null, cpu_nsec: null,
                sessions: map({id, role, memory, peak: .memory, cpu_seconds: 1}), stacks: []}],
       stacks: [], heavy: null, gate: {running: false, memory: 0, cpu_seconds: 0}}' >>"$file"
}

# level_record <level>: the team set to manual <level> an hour ago.
level_record() {
  jq -cn --arg ts "$(date -u -d '1 hour ago' +%FT%TZ)" --arg level "$1" \
    '{ts: $ts, mode: "manual", level: $level, by: "Daniel", machine: "home-pc"}' >"$TEAM_HOME/level.jsonl"
}

@test "level-stow: over budget in two readings names the tasks to stow, newest first, after the slots finding" {
  # T1 (opened 03:00) and T2 (04:00) each have a busy builder using 5 GiB; minor leaves 9.6 GiB.
  level_task T1 03:00 builder:1a1a1a1a
  level_task T2 04:00 builder:2b2b2b2b
  sessions "$(session 1a1a1a1a T1-builder busy working)" "$(session 2b2b2b2b T2-builder busy working)"
  level_record minor
  capacity_reading 10 8 T1:builder:1a1a1a1a:1 T2:builder:2b2b2b2b:1
  capacity_reading 5 8 T1:builder:1a1a1a1a:5 T2:builder:2b2b2b2b:5
  # One reading over budget after one within it is not enough.
  run_bin -0 --separate-stderr team-sweep
  assert_equal "$output$stderr" ""
  capacity_reading 0 8 T1:builder:1a1a1a1a:5 T2:builder:2b2b2b2b:5
  local before
  before=$(cat "$HOME/.local/state/agent-team/capacity/readings.jsonl")
  run_bin -1 --separate-stderr team-sweep
  assert_equal "$stderr" ""
  assert_equal "$output" "level: over budget at minor (30%): stow T2"
  run_bin -1 team-sweep --json
  assert_equal "$(jq -c '.[0]' <<<"$output")" '{"task":null,"kind":"level-stow","session":null,"name":null,"next":"stow T2","text":"level: over budget at minor (30%): stow T2"}'
  # At none every task with a live worker stows, newest first.
  level_record none
  run_bin -1 team-sweep
  assert_equal "$output" "level: over budget at none (0%): stow T2, then T1"
  # The sweep never takes a reading.
  assert_equal "$(cat "$HOME/.local/state/agent-team/capacity/readings.jsonl")" "$before"
}

@test "level-resume: the first task stowed, waiting to resume, that fits again, with task null, before retro-due" {
  # T4 was stowed for the level with a builder and a reviewer, T3 later with a planner; each
  # paused stowed, so neither is missing a worker.
  local t
  for t in T3 T4; do level_task "$t" 03:00; done
  ledger_line '{ts: "2026-10-22T05:00:00Z", task: "T3", event: "stowed", machine: "home-pc", worktrees: [],
    roles: ["planner"], cause: "level"}'
  ledger_line '{ts: "2026-10-22T04:00:00Z", task: "T4", event: "stowed", machine: "home-pc", worktrees: [],
    roles: ["builder", "reviewer"], cause: "level"}'
  for t in T3 T4; do event "$t" paused '{reason: "stowed"}'; done
  level_record minor
  # Minor leaves 9.6 GiB and a closed task's session uses 9.3: neither T3's planner (0.5 GiB) nor
  # T4's two (1 GiB) fit.
  capacity_reading 0 8 T9:builder:9c9c9c9c:9.3
  run_bin -0 --separate-stderr team-sweep
  assert_equal "$output$stderr" ""
  # At 8.9 GiB T3's planner fits, T4's two still do not: the finding names the first that fits.
  capacity_reading 0 8 T9:builder:9c9c9c9c:8.9
  run_bin -1 team-sweep
  assert_equal "$output" "level: T3 fits again: relaunch its planner"
  # With room for both, the oldest stow comes first, after the task findings and before retro-due.
  capacity_reading 0 8
  schedule "$(ago 50)" 48
  opened T5
  run_bin -1 team-sweep --json
  assert_equal "$(jq -c 'map(.kind)' <<<"$output")" '["no-worker","level-resume","retro-due"]'
  assert_equal "$(jq -c '.[1]' <<<"$output")" '{"task":null,"kind":"level-resume","session":null,"name":null,"next":"relaunch its builder and reviewer","text":"level: T4 fits again: relaunch its builder and reviewer"}'
  # At none nothing fits.
  level_record none
  run_bin -1 team-sweep --json
  assert_equal "$(jq -c 'map(.kind)' <<<"$output")" '["no-worker","retro-due"]'
}

@test "level-resume: a task a handoff stowed and the resume could not relaunch is named once it fits" {
  # T6 was stowed by the shutdown with its builder, and the resume at none relaunched nothing.
  level_task T6 03:00 builder:6f6f6f6f
  ledger_line '{ts: "2026-10-22T04:00:00Z", task: "T6", event: "stowed", machine: "home-pc", worktrees: [],
    roles: ["builder"], sessions: ["builder"], cause: "handoff"}'
  event T6 paused '{reason: "stowed"}'
  level_record none
  capacity_reading 0 8
  run_bin -0 --separate-stderr team-sweep
  assert_equal "$output$stderr" ""
  # Daniel raises the level: the finding names it.
  level_record minor
  run_bin -1 team-sweep
  assert_equal "$output" "level: T6 fits again: relaunch its builder"
  # Once its builder is launched again it waits for nothing.
  ledger_line '{ts: "2026-10-22T05:00:00Z", task: "T6", event: "launch", role: "builder", session: "6e6e6e6e",
    worktree: "/w/6", toolkits: []}'
  sessions "$(session 6e6e6e6e T6-builder busy working)"
  run_bin -0 team-sweep
  assert_equal "$output" ""
}

@test "level: a team-capacity plan that fails is one finding naming its reason, and the task findings still come" {
  opened T3
  mkdir -p "$HOME/.config/agent-team"
  echo '{"minor_share": 2}' >"$HOME/.config/agent-team/capacity.json"
  run_bin -1 --separate-stderr team-sweep
  assert_equal "$stderr" ""
  assert_equal "${lines[0]}" "T3 no-worker: opened with no worker launched; next: launch one with team-worker, or log what is known with team-log"
  assert_equal "${lines[1]%%:*}" "level"
  assert_contains "${lines[1]}" "level: team-capacity: ~/.config/agent-team/capacity.json"
  assert_contains "${lines[1]}" "minor_share"
  [[ ${lines[1]} == *": fix what team-capacity names" ]]
  run_bin -1 team-sweep --json
  assert_equal "$(jq -c '.[1] | del(.text)' <<<"$output")" \
    '{"task":null,"kind":"level","session":null,"name":null,"next":"fix what team-capacity names"}'
}
