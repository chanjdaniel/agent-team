#!/usr/bin/env bats
# team-resume: the machine taking the team over reads the lease, runs the doctor, waits for or
# refuses another machine's fresh lease, pulls the team home, applies the config, takes the lease,
# enables the heartbeat, makes each open task's worktrees here, writes the report and starts the
# coordinator. Two machines: home-pc (this sandbox's HOME) opens T1 in a git pool project, home,
# with a live builder and a pushed commit; laptop (make_machine) resumes. The doctor is a stub
# (TEAM_DOCTOR) whose lines a test sets; claude is a stub with a session list per machine.

load helpers/common

setup() {
  sandbox
  home=$(make_repo home)
  printf '.scratch/\n' >"$home/.gitignore"
  git -C "$home" add .gitignore
  git -C "$home" commit -q -m "chore: ignore scratch"
  git -C "$home" push -q origin main
  cat >"$TEAM_HOME/projects.toml" <<'TOML'
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
slots = ["slots/home/1", "slots/home/2"]
TOML
  printf 'ledger.jsonl.lock\n' >"$TEAM_HOME/.gitignore"
  team_origin=$(hold_lease home-pc)
  stub_reply curl '{"id":"1563000000000000001"}'
  fake_service_managers
  "$REPO_ROOT/bin/team-timers" enable >/dev/null
  mkdir -p "$HOME/.claude"
  echo "Shared instructions." >"$HOME/.claude/CLAUDE.md"

  # claude: each machine's sessions in its own HOME's sessions.json; --bg adds one; stop marks
  # it stopped, rm takes it off; no plugins and no marketplaces.
  echo '[{"id": "3169fcbd", "name": "coordinator", "status": "busy"},
    {"id": "81f08540", "name": "T1-builder", "status": "idle"}]' >"$HOME/sessions.json"
  stub_script claude <<'SH'
list=$HOME/sessions.json
[[ -e $list ]] || echo '[]' >"$list"
case "$*" in
  'agents --json') cat "$list" ;;
  'stop '*) jq --arg id "$2" 'map(if .id == $id then .status = "stopped" else . end)' "$list" >"$list.next" && mv "$list.next" "$list" ;;
  'rm '*) jq --arg id "$2" 'map(select(.id != $id))' "$list" >"$list.next" && mv "$list.next" "$list" ;;
  'plugin list --json' | 'plugin marketplace list --json') echo '[]' ;;
  '--bg --name '*)
    jq --arg name "$3" '. + [{id: "7c3e9a10", name: $name, status: "idle"}]' "$list" >"$list.next" && mv "$list.next" "$list"
    echo "Started background session 7c3e9a10 ($3)" ;;
  *) echo "claude stub: unplanned call: $*" >&2; exit 64 ;;
esac
SH

  # The doctor: prints doctor.json (all PASS unless a test writes it), fails on a FAIL, and logs
  # each run with the machine's HOME.
  export TEAM_DOCTOR=$BATS_TEST_TMPDIR/doctor
  cat >"$TEAM_DOCTOR" <<'SH'
#!/usr/bin/env bash
echo "$HOME" >>"$BATS_TEST_TMPDIR/doctor.runs"
cat "$BATS_TEST_TMPDIR/doctor.json"
jq -e 'all(.verdict != "FAIL")' "$BATS_TEST_TMPDIR/doctor.json" >/dev/null
SH
  chmod +x "$TEAM_DOCTOR"
  doctor_says '{"check": "machine", "verdict": "PASS", "reason": "laptop", "fix": ""}' \
    '{"check": "lease", "verdict": "WARN", "reason": "released, epoch 1", "fix": "team-lease take"}'

  run_bin -0 team-open home feature feat work "Do the work"
  wt=$HOME/slots/home/1
  echo "spec" >"$wt/.scratch/task/spec.md"
  echo "a" >"$wt/a.txt"
  git -C "$wt" add a.txt
  git -C "$wt" commit -q -m "feat: a"
  head=$(git -C "$wt" rev-parse HEAD)

  make_machine laptop
  laptop=$BATS_TEST_TMPDIR/machines/laptop
  report=$laptop/team/tasks/resume-$(date +%F).json
}

# doctor_says <check json>...: what the doctor stub prints.
doctor_says() {
  printf '%s\n' "$@" | jq -s . >"$BATS_TEST_TMPDIR/doctor.json"
}

# home-pc hands off, as its coordinator's handoff skill runs it.
hand_off() {
  "$REPO_ROOT/bin/team-handoff" >/dev/null
}

