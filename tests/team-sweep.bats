#!/usr/bin/env bats
# team-sweep: what the coordinator must not leave unattended (a task with no live worker, a
# worker waiting for input or idle without reporting, a busy worker whose transcripts have gone
# unwritten past its limit, a team session outliving its task, the team's stow plan, a retro due),
# from the ledger, the live session list, the stored capacity readings and the transcripts' times.

load helpers/common

setup() {
  sandbox
  stub_reply claude '[]'
  printf '%s\n' '[proj]' 'repo = "owner/proj"' 'path = "projects/proj"' 'base = "main"' 'delivery = "direct-pr"' \
    'merge_method = "merge"' 'required_checks = []' 'task_dir = ".scratch/task"' 'docs = []' 'toolkits = []' \
    '[proj.pool]' 'provider = "git"' 'slots = ["slots/proj/1"]' >"$TEAM_HOME/projects.toml"
  # #coordinator's guild, as team-inbox keeps it after its first read, so team-log's refresh of the
  # waiting list calls Discord for nothing.
  mkdir -p "$HOME/.local/state/agent-team"
  echo '{"channel":"1562486564871995482","guild":"1560000000000000000"}' >"$HOME/.local/state/agent-team/inbox.json"
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
  # Blocked after the merge, the task is parked, not to be closed.
  event T7 blocked '{reason: "the second half waits on T31"}'
  run_bin -0 team-sweep
}

@test "no-worker: a merged part is told to launch the next phase, and its last part to close" {
  opened T7
  launch T7 builder 22222222
  event T7 merged '{pr: 5, merge: "abcdef0", head: "1234567", by: "daniel", phases_left: [2, 3]}'
  run_bin -1 team-sweep
  assert_equal "$output" "T7 no-worker: a part merged, with phase 2, 3 still to build, with no live worker (latest T7-builder 22222222); next: launch the next phase's first ticket's builder (team-tickets T7 names it)"
  sessions "$(session 22222222 T7-builder idle working)"
  run_bin -1 team-sweep
  assert_equal "$output" "T7 no-worker: a part merged, with phase 2, 3 still to build, with every live worker idle (latest T7-builder 22222222); next: launch the next phase's first ticket's builder (team-tickets T7 names it)"
  # The next phase's builder at work is enough.
  launch T7 builder 33333333
  sessions "$(session 33333333 T7-builder busy working)"
  run_bin -0 team-sweep
  # Its part merged with every ticket done, the task is merged and told to close.
  event T7 merged '{pr: 6, merge: "abcdef1", head: "2345678", by: "daniel", phases_left: []}'
  sessions "$(session 33333333 T7-builder idle working)"
  run_bin -1 team-sweep
  assert_equal "$output" "T7 no-worker: merged and not closed, with every live worker idle (latest T7-builder 33333333); next: close it with team-close T7"
  no_github
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

@test "T278's B5: a launch past an open ask parks nothing, so the sweep watches its worker; an ask no launch passed parks the task" {
  opened T8
  event T8 plan-approved '{by: "coordinator"}'
  launch T8 builder 4f2a9c1e
  event T8 asked '{id: "q1", text: "which import?"}'
  event T8 waiting '{on: "Daniel", cause: "ask", ask: "q1", reason: "ask q1"}'
  ledger_line '{ts: "2026-10-22T02:20:00Z", task: "T8", event: "launch", role: "builder", session: "5e5e5e5e",
    worktree: "/w/1", toolkits: [], project: "proj", branch: "feat/T8-work"}'
  sessions "$(session 5e5e5e5e T8-builder idle)"
  # A launch that did not name the ask leaves the task parked on it: no finding.
  run_bin -0 team-sweep
  assert_equal "$output" ""
  # One that went past it (team-worker --past-ask q1) is watched: idle with no event, it is silent.
  ledger_line '{ts: "2026-10-22T02:30:00Z", task: "T8", event: "launch", role: "builder", session: "6e6e6e6e",
    worktree: "/w/1", toolkits: [], project: "proj", branch: "feat/T8-work", past_ask: ["q1"]}'
  sessions "$(session 6e6e6e6e T8-builder idle)"
  run_bin -1 team-sweep
  assert_equal "$output" "T8 silent: T8-builder 6e6e6e6e is idle with no ledger event since its launch at 2026-10-22T02:30:00Z; next: read claude logs 6e6e6e6e, then send it one line or log what is known with team-log"
}

