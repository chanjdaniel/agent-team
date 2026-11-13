#!/usr/bin/env bats
# team-snapshot: everything open across the team in one view: every open task's state, the live
# team sessions and strays, open PRs in every registered project, the asks waiting on Daniel, and
# the coordinator's current items (tasks/current.md).

load helpers/common

setup() {
  sandbox
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
slots = ["slots/proj/1", "slots/proj/2"]

[conv]
repo = "owner/conv"
path = "projects/conv"
base = "dev"
delivery = "no-mistakes"
merge_method = "merge"
required_checks = []
task_dir = ".scratch/task"
docs = []
toolkits = []

[conv.pool]
provider = "git"
slots = ["slots/conv/1"]
TOML
  stub_reply claude '[]'
  github
  head=a1b2c3d4e5f60718293a4b5c6d7e8f9012345678
}

# ledger_line [jq options...] <filter>: append the line jq builds, standing in for its writer.
ledger_line() {
  jq -cn "$@" >>"$TEAM_HOME/ledger.jsonl"
}

# event <task> <kind> [<jq object of more fields>]
event() {
  ledger_line --arg t "$1" --arg e "$2" "{ts: \"2026-10-22T02:00:00Z\", task: \$t, event: \$e} + (${3:-{\}})"
}

# opened <task> [<project>]
opened() {
  event "$1" opened "{project: \"${2:-proj}\", path: \"feature\", type: \"feat\", title: \"Work\",
    branch: \"feat/$1-work\", base: \"main\", base_sha: \"0123456\", worktree: \"/w/1\"}"
}

# launch <task> <role> <session>
launch() {
  event "$1" launch "{role: \"$2\", session: \"$3\", worktree: \"/w/1\", toolkits: []}"
}

# session <short id> <name> <status> [<state>]: one background session as claude agents --json
# lists it.
session() {
  jq -cn --arg id "$1" --arg name "$2" --arg status "$3" --arg state "${4:-}" \
    '{pid: 4242, cwd: "/w/1", kind: "background", startedAt: 1761098400000,
      sessionId: "\($id)-1111-4222-8333-444455556666", name: $name, status: $status, id: $id,
      state: (if $state == "" then null else $state end)}'
}

# sessions <session JSON>...: the live session list.
sessions() {
  stub_reply claude "$(jq -cs . <<<"$*")"
}

