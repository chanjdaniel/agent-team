#!/usr/bin/env bats
# team-capacity: the team's systemd user slice and the gate's place in it (install), every live
# team session held in a scope under its task's slice (place), and what the doctor's resources
# line reads (check). Every test runs on the sandbox's stubs: systemctl as fake_service_managers
# makes it, busctl as fake_placement makes it, and the processes and cgroups under
# TEAM_CGROUP_ROOT, never the machine's own.

load helpers/common

# The unit directory, and the directory of the readings, the kept state and the cost samples.
UNITS='' STATE_DIR=''

setup() {
  sandbox
  fake_service_managers
  fake_placement
  stub_command uname no-mistakes
  stub_reply uname Linux
  stub_reply no-mistakes "daemon restarted"
  user_controllers cpu memory pids
  UNITS=$HOME/.config/systemd/user
  STATE_DIR=$HOME/.local/state/agent-team/capacity
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
  assert_contains "$output" "usage: team-capacity install | place [--quiet] [<session id>...] | check [--json] [--holding] [--heartbeat enabled|disabled] | sample | status [--json] [--stored] | costs [--json]"
  run_bin -2 team-capacity nope
  assert_contains "$output" "unknown subcommand 'nope'"
  run_bin -2 team-capacity install now
  assert_contains "$output" "unexpected argument 'now'"
  run_bin -2 team-capacity check --yaml
  assert_contains "$output" "unexpected argument '--yaml'"
  run_bin -2 team-capacity admit
  assert_contains "$output" "admit needs --kind <kind>"
  run_bin -2 team-capacity admit --kind builder
  assert_contains "$output" "--kind takes session:<role>, stack:<project>, heavy:<kind> or gate"
  run_bin -2 team-capacity admit --kind session:builder --task 7
  assert_contains "$output" "--task takes a task, T<n>"
  run_bin -2 team-capacity admit --kind stack:shop --seed-bytes 1.5
  assert_contains "$output" "--seed-bytes takes a whole number of bytes"
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

@test "place adopts each live team session, its pty host and its descendants into its task's scope, and leaves the coordinator, an unnamed session, a load check's T0 session and a placed one" {
  session_tree 100
  session_tree 500
  session_tree 200
  session_tree 300
  session_tree 400
  fake_process 399 10 "$(user_cgroup agent-team-T8-4f2a9c1e.scope agent-team-T8.slice)" claude bg-pty-host --bg-pty-host x
  fake_process 400 399 "$(user_cgroup agent-team-T8-4f2a9c1e.scope agent-team-T8.slice)" claude bg-spare
  sessions "a1b2c3d4 T7-builder 100" "c0ffee00 coordinator 200" "deadbeef - 300" "4f2a9c1e T8-reviewer 400" "e0e0e0e0 T0-planner 500"
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
  assert_contains "$(cgroup_of 500)" "konsole"
  assert_equal "$(stub_calls busctl | jq -c '.[:11]')" \
    '["--user","call","org.freedesktop.systemd1","/org/freedesktop/systemd1","org.freedesktop.systemd1.Manager","StartTransientUnit","ssa(sv)a(sa(sv))","agent-team-T7-a1b2c3d4.scope","fail","3","PIDs"]'

  # Placed now, so a second run moves nothing.
  : >"$STUB_CALLS/busctl.log"
  run_bin -0 team-capacity place
  assert_equal "$output" "left T7-builder a1b2c3d4: already in agent-team-T7-a1b2c3d4.scope
left T8-reviewer 4f2a9c1e: already in agent-team-T8-4f2a9c1e.scope"
  assert_equal "$(stub_calls busctl)" ""
  # The heartbeat's --quiet says only what it placed.
  run_bin -0 --separate-stderr team-capacity place --quiet
  assert_equal "$output$stderr" ""
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

@test "place tries once more with a fresh tree when a process ends before the call, says each session it cannot place while it places the others, and skips one whose process is gone" {
  session_tree 100
  session_tree 200
  session_tree 300
  echo 102 >"$STUB_FIXTURES/busctl-gone"
  echo 200 >"$STUB_FIXTURES/busctl-refuse"
  sessions "a1b2c3d4 T7-builder 100" "b1b2c3d4 T9-planner 200" "c1b2c3d4 T10-reviewer 300" "d1b2c3d4 T11-builder 500"
  run_bin -1 --separate-stderr team-capacity place
  assert_equal "$output" "placed T7-builder a1b2c3d4 in agent-team-T7-a1b2c3d4.scope (3 processes)
placed T10-reviewer c1b2c3d4 in agent-team-T10-c1b2c3d4.scope (4 processes)"
  assert_equal "$stderr" "team-capacity: could not place T9-planner b1b2c3d4 (pid 200) in agent-team-T9.slice: Call failed: Access denied"
  assert_equal "$(placements)" "agent-team-T7-a1b2c3d4.scope agent-team-T7.slice 100 99 101 102
agent-team-T7-a1b2c3d4.scope agent-team-T7.slice 100 99 101
agent-team-T9-b1b2c3d4.scope agent-team-T9.slice 200 199 201 202
agent-team-T9-b1b2c3d4.scope agent-team-T9.slice 200 199 201 202
agent-team-T10-c1b2c3d4.scope agent-team-T10.slice 300 299 301 302"
}

@test "place with ids places only those, and refuses an id that is no live team session or whose process is gone" {
  session_tree 100
  session_tree 200
  session_tree 300
  sessions "a1b2c3d4 T7-builder 100" "b1b2c3d4 T9-planner 200" "c0ffee00 coordinator 300" "d1b2c3d4 T11-builder 500"
  run_bin -1 --separate-stderr team-capacity place b1b2c3d4 99999999 c0ffee00 d1b2c3d4
  assert_equal "$output" "placed T9-planner b1b2c3d4 in agent-team-T9-b1b2c3d4.scope (4 processes)"
  assert_equal "$stderr" "team-capacity: could not place 99999999: no live session has that id
team-capacity: could not place c0ffee00: it is no team session (named coordinator, not T<n>-<role>)
team-capacity: could not place T11-builder d1b2c3d4: its process 500 is gone"
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
  assert_equal "$(jq -c . <<<"$output")" '{"os":"macos","verdict":"PASS","reason":"manual, full (90%): no reading of the machine'"'"'s load yet, so no budget; no hard limits on macOS: admission and stow only","fix":"","problems":[]}'
  assert_equal "$(stub_calls systemctl)$(stub_calls busctl)$(stub_calls claude)" ""
  [[ ! -e $UNITS/agent-team.slice ]]
}


# A machine with work for sample to read: the fixture registry, T7 holding Conventioner's slot 1
# and T9 agent-team's worktree 2, and the stub docker, whose team stack conventioner-2 runs for
# T7's worktree.
sample_machine() {
  load_docker
  cp "$BATS_TEST_DIRNAME/fixtures/projects.toml" "$TEAM_HOME/projects.toml"
  T7_WT=$HOME/.treehouse/Conventioner-d4c77a/1/Conventioner
  T9_WT=$HOME/agent-team/.claude/worktrees/2
  opened T7 conventioner "$T7_WT"
  opened T9 agent-team "$T9_WT"
  docker_stub "$T7_WT"
}

# The docker helpers, loaded only by the tests that read stacks.
load_docker() {
  # shellcheck source=tests/helpers/docker.bash
  source "$BATS_TEST_DIRNAME/helpers/docker.bash"
}

# Log the task <task> opened in <project> with its worktree <path>.
opened() {
  jq -cn --arg task "$1" --arg p "$2" --arg wt "$3" --arg b "feat/$1-work" \
    '{ts: "2026-11-01T10:00:00Z", task: $task, event: "opened", project: $p, path: "feature", type: "feat", title: "Work",
      branch: $b, base: "dev", base_sha: "abc1234", worktree: $wt}' >>"$TEAM_HOME/ledger.jsonl"
}

# proc <pid> <parent pid> <resident MiB> <CPU seconds> <directory or -> [<cgroup>]: a process of
# the simulated machine (TEAM_SLOTS_PROCS), its directory unreadable for -.
proc() {
  local dir=$5
  [[ $dir != - ]] || dir=''
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" $(($3 * 1024)) "$4" "$dir" "${6:-}" >>"$TEAM_SLOTS_PROCS"
}

# unit <unit> <property>=<value>...: what the user manager reports of <unit>.
unit() {
  local pair state=$HOME/.fake-systemd
  mkdir -p "$state"
  for pair in "${@:2}"; do echo "${pair#*=}" >"$state/$1.${pair%%=*}"; done
}

# Move every stored reading, the kept state's times and the snapshot <seconds> into the past, so
# the next sample is not within a minute of the last and reads the CPU against the snapshot.
age_by() {
  local file
  for file in "$STATE_DIR/readings.jsonl" "$STATE_DIR/live.json"; do
    [[ -e $file ]] || continue
    jq -c --argjson s "$1" 'walk(if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")
      then fromdateiso8601 - $s | todate else . end)' "$file" >"$file.new"
    mv "$file.new" "$file"
  done
  [[ ! -e $STATE_DIR/procs.tsv ]] || touch -d "@$(($(date +%s) - $1))" "$STATE_DIR/procs.tsv"
}

