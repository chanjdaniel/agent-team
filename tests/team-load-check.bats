#!/usr/bin/env bats
# team-load-check: team-doctor --json runs first, and a FAIL there that bears on a session the
# form starts stops the load check before it touches its worktree or launches a worker; the other
# tests pass a stub doctor (TEAM_DOCTOR).
# The planner form: the planner it launches through team-worker, in a detached worktree of the code
# checkout (a sandbox repo, TEAM_LOAD_CHECK_CHECKOUT) at .claude/worktrees/load-check, reports its
# MCP tools and skills, and the check fails on anything production or coordinator-only. The session
# is a claude stub that writes the inventory from $STUB_FIXTURES/inventory.txt, notes in
# $BATS_TEST_TMPDIR/launch where it started, and writes outside.txt where it started when
# $STUB_FIXTURES/write-outside exists. It copies the markers planted in its worktree to
# $BATS_TEST_TMPDIR/planted-claude.md and planted-claude/, and writes the isolation report from what
# team-worker gave it (its fixtures are named beside it). Before it, each treehouse project's
# lease is rehearsed on a fake pool (helpers/treehouse); the registry has no treehouse project
# unless a test adds one.

load helpers/common
load helpers/ops-request
load helpers/treehouse

setup() {
  sandbox
  code=$(make_repo code)
  printf '%s\n' .scratch/ .claude/worktrees/ >"$code/.gitignore"
  # The project's instructions, which team-worker gives each session from origin/main.
  echo "# code" >"$code/CLAUDE.md"
  git -C "$code" add .gitignore CLAUDE.md
  git -C "$code" commit -q -m "chore: ignore scratch and worktrees"
  git -C "$code" push -q origin main
  code=$(realpath "$code") wt=$code/.claude/worktrees/load-check
  export TEAM_LOAD_CHECK_CHECKOUT=$code
  # A doctor that answers --json with $BATS_TEST_TMPDIR/doctor.json, and fails when it holds a
  # FAIL, as team-doctor does; it passes until a test calls doctor_results. The doctor's own lines
  # are tests/team-doctor*.bats'.
  export TEAM_DOCTOR=$BATS_TEST_TMPDIR/doctor
  printf '%s\n' '#!/usr/bin/env bash' '[[ $* == --json ]] || exit 64' 'cat "$BATS_TEST_TMPDIR/doctor.json"' \
    'jq -e "all(.[]; .verdict != \"FAIL\")" "$BATS_TEST_TMPDIR/doctor.json" >/dev/null 2>&1' >"$TEAM_DOCTOR"
  chmod +x "$TEAM_DOCTOR"
  doctor_results
  registry
  stub_script claude <<'SH'
case $1 in
  --bg)
    { pwd -P; git rev-parse HEAD; git symbolic-ref -q HEAD || echo detached
      git check-ignore -q .scratch/inventory.txt && echo '.scratch ignored'
      ls -A | grep -vx -e .git -e .gitignore -e README.md -e CLAUDE.md -e .scratch -e .claude || true; } >"$BATS_TEST_TMPDIR/launch"
    rm -rf "$BATS_TEST_TMPDIR/planted-claude" && cp -R .claude "$BATS_TEST_TMPDIR/planted-claude" 2>/dev/null || true
    cp CLAUDE.md "$BATS_TEST_TMPDIR/planted-claude.md" 2>/dev/null || true
    [[ ! -e $STUB_FIXTURES/write-outside ]] || echo planner >outside.txt
    # The isolation report, as a session reports what it was given: the heading of its system
    # prompt file's project section, its settings' memory directory, its working directory, and a
    # marker only where $STUB_FIXTURES/leak-claude-md or leak-rules has the worktree's file reach
    # it; run-hook runs the worktree's SessionStart hook; heading, memory and cwd override a value;
    # no-isolation writes no report.
    prompt_file='' settings_file='' args=("$@")
    for ((i = 0; i < ${#args[@]} - 1; i++)); do
      case ${args[i]} in
        --append-system-prompt-file) prompt_file=${args[i + 1]} ;;
        --settings) settings_file=${args[i + 1]} ;;
      esac
    done
    if [[ -e $STUB_FIXTURES/run-hook ]]; then
      bash -c "$(jq -r '.hooks.SessionStart[].hooks[].command' .claude/settings.json)"
    fi
    if [[ ! -e $STUB_FIXTURES/no-isolation ]]; then
      markers=$( { [[ ! -e $STUB_FIXTURES/leak-claude-md ]] || cat CLAUDE.md
        [[ ! -e $STUB_FIXTURES/leak-rules ]] || cat .claude/rules/*.md; } | { grep -oE 'load-check-marker-[a-z0-9-]+' || true; } | paste -sd ' ')
      heading=$(sed -n 's/^# \(Project instructions: .*\)$/\1/p' "$prompt_file" | head -n 1)
      memory=$(jq -r '.autoMemoryDirectory // "none"' "$settings_file")
      memory=${memory/#\~/$HOME}
      [[ ! -f $STUB_FIXTURES/heading ]] || heading=$(cat "$STUB_FIXTURES/heading")
      [[ ! -f $STUB_FIXTURES/memory ]] || memory=$(cat "$STUB_FIXTURES/memory")
      cwd=$(pwd -P)
      [[ ! -f $STUB_FIXTURES/cwd ]] || cwd=$(cat "$STUB_FIXTURES/cwd")
      printf '%s\n' "markers: ${markers:-none}" "heading: ${heading:-none}" "memory: $memory" "cwd: $cwd" >.scratch/isolation.txt
    fi
    cp "$STUB_FIXTURES/inventory.txt" .scratch/inventory.txt
    echo "Started background session 4f2a9c1e (${*: -2:1}). Attach with: claude attach 4f2a9c1e"
    ;;
  agents) echo '[]' ;;
  --settings)
    # claude --settings <file> auto-mode config: the file's autoMode lists, "$defaults" read as one
    # built-in line, or $STUB_FIXTURES/automode.json when the test writes one
    [[ ${3:-} == auto-mode && ${4:-} == config ]] || exit 64
    pwd -P >>"$BATS_TEST_TMPDIR/automode-cwd"
    if [[ -f $STUB_FIXTURES/automode.json ]]; then cat "$STUB_FIXTURES/automode.json"
    else jq '(.autoMode // {}) | map_values(map(if . == "$defaults" then "a built-in line" else . end))' "$2"; fi
    ;;
  stop | rm) ;;
  *) exit 64 ;;
esac
SH
}

# registry [<proj's pool block>]: projects.toml with the code checkout's own project, code, and a
# git pool project, site, and, when given, proj, with that pool, listing prod-read, prod-write and
# vercel-read (T0 takes no production toolkit its project does not list); code is registered, as
# the real code checkout is, since team-worker gives a toolkit, the project's instructions and its
# memory directory only in a registered project's worktree
registry() {
  {
    project code
    printf '%s\n' '[code.pool]' 'provider = "git"' 'slots = []'
    project site
    printf '%s\n' '[site.pool]' 'provider = "git"' 'slots = []'
    if [[ -n ${1:-} ]]; then project proj '["prod-read", "prod-write", "vercel-read"]' && echo "$1"; fi
  } >"$TEAM_HOME/projects.toml"
}

# project <name> [<toolkits, a TOML list>]: the project's table, its toolkits none by default
project() {
  printf '%s\n' "[$1]" "repo = \"owner/$1\"" "path = \"projects/$1\"" 'base = "main"' 'delivery = "no-mistakes"' \
    'merge_method = "merge"' 'required_checks = []' 'task_dir = ".scratch/task"' 'docs = []' "toolkits = ${2:-[]}"
}

# doctor_results [<verdict> <check>]...: the stub doctor's results: a PASS of machine, then each
# given one, its reason "broken" and its fix "repair it"
doctor_results() {
  local results='{"check": "machine", "verdict": "PASS", "reason": "named", "fix": ""}'
  while [[ $# -gt 0 ]]; do
    results+=$(jq -cn --arg verdict "$1" --arg check "$2" '{$check, $verdict, reason: "broken", fix: "repair it"}')
    shift 2
  done
  jq -s . <<<"$results" >"$BATS_TEST_TMPDIR/doctor.json"
}

# going_on <check>: the line the load check names a FAIL it goes on past with
going_on() {
  echo "load check: going on past FAIL $1: it bears on no session this check starts"
}

stopped="load check: team-doctor reports a FAIL above; fix it, then run the load check again"

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
    "$(printf '%s\n' "[\"--settings\",\"$TEAM_HOME/tasks/T0/settings.planner.code.json\",\"auto-mode\",\"config\"]" \
      '["agents","--json"]' '["stop","4f2a9c1e"]' '["rm","4f2a9c1e"]')"
}

# The team's autoMode lines in the settings team-worker generated for <role> (default planner),
# the registry's projects filled in: settings.<role>.code.json, keyed by the code checkout's
# project, for every role but ops.
team_lines() {
  local stem=${1:-planner}
  [[ $stem == ops ]] || stem+=.code
  jq -r '.autoMode.environment[] | select(. != "$defaults")' "$TEAM_HOME/tasks/T0/settings.$stem.json"
}

@test "the planner's effective autoMode, read under its settings in its worktree, holds the team's lines and is kept" {
  inventory --- tdd
  run_bin -0 team-load-check
  assert_contains "$output" "load check: planner's effective autoMode holds the $(team_lines | wc -l) lines of its settings' autoMode (claude auto-mode config under its settings, kept in tasks/T0/automode-planner.json)"
  assert_equal "${lines[-1]}" PASS
  assert_equal "$(cat "$BATS_TEST_TMPDIR/automode-cwd")" "$wt"
  assert_equal "$(jq -r '.environment[]' "$TEAM_HOME/tasks/T0/automode-planner.json")" "$(echo 'a built-in line'; team_lines)"
}

@test "an effective autoMode that lacks a team line, or no config at all, fails the check" {
  inventory --- tdd
  # The worker settings' first team line, which names no registry fact, is the one the config holds.
  jq -n --arg first "$(jq -r '.autoMode.environment[1]' "$REPO_ROOT/settings/worker.json")" '{environment: ["a built-in line", $first], soft_deny: ["a built-in rule"]}' \
    >"$STUB_FIXTURES/automode.json"
  run_bin -1 team-load-check
  assert_contains "$output" "FAIL planner: its effective autoMode lacks its settings' environment line: $(team_lines | sed -n 2p)"
  assert_equal "$(grep -c "FAIL planner: its effective autoMode lacks" <<<"$output")" "$(($(team_lines | wc -l) - 1))"
  assert_equal "${lines[-1]}" "load check FAILED (inventory in tasks/T0/)"
  left_nothing

  echo 'not json' >"$STUB_FIXTURES/automode.json"
  run_bin -1 team-load-check
  assert_contains "$output" "FAIL planner: claude auto-mode config under its settings printed no config"
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

@test "a vercel-read tool or skill in a planner fails the check" {
  inventory mcp__vercel-read__list-env-names --- tdd
  run_bin -1 team-load-check
  assert_contains "$output" "FAIL: MCP tools from outside the toolkits:"$'\n'"  mcp__vercel-read__list-env-names"
  assert_contains "$output" "FAIL: a production or coordinator-only server or plugin reached the worker"

  inventory --- tdd vercel-read:reading-vercel-deployments
  run_bin -1 team-load-check
  assert_contains "$output" "FAIL: a production or coordinator-only server or plugin reached the worker"
  [[ $output != *"MCP tools from outside"* ]]
  assert_equal "${lines[-1]}" "load check FAILED (inventory in tasks/T0/)"
}

# toolkit_checkout: a code checkout of the test's own for run_bin, holding this one's bin/, roles/
# and settings/ and two fixture toolkits: served, whose .mcp.json declares the MCP servers served
# and spare, and plain, with no .mcp.json; the code checkout's project is registered (registry).
toolkit_checkout() {
  export CODE_CHECKOUT=$BATS_TEST_TMPDIR/toolkit-code
  mkdir -p "$CODE_CHECKOUT/toolkits/served" "$CODE_CHECKOUT/toolkits/plain"
  copy_bin "$CODE_CHECKOUT/bin"
  cp -R "$REPO_ROOT/roles" "$REPO_ROOT/settings" "$CODE_CHECKOUT/"
  echo '{"mcpServers": {"served": {"command": "node"}, "spare": {"command": "node"}}}' >"$CODE_CHECKOUT/toolkits/served/.mcp.json"
}

@test "each MCP server a given toolkit declares must bring its tools to the planner, under its own name or the plugin's" {
  toolkit_checkout
  inventory mcp__served__look mcp__served__read mcp__plugin_served_spare__look --- served:a-skill
  run_bin -0 team-load-check --toolkit served
  assert_contains "$output" "load check: 3 MCP tools, 1 skills"
  assert_equal "${lines[-1]}" PASS

  # The toolkit's skill came, and none of its servers' tools.
  inventory --- served:a-skill
  run_bin -1 team-load-check --toolkit served
  assert_contains "$output" "FAIL: toolkit served brought no tools from its MCP server served"
  assert_contains "$output" "FAIL: toolkit served brought no tools from its MCP server spare"
  assert_equal "${lines[-1]}" "load check FAILED (inventory in tasks/T0/)"

  # One server's tools came, the other's did not.
  inventory mcp__served__look --- served:a-skill
  run_bin -1 team-load-check --toolkit served
  assert_contains "$output" "FAIL: toolkit served brought no tools from its MCP server spare"
  [[ $output != *"MCP server served"* ]]

  # A server the toolkit's mcp-roles.json names for other roles only is neither expected of the
  # planner nor allowed it.
  echo '{"spare": ["builder", "reviewer"]}' >"$CODE_CHECKOUT/toolkits/served/mcp-roles.json"
  run_bin -0 team-load-check --toolkit served
  assert_equal "${lines[-1]}" PASS
  inventory mcp__served__look mcp__spare__look --- served:a-skill
  run_bin -1 team-load-check --toolkit served
  assert_contains "$output" "FAIL: MCP tools from outside the toolkits:"$'\n'"  mcp__spare__look"
  rm "$CODE_CHECKOUT/toolkits/served/mcp-roles.json"

  # A toolkit that declares no MCP server needs none.
  inventory --- plain:a-skill
  run_bin -0 team-load-check --toolkit plain
}

# left_nothing: the load check's worktree is gone, and the code checkout is as it was
left_nothing() {
  [[ ! -e $wt ]]
  assert_equal "$(git -C "$code" worktree list --porcelain | sed -n 's/^worktree //p')" "$code"
  assert_equal "$(git -C "$code" status --porcelain --ignored)" ""
}

@test "the planner runs in a fresh worktree of the code checkout, detached at its HEAD, which is removed at the end" {
  inventory --- tdd
  run_bin -0 team-load-check
  assert_equal "$(cat "$BATS_TEST_TMPDIR/launch")" "$(printf '%s\n' "$wt" "$(git -C "$code" rev-parse HEAD)" detached '.scratch ignored')"
  left_nothing

  # What an earlier run left there, registered or not, is replaced by a fresh worktree.
  git -C "$code" worktree add -q -b stale "$wt"
  touch "$wt/stale.txt"
  run_bin -0 team-load-check
  assert_equal "$(cat "$BATS_TEST_TMPDIR/launch")" "$(printf '%s\n' "$wt" "$(git -C "$code" rev-parse HEAD)" detached '.scratch ignored')"
  git -C "$code" branch -q -D stale
  left_nothing
  mkdir -p "$wt"
  touch "$wt/junk.txt"
  run_bin -0 team-load-check
  assert_equal "$(sed -n 1p "$BATS_TEST_TMPDIR/launch")" "$wt"
  assert_equal "$(sed -n 5p "$BATS_TEST_TMPDIR/launch")" ""
  left_nothing
}

@test "a planner that writes outside .scratch/ fails the check, and the worktree is still removed" {
  inventory --- tdd
  touch "$STUB_FIXTURES/write-outside"
  run_bin -1 team-load-check
  assert_contains "$output" "FAIL: the planner wrote outside .scratch/"
  left_nothing
}

@test "a failing planner check also leaves nothing in the code checkout" {
  inventory mcp__prod-read__find --- tdd
  run_bin -1 team-load-check
  left_nothing
}

# isolation_pass: the PASS line of a planner none of whose worktree's markers reached it
isolation_pass() {
  echo "PASS planner: no marker of its worktree reached it (the line in CLAUDE.md, the file in .claude/rules/, the SessionStart hook in .claude/settings.json), its project instructions are headed 'Project instructions: code, from origin/main at $(git -C "$code" rev-parse origin/main)', its memory directory is $TEAM_HOME/memory/code, and it works in $wt"
}

@test "the planner's worktree gets a CLAUDE.md line, a .claude/rules/ file and a .claude/settings.json hook and allow rule, and a planner that reports none of them passes" {
  inventory --- tdd
  # A tracked .claude/settings.json keeps its keys, and a commit not on origin/main is not the
  # instructions' ref.
  mkdir -p "$code/.claude"
  echo '{"worktree": {"bgIsolation": "none"}}' >"$code/.claude/settings.json"
  git -C "$code" add .claude/settings.json
  git -C "$code" commit -q -m "chore: settings"
  run_bin -0 team-load-check
  assert_contains "$output" "$(isolation_pass)"
  assert_equal "${lines[-1]}" PASS

  # The markers, planted before the launch, each its own word of this run.
  assert_equal "$(head -n 1 "$BATS_TEST_TMPDIR/planted-claude.md")" "# code"
  claude_md=$(tail -n 1 "$BATS_TEST_TMPDIR/planted-claude.md" | grep -oE 'load-check-marker-claude-md-[0-9a-f]+')
  rules=$(grep -ohE 'load-check-marker-rules-[0-9a-f]+' "$BATS_TEST_TMPDIR"/planted-claude/rules/*.md)
  settings=$BATS_TEST_TMPDIR/planted-claude/settings.json
  assert_equal "$(jq -r .worktree.bgIsolation "$settings")" none
  assert_equal "$(jq -r '.hooks.SessionStart | length' "$settings")" 1
  hook=$(jq -r '.hooks.SessionStart[0].hooks[0] | select(.type == "command") | .command' "$settings")
  assert_contains "$hook" "$wt/.scratch/load-check-hook-"
  [[ $(jq -r '.permissions.allow[]' "$settings") =~ ^Bash\(echo\ load-check-marker-allow-[0-9a-f]+\)$ ]]
  [[ ${claude_md#load-check-marker-claude-md-} == "${rules#load-check-marker-rules-}" ]]
  # The planner is asked for them, and never told them.
  prompt=$(stub_calls claude | jq -rs '[.[] | select(.[0] == "--bg")][-1] | join(" ")')
  assert_contains "$prompt" ".scratch/isolation.txt"
  [[ $prompt != *"$claude_md"* && $prompt != *"$rules"* ]]
  left_nothing

  # A second run plants markers of its own.
  run_bin -0 team-load-check
  [[ $(tail -n 1 "$BATS_TEST_TMPDIR/planted-claude.md") != *"$claude_md"* ]]
  left_nothing
}

@test "each worktree marker that reaches the planner and each wrong value it reports is its own FAIL line, and the worktree is still removed" {
  inventory --- tdd
  sha=$(git -C "$code" rev-parse origin/main)
  # fails_with <fixture> <FAIL line>: the planner with <fixture> fails on that line alone
  fails_with() {
    run_bin -1 team-load-check
    assert_contains "$output" "$2"
    assert_equal "$(grep -c '^FAIL' <<<"$output")" 1
    [[ $output != *"PASS planner:"* ]]
    assert_equal "${lines[-1]}" "load check FAILED (inventory in tasks/T0/)"
    left_nothing
    rm -f "$STUB_FIXTURES/$1"
  }
  touch "$STUB_FIXTURES/leak-claude-md"
  fails_with leak-claude-md "FAIL planner: the marker line of its worktree's CLAUDE.md reached it, so its project instructions came from the worktree"
  touch "$STUB_FIXTURES/leak-rules"
  fails_with leak-rules "FAIL planner: the marker file of its worktree's .claude/rules/ reached it"
  touch "$STUB_FIXTURES/run-hook"
  fails_with run-hook "FAIL planner: the SessionStart hook of its worktree's .claude/settings.json ran, so the worktree's project settings configured it"
  echo "Project instructions: code, from the worktree" >"$STUB_FIXTURES/heading"
  fails_with heading "FAIL planner: its project instructions are headed 'Project instructions: code, from the worktree', not 'Project instructions: code, from origin/main at $sha'"
  echo none >"$STUB_FIXTURES/heading"
  fails_with heading "FAIL planner: its project instructions are headed 'none', not 'Project instructions: code, from origin/main at $sha'"
  echo "$HOME/.claude/projects/-wt/memory" >"$STUB_FIXTURES/memory"
  fails_with memory "FAIL planner: its memory directory is '$HOME/.claude/projects/-wt/memory', not $TEAM_HOME/memory/code, the project's folder in the team home"
  echo "$code" >"$STUB_FIXTURES/cwd"
  fails_with cwd "FAIL planner: its working directory is '$code', not the worktree it was started in, $wt"
  touch "$STUB_FIXTURES/no-isolation"
  fails_with no-isolation "FAIL planner: it wrote no .scratch/isolation.txt, so nothing shows that its worktree's markers did not reach it"

  # All at once, each its own line.
  touch "$STUB_FIXTURES/leak-claude-md" "$STUB_FIXTURES/leak-rules" "$STUB_FIXTURES/run-hook"
  echo "$code" >"$STUB_FIXTURES/cwd"
  run_bin -1 team-load-check
  assert_equal "$(grep -c '^FAIL planner: ' <<<"$output")" 4
  left_nothing
}

@test "a code checkout that is no registered project's fails the planner's isolation check, naming why" {
  inventory --- tdd
  { project site; printf '%s\n' '[site.pool]' 'provider = "git"' 'slots = []'; } >"$TEAM_HOME/projects.toml"
  run_bin -1 team-load-check
  assert_contains "$output" "FAIL planner: $code is no registered project's primary checkout, so neither its project instructions nor its memory directory can be shown to be the project's"
  left_nothing
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

@test "a numbered slot in the pool's folder that the registry does not list is rehearsed as a slot (T45)" {
  lease_setup
  local slot=$HOME/.treehouse/proj-abc123/5/proj
  git -C "$primary" worktree add -q --detach "$slot" origin/main
  echo "$slot" >"$BATS_TEST_TMPDIR/free"
  run_bin -0 team-load-check
  assert_contains "$output" "PASS lease proj: slot $slot leased, pre-warmed and clean, returned"
  assert_equal "$(pool_leases)" ""
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

# ops_setup: a linked worktree of proj, registered with a git pool, the stub, and a session that
# passes every check
ops_setup() {
  local clone
  registry "$(printf '%s\n' '[proj.pool]' 'provider = "git"' 'slots = []')"
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
  --settings)
    # claude --settings <file> auto-mode config: the file's autoMode lists, "$defaults" read as one
    # built-in line, or $STUB_FIXTURES/automode.json when the test writes one
    [[ ${3:-} == auto-mode && ${4:-} == config ]] || exit 64
    pwd -P >>"$BATS_TEST_TMPDIR/automode-cwd"
    if [[ -f $STUB_FIXTURES/automode.json ]]; then cat "$STUB_FIXTURES/automode.json"
    else jq '(.autoMode // {}) | map_values(map(if . == "$defaults" then "a built-in line" else . end))' "$2"; fi
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
  local request
  request=$(ops_request "$OPS_COORDINATOR")
  run_bin -0 team-load-check --role ops --worktree "$wt" --request "$request" --toolkit prod-read
  # team-worker launched it on Daniel's message, read back from #coordinator, and recorded it.
  assert_equal "$(stub_calls curl | jq -r '.[-1]')" "https://discord.com/api/v10/channels/$OPS_COORDINATOR/messages/${request##*/}"
  assert_equal "$(cut -d ' ' -f 1,3 "$HOME/.local/state/agent-team/ops-requests")" "${request##*/} 6f93fe38"
  assert_contains "$(last_prompt)" "on Daniel's request $request."
  assert_contains "$output" "load check: Daniel, a 1Password prompt is coming on the PC: approve it"
  assert_contains "$output" "load check: ops's effective autoMode holds the $(team_lines ops | wc -l) lines of its settings' autoMode"
  assert_equal "$(cat "$BATS_TEST_TMPDIR/automode-cwd")" "$(realpath "$wt")"
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

@test "the ops form needs --request, the link to Daniel's message, before the doctor runs; a message used before launches nothing" {
  ops_setup
  cp "$TEAM_DOCTOR" "$BATS_TEST_TMPDIR/doctor.pass"
  printf '%s\n' '#!/usr/bin/env bash' 'touch "$BATS_TEST_TMPDIR/doctor-ran"' 'exit 1' >"$TEAM_DOCTOR"
  run_bin -2 team-load-check --role ops --worktree "$wt" --toolkit prod-read
  assert_equal "$output" "team-load-check: --role ops needs --request <the link to Daniel's Discord message in #coordinator asking for this load check>"
  run_bin -2 team-load-check --role ops --worktree "$wt" --request load-check --toolkit prod-read
  assert_equal "$output" "team-load-check: --request must link Daniel's Discord message, https://discord.com/channels/<guild>/<channel>/<message>, got 'load-check'"
  run_bin -2 team-load-check --request "$(ops_request "$OPS_COORDINATOR")"
  assert_equal "$output" "team-load-check: --request is for --role ops only"
  run_bin -2 team-load-check --context --request "$(ops_request "$OPS_COORDINATOR")"
  assert_equal "$output" "team-load-check: --request is for --role ops only"
  [[ ! -e $BATS_TEST_TMPDIR/doctor-ran ]]
  assert_equal "$(stub_calls claude)" ""
  cp "$BATS_TEST_TMPDIR/doctor.pass" "$TEAM_DOCTOR"
  run_bin -0 team-load-check --help
  assert_contains "$output" "team-load-check --role ops --worktree <path> --request <link> --toolkit <name>..."
  assert_contains "$output" "The ops form needs --request <link>, the link to Daniel's message in #coordinator asking for this"
  assert_contains "$output" "so each load"$'\n'"check of the ops role needs a new message"

  # One message runs one load check: the next needs a new one.
  local request
  request=$(ops_request "$OPS_COORDINATOR")
  run_bin -0 team-load-check --role ops --worktree "$wt" --request "$request" --toolkit prod-read
  : >"$STUB_CALLS/claude.log"
  run_bin -1 team-load-check --role ops --worktree "$wt" --request "$request" --toolkit prod-read
  assert_contains "$output" "team-worker: Discord message ${request##*/} asked for T0's ops launch 6f93fe38 at "
  assert_equal "$(stub_calls claude | jq -c 'select(.[0] == "--bg" or .[0] == "rm")')" ""
}

@test "the ops form in a worktree whose project does not list the toolkit is refused by team-worker, starting no session" {
  ops_setup
  sed -i 's/^toolkits = \["prod-read", "prod-write", "vercel-read"\]$/toolkits = ["prod-read"]/' "$TEAM_HOME/projects.toml"
  run_bin -1 team-load-check --role ops --worktree "$wt" --request "$(ops_request "$OPS_COORDINATOR")" --toolkit prod-read --toolkit prod-write
  assert_contains "$output" "team-worker: toolkit 'prod-write' is not one of proj's toolkits in projects.toml (prod-read): a new toolkit for a project takes Daniel's yes, then its name in that project's toolkits line in projects.toml"
  assert_equal "$(stub_calls claude | jq -c 'select(.[0] == "--bg")')" ""
  assert_equal "$(stub_calls curl)" ""
}

@test "an ops session with a stray tool, a shell or a readable /proc fails, and is still ended" {
  ops_setup
  local s=$STUB_FIXTURES/session
  sed -i 's/^Bash: absent$/Bash: present/; s/^tools: Read,/tools: Read, Bash, WebFetch,/' "$s/tools.txt"
  echo mcp__plugin_prod-read_prod-read__find >>"$s/tools.txt"
  printf '%s\n' 'grep-environ: allowed: 42' 'read-status: allowed' >"$s/probes.txt"
  run_bin -1 team-load-check --role ops --worktree "$wt" --request "$(ops_request "$OPS_COORDINATOR")" --toolkit prod-read
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
  run_bin -1 team-load-check --role ops --worktree "$wt" --request "$(ops_request "$OPS_COORDINATOR")" --toolkit prod-read
  assert_contains "$output" "FAIL: skills beyond the toolkits': simplify prod-write:changing-production-data loop"
  assert_contains "$output" "FAIL: the session cannot invoke querying-production-data"
  assert_equal "${lines[-1]}" "load check FAILED (inventory in tasks/T0/)"

  # The bare names count as well as the namespaced ones; no skills file is no skill.
  rm -f "$STUB_FIXTURES/launched" "$STUB_FIXTURES/removed"
  echo querying-production-data >"$s/skills.txt"
  run_bin -0 team-load-check --role ops --worktree "$wt" --request "$(ops_request "$OPS_COORDINATOR")" --toolkit prod-read
  rm -f "$STUB_FIXTURES/launched" "$STUB_FIXTURES/removed" "$s/skills.txt"
  run_bin -1 team-load-check --role ops --worktree "$wt" --request "$(ops_request "$OPS_COORDINATOR")" --toolkit prod-read
  assert_contains "$output" "FAIL: the session cannot invoke querying-production-data"

  # A write session needs both.
  rm -f "$STUB_FIXTURES/launched" "$STUB_FIXTURES/removed"
  write_session
  echo prod-read:querying-production-data >"$s/skills.txt"
  run_bin -1 team-load-check --role ops --worktree "$wt" --request "$(ops_request "$OPS_COORDINATOR")" --toolkit prod-read --toolkit prod-write
  assert_contains "$output" "FAIL: the session cannot invoke changing-production-data"
  [[ $output != *"skills beyond"* ]]
}

@test "the ops log must gain exactly a requested and a ran line for the one read" {
  ops_setup
  oplog_lines requested
  run_bin -1 team-load-check --role ops --worktree "$wt" --request "$(ops_request "$OPS_COORDINATOR")" --toolkit prod-read
  assert_contains "$output" "FAIL: the ops log did not gain exactly a requested and a ran line for list-collections"

  rm -f "$STUB_FIXTURES/launched" "$STUB_FIXTURES/removed"
  oplog_lines requested ran ran
  run_bin -1 team-load-check --role ops --worktree "$wt" --request "$(ops_request "$OPS_COORDINATOR")" --toolkit prod-read
  assert_contains "$output" "FAIL: the ops log did not gain exactly a requested and a ran line for list-collections"
}

@test "an ops session whose prod-read did not connect fails on that alone, with the notice it saw" {
  ops_setup
  local s=$STUB_FIXTURES/session
  printf '%s\n' 'prod-read: failed' 'notice: prod-read (CONNECTION_CLOSED): "Connection closed"' >"$s/connect.txt"
  rm "$s/tools.txt" "$s/probes.txt" "$s/query.txt"
  echo 'not connected' >"$s/done.txt"
  : >"$STUB_FIXTURES/ops-log"
  run_bin -1 team-load-check --role ops --worktree "$wt" --request "$(ops_request "$OPS_COORDINATOR")" --toolkit prod-read
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
  run_bin -0 team-load-check --role ops --worktree "$wt" --request "$(ops_request "$OPS_COORDINATOR")" --toolkit prod-read --toolkit prod-write
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
  run_bin -1 team-load-check --role ops --worktree "$wt" --request "$(ops_request "$OPS_COORDINATOR")" --toolkit prod-read --toolkit prod-write
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

# The Vercel form: vercel-read alone or beside prod-read, with its one smoke read.

vercel_tools=(domain-deployment get-deployment list-deployments list-env-names runtime-logs)

# vercel_session [prod-read]: a session that passes with vercel-read, alone or beside prod-read
vercel_session() {
  local s=$STUB_FIXTURES/session both=${1:-}
  {
    [[ -z $both ]] || printf '%s\n' 'prod-read: connected' 'notice: connected'
    printf '%s\n' 'vercel-read: connected' 'notice: connected'
  } >"$s/connect.txt"
  {
    echo "tools: Read, Glob, Grep, Edit, Write, ToolSearch, SendMessage, ListAgents, Skill, EndConversation"
    [[ -z $both ]] || printf 'mcp__prod-read__%s\n' "${prod_read_tools[@]}"
    printf 'mcp__vercel-read__%s\n' "${vercel_tools[@]}"
    printf '%s: absent\n' Bash WebFetch WebSearch Agent Artifact
  } >"$s/tools.txt"
  { [[ -z $both ]] || echo prod-read:querying-production-data; echo vercel-read:reading-vercel-deployments; } >"$s/skills.txt"
  printf '%s\n' 'list-deployments: ok' 'count: 1' >"$s/vercel.txt"
  if [[ -n $both ]]; then
    printf '%s\n' 'list-collections: ok' 'count: 2' 'names: markets, stalls' >"$s/query.txt"
    oplog_lines requested ran
  else
    rm -f "$s/query.txt"
    : >"$STUB_FIXTURES/ops-log"
  fi
  vercel_lines requested ran >>"$STUB_FIXTURES/ops-log"
}

# vercel_lines <kind>...: what the session's hook appends, one list-deployments line per kind
vercel_lines() {
  local kind
  for kind in "$@"; do
    echo "- 2026-11-09T12:28:58Z $kind \`vercel-read\` \`list-deployments\` \`{\"project\":\"back-end\",\"limit\":1}\`"
  done
}

# relaunch: the stub plays a fresh session for the next run
relaunch() { rm -f "$STUB_FIXTURES/launched" "$STUB_FIXTURES/removed"; }

# last_prompt: the first prompt of the last session launched
last_prompt() { stub_calls claude | jq -rs '[.[] | select(.[0] == "--bg")][-1][-1]'; }

@test "an ops session that reads only through vercel-read passes, keeps its inventory and is ended with its transcript" {
  ops_setup
  vercel_session
  run_bin -0 team-load-check --role ops --worktree "$wt" --request "$(ops_request "$OPS_COORDINATOR")" --toolkit vercel-read
  assert_contains "$output" "load check: Daniel, a 1Password prompt is coming on the PC: approve it"
  assert_contains "$output" "load check: 5 MCP tools, 10 built-in tools"
  assert_equal "${lines[-1]}" "PASS"
  local inventory=$TEAM_HOME/tasks/T0/inventory-vercel-read.txt
  assert_equal "$(sed '/^---$/q' "$inventory" | grep '^mcp__')" "$(printf 'mcp__vercel-read__%s\n' "${vercel_tools[@]}")"
  assert_contains "$(<"$inventory")" $'---\ntools: Read'
  assert_contains "$(<"$inventory")" $'\nskill: vercel-read:reading-vercel-deployments'
  [[ ! -e $TEAM_HOME/tasks/T0/inventory-prod-read.txt ]]
  assert_equal "$(find "$HOME/.claude/projects" -name "$ops_uuid*")" ""
  assert_equal "$(stub_calls claude | jq -c 'select(.[0] == "rm")')" '["rm","6f93fe38"]'
}

@test "a vercel-read session with a stray or missing tool or skill, no smoke read, a wrong ops log or a Vercel token in its transcript fails" {
  ops_setup
  vercel_session
  local s=$STUB_FIXTURES/session token
  sed -i '/^mcp__vercel-read__runtime-logs$/d' "$s/tools.txt"
  echo mcp__vercel-read__promote-deployment >>"$s/tools.txt"
  echo simplify >"$s/skills.txt"
  echo 'list-deployments: error: Vercel answered 403 forbidden' >"$s/vercel.txt"
  vercel_lines requested >"$STUB_FIXTURES/ops-log"
  # Built here, so the file holds no token-shaped string.
  token=vcp_$(printf 'Ab1_%.0s' {1..5})
  jq -nc --arg text "the token is $token" '{type: "user", message: {content: $text}}' >"$STUB_FIXTURES/transcript.jsonl"
  run_bin -1 team-load-check --role ops --worktree "$wt" --request "$(ops_request "$OPS_COORDINATOR")" --toolkit vercel-read
  assert_contains "$output" "FAIL: the MCP tools are not exactly the toolkits' sets, once each:"$'\n'"  < mcp__vercel-read__runtime-logs"$'\n'"  > mcp__vercel-read__promote-deployment"
  assert_contains "$output" "FAIL: skills beyond the toolkits': simplify"
  assert_contains "$output" "FAIL: the session cannot invoke reading-vercel-deployments"
  assert_contains "$output" "FAIL: list-deployments did not run"
  assert_contains "$output" "FAIL: the ops log did not gain exactly a requested and a ran line for list-deployments"
  assert_contains "$output" "FAIL: the ops log gained 1 event lines, not one per call made"
  assert_contains "$output" "FAIL: a Vercel token in:"$'\n'"  $HOME/.claude/projects/-wt/$ops_uuid.jsonl"
  [[ $output != *"connection string"* && $output != *list-collections* ]]
  assert_equal "${lines[-1]}" "load check FAILED (inventory in tasks/T0/)"
  assert_equal "$(find "$HOME/.claude/projects" -name "$ops_uuid*")" ""

  # Another toolkit's skill is extra too; a vcp_ too short to be a token is no leak.
  relaunch
  vercel_session
  echo prod-read:querying-production-data >>"$s/skills.txt"
  vercel_lines ran >>"$STUB_FIXTURES/ops-log"
  jq -nc '{type: "user", message: {content: "masked as <vercel-token>, the vcp_ prefix, vcp_short"}}' >"$STUB_FIXTURES/transcript.jsonl"
  run_bin -1 team-load-check --role ops --worktree "$wt" --request "$(ops_request "$OPS_COORDINATOR")" --toolkit vercel-read
  assert_contains "$output" "FAIL: skills beyond the toolkits': prod-read:querying-production-data"
  assert_contains "$output" "FAIL: the ops log did not gain exactly a requested and a ran line for list-deployments"
  assert_equal "$(grep -c '^FAIL' <<<"$output")" 3
  [[ $output != *"Vercel token"* && $output != *"cannot invoke"* ]]
}

@test "the leak check scans the team home only where an ops session can write, so another task's fixture token is no leak" {
  ops_setup
  vercel_session
  local token
  # Built here, so the file holds no token-shaped string.
  token=vcp_$(printf 'Fx9_%.0s' {1..5})
  mkdir -p "$TEAM_HOME/tasks/T9/scratch/work" "$TEAM_HOME/memory/proj"
  echo "const token = \"$token\";" >"$TEAM_HOME/tasks/T9/scratch/work/dump-tools.mjs"
  run_bin -0 team-load-check --role ops --worktree "$wt" --request "$(ops_request "$OPS_COORDINATOR")" --toolkit vercel-read
  assert_equal "${lines[-1]}" "PASS"

  # In T0's directory or the memory, it is one.
  relaunch
  echo "$token" >"$TEAM_HOME/tasks/T0/notes.txt"
  echo "$token" >"$TEAM_HOME/memory/proj/vercel.md"
  # And in an MCP log under Claude Code's cache: Library/Caches on macOS, else XDG_CACHE_HOME's
  # when it is set.
  local cache=$HOME/xdg/claude-cli-nodejs
  [[ $(uname -s) != Darwin ]] || cache=$HOME/Library/Caches/claude-cli-nodejs
  local log=$cache/-p/mcp-logs-vercel-read/2026-11-09T10-00-00-000Z.jsonl
  mkdir -p "${log%/*}"
  echo "{\"debug\":\"$token\"}" >"$log"
  XDG_CACHE_HOME=$HOME/xdg run_bin -1 team-load-check --role ops --worktree "$wt" --request "$(ops_request "$OPS_COORDINATOR")" --toolkit vercel-read
  assert_contains "$output" "FAIL: a Vercel token in:"
  assert_contains "$output" "  $TEAM_HOME/tasks/T0/notes.txt"
  assert_contains "$output" "  $TEAM_HOME/memory/proj/vercel.md"
  assert_contains "$output" "  $log"
  [[ $output != *"tasks/T9"* ]]
}

@test "an ops session whose vercel-read did not connect fails on that alone, with the notice it saw, alone or beside prod-read" {
  ops_setup
  vercel_session
  local s=$STUB_FIXTURES/session
  printf '%s\n' 'vercel-read: failed' 'notice: vercel-read (CONNECTION_CLOSED): "Connection closed"' >"$s/connect.txt"
  rm "$s/tools.txt" "$s/probes.txt" "$s/vercel.txt"
  echo 'not connected' >"$s/done.txt"
  : >"$STUB_FIXTURES/ops-log"
  run_bin -1 team-load-check --role ops --worktree "$wt" --request "$(ops_request "$OPS_COORDINATOR")" --toolkit vercel-read
  assert_contains "$output" 'FAIL: a production server did not connect: vercel-read (CONNECTION_CLOSED): "Connection closed"'
  assert_equal "$(grep -c '^FAIL' <<<"$output")" 1
  assert_equal "$(find "$HOME/.claude/projects" -name "$ops_uuid*")" ""

  relaunch
  printf '%s\n' 'prod-read: connected' 'notice: connected' 'vercel-read: still connecting after 30 searches' \
    'notice: vercel-read is still connecting' >"$s/connect.txt"
  run_bin -1 team-load-check --role ops --worktree "$wt" --request "$(ops_request "$OPS_COORDINATOR")" --toolkit prod-read --toolkit vercel-read
  assert_contains "$output" 'FAIL: a production server did not connect: connected vercel-read is still connecting'
  assert_equal "$(grep -c '^FAIL' <<<"$output")" 1
}

@test "an ops session with prod-read and vercel-read passes on both smoke reads, and the ops log must gain both reads' lines and no more" {
  ops_setup
  vercel_session prod-read
  run_bin -0 team-load-check --role ops --worktree "$wt" --request "$(ops_request "$OPS_COORDINATOR")" --toolkit vercel-read --toolkit prod-read
  assert_contains "$output" "load check: Daniel, two 1Password prompts are coming on the PC: approve them"
  [[ $output != *"write prompts"* ]]
  assert_contains "$output" "load check: 16 MCP tools, 10 built-in tools"
  assert_equal "${lines[-1]}" "PASS"
  stub_calls claude | jq -e 'select(.[0] == "--bg")
    | [.[] | select(endswith("/toolkits/prod-read") or endswith("/toolkits/vercel-read"))] | length == 2' >/dev/null
  local inventory=$TEAM_HOME/tasks/T0/inventory-prod-read-vercel-read.txt
  assert_equal "$(sed '/^---$/q' "$inventory" | grep -c '^mcp__prod-read__')" 11
  assert_equal "$(sed '/^---$/q' "$inventory" | grep -c '^mcp__vercel-read__')" 5
  assert_contains "$(<"$inventory")" $'\nskill: prod-read:querying-production-data\nskill: vercel-read:reading-vercel-deployments'
  [[ ! -e $TEAM_HOME/tasks/T0/inventory-prod-read.txt && ! -e $TEAM_HOME/tasks/T0/inventory-vercel-read.txt ]]

  # prod-read's lines alone, then one line too many, then a smoke read not run.
  relaunch
  oplog_lines requested ran
  run_bin -1 team-load-check --role ops --worktree "$wt" --request "$(ops_request "$OPS_COORDINATOR")" --toolkit prod-read --toolkit vercel-read
  assert_contains "$output" "FAIL: the ops log did not gain exactly a requested and a ran line for list-deployments"
  assert_contains "$output" "FAIL: the ops log gained 2 event lines, not one per call made"
  [[ $output != *"line for list-collections"* ]]
  relaunch
  vercel_session prod-read
  vercel_lines ran >>"$STUB_FIXTURES/ops-log"
  run_bin -1 team-load-check --role ops --worktree "$wt" --request "$(ops_request "$OPS_COORDINATOR")" --toolkit prod-read --toolkit vercel-read
  assert_contains "$output" "FAIL: the ops log gained 5 event lines, not one per call made"
  relaunch
  vercel_session prod-read
  rm "$STUB_FIXTURES/session/query.txt"
  run_bin -1 team-load-check --role ops --worktree "$wt" --request "$(ops_request "$OPS_COORDINATOR")" --toolkit prod-read --toolkit vercel-read
  assert_contains "$output" "FAIL: list-collections did not run"
  [[ $output != *"list-deployments did not run"* ]]
}

@test "the session prompt waits for and smoke-reads only the toolkits given" {
  ops_setup
  run_bin -0 team-load-check --role ops --worktree "$wt" --request "$(ops_request "$OPS_COORDINATOR")" --toolkit prod-read
  local prompt
  prompt=$(last_prompt)
  assert_contains "$prompt" "1. Wait for prod-read: "
  assert_contains "$prompt" "4. Call mcp__prod-read__list-collections exactly once"
  assert_contains "$prompt" "5. Write done.txt with the line 'done'."
  [[ $prompt != *vercel* ]]

  relaunch
  vercel_session
  run_bin -0 team-load-check --role ops --worktree "$wt" --request "$(ops_request "$OPS_COORDINATOR")" --toolkit vercel-read
  prompt=$(last_prompt)
  assert_contains "$prompt" "1. Wait for vercel-read: "
  assert_contains "$prompt" "for each of vercel-read, a line '<server>: connected'"
  assert_contains "$prompt" "4. Call mcp__vercel-read__list-deployments exactly once, with project 'back-end' and limit 1"
  assert_contains "$prompt" "Write vercel.txt with a line 'list-deployments: ok' or 'list-deployments: error: <first line of the error>', then a line 'count: <number of deployments>'."
  assert_contains "$prompt" "5. Write done.txt with the line 'done'."
  [[ $prompt != *prod-read* && $prompt != *list-collections* && $prompt != *query.txt* ]]

  relaunch
  vercel_session prod-read
  run_bin -0 team-load-check --role ops --worktree "$wt" --request "$(ops_request "$OPS_COORDINATOR")" --toolkit vercel-read --toolkit prod-read
  prompt=$(last_prompt)
  assert_contains "$prompt" "1. Wait for prod-read and vercel-read: "
  assert_contains "$prompt" "4. Call mcp__prod-read__list-collections exactly once"
  assert_contains "$prompt" "5. Call mcp__vercel-read__list-deployments exactly once"
  assert_contains "$prompt" "6. Write done.txt with the line 'done'."
  [[ $prompt != *prod-write* ]]
}

@test "the ops form takes vercel-read alone or beside prod-read, and refuses any other set, naming the four" {
  local sets="--role ops checks --toolkit prod-read, alone or with --toolkit prod-write; --toolkit vercel-read; or --toolkit prod-read with --toolkit vercel-read"
  run_bin -2 team-load-check --role ops --worktree "$HOME" --toolkit vercel-read --toolkit prod-write
  assert_contains "$output" "$sets"
  run_bin -2 team-load-check --role ops --worktree "$HOME" --toolkit prod-read --toolkit prod-write --toolkit vercel-read
  assert_contains "$output" "$sets"
  run_bin -2 team-load-check --role ops --worktree "$HOME" --toolkit vercel-read --toolkit vercel-read
  assert_contains "$output" "$sets"
  run_bin -2 team-load-check --role ops --worktree "$HOME"
  assert_contains "$output" "$sets"
  assert_equal "$(stub_calls claude)" ""
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

@test "a toolkit team-worker refuses the form's roles is refused with its message while the arguments are read, before the doctor or a lease" {
  lease_setup
  printf '%s\n' '#!/usr/bin/env bash' 'touch "$BATS_TEST_TMPDIR/doctor-ran"' \
    'echo "[{\"check\": \"machine\", \"verdict\": \"FAIL\", \"reason\": \"ran\", \"fix\": \"\"}]"; exit 1' >"$TEAM_DOCTOR"
  stub_script treehouse <<'SH'
touch "$BATS_TEST_TMPDIR/treehouse-ran"
exit 1
SH
  # want <status> <role> <toolkit>: team-worker's refusal of the toolkit for the role, read from
  # team-worker itself, which refuses it before it looks at the worktree.
  want() {
    run_bin "-$1" team-worker T0 "$2" "$HOME" --toolkit "$3" -- go
    want=team-load-check:${output#team-worker:}
  }
  want 2 planner frontend
  run_bin -2 team-load-check --toolkit frontend
  assert_equal "$output" "$want"
  assert_contains "$output" "toolkit 'frontend' is Daniel's own"
  want 2 planner coordinator
  run_bin -2 team-load-check --toolkit browser --toolkit coordinator
  assert_equal "$output" "$want"
  assert_contains "$output" "toolkit 'coordinator' is the coordinator's own"
  want 1 builder prod-read
  run_bin -2 team-load-check --context --toolkit prod-read
  assert_equal "$output" "$want"
  assert_contains "$output" "toolkit 'prod-read' is for the ops role only"
  want 1 reviewer prod-write
  run_bin -2 team-load-check --context --role reviewer --toolkit prod-write
  assert_equal "$output" "$want"
  want 1 planner prod-read
  run_bin -2 team-load-check --toolkit prod-read
  assert_equal "$output" "$want"
  want 1 planner vercel-read
  run_bin -2 team-load-check --toolkit vercel-read
  assert_equal "$output" "$want"
  assert_contains "$output" "toolkit 'vercel-read' is for the ops role only"
  want 1 builder vercel-read
  run_bin -2 team-load-check --context --role builder --toolkit vercel-read
  assert_equal "$output" "$want"
  # The ops form refuses what no worker loads before it judges its toolkit set.
  want 2 ops frontend
  run_bin -2 team-load-check --role ops --worktree "$HOME" --toolkit prod-read --toolkit frontend
  assert_equal "$output" "$want"

  [[ ! -e $BATS_TEST_TMPDIR/doctor-ran && ! -e $BATS_TEST_TMPDIR/treehouse-ran ]]
  assert_equal "$(stub_calls th-lease.sh)" ""
  assert_equal "$(stub_calls claude)" ""
}

# The context form. The claude stub plays one session per role, its id from the role
# (1a1a1a1a planner, 2b2b2b2b builder, 3c3c3c3c reviewer): claude --bg notes in
# $BATS_TEST_TMPDIR/launch-<role> where it started and with what prompt, and writes its transcript
# from tests/fixtures/load-check-context/<role>.jsonl (or '{}' when $STUB_FIXTURES/silent-<role>
# exists), and fails when $STUB_FIXTURES/fail-<role> exists; claude agents lists each until claude rm,
# 'idle', or 'gone' with $STUB_FIXTURES/gone-<role>.

# context_setup: the stub for the context form
context_setup() {
  export CONTEXT_FIXTURES=$BATS_TEST_DIRNAME/fixtures/load-check-context
  stub_script claude <<'SH'
declare -A ids=([planner]=1a1a1a1a [builder]=2b2b2b2b [reviewer]=3c3c3c3c)
uuid() { echo "$1-0000-4000-8000-000000000001"; }
case $1 in
  --bg)
    while [[ $1 != --name ]]; do shift; done
    role=${2#T0-} id=${ids[${2#T0-}]}
    [[ ! -e $STUB_FIXTURES/fail-$role ]] || { echo "launch failed" >&2; exit 1; }
    { pwd -P; echo "${*: -1}"; } >"$BATS_TEST_TMPDIR/launch-$role"
    transcript=$HOME/.claude/projects/-wt/$(uuid "$id").jsonl
    mkdir -p "$(dirname "$transcript")"
    if [[ -e $STUB_FIXTURES/silent-$role ]]; then echo '{}' >"$transcript"; else cp "$CONTEXT_FIXTURES/$role.jsonl" "$transcript"; fi
    touch "$STUB_FIXTURES/launched-$role"
    echo "Started background session $id ($2). Attach with: claude attach $id"
    ;;
  agents)
    for role in planner builder reviewer; do
      id=${ids[$role]}
      [[ -f $STUB_FIXTURES/launched-$role && ! -f $STUB_FIXTURES/removed-$id && ! -f $STUB_FIXTURES/gone-$role ]] || continue
      jq -cn --arg id "$id" --arg name "T0-$role" --arg uuid "$(uuid "$id")" '{id: $id, name: $name, state: "idle", sessionId: $uuid}'
    done | jq -s .
    ;;
  --settings)
    # claude --settings <file> auto-mode config: the file's autoMode lists, "$defaults" read as one
    # built-in line, or $STUB_FIXTURES/automode.json when the test writes one
    [[ ${3:-} == auto-mode && ${4:-} == config ]] || exit 64
    pwd -P >>"$BATS_TEST_TMPDIR/automode-cwd"
    if [[ -f $STUB_FIXTURES/automode.json ]]; then cat "$STUB_FIXTURES/automode.json"
    else jq '(.autoMode // {}) | map_values(map(if . == "$defaults" then "a built-in line" else . end))' "$2"; fi
    ;;
  stop) ;;
  rm) touch "$STUB_FIXTURES/removed-$2" ;;
  *) exit 64 ;;
esac
SH
}

