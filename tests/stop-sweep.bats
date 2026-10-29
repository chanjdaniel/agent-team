#!/usr/bin/env bats
# hooks/stop-sweep: the coordinator's Stop hook keeps a turn open once while team-sweep has
# findings, or while the sweep itself fails, so supervision is never silently off.

load helpers/common

setup() {
  sandbox
  stub_reply claude '[]'
  # A registry, which team-sweep's slots finding reads through team-slots.
  printf '%s\n' '[proj]' 'repo = "owner/proj"' 'path = "projects/proj"' 'base = "main"' 'delivery = "direct-pr"' \
    'merge_method = "merge"' 'required_checks = []' 'task_dir = ".scratch/task"' 'docs = []' 'toolkits = []' \
    '[proj.pool]' 'provider = "git"' 'slots = ["slots/proj/1"]' >"$TEAM_HOME/projects.toml"
}

# stop [<stop_hook_active>]: run the hook on a Stop event, as Claude Code sends it.
stop() {
  local status=$1
  run_bin "$status" --separate-stderr hooks/stop-sweep \
    <<<"$(jq -cn --argjson active "${2:-false}" '{session_id: "3169fcbd-0000-4000-8000-000000000000",
      transcript_path: "/tmp/t.jsonl", cwd: "/home/x/agent-team", permission_mode: "bypassPermissions",
      hook_event_name: "Stop", stop_hook_active: $active}')"
}

# A task opened with no worker: one no-worker finding.
unattended_task() {
  jq -cn '{ts: "2026-10-22T02:00:00Z", task: "T3", event: "opened", project: "proj", path: "feature",
    type: "feat", title: "Work", branch: "feat/T3-work", base: "main", base_sha: "0123456",
    worktree: "/w/1"}' >>"$TEAM_HOME/ledger.jsonl"
}

@test "with no findings it prints nothing and exits 0" {
  stop -0
  assert_equal "$output$stderr" ""
  assert_equal "$(stub_calls claude)" '["agents","--json"]'
}

@test "with findings it blocks the stop once, with the findings as the reason" {
  unattended_task
  jq -cn '{ts: "2026-10-22T02:00:00Z", task: "T4", event: "closed", archive: [], returned: [], kept: []}' \
    >>"$TEAM_HOME/ledger.jsonl"
  stub_reply claude '[{"kind": "background", "id": "77777777", "sessionId": "77777777-1111", "name": "T4-builder", "status": "idle", "state": "blocked"}]'
  stop -0
  assert_equal "$stderr" ""
  assert_equal "$(jq -r .decision <<<"$output")" "block"
  assert_equal "$(jq -r .reason <<<"$output")" "team-sweep found 2 things to reconcile before this turn ends:
T3 no-worker: opened with no worker launched; next: launch one with team-worker, or log what is known with team-log
T4 stray: T4-builder 77777777 is live but T4 is closed; next: read claude logs 77777777 for anything left to log, then stop it with claude stop 77777777
Act on each, then end the turn."
  assert_equal "$(jq -c 'keys' <<<"$output")" '["decision","reason"]'
}

@test "one finding reads as one thing" {
  unattended_task
  stop -0
  assert_contains "$(jq -r .reason <<<"$output")" "team-sweep found 1 thing to reconcile before this turn ends:"
}

@test "a due retro is one of the findings in the reason" {
  local since
  since=$(($(date +%s) - 50 * 3600))
  unattended_task
  jq -cn --arg ts "$(date -u -d "@$since" +%FT%TZ)" '{ts: $ts, task: "T26", event: "retro-schedule",
    every_hours: 48, discord_message: "1563171945980370967"}' >>"$TEAM_HOME/ledger.jsonl"
  stop -0
  assert_equal "$(jq -r .reason <<<"$output")" "team-sweep found 2 things to reconcile before this turn ends:
T3 no-worker: opened with no worker launched; next: launch one with team-worker, or log what is known with team-log
retro due since $(date -u -d "@$((since + 48 * 3600))" +%FT%TZ) (every 48h, last retro none): run the retro skill
Act on each, then end the turn."
}

@test "when the stop hook is already active it exits 0 at once, without sweeping" {
  unattended_task
  stop -0 true
  assert_equal "$output$stderr" ""
  assert_equal "$(stub_calls claude)" ""
}

@test "when the sweep fails it blocks with the error" {
  unattended_task
  stub_reply claude "boom" 1
  stop -0
  assert_equal "$(jq -r .decision <<<"$output")" "block"
  assert_equal "$(jq -r .reason <<<"$output")" "team-sweep failed (exit 1), so supervision is off until it works again:
team-sweep: cannot read the live session list (claude agents --json)
Find out why and fix it, or check the tasks and workers by hand (team-state, claude agents), then end the turn."
}

@test "input that is not a Stop event's JSON still sweeps" {
  unattended_task
  run_bin -0 hooks/stop-sweep <<<"not json"
  assert_equal "$(jq -r .decision <<<"$output")" "block"
  run_bin -0 hooks/stop-sweep </dev/null
  assert_equal "$(jq -r .decision <<<"$output")" "block"
}

@test "coordinator.settings.json wires the hook on Stop, and no worker settings file mentions it" {
  local settings=$REPO_ROOT/coordinator.settings.json commands command
  commands=$(jq -r '[.hooks.Stop[].hooks[] | select(.type == "command") | .command] | .[]' "$settings")
  assert_equal "$(wc -l <<<"$commands")" 1
  # claude-coordinator fills in @TEAM_CODE@ with its own checkout.
  command=${commands//@TEAM_CODE@/$REPO_ROOT}
  assert_equal "$command" "\"$REPO_ROOT/bin/hooks/stop-sweep\""
  # Run the command as Claude Code does, through a shell: an active stop exits 0 at once, an
  # inactive one sweeps the sandbox ledger.
  unattended_task
  guard_sandbox
  run -0 sh -c "$command" <<<'{"hook_event_name": "Stop", "stop_hook_active": true}'
  assert_equal "$output" ""
  run -0 sh -c "$command" <<<'{"hook_event_name": "Stop", "stop_hook_active": false}'
  assert_equal "$(jq -r .decision <<<"$output")" "block"
  # Workers never sweep: no worker settings file names the hook, the sweep or a Stop hook.
  run grep -lE 'stop-sweep|team-sweep|"Stop"' "$REPO_ROOT"/settings/*.json
  assert_equal "$output" ""
}
