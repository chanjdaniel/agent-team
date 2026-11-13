#!/usr/bin/env bats
# team-queue list: the room for one more task, read from team-capacity plan --json (the file
# --plan names, else its own run) and team-capacity costs --json, both a stub here, then the
# index's ranked sections; --json's team-queue/1 object, its problems and its queue-ready and
# queue findings, which the sweep appends.

load helpers/common

GIB=1073741824

setup() {
  sandbox
  queued=$TEAM_HOME/tasks/queued
  mkdir -p "$queued"
  printf 'ledger.jsonl.lock\n' >"$TEAM_HOME/.gitignore"
  cat >"$TEAM_HOME/projects.toml" <<'TOML'
[proj]
repo = "owner/proj"
path = "projects/proj"
base = "main"
delivery = "direct-pr"
merge_method = "merge"
required_checks = []
task_dir = ".scratch/task"
docs = []
toolkits = []

[proj.pool]
provider = "git"
slots = ["slots/proj/1"]
TOML
  printf '# Current items\n' >"$TEAM_HOME/tasks/current.md"
  make_team_home >/dev/null
  # team-queue runs its sibling team-capacity, so the test's own code checkout has the logging
  # stub in its place, answering from the plan and costs below.
  CODE_CHECKOUT=$BATS_TEST_TMPDIR/code
  mkdir -p "$CODE_CHECKOUT"
  copy_bin "$CODE_CHECKOUT/bin"
  shared_make stub "$REPO_ROOT/tests/helpers/stub"
  ln -f "$BATS_RUN_TMPDIR/shared/stub" "$CODE_CHECKOUT/bin/team-capacity"
  stub_script team-capacity <<'SH'
case $1 in
  plan) [[ ! -f $STUB_FIXTURES/plan.err ]] || { print_file "$STUB_FIXTURES/plan.err" >&2; exit 1; }
    print_file "$STUB_FIXTURES/plan.json" ;;
  costs) [[ ! -f $STUB_FIXTURES/costs.err ]] || { print_file "$STUB_FIXTURES/costs.err" >&2; exit 1; }
    print_file "$STUB_FIXTURES/costs.json" ;;
  *) exit 9 ;;
esac
SH
  plan
  costs
  export TEAM_QUEUE_TODAY=2026-11-13
}

# The plan team-capacity plan --json prints: at full (90%), 16.9 GiB budget, 5.2 GiB reserved,
# nothing over, stowed or refused, changed by the jq update given: plan [<update>]
plan() {
  jq -cn --argjson gib "$GIB" '{schema: "team-capacity-plan/1", mode: "manual", level: "full", share: 0.9,
      budget: (16.9 * $gib | round), reserved: (5.2 * $gib | round), over: false, confirmed: false,
      stop_sessions: [], stop_stacks: [], stow: [], resume: [], launch: []} | '"${1:-.}" >"$STUB_FIXTURES/plan.json"
}

# The costs team-capacity costs --json prints, a builder needing 1.7 GiB, changed by the jq update
# given: costs [<update>]
costs() {
  jq -cn --argjson gib "$GIB" '{schema: "team-capacity-costs/1", costs: [
      {kind: "session:planner", estimate_bytes: (0.5 * $gib | round), source: "seed", samples: 0, range: null, says: "x"},
      {kind: "session:builder", estimate_bytes: (1.7 * $gib | round), source: "learned", samples: 7, range: null, says: "x"}]}
    | '"${1:-.}" >"$STUB_FIXTURES/costs.json"
}

# Write tasks/queued/<name> with the front matter lines given, then its title: item <name> [<key>: <value>]...
item() {
  local name=$1
  shift
  { echo ---; printf '%s\n' "$@"; echo ---; echo "# ${name%.md}"; } >"$queued/$name"
}

# A ready item of project proj: ready <name> <priority> <size> <summary> [<key>: <value>]...
ready() {
  item "$1" "summary: $4" "project: proj" "priority: $2" "size: $3" "${@:5}"
}

# Append one event of <task> to the ledger at <ts>: event <task> <event> <ts> [<jq object>]
event() {
  jq -cn --arg task "$1" --arg event "$2" --arg ts "$3" '{ts: $ts, task: $task, event: $event} + '"${4:-{\}}" \
    >>"$TEAM_HOME/ledger.jsonl"
}

