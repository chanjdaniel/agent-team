#!/usr/bin/env bats
# team-load-check, the planner form: the planner it launches through team-worker reports its MCP tools and skills,
# and the check fails on anything production or coordinator-only. The session is a claude stub
# that writes the inventory from $STUB_FIXTURES/inventory.txt.

load helpers/common

setup() {
  sandbox
  export TEAM_LOAD_CHECK_DIR=$BATS_TEST_TMPDIR/load-check
  stub_script claude <<'SH'
case $1 in
  --bg)
    cp "$STUB_FIXTURES/inventory.txt" .scratch/inventory.txt
    echo "Started background session 4f2a9c1e (${*: -2:1}). Attach with: claude attach 4f2a9c1e"
    ;;
  agents) echo '[]' ;;
  stop | rm) ;;
  *) exit 64 ;;
esac
SH
}

# inventory <line>...: what the planner reports
inventory() {
  printf '%s\n' "$@" >"$STUB_FIXTURES/inventory.txt"
}

@test "a planner with no MCP tool and no production skill passes, and its inventory is kept" {
  inventory --- tdd implement
  run_bin -0 team-load-check
  assert_contains "$output" "load check: 0 MCP tools, 2 skills"
  assert_contains "$output" "PASS"
  assert_equal "$(cat "$TEAM_HOME/tasks/T0/inventory.txt")" "$(printf '%s\n' --- tdd implement)"
  assert_equal "$(stub_calls claude | jq -c 'select(.[0] != "--bg")')" \
    "$(printf '%s\n' '["agents","--json"]' '["stop","4f2a9c1e"]' '["rm","4f2a9c1e"]')"
}

@test "a production toolkit's tool or skill in a planner fails the check" {
  inventory mcp__prod-read__find --- tdd
  run_bin -1 team-load-check
  assert_contains "$output" "FAIL: MCP tools from outside the toolkits:"$'\n'"  mcp__prod-read__find"
  assert_contains "$output" "FAIL: a production or coordinator-only server or plugin reached the worker"

  inventory --- prod-write:changing-production-data
  run_bin -1 team-load-check
  assert_contains "$output" "FAIL: a production or coordinator-only server or plugin reached the worker"
  assert_contains "$output" "load check FAILED"
}

# The ops form. The claude stub plays the ops session: claude --bg copies $STUB_FIXTURES/session/
# into the worktree's .scratch/load-check-ops/, appends $STUB_FIXTURES/ops-log to T0's ops log as
# the ops-log hook would, and writes the session's transcript ($STUB_FIXTURES/transcript.jsonl, or
# '{}'); claude agents lists it until claude rm. team-ops-end, run for real, deletes the transcript.

ops_uuid=6f93fe38-4a6e-4b35-8f39-776a26bc624b
prod_read_tools=(aggregate aggregate-db collection-indexes collection-schema collection-storage-size
  count db-stats explain find list-collections list-databases)
prod_write_tools=(insert-many update-many delete-many create-index drop-index)

# ops_setup: a linked worktree, the stub, and a session that passes every check
ops_setup() {
  local clone
  clone=$(make_repo proj)
  wt=$HOME/wt/proj-1
  git -C "$clone" worktree add -q -b load "$wt"
  stub_script claude <<'SH'
transcript=$HOME/.claude/projects/-wt/6f93fe38-4a6e-4b35-8f39-776a26bc624b.jsonl
case $1 in
  --bg)
    touch "$STUB_FIXTURES/launched"
    cp -R "$STUB_FIXTURES/session/." .scratch/load-check-ops/
    cat "$STUB_FIXTURES/ops-log" >>"$TEAM_HOME/tasks/T0/ops-log.md"
    mkdir -p "$(dirname "$transcript")"
    cat "$STUB_FIXTURES/transcript.jsonl" 2>/dev/null >"$transcript" || echo '{}' >"$transcript"
    echo "Started background session 6f93fe38 (${*: -2:1}). Attach with: claude attach 6f93fe38"
    ;;
  agents)
    if [[ -f $STUB_FIXTURES/launched && ! -f $STUB_FIXTURES/removed ]]; then
      echo '[{"id": "6f93fe38", "name": "T0-ops", "state": "done", "sessionId": "6f93fe38-4a6e-4b35-8f39-776a26bc624b"}]'
    else
      echo '[]'
    fi
    ;;
  stop) ;;
  rm) touch "$STUB_FIXTURES/removed" ;;
  *) exit 64 ;;