@test "a denied finds nothing new: it is no report, parks nothing and clears no park" {
  local denied='{role: "builder", session: "4f2a9c1e", what: "Bash", why: "[deny rule] git reset * --hard*"}'
  opened T8
  launch T8 builder 4f2a9c1e
  sessions "$(session 4f2a9c1e T8-builder idle)"
  run_bin -1 team-sweep
  local silent=$output
  # A denial the worker went past is not a report: an idle session after it is still silent.
  event T8 denied "$denied"
  run_bin -1 team-sweep
  assert_equal "$output" "$silent"
  # Busy, it is at work, as with no denial.
  sessions "$(session 4f2a9c1e T8-builder busy working)"
  run_bin -0 team-sweep
  # After a report, a denial leaves the next step with the coordinator, as before it.
  event T8 ticket-done '{ticket: "1", commits: ["abc1234"]}'
  sessions "$(session 4f2a9c1e T8-builder idle)"
  run_bin -1 team-sweep
  local handed_back=$output
  assert_contains "$handed_back" "T8 no-worker: every live worker is idle with a ledger event since its launch"
  event T8 denied "$denied"
  run_bin -1 team-sweep
  assert_equal "$output" "$handed_back"
  # It clears no park: a blocked task stays parked, and a task with no worker is not parked by it.
  event T8 blocked '{reason: "the push was refused"}'
  event T8 denied "$denied"
  run_bin -0 team-sweep
  opened T9
  launch T9 builder 99999999
  event T9 denied '{role: "builder", what: "Bash", why: "no verdict"}'
  run_bin -1 team-sweep
  assert_equal "$output" "T9 no-worker: no live session among its 1 launch (latest T9-builder 99999999); next: read claude logs 99999999 for how it ended, then launch the next worker with team-worker or log what is known with team-log"
  no_github
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

@test "stalled: a wait on a PR's checks passes past 50 minutes, ending by about 100, and is named at 1 hour 55 minutes" {
  opened T8
  launch T8 builder 4f2a9c1e
  sessions "$(session 4f2a9c1e T8-builder busy working)"
  local wait='/home/x/agent-team/bin/team-ci-wait https://github.com/owner/proj/pull/217 a1b2c3d'
  { call toolu_01 106 Bash "$wait" background; result toolu_01 106 background; } | transcript - 4f2a9c1e 105
  run_bin -0 team-sweep
  { call toolu_01 116 Bash "$wait" background; result toolu_01 116 background; } | transcript - 4f2a9c1e 115
  run_bin -1 team-sweep
  assert_contains "$output" "T8-builder 4f2a9c1e has written nothing for 1h55m, waiting on \"$wait\" (Bash, in the background, running 1h56m); next:"
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
  # python3 runs the reader as Python 3.9 would, and every other script as itself.
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

@test "coordinator-twin: another session named coordinator on this machine, beside the one the sweep runs in" {
  sessions "$(session 3169fcbd coordinator busy working)" "$(session 5e7b1c04 coordinator idle blocked 1762596000000)" \
    "$(jq -cn '{pid: 5151, cwd: "/home/x", kind: "interactive", startedAt: 1762682400000,
      sessionId: "c0ffee00-1111-4222-8333-444455556666", name: "coordinator", status: "idle"}')"
  CLAUDE_CODE_SESSION_ID=3169fcbd-1111-4222-8333-444455556666 run_bin -1 team-sweep
  assert_equal "$output" "coordinator-twin: coordinator 5e7b1c04 (background, blocked, started 2025-11-08T10:00:00Z) is a second session named coordinator on this machine; next: read claude logs 5e7b1c04 for anything left to log, then stop it with claude stop 5e7b1c04
coordinator-twin: coordinator c0ffee00 (interactive, idle, started 2025-11-09T10:00:00Z) is a second session named coordinator on this machine; next: ask Daniel to end it, an interactive session, pid 5151"
  CLAUDE_CODE_SESSION_ID=3169fcbd-1111-4222-8333-444455556666 run_bin -1 team-sweep --json
  assert_equal "$(jq -c 'map([.task, .kind, .session, .name])' <<<"$output")" \
    '[[null,"coordinator-twin","5e7b1c04","coordinator"],[null,"coordinator-twin","c0ffee00","coordinator"]]'
}

@test "coordinator-twin: with no session of its own to tell apart, the sweep names every coordinator, each if it is not you" {
  sessions "$(session 3169fcbd coordinator busy working)" "$(session 5e7b1c04 coordinator idle blocked)"
  run_bin -1 team-sweep
  assert_equal "$output" "coordinator-twin: coordinator 3169fcbd (background, working, started 2025-10-22T02:00:00Z) is one of 2 sessions named coordinator on this machine; next: if it is not you, read claude logs 3169fcbd for anything left to log, then stop it with claude stop 3169fcbd
coordinator-twin: coordinator 5e7b1c04 (background, blocked, started 2025-10-22T02:00:00Z) is one of 2 sessions named coordinator on this machine; next: if it is not you, read claude logs 5e7b1c04 for anything left to log, then stop it with claude stop 5e7b1c04"
}

@test "coordinator-twin: a twin with no startedAt reads as started at an unknown time, and the sweep still runs" {
  sessions "$(session 3169fcbd coordinator busy working)" \
    "$(session 5e7b1c04 coordinator idle blocked | jq -c 'del(.startedAt)')"
  CLAUDE_CODE_SESSION_ID=3169fcbd-1111-4222-8333-444455556666 run_bin -1 --separate-stderr team-sweep
  assert_equal "$stderr" ""
  assert_equal "$output" "coordinator-twin: coordinator 5e7b1c04 (background, blocked, started at an unknown time) is a second session named coordinator on this machine; next: read claude logs 5e7b1c04 for anything left to log, then stop it with claude stop 5e7b1c04"
}

@test "coordinator-twin: one coordinator, the sweep's own or another, finds nothing" {
  sessions "$(session 3169fcbd coordinator busy working)"
  run_bin -0 team-sweep
  CLAUDE_CODE_SESSION_ID=3169fcbd-1111-4222-8333-444455556666 run_bin -0 team-sweep
  CLAUDE_CODE_SESSION_ID=0badf00d-1111-4222-8333-444455556666 run_bin -0 team-sweep
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
  ci T3 passed
  run_bin -0 team-sweep
  event T3 review '{verdict: "findings", head: "a1b2c3d"}'
  run_bin -1 team-sweep
  assert_contains "$output" "T3 no-worker"
  no_github
}

# ci <task> <outcome> [<head>] [<ts>]: team-next <task> --ci's end on PR 5 of proj at <head>
# (a1b2c3d4e5 by default), logged at <ts> (02:00 on 2026-10-22 by default).
ci() {
  ledger_line --arg t "$1" --arg o "$2" --arg head "${3:-a1b2c3d4e5}" --arg ts "${4:-2026-10-22T02:00:00Z}" \
    '{ts: $ts, task: $t, event: "ci", url: "https://github.com/owner/proj/pull/5", head: $head, outcome: $o}'
}

# Task <task>'s PR 5 of proj reviewed and passed at its head, and its checks wait ended green,
# with no plan approved.
passed_pr() {
  event "$1" pr '{url: "https://github.com/owner/proj/pull/5", head: "a1b2c3d"}'
  event "$1" review '{verdict: "pass", head: "a1b2c3d4e5", findings: {blocking: 0, correctness: 0, security: 0, "real-data": 0, "note-change": 0, "note-before": 0}, guarded: []}'
  ci "$1" passed
}

# Task <task>'s plan approved by the coordinator, as team-log records it.
approved() {
  event "$1" plan-approved '{by: "coordinator", plan: {"tasks/T3/plan.md": "0000"}, scope: ["src/"]}'
}

# Task <task>'s PR 5 of proj reviewed and passed at its head, its plan approved: the default word
# holds on the ledger.
approved_pr() {
  approved "$1"
  passed_pr "$1"
}

# said <task> <kind> <scope> <message>: Daniel's withdrawal of the default word
# (merge-default-withdrawn) or its giving back (merge-default-restored) for <scope> (task, a
# project or all), logged under <task>, in #coordinator.
said() {
  event "$1" "$2" "{scope: \"$3\", discord_message: \"$4\", discord_channel: \"1562000000000000000\"}"
}

# Register <project> beside proj, at owner/<project>: register <project>
register() {
  printf '%s\n' "[$1]" "repo = \"owner/$1\"" "path = \"projects/$1\"" 'base = "main"' 'delivery = "direct-pr"' \
    'merge_method = "merge"' 'required_checks = []' 'task_dir = ".scratch/task"' 'docs = []' 'toolkits = []' \
    "[$1.pool]" 'provider = "git"' "slots = [\"slots/$1/1\"]" >>"$TEAM_HOME/projects.toml"
}

# T3's merge-due line for PR 5.
due() {
  echo "T3 merge-due: awaiting the merge of https://github.com/owner/proj/pull/5 on the default word, the approved plan, with no ask open; next: run team-merge T3; on a refusal, ask Daniel for the per-head word with team-ask"
}

@test "merge-due: an awaiting-merge task whose default word holds and nothing else parking it" {
  opened T3
  launch T3 reviewer 11111111
  approved_pr T3
  sessions "$(session 11111111 T3-reviewer idle)"
  run_bin -1 team-sweep
  assert_equal "$output" "$(due)"
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

@test "merge-due: none while the latest review, a pass logged through team-log, sent findings back" {
  opened T3
  launch T3 builder 11111111
  approved_pr T3
  local counts='findings=blocking:0,correctness:1,security:0,real-data:0,note-change:0,note-before:0'
  run_bin -0 team-log T3 review verdict=pass head=a1b2c3d4e5 "$counts" sent_back=1 guarded=none
  # The builder's live session holds the fix round.
  sessions "$(session 11111111 T3-builder busy)"
  run_bin -0 team-sweep
  assert_equal "$output" ""
  # The verify pass that sends nothing back makes it due again.
  run_bin -0 team-log T3 review verdict=pass head=a1b2c3d4e5 "$counts" sent_back=none guarded=none
  ci T3 passed
  run_bin -1 team-sweep
  assert_contains "$output" "T3 merge-due"
  no_github
}

@test "merge-due: none with no plan approved or the approval withdrawn, while another park stands, or before the review passed" {
  opened T3
  launch T3 builder 11111111
  passed_pr T3
  # No plan approved: the task waits on Daniel's per-head word.
  run_bin -0 team-sweep
  # A plan-approved logged before T276, with no plan, is the coordinator's and holds for proj.
  event T3 plan-approved '{by: "Daniel"}'
  run_bin -1 team-sweep
  assert_equal "$output" "$(due)"

  # A withdrawn approval leaves the task awaiting Daniel's per-head word: parked.
  event T3 plan-approval-withdrawn '{discord_message: "1563000000000000002"}'
  run_bin -0 team-sweep
  approved T3
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
  assert_equal "$output" "$(due)"

  # A new head under review is no merge yet: the task's worker findings come back.
  event T3 pr '{url: "https://github.com/owner/proj/pull/5", head: "b2c3d4e"}'
  run_bin -1 team-sweep
  assert_equal "$output" "T3 no-worker: no live session among its 1 launch (latest T3-builder 11111111); next: read claude logs 11111111 for how it ended, then launch the next worker with team-worker or log what is known with team-log"
}

@test "merge-due: none while the default word is withdrawn for the task, its project or all, by any task, until it is given back" {
  opened T3
  launch T3 reviewer 11111111
  approved_pr T3
  sessions "$(session 11111111 T3-reviewer idle)"
  run_bin -1 team-sweep
  assert_equal "$output" "$(due)"

  # A withdrawal of its project, logged under another task, holds it back.
  said T2 merge-default-withdrawn proj 1563000000000000001
  event T2 closed
  run_bin -0 team-sweep
  # Given back for every project (T278's C3), it is due again.
  said T3 merge-default-restored all 1563000000000000002
  run_bin -1 team-sweep
  assert_equal "$output" "$(due)"
  # Withdrawn for another project, or for another task, it still is.
  register conv
  said T3 merge-default-withdrawn conv 1563000000000000003
  said T2 merge-default-withdrawn task 1563000000000000004
  run_bin -1 team-sweep
  assert_equal "$output" "$(due)"
  # Withdrawn for the task, then for all and given back for the project, it is held back, then due.
  said T3 merge-default-withdrawn task 1563000000000000005
  run_bin -0 team-sweep
  said T3 merge-default-withdrawn all 1563000000000000006
  said T3 merge-default-restored proj 1563000000000000007
  run_bin -1 team-sweep
  assert_equal "$output" "$(due)"
  no_github
}

@test "merge-due: none for the team's own project, by name, repo or path, whoever approved the plan" {
  # The queued note's case: an agent-team task with the coordinator's approval is never due.
  register agent-team
  event T3 opened '{project: "agent-team", path: "feature", type: "feat", title: "Work",
    branch: "feat/T3-work", base: "main", base_sha: "0123456", worktree: "/w/1"}'
  launch T3 reviewer 11111111
  approved_pr T3
  sessions "$(session 11111111 T3-reviewer idle)"
  run_bin -0 --separate-stderr team-sweep
  assert_equal "$output" ""
  assert_equal "$stderr" ""
  # Nor with Daniel's.
  event T3 asked '{id: "plan", text: "Approve the plan?"}'
  event T3 plan-approved '{by: "Daniel", ask: "plan", discord_message: "1563000000000000001", plan: {"tasks/T3/plan.md": "0000"}}'
  run_bin -0 team-sweep

  # proj is the team's own by the code checkout's repo, and conv by its path.
  : >"$TEAM_HOME/ledger.jsonl"
  opened T3
  launch T3 reviewer 11111111
  approved_pr T3
  run_bin -1 team-sweep
  assert_equal "$output" "$(due)"
  export CODE_CHECKOUT
  CODE_CHECKOUT=$(make_repo proj)
  copy_bin "$CODE_CHECKOUT/bin"
  git -C "$CODE_CHECKOUT" remote set-url origin git@github.com:owner/proj.git
  run_bin -0 team-sweep
  # conv is, by its path, the code checkout, whose origin is no project's: its PR is never due,
  # while proj's is.
  register conv
  CODE_CHECKOUT=$(make_repo conv)
  copy_bin "$CODE_CHECKOUT/bin"
  run_bin -1 team-sweep
  assert_equal "$output" "$(due)"
  event T3 pr '{url: "https://github.com/owner/conv/pull/7", head: "c3d4e5f", project: "conv"}'
  event T3 review '{verdict: "pass", head: "c3d4e5f", findings: {blocking: 0, correctness: 0, security: 0, "real-data": 0, "note-change": 0, "note-before": 0}, guarded: []}'
  event T3 ci '{url: "https://github.com/owner/conv/pull/7", head: "c3d4e5f", outcome: "passed"}'
  event T3 worktree-added '{project: "conv", branch: "feat/T3-work", worktree: "/w/2"}'
  run_bin -1 team-sweep
  assert_equal "$output" "$(due)"
}

@test "merge-due: with the registry unreadable, none, and stderr says why" {
  opened T3
  launch T3 reviewer 11111111
  approved_pr T3
  sessions "$(session 11111111 T3-reviewer idle)"
  rm "$TEAM_HOME/projects.toml"
  run_bin -0 --separate-stderr team-sweep
  assert_equal "$output" ""
  assert_equal "$stderr" "team-sweep: finds no task merge-due, since the registry cannot be read: team-project: no registry at $TEAM_HOME/projects.toml"
}

@test "merge-due: none for a head the word does not cover, as team-state reads it" {
  opened T3
  launch T3 reviewer 11111111
  sessions "$(session 11111111 T3-reviewer idle)"
  approved T3
  event T3 pr '{url: "https://github.com/owner/proj/pull/5", head: "a1b2c3d"}'
  local counts='{blocking: 0, correctness: 0, security: 0, "real-data": 0, "note-change": 0, "note-before": 0}'
  # The reviewer found guarded areas, or logged none, or an earlier review counted a security
  # finding: team-merge would refuse the word, so the coordinator is not sent to it.
  event T3 review "{verdict: \"pass\", head: \"a1b2c3d4e5\", findings: $counts, guarded: [\"ci\"]}"
  ci T3 passed a1b2c3d4e5
  run_bin -0 team-sweep
  event T3 review "{verdict: \"pass\", head: \"a1b2c3d4e5\", findings: $counts}"
  ci T3 passed a1b2c3d4e5
  run_bin -0 team-sweep
  # A pass that names none is covered again, until a review that counted a security finding.
  event T3 review "{verdict: \"pass\", head: \"a1b2c3d4e5\", findings: $counts, guarded: []}"
  ci T3 passed a1b2c3d4e5
  run_bin -1 team-sweep
  assert_equal "$output" "$(due)"
  event T3 review "{verdict: \"pass\", head: \"a1b2c3d4e5\", findings: ($counts + {security: 1}), guarded: []}"
  ci T3 passed a1b2c3d4e5
  run_bin -0 team-sweep
  : >"$TEAM_HOME/ledger.jsonl"
  opened T3
  launch T3 reviewer 11111111
  approved_pr T3
  event T3 review "{verdict: \"pass\", head: \"a1b2c3d4e5\", findings: $counts, guarded: [\"secrets\"]}"
  ci T3 passed a1b2c3d4e5
  run_bin -0 team-sweep
  # An area retired since (T276), which a review logged before may name, holds nothing back.
  event T3 review "{verdict: \"pass\", head: \"a1b2c3d4e5\", findings: $counts, guarded: [\"settings\", \"dependencies\"]}"
  ci T3 passed a1b2c3d4e5
  run_bin -1 team-sweep
  assert_equal "$output" "$(due)"
  no_github
}

@test "merge-due: none while a builder is on a merge-base round, until its rereview or its workers are gone" {
  opened T3
  launch T3 builder 11111111
  launch T3 reviewer 22222222
  passed_pr T3
  approved T3
  sessions "$(session 11111111 T3-builder idle)"
  run_bin -1 team-sweep
  assert_contains "$output" "T3 merge-due"

  # The holder is sent the brief, and the coordinator logs the resumed naming it. A plain resumed
  # says nothing of a round.
  event T3 resumed
  run_bin -1 team-sweep
  assert_contains "$output" "T3 merge-due"
  event T3 resumed '{brief: "brief-merge-base-2"}'
  sessions "$(session 11111111 T3-builder busy)"
  run_bin -0 team-sweep
  no_github
  # The builder reports its merge, and the rereview is still on it.
  event T3 'done' '{role: "builder", session: "11111111", report: "merged main f00ba47 conflicts: none"}'
  launch T3 reviewer 33333333
  sessions "$(session 11111111 T3-builder idle)" "$(session 33333333 T3-reviewer busy)"
  run_bin -0 team-sweep
  # Its worker gone with no review, the round is over, and the finding comes back.
  sessions "$(session 11111111 T3-builder idle)"
  run_bin -1 team-sweep
  assert_contains "$output" "T3 merge-due"
  # With its reviewer live, its pass ends the round, on the merged head.
  sessions "$(session 33333333 T3-reviewer busy)"
  run_bin -0 team-sweep
  event T3 review '{verdict: "pass", head: "f00ba47", findings: {blocking: 0, correctness: 0, security: 0, "real-data": 0, "note-change": 0, "note-before": 0}, guarded: []}'
  ci T3 passed f00ba47
  run_bin -1 team-sweep
  assert_contains "$output" "T3 merge-due"
}

@test "merge-due: judged on the latest review, of a head no pr event logged" {
  opened T3
  launch T3 reviewer 11111111
  sessions "$(session 11111111 T3-reviewer idle)"
  approved T3
  event T3 pr '{url: "https://github.com/owner/proj/pull/5", head: "a1b2c3d"}'
  local counts='{blocking: 0, correctness: 0, security: 0, "real-data": 0, "note-change": 0, "note-before": 0}'
  event T3 review "{verdict: \"pass\", head: \"a1b2c3d\", findings: $counts, guarded: []}"
  ci T3 passed a1b2c3d
  run_bin -1 team-sweep
  assert_contains "$output" "T3 merge-due"
  # A review of a newer head sends findings back: the pass on the pr event's head no longer counts.
  event T3 review "{verdict: \"findings\", head: \"b2c3d4e\", findings: ($counts + {correctness: 1}), sent_back: [1], guarded: []}"
  run_bin -0 team-sweep
  # The fix passes, naming a guarded area, which the word does not cover.
  event T3 review "{verdict: \"pass\", head: \"c3d4e5f\", findings: $counts, guarded: [\"ci\"]}"
  ci T3 passed c3d4e5f
  run_bin -0 team-sweep
  # The next pass names none: the word covers it again.
  event T3 review "{verdict: \"pass\", head: \"d4e5f6a\", findings: $counts, guarded: []}"
  ci T3 passed d4e5f6a
  run_bin -1 team-sweep
  assert_contains "$output" "T3 merge-due"
  no_github
}

@test "merge-due: none while a fresh builder launched on a merge-base brief works, nor after team-catch-up's merge is over the hold" {
  opened T3
  launch T3 builder 11111111
  passed_pr T3
  approved T3
  sessions "$(session 44444444 T3-builder busy)"
  ledger_line '{ts: "2026-10-22T02:30:00Z", task: "T3", event: "launch", role: "builder", session: "44444444", worktree: "/w/1",
    toolkits: [], project: "proj", branch: "feat/T3-work", brief: "brief-merge-base"}'
  run_bin -0 team-sweep
  # A clean catch-up settles the base with no round left to wait for.
  event T3 caught-up '{url: "https://github.com/owner/proj/pull/5", from: "a1b2c3d", head: "f00ba47", base: "main"}'
  # Its checks wait on the merge is still to end: no merge yet, until it ends green.
  run_bin -1 team-sweep
  [[ $output != *merge-due* ]]
  ci T3 passed f00ba47
  run_bin -1 team-sweep
  assert_contains "$output" "T3 merge-due"
}

