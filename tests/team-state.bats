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
    waiting: null, rehome_failures: [], merge_preapproval: null, pr: null}')"
  assert_equal "$(stub_calls gh)" ""
}

@test "an ask is settled by a later merge-approved naming the PR URL its text names, and only that PR's" {
  open_task
  event T14 asked '{id: "merge", text: "merge it? https://github.com/o/r/pull/1 at 0123456"}'
  event T14 asked '{id: "merge-12", text: "merge it? https://github.com/o/r/pull/12 at 89abcde"}'
  event T14 merge-approved '{url: "https://github.com/o/r/pull/1/", discord_message: "1563000000000000001"}'
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c '[.pending_asks[].id]' <<<"$output")" '["merge-12"]'
  # An answered or a merge-approved settles only an ask logged before it.
  event T14 answered '{id: "again", answer: "y"}'
  event T14 asked '{id: "again", text: "and https://github.com/o/r/pull/1?"}'
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c '[.pending_asks[].id]' <<<"$output")" '["merge-12","again"]'
}

@test "an ask is settled by a later merge-preapproved naming its id, as by an answered" {
  open_task
  event T14 asked '{id: "plan", text: "Approve the plan, and its merge?"}'
  event T14 asked '{id: "name", text: "Which name?"}'
  event T14 asked '{id: "other", text: "And this?"}'
  event T14 merge-preapproved '{project: "proj", ask: "plan", discord_message: "1563000000000000001", scope: ["src/"]}'
  event T14 answered '{id: "name", answer: "team-state"}'
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c '[.pending_asks[].id]' <<<"$output")" '["other"]'
  # It settles only an ask logged before it, and only the one it names.
  event T14 asked '{id: "plan", text: "Approve the new plan?"}'
  event T15 merge-preapproved '{project: "proj", ask: "plan", discord_message: "1563000000000000002", scope: ["src/"]}'
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c '[.pending_asks[].id]' <<<"$output")" '["other","plan"]'
}

@test "worktrees recorded under another home show as the same paths under this HOME" {
  event T14 opened '{project: "proj", path: "feature", type: "feat", title: "The tooling",
    branch: "feat/T14-tooling", base: "main", base_sha: "0123456", worktree: "/home/someone/slots/proj/1"}'
  event T14 launch '{role: "builder", session: "59709d99", worktree: "/home/someone/slots/proj/1", toolkits: []}'
  event T14 worktree-added '{project: "conv", branch: "feat/T14-x", base: "dev", base_sha: "89abcde",
    worktree: "/Users/someone/slots/conv/2"}'
  event T14 worktree-returned '{project: "conv", worktree: "/home/other/slots/conv/2"}'
  event T14 worktree-added '{project: "tmp", branch: "feat/T14-y", base: "dev", base_sha: "89abcde", worktree: "/tmp/y"}'
  cp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/before"
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c '[.worktrees[] | [.worktree, .returned]], [.workers[].worktree]' <<<"$output")" \
    "$(jq -cn --arg home "$HOME" '[["\($home)/slots/proj/1", false], ["\($home)/slots/conv/2", true], ["/tmp/y", false]],
      ["\($home)/slots/proj/1"]')"
  cmp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/before"
}

@test "a legacy task's launches recorded under another home show as paths under this HOME" {
  ledger_line '{ts: "2026-10-01T00:00:00Z", task: "T4", event: "launch", role: "builder", session: "59709d99",
    worktree: "/home/danielc/agent-team/.claude/worktrees/1"}'
  run_bin -0 team-state T4 --json
  assert_equal "$(jq -r '.workers[].worktree' <<<"$output")" "$HOME/agent-team/.claude/worktrees/1"
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
     live: true, status: "idle", state: "blocked", context: null},
    {role: "reviewer", session: "3ed2d1f2", launched: "2026-10-22T02:00:00Z", worktree: "/w/1",
     live: false, status: null, state: null, context: null}]')"
  assert_equal "$(stub_calls claude)" '["agents","--json"]'
}