esac
SH
  local s=$STUB_FIXTURES/session
  mkdir -p "$s"
  printf '%s\n' 'prod-read: connected' 'notice: connected' >"$s/connect.txt"
  {
    echo "tools: Read, Glob, Grep, Edit, Write, ToolSearch, SendMessage, ListAgents, EndConversation, $(printf 'mcp__prod-read__%s, ' "${prod_read_tools[@]}" | sed 's/, $//')"
    printf 'mcp__prod-read__%s\n' "${prod_read_tools[@]}"
    printf '%s: absent\n' Bash WebFetch WebSearch Agent Artifact
  } >"$s/tools.txt"
  printf '%s\n' 'grep-environ: refused: Permission to read /proc/self/environ has been denied.' \
    'read-status: refused: File is in a directory that is denied by your permission settings.' >"$s/probes.txt"
  printf '%s\n' 'list-collections: ok' 'count: 2' 'names: markets, stalls' >"$s/query.txt"
  echo 'done' >"$s/done.txt"
  oplog_lines requested ran
}

# oplog_lines <kind>...: what the session's hook appends, one list-collections line per kind
oplog_lines() {
  local kind
  for kind in "$@"; do
    echo "- 2026-10-23T12:28:58Z $kind \`prod-read\` \`list-collections\` \`{\"connectionId\":\"preconfigured\",\"database\":\"conventioner\"}\`"
  done >"$STUB_FIXTURES/ops-log"
}

@test "an ops session that can read only through prod-read passes, keeps its inventory and is ended with its transcript" {
  ops_setup
  mkdir -p "$TEAM_HOME/tasks/T0"
  printf '%s\n' '# Ops log of T0' '' '- 2026-10-22T00:00:00Z requested `prod-read` `find` `{}`' >"$TEAM_HOME/tasks/T0/ops-log.md"
  run_bin -0 team-load-check --role ops --worktree "$wt" --toolkit prod-read
  assert_contains "$output" "load check: Daniel, a 1Password prompt is coming on the PC: approve it"
  assert_contains "$output" "load check: 11 MCP tools, 9 built-in tools"
  assert_equal "${lines[-1]}" "PASS"
  # Launched through team-worker as the T0 ops session, in the given worktree.
  stub_calls claude | jq -e --arg wt "$(realpath "$wt")" 'select(.[0] == "--bg")
    | (index("--restricted") != null) and (.[index("--name") + 1] == "T0-ops")
      and (.[-1] | contains(".scratch/load-check-ops/"))' >/dev/null
  local inventory=$TEAM_HOME/tasks/T0/inventory-prod-read.txt
  assert_equal "$(sed '/^---$/q' "$inventory" | grep -c '^mcp__prod-read__')" 11
  assert_contains "$(<"$inventory")" $'---\ntools: Read'
  assert_equal "$(find "$HOME/.claude/projects" -name "$ops_uuid*")" ""
  assert_equal "$(stub_calls claude | jq -c 'select(.[0] == "rm")')" '["rm","6f93fe38"]'
}

@test "an ops session with a stray tool, a shell or a readable /proc fails, and is still ended" {
  ops_setup
  local s=$STUB_FIXTURES/session
  sed -i 's/^Bash: absent$/Bash: present/; s/^tools: Read,/tools: Read, Bash, WebFetch,/' "$s/tools.txt"
  echo mcp__plugin_prod-read_prod-read__find >>"$s/tools.txt"
  printf '%s\n' 'grep-environ: allowed: 42' 'read-status: allowed' >"$s/probes.txt"
  run_bin -1 team-load-check --role ops --worktree "$wt" --toolkit prod-read
  assert_contains "$output" "FAIL: the MCP tools are not exactly the toolkits' sets, once each:"$'\n'"  > mcp__plugin_prod-read_prod-read__find"
  assert_contains "$output" "FAIL: built-in tools beyond the ops allowlist: Bash WebFetch"
  assert_contains "$output" "FAIL: Bash is not reported absent"
  assert_contains "$output" "FAIL: the Grep of /proc/self/environ was not refused"
  assert_contains "$output" "FAIL: the Read of /proc/self/status was not refused"
  assert_equal "${lines[-1]}" "load check FAILED (inventory in tasks/T0/)"
  assert_equal "$(find "$HOME/.claude/projects" -name "$ops_uuid*")" ""
}

