#!/usr/bin/env bats
# The library's ledger_append: every script's event is checked against the ledger contract,
# including that the script appending it is the kind's writer.

load helpers/common

setup() {
  sandbox
  mkdir -p "$BATS_TEST_TMPDIR/bin"
}

# Run a script named <name> that sources this checkout's library and appends <event>.
append_as() {
  local script=$BATS_TEST_TMPDIR/bin/$1
  cat >"$script" <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail
source "$REPO_ROOT/bin/lib/team.sh" "\$@"
ledger_append "\$1"
SCRIPT
  chmod +x "$script"
  guard_sandbox
  run "$script" "$2"
}

@test "an event that meets the contract is appended by its writer" {
  append_as team-thread '{"ts":"2026-10-22T02:00:00Z","task":"T7","event":"thread","discord_thread":"1563"}'
  assert_equal "$status" "0"
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" '{"ts":"2026-10-22T02:00:00Z","task":"T7","event":"thread","discord_thread":"1563"}'
}

@test "an event is refused, with nothing appended, when it breaks the contract" {
  append_as team-thread '{"ts":"2026-10-22T02:00:00Z","task":"T7","event":"thread"}'
  assert_equal "$status" "1"
  assert_contains "$output" "team-thread: refusing a ledger event: thread needs discord_thread"
  # A Discord id is a string of digits when appended; --check alone takes the number dev wrote.
  append_as team-thread '{"ts":"2026-10-22T02:00:00Z","task":"T7","event":"thread","discord_thread":1563}'
  assert_contains "$output" "discord_thread must be a Discord id, a string of digits, got a number"
  append_as team-thread '{"ts":"2026-10-22T02:00:00Z","task":"T7","event":"thread","discord_thread":"t1563"}'
  assert_contains "$output" "discord_thread must be a Discord id, a string of digits, got a string that is not one"
  append_as team-thread '{"task":"T7","event":"thread","discord_thread":"1563"}'
  assert_contains "$output" "missing ts"
  append_as team-thread '{"ts":"2026-10-22T02:00:00Z","task":"T7","event":"thred","discord_thread":"1563"}'
  assert_contains "$output" "unknown event kind 'thred'"
  append_as team-thread '["not", "an object"]'
  assert_contains "$output" "not a JSON object for the ledger"
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" ""
}

@test "a review whose sent_back holds whole numbers as strings is refused, a form only --check takes" {
  local review='{"ts":"2026-10-27T02:00:00Z","task":"T7","event":"review","verdict":"findings","head":"a1b2c3d","findings":{"blocking":1,"correctness":0,"security":0,"real-data":0,"note-change":0,"note-before":0},"guarded":[]'
  append_as team-log "$review,\"sent_back\":[\"5\"]}"
  assert_equal "$status" "1"
  assert_contains "$output" 'team-log: refusing a ledger event: sent_back must be a list of whole numbers, got "5"'
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" ""
  append_as team-log "$review,\"sent_back\":[5]}"
  assert_equal "$status" "0"
}

@test "a launch may name its model, as a string, written by team-worker" {
  local launch='{"ts":"2026-10-27T02:00:00Z","task":"T7","event":"launch","role":"reviewer","session":"4f2a9c1e","worktree":"/w","toolkits":[]'
  append_as team-worker "$launch,\"model\":\"sonnet\"}"
  assert_equal "$status" "0"
  append_as team-worker "$launch,\"model\":5}"
  assert_equal "$status" "1"
  assert_contains "$output" "model must be a string, got a number"
  append_as team-worker "$launch}"
  assert_equal "$status" "0"
  assert_equal "$(jq -c '.model' "$TEAM_HOME/ledger.jsonl")" $'"sonnet"\nnull'
}

@test "legacy shapes are refused at append time, whatever their ts" {
  append_as team-close '{"ts":"2026-10-01T00:00:00Z","task":"T1","event":"closed"}'
  assert_equal "$status" "1"
  assert_contains "$output" "closed needs archive"
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" ""
}

@test "an event is refused when the appending script is not the kind's writer" {
  append_as team-log '{"ts":"2026-10-22T02:00:00Z","task":"T7","event":"thread","discord_thread":"1563"}'
  assert_equal "$status" "1"
  assert_contains "$output" "thread events are written by team-thread, not team-log"
  append_as team-thread '{"ts":"2026-10-22T02:00:00Z","task":"T7","event":"resumed"}'
  assert_contains "$output" "resumed events are written by team-log or team-answer, not team-thread"
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" ""
}

