#!/usr/bin/env bats
# team-capacity: the team's systemd user slice and the gate's place in it (install), every live
# team session held in a scope under its task's slice (place), and what the doctor's resources
# line reads (check). Every test runs on the sandbox's stubs: systemctl as fake_service_managers
# makes it, busctl as fake_placement makes it, and the processes and cgroups under
# TEAM_CGROUP_ROOT, never the machine's own.

load helpers/common

UNITS=

setup() {
  sandbox
  fake_service_managers
  fake_placement
  stub_command uname no-mistakes
  stub_reply uname Linux
  stub_reply no-mistakes "daemon restarted"
  user_controllers cpu memory pids
  UNITS=$HOME/.config/systemd/user
  mkdir -p "$UNITS"
  stub_script claude <<'EOF'
case $* in
  'agents --json') cat "$STUB_FIXTURES/agents.json" 2>/dev/null || echo '[]' ;;
  *) echo "claude stub: unplanned call: $*" >&2; exit 127 ;;
esac
EOF
}

# The gate's daemon unit, as no-mistakes writes it, <state> active or inactive, in <cgroup>
# (default app.slice's service): gate_daemon <hash> <state> [<cgroup>]
gate_daemon() {
  local unit=no-mistakes-daemon-$1.service state=$HOME/.fake-systemd
  mkdir -p "$state"
  printf '%s\n' '[Unit]' 'Description=no-mistakes background daemon' '[Service]' \
    "ExecStart=$HOME/.no-mistakes/bin/no-mistakes daemon run --root $HOME/.no-mistakes" >"$UNITS/$unit"
  if [[ $2 == active ]]; then
    touch "$state/$unit.active"
    echo active >"$state/$unit.ActiveState"
  else
    rm -f "$state/$unit.active"
    echo inactive >"$state/$unit.ActiveState"
  fi
  echo "${3:-$(user_cgroup "$unit")}" >"$state/$unit.ControlGroup"
}

# The live sessions claude agents --json lists: each argument one "<id> <name> <pid>" (name - for
# an unnamed one).
sessions() {
  local spec id name pid
  for spec; do
    read -r id name pid <<<"$spec"
    jq -cn --arg id "$id" --arg name "$name" --argjson pid "$pid" '{pid: $pid, id: $id, cwd: "/w",
      kind: "background", sessionId: "\($id)-1111-4222-8333-444455556666", status: "idle"}
      + (if $name == "-" then {} else {name: $name} end)'
  done | jq -s . >"$STUB_FIXTURES/agents.json"
}

# A session's process tree as the claude daemon makes it: the daemon (pid 10), the session's pty
# host <pid - 1>, the session <pid> and its children <pid + 1> (a shell) and <pid + 2> (its child),
# all in the Konsole tab's scope the daemon was started from: session_tree <pid>
session_tree() {
  local pid=$1
  [[ -d $TEAM_CGROUP_ROOT/proc/10 ]] || fake_process 10 1 - claude daemon run
  fake_process $((pid - 1)) 10 - claude bg-pty-host --bg-pty-host /tmp/cc-daemon/pty.sock 200 50 -- claude
  fake_process "$pid" $((pid - 1)) - claude bg-spare --bg-spare /tmp/cc-daemon/claim.sock
  fake_process $((pid + 1)) "$pid" - bash -c 'tests/run'
  fake_process $((pid + 2)) $((pid + 1)) - sleep 30
}

# The PIDs each StartTransientUnit call adopted, with its scope and slice, one call per line:
# "<scope> <slice> <pid>..."
placements() {
  stub_calls busctl | jq -r 'select(.[5] == "StartTransientUnit") | . as $c
    | ($c | index("PIDs")) as $p | ($c | index("Slice")) as $s
    | [$c[7], $c[$s + 2]] + $c[$p + 3:$p + 3 + ($c[$p + 2] | tonumber)] | join(" ")'
}