# list --json's object, run from the test's code checkout as run_bin runs it, its stdout alone.
listed() {
  guard_sandbox && "$CODE_CHECKOUT/bin/team-queue" list --json
}

# The room's says, from list --json.
says() {
  listed | jq -r .room.says
}

@test "the room fits only when the level, the budget, the stowed and refused work and the opened tasks allow it" {
  run_bin -0 team-queue list --json
  assert_equal "$(jq -c .room <<<"$output")" \
    '{"fits":true,"says":"room for one more task at full (90%): 11.7 GiB of 16.9 GiB free, a builder needs 1.7 GiB"}'
  plan '.level = "none" | .share = 0 | .budget = 0'
  run_bin -0 team-queue list --json
  assert_equal "$(jq -c .room <<<"$output")" '{"fits":false,"says":"no room: the level is none"}'
  plan '.over = true | .reserved = .budget * 2'
  assert_equal "$(says)" "no room: over budget"
  plan '.resume = [{task: "T171", stowed: "2026-11-13T01:00:00Z", roles: ["builder"], needs: 1, fits: true, hold: null}]
    | .launch = [{task: "T5", refused: "2026-11-13T00:00:00Z", roles: ["reviewer"], needs: 1, fits: true, hold: null}]'
  assert_equal "$(says)" "no room: T171 waits to resume"
  plan '.launch = [{task: "T5", refused: "2026-11-13T00:00:00Z", roles: ["reviewer"], needs: 1, fits: false, hold: null}]'
  assert_equal "$(says)" "no room: T5 waits to launch"
  # Stowed or refused work something holds will not be relaunched, so it takes no room first.
  plan '.resume = [{task: "T9", stowed: "2026-11-13T01:00:00Z", roles: ["builder"], needs: 1, fits: true, hold: "held: Daniel'"'"'s hold"},
      {task: "T171", stowed: "2026-11-13T02:00:00Z", roles: ["builder"], needs: 1, fits: true, hold: null}]
    | .launch = [{task: "T5", refused: "2026-11-13T00:00:00Z", roles: ["reviewer"], needs: 1, fits: true, hold: "unanswered ask a1: which?"}]'
  assert_equal "$(says)" "no room: T171 waits to resume"
  plan '.resume = [{task: "T9", stowed: "2026-11-13T01:00:00Z", roles: ["builder"], needs: 1, fits: true, hold: "held: Daniel'"'"'s hold"}]
    | .launch = [{task: "T5", refused: "2026-11-13T00:00:00Z", roles: ["reviewer"], needs: 1, fits: true, hold: "unanswered ask a1: which?"},
      {task: "T6", refused: "2026-11-13T00:00:00Z", roles: ["reviewer"], needs: 1, fits: true, hold: null}]'
  assert_equal "$(says)" "no room: T6 waits to launch"
  plan '.resume = [{task: "T9", stowed: "2026-11-13T01:00:00Z", roles: ["builder"], needs: 1, fits: true, hold: "held: Daniel'"'"'s hold"}]
    | .launch = [{task: "T5", refused: "2026-11-13T00:00:00Z", roles: ["reviewer"], needs: 1, fits: true, hold: "unanswered ask a1: which?"}]'
  assert_equal "$(says)" "room for one more task at full (90%): 11.7 GiB of 16.9 GiB free, a builder needs 1.7 GiB"
  plan '.level = "minor" | .share = 0.3 | .budget = (9.2 * '"$GIB"' | round) | .reserved = (8.3 * '"$GIB"' | round)'
  assert_equal "$(says)" "no room: 0.9 GiB free at minor (30%), a builder needs 1.7 GiB"
  # Exactly a builder's estimate free is room.
  plan '.reserved = .budget - (1.7 * '"$GIB"' | round)'
  assert_equal "$(says)" "room for one more task at full (90%): 1.7 GiB of 16.9 GiB free, a builder needs 1.7 GiB"
  plan
  # A task opened with no worker launched since holds the room until it has one; a closed one
  # never does, and one opened on an earlier day names its date.
  event T9 opened 2026-11-10T08:00:00Z '{project: "proj"}'
  event T9 closed 2026-11-10T09:00:00Z
  event T312 opened 2026-11-12T14:05:12Z '{project: "proj"}'
  event T313 opened 2026-11-13T14:05:12Z '{project: "proj"}'
  assert_equal "$(says)" "no room: T312, opened at 2026-11-12 14:05, has no worker yet"
  event T312 launch 2026-11-13T14:06:00Z '{role: "planner", session: "aaaa0001"}'
  assert_equal "$(says)" "no room: T313, opened at 14:05, has no worker yet"
  event T313 launch 2026-11-13T14:07:00Z '{role: "planner", session: "aaaa0002"}'
  assert_equal "$(says)" "room for one more task at full (90%): 11.7 GiB of 16.9 GiB free, a builder needs 1.7 GiB"
  # A task opened again after its launch has no worker for that opening.
  event T313 opened 2026-11-13T15:00:00Z '{project: "proj"}'
  assert_equal "$(says)" "no room: T313, opened at 15:00, has no worker yet"
}

