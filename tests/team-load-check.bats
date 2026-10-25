#!/usr/bin/env bats
# team-load-check: team-doctor runs first, and a FAIL there stops the load check before it
# touches its scratch repo or launches a worker; the other tests pass a stub doctor (TEAM_DOCTOR).
# The planner form: the planner it launches through team-worker reports its MCP tools and skills,
# and the check fails on anything production or coordinator-only. The session is a claude stub
# that writes the inventory from $STUB_FIXTURES/inventory.txt. Before it, each treehouse project's
# lease is rehearsed on a fake pool (helpers/treehouse); the registry has no treehouse project
# unless a test adds one.

load helpers/common
load helpers/treehouse

setup() {
  sandbox
  export TEAM_LOAD_CHECK_DIR=$BATS_TEST_TMPDIR/load-check
  # A doctor that passes; the doctor's own lines are tests/team-doctor*.bats'.
  export TEAM_DOCTOR=$BATS_TEST_TMPDIR/doctor
  printf '%s\n' '#!/usr/bin/env bash' 'echo "PASS machine: named"' >"$TEAM_DOCTOR"
  chmod +x "$TEAM_DOCTOR"
  registry
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

# registry [<treehouse project's pool block>]: projects.toml with a git pool project, site, and,
# when given, a treehouse one, proj, with that pool
registry() {
  {
    project site
    printf '%s\n' '[site.pool]' 'provider = "git"' 'slots = []'
    if [[ -n ${1:-} ]]; then project proj && echo "$1"; fi
  } >"$TEAM_HOME/projects.toml"
}

project() {
  printf '%s\n' "[$1]" "repo = \"owner/$1\"" "path = \"projects/$1\"" 'base = "main"' 'delivery = "no-mistakes"' \
    'merge_method = "merge"' 'required_checks = []' 'task_dir = ".scratch/task"' 'docs = []' 'toolkits = []'
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

# The lease rehearsal. proj's primary checkout has two treehouse slots, free, whose fake lease
# runs $BATS_TEST_TMPDIR/prewarm in the slot it hands out (helpers/treehouse).

# lease_setup: proj with a treehouse pool of two free slots
lease_setup() {
  primary=$(make_repo proj)
  printf '%s\n' .scratch/ node_modules/ >"$primary/.gitignore"
  git -C "$primary" add .gitignore
  git -C "$primary" commit -q -m "chore: ignore scratch"
  git -C "$primary" push -q origin main
  local pool=$HOME/.treehouse/proj-abc123 slot
  slots=("$pool/1/proj" "$pool/2/proj")
  for slot in "${slots[@]}"; do git -C "$primary" worktree add -q --detach "$slot" origin/main; done
  printf '%s\n' "${slots[@]}" >"$BATS_TEST_TMPDIR/free"
  fake_pool_commands "$primary"
  registry "$(printf '%s\n' '[proj.pool]' 'provider = "treehouse"' 'lease = "scripts/th-lease.sh"' \
    'return = "scripts/th-return.sh"' \
    'slots = [".treehouse/proj-abc123/1/proj", ".treehouse/proj-abc123/2/proj"]')"
  inventory --- tdd
}

# The holder the load check leased to, from the lease command's first call.
lease_holder() {
  stub_calls th-lease.sh | jq -r '.args[0]' | head -n 1
}

@test "each treehouse project's slot is leased, pre-warmed, found clean and returned, before the planner runs" {
  lease_setup
  echo 'mkdir -p node_modules && touch node_modules/.warm' >"$BATS_TEST_TMPDIR/prewarm"
  run_bin -0 team-load-check
  local holder
  holder=$(lease_holder)
  [[ $holder == load-check-* ]]
  assert_equal "$(pool_calls th-lease.sh)" "$holder"
  assert_equal "$(stub_calls th-lease.sh | jq -r .cwd)" "$primary"
  assert_contains "$output" "load check: leasing a slot of proj (a cold slot's pre-warm can take minutes)"
  assert_contains "$output" "PASS lease proj: slot ${slots[0]} leased, pre-warmed and clean, returned"
  # Only the treehouse project is rehearsed; the planner runs after it.
  [[ $output != *"lease site"* ]]
  assert_contains "$output" $'returned\nload check: worker 4f2a9c1e started'
  assert_equal "${lines[-1]}" "PASS"
  # Returned through the return command, forced back only from this run's holder; the warm
  # node_modules git ignores is left.
  assert_equal "$(pool_calls th-return.sh)" "${slots[0]} --force --if-lease-holder $holder"
  assert_equal "$(pool_leases)" ""
  [[ -e ${slots[0]}/node_modules/.warm ]]
}

@test "a pre-warm that changes the slot fails the load check, naming the project and the paths, and the slot is still returned" {
  lease_setup
  echo 'echo changed >>README.md && touch new.lock' >"$BATS_TEST_TMPDIR/prewarm"
  run_bin -1 team-load-check
  assert_contains "$output" "FAIL lease proj: slot ${slots[0]} is not clean after the pre-warm: changes to tracked files: README.md; untracked files: new.lock; returned"
  assert_equal "${lines[-1]}" "load check FAILED (inventory in tasks/T0/)"
  assert_equal "$(pool_leases)" ""
  assert_equal "$(git -C "${slots[0]}" status --porcelain)" ""

  # A non-empty task directory fails it as team-open would.
  rm "$BATS_TEST_TMPDIR/prewarm"
  local next
  next=$(head -n 1 "$BATS_TEST_TMPDIR/free")
  mkdir -p "$next/.scratch/task" && touch "$next/.scratch/task/plan.md"
  run_bin -1 team-load-check
  assert_contains "$output" "FAIL lease proj: slot $next is not clean after the pre-warm: a non-empty task directory .scratch/task: plan.md; returned"
  assert_equal "$(pool_leases)" ""
}

@test "a project with no free slot is a WARN naming the holders, and a lease command that fails with a slot free is a FAIL" {
  lease_setup
  : >"$BATS_TEST_TMPDIR/free"
  printf '%s\tT7\n%s\tT9\n' "${slots[@]}" >"$BATS_TEST_TMPDIR/leases"
  run_bin -0 team-load-check
  assert_contains "$output" "WARN lease proj: no free slot to rehearse a lease on: ${slots[0]}: T7; ${slots[1]}: T9"
  assert_equal "${lines[-1]}" "PASS"
  assert_equal "$(pool_leases)" "$(printf '%s T7\n%s T9' "${slots[@]}")"

  # A slot is free, yet the lease fails: the standby is broken.
  printf '%s\tT7\n' "${slots[0]}" >"$BATS_TEST_TMPDIR/leases"
  run_bin -1 team-load-check
  assert_contains "$output" "FAIL lease proj: the lease command failed though ${slots[1]} is free: all 2 worktrees are in use or dirty"

  # A pool treehouse cannot read is a FAIL, leasing nothing.
  rm "$STUB_FIXTURES/treehouse.sh"
  stub_reply treehouse 'not json'
  rm "$STUB_CALLS/th-lease.sh.log"
  run_bin -1 team-load-check
  assert_contains "$output" "FAIL lease proj: cannot read its pool: treehouse status --json did not answer in $primary"
  assert_equal "$(stub_calls th-lease.sh)" ""
}

@test "a load check stopped during the lease still returns the slot" {
  lease_setup
  printf '%s\n' "touch '$BATS_TEST_TMPDIR/leasing'" 'echo changed >>README.md' 'sleep 1' >"$BATS_TEST_TMPDIR/prewarm"
  guard_sandbox
  "$REPO_ROOT/bin/team-load-check" >"$BATS_TEST_TMPDIR/out" 2>&1 &
  local pid=$!
  for _ in $(seq 1 100); do [[ ! -e $BATS_TEST_TMPDIR/leasing ]] || break; sleep 0.1; done
  kill -TERM "$pid"
  [[ -e $BATS_TEST_TMPDIR/leasing ]]
  local status=0
  wait "$pid" || status=$?
  assert_equal "$status" 143
  assert_equal "$(pool_leases)" ""
  assert_equal "$(git -C "${slots[0]}" status --porcelain)" ""
  assert_equal "$(stub_calls claude)" ""
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
    echo "tools: Read, Glob, Grep, Edit, Write, ToolSearch, SendMessage, ListAgents, Skill, EndConversation, $(printf 'mcp__prod-read__%s, ' "${prod_read_tools[@]}" | sed 's/, $//')"
    printf 'mcp__prod-read__%s\n' "${prod_read_tools[@]}"
    printf '%s: absent\n' Bash WebFetch WebSearch Agent Artifact
  } >"$s/tools.txt"
  printf '%s\n' 'grep-environ: refused: Permission to read /proc/self/environ has been denied.' \
    'read-status: refused: File is in a directory that is denied by your permission settings.' >"$s/probes.txt"
  printf '%s\n' 'list-collections: ok' 'count: 2' 'names: markets, stalls' >"$s/query.txt"
  echo 'prod-read:querying-production-data' >"$s/skills.txt"
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
  assert_contains "$output" "load check: 11 MCP tools, 10 built-in tools"
  assert_equal "${lines[-1]}" "PASS"
  # Launched through team-worker as the T0 ops session, in the given worktree.
  stub_calls claude | jq -e --arg wt "$(realpath "$wt")" 'select(.[0] == "--bg")
    | (index("--restricted") != null) and (.[index("--name") + 1] == "T0-ops")
      and (.[-1] | contains(".scratch/load-check-ops/"))' >/dev/null
  local inventory=$TEAM_HOME/tasks/T0/inventory-prod-read.txt
  assert_equal "$(sed '/^---$/q' "$inventory" | grep -c '^mcp__prod-read__')" 11
  assert_contains "$(<"$inventory")" $'---\ntools: Read'
  assert_contains "$(<"$inventory")" $'\nskill: prod-read:querying-production-data'
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

@test "an ops session must see its toolkits' skills and no other skill" {
  ops_setup
  local s=$STUB_FIXTURES/session
  printf '%s\n' simplify prod-write:changing-production-data loop >"$s/skills.txt"
  run_bin -1 team-load-check --role ops --worktree "$wt" --toolkit prod-read
  assert_contains "$output" "FAIL: skills beyond the toolkits': simplify prod-write:changing-production-data loop"
  assert_contains "$output" "FAIL: the session cannot invoke querying-production-data"
  assert_equal "${lines[-1]}" "load check FAILED (inventory in tasks/T0/)"

  # The bare names count as well as the namespaced ones; no skills file is no skill.
  rm -f "$STUB_FIXTURES/launched" "$STUB_FIXTURES/removed"
  echo querying-production-data >"$s/skills.txt"
  run_bin -0 team-load-check --role ops --worktree "$wt" --toolkit prod-read
  rm -f "$STUB_FIXTURES/launched" "$STUB_FIXTURES/removed" "$s/skills.txt"
  run_bin -1 team-load-check --role ops --worktree "$wt" --toolkit prod-read
  assert_contains "$output" "FAIL: the session cannot invoke querying-production-data"

  # A write session needs both.
  rm -f "$STUB_FIXTURES/launched" "$STUB_FIXTURES/removed"
  write_session
  echo prod-read:querying-production-data >"$s/skills.txt"
  run_bin -1 team-load-check --role ops --worktree "$wt" --toolkit prod-read --toolkit prod-write
  assert_contains "$output" "FAIL: the session cannot invoke changing-production-data"
  [[ $output != *"skills beyond"* ]]
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
    echo "tools: Read, Glob, Grep, Edit, Write, ToolSearch, SendMessage, ListAgents, Skill, EndConversation"
    printf 'mcp__prod-read__%s\n' "${prod_read_tools[@]}"
    printf 'mcp__prod-write__%s\n' "${prod_write_tools[@]}"
    printf '%s: absent\n' Bash WebFetch WebSearch Agent Artifact
  } >"$s/tools.txt"
  printf '%s\n' prod-read:querying-production-data prod-write:changing-production-data >"$s/skills.txt"
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
  assert_contains "$output" "load check: 16 MCP tools, 10 built-in tools"
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

@test "a FAIL from team-doctor stops the load check, launching nothing" {
  unset TEAM_DOCTOR
  hold_lease home-pc >/dev/null
  # An OS the team does not run on is a FAIL whatever this machine's tools are.
  stub_command uname
  stub_reply uname Linux
  export TEAM_OS_RELEASE=$BATS_TEST_TMPDIR/os-release
  printf '%s\n' 'PRETTY_NAME="Ubuntu 24.04.3 LTS"' 'ID=ubuntu' >"$TEAM_OS_RELEASE"
  rm "$STUB_FIXTURES/claude.sh"
  stub_reply claude '{"loggedIn": true, "authMethod": "claude.ai"}'
  stub_reply gh ''
  stub_reply curl ''

  run_bin -1 --separate-stderr team-load-check
  assert_equal "${lines[0]}" "FAIL os: Ubuntu 24.04.3 LTS is neither Arch Linux nor macOS, so no tool is checked; fix: run the team on Arch Linux or macOS"
  assert_equal "$stderr" "load check: team-doctor reports a FAIL above; fix it, then run the load check again"
  [[ ! -e $TEAM_LOAD_CHECK_DIR ]]
  # claude was asked only the doctor's questions, its login, its plugins and its trust probe of
  # the team home (which the stub's reply never starts): no session of the load check's.
  assert_equal "$(stub_calls claude | jq -r 'join(" ")' | sort -u)" "--bg --name team-doctor-home-trust
agents --json
auth status --json
plugin list --json"
}
