#!/usr/bin/env bats
# team-timers: the heartbeat, one job every 5 minutes running `team-timers run`, as systemd user
# units on Linux and LaunchAgents on macOS. A stubbed uname picks the OS; the systemctl and
# launchctl stubs keep each machine's units under its own HOME (fake_service_managers), so no
# test reaches this machine's own systemd. home-pc holds the lease on a bare origin.

load helpers/common
load helpers/docker
load helpers/inbox
load helpers/uptime

# The live session list with only the coordinator in it, which the coordinator step looks for.
COORDINATOR='[{"id": "c0ffee00", "name": "coordinator", "status": "idle"}]'

setup() {
  sandbox
  # A registry, committed with the team home, for the capacity step's readings, and a
  # claude daemon whose one live session is the coordinator, which the coordinator and capacity
  # steps read.
  cp "$BATS_TEST_DIRNAME/fixtures/projects.toml" "$TEAM_HOME/projects.toml"
  stub_reply claude "$COORDINATOR"
  origin=$(hold_lease home-pc)
  fake_service_managers
  stub_command uname
  stub_reply uname Linux
  units=$HOME/.config/systemd/user agents=$HOME/Library/LaunchAgents
  log=$HOME/.local/state/agent-team/heartbeat.log
  failures=$HOME/.local/state/agent-team/heartbeat-failures.log
  notices=$HOME/.local/state/agent-team/notices.json
  inbox_discord alerts
  inbox_guild_kept
}

# The failures log's lines, each without its time.
problems() {
  cut -d' ' -f2- "$failures" 2>/dev/null || true
}

# The commit at the tip of origin's lease branch.
lease_tip() {
  git -C "$origin" rev-parse lease
}

# The PATH a script sees once the library is sourced: on macOS, Homebrew's GNU tools first.
script_path() {
  bash -c 'source "$1/bin/lib/team.sh"; printf "%s\n" "$PATH"' script_path "$REPO_ROOT"
}

expected_service() {
  cat <<EOF
# Written by team-timers enable; team-timers disable removes it.
[Unit]
Description=agent-team heartbeat (team-timers run)

[Service]
Type=oneshot
Environment="TEAM_HOME=$TEAM_HOME"
Environment="PATH=$1"
ExecStart="$REPO_ROOT/bin/team-timers" run
TimeoutStartSec=4500
EOF
}

expected_timer() {
  cat <<'EOF'
# Written by team-timers enable; team-timers disable removes it.
[Unit]
Description=agent-team heartbeat every 5 minutes

[Timer]
OnCalendar=*:0/5
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

plist_head() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- Written by team-timers enable; team-timers disable removes it. -->
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$1</string>
EOF
}

expected_heartbeat_plist() {
  local minute
  plist_head agent-team.heartbeat
  cat <<EOF
  <key>ProgramArguments</key>
  <array>
    <string>$REPO_ROOT/bin/team-timers</string>
    <string>run</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>TEAM_HOME</key>
    <string>$TEAM_HOME</string>
    <key>PATH</key>
    <string>$1</string>
    <key>TEAM_HEARTBEAT_JOB</key>
    <string>agent-team.heartbeat</string>
  </dict>
  <key>StandardErrorPath</key>
  <string>$HOME/.local/state/agent-team/heartbeat.err</string>
  <key>StartCalendarInterval</key>
  <array>
EOF
  for minute in 0 5 10 15 20 25 30 35 40 45 50 55; do
    printf '    <dict>\n      <key>Minute</key>\n      <integer>%s</integer>\n    </dict>\n' "$minute"
  done
  printf '  </array>\n</dict>\n</plist>\n'
}

expected_caffeinate_plist() {
  plist_head agent-team.caffeinate
  cat <<'EOF'
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/caffeinate</string>
    <string>-i</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
</dict>
</plist>
EOF
}

@test "on Linux, enable writes the service and the timer, pointing at this checkout's team-timers run, and starts the timer" {
  run_bin -0 team-timers enable
  assert_equal "$output" "the heartbeat is enabled: agent-team-heartbeat.timer runs $REPO_ROOT/bin/team-timers run every 5 minutes"
  assert_equal "$(cat "$units/agent-team-heartbeat.service")" "$(expected_service "$PATH")"
  assert_equal "$(cat "$units/agent-team-heartbeat.timer")" "$(expected_timer)"
  assert_equal "$(stub_calls systemctl | grep -v '"is-')" \
    "$(printf '%s\n' '["--user","daemon-reload"]' '["--user","enable","--now","agent-team-heartbeat.timer"]')"
  # No caffeinate and no LaunchAgent on Linux.
  [[ ! -e $agents ]]
  assert_equal "$(stub_calls launchctl)" ""
}

@test "on macOS, enable writes the heartbeat's LaunchAgent at every fifth minute and caffeinate's, and loads both" {
  as_macos
  local path
  path=$(script_path)
  run_bin -0 team-timers enable
  assert_equal "$output" "the heartbeat is enabled: agent-team.heartbeat runs $REPO_ROOT/bin/team-timers run every 5 minutes, and agent-team.caffeinate keeps this Mac awake while it is enabled"
  assert_equal "$(cat "$agents/agent-team.heartbeat.plist")" "$(expected_heartbeat_plist "$path")"
  assert_equal "$(cat "$agents/agent-team.caffeinate.plist")" "$(expected_caffeinate_plist)"
  assert_equal "$(stub_calls launchctl | grep -v '"print"')" "$(printf '%s\n' \
    "[\"bootstrap\",\"gui/$(id -u)\",\"$agents/agent-team.heartbeat.plist\"]" \
    "[\"bootstrap\",\"gui/$(id -u)\",\"$agents/agent-team.caffeinate.plist\"]")"
  [[ ! -e $units ]]
  assert_equal "$(stub_calls systemctl)" ""
}

@test "on Linux, enable and disable are idempotent, and disable stops and removes the units" {
  run_bin -0 team-timers enable
  : >"$STUB_CALLS/systemctl.log"
  run_bin -0 team-timers enable
  assert_equal "$output" "the heartbeat is already enabled: agent-team-heartbeat.timer"
  assert_equal "$(stub_calls systemctl | grep -v '"is-')" ""

  run_bin -0 team-timers disable
  assert_equal "$output" "the heartbeat is disabled: agent-team-heartbeat.timer stopped and removed"
  assert_equal "$(stub_calls systemctl | grep -v '"is-')" \
    "$(printf '%s\n' '["--user","disable","--now","agent-team-heartbeat.timer"]' '["--user","daemon-reload"]')"
  [[ ! -e $units/agent-team-heartbeat.service && ! -e $units/agent-team-heartbeat.timer ]]

  : >"$STUB_CALLS/systemctl.log"
  run_bin -0 team-timers disable
  assert_equal "$output" "the heartbeat is not installed; nothing to disable"
  assert_equal "$(stub_calls systemctl | grep -v '"is-')" ""
}

@test "on Linux, enable after a unit changed or the timer stopped puts it right" {
  run_bin -0 team-timers enable
  # An older definition: rewritten, reloaded and the running timer restarted.
  echo "# stale" >>"$units/agent-team-heartbeat.timer"
  : >"$STUB_CALLS/systemctl.log"
  run_bin -0 team-timers enable
  assert_equal "$(cat "$units/agent-team-heartbeat.timer")" "$(expected_timer)"
  assert_equal "$(stub_calls systemctl | grep -v '"is-')" "$(printf '%s\n' '["--user","daemon-reload"]' \
    '["--user","enable","--now","agent-team-heartbeat.timer"]' '["--user","restart","agent-team-heartbeat.timer"]')"

  # Stopped by hand: started again.
  rm "$HOME/.fake-systemd/agent-team-heartbeat.timer.active"
  : >"$STUB_CALLS/systemctl.log"
  run_bin -0 team-timers enable
  assert_equal "$(stub_calls systemctl | grep -v '"is-')" '["--user","enable","--now","agent-team-heartbeat.timer"]'
}

@test "on Linux, enable rewrites and reloads an installed service with no TimeoutStartSec" {
  run_bin -0 team-timers enable
  # The service as enable wrote it before it had a start timeout.
  expected_service "$PATH" | grep -v '^TimeoutStartSec=' >"$units/agent-team-heartbeat.service"
  : >"$STUB_CALLS/systemctl.log"
  run_bin -0 team-timers enable
  assert_equal "$output" "the heartbeat is enabled: agent-team-heartbeat.timer runs $REPO_ROOT/bin/team-timers run every 5 minutes"
  assert_equal "$(cat "$units/agent-team-heartbeat.service")" "$(expected_service "$PATH")"
  assert_equal "$(grep -c '^TimeoutStartSec=4500$' "$units/agent-team-heartbeat.service")" 1
  assert_equal "$(stub_calls systemctl | grep -v '"is-')" "$(printf '%s\n' '["--user","daemon-reload"]' \
    '["--user","enable","--now","agent-team-heartbeat.timer"]' '["--user","restart","agent-team-heartbeat.timer"]')"
}

@test "on macOS, enable and disable are idempotent, a changed LaunchAgent is reloaded, and caffeinate goes with the heartbeat" {
  as_macos
  local uid
  uid=$(id -u)
  run_bin -0 team-timers enable
  : >"$STUB_CALLS/launchctl.log"
  run_bin -0 team-timers enable
  assert_equal "$output" "the heartbeat is already enabled: agent-team.heartbeat, agent-team.caffeinate"
  assert_equal "$(stub_calls launchctl | grep -v '"print"')" ""

  echo "<!-- stale -->" >>"$agents/agent-team.caffeinate.plist"
  : >"$STUB_CALLS/launchctl.log"
  run_bin -0 team-timers enable
  assert_equal "$(stub_calls launchctl | grep -v '"print"')" "$(printf '%s\n' \
    "[\"bootout\",\"gui/$uid/agent-team.caffeinate\"]" \
    "[\"bootstrap\",\"gui/$uid\",\"$agents/agent-team.caffeinate.plist\"]")"
  assert_equal "$(cat "$HOME/.fake-launchd/agent-team.caffeinate")" "$(expected_caffeinate_plist)"

  : >"$STUB_CALLS/launchctl.log"
  run_bin -0 team-timers disable
  assert_equal "$output" "the heartbeat is disabled: agent-team.heartbeat, agent-team.caffeinate stopped and removed"
  assert_equal "$(stub_calls launchctl | grep -v '"print"')" "$(printf '%s\n' \
    "[\"bootout\",\"gui/$uid/agent-team.caffeinate\"]" "[\"bootout\",\"gui/$uid/agent-team.heartbeat\"]")"
  [[ ! -e $agents/agent-team.heartbeat.plist && ! -e $agents/agent-team.caffeinate.plist ]]
  [[ ! -e $HOME/.fake-launchd/agent-team.caffeinate ]]

  : >"$STUB_CALLS/launchctl.log"
  run_bin -0 team-timers disable
  assert_equal "$output" "the heartbeat is not installed; nothing to disable"
  assert_equal "$(stub_calls launchctl | grep -v '"print"')" ""
}

# The calls the fake launchctl made to agent-team.heartbeat, each with the lock's and the plist's
# state then, one a line.
heartbeat_calls() {
  cat "$HOME/.fake-launchd/heartbeat-calls" 2>/dev/null || true
}

# Forget the launchctl calls made so far.
forget_launchctl() {
  : >"$STUB_CALLS/launchctl.log"
  rm -f "$HOME/.fake-launchd/heartbeat-calls"
}

@test "on macOS, disable with no run in progress removes both LaunchAgents, then stops caffeinate and the heartbeat, the heartbeat under the run's lock" {
  as_macos
  local uid
  uid=$(id -u)
  run_bin -0 team-timers enable
  forget_launchctl
  run_bin -0 --separate-stderr team-timers disable
  assert_equal "$output" "the heartbeat is disabled: agent-team.heartbeat, agent-team.caffeinate stopped and removed"
  assert_equal "$stderr" ""
  assert_equal "$(stub_calls launchctl | grep -v '"print"')" "$(printf '%s\n' \
    "[\"bootout\",\"gui/$uid/agent-team.caffeinate\"]" "[\"bootout\",\"gui/$uid/agent-team.heartbeat\"]")"
  assert_equal "$(heartbeat_calls)" "bootout lock held plist absent"
  [[ ! -e $agents/agent-team.heartbeat.plist && ! -e $agents/agent-team.caffeinate.plist ]]
  [[ ! -e $HOME/.fake-launchd/agent-team.heartbeat && ! -e $HOME/.fake-launchd/agent-team.caffeinate ]]
  # The lock is let go.
  flock -n "$HOME/.local/state/agent-team/heartbeat.lock" true
}

@test "on macOS, disable while a run holds the lock, and disable inside the heartbeat job, leave the heartbeat to unload itself" {
  as_macos
  local uid lock=$HOME/.local/state/agent-team/heartbeat.lock case
  uid=$(id -u)
  mkdir -p "${lock%/*}"
  for case in held-outside free-inside held-inside; do
    rm -f "$HOME/.fake-launchd/agent-team.heartbeat"
    run_bin -0 team-timers enable
    forget_launchctl
    case $case in
      held-outside) run -0 --separate-stderr flock "$lock" "$REPO_ROOT/bin/team-timers" disable ;;
      free-inside) TEAM_HEARTBEAT_JOB=agent-team.heartbeat run_bin -0 --separate-stderr team-timers disable ;;
      held-inside) TEAM_HEARTBEAT_JOB=agent-team.heartbeat run -0 --separate-stderr flock "$lock" "$REPO_ROOT/bin/team-timers" disable ;;
    esac
    assert_equal "$output" "the heartbeat is disabled: agent-team.caffeinate stopped and both removed; agent-team.heartbeat unloads itself when its run in progress ends"
    assert_equal "$stderr" ""
    assert_equal "$(stub_calls launchctl | grep -v '"print"')" "[\"bootout\",\"gui/$uid/agent-team.caffeinate\"]"
    assert_equal "$(heartbeat_calls)" ""
    [[ ! -e $agents/agent-team.heartbeat.plist && ! -e $agents/agent-team.caffeinate.plist ]]
    [[ -e $HOME/.fake-launchd/agent-team.heartbeat && ! -e $HOME/.fake-launchd/agent-team.caffeinate ]]
  done
}

@test "on macOS, a run inside the heartbeat job whose LaunchAgent is gone unloads its job and does nothing else" {
  as_macos
  local uid stub
  uid=$(id -u)
  run_bin -0 team-timers enable
  rm "$agents/agent-team.heartbeat.plist"
  for stub in "$STUB_CALLS"/*.log; do : >"$stub"; done
  rm -f "$HOME/.fake-launchd/heartbeat-calls"
  TEAM_HEARTBEAT_JOB=agent-team.heartbeat run_bin -0 --separate-stderr team-timers run
  assert_equal "$output" ""
  assert_equal "$stderr" "team-timers: the heartbeat was disabled, so this run unloads its job and does nothing else"
  assert_equal "$(stub_calls launchctl)" "[\"bootout\",\"gui/$uid/agent-team.heartbeat\"]"
  [[ ! -e $HOME/.fake-launchd/agent-team.heartbeat ]]
  [[ ! -e $log && ! -e $failures && ! -e $HOME/.local/state/agent-team/health.json ]]
  for stub in "$STUB_CALLS"/*.log; do
    [[ $stub == */launchctl.log || $stub == */uname.log ]] || assert_equal "$(basename "$stub"): $(cat "$stub")" "$(basename "$stub"): "
  done
}

@test "on macOS, a run inside the job whose LaunchAgent goes during it unloads its job last, after its log line, record and alerts" {
  as_macos
  local uid
  uid=$(id -u)
  run_bin -0 team-timers enable
  # The coordinator step's session list, read mid-run, is when a handoff's disable removes the
  # plist.
  stub_script claude <<SH
[[ \$1 == agents ]] && rm -f '$agents/agent-team.heartbeat.plist'
echo '$COORDINATOR'
SH
  forget_launchctl
  TEAM_HEARTBEAT_JOB=agent-team.heartbeat run_bin -0 team-timers run
  assert_equal "$(stub_calls launchctl | grep -v '"print"' | tail -n 1)" "[\"bootout\",\"gui/$uid/agent-team.heartbeat\"]"
  assert_equal "$(heartbeat_calls)" "bootout lock free plist absent"
  [[ ! -e $HOME/.fake-launchd/agent-team.heartbeat ]]
  assert_equal "$output" "$(cat "$log")"
  jq -e '.last_run.ended == "ok" and .last_run.holding == true' "$HOME/.local/state/agent-team/health.json"
}

