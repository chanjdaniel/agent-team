#!/usr/bin/env bats
# team-heavy: the machine's heavy commands take one flock in turn, in the sandbox's HOME, each in a
# process group (and on Linux a scope) of its own, measured and stoppable; and tests/run,
# team-checks' local checks and the doctor use it.

load helpers/common

setup() {
  sandbox
  COSTS=$HOME/.local/state/agent-team/capacity/costs.jsonl
  ADMITTED=$HOME/.local/state/agent-team/capacity/admitted.json
  # A reading of the machine with room for a heavy run, so team-capacity admit takes none.
  capacity_room $((16 * 1073741824))
}

teardown() {
  # Let a holder a test left go, so bats does not wait on it.
  touch "$BATS_TEST_TMPDIR/release"
  wait 2>/dev/null || true
}

# Wait until <file> exists, up to 20 seconds.
wait_for() {
  local i
  for ((i = 0; i < 200; i++)); do
    [[ ! -e $1 ]] || return 0
    sleep 0.1
  done
  echo "wait_for: $1 never appeared" >&2
  return 1
}

COSTS='' ADMITTED=''

# Start a run labelled <label> in the background that holds the lock until $BATS_TEST_TMPDIR/release
# exists, and return once it holds it.
hold() {
  "$REPO_ROOT/bin/team-heavy" run --label "$1" -- bash -c '
    touch "$0/held"
    until [[ -e $0/release ]]; do sleep 0.1; done
    echo "$1" >>"$0/order"' "$BATS_TEST_TMPDIR" "$1" >/dev/null 2>&1 3>&- &
  wait_for "$BATS_TEST_TMPDIR/held"
}

@test "run takes the lock, runs the command with TEAM_HEAVY_HELD set and the lock's descriptor closed, and exits with its status" {
  run_bin -0 team-heavy status
  assert_equal "$output" free
  cd "$HOME"
  run_bin -3 --separate-stderr team-heavy run -- bash -c 'echo "held=$TEAM_HEAVY_HELD"; "$0/bin/team-heavy" status; exit 3' "$REPO_ROOT"
  assert_equal "${lines[0]}" "held=1"
  [[ ${lines[1]} =~ ^held\ by\ bash\ -c\ .*\ in\ ~\ \(pid\ [0-9]+\)\ since\ [0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9:]{8}\ [+-][0-9]{4}$ ]]
  run_bin -0 team-heavy status
  assert_equal "$output" free
}

@test "a second run waits once, naming the holder, and runs when the first ends" {
  hold first
  run_bin -0 team-heavy status
  [[ $output =~ ^held\ by\ first\ \(pid\ [0-9]+\)\ since\ [0-9-]{10}\ [0-9:]{8}\ [+-][0-9]{4}$ ]]
  (sleep 1 && touch "$BATS_TEST_TMPDIR/release") &
  run_bin -0 --separate-stderr team-heavy run --wait 1 --label second -- bash -c 'echo second >>"$0/order"' "$BATS_TEST_TMPDIR"
  assert_equal "$(grep -c waiting <<<"$stderr")" 1
  assert_contains "$stderr" "team-heavy: waiting up to 1 minutes for the heavy-run lock, held by first (pid "
  assert_equal "$(cat "$BATS_TEST_TMPDIR/order")" "first"$'\n'"second"
}

@test "a run that cannot wait exits 75 naming the holder, and runs nothing" {
  hold first
  run_bin -75 --separate-stderr team-heavy run --wait 0 -- touch "$BATS_TEST_TMPDIR/ran"
  assert_contains "$stderr" "team-heavy: the heavy-run lock is held by first (pid "
  [[ ! -e $BATS_TEST_TMPDIR/ran ]]
  TEAM_HEAVY_WAIT_MINUTES=0 run_bin -75 --separate-stderr team-heavy run -- touch "$BATS_TEST_TMPDIR/ran"
  [[ ! -e $BATS_TEST_TMPDIR/ran ]]
}

