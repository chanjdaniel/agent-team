#!/usr/bin/env bats
# team-resume: the machine taking the team over reads the lease, runs the doctor, waits for or
# refuses another machine's fresh lease, pulls the team home and the code checkout, applies the
# config, takes the lease, enables the heartbeat, makes each open task's worktrees here, writes the
# report and starts the coordinator. Two machines: home-pc (this sandbox's HOME) opens T1 in a git
# pool project, home, with a live builder and a pushed commit; laptop (make_machine) resumes, from
# a code checkout of the test's own (code_checkout). The doctor is a stub (TEAM_DOCTOR) whose lines
# a test sets; claude is a stub with a session list per machine.

load helpers/common
load helpers/treehouse

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

  # claude: each machine's sessions in its own HOME's sessions.json; --bg adds one, but in a root
  # listed in $BATS_TEST_TMPDIR/untrusted; stop marks it stopped, rm takes it off; no plugins and
  # no marketplaces.
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
    if grep -qxF "$PWD" "$BATS_TEST_TMPDIR/untrusted" 2>/dev/null; then
      echo "Error: Workspace not trusted. Run claude here once and accept the trust dialog." >&2
      exit 1
    fi
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
  # The live builder's launch, as team-worker logs it.
  jq -cn --arg wt "$wt" '{ts: (now | todate), task: "T1", event: "launch", role: "builder", session: "81f08540",
    worktree: $wt, toolkits: [], machine: "home-pc"}' >>"$TEAM_HOME/ledger.jsonl"

  make_machine laptop
  laptop=$BATS_TEST_TMPDIR/machines/laptop
  code_checkout
  report=$laptop/team/tasks/resume-$(date +%F).json
}

