#!/usr/bin/env bats
# hooks/session-digest: the coordinator's SessionStart hook prints the team snapshot with the
# instruction to reconcile it before new work and the live workers whose idle notices to re-arm.

load helpers/common

setup() {
  sandbox
  cat >"$TEAM_HOME/projects.toml" <<'TOML'
[proj]
repo = "owner/proj"
path = "projects/proj"
base = "main"
delivery = "direct-pr"
merge_method = "merge"
required_checks = []
task_dir = ".scratch/task"
docs = []
toolkits = []

[proj.pool]
provider = "git"
slots = ["slots/proj/1"]
TOML
  stub_reply claude '[]'
  stub_reply gh '[]'
}

# start [<source>]: run the hook on a SessionStart event, as Claude Code sends it.
start() {
  run_bin "$1" --separate-stderr hooks/session-digest \
    <<<"$(jq -cn --arg source "${2:-startup}" '{session_id: "3169fcbd-0000-4000-8000-000000000000",
      transcript_path: "/tmp/t.jsonl", cwd: "/home/x/agent-team", hook_event_name: "SessionStart",
      source: $source}')"
}

event() {
  jq -cn --arg t "$1" --arg e "$2" "{ts: \"2026-10-22T02:00:00Z\", task: \$t, event: \$e} + (${3:-{\}})" \
    >>"$TEAM_HOME/ledger.jsonl"
}

# Two open tasks with live builders, one stray.
team_at_work() {
  event T3 launch '{role: "builder", session: "59709d99", worktree: "/w/1", toolkits: []}'
  event T12 launch '{role: "builder", session: "3ed2d1f2", worktree: "/w/2", toolkits: []}'
  event T4 closed '{archive: [], returned: [], kept: []}'
  stub_reply claude '[
    {"id": "59709d99", "sessionId": "59709d99-7687", "name": "T3-builder", "status": "busy", "state": "working"},
    {"id": "3ed2d1f2", "sessionId": "3ed2d1f2-1111", "name": "T12-builder", "status": "idle", "state": "blocked"},
    {"id": "77777777", "sessionId": "77777777-1111", "name": "T4-reviewer", "status": "idle"}]'
}

@test "it prints the snapshot, then the instruction to reconcile, then the workers whose idle notices to re-arm" {
  team_at_work
  start -0
  assert_equal "$stderr" ""
  assert_equal "$output" "Open tasks (2):
  T3 planning | T3-builder busy
  T12 planning | T12-builder idle blocked
Live team sessions (2):
  T3-builder 59709d99 busy
  T12-builder 3ed2d1f2 idle blocked
Stray sessions (1):
  T4-reviewer 77777777 idle: T4 is closed
Open PRs:
  proj (owner/proj): none
Pending asks: none

Reconcile these before taking new work: log what the ledger is missing with team-log, act on what team-sweep finds (stray sessions, and tasks with no live worker that are not held, blocked, awaiting merge, asking, paused or waiting), and chase the pending asks.
Re-arm the idle notice for each live worker (SendMessage to its name with notify_when_idle):
  T3-builder 59709d99
  T12-builder 3ed2d1f2"
  # One snapshot: the session list is read once.
  assert_equal "$(stub_calls claude)" '["agents","--json"]'
}

@test "a resumed or compacted session gets the same digest" {
  team_at_work
  start -0 resume
  assert_contains "$output" "  T12-builder 3ed2d1f2"
  start -0 compact
  assert_contains "$output" "  T12-builder 3ed2d1f2"
}

@test "with no live workers it says there is no idle notice to re-arm, strays aside" {
  event T4 closed '{archive: [], returned: [], kept: []}'
  stub_reply claude '[{"id": "77777777", "sessionId": "77777777-1111", "name": "T4-reviewer", "status": "idle"}]'
  start -0
  assert_equal "$(tail -n 2 <<<"$output")" "Reconcile these before taking new work: log what the ledger is missing with team-log, act on what team-sweep finds (stray sessions, and tasks with no live worker that are not held, blocked, awaiting merge, asking, paused or waiting), and chase the pending asks.
No live workers, so no idle notices to re-arm."
}

@test "when the snapshot fails it prints the error and still exits 0" {
  team_at_work
  stub_reply claude "boom" 1
  start -0
  assert_equal "$stderr" ""
  assert_equal "$output" "team-snapshot failed (exit 1), so there is no digest:
team-snapshot: cannot read the live session list (claude agents --json)
Reconcile by hand before taking new work (team-sweep, team-state T<n>, claude agents), and re-arm the idle notice (SendMessage with notify_when_idle) for each live worker."
}

@test "coordinator.settings.json wires the hook on SessionStart, and no worker settings file mentions it" {
  local settings=$REPO_ROOT/coordinator.settings.json commands command
  commands=$(jq -r '[.hooks.SessionStart[] | select(has("matcher") | not) | .hooks[] | select(.type == "command") | .command] | .[]' "$settings")
  assert_equal "$(wc -l <<<"$commands")" 1
  # claude-coordinator fills in @TEAM_HOME@ with its own checkout.
  command=${commands//@TEAM_HOME@/$REPO_ROOT}
  assert_equal "$command" "\"$REPO_ROOT/bin/hooks/session-digest\""
  # The Stop hook stays beside it.
  assert_contains "$(jq -r '.hooks.Stop[].hooks[].command' "$settings")" "bin/hooks/stop-sweep"
  # Run the command as Claude Code does, through a shell.
  team_at_work
  guard_sandbox
  run -0 sh -c "$command" <<<'{"hook_event_name": "SessionStart", "source": "startup"}'
  assert_contains "$output" "  T12-builder 3ed2d1f2"
  # Workers never get the digest: no worker settings file names the hook, the snapshot or a
  # SessionStart hook.
  run grep -lE 'session-digest|team-snapshot|"SessionStart"' "$REPO_ROOT"/settings/*.json
  assert_equal "$output" ""
}