@test "a nested run runs at once, and what a run leaves running does not keep the lock" {
  hold first
  TEAM_HEAVY_HELD=1 run_bin -0 team-heavy run --wait 0 -- echo nested
  assert_equal "$output" nested
  touch "$BATS_TEST_TMPDIR/release"
  wait
  run_bin -0 team-heavy run -- bash -c 'sleep 30 >/dev/null 2>&1 & echo $! >"$0/left"' "$BATS_TEST_TMPDIR"
  run_bin -0 team-heavy status
  kill "$(cat "$BATS_TEST_TMPDIR/left")"
  assert_equal "$output" free
}

@test "run and status refuse a malformed command line" {
  run_bin -2 team-heavy
  run_bin -2 team-heavy start
  run_bin -2 team-heavy status --json
  run_bin -2 team-heavy run echo hi
  run_bin -2 team-heavy run --
  run_bin -2 team-heavy run --wait soon -- echo hi
  TEAM_HEAVY_WAIT_MINUTES=soon run_bin -2 team-heavy run -- echo hi
  TEAM_HEAVY_RECHECK_SECONDS=0 run_bin -2 team-heavy run -- echo hi
}

# A root holding this checkout's bin/ and tests/run, whose bats is a stub that logs
# TEAM_HEAVY_HELD and the lock's status to $BATS_TEST_TMPDIR/bats, then takes FAKE_BATS_SECONDS
# (default 0), long enough for a heavy run's memory to be sampled.
fake_suite() {
  local root=$BATS_TEST_TMPDIR/suite
  mkdir -p "$root/tests/vendor/bats-core/bin"
  copy_bin "$root/bin"
  cp "$REPO_ROOT/tests/run" "$root/tests/run"
  link_shared tests-shards "$REPO_ROOT/tests/shards" "$root/tests/shards"
  touch "$root/tests/one.bats"
  cat >"$root/tests/vendor/bats-core/bin/bats" <<SH
#!/usr/bin/env bash
echo "held=\$TEAM_HEAVY_HELD \$("$root/bin/team-heavy" status)" >>"$BATS_TEST_TMPDIR/bats"
sleep "\${FAKE_BATS_SECONDS:-0}"
echo "ok 1 one"
SH
  chmod +x "$root/tests/vendor/bats-core/bin/bats"
  echo "$root"
}

@test "tests/run runs its bats under the heavy-run lock, and waits for another holder" {
  root=$(fake_suite)
  run -0 "$root/tests/run" bats
  [[ $(cat "$BATS_TEST_TMPDIR/bats") =~ ^held=1\ held\ by\ tests/run\ bats\ in\ "$root"\ \(pid\ [0-9]+\)\ since\  ]]
  rm "$BATS_TEST_TMPDIR/bats"
  hold first
  TEAM_HEAVY_WAIT_MINUTES=0 run -75 --separate-stderr "$root/tests/run" bats
  assert_contains "$stderr" "team-heavy: the heavy-run lock is held by first (pid "
  [[ ! -e $BATS_TEST_TMPDIR/bats ]]
  # Under a run already, it runs at once.
  TEAM_HEAVY_HELD=1 run -0 "$root/tests/run" bats
  assert_contains "$(cat "$BATS_TEST_TMPDIR/bats")" "held=1 held by first"
}

# fake_suite with a second file, two.bats, whose bats stub logs to $BATS_TEST_TMPDIR/at-once how
# many of the two files ran at once: each waits up to 2 seconds for the other to start.
two_file_suite() {
  local root
  root=$(fake_suite)
  touch "$root/tests/two.bats"
  cat >"$root/tests/vendor/bats-core/bin/bats" <<SH
#!/usr/bin/env bash
running=$BATS_TEST_TMPDIR/running
mkdir -p "\$running"
touch "\$running/\$\$"
for _ in {1..40}; do
  [[ \$(find "\$running" -type f | wc -l) -lt 2 ]] || break
  sleep 0.05
done
find "\$running" -type f | wc -l >>"$BATS_TEST_TMPDIR/at-once"
sleep 0.3
rm "\$running/\$\$"
echo "ok 1 one"
SH
  echo "$root"
}