@test "a malformed command line is a usage error" {
  run_bin -2 team-capacity
  assert_contains "$output" "usage: team-capacity install | place [<session id>...] | check [--json]"
  run_bin -2 team-capacity nope
  assert_contains "$output" "unknown subcommand 'nope'"
  run_bin -2 team-capacity install now
  assert_contains "$output" "unexpected argument 'now'"
  run_bin -2 team-capacity check --yaml
  assert_contains "$output" "unexpected argument '--yaml'"
}

@test "install writes the team's slice and a drop-in for each gate daemon, reloads, and restarts an idle running daemon into the slice" {
  gate_daemon 60757c3c active
  gate_daemon 0000aaaa inactive
  # The daemon's restart moves it into the slice, as its drop-in makes systemd start it there.
  stub_script no-mistakes <<'EOF'
[[ $* == "daemon restart" ]] || { echo "no-mistakes stub: unplanned call: $*" >&2; exit 127; }
echo "/user.slice/user-$(id -u).slice/user@$(id -u).service/agent.slice/agent-team.slice/no-mistakes-daemon-60757c3c.service" \
  >"$HOME/.fake-systemd/no-mistakes-daemon-60757c3c.service.ControlGroup"
echo "daemon restarted"
EOF
  run_bin -0 team-capacity install
  assert_equal "$output" "wrote ~/.config/systemd/user/agent-team.slice
wrote ~/.config/systemd/user/no-mistakes-daemon-0000aaaa.service.d/agent-team.conf
wrote ~/.config/systemd/user/no-mistakes-daemon-60757c3c.service.d/agent-team.conf
reloaded the user manager
restarted the gate's daemon no-mistakes-daemon-60757c3c.service into agent-team.slice (no pipeline was running)"
  grep -qx '\[Slice\]' "$UNITS/agent-team.slice"
  grep -qx 'Description=.*' "$UNITS/agent-team.slice"
  run ! grep -qE '^(CPUQuota|MemoryHigh|MemoryMax)=' "$UNITS/agent-team.slice"
  assert_equal "$(cat "$UNITS/no-mistakes-daemon-60757c3c.service.d/agent-team.conf")" "# team-capacity install: every gate run in the team's slice.
[Service]
Slice=agent-team.slice"
  assert_equal "$(stub_calls systemctl | jq -c 'select(.[1] == "daemon-reload")')" '["--user","daemon-reload"]'
  # Only the running daemon restarts: the stopped one starts in the slice when it next starts.
  assert_equal "$(stub_calls no-mistakes)" '["daemon","restart"]'

  # Idempotent: nothing to write, reload or restart.
  : >"$STUB_CALLS/systemctl.log" && : >"$STUB_CALLS/no-mistakes.log"
  run_bin -0 team-capacity install
  assert_equal "$output" "agent-team.slice and the gate's drop-ins are installed, and the gate's daemon runs in the slice: nothing to do"
  assert_equal "$(stub_calls systemctl | jq -c 'select(.[1] != "show")')" ""
  assert_equal "$(stub_calls no-mistakes)" ""
}

@test "install leaves a daemon running a pipeline unrestarted, saying how to restart it later" {
  gate_daemon 60757c3c active
  stub_reply no-mistakes "Error: 1 pipeline run is active; pass --force to restart anyway" 1
  run_bin -0 team-capacity install
  assert_contains "$output" "reloaded the user manager"
  assert_contains "$output" "the gate's daemon no-mistakes-daemon-60757c3c.service runs a pipeline (no-mistakes daemon restart: Error: 1 pipeline run is active; pass --force to restart anyway), so it stays outside agent-team.slice until it restarts: once no gate runs, run team-capacity install again"
  # Never forced.
  assert_equal "$(stub_calls no-mistakes)" '["daemon","restart"]'

  # Next time the drop-in is there, so only the restart is tried again.
  : >"$STUB_CALLS/systemctl.log"
  run_bin -0 team-capacity install
  assert_equal "$(stub_calls systemctl | jq -c 'select(.[1] == "daemon-reload")')" ""
  assert_contains "$output" "so it stays outside agent-team.slice until it restarts"
}