# A --wait run a failed test left waiting would hold the bats run open for good.
teardown() {
  pkill -f "$CODE_CHECKOUT/bin/team-resume" 2>/dev/null || true
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

@test "after a handoff, laptop resumes: doctor, pull, code, config, lease, heartbeat, worktree, report and coordinator" {
  hand_off

  on_machine laptop run_bin -0 --separate-stderr team-resume
  assert_equal "$stderr" ""
  assert_equal "${lines[0]}" "github: origin answers; the lease is released by home-pc, epoch 1"
  assert_contains "$output" "doctor: WARN lease: released, epoch 1"
  assert_contains "$output" "doctor: 1 passed, 1 warned"
  assert_contains "$output" "team home: dev fast-forwarded to $(git -C "$team_origin" rev-parse --short=7 dev)"
  assert_contains "$output" "code: dev is up to date at $(git -C "$CODE_ORIGIN" rev-parse --short=7 dev)"
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
  assert_equal "$(jq -c '.tasks | map({task, roles: .stowed.roles, sessions: .stowed.sessions, from: .stowed.machine, crashed, failures})' "$report")" \
    '[{"task":"T1","roles":["builder"],"sessions":["builder"],"from":"home-pc","crashed":null,"failures":[]}]'
  assert_equal "$(jq -c '.tasks[0].worktrees' "$report")" \
    "[{\"project\":\"home\",\"branch\":\"feat/T1-work\",\"worktree\":\"$laptop/home/slots/home/1\",\"from\":\"$wt\",\"moved\":true,\"head\":\"$head\",\"archive\":\"tasks/T1/scratch\",\"snapshot\":null}]"

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
  assert_equal "$stderr" "team-resume: home-pc holds the lease (renewed 4 min ago): run \`team-resume --wait\` here first, then say 'hand off' to the coordinator there once it says this machine is ready"
  assert_equal "$(laptop_state)" "$before"
  [[ ! -e $laptop/home/.claude/CLAUDE.md ]]
  assert_equal "$(coordinator_launches)" ""
}

@test "--wait, started before the handoff, says once the doctor passed that this machine is ready, then resumes on the release" {
  local out=$BATS_TEST_TMPDIR/wait.out pid i code_head moved
  # origin's code is ahead: the check before the wait says so, and moves nothing.
  code_head=$(git -C "$CODE_CHECKOUT" rev-parse HEAD)
  moved=$(push_to_dev "$CODE_ORIGIN" bin/team-new)
  TEAM_RESUME_POLL_SECONDS=1 on_machine laptop "$CODE_CHECKOUT/bin/team-resume" --wait >"$out" 2>&1 3>&- &
  pid=$!
  for ((i = 0; i < 60; i++)); do
    grep -q 'waiting for its release' "$out" && break
    sleep 0.5
  done
  # The ready line comes once, after the doctor's and the checks of both checkouts, and is
  # Daniel's cue to say "hand off".
  assert_equal "$(grep -A3 '^doctor: [0-9]' "$out")" "doctor: 1 passed, 1 warned
team home: before the wait: dev is up to date at $(git -C "$laptop/team" rev-parse --short=7 HEAD)
code: before the wait: dev can fast-forward to ${moved:0:7}
lease: home-pc holds the lease; this machine is ready: say 'hand off' to the coordinator there now (waiting for its release, reading it every 1s; Ctrl+C stops, changing nothing)"
  # Still waiting a few reads later: nothing taken, nothing pulled.
  sleep 2
  assert_equal "$(lease_json | jq -r .holder)" home-pc
  [[ ! -e $laptop/home/.claude/CLAUDE.md ]]
  assert_equal "$(git -C "$CODE_CHECKOUT" rev-parse HEAD)" "$code_head"

  hand_off
  wait "$pid"
  assert_equal "$(grep -c 'this machine is ready' "$out")" 1
  assert_contains "$(cat "$out")" "code: dev fast-forwarded to ${moved:0:7}"
  assert_contains "$(cat "$out")" "lease: released by home-pc, epoch 1"
  assert_contains "$(cat "$out")" "lease: laptop holds the lease, epoch 2"
  # The pull came after the release, so laptop has the handoff's stowed.
  assert_equal "$(jq -c 'select(.event == "stowed") | .roles' "$laptop/team/ledger.jsonl")" '["builder"]'
  assert_equal "$(git -C "$laptop/home/slots/home/1" rev-parse HEAD)" "$head"
  assert_equal "$(coordinator_launches | wc -l)" 1
}

@test "--wait, started while home-pc still holds the team, is a preflight: a doctor FAIL refuses before any wait, and nothing changes" {
  doctor_says '{"check": "trust home", "verdict": "FAIL", "reason": "claude --bg in projects/home says Workspace not trusted", "fix": "Daniel runs claude once in projects/home"}'
  local before
  before=$(laptop_state)

  on_machine laptop run_bin -1 --separate-stderr team-resume --wait
  assert_equal "$stderr" "team-resume: team-doctor reports what this machine lacks; fix each, then run team-resume again (nothing changed):
  FAIL trust home: claude --bg in projects/home says Workspace not trusted; fix: Daniel runs claude once in projects/home"
  [[ $output != *'this machine is ready'* ]]
  # home-pc still holds the team, so Daniel fixes this before saying "hand off" there.
  assert_equal "$(lease_json | jq -c '[.holder, .state]')" '["home-pc","held"]'
  assert_equal "$(laptop_state)" "$before"
  assert_equal "$(coordinator_launches)" ""
}

@test "--wait refuses before the wait a team home with commits origin's lacks, which the handoff's push would leave diverged" {
  echo "mine" >"$laptop/team/mine.md"
  git -C "$laptop/team" add mine.md
  git -C "$laptop/team" commit -q -m "docs: a commit of its own"
  local before
  before=$(laptop_state)

  on_machine laptop run_bin -1 --separate-stderr team-resume --wait
  assert_equal "$stderr" "team-resume: team home: dev has 1 commit(s) origin's lacks, which the handoff's push would leave diverged; bring it level with origin's dev, then run \`team-resume --wait\` again (checked before the wait: nothing changed, and home-pc still runs the team)"
  [[ $output != *'this machine is ready'* ]]
  assert_equal "$(lease_json | jq -c '[.holder, .state]')" '["home-pc","held"]'
  assert_equal "$(laptop_state)" "$before"
  assert_equal "$(coordinator_launches)" ""
}

@test "--wait refuses before the wait a code checkout that has diverged, or that is on a detached HEAD" {
  push_to_dev "$CODE_ORIGIN" README.md >/dev/null
  echo "mine" >"$CODE_CHECKOUT/mine.txt"
  git -C "$CODE_CHECKOUT" add mine.txt
  git -C "$CODE_CHECKOUT" commit -q -m "chore: a commit of its own"
  local before code_head
  before=$(laptop_state) code_head=$(git -C "$CODE_CHECKOUT" rev-parse HEAD)

  on_machine laptop run_bin -1 --separate-stderr team-resume --wait
  assert_contains "$output" "team home: before the wait: dev is up to date at"
  assert_equal "$stderr" "team-resume: code: dev has diverged from origin's; bring $CODE_CHECKOUT level with origin's dev, then run \`team-resume --wait\` again (checked before the wait: nothing changed, and home-pc still runs the team)"
  [[ $output != *'this machine is ready'* ]]
  assert_equal "$(git -C "$CODE_CHECKOUT" rev-parse HEAD)" "$code_head"
  assert_equal "$(lease_json | jq -c '[.holder, .state]')" '["home-pc","held"]'
  assert_equal "$(laptop_state)" "$before"

  git -C "$CODE_CHECKOUT" switch -q --detach
  on_machine laptop run_bin -1 --separate-stderr team-resume --wait
  assert_equal "$stderr" "team-resume: code: $CODE_CHECKOUT is on a detached HEAD; check out its branch, then run \`team-resume --wait\` again (checked before the wait: nothing changed, and home-pc still runs the team)"
  assert_equal "$(lease_json | jq -c '[.holder, .state]')" '["home-pc","held"]'
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

@test "an untrusted team home, where the coordinator starts, stops the resume at the doctor with nothing changed" {
  # The real doctor, whose trust team home line alone is passed on: this sandbox's machine lacks
  # what the other lines check.
  {
    echo '#!/usr/bin/env bash'
    printf 'doctor=%q\n' "$REPO_ROOT/bin/team-doctor"
    cat <<'SH'
"$doctor" --json 2>/dev/null </dev/null | jq '[.[] | select(.check == "trust team home")]' >"$BATS_TEST_TMPDIR/doctor.json"
cat "$BATS_TEST_TMPDIR/doctor.json"
jq -e 'length == 1 and all(.verdict != "FAIL")' "$BATS_TEST_TMPDIR/doctor.json" >/dev/null
SH
  } >"$TEAM_DOCTOR"
  hand_off
  echo "$laptop/team" >"$BATS_TEST_TMPDIR/untrusted"
  local before
  before=$(laptop_state)

  on_machine laptop run_bin -1 --separate-stderr team-resume
  assert_equal "$stderr" "team-resume: team-doctor reports what this machine lacks; fix each, then run team-resume again (nothing changed):
  FAIL trust team home: claude --bg in $laptop/team says Workspace not trusted; fix: Daniel runs claude once in $laptop/team and accepts the trust dialog"
  assert_equal "$(laptop_state)" "$before"
  assert_equal "$(lease_json | jq -c '[.holder, .state]')" '["home-pc","released"]'
  # Only the doctor's probes started: the team home's, and the project home's.
  assert_equal "$(coordinator_launches | jq -r '.[2]')" "team-doctor-home-trust
team-doctor-trust-home"

  # Once Daniel has trusted it, the same resume goes through, and the coordinator starts there.
  rm "$BATS_TEST_TMPDIR/untrusted"
  on_machine laptop run_bin -0 team-resume
  assert_contains "$output" "doctor: 1 passed, 0 warned"
  assert_equal "$(lease_json | jq -c '[.holder, .state]')" '["laptop","held"]'
  assert_equal "$(coordinator_launches | jq -r '.[2]' | tail -n 1)" coordinator
  [[ $(jq -r '.[].name' "$laptop/home/sessions.json") == coordinator ]]
}

@test "the code checkout's branch is fast-forwarded to origin's after the team home, before the config" {
  hand_off
  moved=$(push_to_dev "$CODE_ORIGIN" bin/team-new)

  on_machine laptop run_bin -0 --separate-stderr team-resume
  assert_equal "$stderr" ""
  assert_equal "$(grep -E '^(team home|code|config|lease): ' <<<"$output" | cut -d: -f1 | uniq | paste -sd ' ')" "team home code config lease"
  assert_contains "$output" "code: dev fast-forwarded to ${moved:0:7}"
  assert_equal "$(git -C "$CODE_CHECKOUT" rev-parse HEAD)" "$moved"
  [[ -e $CODE_CHECKOUT/bin/team-new ]]
}

@test "a code checkout that has diverged refuses the resume before the config and the lease" {
  hand_off
  push_to_dev "$CODE_ORIGIN" README.md >/dev/null
  echo "mine" >"$CODE_CHECKOUT/mine.txt"
  git -C "$CODE_CHECKOUT" add mine.txt
  git -C "$CODE_CHECKOUT" commit -q -m "chore: a commit of its own"
  before=$(git -C "$CODE_CHECKOUT" rev-parse HEAD)

  on_machine laptop run_bin -1 --separate-stderr team-resume
  assert_contains "$output" "team home: dev fast-forwarded to"
  assert_equal "$stderr" "team-resume: code: dev has diverged from origin's; bring $CODE_CHECKOUT level with origin's dev, then run team-resume again"
  assert_equal "$(git -C "$CODE_CHECKOUT" rev-parse HEAD)" "$before"
  [[ ! -e $laptop/home/.claude/CLAUDE.md ]]
  assert_equal "$(lease_json | jq -r .state)" released
  assert_equal "$(coordinator_launches)" ""
}

@test "local changes in the way refuse the resume at the code step, and others are carried along" {
  hand_off
  moved=$(push_to_dev "$CODE_ORIGIN" tool.sh)
  echo "mine" >"$CODE_CHECKOUT/tool.sh"
  before=$(git -C "$CODE_CHECKOUT" rev-parse HEAD)

  on_machine laptop run_bin -1 --separate-stderr team-resume
  assert_equal "$stderr" "team-resume: code: local changes to tool.sh are in the way; bring $CODE_CHECKOUT level with origin's dev, then run team-resume again"
  assert_equal "$(git -C "$CODE_CHECKOUT" rev-parse HEAD)" "$before"
  assert_equal "$(cat "$CODE_CHECKOUT/tool.sh")" mine

  # Out of the way, a change to another file stays, and the resume goes on.
  rm "$CODE_CHECKOUT/tool.sh"
  echo "edited" >>"$CODE_CHECKOUT/README.md"
  on_machine laptop run_bin -0 team-resume
  assert_contains "$output" "code: dev fast-forwarded to ${moved:0:7}"
  assert_equal "$(tail -n 1 "$CODE_CHECKOUT/README.md")" edited
}

@test "a code checkout on a detached HEAD refuses the resume" {
  hand_off
  git -C "$CODE_CHECKOUT" switch -q --detach

  on_machine laptop run_bin -1 --separate-stderr team-resume
  assert_equal "$stderr" "team-resume: code: $CODE_CHECKOUT is on a detached HEAD; check out its branch, then run team-resume again"
  assert_equal "$(lease_json | jq -r .state)" released
}

@test "a code checkout that is the team home is skipped, saying so" {
  hand_off
  code_checkout "$laptop/team"

  on_machine laptop run_bin -0 --separate-stderr team-resume
  assert_contains "$output" "team home: dev fast-forwarded to $(git -C "$team_origin" rev-parse --short=7 dev)"
  assert_contains "$output" "code: the code checkout is the team home, brought up to date above"
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
  assert_contains "$stderr" "salvage/home/T1-laptop"
  assert_contains "$stderr" "team-resume: 1 worktree(s) could not be re-homed; the report names each, and the coordinator says so on Discord"
  assert_contains "$output" "T2 home: $laptop/home/slots/home/1 on feat/T2-other at "
  assert_equal "$(cat "$laptop/home/slots/home/1/.scratch/task/spec.md")" "spec 2"

  assert_equal "$(jq -c '.tasks | map({task, worktrees: (.worktrees | length), failures: (.failures | map({project, branch}))})' "$report")" \
    '[{"task":"T1","worktrees":0,"failures":[{"project":"home","branch":"feat/T1-work"}]},{"task":"T2","worktrees":1,"failures":[]}]'
  assert_contains "$(jq -r '.tasks[0].failures[0].reason' "$report")" "salvage/home/T1-laptop"
  # The coordinator still starts, to say what did not resume.
  assert_equal "$(coordinator_launches | wc -l)" 1
}

@test "a treehouse slot its lease's pre-warm dirties is handed back, so each run again leases no slot more" {
  # conv, a treehouse project, with T2 open in it on home-pc.
  local conv slots=() laptop_slots=() pool=.treehouse/conv-abc123
  conv=$(make_repo conv)
  printf '.scratch/\n' >"$conv/.gitignore"
  git -C "$conv" add .gitignore
  git -C "$conv" commit -q -m "chore: ignore scratch"
  git -C "$conv" push -q origin main
  cat >>"$TEAM_HOME/projects.toml" <<TOML

[conv]
repo = "owner/conv"
path = "projects/conv"
base = "main"
delivery = "no-mistakes"
merge_method = "merge"
required_checks = []
task_dir = ".scratch/task"
docs = []
toolkits = []

[conv.pool]
provider = "treehouse"
lease = "scripts/th-lease.sh"
return = "scripts/th-return.sh"
slots = ["$pool/1/conv", "$pool/2/conv"]
TOML
  git -C "$TEAM_HOME" commit -q -m "chore: register conv" projects.toml
  git -C "$TEAM_HOME" push -q origin dev
  slots=("$HOME/$pool/1/conv" "$HOME/$pool/2/conv")
  git -C "$conv" worktree add -q --detach "${slots[0]}" origin/main
  git -C "$conv" worktree add -q --detach "${slots[1]}" origin/main
  printf '%s\n' "${slots[@]}" >"$BATS_TEST_TMPDIR/free"
  fake_pool_commands "$conv"
  run_bin -0 team-open conv feature feat move "Move it"
  git -C "${slots[0]}" push -q origin HEAD:refs/heads/feat/T2-move
  hand_off

  # laptop's clone of conv and its own pool, whose pre-warm rewrites a tracked file.
  local lconv=$laptop/home/projects/conv
  git clone -q "$BATS_TEST_TMPDIR/origin/conv.git" "$lconv" 2>/dev/null
  laptop_slots=("$laptop/home/$pool/1/conv" "$laptop/home/$pool/2/conv")
  git -C "$lconv" worktree add -q --detach "${laptop_slots[0]}" origin/main
  git -C "$lconv" worktree add -q --detach "${laptop_slots[1]}" origin/main
  printf '%s\n' "${laptop_slots[@]}" | tee "$BATS_TEST_TMPDIR/free" >"$BATS_TEST_TMPDIR/pool"
  : >"$BATS_TEST_TMPDIR/leases"
  fake_pool_commands "$lconv"
  echo 'echo rewritten >>README.md' >"$BATS_TEST_TMPDIR/prewarm"

  on_machine laptop run_bin -1 --separate-stderr team-resume
  assert_contains "$stderr" "team-resume: T2 conv: not re-homed: "
  assert_contains "$stderr" "changes to tracked files: README.md"
  assert_contains "$output" "T1 home: $laptop/home/slots/home/1 on feat/T1-work"
  assert_equal "$(pool_leases)" ""

  # Run again, as the header says a stopped resume is: the same refusal, and still no lease.
  on_machine laptop run_bin -1 --separate-stderr team-resume
  assert_contains "$stderr" "team-resume: T2 conv: not re-homed: "
  assert_equal "$(pool_leases)" ""
  assert_equal "$(git -C "${laptop_slots[0]}" status --porcelain)$(git -C "${laptop_slots[1]}" status --porcelain)" ""

  # Once the pre-warm is fixed, the next run finishes the resume in one slot.
  rm "$BATS_TEST_TMPDIR/prewarm"
  echo '[]' >"$laptop/home/sessions.json"
  on_machine laptop run_bin -0 --separate-stderr team-resume
  assert_contains "$output" "T2 conv: "
  assert_equal "$(pool_leases | wc -l)" "1"
  assert_equal "$(pool_leases | cut -d' ' -f2)" "T2"
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

@test "after home-pc crashed, --steal resumes T1 from its last checkpoint, and home-pc fences itself and lists what to salvage" {
  # The team's config was shared earlier; home-pc pushed T1's branch and launched its builder.
  "$REPO_ROOT/bin/team-config" capture >/dev/null
  git -C "$TEAM_HOME" add machine
  git -C "$TEAM_HOME" commit -q -m "chore: capture the config"
  git -C "$TEAM_HOME" push -q origin dev
  git -C "$wt" push -q origin HEAD:refs/heads/feat/T1-work
  jq -cn --arg wt "$wt" '{ts: (now | todate), task: "T1", event: "launch", role: "builder", session: "81f08540",
    worktree: $wt, toolkits: [], machine: "home-pc"}' >>"$TEAM_HOME/ledger.jsonl"
  # A checkpoint of a tracked edit and a new file.
  echo "edited" >"$wt/a.txt"
  echo "b" >"$wt/b.txt"
  run_bin -0 team-checkpoint --force
  local wip at checkpoint
  wip=$(git -C "$team_origin" rev-parse wip/home/T1)
  at=$(git -C "$team_origin" show -s --format=%ct "$wip")
  checkpoint=$(git -C "$team_origin" log -1 --format=%ct dev -- tasks/T1/scratch | jq -r 'tonumber | todate')
  # home-pc worked on, then died: no handoff, and no heartbeat run since.
  echo "later" >"$wt/a.txt"
  echo "c" >"$wt/c.txt"
  git -C "$wt" add c.txt
  git -C "$wt" commit -q -m "feat: c"
  age_lease 75

  local tty=$BATS_TEST_TMPDIR/steal-tty lt=$laptop/home/slots/home/1
  echo home-pc >"$tty"
  TEAM_LEASE_TTY=$tty on_machine laptop run_bin -0 --separate-stderr team-resume --steal
  assert_equal "$stderr" ""
  assert_equal "$(lease_json | jq -c '[.holder, .epoch, .stolen_from]')" '["laptop",2,"home-pc"]'
  assert_contains "$output" "T1 home: applied wip/home/T1 ${wip:0:7} (the checkpoint of $(jq -nr --argjson t "$at" '$t | todate')) to $lt as uncommitted changes"
  assert_contains "$output" "T1: crashed on home-pc, with no handoff since its last launch; resuming from the checkpoint of $checkpoint, to relaunch: builder"
  # The worktree is the pushed branch with the checkpoint's changes uncommitted, not the later ones.
  assert_equal "$(git -C "$lt" rev-parse HEAD)" "$head"
  assert_equal "$(git -C "$lt" status --porcelain)" "$(printf '%s\n' " M a.txt" "?? b.txt")"
  assert_equal "$(cat "$lt/a.txt")" "edited"
  [[ ! -e $lt/c.txt ]]
  # The report marks T1 crashed, with the checkpoint's time and the snapshot applied.
  [[ $checkpoint > $(jq -nr --argjson t "$at" '$t | todate') || $checkpoint == $(jq -nr --argjson t "$at" '$t | todate') ]]
  assert_equal "$(jq -c '.tasks[0] | {stowed, crashed}' "$report")" \
    "{\"stowed\":null,\"crashed\":{\"machine\":\"home-pc\",\"checkpoint\":\"$checkpoint\",\"roles\":[\"builder\"]}}"
  assert_equal "$(jq -c '.tasks[0].worktrees[0].snapshot | {commit, parent, applied, reason}' "$report")" \
    "{\"commit\":\"$wip\",\"parent\":\"$head\",\"applied\":true,\"reason\":null}"

  # home-pc boots: its heartbeat's next run finds laptop's lease and fences home-pc.
  run -0 "$REPO_ROOT/bin/team-timers" run
  [[ -e $HOME/.local/state/agent-team/fenced ]]
  # Its doctor then lists what only home-pc holds, with the commands that push it to a salvage
  # branch, and fails.
  run -1 --separate-stderr "$REPO_ROOT/bin/team-doctor" --json
  assert_equal "$(jq -c '.[] | select(.check | startswith("salvage")) | [.check, .verdict, .reason, .fix]' <<<"$output")" \
    "$(jq -cn --arg url "$team_origin" '["salvage T1 home", "FAIL",
      "~/slots/home/1 has 1 commit on no origin branch and uncommitted changes (changes to tracked files: a.txt; untracked files: b.txt)",
      "git -C ~/slots/home/1 add -A && git -C ~/slots/home/1 commit -m \"wip: salvage from home-pc\", then git -C ~/slots/home/1 push \($url) HEAD:refs/heads/salvage/home/T1-home-pc"]')"
}

@test "a crash before T1's branch was ever pushed resumes it from wip/home/T1: the branch's commits, and the checkpoint's changes uncommitted" {
  "$REPO_ROOT/bin/team-config" capture >/dev/null
  git -C "$TEAM_HOME" add machine
  git -C "$TEAM_HOME" commit -q -m "chore: capture the config"
  git -C "$TEAM_HOME" push -q origin dev
  jq -cn --arg wt "$wt" '{ts: (now | todate), task: "T1", event: "launch", role: "builder", session: "81f08540",
    worktree: $wt, toolkits: [], machine: "home-pc"}' >>"$TEAM_HOME/ledger.jsonl"
  # The builder's commit (feat: a) was never pushed; a checkpoint saw it with an uncommitted edit.
  echo "edited" >"$wt/a.txt"
  run_bin -0 team-checkpoint --force
  run -1 git -C "$BATS_TEST_TMPDIR/origin/home.git" rev-parse -q --verify refs/heads/feat/T1-work
  age_lease 75

  local tty=$BATS_TEST_TMPDIR/steal-tty lt=$laptop/home/slots/home/1
  echo home-pc >"$tty"
  TEAM_LEASE_TTY=$tty on_machine laptop run_bin -0 --separate-stderr team-resume --steal
  assert_equal "$stderr" ""
  assert_contains "$output" "T1 home: feat/T1-work is not on origin; it is taken from wip/home/T1, at ${head:0:7}"
  assert_contains "$output" "T1 home: applied wip/home/T1 "
  assert_equal "$(git -C "$lt" rev-parse HEAD)" "$head"
  assert_equal "$(git -C "$lt" log -1 --format=%s)" "feat: a"
  assert_equal "$(git -C "$lt" status --porcelain)" " M a.txt"
  assert_equal "$(jq -r '.tasks[0].worktrees[0].snapshot | "\(.parent) \(.applied)"' "$report")" "$head true"
}

