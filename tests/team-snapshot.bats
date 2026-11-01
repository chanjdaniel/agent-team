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
# with no file fails like GitHub down), view-<n> for gh pr view, and checks-<n> for both
# gh pr checks calls (an empty list when absent).
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

# reserve_agent_team: register agent-team with the code checkout as its primary, so it is the
# project the machine's slots keep one for, with no open PRs.
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
  local tasks
  tasks=$(section "Open tasks")
  assert_equal "$tasks" "Open tasks (3):
  T3 proj feature planning | no live worker
  T12 proj feature planning | T12-builder idle blocked
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
  assert_equal "$(jq -c 'keys_unsorted' <<<"$snapshot")" '["schema","tasks","slots","standing_words","sessions","strays","prs","pending_asks","items"]'
  assert_equal "$(jq -r '.tasks | map(.task) | join(" ")' <<<"$snapshot")" "T3 T4"
  run_bin -0 team-state T3 --json
  assert_equal "$(jq -c '.tasks[0]' <<<"$snapshot")" "$(jq -c . <<<"$output")"
  assert_equal "$(jq -c '.tasks[0].pr | [.number, .checks.passed]' <<<"$snapshot")" '[5,["test"]]'
  run_bin -0 team-state T4 --json
  assert_equal "$(jq -c '.tasks[1]' <<<"$snapshot")" "$(jq -c . <<<"$output")"
}

@test "the slots line follows the open tasks, and --json carries team-slots' object as slots, with no reading taken" {
  reserve_agent_team
  mkdir -p "$HOME/.config/agent-team"
  echo home-pc >"$HOME/.config/agent-team/machine"
  echo '{"cap": 10}' >"$HOME/.config/agent-team/slots.json"
  open_prs owner/proj '[]'
  open_prs owner/conv '[]'
  opened T3
  opened T4 conv
  run_bin -0 team-snapshot
  assert_equal "$(head -n 6 <<<"$output")" "Open tasks (2):
  T3 proj feature planning | no live worker
  T4 conv feature planning | no live worker
home-pc: 2 of 10 task slots held, 1 kept for agent-team (agent-team holds 0); effective 10
Standing merge word: none
Live team sessions: none"
  run_bin -0 team-snapshot --json
  local snapshot=$output
  run_bin -0 team-slots status --stored --json
  assert_equal "$(jq -c .slots <<<"$snapshot")" "$(jq -c . <<<"$output")"
  assert_equal "$(jq -r '.slots | [.schema, .counts.held, .effective.cap] | join(" ")' <<<"$snapshot")" "team-slots/1 2 10"
  [[ ! -e $HOME/.local/state/agent-team/slots ]]
}