@test "on macOS, a run inside the job that its time limit stops unloads its job last when its LaunchAgent went" {
  as_macos
  local uid hung=$BATS_TEST_TMPDIR/hung
  uid=$(id -u)
  run_bin -0 team-timers enable
  stub_script claude <<SH
[[ \$1 == agents ]] || exit 0
rm -f '$agents/agent-team.heartbeat.plist'
trap '' TERM
echo "\$\$" >>'$hung'
command -p sleep 300
SH
  forget_launchctl
  TEAM_HEARTBEAT_JOB=agent-team.heartbeat TEAM_TIMERS_RUN_SECONDS=8 TEAM_TIMERS_KILL_SECONDS=1 run_bin -1 team-timers run
  [[ $(tail -n 1 "$log") =~ ^[0-9T:Z-]+" run: failed: timed out after 8 s"$ ]]
  assert_equal "$(still_running "$hung")" ""
  jq -e '.last_run.ended == "timed-out"' "$HOME/.local/state/agent-team/health.json"
  assert_equal "$(stub_calls launchctl | grep -v '"print"' | tail -n 1)" "[\"bootout\",\"gui/$uid/agent-team.heartbeat\"]"
  assert_equal "$(heartbeat_calls)" "bootout lock held plist absent"
}

@test "on macOS, a disable from outside while a run its time limit stopped writes its record leaves the job to unload itself" {
  as_macos
  local uid hung=$BATS_TEST_TMPDIR/hung run_tmp=$BATS_TEST_TMPDIR/run-tmp pid rc tries=0
  uid=$(id -u)
  mkdir "$run_tmp"
  run_bin -0 team-timers enable
  stub_script claude <<SH
[[ \$1 == agents ]] || exit 0
trap '' TERM
echo "\$\$" >>'$hung'
command -p sleep 300
SH
  forget_launchctl
  # The run's temporary files in a directory of the test's own, where bounded_run marks that the
  # time limit fired (its err file's .fired). The limit leaves the run time to reach the session
  # list the stub hangs, which a loaded macOS runner has taken over 2 s to; each wait has a
  # deadline, so a run stopped short fails the test rather than hanging it.
  TMPDIR=$run_tmp TEAM_HEARTBEAT_JOB=agent-team.heartbeat TEAM_TIMERS_RUN_SECONDS=8 TEAM_TIMERS_KILL_SECONDS=4 \
    "$REPO_ROOT/bin/team-timers" run >"$BATS_TEST_TMPDIR/run.out" 2>&1 &
  pid=$!
  until [[ -s $hung ]]; do
    ((++tries < 600)) || { echo "the run never reached its session list in 60 s" >&2; return 1; }
    command -p sleep 0.1
  done
  until compgen -G "$run_tmp/*.fired" >/dev/null; do
    ((++tries < 1200)) || { echo "the run's time limit never fired in 120 s" >&2; return 1; }
    command -p sleep 0.1
  done
  # The time limit has stopped the run, whose lock went with it, and bounded_run is still in its
  # wait before the timed-out log line and record.
  command -p sleep 1
  run_bin -0 --separate-stderr team-timers disable
  assert_equal "$output" "the heartbeat is disabled: agent-team.caffeinate stopped and both removed; agent-team.heartbeat unloads itself when its run in progress ends"
  rc=0
  wait "$pid" || rc=$?
  assert_equal "$rc" 1
  [[ $(tail -n 1 "$log") =~ ^[0-9T:Z-]+" run: failed: timed out after 8 s"$ ]]
  assert_equal "$(still_running "$hung")" ""
  jq -e '.last_run.ended == "timed-out"' "$HOME/.local/state/agent-team/health.json"
  assert_equal "$(stub_calls launchctl | grep -v '"print"' | tail -n 1)" "[\"bootout\",\"gui/$uid/agent-team.heartbeat\"]"
  assert_equal "$(heartbeat_calls)" "bootout lock held plist absent"
  [[ ! -e $HOME/.fake-launchd/agent-team.heartbeat ]]
}

@test "on macOS, disable passes when the heartbeat job unloads itself between disable's look and its bootout" {
  as_macos
  local uid
  uid=$(id -u)
  run_bin -0 team-timers enable
  # The fake's first look at the heartbeat finds it loaded, and the job's run unloads it as it
  # answers.
  { cat <<'SH'
if [[ ${1:-} == print && ${2:-} == */agent-team.heartbeat && ! -e $HOME/.fake-launchd/answered ]]; then
  touch "$HOME/.fake-launchd/answered"
  rm -f "$HOME/.fake-launchd/agent-team.heartbeat"
  echo "$2 = {"
  echo "}"
  exit 0
fi
SH
    cat "$STUB_FIXTURES/launchctl.sh"; } >"$BATS_TEST_TMPDIR/launchctl.sh"
  mv "$BATS_TEST_TMPDIR/launchctl.sh" "$STUB_FIXTURES/launchctl.sh"
  forget_launchctl
  run_bin -0 --separate-stderr team-timers disable
  assert_equal "$output" "the heartbeat is disabled: agent-team.heartbeat, agent-team.caffeinate stopped and removed"
  assert_equal "$stderr" ""
  assert_equal "$(stub_calls launchctl | grep -v '"print"')" "[\"bootout\",\"gui/$uid/agent-team.caffeinate\"]"
  [[ ! -e $agents/agent-team.heartbeat.plist && ! -e $HOME/.fake-launchd/agent-team.heartbeat ]]
}
@test "on macOS, a run with its LaunchAgent there, or outside the job, never unloads the heartbeat" {
  as_macos
  run_bin -0 team-timers enable
  forget_launchctl
  TEAM_HEARTBEAT_JOB=agent-team.heartbeat run_bin -0 team-timers run
  assert_equal "$(stub_calls launchctl | grep -v '"print"')" ""

  rm "$agents/agent-team.heartbeat.plist"
  age_lease 20
  run_bin -0 --separate-stderr team-timers run
  assert_equal "$stderr" ""
  assert_equal "$(stub_calls launchctl | grep -v '"print"')" ""
  assert_contains "$output" " lease: home-pc renewed the lease, epoch 1"
  [[ -e $HOME/.fake-launchd/agent-team.heartbeat ]]
}

@test "on macOS, A holds, B steals: A's next run inside its job fences A, writes its log line and record, and unloads its job last" {
  as_macos
  local uid
  uid=$(id -u)
  run_bin -0 team-timers enable
  stub_reply curl "curl must not be called" 99
  stub_script claude <<'EOF'
case $1 in
  agents) echo '[{"id": "3169fcbd", "name": "coordinator", "status": "busy"}, {"id": "81f08540", "name": "T5-builder", "status": "busy"}]' ;;
  stop) echo "Stopped $2" ;;
  *) exit 127 ;;
esac
EOF
  make_machine laptop
  steal_lease laptop home-pc
  forget_launchctl
  TEAM_HEARTBEAT_JOB=agent-team.heartbeat run_bin -0 team-timers run
  [[ $output =~ ^[0-9T:Z-]+" lease: home-pc no longer holds the lease: laptop holds it (epoch 2); fenced home-pc: stopped coordinator (3169fcbd), T5-builder (81f08540); the heartbeat is disabled: agent-team.caffeinate stopped and both removed; agent-team.heartbeat unloads itself when its run in progress ends; team-lease take clears the fence"$ ]]
  assert_equal "$output" "$(tail -n 1 "$log")"
  [[ -e $HOME/.local/state/agent-team/fenced ]]
  assert_equal "$(stub_calls claude)" "$(printf '%s\n' '["agents","--json"]' '["stop","3169fcbd"]' '["stop","81f08540"]')"
  [[ ! -e $agents/agent-team.heartbeat.plist && ! -e $agents/agent-team.caffeinate.plist ]]
  [[ ! -e $HOME/.fake-launchd/agent-team.caffeinate && ! -e $HOME/.fake-launchd/agent-team.heartbeat ]]
  jq -e '.last_run.ended == "fenced"' "$HOME/.local/state/agent-team/health.json"
  assert_equal "$(stub_calls launchctl | grep -v '"print"')" "$(printf '%s\n' \
    "[\"bootout\",\"gui/$uid/agent-team.caffeinate\"]" "[\"bootout\",\"gui/$uid/agent-team.heartbeat\"]")"
  assert_equal "$(heartbeat_calls)" "bootout lock free plist absent"
  assert_equal "$(stub_calls curl)" ""
}

@test "on macOS, enable reloads a loaded heartbeat whose LaunchAgent is gone or changed under the run's lock, and past TEAM_TIMERS_LOCK_SECONDS reloads it anyway" {
  as_macos
  local uid lock=$HOME/.local/state/agent-team/heartbeat.lock
  uid=$(id -u)
  run_bin -0 team-timers enable
  local reload
  reload=$(printf '%s\n' "[\"bootout\",\"gui/$uid/agent-team.heartbeat\"]" \
    "[\"bootstrap\",\"gui/$uid\",\"$agents/agent-team.heartbeat.plist\"]")

  rm "$agents/agent-team.heartbeat.plist"
  forget_launchctl
  run_bin -0 --separate-stderr team-timers enable
  assert_equal "$stderr" ""
  assert_equal "$(stub_calls launchctl | grep -v '"print"')" "$reload"
  assert_equal "$(heartbeat_calls)" "$(printf '%s\n' "bootout lock held plist present" "bootstrap lock held plist present")"
  flock -n "$lock" true

  echo "<!-- stale -->" >>"$agents/agent-team.heartbeat.plist"
  forget_launchctl
  run_bin -0 --separate-stderr team-timers enable
  assert_equal "$stderr" ""
  assert_equal "$(stub_calls launchctl | grep -v '"print"')" "$reload"
  assert_equal "$(heartbeat_calls)" "$(printf '%s\n' "bootout lock held plist present" "bootstrap lock held plist present")"

  rm "$agents/agent-team.heartbeat.plist"
  forget_launchctl
  local start=$SECONDS
  TEAM_TIMERS_LOCK_SECONDS=1 run -0 --separate-stderr flock "$lock" "$REPO_ROOT/bin/team-timers" enable
  ((SECONDS - start < 10))
  assert_equal "$stderr" "team-timers: a heartbeat run still held its lock after 1 s, so the job was reloaded under it"
  assert_equal "$(stub_calls launchctl | grep -v '"print"')" "$reload"
  assert_equal "$(cat "$HOME/.fake-launchd/agent-team.heartbeat")" "$(cat "$agents/agent-team.heartbeat.plist")"
}