@test "the ops log must gain exactly a requested and a ran line for the one read" {
  ops_setup
  oplog_lines requested
  run_bin -1 team-load-check --role ops --worktree "$wt" --toolkit prod-read
  assert_contains "$output" "FAIL: the ops log did not gain exactly a requested and a ran line for list-collections"

  rm -f "$STUB_FIXTURES/launched" "$STUB_FIXTURES/removed"
  oplog_lines requested ran ran
  run_bin -1 team-load-check --role ops --worktree "$wt" --toolkit prod-read
  assert_contains "$output" "FAIL: the ops log did not gain exactly a requested and a ran line for list-collections"
}

@test "an ops session whose prod-read did not connect fails on that alone, with the notice it saw" {
  ops_setup
  local s=$STUB_FIXTURES/session
  printf '%s\n' 'prod-read: failed' 'notice: prod-read (CONNECTION_CLOSED): "Connection closed"' >"$s/connect.txt"
  rm "$s/tools.txt" "$s/probes.txt" "$s/query.txt"
  echo 'not connected' >"$s/done.txt"
  : >"$STUB_FIXTURES/ops-log"
  run_bin -1 team-load-check --role ops --worktree "$wt" --toolkit prod-read
  assert_contains "$output" 'FAIL: a production server did not connect: prod-read (CONNECTION_CLOSED): "Connection closed"'
  assert_equal "$(grep -c '^FAIL' <<<"$output")" 1
  assert_equal "$(find "$HOME/.claude/projects" -name "$ops_uuid*")" ""
}

# The write form: the session has both toolkits, makes the five write calls, Daniel declines each.

# write_session: both servers connected, both tool sets, and every write reported denied
write_session() {
  local s=$STUB_FIXTURES/session
  printf '%s\n' 'prod-read: connected' 'notice: connected' 'prod-write: connected' 'notice: connected' >"$s/connect.txt"
  {
    echo "tools: Read, Glob, Grep, Edit, Write, ToolSearch, SendMessage, ListAgents, EndConversation"
    printf 'mcp__prod-read__%s\n' "${prod_read_tools[@]}"
    printf 'mcp__prod-write__%s\n' "${prod_write_tools[@]}"
    printf '%s: absent\n' Bash WebFetch WebSearch Agent Artifact
  } >"$s/tools.txt"
  local tool
  for tool in "${prod_write_tools[@]}"; do
    echo "$tool: denied: The user doesn't want to proceed with this tool use."
  done >"$s/writes.txt"
  transcript list-collections:result "${prod_write_tools[@]/%/:user-rejected}" >"$STUB_FIXTURES/transcript.jsonl"
  oplog_lines requested ran
  for tool in "${prod_write_tools[@]}"; do write_line requested "$tool"; done >>"$STUB_FIXTURES/ops-log"
}

