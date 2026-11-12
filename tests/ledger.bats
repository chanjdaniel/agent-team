#!/usr/bin/env bats
# The library's ledger_append: every script's event is checked against the ledger contract,
# including that the script appending it is the kind's writer.

load helpers/common

setup() {
  sandbox
  mkdir -p "$BATS_TEST_TMPDIR/bin"
}

# Run a script named <name> that sources this checkout's library (CODE_CHECKOUT's, when
# with_lifecycle_from made one) and appends <event>, waiting <seconds> for the ledger's lock when
# given: append_as <name> <event> [<seconds>]
append_as() {
  local script=$BATS_TEST_TMPDIR/bin/$1
  cat >"$script" <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail
source "${CODE_CHECKOUT:-$REPO_ROOT}/bin/lib/team.sh" "\$@"
ledger_append "\$1" \${2:+"\$2"}
SCRIPT
  chmod +x "$script"
  guard_sandbox
  run "$script" "${@:2}"
}

# The ledger's lines after the thread and opened of opened_task.
after_opened() {
  tail -n +3 "$TEAM_HOME/ledger.jsonl"
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

@test "an event that is not JSON, or more than one object, is refused as such, and a broken ledger.jq shows jq's own error" {
  append_as team-thread 'not json'
  assert_equal "$status" "1"
  assert_equal "$output" "team-thread: not a JSON object for the ledger: not json"
  append_as team-thread '{"a": 1} {"b": 2}'
  assert_equal "$status" "1"
  assert_equal "$output" 'team-thread: not one JSON object for the ledger: {"a": 1} {"b": 2}'
  mkdir "$BATS_TEST_TMPDIR/code"
  copy_bin "$BATS_TEST_TMPDIR/code/bin"
  rm "$BATS_TEST_TMPDIR/code/bin/lib/ledger.jq"
  echo 'def broken: (;' >"$BATS_TEST_TMPDIR/code/bin/lib/ledger.jq"
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' "source \"$BATS_TEST_TMPDIR/code/bin/lib/team.sh\" \"\$@\"" \
    'ledger_append "$1"' >"$BATS_TEST_TMPDIR/bin/team-thread"
  chmod +x "$BATS_TEST_TMPDIR/bin/team-thread"
  run "$BATS_TEST_TMPDIR/bin/team-thread" '{"ts":"2026-10-22T02:00:00Z","task":"T7","event":"thread","discord_thread":"1563"}'
  assert_equal "$status" "1"
  assert_contains "$output" "jq: error: syntax error"
  [[ $output != *"not a JSON object"* ]]
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl" 2>/dev/null)" ""
}

@test "a review whose sent_back holds whole numbers as strings is refused, a form only --check takes" {
  opened_task T7
  local review='{"ts":"2026-10-27T02:00:00Z","task":"T7","event":"review","verdict":"findings","head":"a1b2c3d","findings":{"blocking":1,"correctness":0,"security":0,"real-data":0,"note-change":0,"note-before":0},"guarded":[]'
  append_as team-log "$review,\"sent_back\":[\"5\"]}"
  assert_equal "$status" "1"
  assert_contains "$output" 'team-log: refusing a ledger event: sent_back must be a list of whole numbers, got "5"'
  assert_equal "$(after_opened)" ""
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

@test "an ops launch may name its request's discord_message, an id; no other role's launch may" {
  local launch='{"ts":"2026-10-27T02:00:00Z","task":"T7","event":"launch","session":"4f2a9c1e","worktree":"/w","toolkits":["prod-read"],"request":"https://discord.com/channels/1/2/1564000000000000001"'
  append_as team-worker "$launch,\"role\":\"ops\",\"discord_message\":\"1564000000000000001\"}"
  assert_equal "$status" "0"
  append_as team-worker "$launch,\"role\":\"ops\",\"discord_message\":\"the request\"}"
  assert_equal "$status" "1"
  assert_contains "$output" "discord_message must be a Discord id, a string of digits, got a string that is not one"
  append_as team-worker "$launch,\"role\":\"builder\",\"discord_message\":\"1564000000000000002\"}"
  assert_equal "$status" "1"
  assert_contains "$output" 'team-worker: refusing a ledger event: a launch'"'"'s discord_message is only for role ops, not "builder"'
  assert_equal "$(jq -r .discord_message "$TEAM_HOME/ledger.jsonl")" 1564000000000000001
  # team-log --check holds the lines of the ledger to the same, from strict_from on.
  echo "$launch,\"role\":\"reviewer\",\"discord_message\":\"1564000000000000003\"}" >>"$TEAM_HOME/ledger.jsonl"
  run_bin -1 team-log --check
  assert_contains "$output" "a launch's discord_message is only for role ops, not \"reviewer\""
}

@test "a builder's launch may name its ticket; no other role's launch may" {
  local launch='{"ts":"2026-11-11T02:00:00Z","task":"T7","event":"launch","session":"4f2a9c1e","worktree":"/w","toolkits":[],"branch":"feat/T7-x--03"'
  append_as team-worker "$launch,\"role\":\"builder\",\"ticket\":\"03\"}"
  assert_equal "$status" "0"
  append_as team-worker "$launch,\"role\":\"reviewer\",\"ticket\":\"03\"}"
  assert_equal "$status" "1"
  assert_contains "$output" 'team-worker: refusing a ledger event: a launch'"'"'s ticket is only for role builder, not "reviewer"'
  assert_equal "$(jq -c '[.role, .ticket]' "$TEAM_HOME/ledger.jsonl")" '["builder","03"]'
}

@test "an ops done may carry its report's length and its relay, and a question its text or its length, one of them" {
  opened_task T7
  local at='"ts":"2026-11-09T02:00:00Z","task":"T7"'
  append_as team-log "{$at,\"event\":\"done\",\"role\":\"ops\",\"session\":\"d0000001\",\"report_chars\":412,\"relay\":\"1564000000000000001\"}"
  assert_equal "$status" "0"
  append_as team-log "{$at,\"event\":\"done\",\"role\":\"ops\",\"session\":\"d0000001\",\"report_chars\":\"412\"}"
  assert_equal "$status" "1"
  assert_contains "$output" "team-log: refusing a ledger event: report_chars must be a number, got a string"
  append_as team-log "{$at,\"event\":\"done\",\"role\":\"ops\",\"session\":\"d0000001\",\"report_chars\":412,\"relay\":\"the relay\"}"
  assert_equal "$status" "1"
  assert_contains "$output" "relay must be a Discord id, a string of digits, got a string that is not one"
  append_as team-log "{$at,\"event\":\"done\",\"role\":\"builder\",\"session\":\"b0000001\",\"report_chars\":12}"
  assert_equal "$status" "1"
  assert_contains "$output" 'team-log: refusing a ledger event: a done'"'"'s report_chars is only for role ops, not "builder"'
  append_as team-log "{$at,\"event\":\"done\",\"role\":\"builder\",\"session\":\"b0000001\",\"relay\":\"1564000000000000001\"}"
  assert_equal "$status" "1"
  assert_contains "$output" 'a done'"'"'s relay is only for role ops, not "builder"'
  append_as team-ask "{$at,\"event\":\"question\",\"role\":\"ops\",\"chars\":812,\"discord_message\":\"1564000000000000002\"}"
  assert_equal "$status" "0"
  append_as team-log "{$at,\"event\":\"question\",\"role\":\"builder\",\"text\":\"which store?\"}"
  assert_equal "$status" "0"
  append_as team-log "{$at,\"event\":\"question\",\"role\":\"ops\",\"text\":\"which store?\",\"chars\":12}"
  assert_equal "$status" "1"
  assert_contains "$output" "team-log: refusing a ledger event: a question takes text or chars, not both"
  append_as team-log "{$at,\"event\":\"question\",\"role\":\"ops\"}"
  assert_equal "$status" "1"
  assert_contains "$output" "team-log: refusing a ledger event: a question needs text or chars"
  append_as team-log "{$at,\"event\":\"question\",\"role\":\"builder\",\"text\":\"\"}"
  assert_equal "$status" "1"
  assert_contains "$output" "a question needs text or chars"
  append_as team-log "{$at,\"event\":\"question\",\"role\":\"builder\",\"chars\":12}"
  assert_equal "$status" "1"
  assert_contains "$output" 'a question'"'"'s chars is only for role ops, not "builder"'
  assert_equal "$(after_opened | jq -c '{event, role}')" '{"event":"done","role":"ops"}
{"event":"question","role":"ops"}
{"event":"question","role":"builder"}'
  # team-log --check holds the ledger's lines to the same, from strict_from on.
  echo "{$at,\"event\":\"question\",\"role\":\"ops\"}" >>"$TEAM_HOME/ledger.jsonl"
  run_bin -1 team-log --check
  assert_contains "$output" "ledger.jsonl:6: a question needs text or chars"
}

@test "an address at a public provider in a list's item is refused, naming the item and never the value" {
  local provider=gmail.com
  append_as team-worker '{"ts":"2026-10-27T02:00:00Z","task":"T7","event":"launch","role":"reviewer","session":"4f2a9c1e","worktree":"/w","toolkits":["browser","x@'"$provider"'"]}'
  assert_equal "$status" "1"
  assert_contains "$output" "team-worker: refusing a ledger event: toolkits.1 holds 1 email address at a public provider"
  [[ $output != *"x@$provider"* ]]
  [[ ! -s $TEAM_HOME/ledger.jsonl ]]
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
  opened_task T7
  local at='"ts":"2026-10-31T02:00:00Z","task":"T7"'
  append_as team-log "{$at,\"event\":\"merge-preapproved\",\"project\":\"proj\",\"ask\":\"plan\",\"discord_message\":\"1563\",\"scope\":[\"src/\"]}"
  assert_equal "$status" "0"
  append_as team-log "{$at,\"event\":\"merge-preapproval-withdrawn\",\"project\":\"proj\",\"discord_message\":\"1564\"}"
  assert_equal "$status" "0"
  append_as team-log "{$at,\"event\":\"review\",\"verdict\":\"pass\",\"head\":\"a1b2c3d\",\"findings\":{\"note\":1},\"guarded\":[]}"
  assert_equal "$status" "0"
  append_as team-merge "{$at,\"event\":\"merged\",\"pr\":5,\"merge\":\"b2c3d4e\",\"head\":\"a1b2c3d\",\"by\":\"m\",\"approval\":\"plan\"}"
  assert_equal "$status" "0"
  assert_equal "$(after_opened | jq -r .event)" "merge-preapproved
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
  assert_contains "$output" "approval must be one of head, default, plan, standing"
  assert_equal "$(after_opened | wc -l)" "4"
}

@test "a plan approval meets the contract: by Daniel, with their ask and message, or the coordinator, with neither; a withdrawal names a message" {
  opened_task T7
  local at='"ts":"2026-11-11T02:00:00Z","task":"T7"'
  local plan='"plan":{"tasks/T7/plan.md":"ab12"},"scope":["src/"]'
  append_as team-log "{$at,\"event\":\"plan-approved\",\"by\":\"Daniel\",\"ask\":\"plan\",\"discord_message\":\"1563\",$plan}"
  assert_equal "$status" "0"
  append_as team-log "{$at,\"event\":\"plan-approved\",\"by\":\"coordinator\",$plan}"
  assert_equal "$status" "0"
  append_as team-log "{$at,\"event\":\"plan-approval-withdrawn\",\"discord_message\":\"1564\"}"
  assert_equal "$status" "0"
  assert_equal "$(after_opened | jq -r .event)" "plan-approved
plan-approved
plan-approval-withdrawn"

  append_as team-log "{$at,\"event\":\"plan-approved\",\"by\":\"daniel\"}"
  assert_contains "$output" "by must be one of Daniel, coordinator"
  append_as team-log "{$at,\"event\":\"plan-approved\",\"by\":\"coordinator\",\"ask\":\"plan\",\"discord_message\":\"1563\"}"
  assert_contains "$output" "ask"
  assert_contains "$output" "discord_message"
  append_as team-log "{$at,\"event\":\"plan-approved\",\"by\":\"coordinator\",\"plan\":[\"tasks/T7/plan.md\"],\"scope\":\"src/\"}"
  assert_contains "$output" "plan must be an object, got a list; scope must be a list, got a string"
  append_as team-log "{$at,\"event\":\"plan-approval-withdrawn\"}"
  assert_contains "$output" "plan-approval-withdrawn needs discord_message"
  append_as team-merge "{$at,\"event\":\"plan-approval-withdrawn\",\"discord_message\":\"1564\"}"
  assert_contains "$output" "plan-approval-withdrawn events are written by team-log, not team-merge"
  assert_equal "$(after_opened | wc -l)" "3"
}

# plan_approval and the phase over the events read from stdin, one JSON object per line, each of
# T1, from an opened feature task, a minute apart: approval_of
approval_of() {
  jq -L "$REPO_ROOT/bin/lib" -sc 'include "ledger";
    [{event: "opened", path: "feature", project: "proj", worktree: "/w/1"}] + . | to_entries
    | map(.key as $n | {ts: ("2026-11-01T00:00:00Z" | fromdate + $n * 60 | todate), task: "T1"} + .value)
    | [plan_approval, phase]'
}

@test "plan_approval reads the latest approval or withdrawal, an approval with no plan as the coordinator's and legacy, and the phase builds only while it is approved" {
  local daniel='{"event": "plan-approved", "by": "Daniel", "ask": "plan", "discord_message": "1563", "plan": {"tasks/T1/plan.md": "ab12"}, "scope": ["src/"]}'
  local coordinator='{"event": "plan-approved", "by": "coordinator", "plan": {"tasks/T1/plan.md": "cd34"}}'
  local legacy='{"event": "plan-approved", "by": "Daniel", "discord_message": "1565"}'
  local withdrawn='{"event": "plan-approval-withdrawn", "discord_message": "1564"}'
  local launch='{"event": "launch", "role": "builder", "session": "b1"}'
  assert_equal "$(approval_of </dev/null)" '[null,"planning"]'
  assert_equal "$(approval_of <<<"$daniel")" \
    '[{"state":"approved","by":"Daniel","ask":"plan","discord_message":"1563","plan":{"tasks/T1/plan.md":"ab12"},"scope":["src/"],"parallel":null,"ts":"2026-11-01T00:01:00Z","legacy":false},"building"]'
  assert_equal "$(approval_of <<<"$coordinator")" \
    '[{"state":"approved","by":"coordinator","ask":null,"discord_message":null,"plan":{"tasks/T1/plan.md":"cd34"},"scope":null,"parallel":null,"ts":"2026-11-01T00:01:00Z","legacy":false},"building"]'
  # A line from before T276 has no plan: never Daniel's read-back word, whatever its by.
  assert_equal "$(approval_of <<<"$legacy")" \
    '[{"state":"approved","by":"coordinator","ask":null,"discord_message":"1565","plan":null,"scope":null,"parallel":null,"ts":"2026-11-01T00:01:00Z","legacy":true},"building"]'
  # A withdrawal takes the building task back to planning, where no builder launch or ticket-done
  # moves it, until the plan is approved again.
  assert_equal "$(printf '%s\n' "$daniel" "$withdrawn" | approval_of)" \
    '[{"state":"withdrawn","by":null,"ask":null,"discord_message":"1564","plan":null,"scope":null,"parallel":null,"ts":"2026-11-01T00:02:00Z","legacy":false},"planning"]'
  assert_equal "$(printf '%s\n' "$daniel" "$withdrawn" "$launch" '{"event": "ticket-done", "ticket": "01", "commits": ["a1b2c3d"]}' | approval_of | jq -c '[.[0].state, .[1]]')" \
    '["withdrawn","planning"]'
  assert_equal "$(printf '%s\n' "$daniel" "$withdrawn" "$coordinator" | approval_of | jq -c '[.[0].state, .[0].by, .[1]]')" \
    '["approved","coordinator","building"]'
  # The phases' caps are the approval's, and a withdrawal names none.
  assert_equal "$(jq -c '. + {parallel: "2,1"}' <<<"$coordinator" | approval_of | jq -c '.[0].parallel')" '"2,1"'
  # A withdrawal once the PR is up leaves the review phase as it is.
  assert_equal "$(printf '%s\n' "$daniel" "$launch" '{"event": "pr", "url": "https://github.com/o/p/pull/5", "head": "a1b2c3d"}' "$withdrawn" \
    | approval_of | jq -c '[.[0].state, .[1]]')" '["withdrawn","in-review"]'
}

# merge_authority over the events read from stdin, as approval_of reads them, for PR 5 of proj at
# the head a1b2c3d4e5, held to the bar <own> (merge_authority's $own: false, or the team's own
# project as {"app": <the reviewer App's id or null>}), with the ledger's
# merge-default-withdrawn and merge-default-restored events <withdrawals> (a JSON array, default
# none), a string printed raw: authority_of [<own>] [<filter>] [<withdrawals>]
authority_of() {
  jq -L "$REPO_ROOT/bin/lib" -src --argjson own "${1:-false}" --argjson withdrawals "${3:-[]}" 'include "ledger";
    [{event: "opened", path: "feature", project: "proj", branch: "feat/T1-x", worktree: "/w/1"},
     {event: "pr", url: "https://github.com/o/p/pull/5", head: "a1b2c3d4"}] + . | to_entries
    | map(.key as $n | {ts: ("2026-11-01T00:00:00Z" | fromdate + $n * 60 | todate), task: "T1"} + .value)
    | merge_authority("https://github.com/o/p/pull/5"; "a1b2c3d4e5"; "proj"; $own; $withdrawals)
    | '"${2:-.}"
}

# checks_wait over the events given, one JSON object each, of T1, after an opened feature task, a
# minute apart from 2026-11-01T00:01:00Z: waits_of <event>...
waits_of() {
  printf '%s\n' "$@" | jq -L "$REPO_ROOT/bin/lib" -sc 'include "ledger";
    [{event: "opened", path: "feature", project: "proj", branch: "feat/T1-x", worktree: "/w/1"}] + . | to_entries
    | map(.key as $n | {ts: ("2026-11-01T00:00:00Z" | fromdate + $n * 60 | todate), task: "T1"} + .value)
    | checks_wait'
}

# A ci event of PR 5 at <head> with <outcome>, or a ci-rerun of PR 5's check <name> at <head>:
# ci_of <outcome> <head>; rerun_of <name> <head>
ci_of() {
  jq -cn --arg outcome "$1" --arg head "$2" '{event: "ci", url: "https://github.com/o/p/pull/5", head: $head, outcome: $outcome}'
}
rerun_of() {
  jq -cn --arg check "$1" --arg head "$2" '{event: "ci-rerun", url: "https://github.com/o/p/pull/5", head: $head, check: $check, run: "42", job: "43"}'
}

@test "checks_wait names the head a pass waits on the checks of, its latest wait's end, since when (the latest end or rerun), and the checks rerun on it" {
  local url=https://github.com/o/p/pull/5
  local pr='{"event": "pr", "url": "https://github.com/o/p/pull/5", "head": "a1b2c3d4"}'
  local pass='{"event": "review", "verdict": "pass", "head": "a1b2c3d4"}'
  local findings='{"event": "review", "verdict": "findings", "head": "a1b2c3d4"}'
  local up='{"event": "caught-up", "url": "https://github.com/o/p/pull/5", "from": "a1b2c3d4", "head": "b2c3d4e5", "base": "0f0f0f0f"}'
  local up2='{"event": "caught-up", "url": "https://github.com/o/p/pull/5/", "from": "b2c3d4e5", "head": "c3d4e5f6", "base": "0e0e0e0e"}'
  local merged='{"event": "merged", "pr": 5, "url": "https://github.com/o/p/pull/5", "merge": "m1", "head": "a1b2c3d4", "by": "Daniel"}'
  # waiting_on <head> <since> <state> [<reruns>]: the value expected of a wait on PR 5, reviewed at a1b2c3d4.
  waiting_on() {
    jq -cn --arg url "$url" --arg head "$1" --arg since "2026-11-01T00:0$2:00Z" --arg state "$3" --argjson reruns "${4:-[]}" \
      '{url: $url, reviewed: "a1b2c3d4", head: $head, since: $since, state: $state, reruns: $reruns}'
  }
  # No review, a findings review last, a pass with no PR, and a pass whose PR merged: no wait.
  assert_equal "$(waits_of)" "null"
  assert_equal "$(waits_of "$pr")" "null"
  assert_equal "$(waits_of "$pr" "$findings")" "null"
  assert_equal "$(waits_of "$pr" "$pass" "$findings")" "null"
  assert_equal "$(waits_of "$pass")" "null"
  assert_equal "$(waits_of "$pr" "$pass" "$merged")" "null"
  # A pass waits on its own head, since the pass, until a wait ends.
  assert_equal "$(waits_of "$pr" "$pass")" "$(waiting_on a1b2c3d4 2 waiting)"
  # A catch-up made from the passed head, and one made from that, moves the wait to the merge.
  assert_equal "$(waits_of "$pr" "$pass" "$up")" "$(waiting_on b2c3d4e5 3 waiting)"
  assert_equal "$(waits_of "$pr" "$pass" "$up" "$up2")" "$(waiting_on c3d4e5f6 4 waiting)"
  # A catch-up from another head, or one logged before the pass, does not.
  assert_equal "$(waits_of "$pr" "$pass" "$up2")" "$(waiting_on a1b2c3d4 2 waiting)"
  assert_equal "$(waits_of "$pr" "$up" "$pass")" "$(waiting_on a1b2c3d4 3 waiting)"
  # Each outcome of a wait on the head, a full sha matching it by prefix, sets the state and since.
  local outcome
  for outcome in passed failed infrastructure pending; do
    assert_equal "$(waits_of "$pr" "$pass" "$(ci_of "$outcome" a1b2c3d4e5f60718)")" "$(waiting_on a1b2c3d4 3 "$outcome")"
  done
  # The latest wait's end counts; one of another head, of another PR, or logged before the pass
  # does not.
  assert_equal "$(waits_of "$pr" "$pass" "$(ci_of pending a1b2c3d4)" "$(ci_of passed a1b2c3d4)")" "$(waiting_on a1b2c3d4 4 passed)"
  assert_equal "$(waits_of "$pr" "$pass" "$(ci_of passed ffff0000)")" "$(waiting_on a1b2c3d4 2 waiting)"
  assert_equal "$(waits_of "$pr" "$pass" "$(ci_of passed a1b2c3d4 | jq -c '.url = "https://github.com/o/p/pull/6"')")" "$(waiting_on a1b2c3d4 2 waiting)"
  assert_equal "$(waits_of "$pr" "$(ci_of failed a1b2c3d4)" "$pass")" "$(waiting_on a1b2c3d4 3 waiting)"
  # After a catch-up, a wait on the passed head is an old one, and a wait on the merge counts.
  assert_equal "$(waits_of "$pr" "$pass" "$(ci_of passed a1b2c3d4)" "$up")" "$(waiting_on b2c3d4e5 4 waiting)"
  assert_equal "$(waits_of "$pr" "$pass" "$up" "$(ci_of passed a1b2c3d4)")" "$(waiting_on b2c3d4e5 3 waiting)"
  assert_equal "$(waits_of "$pr" "$pass" "$up" "$(ci_of failed b2c3d4e5)")" "$(waiting_on b2c3d4e5 4 failed)"
  # The checks rerun on the head, each named once in the order first rerun, since the latest of
  # them, whose wait starts again; a rerun of another head is not.
  assert_equal "$(waits_of "$pr" "$pass" "$(rerun_of 'macos-shards (1)' a1b2c3d4)" "$(rerun_of 'test-shards (2)' a1b2c3d4)" \
    "$(rerun_of 'macos-shards (1)' a1b2c3d4)" "$(rerun_of 'test-shards (3)' ffff0000)")" \
    "$(waiting_on a1b2c3d4 5 waiting '["macos-shards (1)","test-shards (2)"]')"
  assert_equal "$(waits_of "$pr" "$pass" "$(rerun_of 'macos-shards (1)' a1b2c3d4)" "$up")" "$(waiting_on b2c3d4e5 4 waiting)"
  # A rerun after a wait's end dates the wait from the rerun, its state still that end's; a wait's
  # end after a rerun dates it from the end.
  assert_equal "$(waits_of "$pr" "$pass" "$(ci_of pending a1b2c3d4)" "$(rerun_of 'macos-shards (1)' a1b2c3d4)")" \
    "$(waiting_on a1b2c3d4 4 pending '["macos-shards (1)"]')"
  assert_equal "$(waits_of "$pr" "$pass" "$(rerun_of 'macos-shards (1)' a1b2c3d4)" "$(ci_of pending a1b2c3d4)")" \
    "$(waiting_on a1b2c3d4 4 pending '["macos-shards (1)"]')"
  # A rerun logged before the catch-up the wait is on does not date it.
  assert_equal "$(waits_of "$pr" "$pass" "$(rerun_of 'macos-shards (1)' b2c3d4e5)" "$up")" "$(waiting_on b2c3d4e5 4 waiting '["macos-shards (1)"]')"
}

@test "checks_wait of a task with two PRs is on the PR the pass names by its head, else its latest PR delivered before the pass" {
  local p='{"event": "pr", "url": "https://github.com/o/p/pull/5", "head": "a1b2c3d4"}'
  local q='{"event": "pr", "url": "https://github.com/o/q/pull/7", "head": "d4e5f6a7"}'
  local later='{"event": "pr", "url": "https://github.com/o/r/pull/9", "head": "e5f6a7b8"}'
  local on='{url, reviewed, head}'
  assert_equal "$(waits_of "$p" "$q" '{"event": "review", "verdict": "pass", "head": "a1b2c3d4"}' | jq -c "$on")" \
    '{"url":"https://github.com/o/p/pull/5","reviewed":"a1b2c3d4","head":"a1b2c3d4"}'
  # A fix's head, which no pr event logs, is on the latest PR delivered before the pass.
  assert_equal "$(waits_of "$p" "$q" '{"event": "review", "verdict": "pass", "head": "9f9f9f9f"}' "$later" | jq -c "$on")" \
    '{"url":"https://github.com/o/q/pull/7","reviewed":"9f9f9f9f","head":"9f9f9f9f"}'
  # A pass on a PR that merged waits on nothing, though another PR is open.
  assert_equal "$(waits_of "$p" "$q" '{"event": "review", "verdict": "pass", "head": "d4e5f6a7"}' \
    '{"event": "merged", "pr": 7, "url": "https://github.com/o/q/pull/7", "merge": "m1", "head": "d4e5f6a7", "by": "Daniel"}')" "null"
}

@test "merge_authority gives the per-head word and then the default word, each with its ledger reasons and facts, and the first that holds" {
  local pass='{"event": "review", "verdict": "pass", "head": "a1b2c3d4", "findings": {"security": 0, "real-data": 0}, "guarded": []}'
  local coordinator='{"event": "plan-approved", "by": "coordinator", "plan": {"tasks/T1/plan.md": "cd34"}, "scope": ["src/"]}'
  local asked='{"event": "asked", "id": "plan"}'
  local daniel='{"event": "plan-approved", "by": "Daniel", "ask": "plan", "discord_message": "1563", "plan": {"tasks/T1/plan.md": "ab12"}}'
  local approved='{"event": "merge-approved", "url": "https://github.com/o/p/pull/5/", "discord_message": "1566", "head": "a1b2c3d4"}'
  local words='[.words[] | [.word, .applies, .holds, .reasons]], .word'
  # Nothing recorded: neither word applies, each saying why.
  assert_equal "$(authority_of false "$words" </dev/null)" \
    '[["head",false,false,["no merge-approved event for https://github.com/o/p/pull/5: Daniel'"'"'s word is not recorded"]],["default",false,false,["T1 has no approved plan: no plan-approved is logged"]]]
null'
  # The coordinator's approval and a passing review: the default word holds, its facts what team-merge checks.
  assert_equal "$(printf '%s\n' "$coordinator" "$pass" | authority_of false '.word, .words[1].facts')" \
    'default
{"by":"coordinator","ts":"2026-11-01T00:02:00Z","legacy":false,"plan":{"tasks/T1/plan.md":"cd34"},"scope":["src/"],"branch":"feat/T1-x","restored":null,"withdrawn":null}'
  # Daniel's approval names the ask it answers, as logged before it.
  assert_equal "$(printf '%s\n' "$asked" "$daniel" "$pass" | authority_of false '.words[1].facts | [.by, .ask, .discord_message, .asked.ts]')" \
    '["Daniel","plan","1563","2026-11-01T00:02:00Z"]'
  # A per-head word on the URL, a trailing slash aside, is tried first and holds on the ledger with
  # the event its message is timed against; the default word still says its own.
  assert_equal "$(printf '%s\n' "$coordinator" "$approved" | authority_of false '.word, (.words[] | [.word, .holds]), .words[0].facts.logged')" \
    'head
["head",true]
["default",false]
{"ts":"2026-11-01T00:01:00Z","event":"pr"}'
  # A per-head word naming a head nothing logged does not hold, and the default word is next.
  assert_equal "$(printf '%s\n' "$coordinator" "$pass" "${approved/a1b2c3d4/0fedcba9}" | authority_of false '.word, .words[0].reasons[]')" \
    "default
merge-approved names the head 0fedcba, which no pr event of https://github.com/o/p/pull/5, nor a review since, logged: ask again on the PR's head"
  # A withdrawn approval, and the reviews and branch while one stands.
  assert_equal "$(printf '%s\n' "$coordinator" '{"event": "plan-approval-withdrawn", "discord_message": "1564"}' | authority_of false '.words[1] | [.applies, .reasons, .facts]')" \
    '[false,["T1'"'"'s plan approval was withdrawn at 2026-11-01T00:03:00Z in Discord message 1564: approve the plan again"],null]'
  assert_equal "$(printf '%s\n' "$coordinator" | authority_of false '.words[1].reasons[]')" \
    "no review of the head a1b2c3d is logged, so no reviewer has passed it"
  # The team's own project: the one reason, whoever approved.
  assert_equal "$(printf '%s\n' "$asked" "$daniel" "$pass" | authority_of '{"app": null}' '.word, .words[1].reasons')" \
    'null
["the team'"'"'s own project merges unattended only behind the reviewer App'"'"'s check, which is not set up"]'
  # With the reviewer App on: Daniel's approval holds, the coordinator's and a legacy one do not,
  # and the other reasons are given as for any project.
  assert_equal "$(printf '%s\n' "$asked" "$daniel" "$pass" | authority_of '{"app": 123456}' '.word, .words[1].reasons')" \
    'default
[]'
  assert_equal "$(printf '%s\n' "$coordinator" | authority_of '{"app": 123456}' '.words[1].reasons[]')" \
    "the team's own project merges unattended only on a plan Daniel approved, and the coordinator approved T1's at 2026-11-01T00:02:00Z: ask Daniel to approve it
no review of the head a1b2c3d is logged, so no reviewer has passed it"
  assert_equal "$(printf '%s\n' '{"event": "plan-approved", "by": "Daniel"}' "$pass" | authority_of '{"app": 123456}' '.words[1].reasons[]')" \
    "the team's own project merges unattended only on a plan Daniel approved, and T1's approval at 2026-11-01T00:02:00Z is a legacy one, logged with no plan: ask Daniel to approve it"
}

@test "merge_authority's default word is withdrawn when the latest withdrawal or giving back covering the PR is a withdrawal" {
  local pass='{"event": "review", "verdict": "pass", "head": "a1b2c3d4", "findings": {"security": 0, "real-data": 0}, "guarded": []}'
  local coordinator='{"event": "plan-approved", "by": "coordinator", "plan": {"tasks/T1/plan.md": "cd34"}, "scope": ["src/"]}'
  # <kind> <task> <scope> <minute>: one of the ledger's merge-default events, logged at that minute.
  said() {
    jq -cn --arg e "merge-default-$1" --arg t "$2" --arg s "$3" --argjson n "$4" \
      '{ts: ("2026-11-01T00:00:00Z" | fromdate + $n * 60 | todate), task: $t, event: $e, scope: $s,
        discord_message: "15\($n)", discord_channel: "1562"}'
  }
  local filter='.word, .words[1].reasons, .words[1].facts.restored'
  covered() {
    local withdrawals
    withdrawals=$(jq -sc .)
    printf '%s\n' "$coordinator" "$pass" | authority_of false "$filter" "$withdrawals"
  }
  # Each scope that covers T1's PR of proj withdraws it, naming the scope, the time and the message.
  assert_equal "$(said withdrawn T1 task 9 | covered)" 'null
["the default word was withdrawn for T1 at 2026-11-01T00:09:00Z in Discord message 159, and not given back since"]
null'
  assert_equal "$(said withdrawn T5 proj 9 | covered | sed -n 2p)" \
    '["the default word was withdrawn for project proj at 2026-11-01T00:09:00Z in Discord message 159, and not given back since"]'
  assert_equal "$(said withdrawn T5 all 9 | covered | sed -n 2p)" \
    '["the default word was withdrawn for every project at 2026-11-01T00:09:00Z in Discord message 159, and not given back since"]'
  # Another task's or another project's withdrawal does not touch it.
  assert_equal "$({ said withdrawn T5 task 9; said withdrawn T1 conv 10; } | covered)" 'default
[]
null'
  # A giving back of all after the project's withdrawal gives it back (T278 C3), its event in the
  # facts for team-merge to read back; a later withdrawal withdraws it again.
  assert_equal "$({ said withdrawn T5 proj 9; said restored T6 all 10; } | covered)" 'default
[]
{"ts":"2026-11-01T00:10:00Z","task":"T6","event":"merge-default-restored","scope":"all","discord_message":"1510","discord_channel":"1562"}'
  assert_equal "$({ said withdrawn T5 all 9; said restored T1 task 10; said withdrawn T5 proj 11; } | covered | sed -n 1p)" null
  # A giving back of another project after a withdrawal of all leaves the PR withdrawn.
  assert_equal "$({ said withdrawn T5 all 9; said restored T5 conv 10; } | covered | sed -n 2p)" \
    '["the default word was withdrawn for every project at 2026-11-01T00:09:00Z in Discord message 159, and not given back since"]'
  # The team's own project gives its one reason alone, withdrawn or not.
  assert_equal "$(printf '%s\n' "$coordinator" "$pass" | authority_of '{"app": null}' '.words[1].reasons' "$(said withdrawn T1 all 9 | jq -sc .)")" \
    '["the team'"'"'s own project merges unattended only behind the reviewer App'"'"'s check, which is not set up"]'
}