@test "merge-due: under a withdrawal for another project, and parked by an ask, a pause, a wait or a withdrawal of all" {
  opened T3
  launch T3 builder 11111111
  approved_pr T3
  register conv
  said T3 merge-default-withdrawn conv 1563000000000000001
  run_bin -1 team-sweep
  assert_equal "$output" "$(due)"

  # An ask nothing settled, a pause or a wait parks it.
  event T3 asked '{id: "q1", text: "Which name?"}'
  run_bin -0 team-sweep
  event T3 answered '{id: "q1", answer: "Kim"}'
  event T3 paused '{reason: "rate limit"}'
  run_bin -0 team-sweep
  event T3 resumed
  event T3 waiting '{on: "Daniel", reason: "a word on the release"}'
  run_bin -0 team-sweep
  event T3 resumed
  run_bin -1 team-sweep
  assert_contains "$output" "T3 merge-due"

  # A withdrawal for every project parks it.
  said T3 merge-default-withdrawn all 1563000000000000003
  run_bin -0 team-sweep
}

@test "merge-due: none until the checks of the pass passed, as team-next --ci logs it; ci-due while no wait has ended" {
  opened T3
  launch T3 reviewer 11111111
  sessions "$(session 11111111 T3-reviewer idle)"
  approved T3
  event T3 pr '{url: "https://github.com/owner/proj/pull/5", head: "a1b2c3d"}'
  event T3 review '{verdict: "pass", head: "a1b2c3d4e5", findings: {blocking: 0, correctness: 0, security: 0, "real-data": 0, "note-change": 0, "note-before": 0}, guarded: []}'
  # The pass's checks no wait has ended since 2026-10-22: no merge yet, and the wait to arm.
  run_bin -1 team-sweep
  assert_contains "$output" "T3 ci-due: the checks of https://github.com/owner/proj/pull/5 at a1b2c3d4 have had no wait end for "
  [[ $output != *merge-due* ]]
  # A wait that ended at its deadline, or failed, or failed as infrastructure, is no merge either.
  local outcome
  for outcome in pending failed infrastructure; do
    ci T3 "$outcome"
    run_bin team-sweep
    [[ $output != *merge-due* ]]
  done
  # A ci of another head is not the pass's.
  ci T3 passed f00ba47
  run_bin -0 team-sweep
  # The checks of the passed head passed: merge-due, and no ci-due.
  ci T3 passed
  run_bin -1 team-sweep
  assert_equal "$output" "$(due)"
  no_github
}