@test "status says installed, enabled, the last run from the heartbeat log, the last good run and health; --json says the same" {
  run_bin -0 team-timers status
  assert_equal "$output" "$(printf '%s\n' 'installed: no' 'enabled: no' 'last run: never' 'last good run: never' \
    'health: unknown - no health record yet; the heartbeat writes one each run')"
  run_bin -0 team-timers status --json
  jq -e '. == {installed: false, enabled: false, current: null, last_run: null, last_good_run: null,
    health: "Health: unknown - no health record yet; the heartbeat writes one each run"}' <<<"$output"

  run_bin -0 team-timers enable
  run_bin -0 team-timers run
  local last
  last=$(tail -n 1 "$log" | cut -d' ' -f1)
  [[ $last =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
  local good health
  good=$(jq -r .last_run.start "$HOME/.local/state/agent-team/health.json")
  health=$(TEAM_HOME=$TEAM_HOME "$REPO_ROOT/bin/team-timers" health | head -n 1)
  run_bin -0 team-timers status
  assert_equal "$output" "$(printf '%s\n' 'installed: yes' 'enabled: yes' "last run: $last" "last good run: $good" "health: ${health#Health: }")"
  run_bin -0 team-timers status --json
  jq -e --arg last "$last" --arg good "$good" --arg health "$health" \
    '. == {installed: true, enabled: true, current: true, last_run: $last, last_good_run: $good, health: $health}' <<<"$output"

  # Installed but stopped is not enabled.
  rm "$HOME/.fake-systemd/agent-team-heartbeat.timer.active"
  run_bin -0 team-timers status
  assert_equal "${lines[1]}" "enabled: no"

  as_macos
  run_bin -0 team-timers status --json
  jq -e --arg last "$last" '{installed, enabled, current, last_run} == {installed: false, enabled: false, current: null, last_run: $last}' <<<"$output"
  run_bin -0 team-timers enable
  run_bin -0 team-timers status --json
  jq -e '.installed and .enabled' <<<"$output"
  # Without caffeinate it is not enabled.
  launchctl bootout "gui/$(id -u)/agent-team.caffeinate"
  run_bin -0 team-timers status --json
  jq -e '.installed and (.enabled | not)' <<<"$output"
}

@test "status says whether the installed job is the one this checkout defines, the PATH it was enabled with aside" {
  run_bin -0 team-timers enable
  # Another shell's PATH is no change: the job keeps the one enable captured.
  PATH=$PATH:$BATS_TEST_TMPDIR/elsewhere run_bin -0 team-timers status --json
  jq -e '.installed and .enabled and .current == true' <<<"$output"
  run_bin -0 team-timers status
  assert_equal "${lines[0]}" "installed: yes"

  # A service with no start timeout, as an older checkout wrote it.
  sed -i '/^TimeoutStartSec=/d' "$units/agent-team-heartbeat.service"
  run_bin -0 team-timers status --json
  jq -e '.installed and .enabled and .current == false' <<<"$output"
  run_bin -0 team-timers status
  assert_equal "${lines[0]}" "installed: yes, but not as this checkout defines it (team-timers enable rewrites it)"
  run_bin -0 team-timers enable
  run_bin -0 team-timers status --json
  jq -e '.current == true' <<<"$output"

  # Another checkout's job, or another team home's, is not this one's.
  sed -i "s#^ExecStart=.*#ExecStart=\"$HOME/other/bin/team-timers\" run#" "$units/agent-team-heartbeat.service"
  run_bin -0 team-timers status --json
  jq -e '.current == false' <<<"$output"
  run_bin -0 team-timers enable
  sed -i "s#^Environment=\"TEAM_HOME=.*#Environment=\"TEAM_HOME=$HOME/other-home\"#" "$units/agent-team-heartbeat.service"
  run_bin -0 team-timers status --json
  jq -e '.current == false' <<<"$output"

  # Half installed is not current either.
  run_bin -0 team-timers enable
  rm "$units/agent-team-heartbeat.timer"
  run_bin -0 team-timers status --json
  jq -e '.installed == false and .current == false' <<<"$output"

  # On macOS, the heartbeat's LaunchAgent or caffeinate's.
  as_macos
  run_bin -0 team-timers status --json
  jq -e '.current == null' <<<"$output"
  run_bin -0 team-timers enable
  PATH=$PATH:$BATS_TEST_TMPDIR/elsewhere run_bin -0 team-timers status --json
  jq -e '.installed and .enabled and .current == true' <<<"$output"
  echo "<!-- stale -->" >>"$agents/agent-team.caffeinate.plist"
  run_bin -0 team-timers status --json
  jq -e '.current == false' <<<"$output"
  run_bin -0 team-timers enable
  sed -i "s#<string>$REPO_ROOT/bin/team-timers</string>#<string>$HOME/other/bin/team-timers</string>#" "$agents/agent-team.heartbeat.plist"
  run_bin -0 team-timers status
  assert_equal "${lines[0]}" "installed: yes, but not as this checkout defines it (team-timers enable rewrites it)"
}

@test "run on the holder renews only once the last renewal is 15 minutes old" {
  local tip
  tip=$(lease_tip)
  run_bin -0 team-timers run
  # Each step's line in the log too; the checkpoint has its own test.
  assert_equal "$output" "$(cat "$log")"
  [[ $(head -n 1 <<<"$output") =~ ^[0-9T:Z-]+" lease: home-pc holds the lease, epoch 1, renewed 0 minutes ago; no renewal due"$ ]]
  assert_contains "$(tail -n 1 <<<"$output")" " checkpoint: "
  assert_equal "$(lease_tip)" "$tip"

  age_lease 10
  tip=$(lease_tip)
  run_bin -0 team-timers run
  assert_contains "$output" "lease: home-pc holds the lease, epoch 1, renewed 10 minutes ago; no renewal due"
  assert_equal "$(lease_tip)" "$tip"

  age_lease 20
  tip=$(lease_tip)
  run_bin -0 team-timers run
  [[ $(head -n 1 <<<"$output") =~ ^[0-9T:Z-]+" lease: home-pc renewed the lease, epoch 1"$ ]]
  [[ $(lease_tip) != "$tip" ]]
  lease_json | jq -e '.holder == "home-pc" and .epoch == 1 and (.renewed_at | fromdateiso8601) > now - 120'

  # A second run right after makes no lease commit.
  tip=$(lease_tip)
  run_bin -0 team-timers run
  assert_contains "$output" "renewed 0 minutes ago; no renewal due"
  assert_equal "$(lease_tip)" "$tip"
  assert_equal "$(grep -c ' lease: ' "$log")" 4
}

@test "run on the holder checkpoints each time the last checkpoint is 5 minutes old" {
  local state=$HOME/.local/state/agent-team tip
  mkdir -p "$TEAM_HOME/memory/home" "$state"
  echo "- a note" >"$TEAM_HOME/memory/home/MEMORY.md"
  touch -d '-3 minutes' "$state/last-checkpoint"
  tip=$(git -C "$origin" rev-parse dev)
  run_bin -0 team-timers run
  assert_contains "$output" "lease: home-pc holds the lease"
  [[ $(tail -n 1 <<<"$output") =~ ^[0-9T:Z-]+" checkpoint: not due: the last checkpoint was 3 minutes ago (--force makes one now)"$ ]]
  assert_equal "$(git -C "$origin" rev-parse dev)" "$tip"

  # The heartbeat's next run, 5 minutes on, makes one, and so does the one after.
  touch -d '-5 minutes' "$state/last-checkpoint"
  run_bin -0 team-timers run
  [[ $(tail -n 1 <<<"$output") =~ ^[0-9T:Z-]+" checkpoint: team home: committed "[0-9a-f]+" chore: checkpoint and pushed dev"$ ]]
  # It takes the waiting list the first run's inbox step wrote, a record too.
  assert_equal "$(git -C "$origin" diff-tree -r --no-commit-id --name-only dev)" "memory/home/MEMORY.md
waiting.json
waiting.md"
  assert_equal "$(tail -n 1 "$log")" "$(tail -n 1 <<<"$output")"
  # The waiting list, which did not change, is not committed again.
  echo "steps" >"$TEAM_HOME/manual-steps.md"
  touch -d '-5 minutes' "$state/last-checkpoint"
  run_bin -0 team-timers run
  [[ $(tail -n 1 <<<"$output") =~ ^[0-9T:Z-]+" checkpoint: team home: committed "[0-9a-f]+" chore: checkpoint and pushed dev"$ ]]
  assert_equal "$(git -C "$origin" diff-tree -r --no-commit-id --name-only dev)" "manual-steps.md"

  # A machine that does not hold the lease never checkpoints, however old the last one.
  run -0 "$REPO_ROOT/bin/team-lease" release
  echo "- another note" >>"$TEAM_HOME/memory/home/MEMORY.md"
  touch -d '-30 minutes' "$state/last-checkpoint"
  tip=$(git -C "$origin" rev-parse dev)
  run_bin -0 team-timers run
  assert_equal "$(grep -c checkpoint: <<<"$output")" 0
  assert_equal "$(git -C "$origin" rev-parse dev)" "$tip"
}

@test "a checkpoint that fails is logged and fails the run" {
  local state=$HOME/.local/state/agent-team
  mkdir -p "$TEAM_HOME/memory/home"
  echo "- a note" >"$TEAM_HOME/memory/home/MEMORY.md"
  git -C "$TEAM_HOME" checkout -q --detach
  run_bin -1 team-timers run
  [[ $(grep -E '^[^ ]+ checkpoint: ' <<<"$output" | tail -n 1) =~ ^[0-9T:Z-]+" checkpoint: failed: team home: not on a branch, so the records are not committed"$ ]]
  [[ ! -e $state/last-checkpoint ]]
}

@test "a failed step's line goes to both logs, the same line in each, and a run with no problem adds nothing to the failures log" {
  run_bin -0 team-timers run
  [[ ! -e $failures ]]

  mkdir -p "$TEAM_HOME/memory/home"
  echo "- a note" >"$TEAM_HOME/memory/home/MEMORY.md"
  git -C "$TEAM_HOME" checkout -q --detach
  touch -d '-5 minutes' "$HOME/.local/state/agent-team/last-checkpoint"
  run_bin -1 team-timers run
  # The ledger's commit and the last one each fail, so two lines, the same in both logs and on
  # stdout.
  local line
  line=$(grep ' checkpoint: failed: ' "$log")
  assert_equal "$(cut -d' ' -f2- <<<"$line")" "checkpoint: failed: team home: not on a branch, so the records are not committed
checkpoint: failed: team home: not on a branch, so the records are not committed"
  assert_equal "$(cat "$failures")" "$line"
  assert_equal "$(grep ' checkpoint: failed: ' <<<"$output")" "$line"

  # Back on its branch: the next run's good lines are in the heartbeat log alone.
  git -C "$TEAM_HOME" checkout -q dev
  touch -d '-5 minutes' "$HOME/.local/state/agent-team/last-checkpoint"
  run_bin -0 team-timers run
  assert_contains "$output" " checkpoint: team home: committed "
  assert_equal "$(cat "$failures")" "$line"
}

# Open T1 in a git-pool project, home, on a bare origin, its task directory holding a nested
# repository and a file over 1 MiB, which the checkpoint's archive leaves out, each named; and
# make the team home's origin refuse every wip ref, so its snapshot push fails.
open_task_refused_wip() {
  make_repo home >/dev/null
  printf '.scratch/\n' >"$HOME/projects/home/.gitignore"
  git -C "$HOME/projects/home" add .gitignore
  git -C "$HOME/projects/home" commit -q -m "chore: ignore scratch"
  git -C "$HOME/projects/home" push -q origin main
  cat >>"$TEAM_HOME/projects.toml" <<'TOML'

[home]
repo = "owner/home"
path = "projects/home"
base = "main"
delivery = "direct-pr"
merge_method = "merge"
required_checks = []
task_dir = ".scratch/task"
docs = []
toolkits = []

[home.pool]
provider = "git"
slots = ["slots/home/1"]
TOML
  # team-thread's post answers with the thread's id; team-inbox's calls go to the fake Discord.
  stub_script curl <<'SH'
[[ ! -f $STUB_FIXTURES/inbox.sh ]] || source "$STUB_FIXTURES/inbox.sh"
echo '{"id":"1563000000000000001"}'
SH
  run_bin -0 team-open home feature feat work "Do the work"
  local dir=$HOME/slots/home/1/.scratch/task
  git init -q "$dir/clone"
  head -c 2M /dev/zero >"$dir/big.bin"
  echo "spec" >"$dir/spec.md"
  printf '#!/bin/sh\nwhile read old new ref; do case $ref in refs/heads/wip/*) echo "the test refuses wip" >&2; exit 1 ;; esac; done\n' \
    >"$origin/hooks/pre-receive"
  chmod +x "$origin/hooks/pre-receive"
}

@test "a failed checkpoint logs its own failure lines, never the archive's notes, which are ordinary lines" {
  open_task_refused_wip
  run_bin -1 team-timers run
  assert_equal "$output" "$(cat "$log")"
  [[ $output =~ " checkpoint: T1 home: left out of tasks/T1/scratch: clone (nested repository)"$'\n'[0-9T:Z-]+" checkpoint: T1 home: left out of tasks/T1/scratch: big.bin (over 1 MiB)"$'\n'[0-9T:Z-]+" checkpoint: T1 home: archived .scratch/task to tasks/T1/scratch"$'\n' ]]
  assert_equal "$(grep -c ' checkpoint: failed: ' <<<"$output")" 1
  [[ $(grep ' checkpoint: failed: ' <<<"$output") =~ ^[0-9T:Z-]+" checkpoint: failed: T1 home: cannot push wip/home/T1 to the team home's origin: failed to push some refs to "[^$'\n']+$ ]]
  [[ $(grep ' failed: ' <<<"$output") != *"left out"* ]]
  [[ ! -e $HOME/.local/state/agent-team/last-checkpoint ]]

  # More failures are more lines, in the checkpoint's order: a detached team home fails its
  # ledger commit, first, and its last commit.
  git -C "$TEAM_HOME" checkout -q --detach
  run_bin -1 team-timers run
  [[ $(grep ' checkpoint: failed: ' <<<"$output") =~ ^[0-9T:Z-]+" checkpoint: failed: team home: not on a branch, so the records are not committed"$'\n'[0-9T:Z-]+" checkpoint: failed: T1 home: cannot push wip/home/T1 to the team home's origin: "[^$'\n']+$'\n'[0-9T:Z-]+" checkpoint: failed: team home: not on a branch, so the records are not committed"$ ]]
}

# Run the heartbeat from a code checkout of the test's own (CODE_CHECKOUT) whose team-checkpoint
# is the bash script on stdin, for a checkpoint no real sandbox makes cheaply: fake_checkpoint
fake_checkpoint() {
  CODE_CHECKOUT=$BATS_TEST_TMPDIR/code
  mkdir -p "$CODE_CHECKOUT"
  copy_bin "$CODE_CHECKOUT/bin"
  rm "$CODE_CHECKOUT/bin/team-checkpoint"
  { echo '#!/usr/bin/env bash'; cat; } >"$CODE_CHECKOUT/bin/team-checkpoint"
  chmod +x "$CODE_CHECKOUT/bin/team-checkpoint"
}

# The processes whose ids are listed in the file <file> that still run, one line each.
still_running() {
  local pid
  while read -r pid; do
    if [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null; then echo "$pid still runs"; fi
  done <"$1"
}

@test "the checkpoint is given a deadline for its worktrees of two fifths of its limit" {
  fake_checkpoint <<'SH'
echo "given: $*"
SH
  run_bin -0 team-timers run
  assert_contains "$output" " checkpoint: given: --deadline 120"
  TEAM_TIMERS_CHECKPOINT_SECONDS=100 run_bin -0 team-timers run
  assert_contains "$output" " checkpoint: given: --deadline 40"
}

@test "a checkpoint with more than 20 problem lines logs 20 of them and a count of the rest" {
  # 23 lines would need 23 broken worktrees.
  fake_checkpoint <<'SH'
for n in {1..22}; do echo "team-checkpoint: T$n home: cannot push wip/home/T$n" >&2; done
echo "team-checkpoint: warning: usage: cannot export" >&2
exit 1
SH
  run_bin -1 team-timers run
  local logged
  logged=$(grep -E '^[^ ]+ checkpoint: ' <<<"$output")
  assert_equal "$(grep -c . <<<"$logged")" 21
  [[ $(head -n 1 <<<"$logged") =~ " checkpoint: failed: T1 home: cannot push wip/home/T1"$ ]]
  [[ $(sed -n 20p <<<"$logged") =~ " checkpoint: failed: T20 home: cannot push wip/home/T20"$ ]]
  [[ $(tail -n 1 <<<"$logged") =~ " checkpoint: failed: and 3 more problem lines"$ ]]
}

@test "a good checkpoint with a warning logs it, and the run still exits 0" {
  cp -R "$BATS_TEST_DIRNAME/fixtures/team-tokens/projects" "$HOME/.claude/projects"
  mkdir -p "$TEAM_HOME/usage/home-pc"
  echo "not json" >"$TEAM_HOME/usage/home-pc/2026-10-21.jsonl"
  run_bin -0 team-timers run
  assert_contains "$output" " checkpoint: warning: usage: cannot export: $TEAM_HOME/usage/home-pc/2026-10-21.jsonl holds a line that is no usage line; fix or remove it; the next checkpoint exports it"
  [[ $output != *"checkpoint: failed:"* ]]
  [[ -e $HOME/.local/state/agent-team/last-checkpoint ]]
  assert_equal "$(problems)" "checkpoint: warning: usage: cannot export: $TEAM_HOME/usage/home-pc/2026-10-21.jsonl holds a line that is no usage line; fix or remove it; the next checkpoint exports it"
}

@test "a checkpoint still running at its time limit is stopped with what it started, logged, and the later steps still run" {
  docker_machine
  stack_json '{"heartbeat_janitor": true}'
  add_loose 200
  # A checkpoint deaf to SIGTERM, as a hung git under it may be, with a child of its own.
  local hung=$BATS_TEST_TMPDIR/hung
  fake_checkpoint <<SH
trap '' TERM
echo "a line before it hangs"
command -p sleep 300 &
echo "\$!" >>'$hung'
echo "\$\$" >>'$hung'
wait
SH
  TEAM_TIMERS_CHECKPOINT_SECONDS=1 TEAM_TIMERS_KILL_SECONDS=1 run_bin -1 team-timers run
  assert_equal "$output" "$(cat "$log")"
  # With no good checkpoint yet, its first failure alerts, before the later steps.
  assert_equal "$(steps "$output")" "lease checkpoint alert pack janitor"
  assert_equal "$(grep -E '^[^ ]+ checkpoint: ' <<<"$output" | cut -d' ' -f2-)" "checkpoint: a line before it hangs
checkpoint: failed: timed out after 1 s"
  [[ -s $(day_report) ]]
  assert_equal "$(grep -c . "$hung")" 2
  assert_equal "$(still_running "$hung")" ""
  flock -n "$HOME/.local/state/agent-team/heartbeat.lock" true
}

@test "a checkpoint that fails, and one that exits 75, are each a failed step: the pack and the janitor still run, and the run exits 1" {
  docker_machine
  stack_json '{"heartbeat_janitor": true}'
  add_loose 200
  mkdir -p "$TEAM_HOME/memory/home"
  echo "- a note" >"$TEAM_HOME/memory/home/MEMORY.md"
  git -C "$TEAM_HOME" checkout -q --detach
  run_bin -1 team-timers run
  # With no good checkpoint yet, its first failure alerts, before the later steps.
  assert_equal "$(steps "$output")" "lease checkpoint alert pack janitor"
  [[ $(grep ' checkpoint: failed: ' <<<"$output" | head -n 1) =~ ^[0-9T:Z-]+" checkpoint: failed: team home: not on a branch, so the records are not committed"$ ]]
  assert_contains "$(grep ' pack: ' <<<"$output")" "pack: packed "
  [[ -s $(day_report) ]]
  [[ ! -e $HOME/.local/state/agent-team/last-checkpoint ]]

  # 75: another checkpoint still running, or GitHub unreachable.
  git -C "$TEAM_HOME" checkout -q dev
  rm "$(day_report)"
  add_loose 200
  fake_checkpoint <<'SH'
echo "team-checkpoint: another checkpoint is still running" >&2
exit 75
SH
  run_bin -1 team-timers run
  assert_equal "$(steps "$output")" "lease checkpoint pack janitor"
  assert_equal "$(grep ' checkpoint: ' <<<"$output" | cut -d' ' -f2-)" "checkpoint: failed: another checkpoint is still running"
  [[ -s $(day_report) ]]
}

@test "a run still going at its time limit is stopped with everything it started, logged, exits 1, and the next run takes the lock" {
  # A session list that never answers and is deaf to SIGTERM, under a step's own timeout, whose
  # process group the run's own signal does not reach.
  local hung=$BATS_TEST_TMPDIR/hung
  stub_script claude <<SH
[[ \$1 == agents ]] || exit 0
trap '' TERM
echo "\$\$" >>'$hung'
command -p sleep 300
SH
  local start=$SECONDS
  TEAM_TIMERS_RUN_SECONDS=8 TEAM_TIMERS_KILL_SECONDS=1 run_bin -1 team-timers run
  ((SECONDS - start < 20))
  assert_equal "$output" "$(cat "$log")"
  [[ $(tail -n 1 <<<"$output") =~ ^[0-9T:Z-]+" run: failed: timed out after 8 s"$ ]]
  (($(grep -c . "$hung") >= 1))
  assert_equal "$(still_running "$hung")" ""
  flock -n "$HOME/.local/state/agent-team/heartbeat.lock" true

  rm "$STUB_FIXTURES/claude.sh"
  stub_reply claude "$COORDINATOR"
  run_bin -0 team-timers run
  assert_equal "$(steps "$output")" "lease checkpoint"
}

# The ids of the processes whose arguments are exactly "sleep 4199", each killed, so a run that
# leaves one never holds the file's run open.
leftover_timers() {
  local pid
  command -p ps -A -o pid=,args= | awk '$2 == "sleep" && $3 == "4199" && NF == 3 { print $1 }' |
    while read -r pid; do
      kill -KILL "$pid" 2>/dev/null || true
      echo "$pid"
    done
}

@test "a run leaves no timer behind, even when the process list misses the timer's sleep" {
  # The parent ids' snapshot taken before the timer's sleep was forked: it waits for that sleep,
  # then lists every process but the sleeps. Every other form reads the real table.
  stub_command ps
  stub_script ps <<'SH'
if [[ $* == "-A -o pid=,ppid=" ]]; then
  for ((i = 0; i < 50; i++)); do
    command -p ps -A -o args= | grep -x 'sleep 4199' >/dev/null && break
    command -p sleep 0.1
  done
  command -p ps -A -o pid=,ppid=,comm= | awk '$3 != "sleep" && $3 !~ /\/sleep$/ { print $1, $2 }'
  exit 0
fi
command -p ps "$@"
exit
SH
  export TEAM_TIMERS_RUN_SECONDS=4199
  local start lock=$HOME/.local/state/agent-team/heartbeat.lock
  mkdir -p "${lock%/*}"

  # A run that finds the lock held ends at once.
  start=$SECONDS
  flock "$lock" "$REPO_ROOT/bin/team-timers" run >"$BATS_TEST_TMPDIR/out" 2>&1 || true
  assert_contains "$(cat "$BATS_TEST_TMPDIR/out")" "run: another run is still going; skipped"
  assert_equal "$(leftover_timers)" ""
  ((SECONDS - start < 10))

  # And an ordinary run.
  start=$SECONDS
  run_bin -0 team-timers run
  assert_equal "$(leftover_timers)" ""
  ((SECONDS - start < 10))
}

@test "the inbox step writes waiting.md once a run on the holder, logging only the old message's retire, a numbering afresh or a failure, which never fails the run" {
  run_bin -0 team-timers run
  assert_equal "$(steps "$output")" "lease checkpoint"
  assert_equal "$(inbox_calls)" ""
  assert_equal "$(waiting_items_shown)" "Nothing waits on you."

  # The old Waiting on you message is retired once, and that is logged.
  inbox_kept
  run_bin -0 team-timers run
  assert_equal "$(steps "$output")" "lease checkpoint inbox"
  [[ $(grep ' inbox: ' <<<"$output") =~ ^[0-9T:Z-]+" inbox: retired https://discord.com/channels/$INBOX_GUILD/1562486564871995482/1569000000000000000"$ ]]
  assert_equal "$(inbox_calls)" "PATCH channels/1562486564871995482/messages/1569000000000000000"
  : >"$STUB_FIXTURES/inbox/calls"
  run_bin -0 team-timers run
  assert_equal "$(steps "$output")" "lease checkpoint"
  assert_equal "$(inbox_calls)" ""

  # A waiting.json it cannot read is numbered afresh, which the next run would not show, so it is
  # logged.
  echo '{"schema": "team-waiting/0"}' >"$TEAM_HOME/waiting.json"
  run_bin -0 team-timers run
  assert_equal "$(steps "$output")" "lease checkpoint inbox"
  [[ $(grep ' inbox: ' <<<"$output") =~ ^[0-9T:Z-]+" inbox: numbers the list afresh, since waiting.json cannot be read: its schema is not team-waiting/1"$ ]]
  run_bin -0 team-timers run
  assert_equal "$(steps "$output")" "lease checkpoint"

  waiting_unwritable
  run_bin -0 team-timers run
  assert_equal "$(steps "$output")" "lease checkpoint inbox"
  [[ $(grep ' inbox: ' <<<"$output") =~ ^[0-9T:Z-]+" inbox: failed: cannot write $TEAM_HOME/waiting.md: it is a directory"$ ]]

  # A run that numbers afresh and then fails names the failure's own cause, and logs the
  # numbering too, since waiting.json was written before waiting.md failed.
  echo '{"schema": "team-waiting/0"}' >"$TEAM_HOME/waiting.json"
  run_bin -0 team-timers run
  assert_equal "$(steps "$output")" "lease checkpoint inbox"
  assert_equal "$(grep ' inbox: ' <<<"$output" | sed -E 's/^[0-9T:Z-]+ //')" "inbox: numbers the list afresh, since waiting.json cannot be read: its schema is not team-waiting/1
inbox: failed: cannot write $TEAM_HOME/waiting.md: it is a directory"
}

@test "the inbox step never runs off the lease, offline or on a fenced machine, and runs after the back step" {
  inbox_kept
  make_machine laptop
  on_machine laptop run_bin -0 team-timers run
  assert_equal "$(inbox_calls)" ""

  stub_sleep </dev/null
  discord_answers
  cut_origin
  run_bin -75 team-timers run
  run_bin -75 team-timers run
  assert_equal "$(inbox_calls)" ""
  git -C "${TEAM_HOME:?}" remote set-url origin "${origin:?}"
  run_bin -0 team-timers run
  assert_equal "$(steps "$output")" "back checkpoint inbox"
  assert_equal "$(inbox_calls)" "PATCH channels/1562486564871995482/messages/1569000000000000000"

  steal_lease laptop home-pc
  run_bin -0 team-timers run
  assert_contains "$output" "fenced home-pc"
  run_bin -0 team-timers run
  assert_contains "$output" "home-pc is fenced since "
  assert_equal "$(inbox_calls | wc -l)" 1
}

# Conventioner's API as a production check on the stub production, answering <status> with <body>,
# the known-good site on the stub too, and curl as the fake Discord or the machine's own:
# production <status> <body>
production() {
  uptime_curl
  base=$(uptime_server)
  export TEAM_UPTIME_SECONDS=1 TEAM_UPTIME_KNOWN_GOOD=$base/known-good
  uptime_answer known-good 200 ''
  uptime_check conventioner api "$base/api" '"status":"ok"'
  uptime_answer api "$1" "$2"
}

# The production posts that reached the fake Discord, in order.
production_posts() {
  uptime_posts | grep '^Production' || true
}

# The uptime step's lines of <output>, each without its time.
uptime_lines() {
  sed -n 's/^[^ ]* uptime: //p' <<<"$1"
}

@test "the uptime step makes no fetch and logs nothing with no production check in the registry" {
  uptime_curl
  run_bin -0 team-timers run
  assert_equal "$(steps "$output")" "lease checkpoint"
  assert_equal "$(uptime_lines "$output")" ""
  assert_equal "$(stub_calls curl | jq -r '.[-1]' | grep -v '^https://discord\.com/' || true)" ""
  [[ ! -e $HOME/.local/state/agent-team/uptime.json ]]
}

@test "the uptime step posts one Production down on the second failing run, none on the third, and one Production back once it answers" {
  production 503 'Service Unavailable'
  local since at url
  run_bin -0 team-timers run
  since=$(jq -r '.checks["conventioner/api"].since' "$HOME/.local/state/agent-team/uptime.json")
  at=$(date -d "$since" +%H:%M) url=$base/api
  assert_equal "$(uptime_lines "$output")" "conventioner/api: failed: HTTP 503 (1 in a row, since $since)"
  assert_equal "$(production_posts)" ""

  run_bin -0 team-timers run
  assert_equal "$(uptime_lines "$output")" "conventioner/api: failed: HTTP 503 (2 in a row, since $since)
posted to #coordinator (message 1569000000000000001): down: conventioner/api"
  assert_equal "$(production_posts)" "Production down: conventioner api (<$url>) since $at, 2 checks in a row from home-pc: HTTP 503."
  # Production down is not a failure of the step.
  jq -e '(.steps | has("uptime") | not) and .last_run.ended == "ok"' "$HOME/.local/state/agent-team/health.json"

  run_bin -0 team-timers run
  assert_equal "$(uptime_lines "$output")" "conventioner/api: failed: HTTP 503 (3 in a row, since $since)"
  assert_equal "$(production_posts | wc -l)" 1

  uptime_answer api 200 '{"status":"ok"}'
  run_bin -0 team-timers run
  assert_equal "$(uptime_lines "$output")" "posted to #coordinator (message 1569000000000000002): back: conventioner/api"
  assert_equal "$(production_posts | wc -l)" 2
  [[ $(production_posts | tail -n 1) =~ ^"Production back: conventioner api (<$url>) answers again at "[0-9]{2}:[0-9]{2}", down since $at (" ]]
  run_bin -0 team-timers run
  assert_equal "$(uptime_lines "$output")" ""
  assert_equal "$(production_posts | wc -l)" 2
}

@test "with the known-good site unreachable the uptime step fails the run and counts nothing, posting no production post" {
  production 503 'Service Unavailable'
  export TEAM_UPTIME_KNOWN_GOOD=http://127.0.0.1:9/
  run_bin -1 team-timers run
  run_bin -1 team-timers run
  [[ $(uptime_lines "$output") =~ ^"cannot reach the internet: http://127.0.0.1:9/: "[^$'\n']+"; 1 failing check(s) not counted"$'\n'"failed: this machine cannot reach the internet (http://127.0.0.1:9/: "[^$'\n']+"), so 1 failing check(s) were not counted"$ ]]
  # Both runs' failures, curl's reason aside, which may name how many ms its connect took.
  assert_equal "$(problems | grep -c -xE '^uptime: failed: this machine cannot reach the internet \(http://127\.0\.0\.1:9/: .+\), so 1 failing check\(s\) were not counted$')" 2
  assert_equal "$(production_posts)" ""
  jq -e '.steps.uptime.runs == 2 and (.steps.uptime.reason | startswith("this machine cannot reach the internet (http://127.0.0.1:9/: "))' \
    "$HOME/.local/state/agent-team/health.json"
  jq -e '.checks["conventioner/api"] == null' "$HOME/.local/state/agent-team/uptime.json"
}

@test "two unreachable runs whose curl names another connect time each are both counted in the failures log" {
  production 503 'Service Unavailable'
  # The known-good fetch refused as curl 8 says it, after 0 ms and then after 1 ms.
  { cat <<'EOF'
if [[ ${*: -1} == http://127.0.0.1:9/ ]]; then
  ms=$(cat "$STUB_FIXTURES/connect-ms" 2>/dev/null || echo 0)
  echo $((ms + 1)) >"$STUB_FIXTURES/connect-ms"
  printf 000
  echo "curl: (7) Failed to connect to 127.0.0.1 port 9 after $ms ms: Couldn't connect to server" >&2
  exit 7
fi
EOF
    cat "$STUB_FIXTURES/curl.sh"; } >"$STUB_FIXTURES/curl.sh.new"
  mv "$STUB_FIXTURES/curl.sh.new" "$STUB_FIXTURES/curl.sh"
  TEAM_UPTIME_KNOWN_GOOD=http://127.0.0.1:9/ run_bin -1 team-timers run
  TEAM_UPTIME_KNOWN_GOOD=http://127.0.0.1:9/ run_bin -1 team-timers run
  local fixed='uptime: failed: this machine cannot reach the internet (http://127.0.0.1:9/: Failed to connect to 127.0.0.1 port 9 after'
  assert_equal "$(problems | grep -F "$fixed")" "$fixed 0 ms: Couldn't connect to server), so 1 failing check(s) were not counted
$fixed 1 ms: Couldn't connect to server), so 1 failing check(s) were not counted"
  # So the second run's whole line is in the log once, and the line's fixed part twice.
  assert_equal "$(problems | grep -c -xF "$(grep ' uptime: failed: ' <<<"$output" | cut -d' ' -f2-)")" 1
  assert_equal "$(problems | grep -c -xE '^uptime: failed: this machine cannot reach the internet \(http://127\.0\.0\.1:9/: .+\), so 1 failing check\(s\) were not counted$')" 2
}

@test "the uptime step logs after the alert step's lines and before the inbox step's" {
  production 503 'Service Unavailable'
  # ledger: a line no reader can parse, alerted at once; inbox: the old Waiting on you message,
  # retired.
  echo 'not json' >>"$TEAM_HOME/ledger.jsonl"
  inbox_kept
  run_bin -1 team-timers run
  assert_equal "$(steps "$output")" "lease checkpoint ledger alert uptime inbox"
}

@test "the uptime step never runs off the lease, offline or on a fenced machine, and runs after the back step" {
  production 503 'Service Unavailable'
  make_machine laptop
  TEAM_HOME=$BATS_TEST_TMPDIR/machines/laptop/team uptime_check conventioner api "$base/api" '"status":"ok"'
  on_machine laptop run_bin -0 team-timers run
  assert_equal "$(uptime_lines "$output")" ""

  stub_sleep </dev/null
  cut_origin
  run_bin -75 team-timers run
  run_bin -75 team-timers run
  assert_equal "$(uptime_lines "$output")" ""
  assert_equal "$(uptime_requests)" ""
  git -C "${TEAM_HOME:?}" remote set-url origin "${origin:?}"
  run_bin -0 team-timers run
  assert_equal "$(steps "$output")" "back checkpoint uptime"
  assert_equal "$(uptime_requests | jq -r .path | paste -sd ' ')" "/api /known-good"

  steal_lease laptop home-pc
  run_bin -0 team-timers run
  assert_contains "$output" "fenced home-pc"
  run_bin -0 team-timers run
  assert_contains "$output" "home-pc is fenced since "
  assert_equal "$(uptime_lines "$output")" ""
  assert_equal "$(uptime_requests | wc -l)" 2
}

@test "TEAM_TIMERS_UPTIME_SECONDS replaces the uptime step's 180 s, after which it is stopped and fails the run" {
  production 503 'Service Unavailable'
  uptime_hang api
  export TEAM_TIMERS_UPTIME_SECONDS=1 TEAM_TIMERS_KILL_SECONDS=1 TEAM_UPTIME_SECONDS=30
  local start=$SECONDS
  run_bin -1 team-timers run
  ((SECONDS - start < 20))
  assert_equal "$(uptime_lines "$output")" "failed: timed out after 1 s"
  assert_contains "$(problems)" "uptime: failed: timed out after 1 s"
  grep -q '^UPTIME_TIMEOUT=${TEAM_TIMERS_UPTIME_SECONDS:-180}$' "$REPO_ROOT/bin/team-timers"
}

@test "at the registry's 10 checks, every one hanging, the uptime step's limit fits the fetches, the probe and the down post" {
  # The defaults' ratio, read from the scripts: the step's seconds over a fetch's, with a fetch of 1 s.
  local step fetch i
  step=$(sed -n 's/^UPTIME_TIMEOUT=${TEAM_TIMERS_UPTIME_SECONDS:-\([0-9]*\)}$/\1/p' "$REPO_ROOT/bin/team-timers")
  fetch=$(sed -n 's/^FETCH_SECONDS=${TEAM_UPTIME_SECONDS:-\([0-9]*\)}$/\1/p' "$REPO_ROOT/bin/team-uptime")
  production 200 ''
  uptime_hang api
  for i in 1 2 3 4 5 6 7 8 9; do
    uptime_check conventioner "check-$i" "$base/check-$i" '"status":"ok"'
    uptime_hang "check-$i"
  done
  local limit=$((step / fetch))
  TEAM_TIMERS_UPTIME_SECONDS=$limit TEAM_TIMERS_KILL_SECONDS=1 run_bin -0 team-timers run
  assert_equal "$(production_posts)" ""
  TEAM_TIMERS_UPTIME_SECONDS=$limit TEAM_TIMERS_KILL_SECONDS=1 run_bin -0 team-timers run
  assert_equal "$(uptime_lines "$output" | grep -c "^failed: timed out" || true)" 0
  assert_equal "$(grep -c " uptime: posted to #coordinator (message [0-9]*): down: " <<<"$output")" 1
  assert_equal "$(uptime_posts | grep -c '^Production down: conventioner .*: no answer in 1 s\.$')" 10
  assert_equal "$(production_posts | wc -l)" 10
}

# One ledger line per line on stdin, in order: "launch <task> <role> <session> <worktree>" or
# "<task> <jq object of the event's other fields>".
log_events() {
  local kind more task role session wt
  while read -r kind more; do
    if [[ $kind == launch ]]; then
      read -r task role session wt <<<"$more"
      jq -cn --arg t "$task" --arg r "$role" --arg s "$session" --arg wt "$wt" '{ts: (now | todate), task: $t,
        event: "launch", role: $r, session: $s, worktree: $wt, toolkits: [], machine: "home-pc"}'
    else
      jq -cn --arg t "$kind" "{ts: (now | todate), task: \$t} + ($more)"
    fi
  done >>"$TEAM_HOME/ledger.jsonl"
}

# The claude stub for the finished step: claude agents --json lists $STUB_FIXTURES/agents.json, or
# fails while $STUB_FIXTURES/agents-fail is there; claude stop succeeds unless the id is in
# $STUB_FIXTURES/stop-fails, and hangs, deaf to SIGTERM, when it is in $STUB_FIXTURES/stop-hangs.
finished_stub() {
  : >"$STUB_FIXTURES/stop-fails"
  stub_script claude <<'SH'
if [[ $1 == agents ]]; then
  if [[ -e $STUB_FIXTURES/agents-fail ]]; then echo "cannot reach the daemon" >&2; exit 1; fi
  cat "$STUB_FIXTURES/agents.json"; exit 0
fi
if [[ $1 == stop ]]; then
  if grep -qx "$2" "$STUB_FIXTURES/stop-fails"; then echo "no such session $2" >&2; exit 1; fi
  if grep -qx "$2" "$STUB_FIXTURES/stop-hangs" 2>/dev/null; then trap '' TERM; sleep 60; exit 0; fi
  echo "Stopped $2"; exit 0
fi
echo "claude stub: unplanned call: $*" >&2; exit 127
SH
}

# Open tasks' workers, each listed live: T9's idle planner and reviewer, each handed on by a done
# of its session; its idle builder of the first worktree, whose pr is out with no later builder
# launch there; its idle builder of the second worktree, handed on by a ticket-done and the later
# builder launch there, which is idle with nothing of its own since; reviewers handed on by their
# done but busy, waiting for input, starting and with no status; an idle ops session with a done.
# T8's idle planner, with no event of its own since its launch, T6's idle planner, handed on by
# its done but kept until its plan is approved, since a refusal of its tickets goes back to it,
# and closed T7's idle reviewer, handed on by its done.
finished_workers() {
  local wt1=$HOME/slots/proj/1 wt2=$HOME/slots/proj/2
  log_events <<LINES
launch T9 planner 11111111 $wt1
launch T9 builder 22222222 $wt1
launch T9 reviewer 33333333 $wt1
launch T9 builder 44444444 $wt2
launch T9 reviewer 55555555 $wt1
launch T9 reviewer 5a5a5a5a $wt1
launch T9 reviewer 5b5b5b5b $wt1
launch T9 reviewer 5c5c5c5c $wt1
launch T9 ops 66666666 $wt1
T9 {event: "done", role: "planner", session: "11111111"}
T9 {event: "plan-approved", by: "coordinator"}
T9 {event: "pr", url: "https://github.com/o/r/pull/1", head: "abc1234"}
T9 {event: "done", role: "reviewer", session: "33333333"}
T9 {event: "ticket-done", ticket: "01", commits: ["abc1234"]}
launch T9 builder 45454545 $wt2
T9 {event: "done", role: "reviewer", session: "55555555"}
T9 {event: "done", role: "reviewer", session: "5a5a5a5a"}
T9 {event: "done", role: "reviewer", session: "5b5b5b5b"}
T9 {event: "done", role: "reviewer", session: "5c5c5c5c"}
T9 {event: "done", role: "ops", session: "66666666"}
launch T8 planner 77777777 $wt1
launch T6 planner 99999999 $wt1
T6 {event: "done", role: "planner", session: "99999999"}
launch T7 reviewer 88888888 $wt1
T7 {event: "done", role: "reviewer", session: "88888888"}
T7 {event: "closed"}
LINES
  cat >"$STUB_FIXTURES/agents.json" <<'JSON'
[{"id": "11111111", "name": "T9-planner", "status": "idle"},
 {"id": "22222222", "name": "T9-builder", "status": "idle"},
 {"id": "33333333", "name": "T9-reviewer", "status": "idle"},
 {"id": "44444444", "name": "T9-builder", "status": "idle"},
 {"id": "45454545", "name": "T9-builder", "status": "idle"},
 {"id": "55555555", "name": "T9-reviewer", "status": "busy"},
 {"id": "5a5a5a5a", "name": "T9-reviewer", "status": "idle", "state": "blocked"},
 {"id": "5b5b5b5b", "name": "T9-reviewer", "status": "starting"},
 {"id": "5c5c5c5c", "name": "T9-reviewer"},
 {"id": "66666666", "name": "T9-ops", "status": "idle"},
 {"id": "77777777", "name": "T8-planner", "status": "idle"},
 {"id": "99999999", "name": "T6-planner", "status": "idle"},
 {"id": "88888888", "name": "T7-reviewer", "status": "idle"},
 {"id": "c0ffee00", "name": "coordinator", "status": "idle"}]
JSON
  finished_stub
}

# The ids claude stop was called with, one per line.
stops() {
  stub_calls claude | jq -r 'select(.[0] == "stop") | .[1]'
}

@test "the finished step stops each open task's idle session whose work is handed on, every run on the holder, one line each" {
  finished_workers
  run_bin -0 team-timers run
  assert_equal "$output" "$(cat "$log")"
  assert_equal "$(steps "$output")" "lease checkpoint finished"
  assert_equal "$(grep ' finished: ' <<<"$output" | cut -d ' ' -f 2-)" "finished: stopped T9-planner 11111111: its work is handed on
finished: stopped T9-reviewer 33333333: its work is handed on
finished: stopped T9-builder 44444444: its work is handed on"
  # Left, unnamed: the builder whose pr is out, the later builder, the busy, waiting, starting and
  # statusless reviewers, the ops session, T8's planner with no handing-on event, T6's planner
  # before its plan-approved, closed T7's.
  assert_equal "$(stops)" $'11111111\n33333333\n44444444'
  # Once T6's plan is approved, the next run stops its planner (the sessions stopped are gone).
  log_events <<<'T6 {event: "plan-approved", by: "Daniel"}'
  jq '[.[] | select(.id != "11111111" and .id != "33333333" and .id != "44444444")]' "$STUB_FIXTURES/agents.json" >"$BATS_TEST_TMPDIR/agents.json"
  mv "$BATS_TEST_TMPDIR/agents.json" "$STUB_FIXTURES/agents.json"
  run_bin -0 team-timers run
  assert_equal "$(grep ' finished: ' <<<"$output" | cut -d ' ' -f 2-)" "finished: stopped T6-planner 99999999: its work is handed on"
  # With no reading the team is over no budget, so the level step, which logs each stop of its
  # own, logged none: the stops are the finished step's, whatever the level.
}

@test "the finished step stops nothing off the lease or offline" {
  make_machine laptop
  on_machine laptop finished_workers
  finished_workers
  on_machine laptop run_bin -0 team-timers run
  assert_equal "$(steps "$output")" "lease"
  stub_sleep </dev/null
  cut_origin
  run_bin -75 team-timers run
  run_bin -75 team-timers run
  assert_equal "$(stops)" ""
}

@test "a stop that fails is a warning line and the run goes on; an unreadable session list is one warning line; neither fails the run" {
  finished_workers
  echo 33333333 >"$STUB_FIXTURES/stop-fails"
  run_bin -0 team-timers run
  assert_equal "$(grep ' finished: ' <<<"$output" | cut -d ' ' -f 2-)" "finished: stopped T9-planner 11111111: its work is handed on
finished: warning: could not stop T9-reviewer 33333333 (no such session 33333333)
finished: stopped T9-builder 44444444: its work is handed on"
  assert_equal "$(steps "$output")" "lease checkpoint finished"

  # The coordinator, capacity and level steps read the same list; the coordinator step's failure
  # fails no run, and the capacity and level steps' are what fail this one.
  touch "$STUB_FIXTURES/agents-fail"
  : >"$STUB_CALLS/claude.log"
  run_bin -1 team-timers run
  assert_equal "$(steps "$output")" "lease checkpoint coordinator finished capacity level"
  assert_equal "$(grep ' finished: ' <<<"$output" | cut -d ' ' -f 2-)" \
    "finished: warning: cannot read the live session list (claude agents --json), so no finished session was stopped"
  assert_equal "$(grep -c ': failed: ' <<<"$output")" 3
  [[ $(grep ' capacity: \| level: ' <<<"$output") == *"failed: "*"failed: "* ]]
  assert_equal "$(stops)" ""
}

@test "a claude stop deaf to its time limit's SIGTERM is killed TEAM_TIMERS_KILL_SECONDS later, a warning line, and the step goes on" {
  finished_workers
  echo 11111111 >"$STUB_FIXTURES/stop-hangs"
  local start=$SECONDS
  TEAM_TIMERS_FINISHED_CALL_SECONDS=1 TEAM_TIMERS_KILL_SECONDS=1 run_bin -0 team-timers run
  assert_equal "$(grep ' finished: ' <<<"$output" | cut -d ' ' -f 2-)" "finished: warning: could not stop T9-planner 11111111 (claude stop failed with no reason given)
finished: stopped T9-reviewer 33333333: its work is handed on
finished: stopped T9-builder 44444444: its work is handed on"
  # Killed at 2 s (11 s by default), well before the stub's 60.
  ((SECONDS - start < 40))
}

@test "once the finished step has run its time, no stop starts, and the sessions left are one warning line" {
  finished_workers
  TEAM_TIMERS_FINISHED_SECONDS=0 run_bin -0 team-timers run
  assert_equal "$(grep ' finished: ' <<<"$output" | cut -d ' ' -f 2-)" \
    "finished: warning: 3 finished sessions left for the next run: no stop starts 0 s into the step"
  assert_equal "$(stops)" ""
  # The next run stops them.
  run_bin -0 team-timers run
  assert_equal "$(stops)" $'11111111\n33333333\n44444444'
}

@test "run on a machine that does not hold the lease logs and makes no commit" {
  make_machine laptop
  local tip
  tip=$(lease_tip)
  on_machine laptop run_bin -0 team-timers run
  [[ $output =~ ^[0-9T:Z-]+" lease: home-pc holds the lease (epoch 1); nothing to do"$ ]]
  assert_equal "$(lease_tip)" "$tip"

  run -0 "$REPO_ROOT/bin/team-lease" release
  tip=$(lease_tip)
  run_bin -0 team-timers run
  assert_contains "$output" "lease: the lease is released (epoch 1); nothing to do"
  assert_equal "$(lease_tip)" "$tip"

  # Taken by laptop, and old enough that its holder would renew it.
  on_machine laptop run -0 "$REPO_ROOT/bin/team-lease" take
  age_lease 30
  tip=$(lease_tip)
  run_bin -0 team-timers run
  assert_contains "$output" "lease: laptop holds the lease (epoch 2); nothing to do"
  assert_equal "$(lease_tip)" "$tip"
}

# Origin unreachable for the team home: a closed local port.
cut_origin() {
  git -C "${1:-${TEAM_HOME:?}}" remote set-url origin https://127.0.0.1:9/agent-team.git
}

# git's reason for a cut origin, whose wording after "Failed to connect to 127.0.0.1" changes
# with curl's version ("127.0.0.1:9 ... Could not connect" or "127.0.0.1 port 9 ... Couldn't").
# An ERE, so a pattern holding it goes unquoted after =~.
REFUSED="unable to access 'https://127\\.0\\.0\\.1:9/agent-team\\.git/': Failed to connect to 127\\.0\\.0\\.1[^)]*"

# Make the 60-second wait before the probe's second try return at once, running <script> (read
# from stdin, may be empty) in its place: the uname stub keeps the sandbox's stubs ahead of
# Homebrew's GNU sleep on macOS too.
stub_sleep() {
  stub_command sleep
  stub_script sleep
}

# Discord answers each post (curl) with a message id, or with <status> and an error when given;
# team-inbox's calls go to the fake Discord of helpers/inbox.
discord_answers() {
  if [[ -z ${1:-} ]]; then
    stub_script curl <<'EOF'
[[ ! -f $STUB_FIXTURES/inbox.sh ]] || source "$STUB_FIXTURES/inbox.sh"
echo '{"id":"1563000000000000001"}'
EOF
  else
    stub_script curl <<EOF
[[ ! -f \$STUB_FIXTURES/inbox.sh ]] || source "\$STUB_FIXTURES/inbox.sh"
echo "curl: (22) The requested URL returned error: $1" >&2
exit 22
EOF
  fi
}

# The content of each post to #coordinator, one JSON string per line, team-inbox's left out.
posts() {
  stub_calls curl | jq -c 'select(.[-1] == "https://discord.com/api/v10/channels/1562486564871995482/messages")
    | index("-d") as $i | select($i) | .[$i + 1] | fromjson | .content'
}

# A UTC time as the heartbeat writes it in a post: this machine's local hours and minutes.
clock() {
  date -d "$1" +%H:%M
}

# Serve HTTP <status> to every request on a free local port, standing in for GitHub; prints the
# URL of a repository there. teardown stops it.
http_origin() {
  local port=$BATS_TEST_TMPDIR/http.port
  rm -f "$port"
  python3 -I "$REPO_ROOT/tests/helpers/http-status.py" "$1" "$port" </dev/null >/dev/null 2>"$port.err" 3>&- &
  echo $! >>"$BATS_TEST_TMPDIR/http.pids"
  for _ in $(seq 1 200); do
    [[ ! -s $port ]] || break
    sleep 0.05
  done
  if [[ ! -s $port ]]; then
    echo "http_origin: the server wrote no port in 10 s: $(cat "$port.err")" >&2
    return 1
  fi
  echo "http://127.0.0.1:$(cat "$port")/agent-team.git"
}

teardown() {
  [[ ! -f $BATS_TEST_TMPDIR/http.pids ]] || xargs kill <"$BATS_TEST_TMPDIR/http.pids" 2>/dev/null || true
}

@test "a probe that fails once and then answers sets no flag, posts nothing and goes on to the lease" {
  age_lease 20
  stub_sleep <<EOF
git -C "${TEAM_HOME:?}" remote set-url origin "${origin:?}"
EOF
  cut_origin
  run_bin -0 team-timers run
  assert_equal "$(stub_calls sleep)" '["60"]'
  local pattern="^probe: GitHub unreachable \\($REFUSED\\); trying again in 60s$"
  [[ $(sed -n 1p <<<"$output" | cut -d' ' -f2-) =~ $pattern ]]
  assert_contains "$(sed -n 2p <<<"$output")" " probe: GitHub answered the second try"
  assert_contains "$(sed -n 3p <<<"$output")" " lease: home-pc renewed the lease, epoch 1"
  [[ ! -e $HOME/.local/state/agent-team/offline ]]
  assert_equal "$(posts)" ""
  # The failed probe is a problem; its answer and the renewal are not.
  assert_equal "$(cat "$failures")" "$(sed -n 1p <<<"$output")"
}

@test "two failures hold the team from the first failure's time and post once; later runs post nothing more; the lease is untouched" {
  local tip before
  age_lease 20
  tip=$(lease_tip)
  stub_sleep </dev/null
  discord_answers
  cut_origin
  before=$(date -u +%s)
  run_bin -75 team-timers run
  local flag=$HOME/.local/state/agent-team/offline since
  since=$(jq -r .since "$flag")
  (($(date -d "$since" +%s) >= before && $(date -d "$since" +%s) <= $(date -u +%s)))
  # The flag is the hold alone; that #coordinator was told is the offline notice's.
  jq -e 'keys == ["since"]' "$flag"
  jq -e --arg since "$since" '.notices.offline | .state == "posted" and .since == $since' "$notices"
  assert_contains "$(sed -n 2p <<<"$output")" " probe: GitHub unreachable since $since (unable to access 'https://127.0.0.1:9/agent-team.git/': Failed to connect"
  assert_contains "$(sed -n 2p <<<"$output")" "); the team is holding; #coordinator is told"
  assert_equal "$(posts)" "$(jq -n --arg t "GitHub unreachable since $(clock "$since") on home-pc; holding the team" '$t')"
  assert_equal "$(lease_tip)" "$tip"
  run -75 --separate-stderr "$REPO_ROOT/bin/team-lease" status --json
  assert_equal "$(jq -r .offline_since <<<"$output")" "$since"

  # Still offline: no second try (the team already holds), no post, the same since.
  : >"$STUB_CALLS/sleep.log"
  run_bin -75 team-timers run
  local pattern="^probe: GitHub unreachable since $since \\($REFUSED\\); the team is still holding$"
  [[ $(cut -d' ' -f2- <<<"$output") =~ $pattern ]]
  assert_equal "$(stub_calls sleep)" ""
  assert_equal "$(posts | wc -l)" 1
  assert_equal "$(jq -r .since "$flag")" "$since"
  assert_equal "$(lease_tip)" "$tip"
  # Every line of both runs reports the outage, so the failures log holds them all.
  assert_equal "$(problems | sed -n 3p)" "$(cut -d' ' -f2- <<<"$output")"
  assert_equal "$(cat "$failures")" "$(cat "$log")"
}

@test "the first probe that answers renews at once, clears the flag and posts the window and the tasks with a live worker" {
  stub_sleep </dev/null
  discord_answers
  stub_reply claude '[{"id": "3169fcbd", "name": "coordinator"}, {"id": "81f08540", "name": "T8-reviewer"},
    {"id": "a3586a81", "name": "T5-builder"}, {"id": "1baf2408", "name": "T5-planner"}, {"id": "22222222", "name": "my-T9-builder"}]'
  cut_origin
  run_bin -75 team-timers run
  local since tip
  since=$(jq -r .since "$HOME/.local/state/agent-team/offline")

  # Renewed 5 minutes ago, so no renewal would be due but for the outage.
  age_lease 5
  tip=$(lease_tip)
  git -C "${TEAM_HOME:?}" remote set-url origin "${origin:?}"
  run_bin -0 team-timers run
  [[ $(lease_tip) != "$tip" ]]
  lease_json | jq -e '.holder == "home-pc" and .epoch == 1 and (.renewed_at | fromdateiso8601) > now - 120'
  [[ ! -e $HOME/.local/state/agent-team/offline ]]
  local back
  back=$(sed -nE 's/.* GitHub back at ([^ ]+) .*/\1/p' <<<"$output")
  assert_equal "$(head -n 1 <<<"$output" | cut -d' ' -f2-)" "back: home-pc renewed the lease, epoch 1; GitHub back at $back (unreachable from $since); #coordinator is told"
  assert_equal "$(posts | sed -n 2p)" "$(jq -n --arg t "GitHub back at $(clock "$back") (unreachable from $(clock "$since")); resuming T5, T8" '$t')"

  # The next run is an ordinary one.
  run_bin -0 team-timers run
  assert_contains "$output" "lease: home-pc holds the lease, epoch 1, renewed 0 minutes ago; no renewal due"
  assert_equal "$(posts | wc -l)" 2
}

@test "an outage post that failed goes out with the back message" {
  stub_sleep </dev/null
  discord_answers 503
  stub_reply claude "$COORDINATOR"
  cut_origin
  run_bin -75 team-timers run
  assert_contains "$output" "the team is holding; the post to #coordinator failed (curl: (22) The requested URL returned error: 503); it goes with the back message"
  jq -e '.notices.offline | .state == "open" and (.tried | type) == "string" and .posted == null' "$notices"
  local since
  since=$(jq -r .since "$HOME/.local/state/agent-team/offline")

  discord_answers
  git -C "${TEAM_HOME:?}" remote set-url origin "${origin:?}"
  run_bin -0 team-timers run
  local back
  back=$(sed -nE 's/.* GitHub back at ([^ ]+) .*/\1/p' <<<"$output")
  assert_equal "$(posts | sed -n 2p)" "$(jq -n --arg t "GitHub unreachable since $(clock "$since") on home-pc; holding the team
GitHub back at $(clock "$back") (unreachable from $(clock "$since")); no worker was live, so none was held" '$t')"
  [[ ! -e $HOME/.local/state/agent-team/offline ]]
  jq -e '.notices.offline == null' "$notices"
}

@test "with a session list that never answers, the back post is still made, saying the list could not be read" {
  stub_sleep </dev/null
  discord_answers
  stub_reply claude "$COORDINATOR"
  cut_origin
  run_bin -75 team-timers run
  local since
  since=$(jq -r .since "$HOME/.local/state/agent-team/offline")

  # The back step's read of the session list, the run's first, never answers; later ones do.
  stub_script claude <<SH
if [[ ! -e '$BATS_TEST_TMPDIR/hung' ]]; then
  touch '$BATS_TEST_TMPDIR/hung'
  command -p sleep 300
fi
echo '$COORDINATOR'
SH
  git -C "${TEAM_HOME:?}" remote set-url origin "${origin:?}"
  local start=$SECONDS
  TEAM_TIMERS_FINISHED_CALL_SECONDS=1 TEAM_TIMERS_KILL_SECONDS=1 run_bin -0 team-timers run
  ((SECONDS - start < 20))
  [[ ! -e $HOME/.local/state/agent-team/offline ]]
  local back
  back=$(sed -nE 's/.* GitHub back at ([^ ]+) .*/\1/p' <<<"$output")
  assert_contains "$(head -n 1 <<<"$output")" "; #coordinator is told"
  assert_equal "$(posts | sed -n 2p)" "$(jq -n --arg t "GitHub back at $(clock "$back") (unreachable from $(clock "$since")); resuming the held tasks (the live session list could not be read)" '$t')"
}

@test "GitHub refusing the login (HTTP 403 or 401) is not offline: logged each run, posted once, no second try" {
  local tip
  tip=$(lease_tip)
  git -C "${TEAM_HOME:?}" remote set-url origin "$(http_origin 403)"
  stub_sleep </dev/null
  discord_answers
  run_bin -1 team-timers run
  [[ $output =~ ^[0-9T:Z-]+" probe: GitHub refuses home-pc's login (unable to access 'http://127.0.0.1:"[0-9]+"/agent-team.git/': The requested URL returned error: 403); not offline; #coordinator is told"$ ]]
  [[ ! -e $HOME/.local/state/agent-team/offline ]]
  assert_equal "$(stub_calls sleep)" ""
  local pattern="^GitHub refuses home-pc's login \\(unable to access 'http://127.0.0.1:[0-9]+/agent-team.git/': The requested URL returned error: 403\\); the heartbeat cannot renew the lease until it is fixed there \\(team-doctor\\)$"
  [[ $(posts | jq -r .) =~ $pattern ]]

  # A credential git cannot ask for (HTTP 401) is the same refusal, and is not posted again.
  git -C "${TEAM_HOME:?}" remote set-url origin "$(http_origin 401)"
  run_bin -1 team-timers run
  [[ $output =~ ^[0-9T:Z-]+" probe: GitHub refuses home-pc's login (could not read Username for 'http://127.0.0.1:"[0-9]+"': terminal prompts disabled); not offline"$ ]]
  assert_equal "$(posts | wc -l)" 1
  assert_equal "$(cat "$failures")" "$(cat "$log")"
  assert_equal "$(wc -l <"$failures")" 2

  # Answering again clears it, so a later refusal is posted again.
  git -C "${TEAM_HOME:?}" remote set-url origin "${origin:?}"
  run_bin -0 team-timers run
  assert_contains "$(sed -n 1p <<<"$output")" " probe: GitHub accepts home-pc's login again"
  jq -e '.notices["login-refused"] == null' "$notices"
  [[ ! -e $HOME/.local/state/agent-team/login-refused ]]
  assert_equal "$(lease_tip)" "$tip"
}

@test "a login refusal whose post Discord refused is posted at the next refused run, once" {
  git -C "${TEAM_HOME:?}" remote set-url origin "$(http_origin 403)"
  stub_sleep </dev/null
  discord_answers 503
  run_bin -1 team-timers run
  [[ $output == *"); not offline; the post to #coordinator failed (curl: (22) The requested URL returned error: 503); it is tried again next run" ]]
  jq -e '.notices["login-refused"] | .state == "open" and (.tried | type) == "string"' "$notices"

  discord_answers
  : >"$STUB_CALLS/curl.log"
  run_bin -1 team-timers run
  [[ $output == *"); not offline; #coordinator is told" ]]
  assert_equal "$(posts | wc -l)" 1
  [[ $(posts | jq -r .) == "GitHub refuses home-pc's login ("*"); the heartbeat cannot renew the lease until it is fixed there (team-doctor)" ]]
  jq -e '.notices["login-refused"].state == "posted"' "$notices"
  run_bin -1 team-timers run
  [[ $output == *"); not offline" ]]
  assert_equal "$(posts | wc -l)" 1
}

@test "a login-refused file from before the notice record is moved without a second post while the refusal lasts, and closed silently when GitHub accepts the login" {
  local file=$HOME/.local/state/agent-team/login-refused since
  since=$(date -u +%FT%TZ)
  mkdir -p "${file%/*}"
  jq -n --arg since "$since" '{since: $since, reason: "The requested URL returned error: 403"}' >"$file"
  git -C "${TEAM_HOME:?}" remote set-url origin "$(http_origin 403)"
  stub_sleep </dev/null
  discord_answers
  run_bin -1 team-timers run
  [[ $output == *"); not offline" ]]
  assert_equal "$(posts)" ""
  [[ ! -e $file ]]
  jq -e --arg since "$since" '(.upgraded | index("login-refused") != null)
    and (.notices["login-refused"] | .state == "posted" and .since == $since)' "$notices"
  # The health view reads the refusal from the notice record, dated from the old file.
  run_bin -1 team-timers health --json
  jq -e --arg since "$since" '[.problems[] | select(.key == "login-refused") | .since] == [$since]' <<<"$output"

  git -C "${TEAM_HOME:?}" remote set-url origin "${origin:?}"
  run_bin -0 team-timers run
  assert_contains "$(sed -n 1p <<<"$output")" " probe: GitHub accepts home-pc's login again"
  assert_equal "$(posts)" ""
  jq -e '.notices["login-refused"] == null' "$notices"
  [[ ! -e $file ]]
}

@test "an offline flag from before the notice record is moved by the back step: told, the back post has no outage line; not told, it carries it; the flag goes either way" {
  local flag=$HOME/.local/state/agent-team/offline since back
  since=$(date -u +%FT%TZ)
  discord_answers
  mkdir -p "${flag%/*}"
  jq -n --arg since "$since" '{since: $since, posted: true}' >"$flag"
  run_bin -0 team-timers run
  [[ ! -e $flag ]]
  back=$(sed -nE 's/.* GitHub back at ([^ ]+) .*/\1/p' <<<"$output")
  assert_equal "$(posts)" "$(jq -n --arg t "GitHub back at $(clock "$back") (unreachable from $(clock "$since")); no worker was live, so none was held" '$t')"
  jq -e '(.upgraded | index("offline") != null) and .notices.offline == null' "$notices"

  # The same from a machine with no notice record yet, whose outage post failed.
  rm "$notices"
  : >"$STUB_CALLS/curl.log"
  jq -n --arg since "$since" '{since: $since, posted: false}' >"$flag"
  run_bin -0 team-timers run
  [[ ! -e $flag ]]
  back=$(sed -nE 's/.* GitHub back at ([^ ]+) .*/\1/p' <<<"$output")
  assert_equal "$(posts)" "$(jq -n --arg t "GitHub unreachable since $(clock "$since") on home-pc; holding the team
GitHub back at $(clock "$back") (unreachable from $(clock "$since")); no worker was live, so none was held" '$t')"
  jq -e '.notices.offline == null' "$notices"
}

@test "an offline flag from before the notice record is rewritten as the hold alone, and a run still offline posts nothing" {
  local flag=$HOME/.local/state/agent-team/offline since
  since=$(date -u +%FT%TZ)
  stub_sleep </dev/null
  discord_answers
  mkdir -p "${flag%/*}"
  jq -n --arg since "$since" '{since: $since, posted: false}' >"$flag"
  cut_origin
  run_bin -75 team-timers run
  assert_equal "$(posts)" ""
  jq -e --arg since "$since" '. == {since: $since}' "$flag"
  jq -e --arg since "$since" '.notices.offline | .state == "open" and .tried == $since' "$notices"
}

@test "GitHub answering 5xx is a network failure, tried again and then offline" {
  git -C "${TEAM_HOME:?}" remote set-url origin "$(http_origin 503)"
  stub_sleep </dev/null
  discord_answers
  run_bin -75 team-timers run
  assert_equal "$(stub_calls sleep)" '["60"]'
  assert_contains "$output" "The requested URL returned error: 503); the team is holding; #coordinator is told"
  [[ -e $HOME/.local/state/agent-team/offline ]]
}

@test "a machine that does not hold the lease logs an outage and holds nothing" {
  make_machine laptop
  stub_sleep </dev/null
  cut_origin "$BATS_TEST_TMPDIR/machines/laptop/team"
  on_machine laptop run_bin -75 team-timers run
  assert_contains "$output" "; laptop does not hold the lease, so there is no team to hold"
  [[ ! -e $BATS_TEST_TMPDIR/machines/laptop/home/.local/state/agent-team/offline ]]
  assert_equal "$(stub_calls curl)" ""
}

@test "A holds through an outage while B steals: A's first answering probe fences A instead of resuming, and posts nothing more" {
  stub_sleep </dev/null
  discord_answers
  stub_script claude <<'EOF'
case $1 in
  agents) echo '[{"id": "3169fcbd", "name": "coordinator"}, {"id": "81f08540", "name": "T5-builder"}]' ;;
  stop) echo "Stopped $2" ;;
  *) exit 127 ;;
esac
EOF
  run_bin -0 team-timers enable
  cut_origin
  run_bin -75 team-timers run
  assert_equal "$(posts | wc -l)" 1

  make_machine laptop
  steal_lease laptop home-pc
  local tip
  tip=$(lease_tip)
  git -C "${TEAM_HOME:?}" remote set-url origin "${origin:?}"
  run_bin -0 team-timers run
  [[ $output =~ ^[0-9T:Z-]+" back: home-pc no longer holds the lease: laptop holds it (epoch 2); fenced home-pc: stopped coordinator (3169fcbd), T5-builder (81f08540); the heartbeat is disabled: agent-team-heartbeat.timer stopped and removed; team-lease take clears the fence"$ ]]
  [[ -e $HOME/.local/state/agent-team/fenced && ! -e $HOME/.local/state/agent-team/offline ]]
  assert_equal "$(posts | wc -l)" 1
  assert_equal "$(lease_tip)" "$tip"
}

