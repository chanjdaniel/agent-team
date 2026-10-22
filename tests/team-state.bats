#!/usr/bin/env bats
# team-state: where one task stands, from its ledger events, the live session list and GitHub.

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
required_checks = ["shellcheck", "test"]
task_dir = ".scratch/task"
docs = []
toolkits = []

[proj.pool]
provider = "git"
slots = ["slots/proj/1", "slots/proj/2"]
TOML
  stub_reply claude '[]'
  head=a1b2c3d4e5f60718293a4b5c6d7e8f9012345678
}

# ledger_line [jq options...] <filter>: append the line jq builds, standing in for the script
# that writes it.
ledger_line() {
  jq -cn "$@" >>"$TEAM_HOME/ledger.jsonl"
}

# event <task> <kind> [<jq object of more fields>]
event() {
  ledger_line --arg t "$1" --arg e "$2" "{ts: \"2026-10-22T02:00:00Z\", task: \$t, event: \$e} + (${3:-{\}})"
}

# The opened task T14 of project proj, with its thread and a builder's launch.
open_task() {
  event T14 opened '{project: "proj", path: "feature", type: "feat", title: "The tooling",
    branch: "feat/T14-tooling", base: "main", base_sha: "0123456", worktree: "/w/1"}'
  event T14 thread '{discord_thread: "1563"}'
  event T14 launch '{role: "builder", session: "59709d99", worktree: "/w/1", toolkits: [],
    project: "proj", branch: "feat/T14-tooling"}'
}

# The first <n> lines of a fixture ledger from the real one, as the sandbox ledger.
fixture_ledger() {
  head -n "$2" "$BATS_TEST_DIRNAME/fixtures/ledger-$1.jsonl" >"$TEAM_HOME/ledger.jsonl"
}

# gh answers PR #5 of owner/proj: its view, all its checks and its server-required checks, each
# from the JSON given (or from $view, $checks and $required).
stub_github() {
  export GH_VIEW=${1:-$view} GH_CHECKS=${2:-$checks} GH_REQUIRED=${3:-$required}
  stub_script gh <<'EOF'
case "$1 $2 $*" in
  "pr view"*) echo "$GH_VIEW" ;;
  "pr checks"*--required*) echo "$GH_REQUIRED" ;;
  "pr checks"*) echo "$GH_CHECKS" ;;
  *) echo "unplanned gh call: $*" >&2; exit 1 ;;
esac
EOF
}

# gh fails every call as when GitHub cannot be reached.
github_down() {
  stub_script gh <<'EOF'
echo "error connecting to api.github.com" >&2
exit 1
EOF
}

phase_of() {
  run_bin -0 team-state "$1" --json
  jq -r .phase <<<"$output"
}

@test "an unknown task is exit 1 and a malformed task id is a usage error" {
  open_task
  run_bin -1 team-state T99
  assert_equal "$output" "team-state: unknown task T99: the ledger has no events for it"
  run_bin -2 team-state 14
  run_bin -2 team-state
  run_bin -2 team-state T14 --text
  assert_equal "$(stub_calls gh)" ""
}

@test "the JSON carries its schema and the task's facts from the ledger" {
  open_task
  event T14 worktree-added '{project: "conv", branch: "feat/T14-x", base: "dev", base_sha: "89abcde", worktree: "/t/2"}'
  event T14 worktree-returned '{project: "conv", worktree: "/t/2"}'
  event T14 asked '{id: "q1", text: "Which name?"}'
  event T14 asked '{id: "q2", text: "Ship it?"}'
  event T14 answered '{id: "q1", answer: "team-state"}'
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c 'del(.workers)' <<<"$output")" "$(jq -cn '{
    schema: "team-state/1", task: "T14", title: "The tooling", project: "proj", path: "feature",
    phase: "planning",
    worktrees: [
      {project: "proj", branch: "feat/T14-tooling", worktree: "/w/1", returned: false},
      {project: "conv", branch: "feat/T14-x", worktree: "/t/2", returned: true}],
    thread: "1563",
    last_event: {ts: "2026-10-22T02:00:00Z", task: "T14", event: "answered", id: "q1", answer: "team-state"},
    pending_asks: [{id: "q2", text: "Ship it?", ts: "2026-10-22T02:00:00Z"}],
    pr: null}')"
  assert_equal "$(stub_calls gh)" ""
}

@test "a legacy task with no opened event has no title, project or worktrees" {
  fixture_ledger T4 3
  run_bin -0 team-state T4 --json
  assert_equal "$(jq -c '[.title, .project, .path, .worktrees, .thread, .phase]' <<<"$output")" \
    '[null,null,null,[],null,"building"]'
}

