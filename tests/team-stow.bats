#!/usr/bin/env bats
# team-stow: the chosen tasks stowed on this machine as a handoff stows them, without releasing
# anything: their sessions stopped and removed, their stacks stopped (or downed), one checkpoint,
# their branches pushed and one stowed each with its cause; --stop-runs ends their running test
# and gate. One git-pool project, home, with a stack block, on a bare origin, its gate
# no-mistakes; home-pc holds the lease, and T1, T2 and T3 are open there, each with a live
# builder (stubbed claude), a commit not on origin and a running stack (stubbed docker).

load helpers/common
load helpers/docker

setup() {
  sandbox
  home=$(make_repo home)
  printf '.scratch/\n' >"$home/.gitignore"
  mkdir -p "$home/scripts"
  cp "$REPO_ROOT/tests/fixtures/stack/compose.sh" "$home/scripts/compose.sh"
  cp "$REPO_ROOT/tests/fixtures/stack/docker-compose.yml" "$home/docker-compose.yml"
  git -C "$home" add .gitignore scripts docker-compose.yml
  git -C "$home" commit -q -m "feat: add the stack"
  git -C "$home" push -q origin main
  home_origin=$BATS_TEST_TMPDIR/origin/home.git
  cat >"$TEAM_HOME/projects.toml" <<'TOML'
[home]
repo = "owner/home"
path = "projects/home"
base = "main"
delivery = "no-mistakes"
merge_method = "merge"
required_checks = []
task_dir = ".scratch/task"
docs = []
toolkits = []

[home.pool]
provider = "git"
slots = ["slots/home/1", "slots/home/2", "slots/home/3"]

[home.stack]
compose = "scripts/compose.sh"
seed = "scripts/seed.sh"
log_services = ["web"]
TOML
  printf 'ledger.jsonl.lock\n' >"$TEAM_HOME/.gitignore"
  team_origin=$(hold_lease home-pc)
  stub_reply curl '{"id":"1563000000000000001"}'
  docker_stub "$HOME/slots/home/1"
  capacity_room $((16 * 1024 * 1024 * 1024))

  # claude: agents --json from sessions.json; stop marks a session stopped, rm takes it off the
  # list; both fail once $STUB_FIXTURES/claude-stop-refuse exists.
  cat >"$BATS_TEST_TMPDIR/sessions.json" <<'JSON'
[{"id": "3169fcbd", "sessionId": "3169fcbd-1111", "name": "coordinator", "status": "busy", "state": "working"},
 {"id": "a1a1a1a1", "sessionId": "a1a1a1a1-1111", "name": "T1-builder", "status": "busy", "state": "working"},
 {"id": "a2a2a2a2", "sessionId": "a2a2a2a2-1111", "name": "T2-builder", "status": "idle", "state": "done"},
 {"id": "a3a3a3a3", "sessionId": "a3a3a3a3-1111", "name": "T3-builder", "status": "busy", "state": "working"},
 {"id": "44444444", "sessionId": "44444444-1111", "name": "my-T1-builder", "status": "idle", "state": "done"}]
JSON
  stub_script claude <<'SH'
list=$BATS_TEST_TMPDIR/sessions.json
case "$*" in
  'agents --json' | 'agents --json --all') cat "$list" ;;
  'stop '*) [[ ! -e $STUB_FIXTURES/claude-stop-refuse ]] || { echo "cannot stop $2" >&2; exit 1; }
    jq --arg id "$2" 'map(if .id == $id then .status = "stopped" else . end)' "$list" >"$list.next" && mv "$list.next" "$list" ;;
  'rm '*) [[ ! -e $STUB_FIXTURES/claude-stop-refuse ]] || { echo "cannot remove $2" >&2; exit 1; }
    jq --arg id "$2" 'map(select(.id != $id))' "$list" >"$list.next" && mv "$list.next" "$list" ;;
  *) echo "claude stub: unplanned call: $*" >&2; exit 64 ;;