@test "a machine the back step's renew fences posts nothing and leaves no offline notice" {
  stub_sleep </dev/null
  discord_answers
  stub_script claude <<'SH'
case $1 in
  agents) echo '[{"id": "3169fcbd", "name": "coordinator"}]' ;;
  stop) echo "Stopped $2" ;;
  *) exit 127 ;;
esac
SH
  run_bin -0 team-timers enable
  cut_origin
  run_bin -75 team-timers run
  jq -e '.notices.offline.state == "posted"' "$notices"
  make_machine laptop
  steal_lease laptop home-pc
  git -C "${TEAM_HOME:?}" remote set-url origin "${origin:?}"
  : >"$STUB_CALLS/curl.log"
  run_bin -0 team-timers run
  [[ -e $HOME/.local/state/agent-team/fenced && ! -e $HOME/.local/state/agent-team/offline ]]
  assert_equal "$(posts)" ""
  jq -e '.notices | has("offline") | not' "$notices"
}

@test "A holds, B steals: A's next run fences A, stops only its team sessions, disables the heartbeat and posts nothing" {
  run_bin -0 team-timers enable
  stub_reply curl "curl must not be called" 99
  stub_script claude <<'EOF'
case $1 in
  agents) cat <<'JSON' ;;
[{"id": "3169fcbd", "sessionId": "3169fcbd-1111", "name": "coordinator", "status": "busy", "state": "working"},
 {"id": "81f08540", "sessionId": "81f08540-1111", "name": "T5-builder", "status": "busy", "state": "working"},
 {"id": "a3586a81", "sessionId": "a3586a81-1111", "name": "T12-reviewer", "status": "idle", "state": "done"},
 {"id": "1baf2408", "sessionId": "1baf2408-1111", "name": "sudo-password-faillock", "status": "idle", "state": "done"},
 {"id": "22222222", "sessionId": "22222222-1111", "name": "coordinator-notes", "status": "idle", "state": "done"},
 {"id": "33333333", "sessionId": "33333333-1111", "name": "T5", "status": "idle", "state": "done"},
 {"id": "44444444", "sessionId": "44444444-1111", "name": "my-T5-builder", "status": "idle", "state": "done"},
 {"id": "55555555", "sessionId": "55555555-1111", "status": "idle", "state": "done"}]