@test "default_restore_withdrawn says whether a giving back covers a PR whose latest covering event is a withdrawal" {
  # <events as JSON lines> | gives <task> <scope> [<projects of each task, a JSON object>]
  gives() {
    jq -L "$REPO_ROOT/bin/lib" -sc --arg t "$1" --arg s "$2" --argjson p "${3:-{\}}" 'include "ledger";
      default_restore_withdrawn({task: $t, scope: $s}; $p)'
  }
  local w='{"event": "merge-default-withdrawn"' r='{"event": "merge-default-restored"'
  assert_equal "$(gives T1 all </dev/null)" false
  assert_equal "$(echo "$w, \"task\": \"T1\", \"scope\": \"task\"}" | gives T1 task)" true
  assert_equal "$(echo "$w, \"task\": \"T1\", \"scope\": \"task\"}" | gives T2 task)" false
  # A task's withdrawal is given back by its project's, known from its opened events, or all.
  assert_equal "$(echo "$w, \"task\": \"T1\", \"scope\": \"task\"}" | gives T2 p '{"T1": ["p"]}')" true
  assert_equal "$(echo "$w, \"task\": \"T1\", \"scope\": \"task\"}" | gives T2 q '{"T1": ["p"]}')" false
  assert_equal "$(printf '%s\n' "$w, \"task\": \"T1\", \"scope\": \"task\"}" "$r, \"task\": \"T2\", \"scope\": \"p\"}" | gives T9 all '{"T1": ["p"]}')" false
  # A withdrawal of all is given back by any one project's or task's, and ended by all's.
  assert_equal "$(echo "$w, \"task\": \"T1\", \"scope\": \"all\"}" | gives T2 q)" true
  assert_equal "$(echo "$w, \"task\": \"T1\", \"scope\": \"all\"}" | gives T2 task)" true
  assert_equal "$(printf '%s\n' "$w, \"task\": \"T1\", \"scope\": \"all\"}" "$r, \"task\": \"T1\", \"scope\": \"all\"}" | gives T2 q)" false
}