@test "a plan or costs that cannot be read is no room, naming why, never a failure" {
  ready a.md 1 S "the first"
  printf 'team-capacity: %s/.config/agent-team/capacity.json: "minor_share" is not above 0 and at most 1\n' "$HOME" \
    >"$STUB_FIXTURES/plan.err"
  assert_equal "$(says)" 'no room: the plan cannot be read: team-capacity: ~/.config/agent-team/capacity.json: "minor_share" is not above 0 and at most 1'
  : >"$STUB_FIXTURES/plan.err"
  assert_equal "$(says)" "no room: the plan cannot be read: team-capacity plan failed with no reason given"
  rm "$STUB_FIXTURES/plan.err"
  plan '.budget = null | .reserved = null'
  assert_equal "$(says)" "no room: no reading of the machine's load, so no budget"
  plan
  echo "team-capacity: costs.jsonl line 3 is malformed" >"$STUB_FIXTURES/costs.err"
  assert_equal "$(says)" "no room: the costs cannot be read: team-capacity: costs.jsonl line 3 is malformed"
  rm "$STUB_FIXTURES/costs.err"
  costs '.costs |= map(select(.kind != "session:builder"))'
  assert_equal "$(says)" "no room: the costs give no builder's estimate"
  costs
  # --plan reads the file the caller holds, as the sweep's, and never runs team-capacity plan.
  rm -f "$STUB_CALLS/team-capacity.log"
  echo '{"error": "team-capacity: no session list"}' >"$BATS_TEST_TMPDIR/held.json"
  run_bin -0 team-queue list --json --plan "$BATS_TEST_TMPDIR/held.json"
  assert_equal "$(jq -r .room.says <<<"$output")" "no room: the plan cannot be read: team-capacity: no session list"
  assert_equal "$(cat "$STUB_CALLS/team-capacity.log")" '["costs","--json"]'
  echo 'not json' >"$BATS_TEST_TMPDIR/held.json"
  run_bin -0 team-queue list --plan "$BATS_TEST_TMPDIR/held.json"
  assert_equal "${lines[0]}" "no room: the plan cannot be read: $BATS_TEST_TMPDIR/held.json is no team-capacity-plan/1 object"
  run_bin -0 team-queue list --plan "$BATS_TEST_TMPDIR/none.json"
  assert_equal "${lines[0]}" "no room: the plan cannot be read: no plan at $BATS_TEST_TMPDIR/none.json"
  cp "$STUB_FIXTURES/plan.json" "$BATS_TEST_TMPDIR/held.json"
  run_bin -0 team-queue list --plan "$BATS_TEST_TMPDIR/held.json"
  assert_equal "${lines[0]}" "room for one more task at full (90%): 11.7 GiB of 16.9 GiB free, a builder needs 1.7 GiB"
  # The text form exits 0 with no room and with a problem alike.
  ready bad.md 5 S "a bad one"
  printf 'team-capacity: no reading\n' >"$STUB_FIXTURES/plan.err"
  run_bin -0 --separate-stderr team-queue list
  assert_equal "$stderr" ""
  assert_equal "${lines[0]}" "no room: the plan cannot be read: team-capacity: no reading"
}