JSON
  stop) echo "Stopped $2" ;;
  *) exit 127 ;;
esac
EOF
  make_machine laptop
  steal_lease laptop home-pc
  local tip
  tip=$(lease_tip)

  run_bin -0 team-timers run
  [[ $output =~ ^[0-9T:Z-]+" lease: home-pc no longer holds the lease: laptop holds it (epoch 2); fenced home-pc: stopped coordinator (3169fcbd), T5-builder (81f08540), T12-reviewer (a3586a81); the heartbeat is disabled: agent-team-heartbeat.timer stopped and removed; team-lease take clears the fence"$ ]]
  assert_equal "$output" "$(tail -n 1 "$log")"
  jq -e '.holder == "laptop" and .epoch == 2 and ((.since | fromdateiso8601) > now - 120)' "$HOME/.local/state/agent-team/fenced"
  assert_equal "$(stub_calls claude)" "$(printf '%s\n' '["agents","--json"]' '["stop","3169fcbd"]' '["stop","81f08540"]' '["stop","a3586a81"]')"
  [[ ! -e $units/agent-team-heartbeat.timer && ! -e $HOME/.fake-systemd/agent-team-heartbeat.timer.enabled ]]
  assert_equal "$(stub_calls curl)" ""
  assert_equal "$(lease_tip)" "$tip"

  # The next run, were the heartbeat still to fire, only makes sure it is off.
  : >"$STUB_CALLS/claude.log"
  run_bin -0 team-timers run
  assert_contains "$output" "lease: home-pc is fenced since "
  assert_contains "$output" " (holder seen laptop, epoch 2); the heartbeat is not installed; nothing to disable"
  assert_equal "$(stub_calls claude)" ""
  assert_equal "$(stub_calls curl)" ""
  assert_equal "$(lease_tip)" "$tip"
}