MIB=1048576
GIB=1073741824

# hold_heavy <holder line>: the heavy-run lock held, as a team-heavy run holds it, with <holder
# line> in it, until the test ends or closes HEAVY_FD.
hold_heavy() {
  mkdir -p "$HOME/.local/state/agent-team"
  echo "$1" >"$HOME/.local/state/agent-team/heavy.lock"
  exec {HEAVY_FD}<"$HOME/.local/state/agent-team/heavy.lock"
  flock -x "$HEAVY_FD"
}

# busy_reading [<jq filter>]: a stored reading, taken now, of a 32 GiB machine whose other programs
# use 8 GiB, with T7's builder using 1 GiB, T7's conventioner-2 stack 2 GiB of its 3 GiB of
# mem_limits and the gate running a pipeline at 1 GiB, the filter applied to it.
busy_reading() {
  mkdir -p "$STATE_DIR"
  jq -cn --argjson gib "$GIB" '
    {at: (now | floor | todate), os: "linux", docker: true,
     memory: {total: (32 * $gib), available: (20 * $gib), team: (4 * $gib), others: (8 * $gib)}, cpu: null,
     systemd: true, sessions: true,
     tasks: [{task: "T7", memory: (3 * $gib), cpu: null, cpu_nsec: null,
              sessions: [{id: "a1b2c3d4", role: "builder", memory: $gib, peak: $gib, cpu_seconds: 10}],
              stacks: [{name: "conventioner-2", memory: (2 * $gib), cpu: 0}]}],
     stacks: [{name: "conventioner-2", class: "team", task: "T7", project: "conventioner", memory: (2 * $gib), cpu: 0,
               limits: (3 * $gib)}],
     heavy: null, gate: {running: true, memory: $gib, cpu_seconds: 5}} | '"${1:-.}" >>"$STATE_DIR/readings.jsonl"
}

# level <level>: a level record of manual mode at <level>, made now.
level() {
  jq -cn --arg level "$1" '{ts: (now | floor | todate), mode: "manual", level: $level, by: "Daniel", machine: "home-pc"}' \
    >>"$TEAM_HOME/level.jsonl"
}

# Move every kept admission <seconds> into the past.
age_admissions() {
  jq -c --argjson s "$1" 'map(.at |= (fromdateiso8601 - $s | todate))' "$STATE_DIR/admitted.json" >"$STATE_DIR/admitted.json.new"
  mv "$STATE_DIR/admitted.json.new" "$STATE_DIR/admitted.json"
}

# The reservations of status --json, one compact [part, kind, task, GiB] per item.
reserved_items() {
  guard_sandbox
  "$REPO_ROOT/bin/team-capacity" status --json |
    jq -c --argjson gib "$GIB" '.reserved.items[] | [.part, .kind, .task, (.bytes / $gib | . * 100 | round / 100)]'
}

# The split of status --json's reservations, each part in GiB, the total first.
reserved_split() {
  guard_sandbox
  "$REPO_ROOT/bin/team-capacity" status --json |
    jq -c --argjson gib "$GIB" '.reserved | del(.items) | map_values(. / $gib | . * 100 | round / 100)'
}