@test "the text is the room's line, then the index's sections" {
  opened_task T5
  opened_task T7
  event T5 launch 2026-01-01T00:01:00Z '{role: "planner", session: "aaaa0005"}'
  event T7 launch 2026-01-01T00:01:00Z '{role: "planner", session: "aaaa0007"}'
  ready a-three.md 3 S "the third"
  ready b-one.md 1 M "the first" "takes: c-taken.md"
  ready c-taken.md 2 S "carried with the first"
  ready e-wait.md 1 S "a later one" "after: T7 merged"
  ready f-opened.md 2 S "in the building" "opened: T5"
  ready g-bad.md 5 S "a bad one"
  run_bin -0 --separate-stderr team-queue list
  assert_equal "$stderr" ""
  assert_equal "$output" "room for one more task at full (90%): 11.7 GiB of 16.9 GiB free, a builder needs 1.7 GiB

## Ready, ranked

1. b-one.md (proj, priority 1, M): the first
   - takes c-taken.md: carried with the first
2. a-three.md (proj, priority 3, S): the third

## Waiting

- e-wait.md (proj, priority 1, S): a later one; waits for T7 merged

## Opened

- f-opened.md (proj, T5): in the building

## Unranked

- g-bad.md: priority \"5\" is not 1, 2, 3 or 4"
  # It writes nothing: no index, no commit.
  [[ ! -e $queued/index.md ]]
  # An empty queue is the room's line alone.
  rm "$queued"/*.md
  run_bin -0 team-queue list
  assert_equal "$output" "room for one more task at full (90%): 11.7 GiB of 16.9 GiB free, a builder needs 1.7 GiB"
}


@test "--json is the team-queue/1 object, its items without the internal fields and its problems without the stale index's" {
  opened_task T5
  opened_task T7
  event T5 launch 2026-01-01T00:01:00Z '{role: "planner", session: "aaaa0005"}'
  event T7 launch 2026-01-01T00:01:00Z '{role: "planner", session: "aaaa0007"}'
  ready b-one.md 1 M "the first" "takes: c-taken.md" "guarded: ci" "from: T5"
  ready c-taken.md 2 S "carried with the first"
  ready e-wait.md 1 S "a later one" "after: T7 merged, b-one.md" "waits: Daniel's word" "alone: yes"
  ready f-opened.md 2 S "in the building" "opened: T5"
  ready g-bad.md 5 XL "a bad one"
  # The index was never written, so index --check names it stale; list leaves that line out.
  run_bin -0 --separate-stderr team-queue list --json
  assert_equal "$stderr" ""
  assert_equal "$(jq -r '.schema, (keys_unsorted | join(" "))' <<<"$output")" "team-queue/1
schema room ready waiting opened unranked problems findings"
  assert_equal "$(jq -c .ready <<<"$output")" \
    '[{"file":"b-one.md","title":"b-one","summary":"the first","project":"proj","priority":1,"size":"M","after":[],"waits":null,"from":["T5"],"opened":null,"takes":["c-taken.md"],"alone":false,"guarded":"ci","unblocks":1,"rank":1}]'
  assert_equal "$(jq -c .waiting <<<"$output")" \
    '[{"file":"e-wait.md","title":"e-wait","summary":"a later one","project":"proj","priority":1,"size":"S","after":[{"condition":"T7 merged","met":false},{"condition":"b-one.md","met":false}],"waits":"Daniel'"'"'s word","from":[],"opened":null,"takes":[],"alone":true,"guarded":null,"unblocks":0,"rank":null}]'
  assert_equal "$(jq -c '[.opened[] | {file, opened, rank}]' <<<"$output")" '[{"file":"f-opened.md","opened":"T5","rank":null}]'
  assert_equal "$(jq -c .unranked <<<"$output")" \
    '[{"file":"g-bad.md","problems":["priority \"5\" is not 1, 2, 3 or 4","size \"XL\" is not S, M or L"]}]'
  assert_equal "$(jq -c .problems <<<"$output")" \
    '[{"file":"g-bad.md","problem":"priority \"5\" is not 1, 2, 3 or 4"},{"file":"g-bad.md","problem":"size \"XL\" is not S, M or L"}]'
  run_bin -1 team-queue index --check
  assert_contains "$output" "tasks/queued/index.md: not as team-queue index writes it"
  # A registry that cannot be read is a problem of no file, first.
  mv "$TEAM_HOME/projects.toml" "$TEAM_HOME/projects.toml.away"
  run_bin -0 team-queue list --json
  assert_equal "$(jq -c '.problems[0] | {file, problem: (.problem | startswith("projects not checked: "))}' <<<"$output")" \
    '{"file":null,"problem":true}'
}

# The findings of list --json, one compact line each.
findings() {
  listed | jq -c '.findings[]'
}

@test "queue-ready names the top ready item while the room fits, and never one still waiting" {
  opened_task T7
  event T7 launch 2026-01-01T00:01:00Z '{role: "planner", session: "aaaa0007"}'
  ready c-three.md 3 S "the third"
  ready a-one.md 1 M "the first"
  ready b-two.md 2 L "the second"
  assert_equal "$(findings)" \
    '{"task":null,"kind":"queue-ready","session":null,"name":null,"next":"team-open --queued a-one.md","text":"queue: room for one more task at full (90%): 11.7 GiB of 16.9 GiB free, a builder needs 1.7 GiB: open a-one.md (proj, priority 1, M): the first; next: team-open --queued a-one.md"}'
  ready a-one.md 1 M "the first" "after: T7 merged"
  assert_equal "$(findings | jq -r .text)" \
    "queue: room for one more task at full (90%): 11.7 GiB of 16.9 GiB free, a builder needs 1.7 GiB: open b-two.md (proj, priority 2, L): the second; next: team-open --queued b-two.md"
  plan '.reserved = .budget'
  assert_equal "$(findings)" ""
  plan
  # A summary over 80 characters is cut to 80, the last three dots.
  local long
  long=$(printf 'word %.0s' {1..30})
  ready b-two.md 2 L "${long% }"
  assert_equal "$(findings | jq -r .text)" \
    "queue: room for one more task at full (90%): 11.7 GiB of 16.9 GiB free, a builder needs 1.7 GiB: open b-two.md (proj, priority 2, L): ${long:0:77}...; next: team-open --queued b-two.md"
  # Nothing ready with room is no finding.
  rm "$queued/b-two.md" "$queued/c-three.md"
  assert_equal "$(findings)" ""
}

@test "queue-ready for an item that runs alone names the project's other open tasks to hold first" {
  opened_task T5
  opened_task T7
  opened_task T9
  event T5 launch 2026-01-01T00:01:00Z '{role: "planner", session: "aaaa0005"}'
  event T7 launch 2026-01-01T00:01:00Z '{role: "planner", session: "aaaa0007"}'
  event T9 launch 2026-01-01T00:01:00Z '{role: "planner", session: "aaaa0009"}'
  event T9 closed 2026-01-01T00:02:00Z
  ready split.md 1 L "split the hot files" "alone: yes"
  assert_equal "$(findings | jq -r .text)" \
    "queue: room for one more task at full (90%): 11.7 GiB of 16.9 GiB free, a builder needs 1.7 GiB: open split.md (proj, priority 1, L): split the hot files; it runs alone: hold proj's other open tasks (T5, T7) first; next: team-open --queued split.md"
  # With none of the project's tasks open, there is nothing to hold.
  event T5 closed 2026-01-01T00:02:00Z
  event T7 closed 2026-01-01T00:02:00Z
  assert_equal "$(findings | jq -r .text)" \
    "queue: room for one more task at full (90%): 11.7 GiB of 16.9 GiB free, a builder needs 1.7 GiB: open split.md (proj, priority 1, L): split the hot files; next: team-open --queued split.md"
}

@test "queue names the problems' count and the first two, with room or not" {
  plan '.over = true'
  ready a-bad.md 5 S "a bad one"
  assert_equal "$(findings)" \
    '{"task":null,"kind":"queue","session":null,"name":null,"next":"fix each file team-queue index --check names","text":"queue: 1 problem in tasks/queued/: tasks/queued/a-bad.md: priority \"5\" is not 1, 2, 3 or 4; next: fix each file team-queue index --check names"}'
  ready b-bad.md 2 XL "another"
  item c-bad.md "summary: the third"
  assert_equal "$(findings | jq -r .text)" \
    'queue: 5 problems in tasks/queued/: tasks/queued/a-bad.md: priority "5" is not 1, 2, 3 or 4; tasks/queued/b-bad.md: size "XL" is not S, M or L; next: fix each file team-queue index --check names'
  # With room and an item ready, queue-ready comes first.
  plan
  ready d-good.md 2 S "a good one"
  assert_equal "$(findings | jq -r .kind)" "queue-ready
queue"
}

@test "list refuses a worker session, and a malformed command line is a usage error" {
  worker_refused team-queue "reads no queue" list
  worker_refused team-queue "reads no queue" list --json
  run_bin -2 team-queue list --all
  run_bin -2 team-queue list --plan
  run_bin -2 team-queue list --json --json
  run_bin -2 team-queue list --plan a --plan b
  [[ ! -e $STUB_CALLS/team-capacity.log ]]
}