@test "default_withdrawals gives each withdrawal still the latest covering some PR, in ledger order" {
  # <events as JSON lines> | standing [<projects of each task, a JSON object>]: the messages of the
  # withdrawals that stand.
  standing() {
    jq -L "$REPO_ROOT/bin/lib" -sc --argjson p "${1:-{\}}" 'include "ledger"; default_withdrawals($p) | map(.discord_message)'
  }
  # <kind> <task> <scope> <message>: a merge-default event.
  said() {
    jq -cn --arg e "merge-default-$1" --arg t "$2" --arg s "$3" --arg m "$4" '{task: $t, event: $e, scope: $s, discord_message: $m}'
  }
  assert_equal "$(standing </dev/null)" '[]'
  assert_equal "$({ said withdrawn T1 task 1; said withdrawn T2 proj 2; } | standing)" '["1","2"]'
  # A later withdrawal of all decides for every PR, so it stands alone.
  assert_equal "$({ said withdrawn T1 task 1; said withdrawn T2 proj 2; said withdrawn T3 all 3; } | standing)" '["3"]'
  # A giving back of all ends every withdrawal before it, and a later one stands again.
  assert_equal "$({ said withdrawn T1 task 1; said withdrawn T2 proj 2; said restored T3 all 3; said withdrawn T4 conv 4; } | standing)" '["4"]'
  # A project's giving back ends that project's withdrawal and its tasks', known from their opened
  # events, and leaves a withdrawal of all standing for the other projects.
  assert_equal "$({ said withdrawn T1 task 1; said withdrawn T2 all 2; said restored T3 proj 3; } | standing '{"T1": ["proj"]}')" '["2"]'
  assert_equal "$({ said withdrawn T1 task 1; said restored T3 proj 3; } | standing '{"T1": ["conv"]}')" '["1"]'
  # A task's giving back ends its own withdrawal only.
  assert_equal "$({ said withdrawn T1 task 1; said withdrawn T2 task 2; said restored T1 task 3; } | standing)" '["2"]'
}