# T3's ci-due line for PR 5 at a1b2c3d4, no wait ended for <duration>.
ci_due() {
  echo "T3 ci-due: the checks of https://github.com/owner/proj/pull/5 at a1b2c3d4 have had no wait end for $1; next: arm team-next T3 --ci with Bash run_in_background unless it is running"
}

# minutes_ago <n>: the UTC time that many minutes before now.
minutes_ago() {
  date -u -d "@$(($(date +%s) - $1 * 60))" +%FT%TZ
}

# T3's PR 5 passed at a1b2c3d4e5, <minutes> ago, its plan not approved: passed_at <minutes>
passed_at() {
  : >"$TEAM_HOME/ledger.jsonl"
  opened T3
  launch T3 reviewer 11111111
  event T3 pr '{url: "https://github.com/owner/proj/pull/5", head: "a1b2c3d"}'
  ledger_line --arg ts "$(minutes_ago "$1")" '{ts: $ts, task: "T3", event: "review", verdict: "pass", head: "a1b2c3d4e5"}'
}

@test "ci-due: a pass whose checks no wait has ended and no check was rerun for 100 minutes, not at 99, with session null" {
  sessions "$(session 11111111 T3-reviewer idle)"
  passed_at 99
  run_bin -0 team-sweep
  passed_at 100
  run_bin -1 team-sweep
  assert_equal "$output" "$(ci_due 1h40m)"
  run_bin -1 team-sweep --json
  assert_equal "$(jq -c 'map([.task, .kind, .session, .name, .next])' <<<"$output")" \
    '[["T3","ci-due",null,null,"arm team-next T3 --ci with Bash run_in_background unless it is running"]]'

  # A wait that ended at its deadline dates it from that end.
  ci T3 pending a1b2c3d4e5 "$(minutes_ago 99)"
  run_bin -0 team-sweep
  passed_at 300
  ci T3 pending a1b2c3d4e5 "$(minutes_ago 125)"
  run_bin -1 team-sweep
  assert_equal "$output" "$(ci_due 2h05m)"

  # A rerun starts the wait again, so it dates it from the rerun.
  passed_at 300
  ledger_line --arg ts "$(minutes_ago 99)" '{ts: $ts, task: "T3", event: "ci-rerun", url: "https://github.com/owner/proj/pull/5",
    head: "a1b2c3d4e5", check: "test-shards (1)", run: "7", job: "10"}'
  run_bin -0 team-sweep
  passed_at 300
  ledger_line --arg ts "$(minutes_ago 100)" '{ts: $ts, task: "T3", event: "ci-rerun", url: "https://github.com/owner/proj/pull/5",
    head: "a1b2c3d4e5", check: "test-shards (1)", run: "7", job: "10"}'
  run_bin -1 team-sweep
  assert_equal "$output" "$(ci_due 1h40m)"

  # A wait that ended green, red or as infrastructure leaves none to arm.
  local outcome
  for outcome in passed failed infrastructure; do
    passed_at 300
    ci T3 "$outcome" a1b2c3d4e5 "$(minutes_ago 200)"
    run_bin -0 team-sweep
  done

  # After a catch-up, the wait on the merge dates from it.
  passed_at 300
  ci T3 passed a1b2c3d4e5 "$(minutes_ago 200)"
  ledger_line --arg ts "$(minutes_ago 100)" \
    '{ts: $ts, task: "T3", event: "caught-up", url: "https://github.com/owner/proj/pull/5", from: "a1b2c3d4e5", head: "f00ba47aa", base: "main"}'
  run_bin -1 team-sweep
  assert_equal "$output" "T3 ci-due: the checks of https://github.com/owner/proj/pull/5 at f00ba47a have had no wait end for 1h40m; next: arm team-next T3 --ci with Bash run_in_background unless it is running"
  no_github
}