@test "a session is matched by the start of its full session id when it has no short id" {
  open_task
  stub_reply claude '[{"pid": 2, "cwd": "/w/1", "kind": "background", "sessionId": "59709d99-7687-4f7b",
    "name": "T14-builder", "status": "busy", "state": "working"}]'
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c '.workers[0] | [.live, .status, .state]' <<<"$output")" '[true,"busy","working"]'
}

# transcript <session id> <jq array of lines>: the session's transcript under ~/.claude/projects.
transcript() {
  mkdir -p "$HOME/.claude/projects/-w-1"
  jq -c '.[]' <<<"$2" >"$HOME/.claude/projects/-w-1/$1.jsonl"
}

# A reply's transcript line, of the main conversation or (with true) a sidechain's.
reply_line() {
  jq -cn --argjson input "$1" --argjson write "$2" --argjson read "$3" --argjson side "${4:-false}" \
    '{type: "assistant", isSidechain: $side, message: {usage: {input_tokens: $input,
      cache_creation_input_tokens: $write, cache_read_input_tokens: $read, output_tokens: 7}}}'
}

@test "a live worker's context is what its latest main-conversation reply read, a sidechain's after it aside" {
  open_task
  stub_reply claude '[{"id": "59709d99", "sessionId": "59709d99-7687-4f7b", "cwd": "/w/1",
    "name": "T14-builder", "status": "idle", "state": "working"}]'
  transcript 59709d99-7687-4f7b "[$(reply_line 1 2 3), {\"type\": \"user\"}, $(reply_line 10 2000 300000),
    $(reply_line 5 5 900000 true), {\"type\": \"user\", \"isSidechain\": false}]"
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c '.workers[0].context' <<<"$output")" 302010

  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature planning | T14-builder idle 302k"
}

@test "a live worker with no transcript has a null context and no figure" {
  open_task
  stub_reply claude '[{"id": "59709d99", "sessionId": "59709d99-7687-4f7b", "cwd": "/w/1",
    "name": "T14-builder", "status": "idle", "state": "working"}]'
  transcript 3ed2d1f2-1111 "[$(reply_line 10 2000 300000)]"
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c '.workers[0] | [.live, .context]' <<<"$output")" '[true,null]'

  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature planning | T14-builder idle"
}

@test "a session list that cannot be read is refused" {
  open_task
  stub_reply claude 'not json' 1
  run_bin -1 team-state T14
  assert_contains "$output" "team-state: cannot read the live session list (claude agents --json)"
}

@test "T4's real history gives the right phase at each point" {
  cp "$BATS_TEST_DIRNAME/fixtures/projects.toml" "$TEAM_HOME/projects.toml"
  github_down
  local lines=(1 3 50 51 54 57 59 60 61)
  local phases=(planning building in-review awaiting-merge in-review held in-review merged closed)
  local i
  for i in "${!lines[@]}"; do
    fixture_ledger T4 "${lines[$i]}"
    assert_equal "${lines[$i]}: $(phase_of T4)" "${lines[$i]}: ${phases[$i]}"
  done
}

@test "blocked stands until the next resumed or launch, and held wins over blocked" {
  open_task
  event T14 plan-approved '{by: "Daniel"}'
  event T14 blocked '{reason: "a denied push"}'
  assert_equal "$(phase_of T14)" blocked
  event T14 held '{reason: "OS update"}'
  assert_equal "$(phase_of T14)" held
  event T14 resumed
  assert_equal "$(phase_of T14)" building
  event T14 blocked '{reason: "a denied push"}'
  event T14 launch '{role: "builder", session: "3ed2d1f2", worktree: "/w/1", toolkits: []}'
  assert_equal "$(phase_of T14)" building
}

@test "a denied keeps the phase the task had before it: it parks nothing and clears nothing" {
  local denied='{role: "builder", session: "59709d99", what: "Bash", why: "[deny rule] git reset * --hard*"}'
  open_task
  event T14 plan-approved '{by: "Daniel"}'
  event T14 denied "$denied"
  assert_equal "$(phase_of T14)" building
  event T14 blocked '{reason: "the push was refused"}'
  event T14 denied "$denied"
  assert_equal "$(phase_of T14)" blocked
  event T14 resumed
  event T14 held '{reason: "OS update"}'
  event T14 denied "$denied"
  assert_equal "$(phase_of T14)" held
  event T14 resumed
  event T14 pr '{url: "https://github.com/owner/proj/pull/5", head: "a1b2c3d"}'
  event T14 review '{verdict: "pass", head: "a1b2c3d"}'
  event T14 denied "$denied"
  assert_equal "$(phase_of T14)" awaiting-merge
  event T14 merged '{pr: 5, merge: "fedcba9", head: "a1b2c3d", by: "1563"}'
  event T14 denied "$denied"
  assert_equal "$(phase_of T14)" merged
}