@test "a machine that released the lease is not fenced when another takes it" {
  run_bin -0 team-timers enable
  make_machine laptop
  run -0 "$REPO_ROOT/bin/team-lease" release
  on_machine laptop run -0 "$REPO_ROOT/bin/team-lease" take
  run_bin -0 team-timers run
  assert_contains "$output" "lease: laptop holds the lease (epoch 2); nothing to do"
  [[ ! -e $HOME/.local/state/agent-team/fenced ]]
  assert_equal "$(stub_calls claude)" ""
}

@test "run without a machine name logs why and exits 1" {
  rm "$HOME/.config/agent-team/machine"
  run_bin -1 team-timers run
  assert_contains "$output" "run: this machine has no team name; write one with: echo <name> > ~/.config/agent-team/machine"
  assert_equal "$(tail -n 1 "$log")" "$output"
}

@test "run keeps the heartbeat log to its last 1000 lines once it passes 2000, and skips while another run holds its lock" {
  mkdir -p "${log%/*}"
  seq 1 2500 | sed 's/^/2020-01-01T00:00:00Z old line /' >"$log"
  run_bin -0 team-timers run
  # The kept lines, then the run's lease and checkpoint lines (its ledger commit, its usage export
  # and its last commit): kept by lines, never by age.
  assert_equal "$(wc -l <"$log")" 1004
  assert_equal "$(head -n 1 "$log")" "2020-01-01T00:00:00Z old line 1501"
  [[ ! -e $failures ]]

  local tip
  age_lease 20
  tip=$(lease_tip)
  flock "${log%/*}/heartbeat.lock" "$REPO_ROOT/bin/team-timers" run >"$BATS_TEST_TMPDIR/out" || true
  assert_contains "$(cat "$BATS_TEST_TMPDIR/out")" "run: another run is still going; skipped"
  assert_equal "$(lease_tip)" "$tip"
  assert_equal "$(problems)" "run: another run is still going; skipped"
}