@test "install says when the daemon's restart answered but left it outside the slice" {
  gate_daemon 60757c3c active
  run_bin -0 team-capacity install
  assert_contains "$output" "the gate's daemon no-mistakes-daemon-60757c3c.service still runs outside agent-team.slice after no-mistakes daemon restart ($(user_cgroup no-mistakes-daemon-60757c3c.service)); run team-capacity install again once no gate runs"
}

@test "install with no gate daemon writes the slice alone, and a user manager that does not answer fails it" {
  run_bin -0 team-capacity install
  assert_equal "$output" "wrote ~/.config/systemd/user/agent-team.slice
reloaded the user manager"
  touch "$HOME/.fake-systemd/down"
  rm "$UNITS/agent-team.slice"
  run_bin -1 team-capacity install
  assert_contains "$output" "the user's systemd does not answer (systemctl --user daemon-reload: Failed to connect to user scope bus"
}

@test "place adopts each live team session, its pty host and its descendants into its task's scope, and leaves the coordinator, an unnamed session and a placed one" {
  session_tree 100
  session_tree 200
  session_tree 300
  session_tree 400
  fake_process 399 10 "$(user_cgroup agent-team-T8-4f2a9c1e.scope agent-team-T8.slice)" claude bg-pty-host --bg-pty-host x
  fake_process 400 399 "$(user_cgroup agent-team-T8-4f2a9c1e.scope agent-team-T8.slice)" claude bg-spare
  sessions "a1b2c3d4 T7-builder 100" "c0ffee00 coordinator 200" "deadbeef - 300" "4f2a9c1e T8-reviewer 400"
  run_bin -0 team-capacity place
  assert_equal "$output" "placed T7-builder a1b2c3d4 in agent-team-T7-a1b2c3d4.scope (4 processes)
left T8-reviewer 4f2a9c1e: already in agent-team-T8-4f2a9c1e.scope"
  assert_equal "$(placements)" "agent-team-T7-a1b2c3d4.scope agent-team-T7.slice 100 99 101 102"
  assert_equal "$(cgroup_of 100)" "$(user_cgroup agent-team-T7-a1b2c3d4.scope agent-team-T7.slice)"
  assert_equal "$(cgroup_of 102)" "$(user_cgroup agent-team-T7-a1b2c3d4.scope agent-team-T7.slice)"
  assert_equal "$(cgroup_of 99)" "$(user_cgroup agent-team-T7-a1b2c3d4.scope agent-team-T7.slice)"
  # The daemon and the other sessions stay where they were.
  assert_equal "$(cgroup_of 10)" "$(cgroup_of 200)"
  assert_contains "$(cgroup_of 200)" "konsole"
  assert_contains "$(cgroup_of 300)" "konsole"
  assert_equal "$(stub_calls busctl | jq -c '.[:11]')" \
    '["--user","call","org.freedesktop.systemd1","/org/freedesktop/systemd1","org.freedesktop.systemd1.Manager","StartTransientUnit","ssa(sv)a(sa(sv))","agent-team-T7-a1b2c3d4.scope","fail","3","PIDs"]'

  # Placed now, so a second run moves nothing.
  : >"$STUB_CALLS/busctl.log"
  run_bin -0 team-capacity place
  assert_equal "$output" "left T7-builder a1b2c3d4: already in agent-team-T7-a1b2c3d4.scope
left T8-reviewer 4f2a9c1e: already in agent-team-T8-4f2a9c1e.scope"
  assert_equal "$(stub_calls busctl)" ""
}

@test "place leaves out a parent that is no pty host and a descendant the team's slice already holds" {
  fake_process 50 1 - bash
  fake_process 100 50 - claude --bg
  fake_process 101 100 "$(user_cgroup agent-team-T7-heavy.scope agent-team-T7.slice)" tests/run
  fake_process 102 101 "$(user_cgroup agent-team-T7-heavy.scope agent-team-T7.slice)" bats
  fake_process 103 100 - git status
  sessions "a1b2c3d4 T7-builder 100"
  run_bin -0 team-capacity place
  assert_equal "$output" "placed T7-builder a1b2c3d4 in agent-team-T7-a1b2c3d4.scope (2 processes)"
  assert_equal "$(placements)" "agent-team-T7-a1b2c3d4.scope agent-team-T7.slice 100 103"
  assert_contains "$(cgroup_of 101)" "agent-team-T7-heavy.scope"
}