@test "merged wins over a held from before it, and closed over merged" {
  open_task
  event T14 held '{reason: "OS update"}'
  event T14 merged '{pr: 5, merge: "fedcba9", head: "a1b2c3d", by: "1563"}'
  assert_equal "$(phase_of T14)" merged
  event T14 closed '{archive: [], returned: [], kept: []}'
  assert_equal "$(phase_of T14)" closed
}

@test "a held or blocked logged after the merge outranks it while it stands, for a later part still to come" {
  open_task
  event T14 merged '{pr: 5, merge: "fedcba9", head: "a1b2c3d", by: "1563"}'
  event T14 blocked '{reason: "the second half waits on T31"}'
  assert_equal "$(phase_of T14)" blocked
  event T14 held '{reason: "OS update"}'
  assert_equal "$(phase_of T14)" held
  event T14 resumed
  assert_equal "$(phase_of T14)" merged
}

@test "a task blocked, relaunched and then merged is merged" {
  open_task
  event T14 blocked '{reason: "a denied push"}'
  event T14 launch '{role: "builder", session: "3ed2d1f2", worktree: "/w/1", toolkits: []}'
  event T14 merged '{pr: 5, merge: "fedcba9", head: "a1b2c3d", by: "1563"}'
  assert_equal "$(phase_of T14)" merged
  # A block still standing from before the merge changes nothing either.
  event T14 blocked '{reason: "a denied push"}'
  event T14 merged '{pr: 6, merge: "0123456", head: "b2c3d4e", by: "1563"}'
  assert_equal "$(phase_of T14)" merged
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

@test "with PRs in two repos, the task awaits merge once each is reviewed and is merged once each is" {
  open_task
  github_down
  event T14 plan-approved '{by: "Daniel"}'
  event T14 pr '{url: "https://github.com/owner/proj/pull/5", head: "1111111"}'
  event T14 pr '{url: "https://github.com/owner/conv/pull/5", head: "2222222"}'
  event T14 review '{verdict: "pass", head: "2222222"}'
  assert_equal "$(phase_of T14)" in-review
  event T14 review '{verdict: "pass", head: "1111111"}'
  assert_equal "$(phase_of T14)" awaiting-merge
  # Both PRs are #5, so the merged event's head says which one merged.
  event T14 merged '{pr: 5, merge: "aaaaaaa", head: "1111111", by: "Daniel"}'
  assert_equal "$(phase_of T14)" awaiting-merge
  event T14 merged '{pr: 5, merge: "bbbbbbb", head: "2222222", by: "Daniel"}'
  assert_equal "$(phase_of T14)" merged
}

@test "a merged event naming its PR's URL marks that PR merged, even at a head the ledger never saw" {
  open_task
  github_down
  event T14 pr '{url: "https://github.com/owner/proj/pull/5", head: "1111111"}'
  event T14 pr '{url: "https://github.com/owner/conv/pull/5", head: "2222222"}'
  event T14 merged '{pr: 5, merge: "aaaaaaa", head: "9999999", by: "Daniel", url: "https://github.com/owner/conv/pull/5"}'
  assert_equal "$(phase_of T14)" in-review
  event T14 merged '{pr: 5, merge: "bbbbbbb", head: "8888888", by: "Daniel", url: "https://github.com/owner/proj/pull/5"}'
  assert_equal "$(phase_of T14)" merged
}

@test "a rewrite from a head the ledger never saw moves the PR's head" {
  open_task
  github_down
  event T14 pr '{url: "https://github.com/owner/proj/pull/5", head: "1111111"}'
  event T14 review '{verdict: "findings", head: "1111111"}'
  # The fix was pushed without a new pr event, then its messages were cleaned.
  event T14 history-rewritten '{project: "proj", branch: "feat/T14-tooling", old_head: "5555555", head: "6666666"}'
  event T14 review '{verdict: "pass", head: "6666666"}'
  assert_equal "$(phase_of T14)" awaiting-merge
}

@test "a later PR in the same repo replaces the earlier one" {
  open_task
  github_down
  event T14 pr '{url: "https://github.com/owner/proj/pull/5", head: "1111111"}'
  event T14 pr '{url: "https://github.com/owner/proj/pull/6", head: "3333333"}'
  event T14 review '{verdict: "pass", head: "3333333"}'
  assert_equal "$(phase_of T14)" awaiting-merge
  event T14 merged '{pr: 6, merge: "aaaaaaa", head: "3333333", by: "Daniel"}'
  assert_equal "$(phase_of T14)" merged
}

@test "a rewrite moves only the head of the PR it started from" {
  open_task
  github_down
  event T14 pr '{url: "https://github.com/owner/proj/pull/5", head: "1111111"}'
  event T14 pr '{url: "https://github.com/owner/conv/pull/3", head: "2222222"}'
  event T14 review '{verdict: "pass", head: "1111111"}'
  event T14 review '{verdict: "pass", head: "2222222"}'
  event T14 history-rewritten '{project: "proj", branch: "feat/T14-tooling", old_head: "1111111", head: "4444444"}'
  assert_equal "$(phase_of T14)" in-review
  event T14 review '{verdict: "pass", head: "4444444"}'
  assert_equal "$(phase_of T14)" awaiting-merge
  # The PR part is the latest PR's (conv's), whose head the rewrite of proj did not move.
  stub_github '{"number": 3, "state": "OPEN", "baseRefName": "main", "headRefOid": "2222222"}' '[]' '[]'
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c '.pr | [.number, .ledger_head, .head_moved]' <<<"$output")" '[3,"2222222",false]'
}