@test "ci-due: none while an ask is unsettled or a park stands, nor once findings went back or the PR merged" {
  sessions "$(session 11111111 T3-reviewer idle)"
  passed_at 300
  event T3 asked '{id: "q1", text: "Which name?"}'
  run_bin -0 team-sweep
  event T3 answered '{id: "q1", answer: "Kim"}'
  run_bin -1 team-sweep
  assert_contains "$output" "T3 ci-due"
  local kind
  for kind in held blocked paused waiting; do
    event T3 "$kind" '{reason: "OS update", on: "Daniel"}'
    run_bin -0 team-sweep
    event T3 resumed
  done
  run_bin -1 team-sweep
  assert_contains "$output" "T3 ci-due"

  # Findings sent back: no pass waits.
  event T3 review '{verdict: "findings", head: "a1b2c3d4e5", sent_back: [1]}'
  run_bin team-sweep
  [[ $output != *ci-due* ]]
  # Merged: no checks wait for a merge.
  passed_at 300
  event T3 merged '{pr: 5, merge: "9999999", head: "a1b2c3d", by: "1563000000000000002", url: "https://github.com/owner/proj/pull/5"}'
  run_bin -1 team-sweep
  assert_equal "$output" "T3 no-worker: merged and not closed, with every live worker idle (latest T3-reviewer 11111111); next: close it with team-close T3"
  no_github
}

@test "--help documents ci-due beside merge-due, and still says the sweep reads no GitHub" {
  run_bin -0 team-sweep --help
  assert_contains "$output" "ci-due"
  assert_contains "$output" "have had no wait end for <h>h<mm>m"
  assert_contains "$output" "arm team-next"
  assert_contains "$output" "never GitHub"
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

@test "--wait never ends before its baseline's time on a finding there at its first look, and one that clears and comes back is new" {
  opened T3
  launch T3 builder 4f2a9c1e
  # The baseline's seam makes it 10 minutes: the watch is stopped at 9:30, its 20th wait.
  LOOK_LIMIT=19 looks '[]'
  TEAM_SWEEP_BASELINE_SECONDS=600 run_bin -99 team-sweep --wait
  assert_equal "$output" ""
  assert_equal "$(waits)" 20

  # Gone at the third look, back at the fourth (1:30): it ends three minutes later.
  : >"$STUB_CALLS/sleep.log"
  looks '[]' '[]' "[$(session 4f2a9c1e T3-builder busy working)]" '[]'
  run_bin -0 team-sweep --wait
  assert_contains "$output" "T3 no-worker: no live session among its 1 launch"
  assert_equal "$(waits)" 9
}

@test "--wait ends on a finding there at its first look once it has stood for its baseline's time" {
  opened T3
  launch T3 builder 4f2a9c1e
  opened T4
  launch T4 builder 5a5a5a5a
  # T3 has no worker from the first look on, as one the coordinator just acted on; T4's goes at
  # 0:30, a new finding, which clears again before it has stood three minutes. The baseline's
  # seam makes it 10 minutes.
  local t4
  t4=$(session 5a5a5a5a T4-builder busy working)
  looks "[$t4]" '[]' '[]' "[$t4]"
  TEAM_SWEEP_BASELINE_SECONDS=600 run_bin -0 team-sweep --wait
  assert_equal "$output" "T3 no-worker: no live session among its 1 launch (latest T3-builder 4f2a9c1e); next: read claude logs 4f2a9c1e for how it ended, then launch the next worker with team-worker or log what is known with team-log"
  assert_equal "$(waits)" 20

  # Cleared at 5:00 and back at 5:30, it is new from then: three minutes later, it ends.
  : >"$STUB_CALLS/sleep.log"
  local -a lists=()
  for _ in $(seq 10); do lists+=("[$t4]"); done
  lists+=("[$t4,$(session 4f2a9c1e T3-builder busy working)]" "[$t4]")
  looks "${lists[@]}"
  TEAM_SWEEP_BASELINE_SECONDS=600 run_bin -0 team-sweep --wait
  assert_contains "$output" "T3 no-worker:"
  assert_equal "$(waits)" 17

  # The seam takes only a number of seconds.
  TEAM_SWEEP_BASELINE_SECONDS=10m run_bin -2 team-sweep --wait
  assert_contains "$output" "TEAM_SWEEP_BASELINE_SECONDS must be a number of seconds"
}

@test "--wait never ends on a finding that clears within three minutes" {
  opened T3
  launch T3 builder 4f2a9c1e
  local busy
  busy=$(session 4f2a9c1e T3-builder busy working)
  # No worker from 0:30 to 3:00, as between a DONE and the next launch, then one again; the watch
  # is stopped at 7:00, its 15th wait.
  LOOK_LIMIT=14 looks "[$busy]" '[]' '[]' '[]' '[]' '[]' '[]' "[$busy]"
  run_bin -99 team-sweep --wait
  assert_equal "$output" ""
  assert_equal "$(waits)" 15
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

@test "--wait's unreadable exit names the failing look's last line on stderr, or its exit code with none" {
  opened T3
  # A session list the sweep cannot read fails the look in jq, which says no "team-sweep: " line.
  looks '["x"]'
  run_bin -1 --separate-stderr team-sweep --wait
  assert_equal "$output" ""
  assert_equal "${stderr//"$TEAM_HOME/ledger.jsonl"/<the ledger>}" \
    'team-sweep: jq: error (at <the ledger>:1): Cannot index string with string "name", for 5 minutes running'
  assert_equal "$(waits)" 10

  # A look that fails with nothing on stderr is named by its exit code.
  code_checkout
  local lib=$BATS_TEST_TMPDIR/code/bin/lib
  rm -f "$lib/ledger.jq"
  { cat "$REPO_ROOT/bin/lib/ledger.jq"; echo 'def sweep($a; $b; $c; $d; $e; $f): "" | halt_error(4);'; } >"$lib/ledger.jq"
  looks '[]'
  run_bin -1 --separate-stderr team-sweep --wait
  assert_equal "$stderr" "team-sweep: a look failed with exit 4 and nothing on stderr, for 5 minutes running"
}

@test "--wait ends at once on a failing look once its own code changed under it, naming the files" {
  opened T3
  code_checkout
  looks '[]'
  # A merge replaces the library under the running watch, and its next look fails on the new
  # definitions, as PR 111's change of own_covered's shape did on 2026-11-12.
  local code=$BATS_TEST_TMPDIR/code lib=$BATS_TEST_TMPDIR/code/bin/lib
  printf '%s\n' "{ cat '$lib/ledger.jq'; echo 'def sweep(\$a; \$b; \$c; \$d; \$e; \$f): error(\"Cannot index array\");'; } >'$lib/ledger.jq.new'" \
    "mv '$lib/ledger.jq.new' '$lib/ledger.jq'" >"$BATS_TEST_TMPDIR/at-look.2"
  run_bin -1 --separate-stderr team-sweep --wait
  assert_equal "$output" ""
  assert_equal "${stderr//"$TEAM_HOME/ledger.jsonl"/<the ledger>}" "team-sweep: jq: error (at <the ledger>:1): Cannot index array, after its code changed under this watch (bin/lib/ledger.jq): re-arm it to run the new code"
  assert_equal "$(waits)" 2

  # A change the looks still read through leaves the watch looking, until the stub sleep stops it.
  rm -f "$lib/ledger.jq"
  cat "$REPO_ROOT/bin/lib/ledger.jq" >"$lib/ledger.jq"
  printf '%s\n' "{ cat '$code/bin/team-sweep'; echo '# a later line'; } >'$code/bin/team-sweep.new'" \
    "mv '$code/bin/team-sweep.new' '$code/bin/team-sweep'" >"$BATS_TEST_TMPDIR/at-look.2"
  looks '[]'
  LOOK_LIMIT=4 run_bin -99 team-sweep --wait
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
  launch T30 planner 30303030
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

@test "no slots finding: more tasks held than any cap, each with a busy worker, find nothing, and --help names no slots" {
  local n sessions=()
  for n in 3 4 5 6 7 8 9; do
    opened "T$n"
    launch "T$n" builder "${n}0000000"
    sessions+=("$(session "${n}0000000" "T$n-builder" busy working)")
  done
  sessions "${sessions[@]}"
  run_bin -0 --separate-stderr team-sweep
  assert_equal "$output$stderr" ""
  [[ ! -e $HOME/.local/state/agent-team/slots ]]
  run_bin -0 team-sweep --help
  [[ $output != *slots* ]]
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
                sessions: map({id, role, memory, cpu_seconds: 1}), stacks: []}],
       stacks: [], heavy: null, gate: {running: false, memory: 0, cpu_seconds: 0}}' >>"$file"
}

