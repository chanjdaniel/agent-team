#!/usr/bin/env bats
# hooks/ops-log: the ops session's PreToolUse, PostToolUse and PostToolUseFailure hook appends
# every production tool call to the task's ops log, masked and without results, and blocks a
# write it cannot log.

load helpers/common

setup() {
  sandbox
  taskdir=$TEAM_HOME/tasks/T7
  log=$taskdir/ops-log.md
  mkdir -p "$taskdir"
  wt=$HOME/wt
  mkdir -p "$wt"
  export CLAUDE_PROJECT_DIR=$wt
}

# hook_input <event> <tool name> <tool input JSON> [<extra fields JSON>]: the JSON Claude Code
# sends the hook for an MCP tool call, as the hooks docs record it.
hook_input() {
  jq -cn --arg event "$1" --arg tool "$2" --argjson input "$3" --argjson extra "${4:-{\}}" --arg cwd "$wt" '{
    session_id: "0b5c1f7e-3d7a-4f7e-9c51-2a7d1e0c9b44",
    transcript_path: "/home/u/.claude/projects/-home-u-wt/0b5c1f7e-3d7a-4f7e-9c51-2a7d1e0c9b44.jsonl",
    cwd: $cwd, permission_mode: "auto", hook_event_name: $event,
    tool_name: $tool, tool_input: $input, tool_use_id: "toolu_01ABC123",
    mcp_server: {name: ($tool | split("__")[1]), source: "dynamic"}} + $extra'
}

# hook <expected status> <hook input>: run the hook on that input, as Claude Code does.
hook() {
  run_bin "$1" --separate-stderr hooks/ops-log "$taskdir" <<<"$2"
}

TIME='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'

# The log's lines after its header, with each line's time replaced by TIME.
entries() {
  tail -n +3 "$log" | sed -E "s/^- $TIME /- TIME /"
}

READ_INPUT='{"database":"conventioner","collection":"markets","filter":{"phase":"open"},"projection":{"_id":1,"phase":1},"limit":20}'

@test "a read is logged as requested, then ran, without its result" {
  hook -0 "$(hook_input PreToolUse mcp__prod-read__find "$READ_INPUT")"
  assert_equal "$output$stderr" ""
  hook -0 "$(hook_input PostToolUse mcp__prod-read__find "$READ_INPUT" \
    '{"tool_response": [{"type": "text", "text": "{\"_id\": \"65a1\", \"phase\": \"open\", \"owner\": \"Secret Owner\"}"}], "duration_ms": 41}')"
  assert_equal "$output$stderr" ""
  assert_equal "$(head -n 1 "$log")" '# Ops log of T7'
  assert_equal "$(sed -n 2p "$log")" ''
  assert_equal "$(entries)" "- TIME requested \`prod-read\` \`find\` \`$READ_INPUT\`