@test "the context form prints each worker role's starting context and counts from its first reply, and removes the sessions" {
  context_setup
  run_bin -0 team-load-check --context
  assert_equal "${lines[0]}" "PASS machine: named"
  assert_contains "$output" "role      context  skills  deferred tools  MCP servers
planner     42006       3               3            0
builder     51004       5               4            2
reviewer    45003       2               2            0"
  assert_equal "${lines[-1]}" PASS
  local role
  for role in planner builder reviewer; do
    assert_equal "$(cat "$BATS_TEST_TMPDIR/launch-$role")" "$(printf '%s\n' "$wt" 'Reply with OK and nothing else.')"
    # Each role's effective autoMode, read under its own settings, holds the team's lines.
    assert_contains "$output" "load check: $role's effective autoMode holds the $(team_lines "$role" | wc -l) lines of its settings' autoMode"
    assert_equal "$(jq -r '.environment[]' "$TEAM_HOME/tasks/T0/automode-$role.json")" "$(echo 'a built-in line'; team_lines "$role")"
  done
  assert_equal "$(cat "$BATS_TEST_TMPDIR/automode-cwd")" "$(printf '%s\n' "$wt" "$wt" "$wt")"
  # Only figures leave the transcripts.
  [[ $output != *"never leaves the transcript"* ]]
  assert_equal "$(stub_calls claude | jq -r 'select(.[0] == "rm") | .[1]')" "$(printf '%s\n' 1a1a1a1a 2b2b2b2b 3c3c3c3c)"
  left_nothing
  # No lease is rehearsed and no inventory kept: the form only measures.
  [[ ! -e $TEAM_HOME/tasks/T0/inventory.txt ]]
}