# The most files the last two_file_suite run ran at once, which it then forgets.
most_at_once() {
  sort -n "$BATS_TEST_TMPDIR/at-once" | tail -n 1
  rm "$BATS_TEST_TMPDIR/at-once"
}

@test "tests/run runs TEAM_JOBS bats files at once, else team-capacity jobs' with a team home, else nproc's, and says it on its last line" {
  root=$(two_file_suite)
  TEAM_JOBS=2 run -0 "$root/tests/run" bats
  [[ ${lines[-1]} =~ ^tests/run\ bats:\ 0m\ 0[0-9]s,\ up\ to\ 2\ bats\ files\ at\ once$ ]]
  assert_equal "$(most_at_once)" 2
  TEAM_JOBS=1 run -0 "$root/tests/run" bats
  [[ ${lines[-1]} == *", up to 1 bats file at once" ]]
  assert_equal "$(most_at_once)" 1
  # With a team home, the floor of the level's CPU budget: minor's 30% of 12 cores.
  level=$TEAM_HOME/level.jsonl
  jq -cn '{ts: (now | floor | todate), mode: "manual", level: "minor", by: "Daniel", machine: "home-pc"}' >"$level"
  TEAM_SLOTS_CPUS=12 run -0 "$root/tests/run" bats
  [[ ${lines[-1]} == *", up to 3 bats files at once" ]]
  # With none, as on CI or a fresh clone, nproc's.
  run -0 env -u TEAM_HOME TEAM_SLOTS_CPUS=12 "$root/tests/run" bats
  [[ ${lines[-1]} == *", up to $(nproc) bats file$( (($(nproc) == 1)) || echo s) at once" ]]
  # A TEAM_JOBS that is no count is refused before anything runs.
  rm -f "$BATS_TEST_TMPDIR/at-once"
  for jobs in 0 three -1; do
    TEAM_JOBS=$jobs run -1 --separate-stderr "$root/tests/run" bats
    assert_equal "$stderr" "run: TEAM_JOBS is the count of bats files to run at once, a whole number above 0, not '$jobs'"
  done
  [[ ! -e $BATS_TEST_TMPDIR/at-once ]]
}

# The user manager on Linux, as the systemctl stub: it answers, every scope's MemoryPeak is <peak>
# bytes and its CPUUsageNSec <nsec>, and a stop of a unit is logged and stops nothing (the run's
# process group is what a stop ends here).
fake_scopes() {
  stub_command uname
  stub_reply uname Linux
  stub_script systemctl <<SH
case \$2 in
  show) if [[ \$3 == -P ]]; then echo 262; else printf 'MemoryPeak=%s\\nCPUUsageNSec=%s\\n' $1 $2; fi ;;
  stop) ;;
  *) echo "systemctl stub: unplanned call: \$*" >&2; exit 127 ;;
esac
SH
}

# The cost lines team-heavy wrote, as [kind, peak_bytes, cpu_seconds] one per line.
costs() {
  jq -c '[.kind, .peak_bytes, .cpu_seconds]' "$COSTS"
}

@test "the holder line names the task when AGENT_TEAM_TASK is set, and a holder of Conventioner's form is still a holder" {
  AGENT_TEAM_TASK=T7 hold first
  run_bin -0 team-heavy status
  [[ $output =~ ^held\ by\ first\ \(pid\ [0-9]+,\ T7\)\ since\ [0-9-]{10}\ [0-9:]{8}\ [+-][0-9]{4}$ ]]
  touch "$BATS_TEST_TMPDIR/release"
  wait

  # Conventioner's scripts/e2e-lock.sh: "<who> since <time>", on the same file.
  exec {held}<>"$HOME/.local/state/agent-team/heavy.lock"
  flock -x "$held"
  echo "e2e conventioner since 2026-11-01 10:00:00 +0000" >"$HOME/.local/state/agent-team/heavy.lock"
  run_bin -0 team-heavy status
  assert_equal "$output" "held by e2e conventioner since 2026-11-01 10:00:00 +0000"
  run_bin -0 team-heavy stop
  assert_equal "$output" "nothing to stop: the heavy-run lock is held by e2e conventioner since 2026-11-01 10:00:00 +0000, not a team-heavy run"
  exec {held}<&-
}