# The coordinator launches on laptop: each claude --bg call laptop made, as JSON arguments.
coordinator_launches() {
  stub_calls claude | jq -c 'select(.[0] == "--bg")'
}

# Everything a refused resume must leave as it was on laptop: its team home's HEAD and status,
# the lease, its units, its Claude config, its slots and its reports.
laptop_state() {
  git -C "$laptop/team" rev-parse HEAD
  git -C "$laptop/team" status --porcelain
  lease_json
  find "$laptop/home/.config/systemd" "$laptop/home/.claude" "$laptop/home/slots" "$laptop/team/tasks" \
    -name sessions.json -prune -o -print 2>/dev/null | sort
}

@test "after a handoff, laptop resumes: doctor, pull, config, lease, heartbeat, worktree, report and coordinator" {
  hand_off

  on_machine laptop run_bin -0 --separate-stderr team-resume
  assert_equal "$stderr" ""
  assert_equal "${lines[0]}" "github: origin answers; the lease is released by home-pc, epoch 1"
  assert_contains "$output" "doctor: WARN lease: released, epoch 1"
  assert_contains "$output" "doctor: 1 passed, 1 warned"
  assert_contains "$output" "team home: dev fast-forwarded to $(git -C "$team_origin" rev-parse --short=7 dev)"
  assert_contains "$output" "lease: laptop holds the lease, epoch 2"
  assert_contains "$output" "heartbeat: "
  # The sandbox's paths are not under /home/<name>, so the recorded slot is not re-rooted: the
  # first free slot of laptop's pool is taken, and the move logged.
  assert_contains "$output" "T1 home: $laptop/home/slots/home/1 on feat/T1-work at ${head:0:7}, moved from $wt, scratch restored from tasks/T1/scratch"
  assert_contains "$output" "report: $report"
  assert_contains "$output" "coordinator: started, with the resume skill and the report"
  assert_equal "${lines[-1]}" "Pin the coordinator in \`claude agents\` (Ctrl+T)."

  # The doctor ran on laptop, once.
  assert_equal "$(cat "$BATS_TEST_TMPDIR/doctor.runs")" "$laptop/home"

  # The team home is origin's, with the handoff's commit; the config is applied.
  assert_equal "$(git -C "$laptop/team" rev-parse HEAD)" "$(git -C "$team_origin" rev-parse dev)"
  assert_equal "$(cat "$laptop/home/.claude/CLAUDE.md")" "Shared instructions."

  # The lease is laptop's, and its heartbeat runs.
  assert_equal "$(lease_json | jq -c '[.holder, .epoch, .state]')" '["laptop",2,"held"]'
  on_machine laptop run -0 "$REPO_ROOT/bin/team-timers" status --json
  assert_equal "$(jq -c '[.installed, .enabled]' <<<"$output")" "[true,true]"

  # The worktree is at home-pc's pushed head, with home-pc's scratch.
  assert_equal "$(git -C "$laptop/home/slots/home/1" rev-parse HEAD)" "$head"
  assert_equal "$(git -C "$laptop/home/slots/home/1" branch --show-current)" "feat/T1-work"
  assert_equal "$(cat "$laptop/home/slots/home/1/.scratch/task/spec.md")" "spec"

  # The report.
  assert_equal "$(jq -c '{machine, epoch, stolen_from}' "$report")" '{"machine":"laptop","epoch":2,"stolen_from":null}'
  assert_equal "$(jq -c '.tasks | map({task, roles: .stowed.roles, from: .stowed.machine, failures})' "$report")" \
    '[{"task":"T1","roles":["builder"],"from":"home-pc","failures":[]}]'
  assert_equal "$(jq -c '.tasks[0].worktrees' "$report")" \
    "[{\"project\":\"home\",\"branch\":\"feat/T1-work\",\"worktree\":\"$laptop/home/slots/home/1\",\"from\":\"$wt\",\"moved\":true,\"head\":\"$head\",\"archive\":\"tasks/T1/scratch\"}]"

  # The coordinator, started from laptop's team home, its prompt naming the report and the skill.
  assert_equal "$(coordinator_launches | wc -l)" 1
  assert_equal "$(coordinator_launches | jq -r '.[1:3] | join(" ")')" "--name coordinator"
  assert_equal "$(coordinator_launches | jq -r 'last')" \
    "You are the coordinator, resuming the team on laptop. Follow the \`resume\` skill with the report $report."

  # A second run finishes nothing new, and the live coordinator refuses a second start.
  on_machine laptop run_bin -1 --separate-stderr team-resume
  assert_contains "$output" "lease: laptop holds the lease, epoch 2"
  assert_contains "$stderr" "team-resume: coordinator: a coordinator is already live: session 7c3e9a10"
  assert_equal "$(lease_json | jq -c '[.holder, .epoch]')" '["laptop",2]'
  assert_equal "$(jq -c 'select(.event == "worktree-moved")' "$laptop/team/ledger.jsonl" | wc -l)" 1
}