# level_record <level>: the team set to manual <level> an hour ago.
level_record() {
  jq -cn --arg ts "$(date -u -d '1 hour ago' +%FT%TZ)" --arg level "$1" \
    '{ts: $ts, mode: "manual", level: $level, by: "Daniel", machine: "home-pc"}' >"$TEAM_HOME/level.jsonl"
}

@test "level-stow: over budget in two readings names the tasks to stow, newest first" {
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

@test "stowing: a stow under way 30 minutes with no stowed is named, whatever parks the task, and none at 29" {
  # T7's builder answered its STOW (a paused, so the task is parked) and the run never came.
  level_task T7 03:00 builder:7a7a7a7a
  ledger_line --arg ts "$(date -u -d '30 minutes ago' +%FT%TZ)" '{ts: $ts, task: "T7", event: "stowing",
    machine: "home-pc", cause: "level", roles: ["builder"]}'
  event T7 paused '{reason: "stowed", cause: "stow"}'
  local since
  since=$(jq -r 'select(.event == "stowing") | .ts' "$TEAM_HOME/ledger.jsonl")
  run_bin -1 --separate-stderr team-sweep
  assert_equal "$stderr" ""
  assert_equal "$output" "T7 stowing: stowing since $since (level), with no stowed; next: run team-stow T7, which finishes the stow or logs stow-failed"
  run_bin -1 team-sweep --json
  assert_equal "$(jq -c '.[] | [.task, .kind, .session, .name, .next]' <<<"$output")" \
    '["T7","stowing",null,null,"run team-stow T7, which finishes the stow or logs stow-failed"]'

  # At 29 minutes it is not named yet.
  jq -c --arg ts "$(date -u -d '29 minutes ago' +%FT%TZ)" 'if .event == "stowing" then .ts = $ts else . end' \
    "$TEAM_HOME/ledger.jsonl" >"$BATS_TEST_TMPDIR/ledger.next"
  mv "$BATS_TEST_TMPDIR/ledger.next" "$TEAM_HOME/ledger.jsonl"
  run_bin -0 --separate-stderr team-sweep
  assert_equal "$output$stderr" ""

  # A stowed, or a stow-failed, ends it.
  for kind in stowed stow-failed; do
    jq -c --arg ts "$(date -u -d '40 minutes ago' +%FT%TZ)" 'if .event == "stowing" then .ts = $ts else . end' \
      "$TEAM_HOME/ledger.jsonl" >"$BATS_TEST_TMPDIR/ledger.next"
    mv "$BATS_TEST_TMPDIR/ledger.next" "$TEAM_HOME/ledger.jsonl"
    cp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/ledger.before"
    ledger_line --arg kind "$kind" '{ts: "2026-10-22T04:00:00Z", task: "T7", event: $kind, machine: "home-pc",
      worktrees: [], roles: [], reason: "x"}'
    run_bin -0 --separate-stderr team-sweep
    assert_equal "$output$stderr" ""
    mv "$BATS_TEST_TMPDIR/ledger.before" "$TEAM_HOME/ledger.jsonl"
  done
}

# held_pair [<T3 event>...] -- [<T3 event>...]: the ledger afresh, T3 stowed for the level at 04:00
# with its planner and T4 at 05:00 with its builder, each paused stowed, with each T3 event
# (<kind>:<jq object of more fields>) logged before T3's stow, or after it when it follows the --.
held_pair() {
  local spec at=03:30
  : >"$TEAM_HOME/ledger.jsonl"
  level_task T3 03:00
  level_task T4 03:00
  for spec in "$@"; do
    if [[ $spec == -- ]]; then
      ledger_line '{ts: "2026-10-22T04:00:00Z", task: "T3", event: "stowed", machine: "home-pc", worktrees: [],
        roles: ["planner"], cause: "level"}'
      ledger_line '{ts: "2026-10-22T04:00:00Z", task: "T3", event: "paused", reason: "stowed"}'
      at=04:30
    else
      ledger_line --arg e "${spec%%:*}" --arg ts "2026-10-22T$at:00Z" "{ts: \$ts, task: \"T3\", event: \$e} + ${spec#*:}"
    fi
  done
  ledger_line '{ts: "2026-10-22T05:00:00Z", task: "T4", event: "stowed", machine: "home-pc", worktrees: [],
    roles: ["builder"], cause: "level"}'
  ledger_line '{ts: "2026-10-22T05:00:00Z", task: "T4", event: "paused", reason: "stowed"}'
}

# relaunch_t4: T4's builder launched again since its stow, and live.
relaunch_t4() {
  ledger_line '{ts: "2026-10-22T06:00:00Z", task: "T4", event: "launch", role: "builder", session: "4e4e4e4e",
    worktree: "/w/4", toolkits: []}'
  sessions "$(session 4e4e4e4e T4-builder busy working)"
}

@test "level-resume: a stowed task held, or waiting or blocked since its stow, is never named, until resumed" {
  level_record minor
  # Room for both stowed tasks' roles.
  capacity_reading 0 8
  local hold='{reason: "on hold by Daniel (1500000000000000001)"}'
  # T3 stowed first, then Daniel put it on hold: the finding names T4, the next that fits.
  held_pair -- "waiting:{on: \"Daniel\", reason: \"on hold by Daniel (1500000000000000001)\"}"
  run_bin -1 team-sweep
  assert_equal "$output" "level: T4 fits again: relaunch its builder"
  # With T4 relaunched, T3 is the only one stowed: a held before its stow keeps it stowed.
  held_pair "held:$hold" --
  relaunch_t4
  run_bin -0 --separate-stderr team-sweep
  assert_equal "$output$stderr" ""
  # So does a block logged after its stow.
  held_pair -- "blocked:{reason: \"the fixture server is down\"}"
  relaunch_t4
  run_bin -0 --separate-stderr team-sweep
  assert_equal "$output$stderr" ""
  # A wait logged before the stow is the stowed planner's own interview, which its relaunch resumes.
  held_pair "waiting:{on: \"Daniel\", reason: \"interview in <#1563>\"}" --
  relaunch_t4
  run_bin -1 team-sweep
  assert_equal "$output" "level: T3 fits again: relaunch its planner"
  # A resumed lifts the hold (and the stow's pause, so T3's own findings come back too).
  held_pair "held:$hold" -- "resumed:{}"
  relaunch_t4
  run_bin -1 team-sweep --json
  assert_equal "$(jq -r '.[] | select(.task == null) | .text' <<<"$output")" "level: T3 fits again: relaunch its planner"
}

@test "T278's D1: Daniel's typed hold logged before a level stow keeps level-resume quiet; an outside wait before it does not" {
  level_record minor
  capacity_reading 0 8
  # T3 is held by Daniel before its stow, T4 relaunched: T3 is on hold, and nothing is named.
  held_pair 'held:{reason: "Daniel: not before the release", cause: "daniel-hold", discord_message: "1500000000000000001"}' --
  relaunch_t4
  run_bin -0 --separate-stderr team-sweep
  assert_equal "$output$stderr" ""
  run_bin -0 team-capacity plan --json
  assert_equal "$(jq -c '.resume | map([.task, .hold])' <<<"$output")" '[["T3","held: Daniel: not before the release"]]'
  # An outside wait before the stow was the stowed worker's own state, which its relaunch resumes.
  held_pair 'waiting:{on: "CI", cause: "outside", reason: "the runner queue"}' --
  relaunch_t4
  run_bin -1 team-sweep
  assert_equal "$output" "level: T3 fits again: relaunch its planner"
  # An ask before the stow that no launch went past holds it, wherever it was logged.
  held_pair 'asked:{id: "q1", text: "Which name?"}' --
  relaunch_t4
  run_bin -0 --separate-stderr team-sweep
  assert_equal "$output$stderr" ""
}