@test "a crash relaunches each role whose latest launch since the last stowed nothing ended; no checkpoint is said" {
  "$REPO_ROOT/bin/team-config" capture >/dev/null
  git -C "$wt" push -q origin HEAD:refs/heads/feat/T1-work
  # A planner before an earlier handoff; since it, a builder that finished its ticket, a reviewer
  # that reviewed, then a builder and a reviewer that nothing ended.
  local event
  while IFS= read -r event; do
    jq -c --arg wt "$wt" '{ts: "2026-10-23T09:00:00Z", task: "T1"} + . | if .event == "launch" then
      . + {session: "81f08540", worktree: $wt, toolkits: [], machine: "home-pc"} else . end' <<<"$event" \
      >>"$TEAM_HOME/ledger.jsonl"
  done <<'EVENTS'
{"event": "launch", "role": "planner"}
{"event": "stowed", "machine": "home-pc", "worktrees": [], "roles": ["planner"]}
{"event": "launch", "role": "builder"}
{"event": "ticket-done", "ticket": "01", "commits": ["abc1234"]}
{"event": "launch", "role": "reviewer"}
{"event": "review", "verdict": "findings", "head": "abc1234"}
{"event": "launch", "role": "builder"}
{"event": "launch", "role": "reviewer"}
EVENTS
  git -C "$TEAM_HOME" add ledger.jsonl machine
  git -C "$TEAM_HOME" commit -q -m "chore: the ledger"
  git -C "$TEAM_HOME" push -q origin dev
  age_lease 75

  local tty=$BATS_TEST_TMPDIR/steal-tty
  echo home-pc >"$tty"
  TEAM_LEASE_TTY=$tty on_machine laptop run_bin -0 --separate-stderr team-resume --steal
  assert_contains "$output" "T1 home: wip/home/T1 not applied: the team home's origin has no wip/home/T1: no checkpoint saved this task's work"
  assert_contains "$output" "T1: crashed on home-pc, with no handoff since its last launch; no checkpoint of it was found, to relaunch: builder, reviewer"
  assert_equal "$(jq -c '.tasks[0].crashed' "$report")" '{"machine":"home-pc","checkpoint":null,"roles":["builder","reviewer"]}'
  assert_equal "$(git -C "$laptop/home/slots/home/1" status --porcelain)" ""
}