@test "workers list every launch with its live status and state from one read of the session list" {
  open_task
  event T14 launch '{role: "reviewer", session: "3ed2d1f2", worktree: "/w/1", toolkits: []}'
  stub_reply claude '[
    {"pid": 1, "cwd": "/home", "kind": "interactive", "sessionId": "194f5a85-f4b2-47b2", "name": "me", "status": "idle"},
    {"pid": 2, "id": "59709d99", "cwd": "/w/1", "kind": "background", "sessionId": "59709d99-7687-4f7b",
     "name": "T14-builder", "status": "idle", "state": "blocked"}]'
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c .workers <<<"$output")" "$(jq -cn '[
    {role: "builder", session: "59709d99", launched: "2026-10-22T02:00:00Z", worktree: "/w/1",
     live: true, status: "idle", state: "blocked"},
    {role: "reviewer", session: "3ed2d1f2", launched: "2026-10-22T02:00:00Z", worktree: "/w/1",
     live: false, status: null, state: null}]')"
  assert_equal "$(stub_calls claude)" '["agents","--json"]'
}

@test "a session is matched by the start of its full session id when it has no short id" {
  open_task
  stub_reply claude '[{"pid": 2, "cwd": "/w/1", "kind": "background", "sessionId": "59709d99-7687-4f7b",
    "name": "T14-builder", "status": "busy", "state": "working"}]'
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c '.workers[0] | [.live, .status, .state]' <<<"$output")" '[true,"busy","working"]'
}

@test "a session list that cannot be read is refused" {
  open_task
  stub_reply claude 'not json' 1
  run_bin -1 team-state T14
  assert_contains "$output" "team-state: cannot read the live session list (claude agents --json)"
}

@test "T4's real history gives the right phase at each point" {
  cp "$REPO_ROOT/projects.toml" "$TEAM_HOME/projects.toml"
  github_down
  local lines=(1 3 50 51 54 57 59 60 61)
  local phases=(planning building in-review awaiting-merge in-review held in-review merged closed)
  local i
  for i in "${!lines[@]}"; do
    fixture_ledger T4 "${lines[$i]}"
    assert_equal "${lines[$i]}: $(phase_of T4)" "${lines[$i]}: ${phases[$i]}"
  done
}

@test "blocked stands until resumed, and held wins over blocked" {
  open_task
  event T14 plan-approved '{by: "Daniel"}'
  event T14 blocked '{reason: "a denied push"}'
  assert_equal "$(phase_of T14)" blocked
  event T14 held '{reason: "OS update"}'
  assert_equal "$(phase_of T14)" held
  event T14 resumed
  assert_equal "$(phase_of T14)" building
}

@test "merged wins over held, and closed over merged" {
  open_task
  event T14 held '{reason: "OS update"}'
  event T14 merged '{pr: 5, merge: "fedcba9", head: "a1b2c3d", by: "1563"}'
  assert_equal "$(phase_of T14)" merged
  event T14 closed '{archive: [], returned: [], kept: []}'
  assert_equal "$(phase_of T14)" closed
}

@test "heads compare by the shorter one's prefix, at least 7 characters" {
  open_task
  github_down
  event T14 pr "{url: \"https://github.com/owner/proj/pull/5\", head: \"$head\"}"
  event T14 review '{verdict: "pass", head: "a1b2c3"}'
  assert_equal "$(phase_of T14)" in-review
  event T14 review '{verdict: "pass", head: "A1B2C3D"}'
  assert_equal "$(phase_of T14)" awaiting-merge
  event T14 review '{verdict: "findings", head: "a1b2c3d4"}'
  assert_equal "$(phase_of T14)" in-review
}

@test "a review of an older head does not count once the PR's latest head moved on" {
  open_task
  github_down
  event T14 pr '{url: "https://github.com/owner/proj/pull/5", head: "1111111"}'
  event T14 review '{verdict: "pass", head: "1111111"}'
  event T14 pr '{url: "https://github.com/owner/proj/pull/5", head: "2222222"}'
  assert_equal "$(phase_of T14)" in-review
  event T14 review '{verdict: "pass", head: "2222222"}'
  assert_equal "$(phase_of T14)" awaiting-merge
}