# team_reading <others GiB> [<session>...]: a stored reading, taken now, of a 32 GiB machine whose
# other programs use <others GiB>, with no stack, gate or heavy run, and each <session>, "<task>
# <role> <id> <GiB>", live. At full the team's budget is the 28 GiB the others and reserve_gib
# leave less <others GiB>, below 28.8 GiB.
team_reading() {
  mkdir -p "$STATE_DIR"
  printf '%s\n' "${@:2}" | jq -Rnc --argjson gib "$GIB" --argjson others "$1" '
    [inputs | select(. != "") | split(" ") | {task: .[0], role: .[1], id: .[2], memory: (.[3] | tonumber * $gib | round)}] as $s
    | {at: (now | floor | todate), os: "linux", docker: true,
       memory: {total: (32 * $gib), available: ((32 - $others) * $gib | round), team: ([$s[].memory] | add // 0),
                others: ($others * $gib | round)}, cpu: null,
       systemd: true, sessions: true,
       tasks: [$s | group_by(.task)[] | {task: .[0].task, memory: ([.[].memory] | add), cpu: null, cpu_nsec: null,
                sessions: map({id, role, memory, peak: .memory, cpu_seconds: 1}), stacks: []}],
       stacks: [], heavy: null, gate: {running: false, memory: 0, cpu_seconds: 0}}' >>"$STATE_DIR/readings.jsonl"
}

@test "sample on Linux: each task's use is its slice's, its processes outside the slice and its stacks, each session its scope's" {
  sample_machine
  local t7_scope t9_slice
  t7_scope=$(user_cgroup agent-team-T7-a1b2c3d4.scope agent-team-T7.slice)
  t9_slice=$(user_cgroup agent-team-T9-0dd0ba11.scope agent-team-T9.slice)
  # T7's builder in its scope, with a test run below it; a shell in T7's worktree the slice does
  # not hold, and its child in /tmp.
  proc 100 99 512 60 "$T7_WT" "$t7_scope"
  proc 101 100 256 30 /tmp "$t7_scope"
  proc 102 1 100 5 "$T7_WT/src" "/user.slice/user-1000.slice/session-2.scope"
  proc 103 102 50 1 /tmp "/user.slice/user-1000.slice/session-2.scope"
  # T9's reviewer, not placed, so its tree is what it uses; a heavy run in T9's slice, directory
  # unreadable.
  proc 200 1 300 40 "$T9_WT"
  proc 201 200 20 2 "$T9_WT"
  proc 210 1 64 3 - "$t9_slice"
  # The coordinator in the team home, the team's but no task's; another program.
  proc 300 1 400 9 "$TEAM_HOME"
  proc 400 1 2048 99 /
  # A load check's T0 session, no task's work.
  proc 500 1 300 4 /tmp
  sessions "a1b2c3d4 T7-builder 100" "b1b2c3d4 T9-reviewer 200" "c0ffee00 coordinator 300" "deadbeef T11-builder 999" "e0e0e0e0 T0-planner 500"
  unit agent-team-T7.slice MemoryCurrent=$((1024 * MIB)) CPUUsageNSec=90000000000
  unit agent-team-T7-a1b2c3d4.scope MemoryCurrent=$((800 * MIB)) MemoryPeak=$((900 * MIB)) CPUUsageNSec=85000000000
  unit agent-team-T9.slice MemoryCurrent=$((70 * MIB)) CPUUsageNSec=3000000000
  # The heavy run's team-heavy (pid 210) holds the lock, and its scope reports what it uses.
  hold_heavy "tests/run in ~/t9 (pid 210, T9) since 2026-11-01 10:00:00 +0000"
  unit agent-team-heavy-210.scope MemoryCurrent=$((60 * MIB))
  run_bin -0 --separate-stderr team-capacity sample
  assert_equal "$output$stderr" ""
  local reading
  reading=$(cat "$STATE_DIR/readings.jsonl")
  assert_equal "$(jq -c --argjson mib "$MIB" '.heavy | .memory /= $mib' <<<"$reading")" '{"pid":210,"memory":60}'
  assert_equal "$(jq -c '[.os, .systemd, .sessions, .docker, (.tasks | map(.task))]' <<<"$reading")" \
    '["linux",true,true,true,["T7","T9"]]'
  assert_equal "$(jq -c --argjson mib "$MIB" '.tasks[0] | [.memory - 1024 * $mib - 150 * $mib, .cpu, .cpu_nsec, .stacks]' <<<"$reading")" \
    '[628935884,null,90000000000,[{"name":"conventioner-2","memory":628935884,"cpu":0}]]'
  assert_equal "$(jq -c --argjson mib "$MIB" '.tasks[0].sessions | map(.memory /= $mib | .peak /= $mib)' <<<"$reading")" \
    '[{"id":"a1b2c3d4","role":"builder","memory":800,"peak":900,"cpu_seconds":85}]'
  # T9's slice holds only the heavy run; its reviewer's tree is outside it.
  assert_equal "$(jq -c --argjson mib "$MIB" '.tasks[1] | [.memory / $mib, (.sessions | map(.memory /= $mib | .peak /= $mib)), .stacks]' <<<"$reading")" \
    '[390,[{"id":"b1b2c3d4","role":"reviewer","memory":320,"peak":320,"cpu_seconds":42}],[]]'
  assert_equal "$(jq -c '.stacks' <<<"$reading")" \
    '[{"name":"conventioner-2","class":"team","task":"T7","project":"conventioner","memory":628935884,"cpu":0,"limits":1879048192},{"name":"nmtest-1895520","class":"gate","task":null,"project":null,"memory":315621376,"cpu":0,"limits":536870912}]'
  # The machine's part is team-slots's reading: the team's processes by directory and descent.
  assert_equal "$(jq -c --argjson mib "$MIB" '[.memory.total, .memory.team - 628935884 - 315621376, .cpu]' <<<"$reading" |
    jq -c --argjson mib "$MIB" '.[1] /= $mib')" '[34359738368,1638,null]'
  # One systemctl call for every task's slice, every live team session's scope and the heavy run's.
  assert_equal "$(stub_calls systemctl)" \
    '["--user","show","-p","Id,MemoryCurrent,MemoryPeak,CPUUsageNSec","agent-team-T7.slice","agent-team-T9.slice","agent-team-T7-a1b2c3d4.scope","agent-team-T9-b1b2c3d4.scope","agent-team-heavy-210.scope"]'
}

@test "sample: a task's CPU is its slice's since the newest reading and its processes' outside the slice since the snapshot" {
  sample_machine
  docker_state stats 'map(if .Name == "conventioner-2-mongodb-1" then .CPUPerc = "50.00%" else . end)'
  local scope
  scope=$(user_cgroup agent-team-T7-a1b2c3d4.scope agent-team-T7.slice)
  proc 100 99 512 60 "$T7_WT" "$scope"
  proc 102 1 100 5 "$T7_WT/src"
  proc 200 1 300 40 "$T9_WT"
  sessions "a1b2c3d4 T7-builder 100" "b1b2c3d4 T9-reviewer 200"
  unit agent-team-T7.slice MemoryCurrent=$((1024 * MIB)) CPUUsageNSec=90000000000
  run_bin -0 team-capacity sample
  # With no snapshot, no CPU.
  assert_equal "$(jq -c '[.tasks[].cpu]' "$STATE_DIR/readings.jsonl")" '[null,null]'
  # Five minutes later: T7's slice used 150 s, its shell outside it 25 s, its stack 50.12% of a core;
  # T9, with no slice, its processes' 60 s.
  age_by 300
  : >"$TEAM_SLOTS_PROCS"
  proc 100 99 512 200 "$T7_WT" "$scope"
  proc 102 1 100 30 "$T7_WT/src"
  proc 200 1 300 100 "$T9_WT"
  unit agent-team-T7.slice CPUUsageNSec=240000000000
  run_bin -0 team-capacity sample
  assert_equal "$(tail -n 1 "$STATE_DIR/readings.jsonl" | jq -c '.cpu.seconds as $s | [.cpu.seconds >= 300,
      (.tasks[0].cpu == ((175 / $s + 0.5012) * 100 | round / 100)), (.tasks[1].cpu == ((60 / $s) * 100 | round / 100)),
      .tasks[0].cpu_nsec]')" '[true,true,true,240000000000]'
}

