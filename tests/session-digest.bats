#!/usr/bin/env bats
# hooks/session-digest: the coordinator's SessionStart hook prints the team snapshot (its current
# items included) with the instruction to reconcile it before new work, then the two standing
# watches to arm in the background: the sweep watch and the offline watch.

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

# The last lines of every digest: arm the sweep watch and the offline watch in the background.
watch_lines() {
  echo "Arm each standing watch with Bash run_in_background unless it is already running (Claude Code lists the background commands that run), and re-arm it in the turn it ends, after acting on what it printed ($REPO_ROOT/roles/coordinator.md, Watching workers and Machines):
  sweep watch, ends once a new finding has stood for three minutes, or one already there for 30: \"$REPO_ROOT/bin/team-sweep\" --wait
  offline watch, ends when the hold starts or ends: \"$REPO_ROOT/bin/team-timers\" watch --once"
}

# The command the digest gives for the watch named <name>.
watch_command() {
  watch_lines | sed -nE "s/^  $1 watch, [^:]*: //p"
}

# No digest asks for idle notices or a Monitor any more: refute_idle_notices <digest>
refute_idle_notices() {
  [[ $1 != *notify_when_idle* && $1 != *"idle notice"* && $1 != *Monitor* ]]
}

# The reconcile line every digest has.
reconcile_line() {
  echo "Reconcile these before taking new work: log what the ledger is missing with team-log, act on what team-sweep finds (stray sessions, and tasks with no live worker that are not held, blocked, awaiting merge, asking, paused or waiting), and chase the pending asks and the current items."
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

@test "it prints the snapshot, then the instruction to reconcile and the two watches to arm, and no idle notices" {
  team_at_work
  start -0
  assert_equal "$stderr" ""
  assert_equal "$output" "Open tasks (2):
  T3 planning | T3-builder busy
  T12 planning | T12-builder idle blocked
Resources: manual, full (90%): no reading of the machine's load yet, so no budget
this machine: 0 of 6 task slots held, none kept, since no registered project's primary checkout is the code checkout ...
Live team sessions (2):
  T3-builder 59709d99 busy
  T12-builder 3ed2d1f2 idle blocked
Stray sessions (1):
  T4-reviewer 77777777 idle: T4 is closed
Open PRs:
  proj (owner/proj): none
Pending asks: none
Current items: none

$(reconcile_line)
$(watch_lines)"
  refute_idle_notices "$output"
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

@test "it shows the current items of tasks/current.md on start, resume and after a compaction" {
  team_at_work
  mkdir -p "$TEAM_HOME/tasks"
  printf '%s\n' "# Current items" "" \
    "- ask - which domain for the docs site, Daniel's move | https://discord.com/channels/1/2/3" \
    "- next T12 once it merges, open the Node pin task | tasks/queued/node-pin.md" >"$TEAM_HOME/tasks/current.md"
  local source
  for source in startup resume compact; do
    start -0 "$source"
    assert_contains "$output" "Pending asks: none
Current items (2):
  - ask - which domain for the docs site, Daniel's move | https://discord.com/channels/1/2/3
  - next T12 once it merges, open the Node pin task | tasks/queued/node-pin.md

Reconcile these before taking new work"
  done
}

@test "with no live workers the closing lines are the same, strays aside" {
  event T4 closed '{archive: [], returned: [], kept: []}'
  stub_reply claude '[{"id": "77777777", "sessionId": "77777777-1111", "name": "T4-reviewer", "status": "idle"}]'
  start -0
  assert_equal "$(tail -n 4 <<<"$output")" "$(reconcile_line)
$(watch_lines)"
}

@test "when the snapshot fails it prints the error, still asks for both watches and exits 0" {
  team_at_work
  stub_reply claude "boom" 1
  start -0
  assert_equal "$stderr" ""
  assert_equal "$output" "team-snapshot failed (exit 1), so there is no digest:
team-snapshot: cannot read the live session list (claude agents --json)
Reconcile by hand before taking new work (team-sweep, team-state T<n>, claude agents, tasks/current.md).
$(watch_lines)"
  refute_idle_notices "$output"
}

@test "while the team holds it says so after the reconcile line, from the offline flag, on success and on failure" {
  team_at_work
  local flag=$HOME/.local/state/agent-team/offline hold
  mkdir -p "${flag%/*}"
  echo '{"since": "2026-10-23T13:05:00Z", "posted": true}' >"$flag"
  hold="GitHub unreachable since 2026-10-23T13:05:00Z; the team is holding: hold each live worker and launch nothing until the offline watch says GitHub answers again (Machines)."
  start -0 compact
  assert_contains "$output" "Current items: none

$(reconcile_line)
$hold
$(watch_lines)"
  # A flag with no readable since dates from its modification time.
  echo '{}' >"$flag"
  touch -d 2026-10-24T08:00:00Z "$flag"
  stub_reply claude "boom" 1
  start -0
  assert_contains "$output" "tasks/current.md).
GitHub unreachable since 2026-10-24T08:00:00Z; the team is holding: hold each live worker and launch nothing until the offline watch says GitHub answers again (Machines).
$(watch_lines)"
  # The hold over, the line goes.
  rm "$flag"
  start -0
  [[ $output != *"the team is holding"* ]]
}

@test "the command it gives for the offline watch runs, and ends on the first change of the hold" {
  local command flag=$HOME/.local/state/agent-team/offline
  command=$(watch_command offline)
  assert_equal "$command" "\"$REPO_ROOT/bin/team-timers\" watch --once"
  mkdir -p "${flag%/*}"
  # The first wait starts the hold. The uname stub keeps the stub sleep ahead of Homebrew's GNU
  # sleep on macOS.
  stub_command sleep uname
  stub_script sleep <<<"echo '{\"since\": \"2026-10-23T13:05:00Z\", \"posted\": true}' >'$flag'"
  stub_reply uname Linux
  guard_sandbox
  run -0 sh -c "$command"
  assert_equal "$output" "GitHub unreachable since 2026-10-23T13:05:00Z; the team is holding"
}

@test "the command it gives for the sweep watch runs, and ends on a finding that stands" {
  local command
  command=$(watch_command sweep)
  assert_equal "$command" "\"$REPO_ROOT/bin/team-sweep\" --wait"
  event T3 opened '{project: "proj", path: "feature", type: "feat", title: "Work", branch: "feat/T3-work",
    base: "main", base_sha: "0123456", worktree: "/w/1"}'
  # T3 has no worker from the second look on; the uname stub keeps the stub sleep ahead of
  # Homebrew's GNU sleep on macOS.
  stub_script claude <<EOF
if [[ -e "$BATS_TEST_TMPDIR/slept" ]]; then echo '[]'; else echo '[{"id": "4f2a9c1e", "sessionId": "4f2a9c1e-1111", "name": "T3-builder", "status": "busy", "state": "working"}]'; fi
EOF
  event T3 launch '{role: "builder", session: "4f2a9c1e", worktree: "/w/1", toolkits: []}'
  stub_command sleep uname
  stub_script sleep <<<"touch '$BATS_TEST_TMPDIR/slept'"
  stub_reply uname Linux
  guard_sandbox
  run -0 sh -c "$command"
  assert_contains "$output" "T3 no-worker: no live session among its 1 launch (latest T3-builder 4f2a9c1e)"
  assert_equal "$(stub_calls sleep | grep -c .)" 7
}

@test "coordinator.settings.json wires the hook on SessionStart, and no worker settings file mentions it" {
  local settings=$REPO_ROOT/coordinator.settings.json commands command
  commands=$(jq -r '[.hooks.SessionStart[] | select(has("matcher") | not) | .hooks[] | select(.type == "command") | .command] | .[]' "$settings")
  assert_equal "$(wc -l <<<"$commands")" 1
  # claude-coordinator fills in @TEAM_CODE@ with its own checkout.
  command=${commands//@TEAM_CODE@/$REPO_ROOT}
  assert_equal "$command" "\"$REPO_ROOT/bin/hooks/session-digest\""
  # The Stop hook stays beside it.
  assert_contains "$(jq -r '.hooks.Stop[].hooks[].command' "$settings")" "bin/hooks/stop-sweep"
  # Run the command as Claude Code does, through a shell.
  team_at_work
  guard_sandbox
  run -0 sh -c "$command" <<<'{"hook_event_name": "SessionStart", "source": "startup"}'
  assert_contains "$output" "  T12-builder 3ed2d1f2"
  # Workers never get the digest: no worker settings file names the hook or the snapshot, and
  # their one SessionStart hook is the gh-axi banner.
  run grep -lE 'session-digest|team-snapshot' "$REPO_ROOT"/settings/*.json
  assert_equal "$output" ""
  assert_equal "$(jq -r '.hooks.SessionStart[]?.hooks[].command' "$REPO_ROOT"/settings/*.json)" \
    '"@TEAM_CODE@/bin/hooks/axi-banner" gh-axi'
}
