#!/usr/bin/env bats
# bin/claude-coordinator: one coordinator at a time, launched as before.
load helpers/common

setup() {
  sandbox
  lock=$HOME/.local/state/agent-team/coordinator-launch.lock
  mkdir -p "$HOME/agent-team"
  # claude answers `agents` from $BATS_TEST_TMPDIR/sessions.json; a launch records its cwd and
  # whether the launch lock was free while it ran, and whether it inherited the lock's file.
  echo '[]' >"$BATS_TEST_TMPDIR/sessions.json"
  stub_script claude <<'EOF'
lock=$HOME/.local/state/agent-team/coordinator-launch.lock
if flock -n "$lock" true; then held=free; else held=held; fi
if [[ $1 == agents ]]; then
  echo "agents $held" >>"$STUB_CALLS/claude.lock"
  cat "$BATS_TEST_TMPDIR/sessions.json"
  exit "$(cat "$BATS_TEST_TMPDIR/agents.status" 2>/dev/null || echo 0)"
fi
echo "launch $held" >>"$STUB_CALLS/claude.lock"
printf '%s\n' "$PWD" >>"$STUB_CALLS/claude.cwd"
for fd in /proc/$$/fd/*; do
  if [[ $(readlink "$fd") == "$lock" ]]; then echo "launch inherited the lock" >>"$STUB_CALLS/claude.lock"; fi
done
echo "Started background session 7c3e9a10 (coordinator). Attach with: claude attach 7c3e9a10"
exit "$(cat "$BATS_TEST_TMPDIR/launch.status" 2>/dev/null || echo 0)"
EOF
}

# session <id|-> <sessionId> <name> <status> [<kind>]: one listed session as JSON.
session() {
  jq -cn --arg id "$1" --arg sid "$2" --arg name "$3" --arg status "$4" --arg kind "${5:-background}" \
    '{pid: 4242, cwd: "/somewhere", kind: $kind, startedAt: 1761100000000, sessionId: $sid,
      name: $name, status: $status} + (if $id == "-" then {} else {id: $id, state: "working"} end)'
}

# sessions <session json>...: the list `claude agents --json` prints.
sessions() {
  printf '%s\n' "$@" | jq -s . >"$BATS_TEST_TMPDIR/sessions.json"
}

# The launch command line: today's, plus this checkout's manual and the coordinator's skills.
launch_argv() {
  jq -cn --arg settings "$HOME/agent-team/coordinator.settings.json" --arg code "$REPO_ROOT" \
    '["--bg", "--name", "coordinator",
    "--channels", "plugin:discord@claude-plugins-official",
    "--dangerously-skip-permissions",
    "--append-system-prompt-file", "\($code)/roles/coordinator.md",
    "--plugin-dir", "\($code)/plugins/coordinator-skills",
    "--settings", $settings,
    "You are the coordinator. Daniel talks to you on Discord. Wait for their messages."]'
}

assert_not_launched() {
  if [[ -e $STUB_CALLS/claude.cwd ]] || grep -q -- '"--bg"' "$STUB_CALLS/claude.log" 2>/dev/null; then
    echo "claude --bg was called: $(stub_calls claude)" >&2
    return 1
  fi
}

@test "--help prints the header" {
  run_bin -0 claude-coordinator --help
  assert_contains "$output" "Start the one session that owns Discord: the team's coordinator."
  assert_contains "$output" "Usage: claude-coordinator [working-directory]"
  assert_equal "$(stub_calls claude)" ""
}

@test "with no coordinator live it launches as before, from ~/agent-team by default" {
  sessions "$(session 0a1b2c3d 0a1b2c3d-1111 T14-builder busy)" "$(session - 9f9f9f9f-2222 '' idle interactive)"
  run_bin -0 claude-coordinator
  assert_contains "$output" "Started background session 7c3e9a10"
  assert_equal "$(stub_calls claude)" "$(printf '%s\n%s' '["agents","--json"]' "$(launch_argv)")"
  assert_equal "$(cat "$STUB_CALLS/claude.cwd")" "$HOME/agent-team"
}

@test "the launch appends the manual and loads the skills plugin, both from its own checkout" {
  run_bin -0 claude-coordinator
  local argv manual plugin
  argv=$(stub_calls claude | tail -n 1)
  manual=$(jq -r 'index("--append-system-prompt-file") as $i | .[$i + 1]' <<<"$argv")
  plugin=$(jq -r 'index("--plugin-dir") as $i | .[$i + 1]' <<<"$argv")
  assert_equal "$manual" "$REPO_ROOT/roles/coordinator.md"
  assert_equal "$plugin" "$REPO_ROOT/plugins/coordinator-skills"
  [[ -f $manual && -f $plugin/.claude-plugin/plugin.json ]]
}

@test "it launches from the working directory it is given" {
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
  run_bin -0 claude-coordinator "$BATS_TEST_TMPDIR/elsewhere"
  assert_equal "$(cat "$STUB_CALLS/claude.cwd")" "$BATS_TEST_TMPDIR/elsewhere"
  assert_equal "$(stub_calls claude | tail -n 1)" "$(launch_argv)"
}

@test "a live coordinator refuses the launch, naming its session id" {
  sessions "$(session 0a1b2c3d 0a1b2c3d-1111 T14-builder busy)" "$(session 5e6f7a8b 5e6f7a8b-3333 coordinator idle)"
  run_bin -1 --separate-stderr claude-coordinator
  assert_equal "$output" ""
  assert_contains "$stderr" "claude-coordinator: a coordinator is already live: session 5e6f7a8b"
  assert_equal "$(stub_calls claude)" '["agents","--json"]'
  assert_not_launched
}

@test "a busy coordinator refuses the launch too" {
  sessions "$(session 5e6f7a8b 5e6f7a8b-3333 coordinator busy)"
  run_bin -1 claude-coordinator
  assert_contains "$output" "session 5e6f7a8b"
  assert_not_launched
}

@test "an interactive coordinator, which has no short id, is named by its session id" {
  sessions "$(session - d4c3b2a1-4444-5555 coordinator idle interactive)"
  run_bin -1 claude-coordinator
  assert_contains "$output" "session d4c3b2a1"
  assert_not_launched
}

@test "only a session named exactly coordinator counts" {
  sessions "$(session 11111111 11111111-a T14-coordinator busy)" "$(session 22222222 22222222-b coordinator-old idle)" \
    "$(session 33333333 33333333-c Coordinator idle)"
  run_bin -0 claude-coordinator
  assert_equal "$(stub_calls claude | tail -n 1)" "$(launch_argv)"
}

@test "an unreadable session list refuses the launch" {
  echo 'not json' >"$BATS_TEST_TMPDIR/sessions.json"
  run_bin -1 claude-coordinator
  assert_contains "$output" "cannot read the live session list"
  assert_not_launched

  echo '[]' >"$BATS_TEST_TMPDIR/sessions.json"
  echo 1 >"$BATS_TEST_TMPDIR/agents.status"
  run_bin -1 claude-coordinator
  assert_contains "$output" "cannot read the live session list"
  assert_not_launched
}

@test "it holds the launch lock across the check and the launch, and the session does not inherit it" {
  run_bin -0 claude-coordinator
  assert_equal "$(cat "$STUB_CALLS/claude.lock")" "$(printf 'agents held\nlaunch held')"
  [[ -f $lock ]]
}

@test "a second launch while the lock is held exits 1 at once, without asking claude anything" {
  mkdir -p "${lock%/*}"
  exec {held}>"$lock"
  flock -n "$held"
  guard_sandbox
  run -1 --separate-stderr timeout 10 "$REPO_ROOT/bin/claude-coordinator"
  exec {held}>&-
  assert_contains "$stderr" "claude-coordinator: another claude-coordinator is launching right now"
  assert_contains "$stderr" "$lock"
  assert_equal "$(stub_calls claude)" ""
}

@test "the lock is released when it exits, so the next launch passes" {
  sessions "$(session 5e6f7a8b 5e6f7a8b-3333 coordinator idle)"
  run_bin -1 claude-coordinator
  echo '[]' >"$BATS_TEST_TMPDIR/sessions.json"
  run_bin -0 claude-coordinator
  run_bin -0 claude-coordinator
  assert_equal "$(grep -c -- '"--bg"' "$STUB_CALLS/claude.log")" 2
}

@test "a failed launch exits with claude's status" {
  echo 3 >"$BATS_TEST_TMPDIR/launch.status"
  run_bin -3 claude-coordinator
}

@test "the comment for T6's lease check comes before the launch" {
  local comment launch
  comment=$(grep -n "T6" "$REPO_ROOT/bin/claude-coordinator" | grep -i lease | tail -n 1 | cut -d: -f1)
  launch=$(grep -n "claude --bg" "$REPO_ROOT/bin/claude-coordinator" | tail -n 1 | cut -d: -f1)
  [[ -n $comment && -n $launch && $comment -lt $launch ]]
}