@test "a lease that is not renewed reaches the failures log" {
  age_lease 20
  printf '#!/bin/sh\nwhile read old new ref; do case $ref in refs/heads/lease) echo "the test refuses the lease" >&2; exit 1 ;; esac; done\n' \
    >"$origin/hooks/pre-receive"
  chmod +x "$origin/hooks/pre-receive"
  # Refused under each try, the renew gives up as it does when GitHub is unreachable.
  run_bin -75 team-timers run
  assert_contains "$output" " lease: not renewed: the lease moved under each of 10 attempts "
  assert_equal "$(cat "$failures")" "$(grep ' lease: not renewed: ' "$log")"
}

@test "the failures log keeps 30 days: a line 31 days old is gone after the next run, one 29 days old stays" {
  mkdir -p "${log%/*}"
  {
    echo "$(date -u -d '-31 days' +%FT%TZ) checkpoint: failed: an old failure"
    echo "$(date -u -d '-29 days' +%FT%TZ) inbox: failed: a recent failure"
  } >"$failures"
  run_bin -0 team-timers run
  assert_equal "$(problems)" "inbox: failed: a recent failure"
  assert_equal "$(find "${failures%/*}" -name "heartbeat-failures.log.*")" ""

  # TEAM_TIMERS_FAILURES_DAYS is the age kept.
  TEAM_TIMERS_FAILURES_DAYS=28 run_bin -0 team-timers run
  assert_equal "$(cat "$failures")" ""
}

# The machine's stack settings, ~/.config/agent-team/stack.json under <home> (default HOME):
# stack_json <JSON> [<home>]
stack_json() {
  mkdir -p "${2:-$HOME}/.config/agent-team"
  printf '%s\n' "$1" >"${2:-$HOME}/.config/agent-team/stack.json"
}

# The stub docker's fixture machine (tests/helpers/docker.bash) with no live session, so the
# sweep stops its running team stack conventioner-2 of T7 and the reaper removes three stacks.
docker_machine() {
  cp "$BATS_TEST_DIRNAME/fixtures/projects.toml" "$TEAM_HOME/projects.toml"
  stack_project shop
  docker_stub "$STACK_WORKTREE"
  reap_machine
  stub_reply claude "$COORDINATOR"
  discord_answers
}

# The steps a run's output logged, in order, each run of lines once: steps <output>
steps() {
  sed -E 's/^[^ ]+ ([a-z]+): .*$/\1/' <<<"$1" | uniq | paste -sd ' '
}

# The docker calls made but the read-only ones of team-stack ls --json, which the capacity step's
# reading makes on the holder, and the level step's, which holds the team's containers to the
# level's CPU every run.
docker_acts() {
  docker_calls | grep -vE '^(compose ls --all --format json|ps --all --quiet --no-trunc|inspect --type container .*|stats --no-stream --format json .*)$' |
    grep -vE '^(ps --quiet --filter label=io\.github\.chanjdaniel\.team\.owner=agent-team|update --cpus [0-9.]+ [0-9a-f ]+)$' || true
}

# The readings the capacity step took under <home> (default HOME), one per line.
readings() {
  cat "${1:-$HOME}/.local/state/agent-team/capacity/readings.jsonl" 2>/dev/null || true
}

# The day's janitor report, by local date.
day_report() {
  echo "$HOME/.local/state/agent-team/janitor/$(date +%F).md"
}

@test "every step that logs on the holder logs in one run, in the heartbeat's order" {
  docker_machine
  # uptime: a production check failing once.
  production 503 'Service Unavailable'
  uptime_curl answers
  stack_json '{"heartbeat_sweep": true, "heartbeat_janitor": true}'
  # inbox: the old Waiting on you message, retired.
  inbox_kept
  # coordinator: no session named coordinator is listed; finished: T7's idle reviewer, handed on
  # by its done, stopped; capacity: the same session, still listed by the stub and outside its
  # slice, placed.
  log_events <<LINES
launch T7 reviewer a1b2c3d4 $HOME/slots/proj/1
T7 {event: "done", role: "reviewer", session: "a1b2c3d4"}
LINES
  fake_placement
  fake_process 100 99 - claude
  stub_reply claude '[{"pid": 100, "id": "a1b2c3d4", "name": "T7-reviewer", "status": "idle"}]'
  # level: automatic mode at none for an hour over readings that span rise_minutes, so it rises.
  local file=$HOME/.local/state/agent-team/capacity/readings.jsonl minutes
  mkdir -p "${file%/*}"
  for minutes in 25 20 15 10 5; do
    jq -cn --arg at "$(date -u -d "$minutes minutes ago" +%FT%TZ)" \
      '{at: $at, os: "linux", memory: {total: 34359738368, available: 25769803776, team: 0, others: 8589934592}, cpu: null}' >>"$file"
  done
  jq -cn --arg ts "$(date -u -d '1 hour ago' +%FT%TZ)" '{ts: $ts, mode: "auto", level: "none", by: "auto", machine: "home-pc"}' \
    >"$TEAM_HOME/level.jsonl"
  # stacks: the sweep stops the idle conventioner-2; checkpoint: always a line; pack: 200 loose
  # objects; janitor: no report of today yet.
  add_loose 200
  run_bin -0 team-timers run
  assert_equal "$output" "$(cat "$log")"
  assert_equal "$(steps "$output")" "lease checkpoint coordinator uptime inbox finished capacity level stacks pack janitor"
}

@test "the stacks and janitor steps are off without stack.json, without their keys and while they are false: no line, no call" {
  docker_machine
  run_bin -0 team-timers run
  assert_equal "$(steps "$output")" "lease checkpoint"
  # A file holding only other keys, as a machine that set its memory floor has.
  stack_json '{"memory_floor_gib": 1}'
  run_bin -0 team-timers run
  assert_equal "$(steps "$output")" "lease checkpoint"
  stack_json '{"heartbeat_sweep": false, "heartbeat_janitor": false, "idle_minutes": 0}'
  run_bin -0 team-timers run
  assert_equal "$(steps "$output")" "lease checkpoint"
  assert_equal "$(docker_acts)" ""
  [[ ! -e $HOME/.local/state/agent-team/janitor && ! -e $HOME/.local/state/agent-team/stacks ]]
}

@test "with heartbeat_sweep on, the stacks step sweeps after the level step, a log line per line the sweep prints" {
  docker_machine
  stack_json '{"heartbeat_sweep": true}'
  run_bin -0 team-timers run
  assert_equal "$output" "$(cat "$log")"
  assert_equal "$(steps "$output")" "lease checkpoint stacks"
  [[ $(grep ' stacks: ' <<<"$output") =~ ^[0-9T:Z-]+" stacks: "[0-9T:Z-]+" stopped conventioner-2 of T7 in $STACK_WORKTREE: not seen busy since its start at "[0-9T:Z-]+" (idle_minutes 30), its data kept"$ ]]
  assert_equal "$(docker_calls | sed -n 's/^compose -p \(.*\) stop$/\1/p')" conventioner-2
  # A sweep that stops nothing prints nothing, so the step logs nothing; the janitor stays off.
  run_bin -0 team-timers run
  assert_equal "$(steps "$output")" "lease checkpoint"
  [[ ! -e $HOME/.local/state/agent-team/janitor ]]
}

@test "with heartbeat_janitor on, the janitor step runs team-janitor after the checkpoint, once a local day" {
  docker_machine
  stack_json '{"heartbeat_janitor": true}'
  local report
  report=$(day_report)
  # A dry run's report is no run of the day.
  mkdir -p "${report%/*}"
  echo "# a preview" >"${report%.md}-dry-run.md"
  run_bin -0 team-timers run
  assert_equal "$(steps "$output")" "lease checkpoint janitor"
  assert_equal "$(grep -c ' janitor: ' <<<"$output")" 1
  [[ $(tail -n 1 <<<"$output") =~ ^[0-9T:Z-]+" janitor: No alerts. Removed 3 objects, ".*" Report: ~/.local/state/agent-team/janitor/$(date +%F).md."$ ]]
  [[ -s $report ]]
  docker_calls | grep -qx 'compose -p conventioner-4 down -v --remove-orphans'
  # Today's report is there, so the next runs leave Docker alone.
  local calls
  calls=$(docker_acts | wc -l)
  run_bin -0 team-timers run
  assert_equal "$(steps "$output")" "lease checkpoint"
  assert_equal "$(docker_acts | wc -l)" "$calls"
}

@test "a failing step is logged with its reason, the steps after it still run, and the run exits 1" {
  docker_machine
  stack_json '{"heartbeat_sweep": true, "heartbeat_janitor": true}'
  stub_script claude <<'EOF'
echo "claude: the session list is down" >&2
exit 1
EOF
  run_bin -1 team-timers run
  assert_equal "$output" "$(cat "$log")"
  assert_equal "$(steps "$output")" "lease checkpoint coordinator finished capacity level stacks janitor"
  # The coordinator step cannot look for a coordinator, which fails the step, never the run.
  assert_equal "$(grep -E '^[^ ]+ coordinator: ' <<<"$output" | cut -d ' ' -f 2-)" \
    "coordinator: failed: cannot read the live session list (claude agents --json): claude: the session list is down"
  # The finished step warns and stops nothing, never failing the run.
  assert_equal "$(grep ' finished: ' <<<"$output" | cut -d ' ' -f 2-)" \
    "finished: warning: cannot read the live session list (claude agents --json), so no finished session was stopped"
  # The capacity step's reading still went in, without the sessions; its place failed.
  assert_equal "$(grep ' capacity: ' <<<"$output" | cut -d ' ' -f 2-)" \
    "capacity: failed: claude: the session list is down"
  # The level step applied the limits, but its stow plan needs the session list.
  assert_equal "$(grep ' level: ' <<<"$output" | cut -d ' ' -f 2-)" \
    "level: failed: the stow plan failed: team-capacity: cannot read the live session list (claude agents --json)"
  assert_equal "$(jq -c .sessions "$HOME/.local/state/agent-team/capacity/readings.jsonl")" false
  [[ $(grep ' stacks: ' <<<"$output") =~ ^[0-9T:Z-]+" stacks: failed: ".*"the session list is down" ]]
  assert_contains "$(grep ' janitor: ' <<<"$output")" "No alerts."
  [[ -s $(day_report) ]]

  # Docker not answering: the sweep has nothing to sweep, which it logs nothing for, and the
  # janitor fails, its report then the day's, so it is not run again that day.
  rm "$STUB_FIXTURES/claude.sh"
  stub_reply claude "$COORDINATOR"
  rm "$(day_report)"
  docker_down
  run_bin -1 team-timers run
  assert_equal "$(steps "$output")" "lease checkpoint janitor"
  [[ $(tail -n 1 <<<"$output") =~ ^[0-9T:Z-]+" janitor: failed: Docker does not answer: " ]]
  assert_contains "$(grep ' janitor: ' <<<"$output" | head -n 1)" "Docker does not answer ("
  [[ -s $(day_report) ]]
  run_bin -0 team-timers run
  assert_equal "$(steps "$output")" "lease checkpoint"
}

@test "the pack step packs the team home on the holder once it has 200 loose objects, unreachable ones too" {
  run_bin -0 team-timers run
  assert_equal "$(steps "$output")" "lease checkpoint"
  add_loose 150
  add_loose 60 --unreachable
  (($(loose_count) >= 200))
  run_bin -0 team-timers run
  assert_equal "$(steps "$output")" "lease checkpoint pack"
  [[ $(tail -n 1 <<<"$output") =~ ^[0-9T:Z-]+" pack: packed "[0-9]+" loose objects; 0 left loose, "[0-9.]+" "[KMG]iB" in packs"$ ]]
  assert_equal "$(tail -n 1 "$log")" "$(tail -n 1 <<<"$output")"
  assert_equal "$(loose_count)" 0
  add_loose 190
  run_bin -0 team-timers run
  assert_equal "$(steps "$output")" "lease checkpoint"

  # A machine that does not hold the lease never packs.
  run -0 "$REPO_ROOT/bin/team-lease" release
  add_loose 300
  run_bin -0 team-timers run
  assert_equal "$(grep -c ' pack: ' <<<"$output")" 0
}

@test "a pack that fails is logged with git's reason, the steps after it still run, and the run exits 1" {
  docker_machine
  stack_json '{"heartbeat_janitor": true}'
  add_loose 200
  # Another gc running, as git records it: a live process on this host.
  echo "$$ $(hostname)" >"$TEAM_HOME/.git/gc.pid"
  run_bin -1 team-timers run
  assert_equal "$(steps "$output")" "lease checkpoint pack janitor"
  [[ $(grep ' pack: ' <<<"$output") =~ " pack: failed: fatal: gc is already running on machine " ]]
}

@test "a hung Docker stops each step at its time limit, logged, and the run still checkpoints and frees its lock" {
  docker_machine
  stack_json '{"heartbeat_sweep": true, "heartbeat_janitor": true}'
  docker_hang
  # A reading of a minute ago, so the level step has limits to apply and reaches Docker.
  mkdir -p "$HOME/.local/state/agent-team/capacity"
  jq -cn --arg at "$(date -u -d '1 minute ago' +%FT%TZ)" \
    '{at: $at, os: "linux", memory: {total: 34359738368, available: 25769803776, team: 0, others: 8589934592}, cpu: null}' \
    >"$HOME/.local/state/agent-team/capacity/readings.jsonl"
  # Each step's limit is about 14 times what it takes here to reach its docker call (capacity
  # 0.07 s, level 0.28 s, which first checks the lease and reads the budget), so CI's macOS runner,
  # about 4 times slower, still reaches it before the step stops; all well inside their own 30 s
  # for Docker.
  TEAM_TIMERS_CAPACITY_SECONDS=1 TEAM_TIMERS_LEVEL_SECONDS=4 TEAM_TIMERS_SWEEP_SECONDS=1 \
    TEAM_TIMERS_JANITOR_SECONDS=1 run_bin -1 team-timers run
  assert_equal "$output" "$(cat "$log")"
  assert_equal "$(steps "$output")" "lease checkpoint capacity level stacks janitor"
  [[ $(grep ' capacity: ' <<<"$output") =~ ^[0-9T:Z-]+" capacity: failed: timed out after 1 s"$ ]]
  [[ $(grep ' level: ' <<<"$output") =~ ^[0-9T:Z-]+" level: failed: timed out after 4 s"$ ]]
  [[ $(grep ' stacks: ' <<<"$output") =~ ^[0-9T:Z-]+" stacks: failed: timed out after 1 s"$ ]]
  [[ $(tail -n 1 <<<"$output") =~ ^[0-9T:Z-]+" janitor: failed: timed out after 1 s"$ ]]
  # Nothing they started is left waiting, and the janitor stopped wrote no report, so the next
  # run starts it again.
  local pid
  [[ $(grep -c . "$DOCKER_STATE/hung") == 4 ]]
  while read -r pid; do
    if [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null; then
      echo "docker call $pid still waits"
      return 1
    fi
  done <"$DOCKER_STATE/hung"
  [[ ! -e $(day_report) ]]
  flock -n "$HOME/.local/state/agent-team/heartbeat.lock" true
}

@test "a malformed stack.json fails each step with the reason, never the run, and the checkpoint still runs" {
  docker_machine
  local file=$HOME/.config/agent-team/stack.json
  stack_json '{"heartbeat_sweep": "yes", "heartbeat_janitor": true}'
  run_bin -1 team-timers run
  assert_equal "$(steps "$output")" "lease checkpoint stacks janitor"
  [[ $(grep ' stacks: ' <<<"$output") =~ ^[0-9T:Z-]+" stacks: failed: $file: heartbeat_sweep must be true or false, not \"yes\""$ ]]
  [[ $(grep ' janitor: ' <<<"$output") =~ ^[0-9T:Z-]+" janitor: failed: $file: heartbeat_sweep must be true or false, not \"yes\""$ ]]
  stack_json '{"heartbeat_sweep": true,'
  run_bin -1 team-timers run
  assert_equal "$(steps "$output")" "lease checkpoint stacks janitor"
  assert_contains "$(grep ' stacks: ' <<<"$output")" " stacks: failed: $file is not JSON: "
  stack_json '[true]'
  run_bin -1 team-timers run
  [[ $(grep ' janitor: ' <<<"$output") =~ " janitor: failed: $file is not one JSON object"$ ]]
  assert_equal "$(docker_acts)" ""
}

@test "the heartbeat has no slots step: the capacity step takes the one reading, at most one a minute, before the level step" {
  run_bin -0 team-timers run
  assert_equal "$(steps "$output")" "lease checkpoint"
  assert_equal "$(readings | jq -c '[.os, .docker, .memory.total]')" '["linux",false,34359738368]'
  [[ ! -e $HOME/.local/state/agent-team/slots ]]
  run_bin -0 team-timers run
  assert_equal "$(readings | wc -l)" 1
  # Each step that logs says so in the run's order: capacity, then level.
  local file=$HOME/.config/agent-team/capacity.json
  echo '{"minor_share": 2}' >"$file"
  run_bin -1 team-timers run
  assert_equal "$(steps "$output")" "lease checkpoint capacity level"
  run_bin -0 team-timers --help
  [[ $output != *slots* ]]
}

@test "the capacity step takes a reading with the team's use per task on the holder every run, logging only the sessions it placed" {
  run_bin -0 team-timers run
  assert_equal "$(steps "$output")" "lease checkpoint"
  local file=$HOME/.local/state/agent-team/capacity/readings.jsonl
  assert_equal "$(jq -c '[.os, .systemd, .sessions, .tasks]' "$file")" '["linux",true,true,[]]'
  # A live team session outside its slice is placed, and that is logged.
  fake_placement
  fake_process 100 99 - claude
  stub_reply claude '[{"pid": 100, "id": "a1b2c3d4", "name": "T7-builder", "status": "idle"}, {"id": "c0ffee00", "name": "coordinator", "status": "idle"}]'
  run_bin -0 team-timers run
  assert_equal "$(steps "$output")" "lease checkpoint capacity"
  assert_equal "$(grep ' capacity: ' <<<"$output" | cut -d ' ' -f 2-)" "capacity: placed T7-builder a1b2c3d4 in agent-team-T7-a1b2c3d4.scope (1 process)"
  # Off the lease, none.
  make_machine laptop
  on_machine laptop run_bin -0 team-timers run
  [[ ! -e $BATS_TEST_TMPDIR/machines/laptop/home/.local/state/agent-team/capacity/readings.jsonl ]]
}

@test "a capacity step whose capacity.json is malformed is logged with the reason, its place still runs, and the run exits 1" {
  local file=$HOME/.config/agent-team/capacity.json
  mkdir -p "${file%/*}"
  echo '{"minor_share": "a third"}' >"$file"
  run_bin -1 team-timers run
  assert_equal "$output" "$(cat "$log")"
  assert_equal "$(steps "$output")" "lease checkpoint capacity level"
  [[ $(grep ' capacity: ' <<<"$output") =~ ^[0-9T:Z-]+" capacity: failed: $file: minor_share must be a number above 0 and at most 1, not \"a third\""$ ]]
  [[ $(grep ' level: ' <<<"$output") =~ ^[0-9T:Z-]+" level: failed: $file: minor_share must be a number above 0 and at most 1, not \"a third\""$ ]]
  [[ ! -e $HOME/.local/state/agent-team/capacity/readings.jsonl ]]
  # The coordinator step's session list and its sweep's, the finished step's and the place's.
  assert_equal "$(stub_calls claude)" $'["agents","--json"]\n["agents","--json"]\n["agents","--json"]\n["agents","--json"]'
}

@test "neither step runs off the lease, while another run holds the lock, offline or on a fenced machine; both run after the back step" {
  docker_machine
  stack_json '{"heartbeat_sweep": true, "heartbeat_janitor": true}'
  local state=$HOME/.local/state/agent-team calls
  make_machine laptop
  stack_json '{"heartbeat_sweep": true, "heartbeat_janitor": true}' "$BATS_TEST_TMPDIR/machines/laptop/home"
  on_machine laptop run_bin -0 team-timers run
  assert_equal "$(steps "$output")" "lease"
  assert_equal "$(readings "$BATS_TEST_TMPDIR/machines/laptop/home")" ""

  mkdir -p "$state"
  run flock "$state/heartbeat.lock" "$REPO_ROOT/bin/team-timers" run
  assert_equal "$(steps "$output")" "run"

  stub_sleep </dev/null
  cut_origin
  run_bin -75 team-timers run
  assert_equal "$(steps "$output")" "probe"
  run_bin -75 team-timers run
  assert_equal "$(steps "$output")" "probe"
  assert_equal "$(docker_calls)" ""
  assert_equal "$(readings)" ""

  git -C "${TEAM_HOME:?}" remote set-url origin "${origin:?}"
  run_bin -0 team-timers run
  assert_equal "$(steps "$output")" "back checkpoint stacks janitor"
  assert_equal "$(readings | wc -l)" 1

  steal_lease laptop home-pc
  calls=$(docker_calls | wc -l)
  run_bin -0 team-timers run
  assert_contains "$output" "fenced home-pc"
  assert_equal "$(steps "$output")" "lease"
  run_bin -0 team-timers run
  assert_contains "$output" "home-pc is fenced since "
  assert_equal "$(steps "$output")" "lease"
  assert_equal "$(docker_calls | wc -l)" "$calls"
}

@test "watch prints a line when the offline flag appears and when it goes, checking every 60 s, and nothing in between" {
  local flag=$HOME/.local/state/agent-team/offline
  mkdir -p "${flag%/*}"
  # Each wait moves the outage on: it starts, holds, ends, then the stub stops the watch.
  stub_sleep <<EOF2
n=\$(cat "$BATS_TEST_TMPDIR/waits" 2>/dev/null || echo 0)
echo \$((n + 1)) >"$BATS_TEST_TMPDIR/waits"
case \$n in
  0) echo '{"since": "2026-10-23T13:05:00Z", "posted": true}' >"$flag" ;;
  1) ;;
  2) rm "$flag" ;;
  *) exit 143 ;;
esac
EOF2
  run_bin -143 --separate-stderr team-timers watch
  assert_equal "$stderr" ""
  assert_equal "$output" "GitHub unreachable since 2026-10-23T13:05:00Z; the team is holding
GitHub answers again (unreachable from 2026-10-23T13:05:00Z); the hold is over"
  assert_equal "$(stub_calls sleep)" '["60"]
["60"]
["60"]
["60"]'
}

@test "watch prints the hold at once when the flag is there as it starts, and reads an unreadable flag's time from the file" {
  local flag=$HOME/.local/state/agent-team/offline
  mkdir -p "${flag%/*}"
  echo '{"since": "2026-10-23T13:05:00Z", "posted": false}' >"$flag"
  stub_sleep <<<'exit 143'
  run_bin -143 team-timers watch
  assert_equal "$output" "GitHub unreachable since 2026-10-23T13:05:00Z; the team is holding"
  echo 'not json' >"$flag"
  touch -d 2026-10-23T14:00:00Z "$flag"
  run_bin -143 team-timers watch
  assert_equal "$output" "GitHub unreachable since 2026-10-23T14:00:00Z; the team is holding"
}

@test "watch --once prints the hold starting and exits 0, checking every 60 s" {
  local flag=$HOME/.local/state/agent-team/offline
  mkdir -p "${flag%/*}"
  # The outage starts during the second wait; a fifth wait would stop the stub with 143.
  stub_sleep <<EOF2
n=\$(cat "$BATS_TEST_TMPDIR/waits" 2>/dev/null || echo 0)
echo \$((n + 1)) >"$BATS_TEST_TMPDIR/waits"
case \$n in
  1) echo '{"since": "2026-10-23T13:05:00Z", "posted": true}' >"$flag" ;;
  4) exit 143 ;;
esac
EOF2
  run_bin -0 --separate-stderr team-timers watch --once
  assert_equal "$stderr" ""
  assert_equal "$output" "GitHub unreachable since 2026-10-23T13:05:00Z; the team is holding"
  assert_equal "$(stub_calls sleep)" '["60"]
["60"]'
}

@test "watch --once takes a hold already on as no change, and prints its end and exits 0" {
  local flag=$HOME/.local/state/agent-team/offline
  mkdir -p "${flag%/*}"
  echo '{"since": "2026-10-23T13:05:00Z", "posted": false}' >"$flag"
  stub_sleep <<EOF2
n=\$(cat "$BATS_TEST_TMPDIR/waits" 2>/dev/null || echo 0)
echo \$((n + 1)) >"$BATS_TEST_TMPDIR/waits"
case \$n in
  2) rm "$flag" ;;
  4) exit 143 ;;
esac
EOF2
  run_bin -0 team-timers watch --once
  assert_equal "$output" "GitHub answers again (unreachable from 2026-10-23T13:05:00Z); the hold is over"
  assert_equal "$(stub_calls sleep | grep -c .)" 3
}

@test "watch --once never ends while the flag stays as it found it" {
  local flag=$HOME/.local/state/agent-team/offline
  stub_sleep <<EOF2
n=\$(cat "$BATS_TEST_TMPDIR/waits" 2>/dev/null || echo 0)
echo \$((n + 1)) >"$BATS_TEST_TMPDIR/waits"
((n < 5)) || exit 143
EOF2
  run_bin -143 team-timers watch --once
  assert_equal "$output" ""
  # The same with a hold on all along.
  mkdir -p "${flag%/*}"
  echo '{"since": "2026-10-23T13:05:00Z", "posted": true}' >"$flag"
  rm "$BATS_TEST_TMPDIR/waits"
  run_bin -143 team-timers watch --once
  assert_equal "$output" ""
}

@test "enable refuses on an OS other than Linux or macOS" {
  stub_reply uname FreeBSD
  run_bin -1 --separate-stderr team-timers enable
  assert_equal "$stderr" "team-timers: FreeBSD has neither systemd nor launchd; the heartbeat runs on Linux or macOS"
}

@test "enable refuses a path the unit or plist would need escaped, and writes nothing" {
  local odd
  odd=$BATS_TEST_TMPDIR/team\&co
  mkdir "$odd"
  TEAM_HOME=$odd run_bin -1 --separate-stderr team-timers enable
  assert_equal "$stderr" "team-timers: cannot write the heartbeat's job: '$odd' holds one of % \" \\ & < > or a newline"
  [[ ! -e $units ]]
  assert_equal "$(stub_calls systemctl)" ""
}

@test "team-timers refuses a malformed command line" {
  local args
  for args in "" "start" "enable --now" "status --yes" "health --once" "health --json --json" "run now" "run --once" \
    "watch --json" "watch --once --once"; do
    # shellcheck disable=SC2086 # each case is its words
    run_bin -2 --separate-stderr team-timers $args
    assert_equal "$stderr" "team-timers: usage: team-timers enable | disable | status [--json] | health [--json] | run | watch [--once]"
  done
}

@test "no test reaches this machine's service managers: systemctl and launchctl are the sandbox's stubs" {
  assert_equal "$(command -v systemctl)" "$BATS_TEST_TMPDIR/stubs/systemctl"
  assert_equal "$(command -v launchctl)" "$BATS_TEST_TMPDIR/stubs/launchctl"
}

@test "the level step runs team-level tick after the capacity step, logging an automatic change and its post" {
  discord_answers
  fake_placement
  fake_process 100 99 - claude
  stub_reply claude '[{"pid": 100, "id": "a1b2c3d4", "name": "T7-builder", "status": "idle"}, {"id": "c0ffee00", "name": "coordinator", "status": "idle"}]'
  # Automatic mode at none for an hour, and a stored reading of the last hour each 5 minutes,
  # the other programs using 8 GiB of 32: the readings span rise_minutes, so it rises to full.
  local file=$HOME/.local/state/agent-team/capacity/readings.jsonl minutes
  mkdir -p "${file%/*}"
  for minutes in 25 20 15 10 5; do
    jq -cn --arg at "$(date -u -d "$minutes minutes ago" +%FT%TZ)" \
      '{at: $at, os: "linux", memory: {total: 34359738368, available: 25769803776, team: 0, others: 8589934592}, cpu: null}' >>"$file"
  done
  jq -cn --arg ts "$(date -u -d '1 hour ago' +%FT%TZ)" '{ts: $ts, mode: "auto", level: "none", by: "auto", machine: "home-pc"}' \
    >"$TEAM_HOME/level.jsonl"
  run_bin -0 team-timers run
  assert_equal "$output" "$(cat "$log")"
  assert_equal "$(steps "$output")" "lease checkpoint capacity level"
  [[ $(grep ' level: ' <<<"$output") =~ ^[0-9T:Z-]+" level: Resources: auto raised the team to full (90%) at "[0-9:]{5}": other programs use "[0-9.]+" GiB of 32.0 GiB; nothing needs to stow"$ ]]
  assert_equal "$(posts)" "$(grep ' level: ' <<<"$output" | cut -d ' ' -f 3- | jq -R .)"
  assert_equal "$(jq -c '[.mode, .level, .by]' <(tail -n 1 "$TEAM_HOME/level.jsonl"))" '["auto","full","auto"]'
  # The level record went into the checkpoint.
  assert_equal "$(git -C "$TEAM_HOME" log -1 --format=%s -- level.jsonl)" "$(git -C "$TEAM_HOME" log -1 --format=%s)"
  # A run with nothing to change logs nothing for it.
  run_bin -0 team-timers run
  assert_equal "$(steps "$output")" "lease checkpoint"
}

@test "a level step that fails is logged with its reason, and the steps after it still run" {
  docker_machine
  stack_json '{"heartbeat_sweep": true}'
  echo 'not a level record' >"$TEAM_HOME/level.jsonl"
  run_bin -1 team-timers run
  assert_equal "$output" "$(cat "$log")"
  assert_equal "$(steps "$output")" "lease checkpoint level stacks"
  [[ $(grep ' level: ' <<<"$output") =~ ^[0-9T:Z-]+" level: failed: $TEAM_HOME/level.jsonl has lines that are not level records ".*"line 1; fix or remove them, then run it again"$ ]]
  # The sweep after it still ran.
  assert_equal "$(docker_calls | sed -n 's/^compose -p \(.*\) stop$/\1/p')" conventioner-2
}