@test "the PR part joins the ledger with the PR, its checks and the required ones on GitHub" {
  open_task
  event T14 pr '{url: "https://github.com/owner/proj/pull/5", head: "1111111"}'
  event T14 history-rewritten "{branch: \"feat/T14-tooling\", old_head: \"1111111\", head: \"${head:0:8}\"}"
  event T14 merge-approved '{pr: 5, discord_message: "1564"}'
  view='{"number": 5, "state": "OPEN", "baseRefName": "main", "headRefOid": "'"$head"'"}'
  checks='[
    {"name": "shellcheck", "bucket": "pass", "state": "SUCCESS"},
    {"name": "lint", "bucket": "fail", "state": "FAILURE"},
    {"name": "deploy", "bucket": "cancel", "state": "CANCELLED"},
    {"name": "build", "bucket": "pending", "state": "IN_PROGRESS"},
    {"name": "docs", "bucket": "skipping", "state": "SKIPPED"},
    {"name": "agent-review", "bucket": "pass", "state": "SUCCESS"}]'
  required='[{"name": "shellcheck", "bucket": "pass", "state": "SUCCESS"},
    {"name": "build", "bucket": "pending", "state": "IN_PROGRESS"}]'
  stub_github
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c .pr <<<"$output")" "$(jq -cn --arg head "$head" '{
    url: "https://github.com/owner/proj/pull/5", number: 5, repo: "owner/proj", project: "proj",
    state: "open", base: "main", head: $head, ledger_head: $head[:8], head_moved: false,
    checks: {passed: ["agent-review", "docs", "shellcheck"], failing: ["deploy", "lint"], pending: ["build"]},
    required: ["build", "shellcheck", "test"], required_missing: ["test"],
    agent_review: "success", merge_approved: true}')"
  assert_equal "$(stub_calls gh)" "$(jq -cn '
    ["pr", "view", "5", "--repo", "owner/proj", "--json", "number,state,baseRefName,headRefOid"],
    ["pr", "checks", "5", "--repo", "owner/proj", "--json", "name,bucket,state"],
    ["pr", "checks", "5", "--repo", "owner/proj", "--required", "--json", "name,bucket,state"]')"
}

@test "the head moved when GitHub's head is not the ledger's, and approval is per PR" {
  open_task
  event T14 pr '{url: "https://github.com/owner/proj/pull/5", head: "1111111"}'
  event T14 merge-approved '{pr: 4, discord_message: "1564"}'
  stub_github '{"number": 5, "state": "MERGED", "baseRefName": "main", "headRefOid": "'"$head"'"}' \
    '[{"name": "agent-review", "bucket": "fail", "state": "FAILURE"}]' '[]'
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c '.pr | [.state, .ledger_head, .head_moved, .agent_review, .merge_approved]' <<<"$output")" \
    '["merged","1111111",true,"failure",false]'
}

@test "a PR with no checks, or no server-required ones, has empty lists and agent-review missing" {
  open_task
  event T14 pr "{url: \"https://github.com/owner/proj/pull/5\", head: \"$head\"}"
  stub_script gh <<'EOF'
case "$1 $2 $*" in
  "pr view"*) echo '{"number": 5, "state": "OPEN", "baseRefName": "main", "headRefOid": "a1b2c3d4"}' ;;
  "pr checks"*--required*) echo "no required checks reported on the 'feat/T14-tooling' branch" >&2; exit 1 ;;
  "pr checks"*) echo "no checks reported on the 'feat/T14-tooling' branch" >&2; exit 1 ;;
esac
EOF
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c '.pr | [.checks, .required, .required_missing, .agent_review, .head_moved]' <<<"$output")" \
    '[{"passed":[],"failing":[],"pending":[]},["shellcheck","test"],["shellcheck","test"],"missing",false]'
}

@test "pending checks reported with gh's exit 8 are read, not an error" {
  open_task
  event T14 pr "{url: \"https://github.com/owner/proj/pull/5\", head: \"$head\"}"
  stub_script gh <<'EOF'
case "$1 $2 $*" in
  "pr view"*) echo '{"number": 5, "state": "OPEN", "baseRefName": "main", "headRefOid": "a1b2c3d4"}' ;;
  "pr checks"*) echo '[{"name": "test", "bucket": "pending", "state": "IN_PROGRESS"}]'; exit 8 ;;
esac
EOF
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c '.pr | [.checks.pending, .error]' <<<"$output")" '[["test"],null]'
}

@test "a legacy PR's repo comes from its URL, and its project's required checks from the registry" {
  cp "$REPO_ROOT/projects.toml" "$TEAM_HOME/projects.toml"
  fixture_ledger T5 22
  stub_github '{"number": 4, "state": "MERGED", "baseRefName": "dev", "headRefOid": "3a66af1c99"}' \
    '[{"name": "shellcheck", "bucket": "pass", "state": "SUCCESS"}]' '[]'
  run_bin -0 team-state T5 --json
  assert_equal "$(jq -c '.pr | [.repo, .project, .number, .ledger_head, .required_missing, .head_moved]' <<<"$output")" \
    '["chanjdaniel/agent-team","agent-team",4,"f5c35825",["test"],true]'
  assert_equal "$(jq -c '.phase' <<<"$output")" '"in-review"'
  assert_equal "$(stub_calls gh | jq -r '.[4]' | sort -u)" "chanjdaniel/agent-team"
}