@test "the context form measures one role with --role, and refuses ops" {
  context_setup
  run_bin -0 team-load-check --context --role reviewer
  assert_contains "$output" "reviewer    45003       2               2            0"
  [[ $output != *planner* ]]
  [[ ! -e $BATS_TEST_TMPDIR/launch-planner ]]

  run_bin -2 team-load-check --context --role ops
  assert_contains "$output" "--context measures the roles the load check may start: planner, builder, reviewer; ops needs Daniel"
  run_bin -2 team-load-check --context --role coordinator
  assert_contains "$output" "unknown role 'coordinator'"
  run_bin -2 team-load-check --context --worktree "$HOME"
  assert_contains "$output" "--worktree is for --role ops only"
  assert_equal "$(stub_calls claude | jq -c 'select(.[0] == "--bg")' | wc -l)" 1
}

@test "in the context form, a role whose given toolkit's MCP server listed no tool before its first reply fails, naming the toolkit and server" {
  context_setup
  toolkit_checkout
  # The builder lists both servers' tools before its first reply; the others never do.
  local fixtures=$BATS_TEST_TMPDIR/context-fixtures
  mkdir -p "$fixtures"
  cp "$CONTEXT_FIXTURES"/*.jsonl "$fixtures/"
  sed -i '3i {"type":"attachment","attachment":{"type":"deferred_tools_delta","addedNames":["mcp__served__look","mcp__plugin_served_spare__look"],"removedNames":[]}}' \
    "$fixtures/builder.jsonl"
  # A tool listed only after the first reply does not count.
  echo '{"type":"attachment","attachment":{"type":"deferred_tools_delta","addedNames":["mcp__served__look","mcp__spare__look"],"removedNames":[]}}' \
    >>"$fixtures/reviewer.jsonl"
  CONTEXT_FIXTURES=$fixtures
  run_bin -1 team-load-check --context --toolkit served
  assert_contains "$output" "builder     51004       5               6            4"
  assert_contains "$output" "FAIL planner: toolkit served brought no tools from its MCP server served"
  assert_contains "$output" "FAIL planner: toolkit served brought no tools from its MCP server spare"
  assert_contains "$output" "FAIL reviewer: toolkit served brought no tools from its MCP server served"
  [[ $output != *"FAIL builder"* ]]
  assert_equal "${lines[-1]}" "load check FAILED"

  # A server the toolkit's mcp-roles.json names for other roles only is expected of those alone;
  # the stub forgets the first run's sessions.
  rm "$STUB_FIXTURES"/launched-* "$STUB_FIXTURES"/removed-*
  echo '{"served": ["builder"]}' >"$CODE_CHECKOUT/toolkits/served/mcp-roles.json"
  run_bin -1 team-load-check --context --toolkit served
  assert_contains "$output" "FAIL planner: toolkit served brought no tools from its MCP server spare"
  [[ $output != *"MCP server served"* ]]
  rm "$CODE_CHECKOUT/toolkits/served/mcp-roles.json"

  # A toolkit that declares no MCP server needs none.
  rm "$STUB_FIXTURES"/launched-* "$STUB_FIXTURES"/removed-*
  run_bin -0 team-load-check --context --role builder --toolkit served --toolkit plain
  [[ $output != *FAIL* ]]
  assert_equal "${lines[-1]}" PASS
}

@test "a role with no first reply fails the context form, and every session is still removed" {
  context_setup
  touch "$STUB_FIXTURES/silent-builder" "$STUB_FIXTURES/gone-builder"
  run_bin -1 team-load-check --context
  assert_contains "$output" "FAIL builder: no first reply in its transcript (state 'gone')"
  assert_contains "$output" "planner     42006"
  assert_equal "${lines[-1]}" "load check FAILED"
  assert_equal "$(stub_calls claude | jq -r 'select(.[0] == "rm") | .[1]')" "$(printf '%s\n' 1a1a1a1a 2b2b2b2b 3c3c3c3c)"
  left_nothing
}

@test "a launch that fails midway in the context form still removes the sessions already started" {
  context_setup
  touch "$STUB_FIXTURES/fail-reviewer"
  run_bin -1 team-load-check --context
  assert_equal "$(stub_calls claude | jq -r 'select(.[0] == "rm") | .[1]')" "$(printf '%s\n' 1a1a1a1a 2b2b2b2b)"
  left_nothing
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
  [[ ! -e $wt ]]
  assert_equal "$(git -C "$code" worktree list --porcelain | grep -c '^worktree ')" 1
  # claude was asked only the doctor's questions, its login, its plugins and its trust probes of
  # the team home and of code, the one project with a checkout here (which the stub's reply never
  # starts): no session of the load check's.
  assert_equal "$(stub_calls claude | jq -r 'join(" ")' | LC_ALL=C sort -u)" "--bg --name team-doctor-home-trust
--bg --name team-doctor-trust-code
agents --json
auth status --json
plugin list --json"
}

@test "the doctor's results print as its lines do, and another project's FAIL is named on stderr as one the planner goes on past" {
  doctor_results WARN 'changes site' FAIL 'trust site'
  inventory --- tdd
  run_bin -0 --separate-stderr team-load-check
  assert_equal "${lines[0]}" "PASS machine: named"
  assert_equal "${lines[1]}" "WARN changes site: broken; fix: repair it"
  assert_equal "${lines[2]}" "FAIL trust site: broken; fix: repair it"
  assert_equal "$stderr" "$(going_on 'trust site')"
  assert_equal "${lines[-1]}" "PASS"
  left_nothing
}

@test "a gate-agent FAIL bears on no session the context form starts, which prints its rows" {
  context_setup
  doctor_results FAIL gate-agent
  run_bin -0 --separate-stderr team-load-check --context
  assert_equal "${lines[1]}" "FAIL gate-agent: broken; fix: repair it"
  assert_contains "$output" "role      context  skills  deferred tools  MCP servers
planner     42006       3               3            0"
  assert_equal "$stderr" "$(going_on gate-agent)"
  assert_equal "${lines[-1]}" PASS
}

@test "a FAIL of the code checkout's own project stops the load check before any worktree, as does every FAIL but another project's and the gate's" {
  # The code checkout's own project is the one at its main checkout, run from a linked worktree.
  git -C "$code" worktree add -q --detach "$HOME/code-wt"
  export TEAM_LOAD_CHECK_CHECKOUT=$HOME/code-wt
  local check
  for check in 'trust code' 'checkout code' 'claude login' 'trust team home' projects 'trust nowhere' 'tool jq'; do
    doctor_results FAIL 'trust site' FAIL "$check"
    run_bin -1 --separate-stderr team-load-check
    assert_equal "${lines[2]}" "FAIL $check: broken; fix: repair it"
    assert_equal "$stderr" "$stopped"
    [[ ! -e $wt ]]
    assert_equal "$(git -C "$code" worktree list --porcelain | grep -c '^worktree ')" 2
    assert_equal "$(stub_calls claude)" ""
  done
}

@test "the planner form stops on a treehouse project's checkout, task dir, slots or leases FAIL, and goes on past its others" {
  lease_setup
  local check
  for check in 'checkout proj' 'task dir proj' 'slots proj' 'leases proj'; do
    doctor_results FAIL "$check"
    run_bin -1 --separate-stderr team-load-check
    assert_equal "$stderr" "$stopped"
    assert_equal "$(stub_calls th-lease.sh)" ""
    assert_equal "$(stub_calls claude)" ""
  done

  doctor_results FAIL 'trust proj' FAIL 'gate proj'
  run_bin -0 --separate-stderr team-load-check
  assert_contains "$output" "PASS lease proj: slot ${slots[0]} leased, pre-warmed and clean, returned"
  assert_equal "$stderr" "$(going_on 'trust proj')
$(going_on 'gate proj')"
  assert_equal "${lines[-1]}" "PASS"

  # The context form rehearses no lease, so a treehouse project's slots bear on none of its sessions.
  context_setup
  doctor_results FAIL 'slots proj'
  run_bin -0 --separate-stderr team-load-check --context --role planner
  assert_equal "$stderr" "$(going_on 'slots proj')"
}

@test "the ops form stops on any FAIL of the project its worktree is in, and goes on past another project's" {
  ops_setup
  doctor_results FAIL 'branches proj'
  run_bin -1 --separate-stderr team-load-check --role ops --worktree "$wt" --request "$(ops_request "$OPS_COORDINATOR")" --toolkit prod-read
  assert_equal "$stderr" "$stopped"
  [[ ! -e $STUB_FIXTURES/launched ]]

  doctor_results FAIL 'branches site'
  run_bin -0 --separate-stderr team-load-check --role ops --worktree "$wt" --request "$(ops_request "$OPS_COORDINATOR")" --toolkit prod-read
  assert_equal "$stderr" "$(going_on 'branches site')"
  assert_equal "${lines[-1]}" "PASS"
}

@test "a doctor whose --json prints no results array stops the load check, launching nothing" {
  local out
  for out in 'PASS machine: named' '' '{"check": "machine"}' '[{"check": "machine", "verdict": "PASS"}]'; do
    printf '%s\n' "$out" >"$BATS_TEST_TMPDIR/doctor.json"
    run_bin -1 --separate-stderr team-load-check
    assert_equal "$stderr" "load check: team-doctor --json printed no results; run team-doctor to see why"
    [[ ! -e $wt ]]
    assert_equal "$(stub_calls claude)" ""
  done
}