@test "the reading reads a heavy run's holder line by team-heavy's own form" {
  assert_equal "$(sed -n "s/^HEAVY_HOLDER_FORM=//p" "$REPO_ROOT/bin/team-capacity")" "$(sed -n "s/^HOLDER_FORM=//p" "$REPO_ROOT/bin/team-heavy")"
  [[ -n $(sed -n "s/^HOLDER_FORM=//p" "$REPO_ROOT/bin/team-heavy") ]]
}

@test "sample on macOS: each task's use is its processes' by directory and descent, each session its tree's but its heavy run, and systemd is not asked" {
  sample_machine
  as_macos
  proc 100 99 512 60 "$T7_WT" "/agent.slice/agent-team.slice/agent-team-T7.slice/x.scope"
  proc 101 100 256 30 /tmp
  # The builder's heavy run, team-heavy (pid 102) and its command: the task's, never the session's.
  proc 102 100 50 1 "$T7_WT"
  proc 103 102 1000 100 "$T7_WT"
  # The run holds the lock, as team-heavy does.
  hold_heavy "tests/run all in ~/t7 (pid 102, T7) since 2026-11-01 10:00:00 +0000"
  proc 200 1 300 40 "$T9_WT"
  proc 201 200 20 2 /tmp
  sessions "a1b2c3d4 T7-builder 100"
  run_bin -0 --separate-stderr team-capacity sample
  assert_equal "$output$stderr" ""
  assert_equal "$(jq -c --argjson mib "$MIB" '[.os, .systemd, (.tasks | map([.task, ((.memory - ([.stacks[].memory] | add // 0)) / $mib), .cpu_nsec]))]' \
    "$STATE_DIR/readings.jsonl")" '["macos",null,[["T7",1818,null],["T9",320,null]]]'
  assert_equal "$(jq -c --argjson mib "$MIB" '.tasks[0].sessions | map(.memory /= $mib | .peak /= $mib)' "$STATE_DIR/readings.jsonl")" \
    '[{"id":"a1b2c3d4","role":"builder","memory":768,"peak":768,"cpu_seconds":90}]'
  # The heavy run's use is its team-heavy's tree.
  assert_equal "$(jq -c --argjson mib "$MIB" '.heavy | .memory /= $mib' "$STATE_DIR/readings.jsonl")" '{"pid":102,"memory":1050}'
  assert_equal "$(stub_calls systemctl)" ""

  exec {HEAVY_FD}<&-
  # With the lock free, the holder line is the last run's and its pid is no heavy run: pid 102,
  # the builder's child now, stays the builder's.
  age_by 120
  run_bin -0 --separate-stderr team-capacity sample
  assert_equal "$(tail -n 1 "$STATE_DIR/readings.jsonl" | jq -c --argjson mib "$MIB" '.tasks[0].sessions | map(.memory /= $mib | .peak /= $mib | del(.cpu_seconds))')" \
    '[{"id":"a1b2c3d4","role":"builder","memory":1818,"peak":1818}]'
  assert_equal "$(tail -n 1 "$STATE_DIR/readings.jsonl" | jq -c .heavy)" null
}

@test "sample: a user manager or a session list that does not answer is said in the reading, and the processes count by directory" {
  sample_machine
  proc 100 99 512 60 "$T7_WT" "$(user_cgroup agent-team-T7-a1b2c3d4.scope agent-team-T7.slice)"
  touch "$HOME/.fake-systemd/down" 2>/dev/null || { mkdir -p "$HOME/.fake-systemd" && touch "$HOME/.fake-systemd/down"; }
  echo 'echo "the daemon is not running" >&2; exit 1' | stub_script claude
  run_bin -0 team-capacity sample
  assert_equal "$(jq -c --argjson mib "$MIB" '[.systemd, .sessions, (.tasks | map([.task, ((.memory - ([.stacks[].memory] | add // 0)) / $mib), .sessions]))]' \
    "$STATE_DIR/readings.jsonl")" '[false,false,[["T7",512,[]],["T9",0,[]]]]'
}

@test "sample: a session gone, a stack stopped and a gate run ended each add one cost line, and what was not read ends nothing" {
  sample_machine
  docker_state stats 'map(if .Name == "conventioner-2-mongodb-1" then .CPUPerc = "49.88%" else . end)'
  gate_daemon 60757c3c active
  local scope
  scope=$(user_cgroup agent-team-T7-a1b2c3d4.scope agent-team-T7.slice)
  proc 100 99 512 60 "$T7_WT" "$scope"
  proc 500 1 600 100 "$HOME/.no-mistakes/worktrees/af267dfa548d/01RUN"
  sessions "a1b2c3d4 T7-builder 100"
  unit agent-team-T7-a1b2c3d4.scope MemoryCurrent=$((800 * MIB)) MemoryPeak=$((900 * MIB)) CPUUsageNSec=85000000000
  unit no-mistakes-daemon-60757c3c.service MemoryCurrent=$((2048 * MIB)) CPUUsageNSec=10000000000
  run_bin -0 team-capacity sample
  [[ ! -s $STATE_DIR/costs.jsonl ]]
  assert_equal "$(jq -c '[(.sessions | keys), (.stacks | keys), .gate.peak, .limits]' "$STATE_DIR/live.json")" \
    "[[\"a1b2c3d4\"],[\"conventioner-2\"],$((2048 * MIB)),{\"conventioner\":1879048192}]"

  # Five minutes on, the gate's memory higher and its run still going, the session's peak higher.
  age_by 300
  unit no-mistakes-daemon-60757c3c.service MemoryCurrent=$((2500 * MIB)) CPUUsageNSec=70000000000
  unit agent-team-T7-a1b2c3d4.scope MemoryPeak=$((1000 * MIB)) CPUUsageNSec=95000000000
  run_bin -0 team-capacity sample
  [[ ! -s $STATE_DIR/costs.jsonl ]]

  # The session list unreadable and Docker down end nothing; the gate's run is over.
  age_by 300
  : >"$TEAM_SLOTS_PROCS"
  proc 100 99 512 60 "$T7_WT" "$scope"
  echo 'exit 1' | stub_script claude
  docker_down
  unit no-mistakes-daemon-60757c3c.service MemoryCurrent=$((300 * MIB)) CPUUsageNSec=80000000000
  run_bin -0 team-capacity sample
  # seconds runs from the first reading that saw it to the last: 300, and the time sample took.
  assert_equal "$(jq -c '[.kind, .peak_bytes / 1048576, .cpu_seconds, (.seconds | . >= 300 and . <= 330)]' "$STATE_DIR/costs.jsonl")" \
    '["gate",2500,60,true]'
  assert_equal "$(jq -c '[(.sessions | keys), (.stacks | keys), .gate]' "$STATE_DIR/live.json")" '[["a1b2c3d4"],["conventioner-2"],null]'

  # Then, both answering again, the session is gone and the stack stopped.
  age_by 300
  rm "$STUB_FIXTURES/claude.sh" "$DOCKER_STATE/down"
  stub_reply claude '[]'
  docker_state containers 'map(.State.Running = false)'
  run_bin -0 team-capacity sample
  # Each was last seen by the second reading, the stack's CPU its half a core over the 300 s (and
  # the time sample took) between the two.
  assert_equal "$(tail -n 2 "$STATE_DIR/costs.jsonl" | jq -c '[.kind, .peak_bytes, (.cpu_seconds | if . < 100 then . else . >= 150 and . <= 165 end),
      (.seconds | . >= 300 and . <= 330)]')" \
    "$(printf '%s\n' "[\"session:builder\",$((1000 * MIB)),95,true]" '["stack:conventioner",628935884,true,true]')"
  assert_equal "$(jq -c '[.sessions, .stacks, .gate, .limits]' "$STATE_DIR/live.json")" '[{},{},null,{"conventioner":1879048192}]'
  [[ $(tail -n 1 "$STATE_DIR/costs.jsonl" | jq -r .at) == $(tail -n 1 "$STATE_DIR/readings.jsonl" | jq -r .at) ]]
}