@test "the PR part joins the ledger with the PR, its checks and the required ones on GitHub" {
  open_task
  event T14 pr '{url: "https://github.com/owner/proj/pull/5", head: "1111111"}'
  event T14 history-rewritten "{branch: \"feat/T14-tooling\", old_head: \"1111111\", head: \"${head:0:8}\"}"
  event T14 merge-approved '{url: "https://github.com/owner/proj/pull/5", discord_message: "1564"}'
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
    agent_review: "success", merge_approved: true, standing_word: null}')"
  assert_equal "$(stub_calls gh)" "$(jq -cn '
    ["pr", "view", "5", "--repo", "owner/proj", "--json", "number,state,baseRefName,headRefOid,headRefName,changedFiles"],
    ["pr", "checks", "5", "--repo", "owner/proj", "--json", "name,bucket,state"],
    ["pr", "checks", "5", "--repo", "owner/proj", "--required", "--json", "name,bucket,state"]')"
}

@test "the head moved when GitHub's head is not the ledger's, and approval is per PR, by its URL" {
  open_task
  event T14 pr '{url: "https://github.com/owner/proj/pull/5", head: "1111111"}'
  event T14 pr '{url: "https://github.com/other/repo/pull/5", head: "3333333"}'
  event T14 pr '{url: "https://github.com/owner/proj/pull/5", head: "1111111"}'
  event T14 merge-approved '{url: "https://github.com/owner/proj/pull/4", discord_message: "1564"}'
  event T14 merge-approved '{url: "https://github.com/other/repo/pull/5", discord_message: "1565"}'
  event T14 merge-approved '{pr: 5, discord_message: "1566"}'
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
  # A registry shaped like the team home's, with required checks for agent-team.
  cp "$BATS_TEST_DIRNAME/fixtures/projects.toml" "$TEAM_HOME/projects.toml"
  fixture_ledger T5 22
  stub_github '{"number": 4, "state": "MERGED", "baseRefName": "dev", "headRefOid": "3a66af1c99"}' \
    '[{"name": "shellcheck", "bucket": "pass", "state": "SUCCESS"}]' '[]'
  run_bin -0 team-state T5 --json
  assert_equal "$(jq -c '.pr | [.repo, .project, .number, .ledger_head, .required_missing, .head_moved]' <<<"$output")" \
    '["chanjdaniel/agent-team","agent-team",4,"f5c35825",["data","macos","test","toolkits","zizmor"],true]'
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
  event T14 merge-approved '{url: "https://github.com/owner/proj/pull/5", discord_message: "1564"}'
  stub_reply claude '[{"id": "59709d99", "sessionId": "59709d99-7687", "name": "T14-builder", "status": "idle", "state": "working"}]'
  github_down
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c .pr <<<"$output")" "$(jq -cn --arg head "$head" '{
    url: "https://github.com/owner/proj/pull/5", number: 5, repo: "owner/proj", project: "proj",
    ledger_head: $head, merge_approved: true, standing_word: null,
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

@test "a failed re-home stands until the worktree is made in its project, and the text form names it" {
  open_task
  event T14 worktree-added '{project: "other", branch: "feat/T14-tooling", base: "main", base_sha: "0123456", worktree: "/w/2"}'
  event T14 rehome-failed '{project: "proj", branch: "feat/T14-tooling", machine: "laptop", reason: "the first refusal"}'
  event T14 rehome-failed '{project: "proj", branch: "feat/T14-tooling", machine: "laptop", reason: "the second refusal"}'
  event T14 rehome-failed '{project: "other", branch: "feat/T14-tooling", machine: "laptop", reason: "no slot"}'
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c .rehome_failures <<<"$output")" \
    '[{"project":"proj","branch":"feat/T14-tooling","machine":"laptop","reason":"the second refusal","since":"2026-10-22T02:00:00Z"},{"project":"other","branch":"feat/T14-tooling","machine":"laptop","reason":"no slot","since":"2026-10-22T02:00:00Z"}]'
  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature planning | no live worker | not re-homed: proj on laptop: the second refusal; other on laptop: no slot"

  # A worktree made elsewhere (worktree-moved) or at its recorded path (rehomed) clears its
  # project's failure, and only that one.
  event T14 worktree-moved '{project: "proj", branch: "feat/T14-tooling", from: "/w/1", worktree: "/w/3", machine: "laptop"}'
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c '[.rehome_failures[].project]' <<<"$output")" '["other"]'
  event T14 rehomed '{project: "other", branch: "feat/T14-tooling", worktree: "/w/2", machine: "laptop"}'
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c .rehome_failures <<<"$output")" '[]'
  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature planning | no live worker"

  # A later failure stands again, until the worktree is returned.
  event T14 rehome-failed '{project: "proj", branch: "feat/T14-tooling", machine: "home-pc", reason: "again"}'
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c '[.rehome_failures[] | .machine]' <<<"$output")" '["home-pc"]'
  event T14 worktree-returned '{project: "proj", worktree: "/w/3"}'
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c .rehome_failures <<<"$output")" '[]'
}