@test "while home-pc holds a fresh lease, the resume refuses and changes nothing" {
  age_lease 4
  # home-pc has moved dev on since laptop cloned it: a pull would change laptop's team home.
  echo "note" >"$TEAM_HOME/manual-steps.md"
  git -C "$TEAM_HOME" add manual-steps.md
  git -C "$TEAM_HOME" commit -q -m "docs: a note"
  git -C "$TEAM_HOME" push -q origin dev
  local before
  before=$(laptop_state)

  on_machine laptop run_bin -1 --separate-stderr team-resume
  assert_equal "$stderr" "team-resume: home-pc holds the lease (renewed 4 min ago): say 'hand off' to the coordinator there, then run \`team-resume --wait\` here"
  assert_equal "$(laptop_state)" "$before"
  [[ ! -e $laptop/home/.claude/CLAUDE.md ]]
  assert_equal "$(coordinator_launches)" ""
}

@test "--wait reads the lease until home-pc releases it, then resumes" {
  local out=$BATS_TEST_TMPDIR/wait.out pid i
  TEAM_RESUME_POLL_SECONDS=1 on_machine laptop "$REPO_ROOT/bin/team-resume" --wait >"$out" 2>&1 3>&- &
  pid=$!
  for ((i = 0; i < 60; i++)); do
    grep -q 'waiting for its release' "$out" && break
    sleep 0.5
  done
  assert_contains "$(cat "$out")" "lease: home-pc holds the lease (renewed 0 min ago); waiting for its release, reading it every 1s (Ctrl+C stops, changing nothing)"
  # Still waiting a few reads later: nothing taken, nothing pulled.
  sleep 2
  assert_equal "$(lease_json | jq -r .holder)" home-pc
  [[ ! -e $laptop/home/.claude/CLAUDE.md ]]

  hand_off
  wait "$pid"
  assert_contains "$(cat "$out")" "lease: released by home-pc, epoch 1"
  assert_contains "$(cat "$out")" "lease: laptop holds the lease, epoch 2"
  # The pull came after the release, so laptop has the handoff's stowed.
  assert_equal "$(jq -c 'select(.event == "stowed") | .roles' "$laptop/team/ledger.jsonl")" '["builder"]'
  assert_equal "$(git -C "$laptop/home/slots/home/1" rev-parse HEAD)" "$head"
  assert_equal "$(coordinator_launches | wc -l)" 1
}

@test "a FAIL from the doctor stops the resume before the lease is touched; its lease and heartbeat lines do not" {
  hand_off
  doctor_says '{"check": "tool jq", "verdict": "FAIL", "reason": "1.6, below the minimum 1.7.1", "fix": "pacman -S jq"}' \
    '{"check": "lease", "verdict": "FAIL", "reason": "fenced since 2026-10-23T10:00:00Z", "fix": "team-resume here"}' \
    '{"check": "heartbeat", "verdict": "FAIL", "reason": "enabled, but this machine does not hold the lease", "fix": "team-timers disable"}'
  local before
  before=$(laptop_state)

  on_machine laptop run_bin -1 --separate-stderr team-resume
  assert_equal "$stderr" "team-resume: team-doctor reports what this machine lacks; fix each, then run team-resume again (nothing changed):
  FAIL tool jq: 1.6, below the minimum 1.7.1; fix: pacman -S jq"
  assert_equal "$(laptop_state)" "$before"
  assert_equal "$(coordinator_launches)" ""

  # Without the tool's FAIL, the lease and heartbeat lines are the resume's own to put right.
  doctor_says '{"check": "lease", "verdict": "FAIL", "reason": "fenced since 2026-10-23T10:00:00Z", "fix": "team-resume here"}' \
    '{"check": "heartbeat", "verdict": "FAIL", "reason": "enabled, but this machine does not hold the lease", "fix": "team-timers disable"}'
  on_machine laptop run_bin -0 team-resume
  assert_contains "$output" "doctor: 0 passed, 0 warned, lease and heartbeat left to the resume"
  assert_equal "$(lease_json | jq -c '[.holder, .state]')" '["laptop","held"]'
}