@test "sample with no seam takes a real reading of this machine, a process in a held worktree counted to its task" {
  sample_machine
  unset TEAM_MEMINFO TEAM_SLOTS_PROCS TEAM_SLOTS_CPUS
  # The stubbed uname says this machine's own OS, read past the stubs.
  if [[ $(command -p uname -s) == Darwin ]]; then as_macos; fi
  mkdir -p "$T7_WT"
  local sleeper rss
  (cd "$T7_WT" && exec sleep 60) &
  sleeper=$!
  rss=$(ps -o rss= -p "$sleeper" | tr -d ' ')
  run_bin -0 --separate-stderr team-capacity sample
  kill "$sleeper"
  assert_equal "$output$stderr" ""
  # The machine's own team slices (the suite's heavy run, in its task's) are tasks of the reading
  # too, so only the sandbox's are read.
  assert_equal "$(jq -c --argjson rss "$rss" '(.tasks | map(select(.task | IN("T7", "T9"))) | INDEX(.task)) as $tasks
      | [.memory.total > 0, ($tasks | keys),
         ($tasks.T7.memory - ([$tasks.T7.stacks[].memory] | add // 0) >= $rss * 1024), $tasks.T7.cpu]' "$STATE_DIR/readings.jsonl")" \
    '[true,["T7","T9"],true,null]'
}

# cost <kind> <peak MiB>...: one cost line of <kind> per peak.
cost() {
  local peak
  mkdir -p "$STATE_DIR"
  for peak in "${@:2}"; do
    jq -cn --arg kind "$1" --argjson peak "$((peak * MIB))" \
      '{at: "2026-11-01T10:00:00Z", kind: $kind, peak_bytes: $peak, cpu_seconds: 1, seconds: 60}' >>"$STATE_DIR/costs.jsonl"
  done
}

@test "costs: the seed until 5 samples, then the 90th percentile of the last 20 peaks plus 10%" {
  cp "$BATS_TEST_DIRNAME/fixtures/projects.toml" "$TEAM_HOME/projects.toml"
  cost session:builder 400 500 600 700
  cost session:reviewer 100 200 300 400 500
  # 25 samples: five large ones, then 1 to 20 hundred MiB, of which the last 20 count.
  cost heavy:tests-run 9000 9000 9000 9000 9000 100 200 300 400 500 600 700 800 900 1000 1100 1200 1300 1400 1500 1600 1700 1800 1900 2000
  echo '{"at": "broken' >>"$STATE_DIR/costs.jsonl"
  run_bin -0 team-capacity costs --json
  assert_equal "$(jq -c '.schema' <<<"$output")" '"team-capacity-costs/1"'
  assert_equal "$(jq -c '.costs | map([.kind, .source, .samples])' <<<"$output")" \
    '[["session:builder","seed",4],["session:ops","seed",0],["session:planner","seed",0],["session:reviewer","learned",5],["stack:conventioner","none",0],["gate","seed",0],["heavy:tests-run","learned",25]]'
  assert_equal "$(jq -c --argjson mib "$MIB" '.costs | map(select(.kind | IN("session:builder", "session:reviewer", "heavy:tests-run", "gate"))
      | [.estimate_bytes, .range])' <<<"$output")" \
    "$(jq -cn --argjson mib "$MIB" '[[536870912, {min: (400 * $mib), max: (700 * $mib)}], [(500 * $mib * 1.1 | round), {min: (100 * $mib), max: (500 * $mib)}],
      [2362232013, null], [(1800 * $mib * 1.1 | round), {min: (100 * $mib), max: (2000 * $mib)}]]')"
  run_bin -0 team-capacity costs
  assert_equal "$(sed -n 1p <<<"$output")" "session:builder: 0.5 GiB, the seed: session_gib 0.5 GiB, its default (4 samples of 5)"
  assert_equal "$(sed -n 4p <<<"$output")" "session:reviewer: 0.5 GiB, learned from 5 samples, 0.1 GiB to 0.5 GiB"
  assert_equal "$(sed -n 5p <<<"$output")" "stack:conventioner: no estimate, no seed: no stack of it seen running yet"
  assert_equal "$(sed -n 6p <<<"$output")" "gate: 2.2 GiB, the seed: gate_gib 2.2 GiB, its default"
  assert_equal "$(sed -n 7p <<<"$output")" "heavy:tests-run: 1.9 GiB, learned from the last 20 of 25 samples, 0.1 GiB to 2.0 GiB"
}

@test "costs: a stack's seed is its mem_limits as the readings last saw it running, and capacity.json's seeds are read" {
  sample_machine
  mkdir -p "$HOME/.config/agent-team"
  echo '{"gate_gib": 3, "session_gib": 0.75}' >"$HOME/.config/agent-team/capacity.json"
  run_bin -0 team-capacity sample
  run_bin -0 team-capacity costs
  assert_equal "$(grep -E '^(session:builder|stack:conventioner|gate):' <<<"$output")" "$(printf '%s\n' \
    "session:builder: 0.8 GiB, the seed: session_gib 0.75 GiB in capacity.json" \
    "stack:conventioner: 1.8 GiB, the seed: its services' mem_limits, 1.8 GiB as last seen running" \
    "gate: 3.0 GiB, the seed: gate_gib 3 GiB in capacity.json")"
}

@test "a malformed capacity.json is refused by sample, status and costs, naming each problem" {
  mkdir -p "$HOME/.config/agent-team"
  local file=$HOME/.config/agent-team/capacity.json sub
  echo '{"full_share": 1.5, "session_gib": 0, "slots": 3}' >"$file"
  for sub in sample status costs; do
    run_bin -1 --separate-stderr team-capacity "$sub"
    assert_equal "$stderr" "team-capacity: $file: full_share must be a number above 0 and at most 1, not 1.5; session_gib must be a number above 0, not 0; slots is not a setting (they are: full_share, minor_share, reserve_gib, reserve_cores, auto_full_free, auto_none_below, rise_minutes, session_gib, heavy_gib, gate_gib, min_cores, min_gib)"
  done
  echo '[1]' >"$file"
  run_bin -1 --separate-stderr team-capacity status
  assert_equal "$stderr" "team-capacity: $file is not one JSON object"
  echo '{"full_share":' >"$file"
  run_bin -1 --separate-stderr team-capacity costs
  assert_contains "$stderr" "team-capacity: $file is not JSON: "
  [[ ! -e $HOME/.local/state/agent-team/capacity/readings.jsonl ]]
}

@test "status: the newest reading's use by the others, the team and each task, taking a reading first only when the newest is over 10 minutes old" {
  sample_machine
  mkdir -p "$HOME/.config/agent-team"
  echo home-pc >"$HOME/.config/agent-team/machine"
  proc 100 99 512 60 "$T7_WT"
  proc 500 1 600 100 "$HOME/.no-mistakes/worktrees/af267dfa548d/01RUN"
  sessions "a1b2c3d4 T7-builder 100"
  run_bin -0 --separate-stderr team-capacity status
  assert_equal "$stderr" ""
  assert_equal "$(wc -l <"$STATE_DIR/readings.jsonl")" 1
  local at
  at=$(jq -r '.at | fromdateiso8601 | strflocaltime("%H:%M")' "$STATE_DIR/readings.jsonl")
  assert_equal "$output" "$(printf '%s\n' "home-pc at $at: other programs use 6.0 GiB of 32.0 GiB; the team 2.0 GiB" \
    "  T7: 1.1 GiB; builder a1b2c3d4 0.5 GiB, stack conventioner-2 0.6 GiB" "  T9: 0.0 GiB" \
    "  gate: running a pipeline, 0.6 GiB")"
  run_bin -0 team-capacity status --json
  assert_equal "$(jq -c '[.schema, .machine, .stale, .settings.full_share, .settings.from.full_share, (.reading.tasks | length)]' <<<"$output")" \
    '["team-capacity/1","home-pc",false,0.9,"default",2]'
  # Nine minutes old, it reads the stored one; eleven, it takes a new one.
  age_by 540
  run_bin -0 team-capacity status
  assert_equal "$(wc -l <"$STATE_DIR/readings.jsonl")" 1
  age_by 120
  run_bin -0 team-capacity status --stored --json
  assert_equal "$(wc -l <"$STATE_DIR/readings.jsonl")" 1
  run_bin -0 team-capacity status --json
  assert_equal "$(wc -l <"$STATE_DIR/readings.jsonl")" 2
}

@test "status with no reading it can take says so on stderr and goes on with the stored ones" {
  cp "$BATS_TEST_DIRNAME/fixtures/projects.toml" "$TEAM_HOME/projects.toml"
  printf 'MemTotal:       33554432 kB\n' >"$TEAM_MEMINFO"
  run_bin -0 --separate-stderr team-capacity status
  assert_equal "$stderr" "team-capacity: took no reading of the machine's load: no MemTotal and MemAvailable in $TEAM_MEMINFO"
  assert_equal "$output" "this machine: no reading of the machine's load yet"
  run_bin -0 team-capacity status --stored --json
  assert_equal "$(jq -c '[.stale, .reading]' <<<"$output")" '[true,null]'
}

@test "check --holding warns when the newest reading is over 15 minutes old, naming the heartbeat's log or its enable" {
  cp "$BATS_TEST_DIRNAME/fixtures/projects.toml" "$TEAM_HOME/projects.toml"
  run_bin -0 team-capacity install
  level_applied manual full 1080
  run_bin -0 team-capacity check
  run_bin -1 team-capacity check --holding
  assert_equal "$output" "WARN manual, full (90%): no reading of the machine's load yet, so no budget; no reading of the machine's load in the last 15 minutes, though this machine holds the lease, whose heartbeat takes one every 5; fix: the capacity step's lines in ~/.local/state/agent-team/heartbeat.log say why it takes none"
  run_bin -1 team-capacity check --holding --heartbeat disabled
  assert_contains "$output" "; fix: team-timers enable"
  run_bin -0 team-capacity sample
  run_bin -0 team-capacity check --holding
  age_by 960
  run_bin -0 team-capacity check --json --holding
  assert_equal "$(jq -r .verdict <<<"$output")" WARN
  run_bin -2 team-capacity check --heartbeat sometimes
}

@test "admit admits what fits the level's budget beside what is reserved, refuses a byte more with the numbers, and reserves each admission for 10 minutes" {
  cp "$BATS_TEST_DIRNAME/fixtures/projects.toml" "$TEAM_HOME/projects.toml"
  # Minor: 30% of 32 GiB, 9.6 GiB. The builder reserves its 1 GiB of use, above its 0.5 GiB seed;
  # the stack its 3 GiB of mem_limits, above its 2 GiB of use; the gate its 2.2 GiB seed.
  busy_reading
  level minor
  assert_equal "$(reserved_items)" '["sessions_use","session:builder","T7",1]
["spike_allowance","session:builder","T7",0]
["stacks","stack:conventioner","T7",3]
["gates","gate",null,2.2]'
  run_bin -0 team-capacity status --json
  assert_equal "$(jq -c '.room | del(.bytes)' <<<"$output")" '{"mode":"manual","level":"minor","share":0.3,"budget_bytes":10307921510}'
  local room
  room=$(jq .room.bytes <<<"$output")
  assert_equal "$room" $((10307921510 - GIB - 3 * GIB - 2362232013))
  assert_equal "$(jq .reserved.bytes <<<"$output")" $((GIB + 3 * GIB + 2362232013))

  run_bin -75 --separate-stderr team-capacity admit --kind stack:other --task T9 --seed-bytes $((room + 1))
  assert_equal "$output" ""
  assert_equal "$stderr" "no room for stack:other at minor (30%): 6.2 GiB of 9.6 GiB reserved, a stack of other needs 3.4 GiB"
  [[ ! -e $STATE_DIR/admitted.json ]]
  run_bin -0 --separate-stderr team-capacity admit --kind stack:other --task T9 --seed-bytes "$room"
  assert_equal "$output" "admitted stack:other at minor (30%): a stack of other needs 3.4 GiB, 6.2 GiB of 9.6 GiB reserved before it"
  assert_equal "$(jq -c 'map(del(.at))' "$STATE_DIR/admitted.json")" "[{\"kind\":\"stack:other\",\"task\":\"T9\",\"bytes\":$room,\"pid\":null}]"
  # The admission is reserved at its estimate, with no use yet, so nothing more fits.
  run_bin -0 team-capacity status --json
  assert_equal "$(jq -c '.reserved.items[-1] | [.kind, .task, .name, (.admitted | test("Z$")), .estimate_bytes, .use_bytes, .bytes]' <<<"$output")" \
    "[\"stack:other\",\"T9\",null,true,$room,null,$room]"
  assert_equal "$(jq .room.bytes <<<"$output")" 0
  run_bin -75 --separate-stderr team-capacity admit --kind session:reviewer --task T9
  assert_equal "$stderr" "no room for session:reviewer at minor (30%): 9.6 GiB of 9.6 GiB reserved, a reviewer needs 0.5 GiB"
  # Ten minutes on, the readings hold what it started, and the next admission drops it.
  age_admissions 601
  run_bin -0 team-capacity admit --kind session:reviewer --task T9
  assert_equal "$(jq -c 'map([.kind, .task, .bytes])' "$STATE_DIR/admitted.json")" '[["session:reviewer","T9",536870912]]'
  # A heavy run's kind costs has no sample of yet is at heavy_gib.
  run_bin -75 --separate-stderr team-capacity admit --kind heavy:tests-run
  assert_equal "$stderr" "no room for heavy:tests-run at minor (30%): 6.7 GiB of 9.6 GiB reserved, a heavy run of tests-run needs 5.0 GiB"
}

@test "status: a session past its admission window reserves its use, the team one spike allowance for the largest gap, and one in its window the larger of its estimate and its use" {
  cp "$BATS_TEST_DIRNAME/fixtures/projects.toml" "$TEAM_HOME/projects.toml"
  mkdir -p "$HOME/.config/agent-team"
  echo '{"session_gib": 2}' >"$HOME/.config/agent-team/capacity.json"
  # With no session past its window there is no allowance.
  team_reading 8
  assert_equal "$(reserved_split)" '{"bytes":0,"sessions_use":0,"spike_allowance":0,"admissions":0,"stacks":0,"heavy_runs":0,"gates":0}'
  # Three sessions never admitted (or long ago): each reserves its use, and the team one allowance,
  # the largest of their estimates less their use, the reviewer's 2 - 0.5.
  team_reading 8 "T7 builder a1 1" "T7 reviewer b2 0.5" "T9 builder c3 1.5"
  assert_equal "$(reserved_items)" '["sessions_use","session:builder","T7",1]
["sessions_use","session:reviewer","T7",0.5]
["sessions_use","session:builder","T9",1.5]
["spike_allowance","session:reviewer","T7",1.5]'
  assert_equal "$(reserved_split)" '{"bytes":4.5,"sessions_use":3,"spike_allowance":1.5,"admissions":0,"stacks":0,"heavy_runs":0,"gates":0}'
  run_bin -0 team-capacity status --json
  assert_equal "$(jq -c --argjson gib "$GIB" '.reserved.items[-1] | [.name, .estimate_bytes / $gib, .use_bytes / $gib]' <<<"$output")" '["b2",2,0.5]'

  # T9's builder admitted again: the session of its kind and task the reading holds is in its
  # window, reserved once at the larger of the admission's estimate and its use, never with its
  # use too; T11's planner, not up yet, at its estimate.
  run_bin -0 team-capacity admit --kind session:builder --task T9
  run_bin -0 team-capacity admit --kind session:planner --task T11
  assert_equal "$output" "admitted session:planner at full (90%): a planner needs 2.0 GiB, 5.0 GiB of 20.0 GiB reserved before it"
  assert_equal "$(reserved_items)" '["sessions_use","session:builder","T7",1]
["sessions_use","session:reviewer","T7",0.5]
["admissions","session:builder","T9",2]
["spike_allowance","session:reviewer","T7",1.5]
["admissions","session:planner","T11",2]'
  assert_equal "$(reserved_split)" '{"bytes":7,"sessions_use":1.5,"spike_allowance":1.5,"admissions":4,"stacks":0,"heavy_runs":0,"gates":0}'
  run_bin -0 team-capacity status --json
  assert_equal "$(jq -c --argjson gib "$GIB" '.reserved.items[2] | [.name, (.admitted | test("Z$")), .estimate_bytes / $gib, .use_bytes / $gib]' <<<"$output")" '["c3",true,2,1.5]'
  assert_equal "$(jq -c '.reserved.items[-1] | [.name, .use_bytes]' <<<"$output")" '[null,null]'

  # One in its window using more than its estimate reserves its use; of two sessions of the
  # admitted kind and task, the one using less, the newer, is in the window.
  team_reading 8 "T7 builder a1 1" "T7 reviewer b2 0.5" "T9 builder c3 3" "T11 planner d4 0.25" "T11 planner e5 1.25"
  assert_equal "$(reserved_items)" '["admissions","session:planner","T11",2]
["sessions_use","session:planner","T11",1.25]
["sessions_use","session:builder","T7",1]
["sessions_use","session:reviewer","T7",0.5]
["admissions","session:builder","T9",3]
["spike_allowance","session:reviewer","T7",1.5]'
  run_bin -0 team-capacity status --json
  assert_equal "$(jq -c '[.reserved.items[] | select(.part == "admissions") | .name]' <<<"$output")" '["d4","c3"]'

  # Ten minutes on, every session reserves its use, and the allowance is the largest gap again.
  age_admissions 601
  assert_equal "$(reserved_split)" '{"bytes":7.75,"sessions_use":6,"spike_allowance":1.75,"admissions":0,"stacks":0,"heavy_runs":0,"gates":0}'
}

@test "admit on home-pc's numbers: seven idle builders at their use and one allowance leave room for an eighth builder and a heavy run" {
  cp "$BATS_TEST_DIRNAME/fixtures/projects.toml" "$TEAM_HOME/projects.toml"
  mkdir -p "$HOME/.config/agent-team"
  # The learned session:builder estimate, 2.4 GiB, and full's 16.4 GiB budget on 2026-11-01, when
  # seven builders at their estimates reserved 16.8 GiB and nothing more was admitted.
  echo '{"session_gib": 2.4}' >"$HOME/.config/agent-team/capacity.json"
  team_reading 11.6 "T1 builder s1 0.1" "T2 builder s2 0.15" "T3 builder s3 0.2" "T4 builder s4 0.2" \
    "T5 builder s5 0.25" "T6 builder s6 0.3" "T7 builder s7 0.3"
  assert_equal "$(reserved_split)" '{"bytes":3.8,"sessions_use":1.5,"spike_allowance":2.3,"admissions":0,"stacks":0,"heavy_runs":0,"gates":0}'
  run_bin -0 team-capacity status --json
  assert_equal "$(jq -r '.room.budget_bytes' <<<"$output")" 17609365914
  run_bin -0 team-capacity admit --kind session:builder --task T8
  assert_equal "$output" "admitted session:builder at full (90%): a builder needs 2.4 GiB, 3.8 GiB of 16.4 GiB reserved before it"
  run_bin -0 team-capacity admit --kind heavy:tests-run --task T8
  assert_equal "$output" "admitted heavy:tests-run at full (90%): a heavy run of tests-run needs 5.0 GiB, 6.2 GiB of 16.4 GiB reserved before it"
}

@test "admit refuses everything at level none, and with no reading to size the budget by fails" {
  cp "$BATS_TEST_DIRNAME/fixtures/projects.toml" "$TEAM_HOME/projects.toml"
  busy_reading
  level none
  local kind
  for kind in session:planner stack:conventioner heavy:tests-run gate; do
    run_bin -75 --separate-stderr team-capacity admit --kind "$kind" --task T7
    assert_equal "$stderr" "the team is at level none: nothing starts"
  done
  [[ ! -e $STATE_DIR/admitted.json ]]
  # A newest reading over 10 minutes old is taken anew first; one it cannot take leaves no budget.
  level full
  age_by 660
  run_bin -0 team-capacity admit --kind session:planner --task T7
  assert_equal "$(wc -l <"$STATE_DIR/readings.jsonl")" 2
  rm "$STATE_DIR/readings.jsonl"
  printf 'MemTotal:       33554432 kB\n' >"$TEAM_MEMINFO"
  run_bin -1 --separate-stderr team-capacity admit --kind session:planner --task T7
  assert_equal "$stderr" "team-capacity: took no reading of the machine's load: no MemTotal and MemAvailable in $TEAM_MEMINFO
team-capacity: no reading of the machine's load, so no budget to admit session:planner by: team-capacity sample says why it takes none"
}

@test "admit counts the running heavy run while its team-heavy holds the lock, at its admission's kind, but not for a heavy run asking" {
  cp "$BATS_TEST_DIRNAME/fixtures/projects.toml" "$TEAM_HOME/projects.toml"
  # The reading saw the heavy run use 6 GiB, above its 5 GiB seed.
  busy_reading ".heavy = {pid: 4242, memory: (6 * $GIB)}"
  # A run in another form (Conventioner's) is reserved at heavy_gib, named by its line.
  hold_heavy "conventioner e2e since 2026-11-01 10:00:00 +0000"
  run_bin -0 team-capacity status --json
  assert_equal "$(jq -c '.reserved.items[-1] | [.kind, .task, .name, .estimate_bytes, .use_bytes]' <<<"$output")" \
    '["heavy",null,"conventioner e2e since 2026-11-01 10:00:00 +0000",5368709120,null]'
  exec {HEAVY_FD}<&-
  hold_heavy "tests/run in ~/t7 (pid 4242, T7) since 2026-11-01 10:00:00 +0000"
  # The holder asks for itself: the running heavy run is not reserved beside it.
  run_bin -0 team-capacity admit --kind heavy:tests-run --task T7
  assert_equal "$output" "admitted heavy:tests-run at full (90%): a heavy run of tests-run needs 5.0 GiB, 6.2 GiB of 20.0 GiB reserved before it"
  assert_equal "$(jq -c 'map([.kind, .task, .pid])' "$STATE_DIR/admitted.json")" '[["heavy:tests-run","T7",4242]]'
  # Every other asker sees it once, at its kind, its use the reading's, never as an admission too.
  assert_equal "$(reserved_items)" '["sessions_use","session:builder","T7",1]
["spike_allowance","session:builder","T7",0]
["stacks","stack:conventioner","T7",3]
["gates","gate",null,2.2]
["heavy_runs","heavy:tests-run","T7",6]'
  run_bin -0 team-capacity status --json
  assert_equal "$(jq -c '.reserved.items[-1] | [.name, .estimate_bytes, .use_bytes]' <<<"$output")" "[\"tests/run in ~/t7\",5368709120,$((6 * GIB))]"
  # It stays reserved past 10 minutes while its team-heavy holds the lock, and goes with the lock.
  age_admissions 3600
  run_bin -0 team-capacity admit --kind session:reviewer --task T9
  assert_equal "$(jq -c 'map(.kind)' "$STATE_DIR/admitted.json")" '["heavy:tests-run","session:reviewer"]'
  assert_equal "$(reserved_items | grep -c heavy)" 1
  exec {HEAVY_FD}<&-
  assert_equal "$(reserved_items | grep -c heavy || true)" 0
}

@test "two admits racing for the last room admit one, and the others exit 75" {
  cp "$BATS_TEST_DIRNAME/fixtures/projects.toml" "$TEAM_HOME/projects.toml"
  capacity_room "$GIB"
  mkdir -p "$HOME/.config/agent-team"
  echo '{"session_gib": 0.6}' >"$HOME/.config/agent-team/capacity.json"
  local dir=$BATS_TEST_TMPDIR i
  local -a pids=()
  for i in 1 2 3; do
    "$REPO_ROOT/bin/team-capacity" admit --kind session:builder --task "T$i" >"$dir/$i.out" 2>"$dir/$i.err" &
    pids+=($!)
  done
  local statuses=() status
  for i in "${pids[@]}"; do
    status=0
    wait "$i" || status=$?
    statuses+=("$status")
  done
  assert_equal "$(printf '%s\n' "${statuses[@]}" | sort -n | paste -sd ' ')" "0 75 75"
  assert_equal "$(jq length "$STATE_DIR/admitted.json")" 1
  assert_contains "$(cat "$dir"/*.err)" "no room for session:builder at full (90%): 0.6 GiB of 1.0 GiB reserved, a builder needs 0.6 GiB"
}