@test "waiting stands until the next launch or resumed, and the text form says what it waits on" {
  open_task
  event T14 waiting '{on: "Daniel", reason: "restart the Docker daemons"}'
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c .waiting <<<"$output")" \
    '{"on":"Daniel","reason":"restart the Docker daemons","since":"2026-10-22T02:00:00Z"}'
  assert_equal "$(jq -r .phase <<<"$output")" planning
  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature planning | no live worker | waiting on Daniel: restart the Docker daemons"
  event T14 launch '{role: "builder", session: "3ed2d1f2", worktree: "/w/1", toolkits: []}'
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c .waiting <<<"$output")" null
  event T14 waiting '{on: "a Docker daemon restart", reason: "containers fail"}'
  event T14 resumed
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c .waiting <<<"$output")" null
}

@test "merge_preapproval is null with none logged, else the latest one's facts, withdrawal, opt-in and own" {
  open_task
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c .merge_preapproval <<<"$output")" null
  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature planning | no live worker"

  # proj opts in now and is not the team's own.
  sed -i 's/^merge_method = "merge"$/&\nmerge_with_plan = true/' "$TEAM_HOME/projects.toml"
  event T14 asked '{id: "plan", text: "Approve the plan, and its merge?"}'
  ledger_line '{ts: "2026-10-22T03:00:00Z", task: "T14", event: "merge-preapproved", project: "proj", ask: "plan",
    discord_message: "1563000000000000001", scope: ["src/", "README.md"]}'
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c .merge_preapproval <<<"$output")" "$(jq -cn '{project: "proj", ask: "plan",
    discord_message: "1563000000000000001", scope: ["src/", "README.md"], ts: "2026-10-22T03:00:00Z",
    withdrawn: null, opted_in: true, own: false}')"
  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature planning | no live worker | merge pre-approved"

  # The text says it before any waiting.
  event T14 waiting '{on: "Daniel", reason: "a word on the name"}'
  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature planning | no live worker | merge pre-approved | waiting on Daniel: a word on the name"
  event T14 resumed

  # The registry is read now: a project that no longer opts in says so.
  sed -i '/^merge_with_plan = true$/d' "$TEAM_HOME/projects.toml"
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c '.merge_preapproval | [.opted_in, .own]' <<<"$output")" '[false,false]'
  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature planning | no live worker | merge pre-approved, but proj does not opt in"

  # A withdrawal of it is told, whatever the registry says.
  ledger_line '{ts: "2026-10-22T04:00:00Z", task: "T14", event: "merge-preapproval-withdrawn", project: "proj",
    discord_message: "1563000000000000002"}'
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c .merge_preapproval.withdrawn <<<"$output")" \
    '{"ts":"2026-10-22T04:00:00Z","discord_message":"1563000000000000002"}'
  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature planning | no live worker | merge pre-approval withdrawn"

  # A later approval stands again, and the latest of the task's is the one read.
  sed -i 's/^merge_method = "merge"$/&\nmerge_with_plan = true/' "$TEAM_HOME/projects.toml"
  ledger_line '{ts: "2026-10-22T05:00:00Z", task: "T14", event: "merge-preapproved", project: "proj", ask: "plan",
    discord_message: "1563000000000000003", scope: ["src/"]}'
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c '.merge_preapproval | [.discord_message, .scope, .withdrawn, .opted_in]' <<<"$output")" \
    '["1563000000000000003",["src/"],null,true]'
  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature planning | no live worker | merge pre-approved"
}

