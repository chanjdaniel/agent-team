#!/usr/bin/env bats
# team-doctor: one PASS, WARN or FAIL line per thing this machine needs, on the machine
# tests/helpers/doctor.bash builds: every tool a version stub, the OS a stubbed uname.
# This file: the resources line, whether this machine can hold the team's work in its slice, as
# team-capacity check says it.

load helpers/common
load helpers/doctor

setup() {
  sandbox
  doctor_machine
  tools_at arch
  fake_placement
}

UNITS_STATE=

# The gate's daemon unit, as no-mistakes writes it, active in <cgroup>: gate_daemon <hash> <cgroup>
gate_daemon() {
  local unit=no-mistakes-daemon-$1.service
  UNITS_STATE=$HOME/.fake-systemd
  printf '%s\n' '[Unit]' 'Description=no-mistakes background daemon' '[Service]' 'ExecStart=no-mistakes daemon run' \
    >"$HOME/.config/systemd/user/$unit"
  touch "$UNITS_STATE/$unit.active"
  echo active >"$UNITS_STATE/$unit.ActiveState"
  echo "$2" >"$UNITS_STATE/$unit.ControlGroup"
}

# The live sessions the doctor's claude stub lists: each argument "<id> <name> <pid>".
sessions() {
  local spec id name pid
  for spec; do
    read -r id name pid <<<"$spec"
    jq -cn --arg id "$id" --arg name "$name" --argjson pid "$pid" '{pid: $pid, id: $id, name: $name, status: "idle"}'
  done | jq -s . >"$STUB_FIXTURES/agents.json"
}

@test "the resources line passes with the slice installed and every live team session in its task's slice" {
  fake_process 100 99 "$(user_cgroup agent-team-T7-a1b2c3d4.scope agent-team-T7.slice)" claude
  fake_process 200 199 "$(user_cgroup agent-team-T9-b1b2c3d4.scope agent-team-T9.slice)" claude
  fake_process 300 1 - claude
  sessions "a1b2c3d4 T7-builder 100" "b1b2c3d4 T9-planner 200" "c0ffee00 coordinator 300" "d1b2c3d4 T11-builder 500"
  run_bin -0 team-doctor
  assert_equal "$(line_of resources)" "PASS resources: agent-team.slice installed, no limits set yet; 2 live team sessions in it"
  run_bin -0 --separate-stderr team-doctor --json
  assert_equal "$(jq -c '.[] | select(.check == "resources") | [.verdict, .fix]' <<<"$output")" '["PASS",""]'
}

@test "the resources line warns on a slice not installed, a gate daemon without its drop-in or outside the slice, and a team session outside its slice" {
  rm "$HOME/.config/systemd/user/agent-team.slice"
  gate_daemon 60757c3c "$(user_cgroup no-mistakes-daemon-60757c3c.service)"
  fake_process 100 1 - claude
  sessions "a1b2c3d4 T7-builder 100"
  run_bin -0 team-doctor
  assert_equal "$(line_of resources)" "WARN resources: agent-team.slice is not installed; the gate's daemon no-mistakes-daemon-60757c3c.service has no drop-in putting it in agent-team.slice; T7-builder a1b2c3d4 runs outside agent-team-T7.slice; fix: team-capacity install (Daniel's yes); team-capacity place"

  # Installed, with the daemon running a pipeline so its restart waits, and the session placed.
  stub_command no-mistakes
  stub_reply no-mistakes "Error: 1 pipeline run is active" 1
  run_bin -0 team-capacity install
  run_bin -0 team-capacity place
  run_bin -0 team-doctor
  assert_equal "$(line_of resources)" "WARN resources: the gate's daemon no-mistakes-daemon-60757c3c.service still runs outside agent-team.slice, its restart waiting; fix: team-capacity install once no gate runs"

  # Restarted into the slice.
  user_cgroup no-mistakes-daemon-60757c3c.service agent-team.slice >"$UNITS_STATE/no-mistakes-daemon-60757c3c.service.ControlGroup"
  run_bin -0 team-doctor
  assert_equal "$(line_of resources)" "PASS resources: agent-team.slice installed, no limits set yet; 1 live team session in it"
}

@test "the resources line warns when the session list cannot be read" {
  echo "not json" >"$STUB_FIXTURES/agents.json"
  run_bin -0 team-doctor
  assert_equal "$(line_of resources)" "WARN resources: cannot read the live session list (claude agents --json), so no session's placement was checked; fix: run team-doctor again"
}

@test "the resources line fails when the user manager does not answer or does not delegate cpu and memory" {
  user_controllers memory pids
  run_bin -1 team-doctor
  assert_equal "$(line_of resources)" "FAIL resources: the user manager's cgroup does not delegate the cpu and memory controllers (cgroup.controllers: memory pids); fix: Daniel delegates them (Delegate=cpu memory pids in a drop-in for user@.service, which needs sudo), then logs in again"
  rm "$TEAM_CGROUP_ROOT/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.controllers"
  run_bin -1 team-doctor
  assert_contains "$(line_of resources)" "FAIL resources: the user manager's cgroup does not delegate the cpu and memory controllers (cgroup.controllers: none)"

  user_controllers cpu memory pids
  touch "$HOME/.fake-systemd/down"
  run_bin -1 team-doctor
  assert_equal "$(line_of resources)" "FAIL resources: the user's systemd does not answer (systemctl --user: Failed to connect to user scope bus via local transport: No such file or directory); fix: log in so the user's systemd runs, then run team-doctor again"
}

@test "on macOS the resources line passes with admission and stow only" {
  on_macos
  tools_at macos
  run_bin -0 team-doctor
  assert_equal "$(line_of resources)" "PASS resources: no hard limits on macOS: admission and stow only"
}

@test "the resources line warns on the lease holder with no reading of the last 15 minutes, naming the heartbeat's log, or its enable when it is off" {
  rm "$HOME/.local/state/agent-team/capacity/readings.jsonl"
  capacity_reading 20
  run_bin -0 team-doctor
  assert_equal "$(line_of resources)" "WARN resources: no reading of the machine's load in the last 15 minutes, though this machine holds the lease, whose heartbeat takes one every 5; fix: the capacity step's lines in ~/.local/state/agent-team/heartbeat.log say why it takes none"
  "$REPO_ROOT/bin/team-timers" disable >/dev/null
  run_bin -1 team-doctor
  assert_contains "$(line_of resources)" "; fix: team-timers enable"
  # A reading of the last 15 minutes passes.
  capacity_reading 5
  "$REPO_ROOT/bin/team-timers" enable >/dev/null
  run_bin -0 team-doctor
  assert_equal "$(line_of resources)" "PASS resources: agent-team.slice installed, no limits set yet; 0 live team sessions in it"
}
