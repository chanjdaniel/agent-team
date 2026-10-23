#!/usr/bin/env bats
# hooks/ops-write-prompt: the ops session's PreToolUse hook for prod-write tools answers "ask" with
# a one-line summary of the write, which Claude Code shows Daniel in the permission prompt; an
# empty filter reads as every document, in capitals. It never approves anything.

load helpers/common

setup() {
  sandbox
}

# prompt_for <tool name> <tool input JSON>: run the hook on a PreToolUse event for that call, as
# Claude Code sends it, and set $reason to the reason it gives.
prompt_for() {
  local input
  input=$(jq -cn --arg tool "$1" --argjson input "$2" '{
    session_id: "0b5c1f7e-3d7a-4f7e-9c51-2a7d1e0c9b44", cwd: "/home/u/wt", permission_mode: "auto",
    hook_event_name: "PreToolUse", tool_name: $tool, tool_input: $input, tool_use_id: "toolu_01ABC123"}')
  run_bin -0 --separate-stderr hooks/ops-write-prompt <<<"$input"
  assert_equal "$(jq -c '.hookSpecificOutput | [.hookEventName, .permissionDecision]' <<<"$output")" '["PreToolUse","ask"]'
  reason=$(jq -r .hookSpecificOutput.permissionDecisionReason <<<"$output")
}

on='"connectionId": "preconfigured", "database": "conventioner", "collection": "ops_checks"'

@test "a delete-many with an empty or missing filter reads as deleting every document" {
  prompt_for mcp__prod-write__delete-many "{$on, \"filter\": {}}"
  assert_equal "$reason" "PRODUCTION WRITE: DELETE EVERY DOCUMENT in conventioner.ops_checks (the filter is empty: {})"
  prompt_for mcp__prod-write__delete-many "{$on}"
  assert_equal "$reason" "PRODUCTION WRITE: DELETE EVERY DOCUMENT in conventioner.ops_checks (the filter is empty: {})"
  prompt_for mcp__plugin_prod-write_prod-write__delete-many "{$on, \"filter\": null}"
  assert_equal "$reason" "PRODUCTION WRITE: DELETE EVERY DOCUMENT in conventioner.ops_checks (the filter is empty: {})"
}

@test "a delete-many with a filter names it" {
  prompt_for mcp__prod-write__delete-many "{$on, \"filter\": {\"_id\": {\"\$oid\": \"6718f0c2a1b2c3d4e5f60718\"}}}"
  assert_equal "$reason" 'PRODUCTION WRITE: delete the documents matching {"_id":{"$oid":"6718f0c2a1b2c3d4e5f60718"}} in conventioner.ops_checks'
}

@test "an update-many names its filter and change, every document in capitals, and an upsert" {
  prompt_for mcp__prod-write__update-many "{$on, \"filter\": {}, \"update\": {\"\$set\": {\"drill\": \"declined\"}}}"
  assert_equal "$reason" 'PRODUCTION WRITE: UPDATE EVERY DOCUMENT in conventioner.ops_checks (the filter is empty: {}) with {"$set":{"drill":"declined"}}'
  prompt_for mcp__prod-write__update-many "{$on, \"filter\": {\"check\": \"e2e\"}, \"update\": {\"\$set\": {\"a\": 1}}, \"upsert\": true}"
  assert_equal "$reason" 'PRODUCTION WRITE: update the documents matching {"check":"e2e"} in conventioner.ops_checks with {"$set":{"a":1}}, inserting one if none matches'
}

@test "an insert-many counts its documents, and the index tools name the index" {
  prompt_for mcp__prod-write__insert-many "{$on, \"documents\": [{\"check\": \"e2e\"}]}"
  assert_equal "$reason" "PRODUCTION WRITE: insert 1 document into conventioner.ops_checks"
  prompt_for mcp__prod-write__insert-many "{$on, \"documents\": [{}, {}, {}]}"
  assert_equal "$reason" "PRODUCTION WRITE: insert 3 documents into conventioner.ops_checks"
  prompt_for mcp__prod-write__create-index "{$on, \"name\": \"check_1\", \"definition\": [{\"type\": \"classic\", \"keys\": {\"check\": 1}}]}"
  assert_equal "$reason" 'PRODUCTION WRITE: create the index check_1 on conventioner.ops_checks, keys {"check":1}'
  prompt_for mcp__prod-write__drop-index "{$on, \"indexName\": \"check_1\", \"type\": \"classic\"}"
  assert_equal "$reason" "PRODUCTION WRITE: drop the index check_1 from conventioner.ops_checks"
}

@test "a long filter is cut, and a tool or input it cannot read still asks" {
  local long
  long=$(printf 'x%.0s' {1..400})
  prompt_for mcp__prod-write__delete-many "{$on, \"filter\": {\"note\": \"$long\"}}"
  assert_contains "$reason" '... in conventioner.ops_checks'
  [[ ${#reason} -lt 400 ]]
  prompt_for mcp__prod-write__rename-collection "{$on}"
  assert_equal "$reason" "PRODUCTION WRITE: rename-collection on conventioner.ops_checks; read its input before you approve"

  run_bin -0 --separate-stderr hooks/ops-write-prompt <<<'not json'
  assert_equal "$(jq -c '.hookSpecificOutput | [.permissionDecision, .permissionDecisionReason]' <<<"$output")" \
    '["ask","PRODUCTION WRITE: read its input before you approve"]'
}

@test "a call that is not a prod-write one gets no answer, so the normal rules apply" {
  run_bin -0 --separate-stderr hooks/ops-write-prompt <<<"$(jq -cn '{hook_event_name: "PreToolUse",
    tool_name: "mcp__prod-read__find", tool_input: {}}')"
  assert_equal "$output" ""
}

@test "the real settings/ops.json runs it before every prod-write tool, in both name forms" {
  local entry
  entry=$(jq -c '[.hooks.PreToolUse[] | select(.hooks[].command | endswith("/bin/hooks/ops-write-prompt"))]' \
    "$REPO_ROOT/settings/ops.json")
  assert_equal "$(jq length <<<"$entry")" 1
  local matcher tool
  matcher=$(jq -r '.[0].matcher' <<<"$entry")
  for tool in mcp__prod-write__delete-many mcp__plugin_prod-write_prod-write__delete-many; do
    grep -Eq -- "$matcher" <<<"$tool" || { echo "$matcher misses $tool" >&2; return 1; }
  done
  run -1 grep -Eq -- "$matcher" <<<mcp__prod-read__find
}