- TIME ran \`prod-read\` \`find\` \`$READ_INPUT\`"
  grep -Eq "^- $TIME requested " "$log"
  run -1 grep -q -e 65a1 -e 'Secret Owner' -e tool_response "$log"
}

@test "a write that ran is logged, with every email address in its input masked at any depth" {
  local input='{"database":"conventioner","collection":"users","filter":{"email":"Ann.Lee+x@Example.co.uk","$or":[{"contact":{"emails":["bo@ex.io","not an address"]}},{"note":"mail cy_d@sub.ex.org now"}]},"update":{"$set":{"owner":"dee@ex.com"}},"regex":"^eve\\.f@ex\\.com$"}'
  hook -0 "$(hook_input PreToolUse mcp__prod-write__update-many "$input")"
  hook -0 "$(hook_input PostToolUse mcp__prod-write__update-many "$input" \
    '{"tool_response": [{"type": "text", "text": "Matched 1 document, modified 1: gus@ex.com"}]}')"
  local masked='{"database":"conventioner","collection":"users","filter":{"email":"<email>","$or":[{"contact":{"emails":["<email>","not an address"]}},{"note":"mail <email> now"}]},"update":{"$set":{"owner":"<email>"}},"regex":"^<email>$"}'
  assert_equal "$(entries)" "- TIME requested \`prod-write\` \`update-many\` \`$masked\`
- TIME ran \`prod-write\` \`update-many\` \`$masked\`"
  run -1 grep -q -e @ -e Matched "$log"
}

@test "a write's phone numbers are masked in any common form, and its dates, ids and counts are kept" {
  local input='{"database":"conventioner","collection":"vendors","filter":{"_id":"65a1f3c2b9e8d7a6f5e4d3c2","since":"2026-10-23T12:28:00Z","day":"2026-10-23"},"update":{"$set":{"phone":"+1 604 555 0101","alt":["(604) 555-0102","6045550103","604.555.0105"],"note":"call +16045550104 or room 12, ref x6045550106"}},"limit":20}'
  hook -0 "$(hook_input PreToolUse mcp__prod-write__update-many "$input")"
  local masked='{"database":"conventioner","collection":"vendors","filter":{"_id":"65a1f3c2b9e8d7a6f5e4d3c2","since":"2026-10-23T12:28:00Z","day":"2026-10-23"},"update":{"$set":{"phone":"<phone>","alt":["<phone>","<phone>","<phone>"],"note":"call <phone> or room 12, ref x6045550106"}},"limit":20}'
  assert_equal "$(entries)" "- TIME requested \`prod-write\` \`update-many\` \`$masked\`"
  run -1 grep -q -e '555 0101' -e '555-0102' -e 6045550103 -e +16045550104 -e '555.0105' "$log"
}

@test "a failed write is logged with its error's first line, masked, and nothing else of the error" {
  local input='{"database":"conventioner","collection":"ops_checks","filter":{"_id":"65a1"},"update":{"$set":{"by":"hal@ex.com"}}}'
  hook -0 "$(hook_input PostToolUseFailure mcp__prod-write__update-one "$input" \
    '{"error": "MongoServerError: Document failed validation for ivy.k@ex.com\n{\"failingDocument\": {\"owner\": \"jo@ex.com\", \"name\": \"Jo Private\"}}", "is_interrupt": false}')"
  assert_equal "$output$stderr" ""
  assert_equal "$(entries)" "- TIME failed \`prod-write\` \`update-one\` \`{\"database\":\"conventioner\",\"collection\":\"ops_checks\",\"filter\":{\"_id\":\"65a1\"},\"update\":{\"\$set\":{\"by\":\"<email>\"}}}\` error \`MongoServerError: Document failed validation for <email>\`"
  run -1 grep -q -e @ -e failingDocument -e 'Jo Private' "$log"
}

@test "a write whose log cannot be written is blocked; a read is reported and let through" {
  local input='{"database":"conventioner","collection":"ops_checks","filter":{"_id":"65a1"},"update":{"$set":{"n":1}}}'
  mkdir "$log"
  hook -2 "$(hook_input PreToolUse mcp__prod-write__update-one "$input")"
  assert_equal "$output" ""
  assert_contains "$stderr" "Blocked: this production write could not be logged to $log, so it does not run."
  hook -0 "$(hook_input PreToolUse mcp__prod-read__find "$READ_INPUT")"
  assert_contains "$stderr" "ops-log: could not log this production read to $log"
  # After the call, a write's lost line is shown to the agent (exit 2 does not block there).
  hook -2 "$(hook_input PostToolUse mcp__prod-write__update-one "$input" '{"tool_response": []}')"
  assert_contains "$stderr" "this production write ran but could not be logged to $log"
}

@test "a write is blocked when its input cannot be read, even if the hook itself fails" {
  hook -2 'not json'
  assert_contains "$stderr" "Blocked:"
  [[ ! -e $log ]]
  # Without a tool name the hook cannot tell a read from a write, so it blocks.
  hook -2 '{"hook_event_name": "PreToolUse", "tool_input": {}}'
  # A missing log directory is a log that cannot be written.
  rm -r "$taskdir"
  hook -2 "$(hook_input PreToolUse mcp__prod-write__insert-many '{"documents":[]}')"
}

@test "the plugin form of a tool name is logged with its toolkit, and an unknown server counts as a write" {
  hook -0 "$(hook_input PreToolUse mcp__plugin_prod-read_prod-read__count '{"collection":"markets"}')"
  hook -0 "$(hook_input PreToolUse mcp__plugin_prod-write_prod-write__delete-many '{"collection":"ops_checks"}')"
  assert_equal "$(entries)" '- TIME requested `prod-read` `count` `{"collection":"markets"}`
- TIME requested `prod-write` `delete-many` `{"collection":"ops_checks"}`'
  rm "$log"
  mkdir "$log"
  hook -0 "$(hook_input PreToolUse mcp__plugin_prod-read_prod-read__count '{}')"
  hook -2 "$(hook_input PreToolUse mcp__prod-readwrite__count '{}')"
}

@test "an input holding backticks stays one code span" {
  hook -0 "$(hook_input PreToolUse mcp__prod-read__find '{"filter":{"name":"a`b``c"}}')"
  assert_equal "$(entries)" '- TIME requested `prod-read` `find` ```{"filter":{"name":"a`b``c"}}```'
}