esac
SH

  local n
  for n in 1 2 3; do
    run_bin -0 team-open home feature "feat" "work$n" "Do the work $n"
    launch "T$n" builder "a${n}a${n}a${n}a${n}" "$HOME/slots/home/$n"
    echo "spec $n" >"$HOME/slots/home/$n/.scratch/task/spec.md"
    echo "$n" >"$HOME/slots/home/$n/f$n.txt"
    git -C "$HOME/slots/home/$n" add "f$n.txt"
    git -C "$HOME/slots/home/$n" commit -q -m "feat: f$n"
    run_bin -0 team-stack up --worktree "$HOME/slots/home/$n" --no-seed
  done
  : >"$STUB_CALLS/claude.log"
  wt1=$HOME/slots/home/1 wt2=$HOME/slots/home/2 wt3=$HOME/slots/home/3
  head1=$(git -C "$wt1" rev-parse HEAD) head2=$(git -C "$wt2" rev-parse HEAD) head3=$(git -C "$wt3" rev-parse HEAD)
}

# A heavy run a failed test left (heavy_run) is stopped, so no stand-in outlives its test.
teardown() {
  [[ -e $BATS_TEST_TMPDIR/cmd && ! -e $BATS_TEST_TMPDIR/run.done ]] || return 0
  TEAM_HEAVY_KILL_SECONDS=1 "$REPO_ROOT/bin/team-heavy" stop >/dev/null 2>&1 || true
  local i
  for ((i = 0; i < 100; i++)); do [[ ! -e $BATS_TEST_TMPDIR/run.done ]] || return 0; sleep 0.1; done
  kill -KILL "$(cat "$BATS_TEST_TMPDIR/cmd")" 2>/dev/null || true
}

# Log <task>'s launch of <role> in session <id> in the worktree <wt> on home-pc, as team-worker does.
launch() {
  jq -cn --arg task "$1" --arg role "$2" --arg session "$3" --arg wt "$4" '{ts: (now | todate), task: $task,
    event: "launch", role: $role, session: $session, worktree: $wt, toolkits: [], machine: "home-pc"}' \
    >>"$TEAM_HOME/ledger.jsonl"
}

# The claude stop and rm calls, one "<verb> <id>" per line.
stops_and_removes() {
  stub_calls claude | jq -r 'select(.[0] == "stop" or .[0] == "rm") | join(" ")'
}

# The ledger's stowed events without their ts, compact, one per line.
stowed_events() {
  jq -c 'select(.event == "stowed") | del(.ts)' "$TEAM_HOME/ledger.jsonl"
}

# The stowed <task> gets on home-pc with its worktree in slot <n> at <head>, the builder's.
stowed_of() {
  jq -cn --arg task "$1" --arg branch "feat/$1-work$2" --arg head "$3" --arg cause "${4:-level}" '{task: $task,
    event: "stowed", machine: "home-pc", worktrees: [{project: "home", branch: $branch, head: $head}],
    roles: ["builder"], sessions: ["builder"], cause: $cause}'
}

# The fixture project's Compose projects whose containers run, one per line in name order.
running_stacks() {
  jq -r '[.[] | select(.State.Running) | .Config.Labels["com.docker.compose.project"]
    | select(startswith("stackfix-"))] | unique | .[]' \
    "$DOCKER_STATE/containers.json"
}

# Every ref of both origins, the session list, the ledger and the running stacks: what a refused
# or repeated stow leaves as it was.
untouched_state() {
  git -C "$team_origin" for-each-ref --format='%(objectname) %(refname)'
  git -C "$home_origin" for-each-ref --format='%(objectname) %(refname)'
  cat "$BATS_TEST_TMPDIR/sessions.json" "$TEAM_HOME/ledger.jsonl"
  running_stacks
}