@test "level-launch: a launch refused for room, not stowed, is named once its role fits again, until it launches" {
  # T5's builder opened its PR; the coordinator's reviewer launch was refused for room at minor.
  level_task T5 03:00 builder:5b5b5b5b
  ledger_line '{ts: "2026-10-22T04:30:00Z", task: "T5", event: "pr", url: "https://github.com/owner/proj/pull/5", head: "a1b2c3d"}'
  ledger_line '{ts: "2026-10-22T04:40:00Z", task: "T5", event: "paused",
    reason: "team-worker: no room for session:reviewer at minor (30%): 9.3 GiB of 9.6 GiB reserved, a reviewer needs 0.5 GiB; room comes when the team'"'"'s work shrinks or the level rises"}'
  level_record minor
  # A closed task's session leaves 0.3 GiB: no room yet, and T5, paused, finds nothing else.
  capacity_reading 0 8 T9:builder:9c9c9c9c:9.3
  run_bin -0 --separate-stderr team-sweep
  assert_equal "$output$stderr" ""
  # Room for a reviewer: the finding names T5's launch.
  capacity_reading 0 8 T9:builder:9c9c9c9c:8.9
  run_bin -1 team-sweep --json
  assert_equal "$(jq -c . <<<"$output")" '[{"task":null,"kind":"level-launch","session":null,"name":null,"next":"launch its reviewer","text":"level: T5 has room again: launch its reviewer, refused for room at 2026-10-22T04:40:00Z"}]'
  # At none nothing fits.
  level_record none
  run_bin -0 team-sweep
  assert_equal "$output" ""
  # Once the reviewer launches it waits for nothing.
  level_record minor
  ledger_line '{ts: "2026-10-22T05:00:00Z", task: "T5", event: "launch", role: "reviewer", session: "5e5e5e5e",
    worktree: "/w/5", toolkits: []}'
  sessions "$(session 5e5e5e5e T5-reviewer busy working)"
  run_bin -0 team-sweep
  assert_equal "$output" ""
}

# refused_t5 [<T5 event>...] -- [<T5 event>...]: the ledger afresh, T5's builder launched and its
# PR opened, then its reviewer's launch refused for room at 04:40, with each T5 event
# (<kind>:<jq object of more fields>) logged before the refusal, or after it when it follows the --.
refused_t5() {
  local spec at=04:35
  : >"$TEAM_HOME/ledger.jsonl"
  level_task T5 03:00 builder:5b5b5b5b
  ledger_line '{ts: "2026-10-22T04:30:00Z", task: "T5", event: "pr", url: "https://github.com/owner/proj/pull/5", head: "a1b2c3d"}'
  for spec in "$@"; do
    if [[ $spec == -- ]]; then
      ledger_line '{ts: "2026-10-22T04:40:00Z", task: "T5", event: "paused",
        reason: "team-worker: no room for session:reviewer at minor (30%): 9.3 GiB of 9.6 GiB reserved, a reviewer needs 0.5 GiB"}'
      at=04:50
    else
      ledger_line --arg e "${spec%%:*}" --arg ts "2026-10-22T$at:00Z" "{ts: \$ts, task: \"T5\", event: \$e} + ${spec#*:}"
    fi
  done
}

@test "level-launch: a refused launch held, or waiting or blocked since its refusal, is never named, until resumed" {
  level_record minor
  # Room for a reviewer.
  capacity_reading 0 8 T9:builder:9c9c9c9c:8.9
  local level='.[] | select(.task == null) | .text'
  # Held after the refusal: no level finding.
  refused_t5 -- 'held:{reason: "on hold by Daniel (1500000000000000001)"}'
  run_bin team-sweep --json
  assert_equal "$(jq -r "$level" <<<"$output")" ""
  # Held before it holds it too, since a held stands wherever it falls.
  refused_t5 'held:{reason: "on hold by Daniel (1500000000000000001)"}' --
  run_bin team-sweep --json
  assert_equal "$(jq -r "$level" <<<"$output")" ""
  # Waiting on Daniel, or blocked, since the refusal: none.
  refused_t5 -- 'waiting:{on: "Daniel", reason: "on hold by Daniel (1500000000000000001)"}'
  run_bin team-sweep --json
  assert_equal "$(jq -r "$level" <<<"$output")" ""
  refused_t5 -- 'blocked:{reason: "the fixture server is down"}'
  run_bin team-sweep --json
  assert_equal "$(jq -r "$level" <<<"$output")" ""
  # A wait before the refusal did not stop the launch tried then, so the finding names T5.
  refused_t5 'waiting:{on: "Daniel", reason: "the merge"}' --
  run_bin team-sweep --json
  assert_equal "$(jq -r "$level" <<<"$output")" "level: T5 has room again: launch its reviewer, refused for room at 2026-10-22T04:40:00Z"
  # A resumed lifts the hold.
  refused_t5 'held:{reason: "on hold by Daniel (1500000000000000001)"}' 'resumed:{}' --
  run_bin team-sweep --json
  assert_equal "$(jq -r "$level" <<<"$output")" "level: T5 has room again: launch its reviewer, refused for room at 2026-10-22T04:40:00Z"
  # A resumed after the refusal ends the refusal too, since the refusal is a standing park and a
  # resumed with no id, all or brief ends every park (T278's A4: parked and refused_launches
  # agree), so nothing is named.
  refused_t5 -- 'held:{reason: "on hold by Daniel (1500000000000000001)"}' 'resumed:{}'
  run_bin team-sweep --json
  assert_equal "$(jq -r "$level" <<<"$output")" ""
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

# A parallel phase of <task>: its plan approved at cap 2, and ticket <NN>'s worktree /w/<NN>
# added for each <NN> after it.
parallel_phase() {
  local task=$1 n
  opened "$task"
  event "$task" plan-approved '{by: "Daniel", parallel: "2"}'
  for n in "${@:2}"; do
    event "$task" worktree-added "{project: \"proj\", branch: \"feat/$task-work--$n\", base: \"feat/$task-work\",
      base_sha: \"0123456\", worktree: \"/w/$n\", ticket: \"$n\"}"
  done
}

# ticket_launch <task> <NN> <session> [<ts>]: ticket NN's builder launched in its ticket worktree.
ticket_launch() {
  ledger_line --arg t "$1" --arg n "$2" --arg s "$3" --arg ts "${4:-2026-10-22T02:10:00Z}" \
    '{ts: $ts, task: $t, event: "launch", role: "builder", session: $s, worktree: "/w/\($n)", toolkits: [],
      project: "proj", branch: "feat/\($t)-work--\($n)", brief: "brief-build-\($n)", ticket: $n}'
}

@test "T287: each ticket builder is judged by its own events, silent beside a busy one and at work until its ticket is done" {
  parallel_phase T7 02 03
  ticket_launch T7 03 33333333
  ticket_launch T7 02 22222222 2026-10-22T02:12:00Z
  # T7-builder-03's launch is not the task's last event, but nothing since names it: it is silent.
  sessions "$(session 22222222 T7-builder-02 busy working)" "$(session 33333333 T7-builder-03 idle)"
  run_bin -1 team-sweep
  assert_equal "$output" "T7 silent: T7-builder-03 33333333 is idle with no ledger event since its launch at 2026-10-22T02:10:00Z; next: read claude logs 33333333, then send it one line or log what is known with team-log"
  # Its own pause names it, and parks only its ticket: the task is still watched, and 02 is busy.
  event T7 paused '{reason: "waiting on the gate", cause: "worker", role: "builder", session: "33333333"}'
  run_bin -0 team-sweep
  # T7-builder-02 idle with nothing naming it since its launch is silent in its turn, by its own launch.
  sessions "$(session 22222222 T7-builder-02 idle)" "$(session 33333333 T7-builder-03 idle)"
  run_bin -1 team-sweep
  assert_equal "$output" "T7 silent: T7-builder-02 22222222 is idle with no ledger event since its launch at 2026-10-22T02:12:00Z; next: read claude logs 22222222, then send it one line or log what is known with team-log"
  # Once its pause ends, 03 idle with an event of its own since, but its ticket not done, is still
  # at work, so the task has a worker though every live session is idle.
  event T7 resumed '{id: "paused-1"}'
  event T7 ticket-done '{ticket: "02", commits: ["abc1234"], head: "abc1234"}'
  event T7 worktree-returned '{project: "proj", worktree: "/w/02", ticket: "02"}'
  run_bin -0 team-sweep
  # Its ticket done, it has handed back like any worker.
  event T7 ticket-done '{ticket: "03", commits: ["bcd2345"], head: "bcd2345"}'
  event T7 worktree-returned '{project: "proj", worktree: "/w/03", ticket: "03"}'
  run_bin -1 team-sweep
  assert_equal "$output" "T7 no-worker: every live worker is idle with a ledger event since its launch (latest T7-builder-02 22222222); next: send it its next step or launch the next worker with team-worker, or log why the task waits with team-log"
  no_github
}

