#!/usr/bin/env bats
# team-load-check: the planner it launches through team-worker reports its MCP tools and skills,
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