@test "a plan-time merge approval, its withdrawal, a review's finding fields and a merge's approval meet the contract" {
  local at='"ts":"2026-10-31T02:00:00Z","task":"T7"'
  append_as team-log "{$at,\"event\":\"merge-preapproved\",\"project\":\"proj\",\"ask\":\"plan\",\"discord_message\":\"1563\",\"scope\":[\"src/\"]}"
  assert_equal "$status" "0"
  append_as team-log "{$at,\"event\":\"merge-preapproval-withdrawn\",\"project\":\"proj\",\"discord_message\":\"1564\"}"
  assert_equal "$status" "0"
  append_as team-log "{$at,\"event\":\"review\",\"verdict\":\"pass\",\"head\":\"a1b2c3d\",\"findings\":{\"note\":1},\"guarded\":[]}"
  assert_equal "$status" "0"
  append_as team-merge "{$at,\"event\":\"merged\",\"pr\":5,\"merge\":\"b2c3d4e\",\"head\":\"a1b2c3d\",\"by\":\"m\",\"approval\":\"plan\"}"
  assert_equal "$status" "0"
  assert_equal "$(jq -r .event "$TEAM_HOME/ledger.jsonl")" "merge-preapproved
merge-preapproval-withdrawn
review
merged"

  append_as team-log "{$at,\"event\":\"merge-preapproved\",\"project\":\"proj\",\"ask\":\"plan\",\"discord_message\":\"1563\",\"scope\":\"src/\"}"
  assert_contains "$output" "scope must be a list, got a string"
  append_as team-log "{$at,\"event\":\"merge-preapproved\",\"project\":\"proj\",\"discord_message\":\"1563\",\"scope\":[]}"
  assert_contains "$output" "merge-preapproved needs ask"
  append_as team-log "{$at,\"event\":\"merge-preapproval-withdrawn\",\"discord_message\":\"1564\"}"
  assert_contains "$output" "merge-preapproval-withdrawn needs project"
  append_as team-merge "{$at,\"event\":\"merge-preapproved\",\"project\":\"proj\",\"ask\":\"plan\",\"discord_message\":\"1563\",\"scope\":[\"src/\"]}"
  assert_contains "$output" "merge-preapproved events are written by team-log, not team-merge"
  append_as team-log "{$at,\"event\":\"review\",\"verdict\":\"pass\",\"head\":\"a1b2c3d\",\"findings\":[1],\"guarded\":{}}"
  assert_contains "$output" "findings must be an object, got a list; guarded must be a list, got an object"
  append_as team-merge "{$at,\"event\":\"merged\",\"pr\":5,\"merge\":\"b2c3d4e\",\"head\":\"a1b2c3d\",\"by\":\"m\",\"approval\":\"per-head\"}"
  assert_contains "$output" "approval must be one of head, plan"
  assert_equal "$(wc -l <"$TEAM_HOME/ledger.jsonl")" "4"
}

@test "a standing merge word and its withdrawal meet the contract, each naming a project, a message and its channel" {
  local at='"ts":"2026-11-01T02:00:00Z","task":"T7"' said='"discord_message":"1566","discord_channel":"1562"'
  append_as team-log "{$at,\"event\":\"merge-standing\",\"project\":\"all\",$said}"
  assert_equal "$status" "0"
  append_as team-log "{$at,\"event\":\"merge-standing-withdrawn\",\"project\":\"proj\",$said}"
  assert_equal "$status" "0"
  assert_equal "$(jq -r .event "$TEAM_HOME/ledger.jsonl")" "merge-standing
merge-standing-withdrawn"

  local kind
  for kind in merge-standing merge-standing-withdrawn; do
    append_as team-log "{$at,\"event\":\"$kind\",$said}"
    assert_contains "$output" "$kind needs project"
    append_as team-log "{$at,\"event\":\"$kind\",\"project\":\"proj\",\"discord_message\":\"1566\"}"
    assert_contains "$output" "$kind needs discord_channel"
    append_as team-log "{$at,\"event\":\"$kind\",\"project\":\"proj\",\"discord_channel\":\"1562\"}"
    assert_contains "$output" "$kind needs discord_message"
    append_as team-log "{$at,\"event\":\"$kind\",\"project\":[\"proj\"],$said}"
    assert_contains "$output" "project must be a string, got a list"
    append_as team-log "{$at,\"event\":\"$kind\",\"project\":\"proj\",\"discord_message\":\"1566\",\"discord_channel\":\"#coordinator\"}"
    assert_contains "$output" "discord_channel must be a Discord id"
    append_as team-merge "{$at,\"event\":\"$kind\",\"project\":\"proj\",$said}"
    assert_contains "$output" "$kind events are written by team-log, not team-merge"
  done
  assert_equal "$(wc -l <"$TEAM_HOME/ledger.jsonl")" "2"
}