@test "a pre-approval of the team's own project says so, by name or by its repo, even opted in" {
  open_task
  sed -i 's/^merge_method = "merge"$/&\nmerge_with_plan = true/' "$TEAM_HOME/projects.toml"
  event T14 asked '{id: "plan", text: "Approve the plan, and its merge?"}'
  event T14 merge-preapproved '{project: "proj", ask: "plan", discord_message: "1563000000000000001", scope: ["src/"]}'
  # proj's repo is the code checkout's origin.
  code_checkout
  git -C "$CODE_CHECKOUT" remote set-url origin git@github.com:Owner/proj.git
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c '.merge_preapproval | [.opted_in, .own]' <<<"$output")" '[true,true]'
  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature planning | no live worker | merge pre-approved, but proj is the team's own project"

  # By name, with the key left out, as the registry must have it.
  cat >>"$TEAM_HOME/projects.toml" <<'TOML'

[agent-team]
repo = "owner/agent-team"
path = "projects/agent-team"
base = "dev"
delivery = "no-mistakes"
merge_method = "merge"
required_checks = []
task_dir = ".scratch/task"
docs = []
toolkits = []

[agent-team.pool]
provider = "git"
slots = ["slots/agent-team/1"]
TOML
  event T14 merge-preapproved '{project: "agent-team", ask: "plan", discord_message: "1563000000000000002", scope: ["bin/"]}'
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c '.merge_preapproval | [.project, .opted_in, .own]' <<<"$output")" '["agent-team",false,true]'
  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature planning | no live worker | merge pre-approved, but agent-team is the team's own project"
}