@test "team-stow T1 T2 stows the two, one line per step and task, and leaves T3 alone" {
  assert_equal "$(running_stacks | paste -sd ' ')" "stackfix-1 stackfix-2 stackfix-3"

  run_bin -0 --separate-stderr team-stow T1 T2
  assert_equal "$stderr" ""
  assert_contains "$output" "lease: home-pc holds the lease, epoch 1"
  assert_contains "$output" "sessions: T1: stopped and removed T1-builder (a1a1a1a1)
sessions: T2: stopped and removed T2-builder (a2a2a2a2)
stacks: T1 home: stackfix-1 is stopped, its data kept
stacks: T2 home: stackfix-2 is stopped, its data kept
checkpoint: "
  assert_contains "$output" "branches: T1 home: pushed feat/T1-work1 at ${head1:0:7}"
  assert_contains "$output" "branches: T2 home: pushed feat/T2-work2 at ${head2:0:7}"
  assert_contains "$output" "stowed: T1 roles builder; home feat/T1-work1 at ${head1:0:7}; cause level
stowed: T2 roles builder; home feat/T2-work2 at ${head2:0:7}; cause level"
  # The checkpoint is the team home's, of every open task; no other step touches T3.
  [[ $(grep -v '^checkpoint: ' <<<"$output") != *T3* ]]

  # The sessions stop before the checkpoint, which runs once.
  [[ $output == *"sessions: T2: stopped and removed"*"checkpoint: "* ]]
  assert_equal "$(git -C "$team_origin" log --format=%s dev | grep -c '^chore: checkpoint$')" 1
  assert_equal "$(git -C "$team_origin" show dev:tasks/T2/scratch/spec.md)" "spec 2"

  assert_equal "$(stops_and_removes)" "stop a1a1a1a1
rm a1a1a1a1
stop a2a2a2a2
rm a2a2a2a2"
  assert_equal "$(running_stacks)" "stackfix-3"
  assert_equal "$(git -C "$home_origin" rev-parse feat/T1-work1 feat/T2-work2)" "$head1
$head2"
  run -1 git -C "$home_origin" rev-parse -q --verify feat/T3-work3
  assert_equal "$(stowed_events)" "$(stowed_of T1 1 "$head1")
$(stowed_of T2 2 "$head2")"
  # The lease and the heartbeat stay: nothing is released.
  assert_equal "$(lease_json | jq -r .state)" held
  assert_equal "$(jq -r '.[].name' "$BATS_TEST_TMPDIR/sessions.json" | paste -sd ' ')" "coordinator T3-builder my-T1-builder"
}

@test "run again, it changes nothing and logs no second stowed" {
  run_bin -0 team-stow T1 T2
  local before
  before=$(untouched_state)
  : >"$STUB_CALLS/claude.log"

  run_bin -0 --separate-stderr team-stow T1 T2
  assert_equal "$stderr" ""
  assert_contains "$output" "sessions: T1: no live session
sessions: T2: no live session
stacks: T1 home: stackfix-1 is stopped, its data kept
stacks: T2 home: stackfix-2 is stopped, its data kept
checkpoint: every task was stowed already, so none was made"
  assert_contains "$output" "branches: T1 home: feat/T1-work1 is on origin at ${head1:0:7}"
  assert_contains "$output" "stowed: T1 already stowed from home-pc
stowed: T2 already stowed from home-pc"
  assert_equal "$(stops_and_removes)" ""
  assert_equal "$(untouched_state)" "$before"
}

@test "--down downs the stacks, --all stows every open task, and an ops session is ended, never carried" {
  local uuid=6f93fe38-4a6e-4b35-8f39-776a26bc624b transcript
  transcript=$HOME/.claude/projects/-slots-home-3/$uuid.jsonl
  mkdir -p "$(dirname "$transcript")"
  echo '{"query": "results"}' >"$transcript"
  jq --arg uuid "$uuid" --arg wt "$wt3" '. + [{id: "6f93fe38", sessionId: $uuid, name: "T3-ops", status: "idle",
    state: "done", cwd: $wt}]' "$BATS_TEST_TMPDIR/sessions.json" >"$BATS_TEST_TMPDIR/sessions.next"
  mv "$BATS_TEST_TMPDIR/sessions.next" "$BATS_TEST_TMPDIR/sessions.json"

  run_bin -0 --separate-stderr team-stow --all --down
  assert_contains "$output" "sessions: T3: ended T3-ops with team-ops-end, its transcript and answer deleted; if its answer had not reached Daniel, Daniel asks again"
  assert_contains "$output" "sessions: T3: stopped and removed T3-builder (a3a3a3a3)"
  assert_contains "$output" "stacks: T1 home: stackfix-1 is removed, its logs in $wt1/.scratch/task/stack-logs"
  assert_contains "$output" "stacks: T3 home: stackfix-3 is removed, its logs in $wt3/.scratch/task/stack-logs"
  [[ ! -e $transcript ]]
  assert_equal "$(running_stacks)" ""
  run -1 stack_exists stackfix-2
  assert_equal "$(stowed_events)" "$(stowed_of T1 1 "$head1")