@test "T287: ticket-gone names a running ticket whose builder's session is gone, in place of no-worker, but not a stowed or parked one" {
  parallel_phase T7 02 03
  ticket_launch T7 02 22222222
  ticket_launch T7 03 33333333
  sessions "$(session 33333333 T7-builder-03 busy working)"
  run_bin -1 team-sweep
  assert_equal "$output" "T7 ticket-gone: ticket 02: its builder T7-builder-02 22222222 is gone with the ticket not done; next: recover it (the recover-worker skill)"
  run_bin -1 team-sweep --json
  assert_equal "$(jq -c '.[] | [.task, .kind, .session, .name]' <<<"$output")" '["T7","ticket-gone","22222222","T7-builder-02"]'
  # Both gone: one line each, and no no-worker beside them.
  sessions
  run_bin -1 team-sweep
  assert_equal "$output" "T7 ticket-gone: ticket 02: its builder T7-builder-02 22222222 is gone with the ticket not done; next: recover it (the recover-worker skill)
T7 ticket-gone: ticket 03: its builder T7-builder-03 33333333 is gone with the ticket not done; next: recover it (the recover-worker skill)"
  # A ticket done is not running; a park naming the session of 03's builder, its answer to STOW,
  # stands for it.
  event T7 ticket-done '{ticket: "02", commits: ["abc1234"], head: "abc1234"}'
  event T7 worktree-returned '{project: "proj", worktree: "/w/02", ticket: "02"}'
  event T7 paused '{reason: "stowed", cause: "stow", role: "builder", session: "33333333"}'
  run_bin -0 team-sweep
  # A stowed after the launch stands for it too, though the park has ended.
  event T7 resumed '{id: "paused-1"}'
  run_bin -1 team-sweep
  assert_contains "$output" "T7 ticket-gone: ticket 03"
  event T7 stowed '{machine: "home-pc", cause: "level", roles: ["builder"], worktrees: []}'
  run_bin -1 team-sweep
  assert_equal "$output" "T7 no-worker: no live session among its 2 launches (latest T7-builder-03 33333333); next: read claude logs 33333333 for how it ended, then launch the next worker with team-worker or log what is known with team-log"
  # The relaunch of ticket 03 after the stow is running again, and gone again once its session is.
  ticket_launch T7 03 34343434
  run_bin -1 team-sweep
  assert_equal "$output" "T7 ticket-gone: ticket 03: its builder T7-builder-03 34343434 is gone with the ticket not done; next: recover it (the recover-worker skill)"
  no_github
}

@test "T287: ticket-worktree-left names a done ticket's worktree still open, until it is returned, but not a stowed or parked one" {
  parallel_phase T7 02 03
  ticket_launch T7 02 22222222
  ticket_launch T7 03 33333333
  event T7 ticket-done '{ticket: "02", commits: ["abc1234"], head: "abc1234"}'
  sessions "$(session 22222222 T7-builder-02 busy working)" "$(session 33333333 T7-builder-03 busy working)"
  run_bin -1 team-sweep
  assert_equal "$output" "T7 ticket-worktree-left: ticket 02 is done, but its worktree /w/02 is still open; next: team-close T7 --ticket 02"
  run_bin -1 team-sweep --json
  assert_equal "$(jq -c '.[] | [.task, .kind, .session, .name]' <<<"$output")" '["T7","ticket-worktree-left",null,null]'
  # A stow after the ticket-done keeps it with the task's other worktrees.
  event T7 stowed '{machine: "home-pc", cause: "level", roles: ["builder"], worktrees: []}'
  run_bin -0 team-sweep
  # A worktree of ticket 02 added again after its ticket-done is not left until its ticket is done again.
  event T7 worktree-added '{project: "proj", branch: "feat/T7-work--02", base: "feat/T7-work", base_sha: "0123456", worktree: "/w/02", ticket: "02"}'
  run_bin -0 team-sweep
  event T7 ticket-done '{ticket: "02", commits: ["abc1234"], head: "abc1234"}'
  run_bin -1 team-sweep
  assert_contains "$output" "T7 ticket-worktree-left: ticket 02"
  # A park of its ticket standing (a room refusal of its brief) stands for it.
  event T7 paused '{reason: "no room for session:builder", cause: "room", role: "builder", brief: "brief-build-02"}'
  run_bin -0 team-sweep
  event T7 resumed '{id: "paused-1"}'
  run_bin -1 team-sweep
  event T7 worktree-returned '{project: "proj", worktree: "/w/02", ticket: "02"}'
  run_bin -0 team-sweep
  no_github
}

@test "T287: a room refusal of a ticket builder's relaunch parks only its ticket, so the builders beside it are still watched" {
  parallel_phase T7 02 03
  ticket_launch T7 02 22222222
  ticket_launch T7 03 33333333
  event T7 stowed '{machine: "home-pc", cause: "level", roles: ["builder"], worktrees: []}'
  # team-next --fill relaunches 02, and 03's relaunch is refused for room on its resume brief.
  ticket_launch T7 02 24242424 2026-10-22T02:20:00Z
  event T7 paused '{reason: "no room for session:builder", cause: "room", role: "builder", brief: "brief-resume-build-03"}'
  sessions "$(session 24242424 T7-builder-02 idle)"
  run_bin -1 team-sweep
  assert_equal "$output" "T7 silent: T7-builder-02 24242424 is idle with no ledger event since its launch at 2026-10-22T02:20:00Z; next: read claude logs 24242424, then send it one line or log what is known with team-log"
  # A later resume brief of the same ticket, -2 after its name, is that ticket's too.
  event T7 resumed '{id: "paused-1"}'
  event T7 paused '{reason: "no room for session:builder", cause: "room", role: "builder", brief: "brief-resume-build-03-2"}'
  run_bin -1 team-sweep
  assert_contains "$output" "T7 silent: T7-builder-02 24242424"
  # Ended only by a launch of ticket 03.
  ticket_launch T7 02 25252525 2026-10-22T02:30:00Z
  sessions "$(session 25252525 T7-builder-02 busy working)"
  run_bin -0 team-sweep
  ticket_launch T7 03 35353535 2026-10-22T02:40:00Z
  run_bin -1 team-sweep
  assert_equal "$output" "T7 ticket-gone: ticket 03: its builder T7-builder-03 35353535 is gone with the ticket not done; next: recover it (the recover-worker skill)"
  no_github
}

@test "T287: a stow where one ticket builder answered and another was stopped parks the task, with no no-worker" {
  parallel_phase T7 02 03
  ticket_launch T7 02 22222222
  ticket_launch T7 03 33333333
  # 02's builder answered STOW; 03's did not in time, and team-stow stopped it as it stood.
  event T7 paused '{reason: "stowed", cause: "stow", role: "builder", session: "22222222"}'
  event T7 stowed '{machine: "home-pc", cause: "level", roles: ["builder"], worktrees: []}'
  sessions
  run_bin -0 team-sweep
  assert_equal "$output" ""
  # Ticket 03 relaunched after the stow is no longer accounted for by it: gone again, it is named.
  ticket_launch T7 03 34343434 2026-10-22T02:20:00Z
  run_bin -1 team-sweep
  assert_equal "$output" "T7 ticket-gone: ticket 03: its builder T7-builder-03 34343434 is gone with the ticket not done; next: recover it (the recover-worker skill)"
  no_github
}

@test "T287: a ticket builder of a closed or unknown task is a stray, by its session's name" {
  parallel_phase T7 02
  ticket_launch T7 02 22222222
  event T7 closed '{archive: [], returned: [], kept: []}'
  sessions "$(session 22222222 T7-builder-02 idle)" "$(session 44444444 T44-builder-03 busy working)"
  run_bin -1 team-sweep
  assert_equal "$output" "T7 stray: T7-builder-02 22222222 is live but T7 is closed; next: read claude logs 22222222 for anything left to log, then stop it with claude stop 22222222
T44 stray: T44-builder-03 44444444 is live but T44 is not in the ledger; next: read claude logs 44444444 for anything left to log, then stop it with claude stop 44444444"
}