@test "a pre-approval of a project the registry no longer has does not opt in, and the state is still told" {
  open_task
  event T14 asked '{id: "plan", text: "Approve the plan, and its merge?"}'
  event T14 merge-preapproved '{project: "gone", ask: "plan", discord_message: "1563000000000000001", scope: ["src/"]}'
  run_bin -0 --separate-stderr team-state T14 --json
  assert_equal "$(jq -c '.merge_preapproval | [.project, .opted_in, .own]' <<<"$output")" '["gone",false,false]'
  assert_equal "$stderr" ""
  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature planning | no live worker | merge pre-approved, but gone does not opt in"
}

# T14 awaiting the merge of PR #5 of proj at $head, from its own branch, after a clean pass that
# counted its findings and found no guarded area, with gh answering the PR from its branch with the
# changed files given (src/tooling.py) on one page of GitHub's file list: awaiting_merge [<path>...]
awaiting_merge() {
  local paths=("${@:-src/tooling.py}")
  open_task
  event T14 pr "{url: \"https://github.com/owner/proj/pull/5\", head: \"$head\", project: \"proj\"}"
  event T14 review "{verdict: \"pass\", head: \"${head:0:8}\", guarded: [],
    findings: {blocking: 0, correctness: 0, security: 0, \"real-data\": 0, \"note-change\": 0, \"note-before\": 0}}"
  pr_files "${paths[@]}"
  export GH_VIEW='{"number": 5, "state": "OPEN", "baseRefName": "main", "headRefOid": "'"$head"'",
    "headRefName": "feat/T14-tooling", "changedFiles": '"${#paths[@]}"'}'
  export GH_CHECKS='[{"name": "shellcheck", "bucket": "pass", "state": "SUCCESS"}]' GH_REQUIRED='[]'
  stub_script gh <<'STUB'
case "$1 $2 $*" in
  "pr view"*) echo "$GH_VIEW" ;;
  "pr checks"*--required*) echo "$GH_REQUIRED" ;;
  "pr checks"*) echo "$GH_CHECKS" ;;
  "api repos/owner/proj/pulls/5/files "*" --paginate") cat "$GH_FILES" ;;
  *) echo "unplanned gh call: $*" >&2; exit 1 ;;
esac
STUB
}

# GitHub's list of PR #5's files, one page: pr_files <path>...
pr_files() {
  export GH_FILES=$BATS_TEST_TMPDIR/files.json
  printf '%s\n' "$@" | jq -R '{filename: .}' | jq -cs . >"$GH_FILES"
}

# One standing word event of <task> (T14): standing <kind> <project> <message> [<task>], in #coordinator.
standing() {
  ledger_line --arg t "${4:-T14}" --arg e "$1" --arg p "$2" --arg m "$3" \
    '{ts: "2026-10-22T03:00:00Z", task: $t, event: $e, project: $p, discord_message: $m, discord_channel: "1562486564871995482"}'
}

# Whether gh was asked for PR #5's file list.
files_read() {
  stub_calls gh | jq -e 'select(.[0] == "api" and .[1] == "repos/owner/proj/pulls/5/files")' >/dev/null
}

@test "a task awaiting merge whose PR the standing word covers says so, a word another task logged included" {
  awaiting_merge
  event T9 thread '{discord_thread: "1999"}'
  standing merge-standing all 1563000000000000001 T9
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c '[.phase, .pr.standing_word]' <<<"$output")" "$(jq -cn '["awaiting-merge", {
    word: {project: "all", task: "T9", ts: "2026-10-22T03:00:00Z", discord_message: "1563000000000000001",
      discord_channel: "1562486564871995482"},
    withdrawn: null, covers: true, reasons: []}]')"
  files_read
  assert_equal "$(stub_calls gh | jq -c 'select(.[0:2] == ["pr", "view"]) | .[-1]')" \
    '"number,state,baseRefName,headRefOid,headRefName,changedFiles"'
  run_bin -0 team-state T14
  assert_equal "$output" \
    "T14 proj feature awaiting-merge | no live worker | PR #5 a1b2c3d checks 1/1 agent-review missing | standing word covers it"

  # It is said before any waiting.
  event T14 waiting '{on: "CI", reason: "a rerun"}'
  run_bin -0 team-state T14
  assert_equal "$output" \
    "T14 proj feature awaiting-merge | no live worker | PR #5 a1b2c3d checks 1/1 agent-review missing | standing word covers it | waiting on CI: a rerun"
}