$(stowed_of T2 2 "$head2")
$(stowed_of T3 3 "$head3")"
  assert_equal "$(jq -r '.[].name' "$BATS_TEST_TMPDIR/sessions.json" | paste -sd ' ')" "coordinator my-T1-builder"
}

# Whether Docker holds any container of the Compose project <project>.
stack_exists() {
  jq -e --arg p "$1" 'any(.[]; .Config.Labels["com.docker.compose.project"] == $p)' "$DOCKER_STATE/containers.json" >/dev/null
}

@test "--cause handoff and --json: the stowed carries the cause, and the facts go to stdout with the steps on stderr" {
  run_bin -0 --separate-stderr team-stow T2 --cause handoff --json
  assert_contains "$stderr" "stowed: T2 roles builder; home feat/T2-work2 at ${head2:0:7}; cause handoff"
  assert_equal "$(jq -c . <<<"$output")" "$(jq -cn --arg head "$head2" '{tasks: [{task: "T2",
    worktrees: [{project: "home", branch: "feat/T2-work2", head: $head}], roles: ["builder"], sessions: ["builder"],
    cause: "handoff"}], refused: []}')"
  assert_equal "$(stowed_events)" "$(stowed_of T2 2 "$head2" handoff)"
}

@test "a diverged branch refuses its task before its sessions stop, and the others still stow" {
  git -C "$wt1" push -q origin feat/T1-work1
  git -C "$wt1" reset -q --hard HEAD~1
  echo "b" >"$wt1/b.txt"
  git -C "$wt1" add b.txt
  git -C "$wt1" commit -q -m "feat: b"

  run_bin -1 --separate-stderr team-stow T1 T2 --json
  assert_contains "$stderr" "team-stow: T1 is not stowed: feat/T1-work1 (home) has diverged from origin: 1 commits here and 1 there; bring it level with origin, then run team-stow again"
  assert_equal "$(jq -c '[.tasks[].task, .refused]' <<<"$output")" \
    '["T2",[{"task":"T1","reason":"feat/T1-work1 (home) has diverged from origin: 1 commits here and 1 there"}]]'
  assert_equal "$(stops_and_removes)" "stop a2a2a2a2
rm a2a2a2a2"
  assert_equal "$(running_stacks | paste -sd ' ')" "stackfix-1 stackfix-3"
  assert_equal "$(stowed_events)" "$(stowed_of T2 2 "$head2")"
}

@test "a session that will not stop refuses its task, which logs no stowed" {
  touch "$STUB_FIXTURES/claude-stop-refuse"
  run_bin -1 --separate-stderr team-stow T1
  assert_contains "$stderr" "team-stow: T1 is not stowed: could not stop T1-builder (a1a1a1a1): cannot stop a1a1a1a1"
  assert_equal "$(stowed_events)" ""
  assert_equal "$(running_stacks | paste -sd ' ')" "stackfix-1 stackfix-2 stackfix-3"
}

@test "a stack that will not stop is said, and its task still stows (exit 1)" {
  docker_down
  run_bin -1 --separate-stderr team-stow T1
  assert_contains "$stderr" "team-stow: stacks: T1 home: "
  assert_contains "$stderr" "; the task still stows"
  assert_equal "$(stowed_events)" "$(stowed_of T1 1 "$head1")"
  assert_equal "$(stops_and_removes)" "stop a1a1a1a1
rm a1a1a1a1"
}