@test "a crashed task whose last launch was ops lists no role to relaunch: Daniel asks again" {
  "$REPO_ROOT/bin/team-config" capture >/dev/null
  git -C "$wt" push -q origin HEAD:refs/heads/feat/T1-work
  # A planner before an earlier handoff; since it, only an ops session on Daniel's request.
  local event
  while IFS= read -r event; do
    jq -c --arg wt "$wt" '{ts: "2026-10-23T09:00:00Z", task: "T1"} + . | if .event == "launch" then
      . + {session: "81f08540", worktree: $wt, toolkits: [], machine: "home-pc"} else . end' <<<"$event" \
      >>"$TEAM_HOME/ledger.jsonl"
  done <<'EVENTS'
{"event": "launch", "role": "planner"}
{"event": "stowed", "machine": "home-pc", "worktrees": [], "roles": ["planner"]}
{"event": "launch", "role": "ops", "toolkits": ["prod-read"], "request": "https://discord.com/channels/1/2/3"}
EVENTS
  git -C "$TEAM_HOME" add ledger.jsonl machine
  git -C "$TEAM_HOME" commit -q -m "chore: the ledger"
  git -C "$TEAM_HOME" push -q origin dev
  age_lease 75

  local tty=$BATS_TEST_TMPDIR/steal-tty
  echo home-pc >"$tty"
  TEAM_LEASE_TTY=$tty on_machine laptop run_bin -0 --separate-stderr team-resume --steal
  assert_contains "$output" "T1: crashed on home-pc, with no handoff since its last launch; no checkpoint of it was found, to relaunch: no role"
  assert_equal "$(jq -c '.tasks[0].crashed.roles' "$report")" '[]'
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