@test "a kind with several writers is appended by each of them, and refused from any other" {
  append_as team-ask '{"ts":"2026-10-22T02:00:00Z","task":"T7","event":"asked","id":"q1","text":"Which?"}'
  assert_equal "$status" "0"
  append_as team-answer '{"ts":"2026-10-22T02:00:01Z","task":"T7","event":"answered","id":"q1","answer":"That one"}'
  assert_equal "$status" "0"
  append_as team-ask '{"ts":"2026-10-22T02:00:02Z","task":"T7","event":"answered","id":"q1","answer":"That one"}'
  assert_equal "$status" "1"
  assert_contains "$output" "answered events are written by team-log or team-answer, not team-ask"
  assert_equal "$(jq -r .event "$TEAM_HOME/ledger.jsonl")" "asked
answered"
}

@test "team-thread's event passes the strict check" {
  stub_reply curl '{"id":"1563000000000000001"}'
  run_bin -0 team-thread T7 conventioner "Sign-in limits"
  run_bin -0 team-log --check
}

# The library's unfinished_roles over a task's events, given one JSON event per line.
unfinished_roles() {
  jq -L "$REPO_ROOT/bin/lib" -sc 'include "ledger"; map({ts: "2026-10-24T12:00:00Z", task: "T1"} + .) | unfinished_roles'
}

@test "a builder that delivered a PR is finished: pr ends a builder, as done, review and ticket-done end theirs" {
  assert_equal "$(unfinished_roles <<'EVENTS'
{"event": "launch", "role": "builder"}
{"event": "pr", "url": "https://github.com/o/r/pull/3", "head": "abc1234"}
EVENTS
)" '[]'
  # A pr ends no other role.
  assert_equal "$(unfinished_roles <<'EVENTS'
{"event": "launch", "role": "reviewer"}
{"event": "pr", "url": "https://github.com/o/r/pull/3", "head": "abc1234"}
EVENTS
)" '["reviewer"]'
  # A builder launched again after its pr, to fix review findings, is unfinished.
  assert_equal "$(unfinished_roles <<'EVENTS'
{"event": "launch", "role": "builder"}
{"event": "pr", "url": "https://github.com/o/r/pull/3", "head": "abc1234"}
{"event": "launch", "role": "reviewer"}
{"event": "review", "verdict": "findings", "head": "abc1234"}
{"event": "launch", "role": "builder"}
EVENTS
)" '["builder"]'
}

@test "the unfinished roles are those launched since the latest stowed that no later event ended, never ops" {
  assert_equal "$(unfinished_roles <<'EVENTS'
{"event": "launch", "role": "planner"}
{"event": "stowed", "machine": "home-pc", "worktrees": [], "roles": ["planner"], "sessions": ["planner"]}
{"event": "launch", "role": "builder"}
{"event": "launch", "role": "reviewer"}
{"event": "review", "verdict": "pass", "head": "abc1234"}
{"event": "done", "role": "reviewer", "session": "6493aef7"}
{"event": "launch", "role": "ops", "toolkits": ["prod-read"], "request": "https://discord.com/channels/1/2/3"}
EVENTS
)" '["builder"]'
}

@test "a stowed may give its cause, level or handoff, and team-stow alone writes it" {
  local stowed='{"ts":"2026-11-01T14:05:00Z","task":"T7","event":"stowed","machine":"home-pc","worktrees":[],"roles":[],"sessions":[]'
  append_as team-stow "$stowed,\"cause\":\"level\"}"
  assert_equal "$status" "0"
  append_as team-stow "$stowed,\"cause\":\"handoff\"}"
  assert_equal "$status" "0"
  append_as team-stow "$stowed}"
  assert_equal "$status" "0"
  assert_equal "$(jq -r '.cause // "none"' "$TEAM_HOME/ledger.jsonl" | paste -sd ' ')" "level handoff none"
  append_as team-stow "$stowed,\"cause\":\"shutdown\"}"
  assert_equal "$status" "1"
  assert_contains "$output" "cause must be one of level, handoff"
  append_as team-log "$stowed,\"cause\":\"level\"}"
  assert_contains "$output" "stowed events are written by team-stow, not team-log"
  append_as team-handoff "$stowed}"
  assert_contains "$output" "stowed events are written by team-stow, not team-handoff"
}