@test "place tries once more with a fresh tree when a process ends before the call, and says each session it cannot place while it places the others" {
  session_tree 100
  session_tree 200
  session_tree 300
  echo 102 >"$STUB_FIXTURES/busctl-gone"
  echo 200 >"$STUB_FIXTURES/busctl-refuse"
  sessions "a1b2c3d4 T7-builder 100" "b1b2c3d4 T9-planner 200" "c1b2c3d4 T10-reviewer 300" "d1b2c3d4 T11-builder 500"
  run_bin -1 --separate-stderr team-capacity place
  assert_equal "$output" "placed T7-builder a1b2c3d4 in agent-team-T7-a1b2c3d4.scope (3 processes)
placed T10-reviewer c1b2c3d4 in agent-team-T10-c1b2c3d4.scope (4 processes)"
  assert_equal "$stderr" "team-capacity: could not place T9-planner b1b2c3d4 (pid 200) in agent-team-T9.slice: Call failed: Access denied
team-capacity: could not place T11-builder d1b2c3d4: its process 500 is gone"
  assert_equal "$(placements)" "agent-team-T7-a1b2c3d4.scope agent-team-T7.slice 100 99 101 102
agent-team-T7-a1b2c3d4.scope agent-team-T7.slice 100 99 101
agent-team-T9-b1b2c3d4.scope agent-team-T9.slice 200 199 201 202
agent-team-T9-b1b2c3d4.scope agent-team-T9.slice 200 199 201 202
agent-team-T10-c1b2c3d4.scope agent-team-T10.slice 300 299 301 302"
}

@test "place with ids places only those, and refuses an id that is no live team session" {
  session_tree 100
  session_tree 200
  session_tree 300
  sessions "a1b2c3d4 T7-builder 100" "b1b2c3d4 T9-planner 200" "c0ffee00 coordinator 300"
  run_bin -1 --separate-stderr team-capacity place b1b2c3d4 99999999 c0ffee00
  assert_equal "$output" "placed T9-planner b1b2c3d4 in agent-team-T9-b1b2c3d4.scope (4 processes)"
  assert_equal "$stderr" "team-capacity: could not place 99999999: no live session has that id
team-capacity: could not place c0ffee00: it is no team session (named coordinator, not T<n>-<role>)"
  assert_contains "$(cgroup_of 100)" "konsole"
  run_bin -2 team-capacity place 'T7 builder'
  assert_contains "$output" "a session id is 8 hex digits, got 'T7 builder'"
}

@test "place fails, moving nothing, when the session list cannot be read" {
  echo 'echo "not json"' | stub_script claude
  run_bin -1 team-capacity place
  assert_contains "$output" "cannot read the live session list (claude agents --json)"
  assert_equal "$(stub_calls busctl)" ""
}

@test "on macOS install and place are no-ops said once, and check passes with the macOS text" {
  as_macos
  session_tree 100
  sessions "a1b2c3d4 T7-builder 100" "b1b2c3d4 T9-planner 200"
  run_bin -0 --separate-stderr team-capacity install
  assert_equal "$output" ""
  assert_equal "$stderr" "team-capacity: no cgroups on macOS: nothing to install"
  run_bin -0 --separate-stderr team-capacity place
  assert_equal "$output" ""
  assert_equal "$stderr" "team-capacity: no cgroups on macOS: no session is placed"
  run_bin -0 team-capacity check --json
  assert_equal "$(jq -c . <<<"$output")" '{"os":"macos","verdict":"PASS","reason":"no hard limits on macOS: admission and stow only","fix":"","problems":[]}'
  assert_equal "$(stub_calls systemctl)$(stub_calls busctl)$(stub_calls claude)" ""
  [[ ! -e $UNITS/agent-team.slice ]]
}