@test "on Linux a run goes through systemd-run in its task's scope and slice, and its scope's peak and CPU are its cost" {
  fake_scopes 3221225472 12500000000
  cd "$HOME"
  AGENT_TEAM_TASK=T7 run_bin -3 --separate-stderr team-heavy run --kind tests-run -- bash -c 'echo "ran held=$TEAM_HEAVY_HELD"; exit 3'
  assert_equal "$output" "ran held=1"
  assert_equal "$stderr" ""
  call=$(stub_calls systemd-run)
  assert_equal "$(jq -c '.[0:4], .[5:9]' <<<"$call")" '["--user","--scope","--collect","--quiet"]'$'\n''["--slice","agent-team-T7.slice","-p","TimeoutStopSec=10"]'
  [[ $(jq -r '.[4]' <<<"$call") =~ ^--unit=agent-team-heavy-[0-9]+\.scope$ ]]
  assert_equal "$(jq -r '.[9]' <<<"$call")" "--description=team-heavy: bash -c echo \"ran held=\$TEAM_HEAVY_HELD\"; exit 3 in ~"
  assert_equal "$(costs)" '["heavy:tests-run",3221225472,12.5]'
  jq -e '(.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")) and (.seconds | type == "number")' "$COSTS"

  # Without a task, the team's slice; the kind is the label's first word.
  run_bin -0 team-heavy run --label "e2e of proj" -- true
  assert_equal "$(stub_calls systemd-run | sed -n 2p | jq -r '.[6]')" agent-team.slice
  assert_equal "$(costs | sed -n 2p)" '["heavy:e2e",3221225472,12.5]'
  # A command given by path is its file's name, so no path goes in the kind.
  run_bin -0 team-heavy run -- "$(type -P true)"
  assert_equal "$(costs | sed -n 3p)" '["heavy:true",3221225472,12.5]'
  run_bin -0 team-heavy status
  assert_equal "$output" free
}

@test "on Linux without a user manager or a scope, a run goes in a process group of its own, says so once, and its sampled peak is its cost" {
  stub_command uname
  stub_reply uname Linux
  # The sandbox's systemctl has no fixture, so the user manager does not answer.
  run_bin -0 --separate-stderr team-heavy run -- bash -c 'echo "$$ $(ps -o pgid= -p $$)"; sleep 1'
  read -r pid pgid <<<"$output"
  assert_equal "$pgid" "$pid"
  assert_equal "$stderr" "team-heavy: systemd's user manager does not answer, so this run has no scope: it runs in a process group of its own"
  assert_equal "$(stub_calls systemd-run)" ""
  jq -e '.kind == "heavy:bash" and .peak_bytes > 0 and (.cpu_seconds | type == "number")' "$COSTS"

  # A user manager that answers but will not start the scope: the same, said once.
  fake_scopes 1 1
  touch "$STUB_FIXTURES/systemd-run-refuse"
  run_bin -0 --separate-stderr team-heavy run --kind checks:proj -- bash -c 'echo "$$ $(ps -o pgid= -p $$)"; sleep 1'
  read -r pid pgid <<<"$output"
  assert_equal "$pgid" "$pid"
  assert_equal "$stderr" "Failed to start transient scope unit: Access denied"$'\n'"team-heavy: systemd-run could not start this run's scope (exit 1), so it runs in a process group of its own"
  assert_equal "$(jq -r .kind "$COSTS" | tail -n 1)" heavy:checks:proj
}