@test "a PR event naming its project takes the repo from the registry" {
  open_task
  event T14 pr "{url: \"https://github.com/Owner/Proj/pull/5\", head: \"$head\", project: \"proj\"}"
  stub_github '{"number": 5, "state": "OPEN", "baseRefName": "main", "headRefOid": "'"$head"'"}' '[]' '[]'
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c '.pr | [.repo, .project]' <<<"$output")" '["owner/proj","proj"]'
  assert_equal "$(stub_calls gh | jq -r '.[4]' | sort -u)" "owner/proj"
}

@test "a PR in a repo the registry does not know has no project required checks" {
  open_task
  event T14 pr "{url: \"https://github.com/someone/else/pull/9\", head: \"$head\"}"
  stub_github '{"number": 9, "state": "OPEN", "baseRefName": "main", "headRefOid": "'"$head"'"}' '[]' '[]'
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c '.pr | [.repo, .project, .required]' <<<"$output")" '["someone/else",null,[]]'
}

@test "when GitHub fails, the PR part carries the error and everything else is complete" {
  open_task
  event T14 plan-approved '{by: "Daniel"}'
  event T14 pr "{url: \"https://github.com/owner/proj/pull/5\", head: \"$head\"}"
  event T14 merge-approved '{pr: 5, discord_message: "1564"}'
  stub_reply claude '[{"id": "59709d99", "sessionId": "59709d99-7687", "name": "T14-builder", "status": "idle", "state": "working"}]'
  github_down
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c .pr <<<"$output")" "$(jq -cn --arg head "$head" '{
    url: "https://github.com/owner/proj/pull/5", number: 5, repo: "owner/proj", project: "proj",
    ledger_head: $head, merge_approved: true,
    error: "gh pr view: error connecting to api.github.com"}')"
  assert_equal "$(jq -c '[.phase, .title, .thread, .workers[0].live, (.worktrees | length)]' <<<"$output")" \
    '["in-review","The tooling","1563",true,1]'

  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature in-review | T14-builder idle | PR #5 GitHub unavailable"
}

@test "the text form is one line: the task, its live workers and its PR" {
  open_task
  event T14 plan-approved '{by: "Daniel"}'
  event T14 launch '{role: "reviewer", session: "3ed2d1f2", worktree: "/w/1", toolkits: []}'
  event T14 pr "{url: \"https://github.com/owner/proj/pull/5\", head: \"$head\"}"
  stub_reply claude '[
    {"id": "59709d99", "sessionId": "59709d99-7687", "name": "T14-builder", "status": "idle", "state": "working"},
    {"id": "3ed2d1f2", "sessionId": "3ed2d1f2-1111", "name": "T14-reviewer", "status": "idle", "state": "blocked"}]'
  stub_github '{"number": 5, "state": "OPEN", "baseRefName": "main", "headRefOid": "'"$head"'"}' \
    '[{"name": "shellcheck", "bucket": "pass", "state": "SUCCESS"}, {"name": "test", "bucket": "pass", "state": "SUCCESS"}]' '[]'
  run_bin -0 team-state T14
  assert_equal "$output" \
    "T14 proj feature in-review | T14-builder idle, T14-reviewer idle blocked | PR #5 a1b2c3d checks 2/2 agent-review missing"
}

@test "the text form says when no worker is live, the head moved and the PR is no longer open" {
  open_task
  event T14 pr '{url: "https://github.com/owner/proj/pull/5", head: "1111111"}'
  event T14 review '{verdict: "pass", head: "1111111"}'
  stub_github '{"number": 5, "state": "MERGED", "baseRefName": "main", "headRefOid": "'"$head"'"}' \
    '[{"name": "test", "bucket": "fail", "state": "FAILURE"}, {"name": "agent-review", "bucket": "pass", "state": "SUCCESS"}]' '[]'
  run_bin -0 team-state T14
  assert_equal "$output" \
    "T14 proj feature awaiting-merge | no live worker | PR #5 merged a1b2c3d (head moved) checks 1/2 agent-review success"
}

@test "a legacy task's text form has only its id and phase before the workers" {
  fixture_ledger T4 3
  run_bin -0 team-state T4
  assert_equal "$output" "T4 building | no live worker"
}