@test "a PR the standing word does not cover names the first reason, how many more, and every one in the JSON" {
  awaiting_merge .github/workflows/ci.yml src/tooling.py
  standing merge-standing proj 1563000000000000001
  event T14 review "{verdict: \"fail\", head: \"1111111\", findings: {security: 1, \"real-data\": 0}, guarded: []}"
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c '.pr.standing_word | [.covers, .reasons]' <<<"$output")" "$(jq -cn '[false, [
    "the review of the head 1111111, at 2026-10-22T02:00:00Z, counted 1 security finding: such a finding on the task, even fixed, comes back to Daniel",
    ".github/workflows/ci.yml is a guarded path (ci): a change there comes back to Daniel"]]')"
  run_bin -0 team-state T14
  assert_equal "${output#*agent-review missing}" \
    " | standing word does not cover it: the review of the head 1111111, at 2026-10-22T02:00:00Z, counted 1 security finding: such a finding on the task, even fixed, comes back to Daniel (and 1 more)"

  # One reason alone has no count; a PR from another branch is one, as team-merge says it.
  : >"$TEAM_HOME/ledger.jsonl"
  awaiting_merge
  standing merge-standing proj 1563000000000000001
  GH_VIEW=${GH_VIEW/feat\/T14-tooling/fix\/other}
  run_bin -0 team-state T14
  assert_equal "${output#*agent-review missing}" \
    " | standing word does not cover it: PR #5 comes from fix/other, not feat/T14-tooling, T14's branch for proj"

  # GitHub it cannot read leaves it uncovered, saying why.
  : >"$TEAM_HOME/ledger.jsonl"
  awaiting_merge
  standing merge-standing proj 1563000000000000001
  github_down
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c '.pr.standing_word | [.covers, .reasons]' <<<"$output")" \
    '[false,["GitHub cannot be read: gh pr view: error connecting to api.github.com"]]'
}

@test "a withdrawn standing word is told as withdrawn, with no file list read" {
  awaiting_merge
  standing merge-standing all 1563000000000000001
  standing merge-standing-withdrawn proj 1563000000000000002
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c '.pr.standing_word | [.word.discord_message, .withdrawn, .covers, .reasons]' <<<"$output")" \
    "$(jq -cn '["1563000000000000001",
      {project: "proj", task: "T14", ts: "2026-10-22T03:00:00Z", discord_message: "1563000000000000002", discord_channel: "1562486564871995482"},
      false,
      ["Daniel'"'"'s standing word on every project, Discord message 1563000000000000001, was withdrawn at 2026-10-22T03:00:00Z in Discord message 1563000000000000002"]]')"
  run ! files_read
  run_bin -0 team-state T14
  assert_equal "${output#*agent-review missing}" " | standing word withdrawn"

  # A word given after it stands again.
  standing merge-standing proj 1563000000000000003
  run_bin -0 team-state T14
  assert_equal "${output#*agent-review missing}" " | standing word covers it"
}

@test "a task not awaiting merge has no standing text, covers null, and reads no file list" {
  awaiting_merge
  standing merge-standing proj 1563000000000000001
  event T14 review "{verdict: \"fail\", head: \"$head\", findings: {blocking: 1}, guarded: []}"
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c '[.phase, .pr.standing_word.word.discord_message, .pr.standing_word.covers, .pr.standing_word.reasons]' <<<"$output")" \
    '["in-review","1563000000000000001",null,[]]'
  run ! files_read
  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature in-review | no live worker | PR #5 a1b2c3d checks 1/1 agent-review missing"

  # Nor does a withdrawn word say anything then.
  standing merge-standing-withdrawn proj 1563000000000000002
  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature in-review | no live worker | PR #5 a1b2c3d checks 1/1 agent-review missing"
}

@test "a task with no standing event for its project has standing_word null and an unchanged line" {
  awaiting_merge
  standing merge-standing other 1563000000000000001
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c '.pr.standing_word' <<<"$output")" null
  run ! files_read
  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature awaiting-merge | no live worker | PR #5 a1b2c3d checks 1/1 agent-review missing"
}
