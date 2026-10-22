#!/usr/bin/env bats
# team-timers: the heartbeat, one job every 5 minutes running `team-timers run`, as systemd user
# units on Linux and LaunchAgents on macOS. A stubbed uname picks the OS; the systemctl and
# launchctl stubs keep each machine's units under its own HOME (fake_service_managers), so no
# test reaches this machine's own systemd. home-pc holds the lease on a bare origin.

load helpers/common

setup() {
  sandbox
  origin=$(hold_lease home-pc)
  fake_service_managers
  cp "$REPO_ROOT/tests/helpers/stub" "$BATS_TEST_TMPDIR/stubs/uname"
  stub_reply uname Linux
  units=$HOME/.config/systemd/user agents=$HOME/Library/LaunchAgents
  log=$HOME/.local/state/agent-team/heartbeat.log
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
    "[\"bootout\",\"gui/$uid/agent-team.heartbeat\"]" "[\"bootout\",\"gui/$uid/agent-team.caffeinate\"]")"
  [[ ! -e $agents/agent-team.heartbeat.plist && ! -e $agents/agent-team.caffeinate.plist ]]
  [[ ! -e $HOME/.fake-launchd/agent-team.caffeinate ]]

  : >"$STUB_CALLS/launchctl.log"
  run_bin -0 team-timers disable
  assert_equal "$output" "the heartbeat is not installed; nothing to disable"
  assert_equal "$(stub_calls launchctl | grep -v '"print"')" ""
}

@test "status says installed, enabled and the last run from the heartbeat log; --json says the same" {
  run_bin -0 team-timers status
  assert_equal "$output" "$(printf '%s\n' 'installed: no' 'enabled: no' 'last run: never')"
  run_bin -0 team-timers status --json
  jq -e '. == {installed: false, enabled: false, last_run: null}' <<<"$output"

  run_bin -0 team-timers enable
  run_bin -0 team-timers run
  local last
  last=$(tail -n 1 "$log" | cut -d' ' -f1)
  [[ $last =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
  run_bin -0 team-timers status
  assert_equal "$output" "$(printf '%s\n' 'installed: yes' 'enabled: yes' "last run: $last")"
  run_bin -0 team-timers status --json
  jq -e --arg last "$last" '. == {installed: true, enabled: true, last_run: $last}' <<<"$output"

  # Installed but stopped is not enabled.
  rm "$HOME/.fake-systemd/agent-team-heartbeat.timer.active"
  run_bin -0 team-timers status
  assert_equal "${lines[1]}" "enabled: no"

  as_macos
  run_bin -0 team-timers status --json
  jq -e --arg last "$last" '. == {installed: false, enabled: false, last_run: $last}' <<<"$output"
  run_bin -0 team-timers enable
  run_bin -0 team-timers status --json
  jq -e '.installed and .enabled' <<<"$output"
  # Without caffeinate it is not enabled.
  launchctl bootout "gui/$(id -u)/agent-team.caffeinate"
  run_bin -0 team-timers status --json
  jq -e '.installed and (.enabled | not)' <<<"$output"
}

@test "run on the holder renews only once the last renewal is 15 minutes old" {
  local tip
  tip=$(lease_tip)
  run_bin -0 team-timers run
  assert_equal "$output" "$(tail -n 1 "$log")"
  [[ $output =~ ^[0-9T:Z-]+" lease: home-pc holds the lease, epoch 1, renewed 0 minutes ago; no renewal due"$ ]]
  assert_equal "$(lease_tip)" "$tip"

  age_lease 10
  tip=$(lease_tip)
  run_bin -0 team-timers run
  assert_contains "$output" "lease: home-pc holds the lease, epoch 1, renewed 10 minutes ago; no renewal due"
  assert_equal "$(lease_tip)" "$tip"

  age_lease 20
  tip=$(lease_tip)
  run_bin -0 team-timers run
  [[ $output =~ ^[0-9T:Z-]+" lease: home-pc renewed the lease, epoch 1"$ ]]
  [[ $(lease_tip) != "$tip" ]]
  lease_json | jq -e '.holder == "home-pc" and .epoch == 1 and (.renewed_at | fromdateiso8601) > now - 120'

  # A second run right after makes no lease commit.
  tip=$(lease_tip)
  run_bin -0 team-timers run
  assert_contains "$output" "renewed 0 minutes ago; no renewal due"
  assert_equal "$(lease_tip)" "$tip"
  assert_equal "$(wc -l <"$log")" 4
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

@test "run with GitHub unreachable logs it, exits 75 and changes nothing" {
  age_lease 20
  local tip
  tip=$(lease_tip)
  git -C "$TEAM_HOME" remote set-url origin https://127.0.0.1:9/agent-team.git
  run_bin -75 team-timers run
  [[ $output =~ ^[0-9T:Z-]+" lease: not checked: GitHub is unreachable ("[^\)]+"); showing the last known lease, unconfirmed"$ ]]
  assert_equal "$(tail -n 1 "$log")" "$output"
  assert_equal "$(lease_tip)" "$tip"
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
  seq 1 2500 | sed 's/^/2026-10-01T00:00:00Z old line /' >"$log"
  run_bin -0 team-timers run
  assert_equal "$(wc -l <"$log")" 1001
  assert_equal "$(head -n 1 "$log")" "2026-10-01T00:00:00Z old line 1501"

  local tip
  age_lease 20
  tip=$(lease_tip)
  flock "${log%/*}/heartbeat.lock" "$REPO_ROOT/bin/team-timers" run >"$BATS_TEST_TMPDIR/out" || true
  assert_contains "$(cat "$BATS_TEST_TMPDIR/out")" "run: another run is still going; skipped"
  assert_equal "$(lease_tip)" "$tip"
}

@test "enable refuses on an OS other than Linux or macOS" {
  stub_reply uname FreeBSD
  run_bin -1 --separate-stderr team-timers enable
  assert_equal "$stderr" "team-timers: FreeBSD has neither systemd nor launchd; the heartbeat runs on Linux or macOS"
}

@test "enable refuses a path the unit or plist would need escaped, and writes nothing" {
  local odd
  odd=$(realpath "$BATS_TEST_TMPDIR")/team\&co
  mkdir "$odd"
  TEAM_HOME=$odd run_bin -1 --separate-stderr team-timers enable
  assert_equal "$stderr" "team-timers: cannot write the heartbeat's job: '$odd' holds one of % \" \\ & < > or a newline"
  [[ ! -e $units ]]
  assert_equal "$(stub_calls systemctl)" ""
}

@test "team-timers refuses a malformed command line" {
  local args
  for args in "" "start" "enable --now" "status --yes" "run now"; do
    # shellcheck disable=SC2086 # each case is its words
    run_bin -2 --separate-stderr team-timers $args
    assert_equal "$stderr" "team-timers: usage: team-timers enable | disable | status [--json] | run"
  done
}

@test "no test reaches this machine's service managers: systemctl and launchctl are the sandbox's stubs" {
  assert_equal "$(command -v systemctl)" "$(realpath "$BATS_TEST_TMPDIR")/stubs/systemctl"
  assert_equal "$(command -v launchctl)" "$(realpath "$BATS_TEST_TMPDIR")/stubs/launchctl"
}