@test "scope_reasons names each changed path outside the approved scope, a rename by both names, and none with no scope" {
  outside() {
    jq -L "$REPO_ROOT/bin/lib" -r --argjson scope "$1" 'include "ledger"; scope_reasons($scope)'
  }
  local changed='[{"path": "src/a.py"}, {"path": "README.md"}, {"path": "docs/x.md"}, {"path": "old.md", "renamed": "src/new.md"}]'
  assert_equal "$(outside '["src/", "README.md"]' <<<"$changed")" \
    "docs/x.md is outside the approved plan's scope: src/, README.md
old.md, renamed to src/new.md, is outside the approved plan's scope: src/, README.md"
  assert_equal "$(outside null <<<"$changed")" ""
}

@test "a standing merge word and its withdrawal meet the contract, each naming a project, a message and its channel" {
  opened_task T7
  local at='"ts":"2026-11-01T02:00:00Z","task":"T7"' said='"discord_message":"1566","discord_channel":"1562"'
  append_as team-log "{$at,\"event\":\"merge-standing\",\"project\":\"all\",$said}"
  assert_equal "$status" "0"
  append_as team-log "{$at,\"event\":\"merge-standing-withdrawn\",\"project\":\"proj\",$said}"
  assert_equal "$status" "0"
  assert_equal "$(after_opened | jq -r .event)" "merge-standing
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
  assert_equal "$(after_opened | wc -l)" "2"
}