@test "on macOS a run goes in a process group of its own, saying nothing of it, and its sampled peak is its cost" {
  as_macos
  run_bin -4 --separate-stderr team-heavy run --kind tests-run -- bash -c 'echo "$$ $(ps -o pgid= -p $$)"; sleep 1; exit 4'
  read -r pid pgid <<<"$output"
  assert_equal "$pgid" "$pid"
  assert_equal "$stderr" ""
  assert_equal "$(stub_calls systemd-run)" ""
  jq -e '.kind == "heavy:tests-run" and .peak_bytes > 0' "$COSTS"
}

@test "a cost sample that cannot be written is a line on stderr and the run's status stands" {
  as_macos
  # No team home, so no admission needs the state directory either.
  rm -r "$HOME/.local/state/agent-team/capacity"
  touch "$HOME/.local/state/agent-team/capacity"
  run -5 --separate-stderr env -u TEAM_HOME "$REPO_ROOT/bin/team-heavy" run -- bash -c 'sleep 1; exit 5'
  assert_contains "$stderr" "team-heavy: could not write the cost sample to ~/.local/state/agent-team/capacity/costs.jsonl"
}

# Start a run for task <task> in the background whose command starts a sleep child, then holds
# until stopped, and return once it runs: its pid and its child's are in $BATS_TEST_TMPDIR/cmd and
# child, its stderr in run.err and its exit status, once it ends, in run.rc. With <ignore> set,
# the command and its child ignore TERM.
stoppable() {
  local trap=''
  [[ -z ${2:-} ]] || trap="trap '' TERM;"
  (
    rc=0
    AGENT_TEAM_TASK=$1 "$REPO_ROOT/bin/team-heavy" run --label "suite of $1" -- bash -c "$trap"'
      sleep 300 & echo $! >"$0/child"
      echo $$ >"$0/cmd"
      while :; do sleep 0.1; done' "$BATS_TEST_TMPDIR" >/dev/null 2>"$BATS_TEST_TMPDIR/run.err" 3>&- || rc=$?
    echo "$rc" >"$BATS_TEST_TMPDIR/run.rc"
  ) 3>&- &
  wait_for "$BATS_TEST_TMPDIR/cmd"
}

# Succeed when no process <pid>... is left.
gone() {
  local pid
  for pid; do ! kill -0 "$pid" 2>/dev/null || return 1; done
}

@test "stop --task ends its task's run whole, leaves another task's alone, and says nothing to stop when nothing runs" {
  run_bin -0 team-heavy stop
  assert_equal "$output" "nothing to stop"
  stoppable T7
  cmd=$(cat "$BATS_TEST_TMPDIR/cmd") child=$(cat "$BATS_TEST_TMPDIR/child")
  run_bin -0 team-heavy stop --task T8
  [[ $output =~ ^nothing\ to\ stop\ for\ T8:\ the\ heavy\ run\ is\ suite\ of\ T7\ \(pid\ [0-9]+,\ T7\)\ since\  ]]
  kill -0 "$cmd" "$child"

  run_bin -0 team-heavy stop --task T7
  [[ $output =~ ^stopped\ suite\ of\ T7\ \(pid\ [0-9]+,\ T7\)\ since\  ]]
  gone "$cmd" "$child"
  wait_for "$BATS_TEST_TMPDIR/run.rc"
  [[ $(cat "$BATS_TEST_TMPDIR/run.rc") != 0 ]]
  assert_contains "$(cat "$BATS_TEST_TMPDIR/run.err")" "team-heavy: the run was stopped, so it leaves no cost sample"
  [[ ! -e $COSTS ]]
  run_bin -0 team-heavy status
  assert_equal "$output" free
  run_bin -0 team-heavy stop --task T7
  assert_equal "$output" "nothing to stop"
}