@test "a team-slots that fails gives slots its error, and the rest of the snapshot as before" {
  opened T3
  launch T3 builder 59709d99
  event T3 asked '{id: "q1", text: "Which name?"}'
  open_prs owner/proj '[]'
  open_prs owner/conv '[]'
  sessions "$(session 59709d99 T3-builder busy working)"
  mkdir -p "$HOME/.config/agent-team"
  echo '{"cap": 0}' >"$HOME/.config/agent-team/slots.json"
  run_bin -1 --separate-stderr team-slots status --stored
  local error=${stderr/"$HOME/"/"~/"}
  assert_contains "$error" "team-slots: ~/.config/agent-team/slots.json"
  run_bin -0 --separate-stderr team-snapshot --json
  assert_equal "$stderr" ""
  assert_equal "$(jq -c .slots <<<"$output")" "$(jq -cn --arg error "$error" '{error: $error}')"
  assert_equal "$(jq -c '[(.tasks | length), (.sessions | length), (.pending_asks | length), (.prs | length)]' <<<"$output")" '[1,1,1,2]'
  run_bin -0 team-snapshot
  assert_equal "$(sed -n 3,5p <<<"$output")" "Task slots unreadable: $error
Standing merge word: none
Live team sessions (1):"
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

@test "an empty ledger shows every part as none" {
  reserve_agent_team
  open_prs owner/proj '[]'
  open_prs owner/conv '[]'
  run_bin -0 team-snapshot
  assert_equal "$output" "Open tasks: none
this machine: 0 of 6 task slots held, 1 kept for agent-team (agent-team holds 0); effective 6
Standing merge word: none
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
  assert_equal "$(jq -c '[.tasks, .standing_words, .sessions, .strays, .pending_asks, .items]' <<<"$output")" '[[],[],[],[],[],[]]'
}

# standing <task> <kind> <project> <message> <ts>: Daniel's standing word on <project>
# (merge-standing) or its withdrawal (merge-standing-withdrawn), in #coordinator, logged under <task>.
standing() {
  event "$1" "$2" "{ts: \"$5\", project: \"$3\", discord_message: \"$4\", discord_channel: \"1562486564871995482\"}"
}

@test "the standing merge words follow the slots line, one per word with the projects it stands for, and --json lists them by project" {
  reserve_agent_team
  open_prs owner/proj '[]'
  open_prs owner/conv '[]'
  opened T3
  opened T4
  standing T3 merge-standing all 1564100000000000001 2026-10-22T03:00:00Z
  standing T3 merge-standing-withdrawn conv 1564100000000000002 2026-10-22T04:00:00Z
  standing T4 merge-standing proj 1564100000000000003 2026-10-22T05:00:00Z
  run_bin -0 team-snapshot
  assert_equal "$(sed -n 4,6p <<<"$output")" "this machine: 2 of 6 task slots held, 1 kept for agent-team (agent-team holds 0); effective 6
Standing merge word: agent-team (Discord message 1564100000000000001, 2026-10-22T03:00:00Z, T3)
Standing merge word: proj (Discord message 1564100000000000003, 2026-10-22T05:00:00Z, T4)"
  run_bin -0 team-snapshot --json
  assert_equal "$(jq -c .standing_words <<<"$output")" '[{"project":"proj","word":{"project":"proj","task":"T4","ts":"2026-10-22T05:00:00Z","discord_message":"1564100000000000003","discord_channel":"1562486564871995482"}},{"project":"agent-team","word":{"project":"all","task":"T3","ts":"2026-10-22T03:00:00Z","discord_message":"1564100000000000001","discord_channel":"1562486564871995482"}}]'

  # One word standing for many projects is one line naming them, and a withdrawal of all ends them.
  standing T4 merge-standing all 1564100000000000004 2026-10-22T06:00:00Z
  run_bin -0 team-snapshot
  assert_equal "$(sed -n 5p <<<"$output")" "Standing merge word: proj, conv, agent-team (Discord message 1564100000000000004, 2026-10-22T06:00:00Z, T4)"
  standing T4 merge-standing-withdrawn all 1564100000000000005 2026-10-22T07:00:00Z
  run_bin -0 team-snapshot
  assert_equal "$(sed -n 5,6p <<<"$output")" "Standing merge word: none
Live team sessions: none"
  run_bin -0 team-snapshot --json
  assert_equal "$(jq -c .standing_words <<<"$output")" '[]'
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
  assert_equal "$(section "Current items")" "Current items (3):
  - owe - the T45 summary, my move | https://discord.com/channels/1/2/3
  - next T45 after it merges, open the Node pin task | tasks/queued/node-pin.md
  - queued - the lease fix, Daniel approved | tasks/queued/conventioner-lease-fix.md"
  assert_equal "${lines[-5]}" "Pending asks: none"
  run_bin -0 team-snapshot --json
  assert_equal "$(jq -c .items <<<"$output")" "$(jq -cn '[
    "owe - the T45 summary, my move | https://discord.com/channels/1/2/3",
    "next T45 after it merges, open the Node pin task | tasks/queued/node-pin.md",
    "queued - the lease fix, Daniel approved | tasks/queued/conventioner-lease-fix.md"]')"
  assert_equal "$(jq -r .schema <<<"$output")" "team-snapshot/1"
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
  [[ ${#lines[@]} -le 50 ]]
  local line
  for line in "${lines[@]}"; do [[ ${#line} -le 120 ]]; done
  # Long free text is cut, with the cut shown.
  assert_contains "$(section "Pending asks")" "  T1 q1: A long question for Daniel A long question for Daniel"
  assert_contains "$(section "Pending asks")" "..."
}

@test "a waiting task says what it waits on" {
  opened T5
  launch T5 builder 59709d99
  event T5 waiting '{on: "Daniel", reason: "restart the Docker daemons"}'
  run_bin -0 team-snapshot
  assert_equal "$(section "Open tasks")" "Open tasks (1):
  T5 proj feature planning | no live worker | waiting on Daniel: restart the Docker daemons"
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