@test "a kind with several writers is appended by each of them, and refused from any other" {
  opened_task T7
  append_as team-ask '{"ts":"2026-10-22T02:00:00Z","task":"T7","event":"asked","id":"q1","text":"Which?"}'
  assert_equal "$status" "0"
  append_as team-answer '{"ts":"2026-10-22T02:00:01Z","task":"T7","event":"answered","id":"q1","answer":"That one"}'
  assert_equal "$status" "0"
  append_as team-ask '{"ts":"2026-10-22T02:00:02Z","task":"T7","event":"answered","id":"q1","answer":"That one"}'
  assert_equal "$status" "1"
  assert_contains "$output" "answered events are written by team-log or team-answer, not team-ask"
  assert_equal "$(after_opened | jq -r .event)" "asked
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

# The library's handed_on_launches over a task's events, given one JSON event per line, each as
# [session, handed_on]: handed_on <role of the new launch, or "" for none>
handed_on() {
  jq -L "$REPO_ROOT/bin/lib" -sc --arg role "$1" \
    'include "ledger"; map({ts: "2026-10-24T12:00:00Z", task: "T1"} + .) | handed_on_launches($role; "/home/x") | map([.session, .handed_on])'
}

@test "a ticket builder ends only by its own done or its ticket's ticket-done, and a task worktree's builder as before" {
  local two='{"event": "launch", "role": "builder", "session": "b3", "worktree": "/w/1--03", "ticket": "03"}
{"event": "launch", "role": "builder", "session": "b4", "worktree": "/w/1--04", "ticket": "04"}'
  # Ticket 03's ticket-done leaves 04's builder unfinished, and builder is named once.
  assert_equal "$(unfinished_roles <<<"$two")" '["builder"]'
  assert_equal "$(unfinished_roles <<EVENTS
$two
{"event": "ticket-done", "ticket": "03", "commits": ["abc1234"]}
{"event": "done", "role": "builder", "session": "b3"}
EVENTS
)" '["builder"]'
  assert_equal "$(unfinished_roles <<EVENTS
$two
{"event": "ticket-done", "ticket": "03", "commits": ["abc1234"]}
{"event": "ticket-done", "ticket": "04", "commits": ["abc1235"]}
EVENTS
)" '[]'
  # A done of its own session ends a ticket builder; a pr or another builder's done does not.
  assert_equal "$(unfinished_roles <<EVENTS
