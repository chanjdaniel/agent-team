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
  assert_contains "$output" "approval must be one of head, plan"
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
    '[{"state":"approved","by":"Daniel","ask":"plan","discord_message":"1563","plan":{"tasks/T1/plan.md":"ab12"},"scope":["src/"],"ts":"2026-11-01T00:01:00Z","legacy":false},"building"]'
  assert_equal "$(approval_of <<<"$coordinator")" \
    '[{"state":"approved","by":"coordinator","ask":null,"discord_message":null,"plan":{"tasks/T1/plan.md":"cd34"},"scope":null,"ts":"2026-11-01T00:01:00Z","legacy":false},"building"]'
  # A line from before T276 has no plan: never Daniel's read-back word, whatever its by.
  assert_equal "$(approval_of <<<"$legacy")" \
    '[{"state":"approved","by":"coordinator","ask":null,"discord_message":"1565","plan":null,"scope":null,"ts":"2026-11-01T00:01:00Z","legacy":true},"building"]'
  # A withdrawal takes the building task back to planning, where no builder launch or ticket-done
  # moves it, until the plan is approved again.
  assert_equal "$(printf '%s\n' "$daniel" "$withdrawn" | approval_of)" \
    '[{"state":"withdrawn","by":null,"ask":null,"discord_message":"1564","plan":null,"scope":null,"ts":"2026-11-01T00:02:00Z","legacy":false},"planning"]'
  assert_equal "$(printf '%s\n' "$daniel" "$withdrawn" "$launch" '{"event": "ticket-done", "ticket": "01", "commits": ["a1b2c3d"]}' | approval_of | jq -c '[.[0].state, .[1]]')" \
    '["withdrawn","planning"]'
  assert_equal "$(printf '%s\n' "$daniel" "$withdrawn" "$coordinator" | approval_of | jq -c '[.[0].state, .[0].by, .[1]]')" \
    '["approved","coordinator","building"]'
  # A withdrawal once the PR is up leaves the review phase as it is.
  assert_equal "$(printf '%s\n' "$daniel" "$launch" '{"event": "pr", "url": "https://github.com/o/p/pull/5", "head": "a1b2c3d"}' "$withdrawn" \
    | approval_of | jq -c '[.[0].state, .[1]]')" '["withdrawn","in-review"]'
}

# merge_authority over the events read from stdin, as approval_of reads them, for PR 5 of proj at
# the head a1b2c3d4e5, the project the team's own when <own> is true, a string printed raw:
# authority_of [<own>] [<filter>]
authority_of() {
  jq -L "$REPO_ROOT/bin/lib" -src --argjson own "${1:-false}" 'include "ledger";
    [{event: "opened", path: "feature", project: "proj", branch: "feat/T1-x", worktree: "/w/1"},
     {event: "pr", url: "https://github.com/o/p/pull/5", head: "a1b2c3d4"}] + . | to_entries
    | map(.key as $n | {ts: ("2026-11-01T00:00:00Z" | fromdate + $n * 60 | todate), task: "T1"} + .value)
    | merge_authority("https://github.com/o/p/pull/5"; "a1b2c3d4e5"; "proj"; $own; [])
    | '"${2:-.}"
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
{"by":"coordinator","ts":"2026-11-01T00:02:00Z","legacy":false,"plan":{"tasks/T1/plan.md":"cd34"},"scope":["src/"],"branch":"feat/T1-x"}'
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
  assert_equal "$(printf '%s\n' "$asked" "$daniel" "$pass" | authority_of true '.word, .words[1].reasons')" \
    'null
["the team'"'"'s own project merges unattended only behind the reviewer App'"'"'s check, which is not set up"]'
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