# transcript <tool>:<outcome>...: a transcript with one call per argument, in order; the outcome
# is 'result', or the toolDenialKind of a call that was refused.
transcript() {
  local call tool outcome i=0 server
  for call in "$@"; do
    tool=${call%%:*} outcome=${call#*:} i=$((i + 1)) server=prod-write
    [[ $tool != list-collections ]] || server=prod-read
    jq -nc --arg name "mcp__${server}__$tool" --arg id "toolu_$i" \
      '{type: "assistant", message: {content: [{type: "text", text: "calling"}, {type: "tool_use", id: $id, name: $name, input: {}}]}}'
    jq -nc --arg id "toolu_$i" --arg kind "$outcome" \
      '{type: "user", message: {content: [{type: "tool_result", tool_use_id: $id, content: "x"}]}}
        + (if $kind == "result" then {} else {toolDenialKind: $kind} end)'
  done
}

# write_line <kind> <tool>: the hook's line for a prod-write call
write_line() {
  echo "- 2026-10-23T12:30:00Z $1 \`prod-write\` \`$2\` \`{\"collection\":\"ops_checks\"}\`"
}

@test "an ops session whose five writes are each declined at a prompt passes, and keeps the write inventory" {
  ops_setup
  write_session
  run_bin -0 team-load-check --role ops --worktree "$wt" --toolkit prod-read --toolkit prod-write
  assert_contains "$output" "load check: Daniel, two 1Password prompts are coming on the PC: approve them; then decline each of the five write prompts on the phone"
  assert_contains "$output" "load check: 16 MCP tools, 9 built-in tools"
  assert_equal "${lines[-1]}" "PASS"
  # Both toolkits reach team-worker, and the prompt has the empty delete-many filter.
  stub_calls claude | jq -e 'select(.[0] == "--bg")
    | ([.[] | select(endswith("/toolkits/prod-write") or endswith("/toolkits/prod-read"))] | length == 2)
      and (.[-1] | contains("mcp__prod-write__delete-many with filter {} (exactly an empty filter)"))' >/dev/null
  local inventory=$TEAM_HOME/tasks/T0/inventory-prod-write.txt
  assert_equal "$(sed '/^---$/q' "$inventory" | grep -c '^mcp__prod-write__')" 5
  assert_equal "$(sed '/^---$/q' "$inventory" | grep -c '^mcp__prod-read__')" 11
  [[ ! -e $TEAM_HOME/tasks/T0/inventory-prod-read.txt ]]
  assert_equal "$(find "$HOME/.claude/projects" -name "$ops_uuid*")" ""
}

@test "a write that ran, a retried write, a missing report or tool, and a logged failure each fail the check" {
  ops_setup
  write_session
  local s=$STUB_FIXTURES/session
  sed -i '/^mcp__prod-write__drop-index$/d' "$s/tools.txt"
  sed -i '/^drop-index: denied/d' "$s/writes.txt"
  transcript list-collections:result insert-many:user-rejected insert-many:user-rejected update-many:result \
    delete-many:user-rejected create-index:user-rejected drop-index:user-rejected >"$STUB_FIXTURES/transcript.jsonl"
  { write_line ran update-many; write_line failed create-index; } >>"$STUB_FIXTURES/ops-log"
  run_bin -1 team-load-check --role ops --worktree "$wt" --toolkit prod-read --toolkit prod-write
  assert_contains "$output" "FAIL: the MCP tools are not exactly the toolkits' sets, once each:"$'\n'"  < mcp__prod-write__drop-index"
  assert_contains "$output" "FAIL: insert-many was not called once and declined at its prompt (transcript: 2 call(s))"
  assert_contains "$output" "FAIL: update-many was not called once and declined at its prompt (transcript: 1 call(s))"
  assert_contains "$output" "FAIL: the session did not report drop-index as denied"
  assert_contains "$output" "FAIL: the ops log did not gain exactly a requested line for update-many"
  assert_contains "$output" "FAIL: the ops log did not gain exactly a requested line for create-index"
  assert_contains "$output" "FAIL: the ops log gained 9 event lines, not one per call made"
  [[ $output != *"FAIL: delete-many"* && $output != *"for delete-many"* ]]
  assert_equal "${lines[-1]}" "load check FAILED (inventory in tasks/T0/)"
  assert_equal "$(find "$HOME/.claude/projects" -name "$ops_uuid*")" ""
}

@test "the ops form needs a worktree and prod-read, alone or with prod-write, and the planner form takes no worktree" {
  run_bin -2 team-load-check --role ops --toolkit prod-read
  assert_contains "$output" "--role ops needs --worktree"
  run_bin -2 team-load-check --role ops --worktree "$HOME" --toolkit prod-write
  assert_contains "$output" "--role ops checks --toolkit prod-read, alone or with --toolkit prod-write"
  run_bin -2 team-load-check --role ops --worktree "$HOME" --toolkit prod-read --toolkit find
  assert_contains "$output" "--role ops checks --toolkit prod-read, alone or with --toolkit prod-write"
  run_bin -2 team-load-check --role ops --worktree "$HOME"
  assert_contains "$output" "--role ops checks --toolkit prod-read, alone or with --toolkit prod-write"
  run_bin -2 team-load-check --worktree "$HOME"
  assert_contains "$output" "--worktree is for --role ops only"
  run_bin -2 team-load-check --role builder
  assert_contains "$output" "unknown role 'builder'"
  run_bin -2 team-load-check --toolkit
  assert_equal "$(stub_calls claude)" ""
}