$two
{"event": "done", "role": "builder", "session": "b4"}
{"event": "pr", "url": "https://github.com/o/r/pull/3", "head": "abc1234"}
EVENTS
)" '["builder"]'
  # A builder of the task worktree ends by any ticket-done, as before, a ticket builder's too.
  assert_equal "$(unfinished_roles <<'EVENTS'
{"event": "launch", "role": "builder", "session": "b0", "worktree": "/w/1"}
{"event": "launch", "role": "builder", "session": "b3", "worktree": "/w/1--03", "ticket": "03"}
{"event": "ticket-done", "ticket": "03", "commits": ["abc1234"]}
EVENTS
)" '[]'
}

@test "a ticket's ticket-done hands on only its own ticket's builder, with a new launch or none" {
  local two='{"event": "launch", "role": "builder", "session": "b3", "worktree": "/w/1--03", "ticket": "03"}
{"event": "launch", "role": "builder", "session": "b4", "worktree": "/w/1--04", "ticket": "04"}
{"event": "ticket-done", "ticket": "03", "commits": ["abc1234"]}'
  # With no new launch (the heartbeat's finished step), ticket 03's builder is a candidate once its
  # ticket-done follows it, with or without its done; 04's is none.
  assert_equal "$(handed_on '' <<<"$two")" '[["b3",true]]'
  assert_equal "$(handed_on '' <<EVENTS
$two
{"event": "done", "role": "builder", "session": "b3"}
EVENTS
)" '[["b3",true]]'
  # A new builder's launch sees both, and only 03's is handed on.
  assert_equal "$(handed_on builder <<<"$two")" '[["b3",true],["b4",false]]'
  # A pr hands on no ticket builder, but a task worktree's builder as before.
  assert_equal "$(handed_on builder <<'EVENTS'
{"event": "launch", "role": "builder", "session": "b0", "worktree": "/w/1"}
{"event": "launch", "role": "builder", "session": "b3", "worktree": "/w/1--03", "ticket": "03"}
{"event": "pr", "url": "https://github.com/o/r/pull/3", "head": "abc1234"}
EVENTS
)" '[["b0",true],["b3",false]]'
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