@test "stop returns once its run ends, even when a queued run takes the lock first" {
  local round queued i
  for round in 1 2 3 4 5 6 7 8; do
    rm -f "$BATS_TEST_TMPDIR"/{cmd,child,run.rc,run.err,queued.err,queued.rc,queued.held}
    stoppable T7
    (
      rc=0
      AGENT_TEAM_TASK=T8 "$REPO_ROOT/bin/team-heavy" run --wait 5 --label "queued of T8" -- bash -c '
        touch "$0/queued.held"; sleep 60' "$BATS_TEST_TMPDIR" >/dev/null 2>"$BATS_TEST_TMPDIR/queued.err" 3>&- || rc=$?
      echo "$rc" >"$BATS_TEST_TMPDIR/queued.rc"
    ) 3>&- &
    queued=$!
    for ((i = 0; i < 200; i++)); do
      ! grep -q waiting "$BATS_TEST_TMPDIR/queued.err" 2>/dev/null || break
      sleep 0.1
    done
    assert_contains "$(cat "$BATS_TEST_TMPDIR/queued.err")" "waiting up to 5 minutes for the heavy-run lock"
    SECONDS=0
    run_bin -0 team-heavy stop --task T7
    [[ $output =~ ^stopped\ suite\ of\ T7\  ]]
    ((SECONDS < 10)) || { echo "round $round: stop took $SECONDS s" && return 1; }
    wait_for "$BATS_TEST_TMPDIR/queued.held"
    run_bin -0 team-heavy status
    [[ $output =~ ^held\ by\ queued\ of\ T8\ \(pid\ [0-9]+,\ T8\)\  ]]
    run_bin -0 team-heavy stop --task T8
    wait "$queued" || true
  done
}