@test "offline, the resume exits 75 at its first step, before the doctor, changing nothing" {
  hand_off
  git -C "$laptop/team" remote set-url origin "https://127.0.0.1:9/agent-team.git"
  local before
  before=$(laptop_state)

  on_machine laptop run_bin -75 --separate-stderr team-resume
  assert_contains "$stderr" "team-resume: GitHub unreachable; no resume while offline"
  [[ ! -e $BATS_TEST_TMPDIR/doctor.runs ]]
  assert_equal "$(laptop_state)" "$before"
  assert_equal "$(coordinator_launches)" ""
}

@test "a task whose worktree cannot be made is in the report with the reason, and the others still resume" {
  run_bin -0 team-open home feature feat other "Other work"
  echo "spec 2" >"$HOME/slots/home/2/.scratch/task/spec.md"
  hand_off
  # laptop has its own commit on T1's branch, which origin lacks.
  local primary=$laptop/home/projects/home
  git -C "$primary" checkout -q -b feat/T1-work
  echo "mine" >"$primary/mine.txt"
  git -C "$primary" add mine.txt
  git -C "$primary" commit -q -m "feat: mine"
  git -C "$primary" checkout -q main

  on_machine laptop run_bin -1 --separate-stderr team-resume
  assert_contains "$stderr" "team-resume: T1 home: not re-homed: "
  assert_contains "$stderr" "salvage/T1-laptop"
  assert_contains "$stderr" "team-resume: 1 worktree(s) could not be re-homed; the report names each, and the coordinator says so on Discord"
  assert_contains "$output" "T2 home: $laptop/home/slots/home/1 on feat/T2-other at "
  assert_equal "$(cat "$laptop/home/slots/home/1/.scratch/task/spec.md")" "spec 2"

  assert_equal "$(jq -c '.tasks | map({task, worktrees: (.worktrees | length), failures: (.failures | map({project, branch}))})' "$report")" \
    '[{"task":"T1","worktrees":0,"failures":[{"project":"home","branch":"feat/T1-work"}]},{"task":"T2","worktrees":1,"failures":[]}]'
  assert_contains "$(jq -r '.tasks[0].failures[0].reason' "$report")" "salvage/T1-laptop"
  # The coordinator still starts, to say what did not resume.
  assert_equal "$(coordinator_launches | wc -l)" 1
}

@test "a stale lease is refused naming --steal, and --steal takes it with the holder's name typed" {
  # home-pc died without a handoff; the team's config was shared earlier.
  "$REPO_ROOT/bin/team-config" capture >/dev/null
  git -C "$TEAM_HOME" add machine
  git -C "$TEAM_HOME" commit -q -m "chore: capture the config"
  git -C "$TEAM_HOME" push -q origin dev
  age_lease 75
  on_machine laptop run_bin -1 --separate-stderr team-resume
  assert_equal "$stderr" "team-resume: home-pc holds the lease, but has not renewed it for 75 min: if home-pc is gone for good, run \`team-resume --steal\` here, typing its name when asked"
  assert_equal "$(lease_json | jq -r .holder)" home-pc

  local tty=$BATS_TEST_TMPDIR/steal-tty
  echo home-pc >"$tty"
  TEAM_LEASE_TTY=$tty on_machine laptop run_bin -0 team-resume --steal
  assert_equal "$(lease_json | jq -c '[.holder, .epoch, .stolen_from]')" '["laptop",2,"home-pc"]'
  assert_equal "$(jq -r .stolen_from "$report")" home-pc
  assert_equal "$(coordinator_launches | wc -l)" 1
}

@test "the coordinator and workers are denied typing team-resume --steal" {
  local file command
  for file in "$REPO_ROOT/coordinator.settings.json" "$REPO_ROOT/settings/worker.json"; do
    for command in "team-resume --steal" "$REPO_ROOT/bin/team-resume --steal" "TEAM_LEASE_TTY=/tmp/x bin/team-resume --steal"; do
      denied_in "$file" "$command" || { echo "${file##*/} allows: $command" >&2; return 1; }
    done
    if denied_in "$file" "team-resume --wait"; then echo "${file##*/} denies: team-resume --wait" >&2; return 1; fi
  done
}

@test "a malformed command line is a usage error, and a machine with no name is refused" {
  local args
  for args in "--now" "--wait --steal" "extra"; do
    # shellcheck disable=SC2086 # each case is its words
    on_machine laptop run_bin -2 --separate-stderr team-resume $args
    assert_contains "$stderr" "usage: team-resume [--wait | --steal]"
  done
  rm "$laptop/home/.config/agent-team/machine"
  on_machine laptop run_bin -1 --separate-stderr team-resume
  assert_contains "$stderr" "team-resume: this machine has no team name"
  run_bin -0 team-resume --help
  assert_contains "$output" "Usage: team-resume [--wait | --steal]"
}