@test "ticket worktrees: each is keyed by project and ticket, so a move, rename or return touches only its own" {
  local events='{"event": "opened", "project": "proj", "branch": "feat/T1-x", "worktree": "/w/1", "path": "feature"}
{"event": "worktree-added", "project": "lib", "branch": "feat/T1-lib", "worktree": "/w/2"}
{"event": "worktree-added", "project": "proj", "branch": "feat/T1-x--02", "base": "feat/T1-x", "worktree": "/w/3", "ticket": "02"}
{"event": "worktree-added", "project": "proj", "branch": "feat/T1-x--03", "base": "feat/T1-x", "worktree": "/w/4", "ticket": "03"}'
  local lib=(jq -L "$REPO_ROOT/bin/lib" -sc)
  open() { "${lib[@]}" 'include "ledger"; map({task: "T1"} + .) | [open_worktrees(.[]; "/home/x") | [.project, .ticket, .branch, .worktree]]'; }
  listed() { "${lib[@]}" 'include "ledger"; [worktree_list[] | [.project, .ticket, .branch, .worktree, .returned]]'; }
  archived() { "${lib[@]}" 'include "ledger"; map({task: "T1"} + .) | [archived_worktrees("/home/x") | [.ticket, .archive]]'; }
  assert_equal "$(open <<<"$events")" \
    '[["proj",null,"feat/T1-x","/w/1"],["lib",null,"feat/T1-lib","/w/2"],["proj","02","feat/T1-x--02","/w/3"],["proj","03","feat/T1-x--03","/w/4"]]'
  assert_equal "$(archived <<<"$events")" '[[null,"scratch"],[null,"scratch-lib"],["02","scratch--02"],["03","scratch--03"]]'
  # The task's branch is never a ticket branch, though a ticket worktree-added is the latest.
  assert_equal "$("${lib[@]}" 'include "ledger"; [task_branch("proj"), task_branch("lib")]' <<<"$events")" '["feat/T1-x","feat/T1-lib"]'

  # A rename names no ticket: only the task's own worktree in proj takes it.
  events+=$'\n''{"event": "branch-renamed", "project": "proj", "branch": "feat/T1-x-fresh"}'
  # A move of ticket 03's worktree moves only it, and a move with no ticket only the task's.
  events+=$'\n''{"event": "worktree-moved", "project": "proj", "branch": "feat/T1-x--03", "from": "/w/4", "worktree": "/w/5", "ticket": "03"}'
  events+=$'\n''{"event": "worktree-moved", "project": "proj", "branch": "feat/T1-x-fresh", "from": "/w/1", "worktree": "/w/6"}'
  assert_equal "$(open <<<"$events")" \
    '[["proj",null,"feat/T1-x-fresh","/w/6"],["lib",null,"feat/T1-lib","/w/2"],["proj","02","feat/T1-x--02","/w/3"],["proj","03","feat/T1-x--03","/w/5"]]'
  assert_equal "$(listed <<<"$events")" \
    '[["proj",null,"feat/T1-x-fresh","/w/6",false],["lib",null,"feat/T1-lib","/w/2",false],["proj","02","feat/T1-x--02","/w/3",false],["proj","03","feat/T1-x--03","/w/5",false]]'
  assert_equal "$("${lib[@]}" 'include "ledger"; task_branch("proj")' <<<"$events")" '"feat/T1-x-fresh"'

  # A return of ticket 02's worktree returns only it; one that names its path with no ticket
  # returns nothing, since the task's own worktree in proj is elsewhere.
  events+=$'\n''{"event": "worktree-returned", "project": "proj", "worktree": "/w/3"}'
  assert_equal "$(open <<<"$events" | jq -c 'map(.[1])')" '[null,null,"02","03"]'
  events+=$'\n''{"event": "worktree-returned", "project": "proj", "worktree": "/w/3", "ticket": "02"}'
  assert_equal "$(open <<<"$events" | jq -c 'map(.[1])')" '[null,null,"03"]'
  assert_equal "$(listed <<<"$events" | jq -c 'map([.[1], .[4]])')" '[[null,false],[null,false],["02",true],["03",false]]'
  assert_equal "$(archived <<<"$events")" '[[null,"scratch"],[null,"scratch-lib"],["03","scratch--03"]]'
}

@test "a ticket on worktree-added, worktree-returned, worktree-moved, rehomed and rehome-failed meets the contract" {
  opened_task T7
  local at='"ts":"2026-10-31T02:00:00Z","task":"T7"'
  append_as team-open "{$at,\"event\":\"worktree-added\",\"project\":\"proj\",\"branch\":\"feat/T7-x--02\",\"base\":\"feat/T7-x\",\"base_sha\":\"abc1234\",\"worktree\":\"/w/2\",\"ticket\":\"02\"}"
  assert_equal "$status" "0"
  append_as team-close "{$at,\"event\":\"worktree-returned\",\"project\":\"proj\",\"worktree\":\"/w/2\",\"ticket\":\"02\"}"
  assert_equal "$status" "0"
  append_as team-open "{$at,\"event\":\"worktree-moved\",\"project\":\"proj\",\"branch\":\"feat/T7-x--02\",\"from\":\"/w/2\",\"worktree\":\"/w/3\",\"machine\":\"m\",\"ticket\":\"02\"}"
  assert_equal "$status" "0"
  append_as team-open "{$at,\"event\":\"rehomed\",\"project\":\"proj\",\"branch\":\"feat/T7-x--02\",\"worktree\":\"/w/3\",\"machine\":\"m\",\"ticket\":\"02\"}"
  assert_equal "$status" "0"
  append_as team-resume "{$at,\"event\":\"rehome-failed\",\"project\":\"proj\",\"branch\":\"feat/T7-x--02\",\"machine\":\"m\",\"reason\":\"r\",\"ticket\":\"02\"}"
  assert_equal "$status" "0"
  append_as team-open "{$at,\"event\":\"worktree-added\",\"project\":\"proj\",\"branch\":\"b\",\"base\":\"b\",\"base_sha\":\"abc1234\",\"worktree\":\"/w/4\",\"ticket\":2}"
  assert_equal "$status" "1"
  assert_contains "$output" "ticket must be a string"
  run_bin -0 team-log --check
}

@test "a branch-renamed meets the contract, written by team-log" {
  opened_task T7
  local at='"ts":"2026-10-31T02:00:00Z","task":"T7"'
  append_as team-log "{$at,\"event\":\"branch-renamed\",\"project\":\"proj\",\"branch\":\"feat/T7-x-fresh\"}"
  assert_equal "$status" "0"
  append_as team-log "{$at,\"event\":\"branch-renamed\",\"project\":\"proj\"}"
  assert_contains "$output" "branch-renamed needs branch"
  append_as team-open "{$at,\"event\":\"branch-renamed\",\"project\":\"proj\",\"branch\":\"feat/T7-x-fresh\"}"
  assert_contains "$output" "branch-renamed events are written by team-log, not team-open"
  assert_equal "$(after_opened | wc -l)" "1"
}