# Whether the task of the events read from stdin, one JSON object per line, is stowed, waiting to
# resume.
awaiting() {
  jq -L "$REPO_ROOT/bin/lib" -sc 'include "ledger"; map({ts: "2026-11-01T12:00:00Z", task: "T1"} + .) | stowed_awaiting_resume'
}

@test "a task is stowed, waiting to resume, while its latest stowed, for the level or a handoff, names roles and no launch follows it" {
  local launch='{"event": "launch", "role": "builder"}'
  local level='{"event": "stowed", "machine": "home-pc", "worktrees": [], "roles": ["builder"], "cause": "level"}'
  local handoff='{"event": "stowed", "machine": "home-pc", "worktrees": [], "roles": ["builder"], "cause": "handoff"}'
  local legacy='{"event": "stowed", "machine": "home-pc", "worktrees": [], "roles": ["builder"]}'
  local idle='{"event": "stowed", "machine": "home-pc", "worktrees": [], "roles": [], "cause": "handoff"}'
  assert_equal "$(awaiting <<<"$launch")" false
  assert_equal "$(printf '%s\n' "$launch" "$level" | awaiting)" true
  assert_equal "$(printf '%s\n' "$launch" "$level" '{"event": "done", "role": "builder"}' | awaiting)" true
  assert_equal "$(printf '%s\n' "$launch" "$level" "$launch" | awaiting)" false
  # A handoff's stow waits too, a stowed with no cause (every line before team-stow) included, so
  # a task the resume could not relaunch comes back when room does.
  assert_equal "$(printf '%s\n' "$launch" "$handoff" | awaiting)" true
  assert_equal "$(printf '%s\n' "$launch" "$legacy" | awaiting)" true
  assert_equal "$(printf '%s\n' "$launch" "$handoff" "$launch" | awaiting)" false
  # A stow with no role to relaunch waits for nothing.
  assert_equal "$(printf '%s\n' "$launch" "$level" "$idle" | awaiting)" false
}

@test "a branch-renamed gives the task's worktree in its project its new branch, in task_branch, open_worktrees and worktree_list" {
  local events='{"event": "opened", "project": "proj", "branch": "feat/T1-x", "worktree": "/w/1", "path": "feature"}
{"event": "worktree-added", "project": "lib", "branch": "feat/T1-lib", "worktree": "/w/2"}
{"event": "branch-renamed", "project": "proj", "branch": "feat/T1-x-fresh"}'
  local lib=(jq -L "$REPO_ROOT/bin/lib" -sc)
  assert_equal "$("${lib[@]}" 'include "ledger"; [task_branch("proj"), task_branch("lib"), task_branch("other")]' <<<"$events")" \
    '["feat/T1-x-fresh","feat/T1-lib",null]'
  assert_equal "$("${lib[@]}" 'include "ledger"; map({task: "T1"} + .) | [open_worktrees(.[]; "/home/x") | [.project, .branch]]' <<<"$events")" \
    '[["proj","feat/T1-x-fresh"],["lib","feat/T1-lib"]]'
  assert_equal "$("${lib[@]}" 'include "ledger"; [worktree_list[] | [.project, .branch]]' <<<"$events")" \
    '[["proj","feat/T1-x-fresh"],["lib","feat/T1-lib"]]'
}

@test "a branch-renamed meets the contract, written by team-log" {
  local at='"ts":"2026-10-31T02:00:00Z","task":"T7"'
  append_as team-log "{$at,\"event\":\"branch-renamed\",\"project\":\"proj\",\"branch\":\"feat/T7-x-fresh\"}"
  assert_equal "$status" "0"
  append_as team-log "{$at,\"event\":\"branch-renamed\",\"project\":\"proj\"}"
  assert_contains "$output" "branch-renamed needs branch"
  append_as team-open "{$at,\"event\":\"branch-renamed\",\"project\":\"proj\",\"branch\":\"feat/T7-x-fresh\"}"
  assert_contains "$output" "branch-renamed events are written by team-log, not team-open"
  assert_equal "$(wc -l <"$TEAM_HOME/ledger.jsonl")" "1"
}