@test "a task that is not open is refused, and the others still stow" {
  run_bin -1 --separate-stderr team-stow T9 T2
  assert_contains "$stderr" "team-stow: T9 is not stowed: it is not an open task"
  assert_equal "$(stowed_events)" "$(stowed_of T2 2 "$head2")"
}

# Run a heavy run of <task> that sleeps until it is stopped, as team-heavy.bats' stoppable does,
# and wait until it holds the lock.
heavy_run() {
  (
    AGENT_TEAM_TASK=$1 "$REPO_ROOT/bin/team-heavy" run --label "suite of $1" -- bash -c '
      echo $$ >"$0/cmd"
      while :; do sleep 0.1; done' "$BATS_TEST_TMPDIR" >/dev/null 2>&1 3>&- || true
    touch "$BATS_TEST_TMPDIR/run.done"
  ) 3>&- &
  local i
  for ((i = 0; i < 200; i++)); do
    [[ ! -e $BATS_TEST_TMPDIR/cmd ]] || return 0
    sleep 0.1
  done
  return 1
}

# The no-mistakes calls, "<directory> <arguments>" one per line.
gate_calls() {
  cat "$STUB_CALLS/no-mistakes.cwd" 2>/dev/null || true
}

@test "--stop-runs ends only the named tasks' heavy run and gate runs, and stows nothing" {
  fake_gate "$wt1" "$wt3"
  heavy_run T3

  run_bin -0 --separate-stderr team-stow T1 T2 --stop-runs
  assert_equal "$stderr" ""
  [[ $output =~ ^"stop-runs: T1: nothing to stop for T1: the heavy run is suite of T3 (pid "[0-9]+", T3) since " ]]
  assert_contains "$output" "
stop-runs: T1 home: aborted the gate's run in $wt1
stop-runs: T2: nothing to stop for T2: the heavy run is suite of T3 (pid "
  [[ $output == *"
stop-runs: T2 home: no gate run is active in $wt2" ]]
  assert_equal "$(gate_calls)" "$wt1 axi
$wt1 axi abort
$wt2 axi"
  [[ ! -e $BATS_TEST_TMPDIR/run.done ]]
  assert_equal "$(stops_and_removes)" ""
  assert_equal "$(stowed_events)" ""
  assert_equal "$(running_stacks | paste -sd ' ')" "stackfix-1 stackfix-2 stackfix-3"

  run_bin -0 team-stow T3 --stop-runs
  assert_contains "$output" "stop-runs: T3: stopped suite of T3 (pid "
  assert_contains "$output" "stop-runs: T3 home: aborted the gate's run in $wt3"
  local i
  for ((i = 0; i < 100; i++)); do [[ ! -e $BATS_TEST_TMPDIR/run.done ]] || break; sleep 0.1; done
  [[ -e $BATS_TEST_TMPDIR/run.done ]]
}

@test "a machine that does not hold the lease, or cannot reach GitHub, refuses and changes nothing" {
  local before
  before=$(untouched_state)
  make_machine laptop
  on_machine laptop run_bin -1 --separate-stderr team-stow T1
  assert_contains "$stderr" "team-stow: laptop does not hold the lease: home-pc holds it"
  assert_equal "$(untouched_state)" "$before"

  git -C "$TEAM_HOME" remote set-url origin https://127.0.0.1:9/agent-team.git
  run_bin -75 --separate-stderr team-stow T1
  assert_contains "$stderr" "team-stow: GitHub unreachable; no stow while offline"
  git -C "$TEAM_HOME" remote set-url origin "$team_origin"
  assert_equal "$(untouched_state)" "$before"
  assert_equal "$(stops_and_removes)" ""
}

@test "it refuses a malformed command line" {
  run_bin -2 team-stow
  assert_equal "$output" "team-stow: usage: team-stow (T<n>... | --all) [--down] [--cause level|handoff] [--json] | team-stow (T<n>... | --all) --stop-runs"
  run_bin -2 team-stow T1 --all
  run_bin -2 team-stow 7
  run_bin -2 team-stow T1 --cause shutdown
  run_bin -2 team-stow T1 --stop-runs --down
  run_bin -2 team-stow T1 --frobnicate
}