@test "a field its kind gives one writer is refused from the kind's other writers" {
  opened_task T7
  assert_equal "$(jq -c '.kinds.asked.field_writers' "$REPO_ROOT/bin/lib/ledger-contract.json")" '{"script":"team-ask","sha256":"team-ask"}'
  local hash at='"ts":"2026-10-22T02:00:00Z","task":"T7","event":"asked","id":"fix","text":"Run it?"'
  hash=$(printf '%064d' 0 | tr 0 a)
  append_as team-ask "{$at,\"script\":\"/w/7/fix.sh\",\"sha256\":\"$hash\"}"
  assert_equal "$status" "0"
  append_as team-log "{$at,\"script\":\"/w/7/fix.sh\",\"sha256\":\"$hash\"}"
  assert_equal "$status" "1"
  assert_contains "$output" "an asked's script is written by team-ask, not team-log; an asked's sha256 is written by team-ask, not team-log"
  append_as team-log "{$at}"
  assert_equal "$status" "0"
  assert_equal "$(after_opened | jq -c '[.id, .script != null]')" '["fix",true]
["fix",false]'
  # An answered's item, the waiting list's number, is team-answer's alone.
  assert_equal "$(jq -c '.kinds.answered.field_writers' "$REPO_ROOT/bin/lib/ledger-contract.json")" '{"item":"team-answer"}'
  at='"ts":"2026-10-22T02:00:01Z","task":"T7","event":"answered","id":"fix","answer":"3 yes"'
  append_as team-log "{$at,\"item\":3}"
  assert_equal "$status" "1"
  assert_contains "$output" "an answered's item is written by team-answer, not team-log"
  append_as team-answer "{$at,\"discord_message\":\"1564000000000000001\",\"item\":3}"
  assert_equal "$status" "0"
}

@test "ledger_push never fails its caller: a commit that fails with nothing on stderr is the one line with its fallback reason, and the script goes on" {
  git -C "$TEAM_HOME" init -q -b dev
  git -C "$TEAM_HOME" remote add origin "$BATS_TEST_TMPDIR/origin.git"
  opened_task T7
  local script=$BATS_TEST_TMPDIR/bin/team-log
  cat >"$script" <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail
source "$REPO_ROOT/bin/lib/team.sh" "\$@"
commit_records() { return 1; }
ledger_append '{"ts":"2026-10-22T02:00:00Z","task":"T7","event":"plan-approved","by":"Daniel"}'
ledger_push
echo "went on"
SCRIPT
  chmod +x "$script"
  guard_sandbox
  run --separate-stderr "$script"
  assert_equal "$status" "0"
  assert_equal "$output" "went on"
  assert_equal "$stderr" "team-log: the ledger is not on origin yet (commit_records failed with no reason); the next checkpoint pushes it"
}

# A ledger whose T1 is closed: its thread, its opened and its closed.
closed_t1() {
  printf '%s\n' \
    '{"ts":"2026-11-01T00:00:00Z","task":"T1","event":"thread","discord_thread":"1563"}' \
    '{"ts":"2026-11-01T00:01:00Z","task":"T1","event":"opened","project":"p","path":"feature","type":"feat","title":"x","branch":"feat/T1-x","base":"dev","base_sha":"0000000","worktree":"/w"}' \
    '{"ts":"2026-11-01T09:00:00Z","task":"T1","event":"closed","archive":[],"returned":[],"kept":[]}' \
    >"$TEAM_HOME/ledger.jsonl"
}

@test "a writer outside refusing_writers appends an event the lifecycle table refuses, saying nothing, in either mode" {
  closed_t1
  local stowed='{"ts":"2026-11-02T00:00:00Z","task":"T1","event":"stowed","machine":"home-pc","worktrees":[],"roles":[]}'
  local thread='{"ts":"2026-11-02T00:00:00Z","task":"T1","event":"thread","discord_thread":"1564"}'
  local from
  for from in null 2026-01-01T00:00:00Z; do
    with_lifecycle_from "$from"
    append_as team-stow "$stowed"
    assert_equal "$status" "0"
    assert_equal "$output" ""
    append_as team-thread "$thread"
    assert_equal "$status" "0"
    assert_equal "$output" ""
  done
  assert_equal "$(jq -r .event "$TEAM_HOME/ledger.jsonl" | tail -n +4 | paste -sd ' ')" "stowed thread stowed thread"
}

@test "a refusing writer's event the table refuses is warned and logged before lifecycle_from, and refused from it on" {
  closed_t1
  local held='{"ts":"2026-11-02T00:00:00Z","task":"T1","event":"held","reason":"after close"}'
  local problem="T1 is closed, and a closed task takes no held"
  with_lifecycle_from null
  append_as team-log "$held"
  assert_equal "$status" "0"
  assert_equal "$output" "team-log: lifecycle: $problem (logged anyway; bin/lib/lifecycle.json refuses it from its lifecycle_from, not set yet)"
  # A time after the event's ts warns, naming it.
  with_lifecycle_from 2026-11-02T00:00:01Z
  append_as team-log "$held"
  assert_equal "$status" "0"
  assert_equal "$output" "team-log: lifecycle: $problem (logged anyway; bin/lib/lifecycle.json refuses it from its lifecycle_from, 2026-11-02T00:00:01Z)"
  assert_equal "$(jq -r .event "$TEAM_HOME/ledger.jsonl" | tail -n +4 | paste -sd ' ')" "held held"
  # From the event's own ts on, it is refused, and nothing is appended.
  cp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/before.jsonl"
  with_lifecycle_from 2026-11-02T00:00:00Z
  append_as team-log "$held"
  assert_equal "$status" "1"
  assert_equal "$output" "team-log: refusing a ledger event: lifecycle: $problem"
  # Several problems are one refusal, joined; here the one rule of a task not opened.
  append_as team-answer '{"ts":"2026-11-02T00:00:00Z","task":"T99","event":"resumed"}'
  assert_equal "$status" "1"
  assert_equal "$output" "team-answer: refusing a ledger event: lifecycle: T99 is not opened (no opened event), and it takes only thread and opened before its opened, not resumed"
  cmp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/before.jsonl"
  # An event the table takes is appended with nothing said, refusing or not.
  append_as team-log '{"ts":"2026-11-02T00:00:00Z","task":"T1","event":"merge-standing","project":"p","discord_message":"1564000000000000001","discord_channel":"1562486564871995482"}'
  assert_equal "$status" "0"
  assert_equal "$output" ""
}

@test "the lifecycle check waits for the ledger's lock, which the seconds bound, and appends nothing without it" {
  closed_t1
  cp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/before.jsonl"
  local held
  exec {held}>>"$TEAM_HOME/ledger.jsonl.lock"
  flock -x "$held"
  with_lifecycle_from null
  append_as team-log '{"ts":"2026-11-02T00:00:00Z","task":"T1","event":"held","reason":"after close"}' 1
  exec {held}>&-
  assert_equal "$status" "1"
  # Refused for the lock, with no warning: the check runs only once the lock is taken.
  assert_equal "$output" "team-log: could not take the ledger's lock within 1s"
  cmp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/before.jsonl"
}