@test "stop kills a run that ignores TERM after the wait, and stops its scope on Linux" {
  fake_scopes 1 1
  export TEAM_HEAVY_KILL_SECONDS=1
  stoppable T7 ignore
  cmd=$(cat "$BATS_TEST_TMPDIR/cmd") child=$(cat "$BATS_TEST_TMPDIR/child")
  run_bin -0 team-heavy stop
  [[ $output =~ ^stopped\ suite\ of\ T7\  ]]
  gone "$cmd" "$child"
  [[ $(stub_calls systemctl | jq -c 'select(.[1] == "stop")') =~ ^\[\"--user\",\"stop\",\"agent-team-heavy-[0-9]+\.scope\"\]$ ]]
}

@test "stop refuses a malformed command line" {
  run_bin -2 team-heavy stop --task
  run_bin -2 team-heavy stop --task 7
  run_bin -2 team-heavy stop now
  run_bin -2 team-heavy run --kind '' -- true
}

@test "a finished tests/run leaves a heavy:tests-run cost, which team-capacity costs learns from its fifth" {
  as_macos
  export FAKE_BATS_SECONDS=1
  root=$(fake_suite)
  run -0 "$root/tests/run" bats
  assert_equal "$(jq -r .kind "$COSTS")" heavy:tests-run
  run_bin -0 team-capacity costs
  assert_contains "$output" "heavy:tests-run: 5.0 GiB, the seed: heavy_gib 5 GiB, its default (1 sample of 5)"
  for _ in 1 2 3 4; do run -0 "$root/tests/run" bats; done
  run_bin -0 team-capacity costs
  [[ $(grep '^heavy:tests-run' <<<"$output") =~ ^heavy:tests-run:\ [0-9.]+\ GiB,\ learned\ from\ 5\ samples, ]]
}

@test "a run is admitted to the level's budget once it holds the lock, its admission kept with its pid and task" {
  AGENT_TEAM_TASK=T7 run_bin -0 --separate-stderr team-heavy run --kind tests-run -- echo ran
  assert_equal "$output" ran
  assert_equal "$(jq -c 'map([.kind, .task, (.pid | type)])' "$ADMITTED")" '[["heavy:tests-run","T7","number"]]'
  # Under a run already, and with no team home, it asks nothing.
  rm "$ADMITTED"
  TEAM_HEAVY_HELD=1 run_bin -0 team-heavy run -- echo nested
  capacity_room $((16 * 1073741824)) none
  env -u TEAM_HOME "$REPO_ROOT/bin/team-heavy" run --wait 0 -- echo homeless >"$BATS_TEST_TMPDIR/out"
  assert_equal "$(cat "$BATS_TEST_TMPDIR/out")" homeless
  [[ ! -e $ADMITTED ]]
}

@test "with no room a run lets the lock go, says once why it waits, and runs when room comes" {
  capacity_room $((16 * 1073741824)) none
  # Two seconds in, once the lock reads free between its re-checks (each holds it a moment, which a
  # loaded machine stretches), the level goes back to full.
  (sleep 2
    for _ in $(seq 100); do
      "$REPO_ROOT/bin/team-heavy" status >"$BATS_TEST_TMPDIR/meanwhile" || true
      [[ $(cat "$BATS_TEST_TMPDIR/meanwhile") == free ]] && break
      sleep 0.1
    done
    capacity_room $((16 * 1073741824)) full) &
  TEAM_HEAVY_RECHECK_SECONDS=1 run_bin -0 --separate-stderr team-heavy run --wait 1 --kind tests-run -- echo ran
  assert_equal "$output" ran
  assert_equal "$(grep -c 'room' <<<"$stderr")" 1
  assert_equal "${stderr%%$'\n'*}" "team-heavy: waiting up to 1 minutes for room in the team's budget: no room for heavy:tests-run: the team is at level none: nothing starts; room comes when Daniel raises the level"
  assert_equal "$(cat "$BATS_TEST_TMPDIR/meanwhile")" free
  assert_equal "$(jq -c 'map(.kind)' "$ADMITTED")" '["heavy:tests-run"]'
}

@test "a run whose wait for room runs out exits 75 with the reason and runs nothing" {
  mkdir -p "$HOME/.config/agent-team"
  echo '{"heavy_gib": 20}' >"$HOME/.config/agent-team/capacity.json"
  run_bin -75 --separate-stderr team-heavy run --wait 0 --kind tests-run -- touch "$BATS_TEST_TMPDIR/ran"
  assert_equal "$stderr" "team-heavy: no room for heavy:tests-run at full (90%): 0.0 GiB of 16.0 GiB reserved, a heavy run of tests-run needs 20.0 GiB; room comes when the team's work shrinks or the level rises"
  TEAM_HEAVY_RECHECK_SECONDS=1 run_bin -75 --separate-stderr team-heavy run --wait 0.04 --kind tests-run -- touch "$BATS_TEST_TMPDIR/ran"
  assert_equal "$stderr" "team-heavy: waiting up to 0.04 minutes for room in the team's budget: no room for heavy:tests-run at full (90%): 0.0 GiB of 16.0 GiB reserved, a heavy run of tests-run needs 20.0 GiB; room comes when the team's work shrinks or the level rises
team-heavy: still no room after 0.04 minutes: no room for heavy:tests-run at full (90%): 0.0 GiB of 16.0 GiB reserved, a heavy run of tests-run needs 20.0 GiB; room comes when the team's work shrinks or the level rises"
  [[ ! -e $BATS_TEST_TMPDIR/ran ]]
  run_bin -0 team-heavy status
  assert_equal "$output" free
  # An admission that fails otherwise fails the run.
  echo '{"heavy_gib": 0}' >"$HOME/.config/agent-team/capacity.json"
  run_bin -1 --separate-stderr team-heavy run --kind tests-run -- touch "$BATS_TEST_TMPDIR/ran"
  assert_equal "$stderr" "team-heavy: team-capacity admit failed for heavy:tests-run (exit 1): team-capacity: $HOME/.config/agent-team/capacity.json: heavy_gib must be a number above 0, not 0"
  [[ ! -e $BATS_TEST_TMPDIR/ran ]]
}