# github: gh answers from files in $STUB_FIXTURES: prs-<owner>_<repo> for gh pr list (a repo
# with no file fails like GitHub down), view-<n> for gh pr view, checks-<n> for both
# gh pr checks calls (an empty list when absent), and compare for gh api's compare of a base and
# head (failing when absent).
github() {
  stub_script gh <<'EOF'
repo='' number=''
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  [[ ${args[i]} == --repo ]] && repo=${args[i + 1]}
done
[[ ${3:-} =~ ^[0-9]+$ ]] && number=$3
case "$1 $2" in
  "pr list")
    file=$STUB_FIXTURES/prs-${repo//\//_}
    if [[ -f $file ]]; then cat "$file"; else echo "HTTP 502: Bad Gateway (https://api.github.com/graphql)" >&2; exit 1; fi ;;
  "pr view")
    file=$STUB_FIXTURES/view-$number
    if [[ -f $file ]]; then cat "$file"; else echo "error connecting to api.github.com" >&2; exit 1; fi ;;
  "pr checks") cat "$STUB_FIXTURES/checks-$number" 2>/dev/null || echo '[]' ;;
  "api repos/"*/compare/*)
    if [[ -f $STUB_FIXTURES/compare ]]; then cat "$STUB_FIXTURES/compare"; else echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi ;;
  *) echo "unplanned gh call: $*" >&2; exit 1 ;;
esac
EOF
}

# open_prs <owner/repo> <JSON list as gh pr list --json prints it>
open_prs() {
  printf '%s\n' "$2" >"$STUB_FIXTURES/prs-${1//\//_}"
}

# pr_json <number> <branch> <title> [<draft>]: one PR as gh pr list --json prints it.
pr_json() {
  jq -cn --argjson n "$1" --arg branch "$2" --arg title "$3" --argjson draft "${4:-false}" \
    '{number: $n, title: $title, url: "https://github.com/owner/proj/pull/\($n)", headRefName: $branch,
      baseRefName: "main", isDraft: $draft}'
}

# pr_event <task> <number>: the task's PR in owner/proj, open on GitHub at $head.
pr_event() {
  event "$1" pr "{url: \"https://github.com/owner/proj/pull/$2\", head: \"$head\"}"
  jq -cn --argjson n "$2" --arg head "$head" '{number: $n, state: "OPEN", baseRefName: "main", headRefOid: $head}' \
    >"$STUB_FIXTURES/view-$2"
}

# reserve_agent_team: register agent-team with the code checkout as its primary, with no open PRs.
reserve_agent_team() {
  code_checkout
  mkdir -p "$HOME/projects"
  ln -s "$CODE_CHECKOUT" "$HOME/projects/agent-team"
  printf '%s\n' '' '[agent-team]' 'repo = "owner/agent-team"' 'path = "projects/agent-team"' 'base = "dev"' \
    'delivery = "direct-pr"' 'merge_method = "merge"' 'required_checks = []' 'task_dir = ".scratch/task"' 'docs = []' \
    'toolkits = []' '[agent-team.pool]' 'provider = "git"' 'slots = ["slots/agent-team/1"]' >>"$TEAM_HOME/projects.toml"
  open_prs owner/agent-team '[]'
}

fixture_ledger() {
  cat "$BATS_TEST_DIRNAME/fixtures/ledger-$1.jsonl" >>"$TEAM_HOME/ledger.jsonl"
}

# The lines of the text form under the heading that starts with <heading>, up to the next
# heading.
section() {
  awk -v heading="$1" 'index($0, heading) == 1 { on = 1; print; next } /^[^ ]/ { on = 0 } on' <<<"$output"
}

@test "open tasks are those with events and no closed, each with its team-state line, in number order" {
  opened T12
  launch T12 builder 59709d99
  opened T3
  opened T4
  event T4 closed '{archive: [], returned: [], kept: []}'
  launch T20 planner 3ed2d1f2
  sessions "$(session 59709d99 T12-builder idle blocked)"
  run_bin -0 team-snapshot
  # T12's builder launch put it in building (the lifecycle's launch rule).
  local tasks
  tasks=$(section "Open tasks")
  assert_equal "$tasks" "Open tasks (3):
  T3 proj feature planning | no live worker
  T12 proj feature building | T12-builder idle blocked
  T20 planning | no live worker"
  run_bin -0 team-state T12
  assert_contains "$tasks" "  $output"
}

@test "--json carries a schema and each open task's team-state JSON" {
  opened T3
  launch T3 builder 59709d99
  event T3 plan-approved '{by: "Daniel"}'
  pr_event T3 5
  echo '[{"name": "test", "bucket": "pass", "state": "SUCCESS"}]' >"$STUB_FIXTURES/checks-5"
  opened T4
  sessions "$(session 59709d99 T3-builder busy working)"
  run_bin -0 team-snapshot --json
  local snapshot=$output
  assert_equal "$(jq -r .schema <<<"$snapshot")" "team-snapshot/1"
  assert_equal "$(jq -c 'keys_unsorted' <<<"$snapshot")" '["schema","tasks","level","awaiting_resume","resources","default_withdrawn","production","denials","sessions","strays","prs","pending_asks","waiting","items","queued"]'
  assert_equal "$(jq -r '.tasks | map(.task) | join(" ")' <<<"$snapshot")" "T3 T4"
  run_bin -0 team-state T3 --json
  assert_equal "$(jq -c '.tasks[0]' <<<"$snapshot")" "$(jq -c . <<<"$output")"
  assert_equal "$(jq -c '.tasks[0].pr | [.number, .checks.passed]' <<<"$snapshot")" '[5,["test"]]'
  run_bin -0 team-state T4 --json
  assert_equal "$(jq -c '.tasks[1]' <<<"$snapshot")" "$(jq -c . <<<"$output")"
}

@test "the live team sessions follow the resources line, with no withdrawal standing, no slots line or key, and no reading taken" {
  reserve_agent_team
  mkdir -p "$HOME/.config/agent-team"
  echo home-pc >"$HOME/.config/agent-team/machine"
  open_prs owner/proj '[]'
  open_prs owner/conv '[]'
  opened T3
  opened T4 conv
  run_bin -0 team-snapshot
  assert_equal "$(head -n 5 <<<"$output")" "Open tasks (2):
  T3 proj feature planning | no live worker
  T4 conv feature planning | no live worker
Resources: manual, full (90%): no reading of the machine's load yet, so no budget
Live team sessions: none"
  run_bin -0 team-snapshot --json
  assert_equal "$(jq -c 'has("slots")' <<<"$output")" false
  [[ ! -e $HOME/.local/state/agent-team ]]
}

# passed <task> <number>: the task's PR <number> in owner/proj reviewed and passed at $head.
passed() {
  pr_event "$1" "$2"
  event "$1" review "{verdict: \"pass\", head: \"$head\", findings: {blocking: 0, correctness: 0, security: 0, \"real-data\": 0, \"note-change\": 0, \"note-before\": 0}, guarded: []}"
}

# ci <task> <number> <outcome>: team-next <task> --ci's end on PR <number> at $head, at 03:00.
ci() {
  ledger_line --arg t "$1" --arg url "https://github.com/owner/proj/pull/$2" --arg head "$head" --arg o "$3" \
    '{ts: "2026-10-22T03:00:00Z", task: $t, event: "ci", url: $url, head: $head, outcome: $o}'
}

@test "each pass whose checks no wait has ended is a checks wait to arm, after the open tasks; none is no line" {
  open_prs owner/proj '[]'
  open_prs owner/conv '[]'
  # No pass, and a pass whose checks passed or failed: nothing to arm.
  opened T3
  opened T5
  passed T5 7
  ci T5 7 passed
  opened T6
  passed T6 8
  ci T6 8 failed
  run_bin -0 team-snapshot
  [[ $output != *"Checks waits"* ]]
  assert_equal "$(sed -n 4p <<<"$output")" "  T6 proj feature awaiting-merge | no live worker | review 1 pass | PR #8 a1b2c3d checks 0/0 agent-review missing | checks failed"
  assert_contains "$(sed -n 5p <<<"$output")" "Resources: "

  # T3's pass waits with no wait ended, and T4's wait ended at its deadline: both are to arm, in
  # task number order, after the open tasks and before the resources line.
  passed T3 5
  opened T4
  passed T4 6
  ci T4 6 pending
  run_bin -0 team-snapshot
  assert_equal "$(sed -n '6,7p' <<<"$output")" \
    "Checks waits to arm unless running: team-next T3 --ci (https://github.com/owner/proj/pull/5 at a1b2c3d4, since 2026-10-22T02:00:00Z)
Checks waits to arm unless running: team-next T4 --ci (https://github.com/owner/proj/pull/6 at a1b2c3d4, since 2026-10-22T03:00:00Z)"
  assert_contains "$(sed -n 8p <<<"$output")" "Resources: "
  run_bin -0 team-snapshot --json
  assert_equal "$(jq -c '[.tasks[] | [.task, .checks_wait.state]]' <<<"$output")" \
    '[["T3","waiting"],["T4","pending"],["T5","passed"],["T6","failed"]]'
}

@test "the resources line follows the open tasks, naming the tasks stowed, waiting to resume, and --json carries it" {
  open_prs owner/proj '[]'
  open_prs owner/conv '[]'
  # Manual minor on a 32 GiB machine with 12 GiB left to the team: 9.6 GiB and 3.6 cores.
  capacity_room $((12 * 1073741824)) minor
  export TEAM_READING_CPUS=12
  opened T3
  # T4 and T6 were stowed for the level and T5 for a handoff, all three waiting to resume; T7 was
  # relaunched since, and T8's stow left no role to relaunch.
  local task
  for task in T4 T5 T6 T7 T8; do opened "$task"; done
  event T4 stowed '{machine: "home-pc", worktrees: [], roles: ["builder"], cause: "level"}'
  event T5 stowed '{machine: "home-pc", worktrees: [], roles: ["builder"], cause: "handoff"}'
  event T6 stowed '{machine: "home-pc", worktrees: [], roles: ["reviewer"], cause: "level"}'
  event T7 stowed '{machine: "home-pc", worktrees: [], roles: ["builder"], cause: "level"}'
  launch T7 builder 77777777
  event T8 stowed '{machine: "home-pc", worktrees: [], roles: [], cause: "level"}'
  run_bin -0 team-snapshot
  # Whole up to 200 columns, as a current item is, so no task it names is cut.
  assert_equal "$(sed -n 8p <<<"$output")" \
    "Resources: manual, minor (30%): 9.6 GiB and 3.6 cores for the team; 0.0 GiB reserved; T4, T5 and T6 stowed, waiting to resume"
  run_bin -0 team-snapshot --json
  local snapshot=$output
  run_bin -0 team-level status --stored --json
  assert_equal "$(jq -c '.level | del(.reading.at, .last_change.ts)' <<<"$snapshot")" "$(jq -c 'del(.reading.at, .last_change.ts)' <<<"$output")"
  assert_equal "$(jq -c '[.awaiting_resume, .resources]' <<<"$snapshot")" \
    '[["T4","T5","T6"],"Resources: manual, minor (30%): 9.6 GiB and 3.6 cores for the team; 0.0 GiB reserved; T4, T5 and T6 stowed, waiting to resume"]'
}

@test "a team-level that fails gives level its error, the text says the resources are unreadable, and the rest is as before" {
  open_prs owner/proj '[]'
  open_prs owner/conv '[]'
  opened T3
  echo 'not json' >"$TEAM_HOME/level.jsonl"
  run_bin -1 --separate-stderr team-level status --stored
  local error=$stderr
  assert_contains "$error" "level.jsonl"
  run_bin -0 --separate-stderr team-snapshot --json
  assert_equal "$stderr" ""
  assert_equal "$(jq -c '[.level, .resources, .awaiting_resume]' <<<"$output")" "$(jq -cn --arg error "$(tail -n 1 <<<"$error")" '[{error: $error}, null, []]')"
  assert_equal "$(jq -c '.tasks | length' <<<"$output")" 1
  # Cut at 200 columns, as on macOS, whose longer temporary paths make it longer.
  run_bin -0 team-snapshot
  assert_equal "$(sed -n 3p <<<"$output")" \
    "$(jq -rn --arg line "Resources unreadable: $(tail -n 1 <<<"$error")" '$line | if length > 200 then .[:197] + "..." else . end')"
}

@test "the session list is read once, and every open task's PR part comes from GitHub" {
  for task in T3 T4 T5; do opened "$task"; done
  pr_event T3 5
  pr_event T5 7
  run_bin -0 team-snapshot --json
  assert_equal "$(stub_calls claude)" '["agents","--json"]'
  assert_equal "$(jq -c '[.tasks[] | .pr.number]' <<<"$output")" '[5,null,7]'
  assert_equal "$(stub_calls gh | jq -sc 'map(select(.[1] == "view") | .[2]) | sort')" '["5","7"]'
}

@test "live team sessions are listed with their task, and strays (closed or unknown task) apart" {
  opened T3
  launch T3 builder 59709d99
  opened T4
  event T4 closed '{archive: [], returned: [], kept: []}'
  opened T12
  sessions "$(session 59709d99 T3-builder busy working)" \
    "$(session 3ed2d1f2 T12-reviewer idle blocked)" \
    "$(session 77777777 T4-builder idle)" \
    "$(session 88888888 T99-planner busy working)" \
    "$(session 99999999 T0-planner idle)" \
    '{"pid": 1, "cwd": "/home", "kind": "interactive", "sessionId": "194f5a85-f4b2", "name": "me", "status": "idle"}' \
    "$(session aaaaaaaa coordinator busy working)"
  run_bin -0 team-snapshot --json
  assert_equal "$(jq -c .sessions <<<"$output")" "$(jq -cn '[
    {task: "T3", role: "builder", name: "T3-builder", session: "59709d99", status: "busy", state: "working", logged: true},
    {task: "T12", role: "reviewer", name: "T12-reviewer", session: "3ed2d1f2", status: "idle", state: "blocked", logged: false}]')"
  assert_equal "$(jq -c .strays <<<"$output")" "$(jq -cn '[
    {task: "T4", role: "builder", name: "T4-builder", session: "77777777", status: "idle", state: null, task_state: "closed"},
    {task: "T99", role: "planner", name: "T99-planner", session: "88888888", status: "busy", state: "working", task_state: "unknown"},
    {task: "T0", role: "planner", name: "T0-planner", session: "99999999", status: "idle", state: null, task_state: "load-check"}]')"

  run_bin -0 team-snapshot
  assert_equal "$(section "Live team sessions")" "Live team sessions (2):
  T3-builder 59709d99 busy
  T12-reviewer 3ed2d1f2 idle blocked (no launch of it in the ledger)"
  assert_equal "$(section "Stray sessions")" "Stray sessions (3):
  T4-builder 77777777 idle: T4 is closed
  T99-planner 88888888 busy: T99 is not in the ledger
  T0-planner 99999999 idle: T0 is the load check's, stray unless one is running"
}

@test "open PRs come from gh pr list for each registered project, with their task from the branch" {
  opened T3
  open_prs owner/proj "[$(pr_json 5 feat/T3-work "The work"), $(pr_json 6 chore/deps "Bump deps" true)]"
  open_prs owner/conv '[]'
  run_bin -0 team-snapshot --json
  assert_equal "$(jq -c .prs <<<"$output")" "$(jq -cn '[
    {project: "proj", repo: "owner/proj", prs: [
      {number: 5, title: "The work", url: "https://github.com/owner/proj/pull/5", branch: "feat/T3-work", base: "main", draft: false, task: "T3"},
      {number: 6, title: "Bump deps", url: "https://github.com/owner/proj/pull/6", branch: "chore/deps", base: "main", draft: true, task: null}]},
    {project: "conv", repo: "owner/conv", prs: []}]')"
  assert_equal "$(stub_calls gh | jq -sc 'map(select(.[1] == "list")) | sort')" \
    '[["pr","list","--repo","owner/conv","--state","open","--limit","100","--json","number,title,url,headRefName,baseRefName,isDraft"],["pr","list","--repo","owner/proj","--state","open","--limit","100","--json","number,title,url,headRefName,baseRefName,isDraft"]]'

  run_bin -0 team-snapshot
  assert_equal "$(section "Open PRs")" "Open PRs:
  proj (owner/proj):
    #5 feat/T3-work: The work
    #6 chore/deps (draft): Bump deps
  conv (owner/conv): none"
}

@test "a failing gh marks that project's PRs as unavailable and the rest is complete" {
  opened T3
  launch T3 builder 59709d99
  event T3 asked '{id: "q1", text: "Which name?"}'
  open_prs owner/conv "[$(pr_json 9 fix/T3-bug "The bug")]"
  sessions "$(session 59709d99 T3-builder busy working)"
  run_bin -0 --separate-stderr team-snapshot --json
  assert_equal "$stderr" ""
  assert_equal "$(jq -c '.prs[0]' <<<"$output")" \
    '{"project":"proj","repo":"owner/proj","error":"gh pr list: HTTP 502: Bad Gateway (https://api.github.com/graphql)"}'
  assert_equal "$(jq -c '[.prs[1].prs[0].number, (.tasks | length), (.sessions | length), (.pending_asks | length)]' <<<"$output")" \
    '[9,1,1,1]'

  run_bin -0 team-snapshot
  assert_equal "$(section "Open PRs")" "Open PRs:
  proj (owner/proj): GitHub unavailable (gh pr list: HTTP 502: Bad Gateway (https://api.github.com/graphql))
  conv (owner/conv):
    #9 fix/T3-bug: The bug"
}

@test "a task whose PR cannot be read says GitHub unavailable, and the snapshot still succeeds" {
  opened T3
  event T3 pr '{url: "https://github.com/owner/proj/pull/5", head: "1234567"}'
  run_bin -0 team-snapshot
  assert_equal "$(section "Open tasks")" "Open tasks (1):
  T3 proj feature in-review | no live worker | PR #5 GitHub unavailable"
}

@test "pending asks (an asked with no answered of the same id) are listed across open tasks with their text" {
  opened T3
  event T3 asked '{id: "q1", text: "Which name?"}'
  event T3 asked '{id: "q2", text: "Ship it?"}'
  event T3 answered '{id: "q1", answer: "team-snapshot"}'
  opened T12
  event T12 asked '{id: "d15", text: "The November spread question for the organizer"}'
  run_bin -0 team-snapshot --json
  assert_equal "$(jq -c .pending_asks <<<"$output")" "$(jq -cn '[
    {task: "T3", id: "q2", text: "Ship it?", ts: "2026-10-22T02:00:00Z"},
    {task: "T12", id: "d15", text: "The November spread question for the organizer", ts: "2026-10-22T02:00:00Z"}]')"
  run_bin -0 team-snapshot
  assert_equal "$(section "Pending asks")" "Pending asks (2):
  T3 q2: Ship it?
  T12 d15: The November spread question for the organizer"
}

@test "an ops session's pending ask shows by its fixed line, and its question with no text breaks nothing" {
  opened T5
  event T5 question '{role: "ops", chars: 71, discord_message: "1564000000000000001"}'
  event T5 asked '{id: "write-1", text: "An ops question of 71 characters, in T5'"'"'s thread.", discord_message: "1564000000000000001"}'
  event T5 question '{role: "ops", chars: 28}'
  run_bin -0 team-snapshot
  assert_equal "$(section "Pending asks")" "Pending asks (1):
  T5 write-1: An ops question of 71 characters, in T5's thread."
}

@test "an empty ledger shows every part as none" {
  reserve_agent_team
  open_prs owner/proj '[]'
  open_prs owner/conv '[]'
  run_bin -0 team-snapshot
  assert_equal "$output" "Open tasks: none
Resources: manual, full (90%): no reading of the machine's load yet, so no budget
Live team sessions: none
Stray sessions: none
Open PRs:
  proj (owner/proj): none
  conv (owner/conv): none
  agent-team (owner/agent-team): none
Pending asks: none
Current items: none"
  rm "$TEAM_HOME/ledger.jsonl"
  run_bin -0 team-snapshot --json
  assert_equal "$(jq -c '[.tasks, .default_withdrawn, .sessions, .strays, .pending_asks, .items, .denials]' <<<"$output")" '[[],[],[],[],[],[],[]]'
}

# said <task> <kind> <scope> <message> <ts>: Daniel's withdrawal of the default merge word
# (merge-default-withdrawn) or its giving back (merge-default-restored) for <scope> (task, a
# project or all), in #coordinator, logged under <task>.
said() {
  event "$1" "$2" "{ts: \"$5\", scope: \"$3\", discord_message: \"$4\", discord_channel: \"1562486564871995482\"}"
}

# The line of a withdrawal of the default word for <whom>, in <message> at <ts>, logged under <task>:
# withdrawn_line <whom> <message> <ts> <task>
withdrawn_line() {
  echo "Default merge word withdrawn for $1 since $3 (Discord message $2, $4)"
}

@test "each withdrawal of the default word that stands follows the resources line, and --json lists them" {
  reserve_agent_team
  open_prs owner/proj '[]'
  open_prs owner/conv '[]'
  opened T3
  opened T4
  said T3 merge-default-withdrawn task 1564100000000000001 2026-10-22T03:00:00Z
  said T4 merge-default-withdrawn conv 1564100000000000002 2026-10-22T04:00:00Z
  run_bin -0 team-snapshot
  assert_equal "$(sed -n 4,7p <<<"$output")" "Resources: manual, full (90%): no reading of the machine's load yet, so no budget
$(withdrawn_line T3 1564100000000000001 2026-10-22T03:00:00Z T3)
$(withdrawn_line "project conv" 1564100000000000002 2026-10-22T04:00:00Z T4)
Live team sessions: none"
  run_bin -0 team-snapshot --json
  assert_equal "$(jq -c '.default_withdrawn | map([.task, .scope, .discord_message])' <<<"$output")" \
    '[["T3","task","1564100000000000001"],["T4","conv","1564100000000000002"]]'

  # A withdrawal of every project decides for every PR, so it stands alone; its giving back ends it.
  said T4 merge-default-withdrawn all 1564100000000000003 2026-10-22T05:00:00Z
  run_bin -0 team-snapshot
  assert_equal "$(sed -n 5,6p <<<"$output")" "$(withdrawn_line "every project" 1564100000000000003 2026-10-22T05:00:00Z T4)
Live team sessions: none"
  said T4 merge-default-restored all 1564100000000000004 2026-10-22T06:00:00Z
  run_bin -0 team-snapshot
  assert_equal "$(sed -n 5p <<<"$output")" "Live team sessions: none"
  run_bin -0 team-snapshot --json
  assert_equal "$(jq -c .default_withdrawn <<<"$output")" '[]'
  # The retired standing word's events are history: no line names them.
  event T4 merge-standing '{project: "all", discord_message: "1564100000000000005", discord_channel: "1562486564871995482"}'
  run_bin -0 team-snapshot
  [[ $output != *"merge word"* ]]
}

# production_check <project> <name>: an [[<project>.uptime]] check of the registry, on the loopback
# (no test fetches it: team-snapshot reads only the last results).
production_check() {
  printf '\n[[%s.uptime]]\nname = "%s"\nurl = "http://127.0.0.1:9/%s"\nexpect = "ok"\n' "$1" "$2" "$2" >>"$TEAM_HOME/projects.toml"
}

# production_state <written> <entries>: team-uptime's state file, written at <written>, its checks
# the jq object <entries>.
production_state() {
  mkdir -p "$HOME/.local/state/agent-team"
  jq -n --arg written "$1" "{schema: \"team-uptime/1\", written: \$written, checks: ($2)}" \
    >"$HOME/.local/state/agent-team/uptime.json"
}

# A check of production_check's as team-uptime run leaves it, checked at <at>: up_check <project>
# <name> <at>, and down_check <project> <name> <at> <since> <reason> (down, its outage posted).
up_check() {
  jq -nc --arg p "$1" --arg n "$2" --arg at "$3" '{("\($p)/\($n)"): {project: $p, name: $n,
    url: "http://127.0.0.1:9/\($n)", expect: "ok", checked: $at, ok: true, reason: null, failures: 0, since: null, alert: null}}'
}
down_check() {
  jq -nc --arg p "$1" --arg n "$2" --arg at "$3" --arg since "$4" --arg reason "$5" '{("\($p)/\($n)"): {project: $p, name: $n,
    url: "http://127.0.0.1:9/\($n)", expect: "ok", checked: $at, ok: false, reason: $reason, failures: 3, since: $since,
    alert: {since: $since, posted: $since, reminded: null, message: "1569000000000000001", back: null}}}'
}

@test "with no production checks there is no Production line, and --json's production has a null line" {
  open_prs owner/proj '[]'
  open_prs owner/conv '[]'
  run_bin -0 team-snapshot
  assert_equal "$(sed -n 3p <<<"$output")" "Live team sessions: none"
  [[ $output != *Production* ]]
  run_bin -0 team-snapshot --json
  assert_equal "$(jq -c .production <<<"$output")" '{"schema":"team-uptime/1","written":null,"line":null,"checks":[]}'
}

@test "the Production line follows the default word's withdrawals, all up or a check down, and --json carries team-uptime status --json's object" {
  open_prs owner/proj '[]'
  open_prs owner/conv '[]'
  opened T3
  said T3 merge-default-withdrawn conv 1564100000000000001 2026-10-22T03:00:00Z
  production_check proj api
  production_check conv front-end
  local at since
  at=$(date -u -d '-3 minutes' +%FT%TZ)
  since=$(date -u -d '-40 minutes' +%FT%TZ)
  production_state "$at" "$(up_check proj api "$at") + $(up_check conv front-end "$at")"
  run_bin -0 team-snapshot
  assert_equal "$(sed -n 4,6p <<<"$output")" "$(withdrawn_line "project conv" 1564100000000000001 2026-10-22T03:00:00Z T3)
Production: all 2 checks up, last checked $(date -d "$at" +%H:%M)
Live team sessions: none"

  production_state "$at" "$(up_check proj api "$at") + $(down_check conv front-end "$at" "$since" 'HTTP 503')"
  run_bin -0 team-snapshot
  assert_equal "$(sed -n 5p <<<"$output")" \
    "Production: conv front-end down since $(date -d "$since" +%H:%M): HTTP 503; 1 more up, last checked $(date -d "$at" +%H:%M)"
  run_bin -0 team-snapshot --json
  local snapshot=$output
  run_bin -0 team-uptime status --json
  assert_equal "$(jq -c .production <<<"$snapshot")" "$(jq -c . <<<"$output")"
}

@test "the Production line is cut at 200 columns" {
  open_prs owner/proj '[]'
  open_prs owner/conv '[]'
  local at n entries='{}'
  at=$(date -u -d '-3 minutes' +%FT%TZ)
  for n in 1 2 3 4; do
    production_check proj "check-$n"
    entries+=" + $(down_check proj "check-$n" "$at" "$at" 'Could not resolve host: api.conventioner.io')"
  done
  production_state "$at" "$entries"
  run_bin -0 team-snapshot
  local line
  line=$(sed -n 3p <<<"$output")
  assert_equal "${#line}" 200
  [[ $line == "Production: proj check-1 down since "*... ]] || { echo "line: $line" >&2; return 1; }
}

# denied <task> <ts> <role> <what> <why>: a denial a worker went past, as team-log --from-message
# logs a BLOCKED that took its allowed way.
denied() {
  ledger_line --arg t "$1" --arg ts "$2" --arg role "$3" --arg what "$4" --arg why "$5" \
    '{ts: $ts, task: $t, event: "denied", role: $role, what: $what, why: $why, session: "b0000001"}'
}

@test "the denials of the last day follow the Production line, newest first, and --json lists them" {
  open_prs owner/proj '[]'
  open_prs owner/conv '[]'
  opened T3
  opened T5
  opened T4
  production_check proj api
  local at hour two_hours day_ago
  at=$(date -u -d '-3 minutes' +%FT%TZ)
  production_state "$at" "$(up_check proj api "$at")"
  hour=$(date -u -d '-1 hour' +%FT%TZ)
  two_hours=$(date -u -d '-2 hours' +%FT%TZ)
  day_ago=$(date -u -d '-25 hours' +%FT%TZ)
  denied T3 "$day_ago" builder command-guard 'a kill of PID 7, a day and an hour ago'
  denied T3 "$two_hours" builder command-guard 'a recursive delete of /tmp/x, which is outside your worktree'
  denied T5 "$hour" reviewer command-guard 'a kill by name or pattern (pkill)'
  denied T4 "$hour" builder command-guard 'a closed task'"'"'s denial'
  event T4 closed '{archive: [], returned: [], kept: []}'
  run_bin -0 team-snapshot
  assert_equal "$(grep -A 2 '^Production: ' <<<"$output")" "Production: all 1 check up, last checked $(date -d "$at" +%H:%M)
Denials gone past in the last day: 2: T5 reviewer command-guard: a kill by name or pattern (pkill); T3 builder command-guard: a recursive delete of /tmp/x, which is outside your worktree
Live team sessions: none"
  run_bin -0 team-snapshot --json
  assert_equal "$(jq -c .denials <<<"$output")" "$(jq -cn --arg hour "$hour" --arg two "$two_hours" '[
    {task: "T5", ts: $hour, role: "reviewer", what: "command-guard", why: "a kill by name or pattern (pkill)"},
    {task: "T3", ts: $two, role: "builder", what: "command-guard",
     why: "a recursive delete of /tmp/x, which is outside your worktree"}]')"
}

@test "with no denial in the last day there is no denials line, and --json's denials is empty" {
  open_prs owner/proj '[]'
  open_prs owner/conv '[]'
  opened T3
  denied T3 "$(date -u -d '-25 hours' +%FT%TZ)" builder command-guard 'a kill of PID 7'
  run_bin -0 team-snapshot
  [[ $output != *Denials* ]] || { echo "$output" >&2; return 1; }
  run_bin -0 team-snapshot --json
  assert_equal "$(jq -c .denials <<<"$output")" '[]'
}

@test "the denials line is cut at 200 columns" {
  open_prs owner/proj '[]'
  open_prs owner/conv '[]'
  opened T3
  local n
  for n in 1 2 3 4; do
    denied T3 "$(date -u -d "-$n minutes" +%FT%TZ)" builder command-guard "a recursive delete of /tmp/scratch-$n, which is outside your worktree and your job's tmp"
  done
  run_bin -0 team-snapshot
  local line
  line=$(grep '^Denials' <<<"$output")
  assert_equal "${#line}" 200
  [[ $line == "Denials gone past in the last day: 4: T3 builder command-guard: a recursive delete of /tmp/scratch-1, "*... ]] ||
    { echo "line: $line" >&2; return 1; }
}

@test "a team-uptime that fails gives production its error, the text says production is unreadable, and the rest is as before" {
  open_prs owner/proj '[]'
  open_prs owner/conv '[]'
  opened T3
  production_check proj api
  mkdir -p "$HOME/.local/state/agent-team"
  echo 'not json {' >"$HOME/.local/state/agent-team/uptime.json"
  run_bin -0 --separate-stderr team-snapshot --json
  assert_equal "$stderr" ""
  assert_equal "$(jq -c .production <<<"$output")" '{"error":"~/.local/state/agent-team/uptime.json is not a team-uptime/1 state"}'
  assert_equal "$(jq -c '.tasks | length' <<<"$output")" 1
  run_bin -0 team-snapshot
  assert_equal "$(sed -n 4,5p <<<"$output")" "Production unreadable: ~/.local/state/agent-team/uptime.json is not a team-uptime/1 state
Live team sessions: none"
}

@test "current items are the item lines of tasks/current.md, after the pending asks and in --json" {
  open_prs owner/proj '[]'
  open_prs owner/conv '[]'
  mkdir -p "$TEAM_HOME/tasks"
  cat >"$TEAM_HOME/tasks/current.md" <<'EOF'
# Current items

- owe - the T45 summary, my move | https://discord.com/channels/1/2/3
- next T45 after it merges, open the Node pin task | tasks/queued/node-pin.md
Not an item: a note under the list.
  - not an item either, indented
- queued - the lease fix, Daniel approved | tasks/queued/conventioner-lease-fix.md
EOF
  run_bin -0 team-snapshot
  # A queued line is the queued index's, never a current item the text shows.
  assert_equal "$(section "Current items")" "Current items (2):
  - owe - the T45 summary, my move | https://discord.com/channels/1/2/3
  - next T45 after it merges, open the Node pin task | tasks/queued/node-pin.md"
  assert_equal "${lines[-4]}" "Pending asks: none"
  run_bin -0 team-snapshot --json
  assert_equal "$(jq -c .items <<<"$output")" "$(jq -cn '[
    "owe - the T45 summary, my move | https://discord.com/channels/1/2/3",
    "next T45 after it merges, open the Node pin task | tasks/queued/node-pin.md",
    "queued - the lease fix, Daniel approved | tasks/queued/conventioner-lease-fix.md"]')"
  assert_equal "$(jq -r .schema <<<"$output")" "team-snapshot/1"
}

@test "with a waiting list the text shows its first five items, ranked, how many more and the replies owed, in place of the pending asks and current.md's asks" {
  open_prs owner/proj '[]'
  open_prs owner/conv '[]'
  opened T3
  event T3 asked '{id: "q1", text: "Which name?"}'
  mkdir -p "$TEAM_HOME/tasks/queued"
  cat >"$TEAM_HOME/tasks/current.md" <<'EOF'
# Current items
- ask - open a research task? | https://discord.com/channels/1/2/3
- owe T4 the weekly report | 1563000000000000045
- next T45 after it merges, open the Node pin task | tasks/queued/node-pin.md
- watch - the CI wait on PR 7 | ledger 2026-11-01T07:08:11Z
- queued - the lease fix | tasks/queued/node-pin.md
EOF
  printf '# Node pin\n' >"$TEAM_HOME/tasks/queued/node-pin.md"
  printf '# Lease fix\n' >"$TEAM_HOME/tasks/queued/lease-fix.md"
  printf '# Queued work\n' >"$TEAM_HOME/tasks/queued/index.md"
  jq -n '{schema: "team-waiting/1",
    items: [range(1; 8) | {n: ., key: "k\(.)", kind: "ask", task: "T3", line: "- **\(.)** T3 q\(.): Q\(.)? - unblocks 1 (1 task)"}],
    withdrawn: [], owed: [{task: "T4", text: "the weekly report", where: "1563000000000000045"}], posted: null}' \
    >"$TEAM_HOME/waiting.json"
  run_bin -0 team-snapshot
  assert_equal "$(section "Waiting on Daniel")" "Waiting on Daniel (7), ranked by what each answer unblocks:
  - **1** T3 q1: Q1? - unblocks 1 (1 task)
  - **2** T3 q2: Q2? - unblocks 1 (1 task)
  - **3** T3 q3: Q3? - unblocks 1 (1 task)
  - **4** T3 q4: Q4? - unblocks 1 (1 task)
  - **5** T3 q5: Q5? - unblocks 1 (1 task)
  and 2 more in waiting.md
  Owed you: T4 the weekly report"
  assert_equal "$(section "Pending asks")" ""
  # The asks and owed replies are the waiting list's, and queued work is the index's.
  assert_equal "$(section "Current items")" "Current items (2):
  - next T45 after it merges, open the Node pin task | tasks/queued/node-pin.md
  - watch - the CI wait on PR 7 | ledger 2026-11-01T07:08:11Z"
  assert_equal "${lines[-1]}" "Queued work: 2 files, listed in tasks/queued/index.md"
  run_bin -0 team-snapshot --json
  assert_equal "$(jq -c '.waiting | [(.lines | length), .total, .owed]' <<<"$output")" '[5,7,["T4 the weekly report"]]'
  assert_equal "$(jq -c '[(.items | length), .queued]' <<<"$output")" '[5,2]'

  # A waiting list of another schema is unreadable: the pending asks and current.md's asks show.
  echo '{"schema": "team-waiting/0"}' >"$TEAM_HOME/waiting.json"
  run_bin -0 team-snapshot
  assert_equal "$(section "Waiting on Daniel")" "Waiting on Daniel unreadable: waiting.json is not team-waiting/1"
  assert_equal "$(section "Pending asks")" "Pending asks (1):
  T3 q1: Which name?"
  assert_equal "$(head -n 1 <<<"$(section "Current items")")" "Current items (4):"
}

@test "a current items file with no item lines is no current items" {
  open_prs owner/proj '[]'
  open_prs owner/conv '[]'
  mkdir -p "$TEAM_HOME/tasks"
  printf '# Current items\n\n' >"$TEAM_HOME/tasks/current.md"
  run_bin -0 team-snapshot
  assert_equal "${lines[-1]}" "Current items: none"
  run_bin -0 team-snapshot --json
  assert_equal "$(jq -c .items <<<"$output")" "[]"
}

@test "the text form shows 40 current items, each whole up to 200 columns, then how many more; --json has them all" {
  open_prs owner/proj '[]'
  open_prs owner/conv '[]'
  mkdir -p "$TEAM_HOME/tasks"
  local long n items
  long="- next - $(printf 'a long promise to keep %.0s' {1..12})| tasks/T9/plan.md"
  {
    echo "# Current items"
    echo "$long"
    for n in $(seq 2 43); do echo "- watch - item $n | tasks/T$n/plan.md"; done
  } >"$TEAM_HOME/tasks/current.md"
  run_bin -0 team-snapshot
  items=$(section "Current items")
  assert_equal "$(head -n 1 <<<"$items")" "Current items (43):"
  assert_equal "$(wc -l <<<"$items")" 42
  assert_equal "$(sed -n 2p <<<"$items")" "  ${long:0:195}..."
  assert_equal "$(sed -n 3p <<<"$items")" "  - watch - item 2 | tasks/T2/plan.md"
  assert_equal "$(sed -n 41p <<<"$items")" "  - watch - item 40 | tasks/T40/plan.md"
  assert_equal "$(tail -n 1 <<<"$items")" "  and 3 more in tasks/current.md"
  run_bin -0 team-snapshot --json
  assert_equal "$(jq '.items | length' <<<"$output")" 43
  assert_equal "$(jq -r '.items[0]' <<<"$output")" "${long:2}"
}

@test "T7 to T10, open in the real ledger (legacy, never closed), each show their state" {
  fixture_ledger T7-T10
  fixture_ledger T4
  run_bin -0 team-snapshot
  assert_equal "$(section "Open tasks")" "Open tasks (4):
  T7 planning | no live worker
  T8 planning | no live worker
  T9 planning | no live worker
  T10 planning | no live worker"
  run_bin -0 team-snapshot --json
  assert_equal "$(jq -c '[.tasks[] | [.task, .thread, (.workers | map(.session))]]' <<<"$output")" \
    '[["T7",null,["418e77bd"]],["T8","1562493626490036344",["77ddfee3"]],["T9","1562493629384368208",["a3529935"]],["T10","1562493631334453309",["954b98a2"]]]'
}

@test "the text form fits one screen for ten open tasks" {
  local list='' all=() n
  for n in $(seq 1 10); do
    opened "T$n" "$([[ $n -le 5 ]] && echo proj || echo conv)"
    launch "T$n" builder "$(printf '%08d' "$n")"
    pr_event "T$n" "$n"
    event "T$n" asked "{id: \"q$n\", text: \"$(printf 'A long question for Daniel %.0s' {1..8})\"}"
    event "T$n" waiting "{on: \"Daniel\", reason: \"$(printf 'a long reason %.0s' {1..8})\"}"
    all+=("$(session "$(printf '%08d' "$n")" "T$n-builder" busy working)")
    list+="$(pr_json "$n" "feat/T$n-a-rather-long-branch-name" "$(printf 'A long pull request title %.0s' {1..6})"),"
  done
  open_prs owner/proj "[${list%,}]"
  open_prs owner/conv '[]'
  sessions "${all[@]}"
  run_bin -0 team-snapshot
  echo "$output"
  # 50 lines at most.
  [[ ${#lines[@]} -le 50 ]]
  # An open task's line is cut at 200 columns, any other at 120.
  local line
  for line in $(section "Open tasks" | sed 1d | awk '{ print length($0) }'); do [[ $line -le 200 ]]; done
  for line in "${lines[@]}"; do [[ $line == "  T"[0-9]*" | "* || ${#line} -le 120 ]]; done
  # Long free text is cut, with the cut shown.
  assert_contains "$(section "Pending asks")" "  T1 q1: A long question for Daniel A long question for Daniel"
  assert_contains "$(section "Pending asks")" "..."
}

@test "an open task's line carries its progress whole: the brief its builder is on, its tickets, its review and how far its PR is behind" {
  local wt=$BATS_TEST_TMPDIR/wt n
  mkdir -p "$wt/.scratch/task/tickets"
  for n in 1 2 3 4 5 6 7; do printf 'Blocked by: None\n' >"$wt/.scratch/task/tickets/0$n-ticket.md"; done
  event T172 opened "$(jq -cn --arg wt "$wt" '{project: "proj", path: "feature", type: "feat", title: "Toil",
    branch: "feat/T172-coordinator-toil-tools", base: "main", base_sha: "0123456", worktree: $wt}')"
  event T172 plan-approved '{by: "Daniel"}'
  for n in 01 02 03; do event T172 ticket-done "{ticket: \"$n\", commits: [\"a0017cce\"]}"; done
  event T172 launch '{role: "builder", session: "59709d99", worktree: "/w/1", toolkits: [], brief: "brief-build-04"}'
  pr_event T172 45
  event T172 review "{verdict: \"findings\", head: \"$head\", sent_back: [5, 6]}"
  echo 16 >"$STUB_FIXTURES/compare"
  sessions "$(session 59709d99 T172-builder idle)"
  open_prs owner/proj '[]'
  open_prs owner/conv '[]'
  run_bin -0 team-snapshot
  local line="  T172 proj feature in-review | T172-builder idle on build-04 | tickets 3/7 | review 1 findings, sent back 5, 6 | PR #45 a1b2c3d 16 behind main checks 0/0 agent-review missing"
  assert_equal "$(section "Open tasks")" "Open tasks (1):
$line"
  # More than 120 columns, kept whole, as team-state says it.
  [[ ${#line} -gt 120 ]]
  run_bin -0 team-state T172
  assert_equal "  $output" "$line"
  run_bin -0 team-snapshot --json
  assert_equal "$(jq -c '.tasks[0] | [.progress.tickets, .progress.reviews.sent_back, .pr.behind_by]' <<<"$output")" \
    '[{"done":["01","02","03"],"total":7,"graph":null},[5,6],16]'
}

@test "a waiting task says what it waits on" {
  opened T5
  launch T5 builder 59709d99
  event T5 waiting '{on: "Daniel", reason: "restart the Docker daemons"}'
  run_bin -0 team-snapshot
  # Its builder's launch put the feature task in building (the lifecycle's launch rule).
  assert_equal "$(section "Open tasks")" "Open tasks (1):
  T5 proj feature building | no live worker | parks: waiting-1 daniel since 2026-10-22T02:00:00Z: restart the Docker daemons"
}

@test "a task with a worktree not re-homed says so until the worktree is made" {
  opened T5
  event T5 rehome-failed '{project: "proj", branch: "feat/T5-work", machine: "laptop", reason: "every slot of proj is taken:"}'
  run_bin -0 team-snapshot
  assert_equal "$(section "Open tasks")" "Open tasks (1):
  T5 proj feature planning | no live worker | not re-homed: proj on laptop: every slot of proj is taken:"
  run_bin -0 team-snapshot --json
  assert_equal "$(jq -c '.tasks[0].rehome_failures | map(.project)' <<<"$output")" '["proj"]'
  event T5 rehomed '{project: "proj", branch: "feat/T5-work", worktree: "/w/1", machine: "laptop"}'
  run_bin -0 team-snapshot
  assert_equal "$(section "Open tasks")" "Open tasks (1):
  T5 proj feature planning | no live worker"
}

@test "a session list that cannot be read is exit 1 with the reason" {
  opened T3
  stub_reply claude 'not json' 1
  run_bin -1 --separate-stderr team-snapshot
  assert_equal "$output" ""
  assert_equal "$stderr" "team-snapshot: cannot read the live session list (claude agents --json)"
}

@test "a broken registry is exit 1 with team-project's reasons" {
  opened T3
  echo '[proj]' >"$TEAM_HOME/projects.toml"
  run_bin -1 --separate-stderr team-snapshot
  assert_equal "$output" ""
  assert_contains "$stderr" "proj: missing required key 'repo'"
}

@test "a task whose state cannot be told carries the reason, and the rest is complete" {
  opened T3
  opened T4
  event T4 pr '{url: "https://github.com/owner/proj/pull/5", head: "1234567", project: "gone"}'
  event T4 asked '{id: "q1", text: "Which name?"}'
  open_prs owner/proj '[]'
  open_prs owner/conv '[]'
  run_bin -0 --separate-stderr team-snapshot --json
  assert_equal "$stderr" ""
  assert_equal "$(jq -c '.tasks[1]' <<<"$output")" \
    '{"task":"T4","error":"team-project: unknown project '"'gone'"'; known: proj, conv"}'
  assert_equal "$(jq -c '[.tasks[0].task, .pending_asks]' <<<"$output")" '["T3",[]]'
  run_bin -0 team-snapshot
  assert_equal "$(section "Open tasks")" "Open tasks (2):
  T3 proj feature planning | no live worker
  T4 state unreadable: team-project: unknown project 'gone'; known: proj, conv"
}

@test "an unknown option or argument is a usage error" {
  run_bin -2 team-snapshot --text
  run_bin -2 team-snapshot T3
  assert_equal "$(stub_calls claude)$(stub_calls gh)" ""
}
