#!/usr/bin/env bats
# team-timers: the heartbeat, one job every 5 minutes running `team-timers run`, as systemd user
# units on Linux and LaunchAgents on macOS. A stubbed uname picks the OS; the systemctl and
# launchctl stubs keep each machine's units under its own HOME (fake_service_managers), so no
# test reaches this machine's own systemd. home-pc holds the lease on a bare origin.

load helpers/common
load helpers/docker
load helpers/inbox

setup() {
  sandbox
  origin=$(hold_lease home-pc)
  fake_service_managers
  stub_command uname
  stub_reply uname Linux
  units=$HOME/.config/systemd/user agents=$HOME/Library/LaunchAgents
  log=$HOME/.local/state/agent-team/heartbeat.log
  inbox_discord
  inbox_kept
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

@test "run on the holder checkpoints only once the last checkpoint is 15 minutes old" {
  local state=$HOME/.local/state/agent-team tip
  mkdir -p "$TEAM_HOME/memory/home" "$state"
  echo "- a note" >"$TEAM_HOME/memory/home/MEMORY.md"
  touch -d '-10 minutes' "$state/last-checkpoint"
  tip=$(git -C "$origin" rev-parse dev)
  run_bin -0 team-timers run
  assert_contains "$output" "lease: home-pc holds the lease"
  [[ $(tail -n 1 <<<"$output") =~ ^[0-9T:Z-]+" checkpoint: not due: the last checkpoint was 10 minutes ago (--force makes one now)"$ ]]
  assert_equal "$(git -C "$origin" rev-parse dev)" "$tip"

  touch -d '-15 minutes' "$state/last-checkpoint"
  run_bin -0 team-timers run
  [[ $(tail -n 1 <<<"$output") =~ ^[0-9T:Z-]+" checkpoint: team home: committed "[0-9a-f]+" chore: checkpoint and pushed dev"$ ]]
  assert_equal "$(git -C "$origin" diff-tree -r --no-commit-id --name-only dev)" "memory/home/MEMORY.md"
  assert_equal "$(tail -n 1 "$log")" "$(tail -n 1 <<<"$output")"

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
  [[ $(tail -n 1 <<<"$output") =~ ^[0-9T:Z-]+" checkpoint: failed: team home: not on a branch, so the records are not committed"$ ]]
  [[ ! -e $state/last-checkpoint ]]
}

@test "the inbox step edits the Waiting on you message once a run on the holder, logging only a new message or a failure, which never fails the run" {
  run_bin -0 team-timers run
  assert_equal "$(steps "$output")" "lease checkpoint"
  assert_equal "$(inbox_calls)" "PATCH channels/1562486564871995482/messages/1569000000000000000"
  assert_equal "$(inbox_items_shown)" "Nothing waits on you."

  # Deleted by hand: posted again, and that is logged.
  rm "$STUB_FIXTURES/inbox/1569000000000000000.json"
  : >"$STUB_FIXTURES/inbox/calls"
  run_bin -0 team-timers run
  assert_equal "$(steps "$output")" "lease inbox checkpoint"
  [[ $(grep ' inbox: ' <<<"$output") =~ ^[0-9T:Z-]+" inbox: posted https://discord.com/channels/$INBOX_GUILD/1562486564871995482/1569000000000000001"$ ]]
  assert_equal "$(inbox_calls)" "PATCH channels/1562486564871995482/messages/1569000000000000000
POST channels/1562486564871995482/messages"

  echo 500 >"$STUB_FIXTURES/inbox/fail"
  run_bin -0 team-timers run
  assert_equal "$(steps "$output")" "lease inbox checkpoint"
  [[ $(grep ' inbox: ' <<<"$output") =~ ^[0-9T:Z-]+" inbox: failed: Discord refused the edit of message 1569000000000000001: curl: (22) The requested URL returned error: 500"$ ]]
}

@test "the inbox step never runs off the lease, offline or on a fenced machine, and runs after the back step" {
  make_machine laptop
  on_machine laptop run_bin -0 team-timers run
  assert_equal "$(inbox_calls)" ""

  stub_sleep </dev/null
  discord_answers
  cut_origin
  run_bin -75 team-timers run
  run_bin -75 team-timers run
  assert_equal "$(inbox_calls)" ""
  git -C "$TEAM_HOME" remote set-url origin "$origin"
  run_bin -0 team-timers run
  assert_equal "$(steps "$output")" "back checkpoint"
  assert_equal "$(inbox_calls)" "PATCH channels/1562486564871995482/messages/1569000000000000000"

  steal_lease laptop home-pc
  run_bin -0 team-timers run
  assert_contains "$output" "fenced home-pc"
  run_bin -0 team-timers run
  assert_contains "$output" "home-pc is fenced since "
  assert_equal "$(inbox_calls | wc -l)" 1
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
  git -C "${1:-$TEAM_HOME}" remote set-url origin https://127.0.0.1:9/agent-team.git
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
git -C "$TEAM_HOME" remote set-url origin "$origin"
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
  jq -e '.posted == true' "$flag"
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
  git -C "$TEAM_HOME" remote set-url origin "$origin"
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
  stub_reply claude '[]'
  cut_origin
  run_bin -75 team-timers run
  assert_contains "$output" "the team is holding; the post to #coordinator failed (curl: (22) The requested URL returned error: 503); it goes with the back message"
  jq -e '.posted == false' "$HOME/.local/state/agent-team/offline"
  local since
  since=$(jq -r .since "$HOME/.local/state/agent-team/offline")

  discord_answers
  git -C "$TEAM_HOME" remote set-url origin "$origin"
  run_bin -0 team-timers run
  local back
  back=$(sed -nE 's/.* GitHub back at ([^ ]+) .*/\1/p' <<<"$output")
  assert_equal "$(posts | sed -n 2p)" "$(jq -n --arg t "GitHub unreachable since $(clock "$since") on home-pc; holding the team
GitHub back at $(clock "$back") (unreachable from $(clock "$since")); no worker was live, so none was held" '$t')"
}

@test "GitHub refusing the login (HTTP 403 or 401) is not offline: logged each run, posted once, no second try" {
  local tip
  tip=$(lease_tip)
  git -C "$TEAM_HOME" remote set-url origin "$(http_origin 403)"
  stub_sleep </dev/null
  discord_answers
  run_bin -1 team-timers run
  [[ $output =~ ^[0-9T:Z-]+" probe: GitHub refuses home-pc's login (unable to access 'http://127.0.0.1:"[0-9]+"/agent-team.git/': The requested URL returned error: 403); not offline; #coordinator is told"$ ]]
  [[ ! -e $HOME/.local/state/agent-team/offline ]]
  assert_equal "$(stub_calls sleep)" ""
  local pattern="^GitHub refuses home-pc's login \\(unable to access 'http://127.0.0.1:[0-9]+/agent-team.git/': The requested URL returned error: 403\\); the heartbeat cannot renew the lease until it is fixed there \\(team-doctor\\)$"
  [[ $(posts | jq -r .) =~ $pattern ]]

  # A credential git cannot ask for (HTTP 401) is the same refusal, and is not posted again.
  git -C "$TEAM_HOME" remote set-url origin "$(http_origin 401)"
  run_bin -1 team-timers run
  [[ $output =~ ^[0-9T:Z-]+" probe: GitHub refuses home-pc's login (could not read Username for 'http://127.0.0.1:"[0-9]+"': terminal prompts disabled); not offline"$ ]]
  assert_equal "$(posts | wc -l)" 1

  # Answering again clears it, so a later refusal is posted again.
  git -C "$TEAM_HOME" remote set-url origin "$origin"
  run_bin -0 team-timers run
  assert_contains "$(sed -n 1p <<<"$output")" " probe: GitHub accepts home-pc's login again"
  [[ ! -e $HOME/.local/state/agent-team/login-refused ]]
  assert_equal "$(lease_tip)" "$tip"
}

@test "GitHub answering 5xx is a network failure, tried again and then offline" {
  git -C "$TEAM_HOME" remote set-url origin "$(http_origin 503)"
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
  git -C "$TEAM_HOME" remote set-url origin "$origin"
  run_bin -0 team-timers run
  [[ $output =~ ^[0-9T:Z-]+" back: home-pc no longer holds the lease: laptop holds it (epoch 2); fenced home-pc: stopped coordinator (3169fcbd), T5-builder (81f08540); the heartbeat is disabled: agent-team-heartbeat.timer stopped and removed; team-lease take clears the fence"$ ]]
  [[ -e $HOME/.local/state/agent-team/fenced && ! -e $HOME/.local/state/agent-team/offline ]]
  assert_equal "$(posts | wc -l)" 1
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
  # The kept lines, then the run's lease and checkpoint lines (its usage export and its commit).
  assert_equal "$(wc -l <"$log")" 1003
  assert_equal "$(head -n 1 "$log")" "2026-10-01T00:00:00Z old line 1501"

  local tip
  age_lease 20
  tip=$(lease_tip)
  flock "${log%/*}/heartbeat.lock" "$REPO_ROOT/bin/team-timers" run >"$BATS_TEST_TMPDIR/out" || true
  assert_contains "$(cat "$BATS_TEST_TMPDIR/out")" "run: another run is still going; skipped"
  assert_equal "$(lease_tip)" "$tip"
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
  stub_reply claude '[]'
  discord_answers
}

# The steps a run's output logged, in order, each run of lines once: steps <output>
steps() {
  sed -E 's/^[^ ]+ ([a-z]+): .*$/\1/' <<<"$1" | uniq | paste -sd ' '
}

# The day's janitor report, by local date.
day_report() {
  echo "$HOME/.local/state/agent-team/janitor/$(date +%F).md"
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
  assert_equal "$(docker_calls)" ""
  [[ ! -e $HOME/.local/state/agent-team/janitor && ! -e $HOME/.local/state/agent-team/stacks ]]
}

@test "with heartbeat_sweep on, the stacks step sweeps before the checkpoint, a log line per line the sweep prints" {
  docker_machine
  stack_json '{"heartbeat_sweep": true}'
  run_bin -0 team-timers run
  assert_equal "$output" "$(cat "$log")"
  assert_equal "$(steps "$output")" "lease stacks checkpoint"
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
  calls=$(docker_calls | wc -l)
  run_bin -0 team-timers run
  assert_equal "$(steps "$output")" "lease checkpoint"
  assert_equal "$(docker_calls | wc -l)" "$calls"
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
  assert_equal "$(steps "$output")" "lease stacks checkpoint janitor"
  [[ $(grep ' stacks: ' <<<"$output") =~ ^[0-9T:Z-]+" stacks: failed: ".*"the session list is down" ]]
  assert_contains "$(grep ' janitor: ' <<<"$output")" "No alerts."
  [[ -s $(day_report) ]]

  # Docker not answering: the sweep has nothing to sweep, which it logs nothing for, and the
  # janitor fails, its report then the day's, so it is not run again that day.
  stub_reply claude '[]'
  rm "$(day_report)"
  docker_down
  run_bin -1 team-timers run
  assert_equal "$(steps "$output")" "lease checkpoint janitor"
  [[ $(tail -n 1 <<<"$output") =~ ^[0-9T:Z-]+" janitor: failed: Docker does not answer: " ]]
  assert_contains "$(grep ' janitor: ' <<<"$output" | head -n 1)" "Docker does not answer ("
  [[ -s $(day_report) ]]
  run_bin -0 team-timers run
  assert_equal "$(steps "$output")" "lease checkpoint"

  # A checkpoint that fails ends the run, as it always has: the janitor waits for the next run.
  rm "$(day_report)"
  mkdir -p "$TEAM_HOME/memory/home"
  echo "- a note" >"$TEAM_HOME/memory/home/MEMORY.md"
  git -C "$TEAM_HOME" checkout -q --detach
  touch -d '-15 minutes' "$HOME/.local/state/agent-team/last-checkpoint"
  run_bin -1 team-timers run
  assert_equal "$(steps "$output")" "lease checkpoint"
  [[ $(tail -n 1 <<<"$output") =~ " checkpoint: failed: team home: not on a branch, so the records are not committed"$ ]]
  [[ ! -e $(day_report) ]]
}

@test "a hung Docker stops each step at its time limit, logged, and the run still checkpoints and frees its lock" {
  docker_machine
  stack_json '{"heartbeat_sweep": true, "heartbeat_janitor": true}'
  docker_hang
  TEAM_TIMERS_SWEEP_SECONDS=1 TEAM_TIMERS_JANITOR_SECONDS=2 run_bin -1 team-timers run
  assert_equal "$output" "$(cat "$log")"
  assert_equal "$(steps "$output")" "lease stacks checkpoint janitor"
  [[ $(grep ' stacks: ' <<<"$output") =~ ^[0-9T:Z-]+" stacks: failed: timed out after 1 s"$ ]]
  [[ $(tail -n 1 <<<"$output") =~ ^[0-9T:Z-]+" janitor: failed: timed out after 2 s"$ ]]
  # Nothing they started is left waiting, and the janitor stopped wrote no report, so the next
  # run starts it again.
  local pid
  [[ $(grep -c . "$DOCKER_STATE/hung") == 2 ]]
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
  assert_equal "$(steps "$output")" "lease stacks checkpoint janitor"
  [[ $(grep ' stacks: ' <<<"$output") =~ ^[0-9T:Z-]+" stacks: failed: $file: heartbeat_sweep must be true or false, not \"yes\""$ ]]
  [[ $(grep ' janitor: ' <<<"$output") =~ ^[0-9T:Z-]+" janitor: failed: $file: heartbeat_sweep must be true or false, not \"yes\""$ ]]
  stack_json '{"heartbeat_sweep": true,'
  run_bin -1 team-timers run
  assert_equal "$(steps "$output")" "lease stacks checkpoint janitor"
  assert_contains "$(grep ' stacks: ' <<<"$output")" " stacks: failed: $file is not JSON: "
  stack_json '[true]'
  run_bin -1 team-timers run
  [[ $(grep ' janitor: ' <<<"$output") =~ " janitor: failed: $file is not one JSON object"$ ]]
  assert_equal "$(docker_calls)" ""
}

@test "neither step runs off the lease, while another run holds the lock, offline or on a fenced machine; both run after the back step" {
  docker_machine
  stack_json '{"heartbeat_sweep": true, "heartbeat_janitor": true}'
  local state=$HOME/.local/state/agent-team calls
  make_machine laptop
  stack_json '{"heartbeat_sweep": true, "heartbeat_janitor": true}' "$BATS_TEST_TMPDIR/machines/laptop/home"
  on_machine laptop run_bin -0 team-timers run
  assert_equal "$(steps "$output")" "lease"

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

  git -C "$TEAM_HOME" remote set-url origin "$origin"
  run_bin -0 team-timers run
  assert_equal "$(steps "$output")" "back stacks checkpoint janitor"

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
  for args in "" "start" "enable --now" "status --yes" "run now" "run --once" "watch --json" "watch --once --once"; do
    # shellcheck disable=SC2086 # each case is its words
    run_bin -2 --separate-stderr team-timers $args
    assert_equal "$stderr" "team-timers: usage: team-timers enable | disable | status [--json] | run | watch [--once]"
  done
}

@test "no test reaches this machine's service managers: systemctl and launchctl are the sandbox's stubs" {
  assert_equal "$(command -v systemctl)" "$BATS_TEST_TMPDIR/stubs/systemctl"
  assert_equal "$(command -v launchctl)" "$BATS_TEST_TMPDIR/stubs/launchctl"
}