@test "two hooks at once never interleave a line, and the header is written once" {
  local input
  input=$(hook_input PreToolUse mcp__prod-read__aggregate "{\"pipeline\":[{\"\$match\":{\"pad\":\"$(head -c 100000 /dev/zero | tr '\0' x)\"}}]}")
  for _ in $(seq 1 30); do
    "$REPO_ROOT/bin/hooks/ops-log" "$taskdir" <<<"$input" &
  done
  wait
  assert_equal "$(grep -c '^# Ops log of T7$' "$log")" 1
  assert_equal "$(grep -cE "^- $TIME requested \`prod-read\` \`aggregate\` \`\\{.*\\}\`\$" "$log")" 30
  assert_equal "$(wc -l <"$log")" 32
}

@test "the ops settings wire the hook for every production tool in both name forms" {
  local s=$REPO_ROOT/settings/ops.json event name
  for event in PreToolUse PostToolUse PostToolUseFailure; do
    assert_equal "$(jq -c --arg e "$event" '[.hooks[$e][] | select(.hooks[].command | endswith("/bin/hooks/ops-log"))]
      | map({matcher, args: .hooks[0].args}) ' "$s")" \
      '[{"matcher":"^mcp__.*prod-(read|write).*__","args":["@TASK_DIR@"]}]'
  done
  # Claude Code tests a matcher holding other characters than letters, digits, _, -, | and spaces
  # as an unanchored JavaScript regular expression; this one means the same in ERE.
  for name in mcp__prod-read__find mcp__prod-write__update-many mcp__plugin_prod-read_prod-read__find \
    mcp__plugin_prod-write_prod-write__delete-one; do
    grep -Eq "$(jq -r '.hooks.PreToolUse[] | select(.hooks[0].command | endswith("/bin/hooks/ops-log")) | .matcher' "$s")" <<<"$name" ||
      { echo "the matcher misses $name" >&2; return 1; }
  done
  for name in mcp__other__find Read mcp__prod_read__find; do
    run -1 grep -Eq "$(jq -r '.hooks.PreToolUse[] | select(.hooks[0].command | endswith("/bin/hooks/ops-log")) | .matcher' "$s")" <<<"$name"
  done
  # A failing or timed-out hook blocks the call instead of letting an unlogged write through.
  assert_equal "$(jq -r '.hooks.PreToolUse[] | select(.hooks[0].command | endswith("/bin/hooks/ops-log")) | .hooks[0].onFailure' "$s")" block
}
