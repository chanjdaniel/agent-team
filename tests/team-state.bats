#!/usr/bin/env bats
# team-state: where one task stands, from its ledger events, the live session list and GitHub.

load helpers/common

setup() {
  sandbox
  # shellcheck disable=SC2153 # TEAM_HOME is the sandbox's, not a misspelt TEAM_CHROME
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

# The opened task T14 of project proj, with its thread and a builder's launch, which puts the
# feature task in building with no plan-approved (the lifecycle's launch rule), so every test
# built on it reads building where it read planning before the lifecycle fold.
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
# from the JSON given (or from $view, $checks and $required), and gh api's compare of its base and
# head from the fourth (or $compare), failing as an unreadable compare when that is empty or unset.
stub_github() {
  export GH_VIEW=${1:-$view} GH_CHECKS=${2:-$checks} GH_REQUIRED=${3:-$required} GH_COMPARE=${4:-${compare:-}}
  stub_script gh <<'EOF'
case "$1 $2 $*" in
  "pr view"*) echo "$GH_VIEW" ;;
  "api repos/"*/compare/*)
    if [[ -n $GH_COMPARE ]]; then echo "$GH_COMPARE"; else echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi ;;
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

# proj made the team's own (its repo the code checkout's origin), with the reviewer App on (App
# 123456 in the code checkout's bin/lib/review-app); gh answers PR #5 open on main at the head,
# agent-review SUCCESS among its checks, its agent-review check runs from $GH_DIR/runs.json and its
# combined status from $GH_DIR/status.json: app_on
app_on() {
  code_checkout
  git -C "$CODE_CHECKOUT" remote set-url origin https://github.com/owner/proj.git
  rm -f "$CODE_CHECKOUT/bin/lib/review-app"
  printf 'id=123456\nslug=team-reviewer\n' >"$CODE_CHECKOUT/bin/lib/review-app"
  export GH_DIR=$BATS_TEST_TMPDIR/gh GH_HEAD=$head
  mkdir -p "$GH_DIR"
  echo '{"statuses": []}' >"$GH_DIR/status.json"
  stub_script gh <<'STUB'
case "$1 $2 $*" in
  "pr view"*) echo "{\"number\": 5, \"state\": \"OPEN\", \"baseRefName\": \"main\", \"headRefOid\": \"$GH_HEAD\"}" ;;
  "pr checks"*--required*) echo '[]' ;;
  "pr checks"*) echo '[{"name": "agent-review", "bucket": "pass", "state": "SUCCESS"}]' ;;
  "api repos/owner/proj/compare/"*) echo 0 ;;
  "api repos/owner/proj/commits/$GH_HEAD/check-runs?check_name=agent-review&filter=latest&per_page=100 "*) cat "$GH_DIR/runs.json" ;;
  "api repos/owner/proj/commits/$GH_HEAD/status "*) cat "$GH_DIR/status.json" ;;
  *) echo "unplanned gh call: $*" >&2; exit 1 ;;
esac
STUB
}

# The head's agent-review check runs, each "<id> <conclusion> <app id> [<sha>]": runs <run>...
runs() {
  local run id conclusion app sha out='[]'
  for run in "$@"; do
    read -r id conclusion app sha <<<"$run"
    out=$(jq -c --argjson id "$id" --arg c "$conclusion" --argjson app "${app:-123456}" --arg sha "${sha:-$head}" \
      '. + [{id: $id, name: "agent-review", head_sha: $sha, status: "completed", conclusion: $c,
        app: {id: $app, slug: (if $app == 123456 then "team-reviewer" else "github-actions" end)}}]' <<<"$out")
  done
  jq -c '{total_count: length, check_runs: .}' <<<"$out" >"$GH_DIR/runs.json"
}

# The head's combined status: an agent-review success by chanjdaniel, or none.
review_status() {
  if [[ ${1:-} == none ]]; then
    echo '{"statuses": []}' >"$GH_DIR/status.json"
  else
    echo '{"statuses": [{"context": "agent-review", "state": "success", "creator": {"login": "chanjdaniel"}}]}' >"$GH_DIR/status.json"
  fi
}

# The App's facts of the PR part now are <expected>, [review_app, review_check, review_check_run,
# review_check_by] as JSON: review_facts <expected>
review_facts() {
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c '.pr | [.review_app, .review_check, .review_check_run, .review_check_by]' <<<"$output")" "$1"
  # agent_review stays gh pr checks' state.
  assert_equal "$(jq -r .pr.agent_review <<<"$output")" success
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
    phase: "building",
    worktrees: [
      {project: "proj", branch: "feat/T14-tooling", worktree: "/w/1", ticket: null, returned: false},
      {project: "conv", branch: "feat/T14-x", worktree: "/t/2", ticket: null, returned: true}],
    thread: "1563",
    last_event: {ts: "2026-10-22T02:00:00Z", task: "T14", event: "answered", id: "q1", answer: "team-state"},
    pending_asks: [{id: "q2", text: "Ship it?", ts: "2026-10-22T02:00:00Z"}],
    waiting: null, parks: [], stowing: null, walk: null, rehome_failures: [], checks_wait: null, pr: null,
    progress: {tickets: {done: [], total: 0, graph: null}, on: [],
      reviews: {count: 0, verdict: null, head: null, sent_back: null}}}')"
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

@test "an ask is settled by a later merge-preapproved naming its id, a kind retired by T276 read for history, as by an answered" {
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
    {role: "builder", session: "59709d99", name: "T14-builder", ticket: null, launched: "2026-10-22T02:00:00Z", worktree: "/w/1",
     live: true, status: "idle", state: "blocked", context: null, brief: null},
    {role: "reviewer", session: "3ed2d1f2", name: "T14-reviewer", ticket: null, launched: "2026-10-22T02:00:00Z", worktree: "/w/1",
     live: false, status: null, state: null, context: null, brief: null}]')"
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
  assert_equal "$output" "T14 proj feature building | T14-builder idle 302k"
}

@test "a live worker with no transcript has a null context and no figure" {
  open_task
  stub_reply claude '[{"id": "59709d99", "sessionId": "59709d99-7687-4f7b", "cwd": "/w/1",
    "name": "T14-builder", "status": "idle", "state": "working"}]'
  transcript 3ed2d1f2-1111 "[$(reply_line 10 2000 300000)]"
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c '.workers[0] | [.live, .context]' <<<"$output")" '[true,null]'

  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature building | T14-builder idle"
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

@test "a held from before the merge shows over merged while it stands, and closed over both" {
  open_task
  event T14 held '{reason: "OS update"}'
  event T14 merged '{pr: 5, merge: "fedcba9", head: "a1b2c3d", by: "1563"}'
  # The lifecycle's precedence: a standing held shows over merged wherever it was logged (it was
  # merged before the fold, which hid a held logged before the merge).
  assert_equal "$(phase_of T14)" held
  event T14 resumed
  assert_equal "$(phase_of T14)" merged
  event T14 closed '{archive: [], returned: [], kept: []}'
  assert_equal "$(phase_of T14)" closed
}

@test "a held or blocked logged after the merge outranks it while it stands" {
  open_task
  event T14 merged '{pr: 5, merge: "fedcba9", head: "a1b2c3d", by: "1563"}'
  event T14 blocked '{reason: "the second half waits on T31"}'
  assert_equal "$(phase_of T14)" blocked
  event T14 held '{reason: "OS update"}'
  assert_equal "$(phase_of T14)" held
  event T14 resumed
  assert_equal "$(phase_of T14)" merged
}

@test "a merged naming phases left reads merged-part on the line, and a builder's launch after it building" {
  open_task
  event T14 merged '{pr: 5, merge: "fedcba9", head: "a1b2c3d", by: "1563", phases_left: [2, 3]}'
  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature merged-part | no live worker"
  event T14 launch '{role: "builder", session: "3ed2d1f2", worktree: "/w/1", toolkits: []}'
  assert_equal "$(phase_of T14)" building
  event T14 merged '{pr: 6, merge: "0123456", head: "b2c3d4e", by: "1563", phases_left: []}'
  assert_equal "$(phase_of T14)" merged
}

@test "a task blocked, relaunched and then merged is merged" {
  open_task
  event T14 blocked '{reason: "a denied push"}'
  event T14 launch '{role: "builder", session: "3ed2d1f2", worktree: "/w/1", toolkits: []}'
  event T14 merged '{pr: 5, merge: "fedcba9", head: "a1b2c3d", by: "1563"}'
  assert_equal "$(phase_of T14)" merged
  # A block still standing from before the merge shows over it (the lifecycle's precedence; it
  # read merged before the fold), until a launch ends it.
  event T14 blocked '{reason: "a denied push"}'
  event T14 merged '{pr: 6, merge: "0123456", head: "b2c3d4e", by: "1563"}'
  assert_equal "$(phase_of T14)" blocked
  event T14 launch '{role: "reviewer", session: "4fe3e2a3", worktree: "/w/1", toolkits: []}'
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

@test "a pass that sent findings back, logged through team-log, leaves the task in review until a pass sends none" {
  open_task
  github_down
  event T14 pr '{url: "https://github.com/owner/proj/pull/5", head: "a1b2c3d"}'
  local counts='findings=blocking:0,correctness:1,security:0,real-data:0,note-change:0,note-before:0'
  run_bin -0 team-log T14 review verdict=pass head=a1b2c3d "$counts" sent_back=1 guarded=none
  assert_equal "$(phase_of T14)" in-review
  run_bin -0 team-log T14 review verdict=pass head=a1b2c3d "$counts" sent_back=none guarded=none
  assert_equal "$(phase_of T14)" awaiting-merge
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
  compare=0
  stub_github
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c '.pr | del(.merge_authority)' <<<"$output")" "$(jq -cn --arg head "$head" '{
    url: "https://github.com/owner/proj/pull/5", number: 5, repo: "owner/proj", project: "proj",
    state: "open", base: "main", branch: null, head: $head, ledger_head: $head[:8], head_moved: false,
    caught_up: false, checks: {passed: ["agent-review", "docs", "shellcheck"], failing: ["deploy", "lint"], pending: ["build"]},
    required: ["build", "shellcheck", "test"], required_missing: ["test"],
    agent_review: "success", merge_approved: true, behind_by: 0,
    review_app: null, review_check: null, review_check_run: null, review_check_by: null}')"
  # The words, as merge_authority derives them: a legacy merge-approved, naming no head, holds on
  # the ledger for the PR's latest pr event; no plan is approved.
  assert_equal "$(jq -c '.pr.merge_authority | [.word, [.words[] | .word, .applies, .holds]]' <<<"$output")" \
    '["head",["head",true,true,"default",false,false]]'
  assert_equal "$(stub_calls gh)" "$(jq -cn --arg head "$head" '
    ["pr", "view", "5", "--repo", "owner/proj", "--json", "number,state,baseRefName,headRefOid,headRefName,changedFiles"],
    ["pr", "checks", "5", "--repo", "owner/proj", "--json", "name,bucket,state"],
    ["pr", "checks", "5", "--repo", "owner/proj", "--required", "--json", "name,bucket,state"],
    ["api", "repos/owner/proj/compare/main...\($head)", "--jq", ".behind_by"]')"
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

@test "the team's own project's PR part, with the reviewer App on, reads the App's check run on the head, and the line names it" {
  open_task
  event T14 pr "{url: \"https://github.com/owner/proj/pull/5\", head: \"$head\", project: \"proj\"}"
  app_on
  runs "4242 success"
  review_facts '[123456,"success",4242,null]'
  # The App's latest run counts, and a status beside it is not read.
  runs "4242 success" "4243 failure"
  review_status
  review_facts '[123456,"failure",4243,null]'
  runs "5150 success 15368"
  review_status none
  review_facts '[123456,"foreign",null,"a check run of App 15368 (github-actions)"]'
  runs "4242 success 123456 1111111111111111111111111111111111111111"
  review_facts '[123456,"missing",null,null]'
  runs
  review_status
  review_facts '[123456,"foreign",null,"a commit status by chanjdaniel"]'
  review_status none
  review_facts '[123456,"missing",null,null]'

  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature in-review | no live worker | PR #5 a1b2c3d checks 1/1 agent-review missing (the reviewer App's check)"
  runs "4242 success"
  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature in-review | no live worker | PR #5 a1b2c3d checks 1/1 agent-review success (the reviewer App's check)"
  runs
  review_status
  run_bin -0 team-state T14
  assert_equal "$output" \
    "T14 proj feature in-review | no live worker | PR #5 a1b2c3d checks 1/1 agent-review foreign (a commit status by chanjdaniel, not the reviewer App's check)"
}

@test "with the reviewer App on, another project's PR part reads no check run, and a check run read that fails is GitHub unavailable" {
  open_task
  event T14 pr "{url: \"https://github.com/owner/proj/pull/5\", head: \"$head\", project: \"proj\"}"
  app_on
  # proj is not the team's own once the code checkout's origin is another repo.
  git -C "$CODE_CHECKOUT" remote set-url origin https://github.com/owner/other.git
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c '.pr | [.review_app, .review_check, .agent_review, .error]' <<<"$output")" '[null,null,"success",null]'
  [[ -z $(stub_calls gh | jq -c 'select(.[1] // "" | test("/commits/"))') ]]
  # The team's own again, with GitHub refusing the check runs.
  git -C "$CODE_CHECKOUT" remote set-url origin https://github.com/owner/proj.git
  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature in-review | no live worker | PR #5 GitHub unavailable"
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
  assert_equal "$(stub_calls gh | jq -r 'if .[0] == "api" then .[1] | split("/")[1:3] | join("/") else .[4] end' | sort -u)" \
    "owner/proj"
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
  assert_equal "$(jq -c '.pr | del(.merge_authority)' <<<"$output")" "$(jq -cn --arg head "$head" '{
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
    "T14 proj feature awaiting-merge | no live worker | review 1 pass | PR #5 merged a1b2c3d (head moved) checks 1/2 agent-review success | checks waiting"
}

@test "a head team-catch-up made from the ledger head is caught up cleanly, not moved" {
  open_task
  event T14 pr '{url: "https://github.com/owner/proj/pull/5", head: "1111111"}'
  event T14 review '{verdict: "pass", head: "1111111"}'
  event T14 caught-up "{url: \"https://github.com/owner/proj/pull/5/\", from: \"11111110000000000000000000000000000000000\",
    head: \"$head\", base: \"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"}"
  stub_github '{"number": 5, "state": "OPEN", "baseRefName": "main", "headRefOid": "'"$head"'", "headRefName": "feat/T14-tooling"}' \
    '[{"name": "agent-review", "bucket": "pass", "state": "SUCCESS"}]' '[]'
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c '.pr | [.branch, .ledger_head, .head_moved, .caught_up]' <<<"$output")" \
    '["feat/T14-tooling","1111111",true,true]'
  run_bin -0 team-state T14
  assert_equal "$output" \
    "T14 proj feature awaiting-merge | no live worker | review 1 pass | PR #5 a1b2c3d (caught up cleanly with main) checks 1/1 agent-review success | checks waiting"
}

@test "a moved head that no latest caught-up event of the PR made from the ledger head is moved, not caught up" {
  local step
  open_task
  event T14 pr '{url: "https://github.com/owner/proj/pull/5", head: "1111111"}'
  event T14 review '{verdict: "pass", head: "1111111"}'
  stub_github '{"number": 5, "state": "OPEN", "baseRefName": "main", "headRefOid": "'"$head"'"}' \
    '[{"name": "agent-review", "bucket": "pass", "state": "SUCCESS"}]' '[]'
  # up <from> <head> [<url>]: a caught-up event of PR #5, or of the URL given.
  up() {
    event T14 caught-up "{url: \"${3:-https://github.com/owner/proj/pull/5}\", from: \"$1\", head: \"$2\", base: \"bbbbbbb\"}"
  }
  # No caught-up event, one of another PR, one from another head, and one to another head.
  for step in : "up 1111111 $head https://github.com/owner/proj/pull/6" "up 2222222 $head" "up 1111111 3333333"; do
    eval "$step"
    run_bin -0 team-state T14 --json
    assert_equal "$(jq -c '.pr | [.head_moved, .caught_up]' <<<"$output")" '[true,false]'
    run_bin -0 team-state T14
    assert_contains "$output" "PR #5 a1b2c3d (head moved) checks 1/1"
  done
  # The latest event of the PR is the one that counts: an earlier one that made the head does not.
  up 1111111 "$head"
  up 1111111 3333333
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c '.pr.caught_up' <<<"$output")" false
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
  assert_equal "$output" "T14 proj feature building | no live worker | not re-homed: proj on laptop: the second refusal; other on laptop: no slot"

  # A worktree made elsewhere (worktree-moved) or at its recorded path (rehomed) clears its
  # project's failure, and only that one.
  event T14 worktree-moved '{project: "proj", branch: "feat/T14-tooling", from: "/w/1", worktree: "/w/3", machine: "laptop"}'
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c '[.rehome_failures[].project]' <<<"$output")" '["other"]'
  event T14 rehomed '{project: "other", branch: "feat/T14-tooling", worktree: "/w/2", machine: "laptop"}'
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c .rehome_failures <<<"$output")" '[]'
  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature building | no live worker"

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
  assert_equal "$(jq -r .phase <<<"$output")" building
  run_bin -0 team-state T14
  # The line shows the standing parks in place of the waiting part.
  assert_equal "$output" "T14 proj feature building | no live worker | parks: waiting-1 daniel since 2026-10-22T02:00:00Z: restart the Docker daemons"
  event T14 launch '{role: "builder", session: "3ed2d1f2", worktree: "/w/1", toolkits: []}'
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c .waiting <<<"$output")" null
  event T14 waiting '{on: "a Docker daemon restart", reason: "containers fail"}'
  event T14 resumed
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c .waiting <<<"$output")" null
}

@test "parks lists the standing parks with their ids and causes, a typed one's own and an old one's legacy_cause, in the JSON and on the line" {
  open_task
  # An old line, with no cause, and typed lines as team-log and team-ask log them.
  event T14 blocked '{reason: "Bash(git push) denied by a deny rule"}'
  ledger_line '{ts: "2026-10-22T02:10:00Z", task: "T14", event: "paused", reason: "stowed, handoff written", cause: "stow",
    role: "builder", session: "59709d99"}'
  ledger_line '{ts: "2026-10-22T02:20:00Z", task: "T14", event: "waiting", on: "Daniel", cause: "ask", ask: "naming",
    reason: "ask naming", since: "2026-10-22T02:15:00Z"}'
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c .parks <<<"$output")" "$(jq -cn '[
    {id: "blocked-1", kind: "blocked", cause: "denial", on: null, reason: "Bash(git push) denied by a deny rule", since: "2026-10-22T02:00:00Z", passed: false},
    {id: "paused-1", kind: "paused", cause: "stow", on: null, reason: "stowed, handoff written", since: "2026-10-22T02:10:00Z", passed: false},
    {id: "waiting-1", kind: "waiting", cause: "ask", on: "Daniel", reason: "ask naming", since: "2026-10-22T02:15:00Z", passed: false}]')"
  # waiting stays in the JSON beside it.
  assert_equal "$(jq -c .waiting <<<"$output")" '{"on":"Daniel","reason":"ask naming","since":"2026-10-22T02:20:00Z"}'
  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature blocked | no live worker | parks: blocked-1 denial since 2026-10-22T02:00:00Z: Bash(git push) denied by a deny rule; paused-1 stow since 2026-10-22T02:10:00Z: stowed, handoff written; waiting-1 ask since 2026-10-22T02:15:00Z: ask naming"
  # With none standing, the JSON lists none and the line has no parks part: all=true ends the
  # block and the pause, and the ask's answer its typed wait.
  event T14 resumed '{all: true}'
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c '.parks | map(.id)' <<<"$output")" '["waiting-1"]'
  event T14 answered '{id: "naming", answer: "the short one"}'
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c .parks <<<"$output")" '[]'
  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature building | no live worker"
}

@test "a stow under way shows as stowing since its time, in the JSON and on the line, until its stowed or stow-failed" {
  open_task
  ledger_line '{ts: "2026-10-22T03:00:00Z", task: "T14", event: "stowing", machine: "home-pc", cause: "level", roles: ["builder"]}'
  ledger_line '{ts: "2026-10-22T03:01:00Z", task: "T14", event: "paused", reason: "stowed", cause: "stow"}'
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c .stowing <<<"$output")" '{"since":"2026-10-22T03:00:00Z","cause":"level"}'
  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature building | no live worker | stowing since 2026-10-22T03:00:00Z | parks: paused-1 stow since 2026-10-22T03:01:00Z: stowed"
  for kind in stowed stow-failed; do
    cp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/ledger.before"
    ledger_line --arg kind "$kind" '{ts: "2026-10-22T03:05:00Z", task: "T14", event: $kind, machine: "home-pc",
      worktrees: [], roles: ["builder"], reason: "x"}'
    run_bin -0 team-state T14 --json
    assert_equal "$(jq -c .stowing <<<"$output")" null
    run_bin -0 team-state T14
    assert_equal "$output" "T14 proj feature building | no live worker | parks: paused-1 stow since 2026-10-22T03:01:00Z: stowed"
    mv "$BATS_TEST_TMPDIR/ledger.before" "$TEAM_HOME/ledger.jsonl"
  done
}

@test "an ask's wait a launch went past says so on the line" {
  # state_line over a state whose ask's wait is passed, as phase 2's launch past an ask leaves it.
  run jq -L "$REPO_ROOT/bin/lib" -nr --slurpfile contract "$REPO_ROOT/bin/lib/ledger-contract.json" \
    'include "ledger"; {task: "T14", project: "proj", path: "feature", phase: "building", workers: [],
      parks: [{id: "waiting-2", kind: "waiting", cause: "ask", on: "Daniel", reason: "ask naming", since: "2026-10-22T02:15:00Z", passed: true}]}
    | state_line'
  assert_equal "$output" "T14 proj feature building | no live worker | parks: waiting-2 ask since 2026-10-22T02:15:00Z: ask naming (passed by a launch)"
}

@test "a walk that is on shows with its start, before any waiting part, until it is off or the task closes" {
  open_task
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c .walk <<<"$output")" null
  ledger_line '{ts: "2026-10-22T03:00:00Z", task: "T14", event: "walk", state: "on"}'
  ledger_line '{ts: "2026-10-22T03:05:00Z", task: "T15", event: "walk", state: "off"}'
  event T14 waiting '{on: "Daniel", reason: "walk the import page"}'
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c .walk <<<"$output")" '{"since":"2026-10-22T03:00:00Z"}'
  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature building | no live worker | walk on since 2026-10-22T03:00:00Z | parks: waiting-1 daniel since 2026-10-22T02:00:00Z: walk the import page"
  # An off ends it; the next on starts another, from its own time.
  ledger_line '{ts: "2026-10-22T04:00:00Z", task: "T14", event: "walk", state: "off"}'
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c .walk <<<"$output")" null
  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature building | no live worker | parks: waiting-1 daniel since 2026-10-22T02:00:00Z: walk the import page"
  ledger_line '{ts: "2026-10-22T05:00:00Z", task: "T14", event: "walk", state: "on"}'
  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature building | no live worker | walk on since 2026-10-22T05:00:00Z | parks: waiting-1 daniel since 2026-10-22T02:00:00Z: walk the import page"
  # A walk left on ends with its task.
  ledger_line '{ts: "2026-10-22T06:00:00Z", task: "T14", event: "closed", archive: [], returned: [], kept: []}'
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c .walk <<<"$output")" null
  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature closed | no live worker | parks: waiting-1 daniel since 2026-10-22T02:00:00Z: walk the import page"
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

# T14's plan approved by the coordinator, as team-log records it, its scope src/ and README.md.
approved() {
  event T14 plan-approved '{by: "coordinator", plan: {"tasks/T14/plan.md": "0000"}, scope: ["src/", "README.md"]}'
}

# A withdrawal of the default word or its giving back, of <task> (T14): said <kind> <scope> <message> [<task>],
# in #coordinator.
said() {
  ledger_line --arg t "${4:-T14}" --arg e "$1" --arg s "$2" --arg m "$3" \
    '{ts: "2026-10-22T03:00:00Z", task: $t, event: $e, scope: $s, discord_message: $m, discord_channel: "1562486564871995482"}'
}

# Whether gh was asked for PR #5's file list.
files_read() {
  stub_calls gh | jq -e 'select(.[0] == "api" and .[1] == "repos/owner/proj/pulls/5/files")' >/dev/null
}

@test "a task awaiting merge whose PR the default word covers says so, the PR's files read" {
  awaiting_merge
  approved
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c '[.phase, .pr.merge_authority.word, (.pr.merge_authority.words[] | [.word, .applies, .holds, .reasons])]' <<<"$output")" \
    "$(jq -cn '["awaiting-merge", "default",
      ["head", false, false, ["no merge-approved event for https://github.com/owner/proj/pull/5: Daniel'"'"'s word is not recorded"]],
      ["default", true, true, []]]')"
  assert_equal "$(jq -c '.pr.merge_authority.words[1].facts | [.by, .scope, .branch, .withdrawn, .restored]' <<<"$output")" \
    '["coordinator",["src/","README.md"],"feat/T14-tooling",null,null]'
  files_read
  assert_equal "$(stub_calls gh | jq -c 'select(.[0:2] == ["pr", "view"]) | .[-1]')" \
    '"number,state,baseRefName,headRefOid,headRefName,changedFiles"'
  run_bin -0 team-state T14
  assert_equal "$output" \
    "T14 proj feature awaiting-merge | no live worker | review 1 pass | PR #5 a1b2c3d checks 1/1 agent-review missing | checks waiting | default word covers it"

  # It is said before any waiting.
  event T14 waiting '{on: "CI", reason: "a rerun"}'
  run_bin -0 team-state T14
  assert_equal "$output" \
    "T14 proj feature awaiting-merge | no live worker | review 1 pass | PR #5 a1b2c3d checks 1/1 agent-review missing | checks waiting | default word covers it | parks: waiting-1 outside since 2026-10-22T02:00:00Z: a rerun"
}

@test "a PR of the team's own project has the default word's one reason, with no file list read" {
  awaiting_merge
  approved
  # proj's repo is the code checkout's origin, so proj is the team's own.
  code_checkout
  git -C "$CODE_CHECKOUT" remote set-url origin https://github.com/owner/proj.git
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c '.pr.merge_authority | [.word, .words[1].reasons]' <<<"$output")" \
    "[null,[\"the team's own project merges unattended only behind the reviewer App's check, which is not set up\"]]"
  run ! files_read
  run_bin -0 team-state T14
  assert_equal "${output#*agent-review missing}" \
    " | checks waiting | default word does not cover it: the team's own project merges unattended only behind the reviewer App's check, which is not set up"
}

@test "a PR the default word does not cover names the first reason, how many more, and every one in the JSON" {
  awaiting_merge .github/workflows/ci.yml src/tooling.py
  approved
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c '.pr.merge_authority | [.word, .words[1].holds, .words[1].reasons]' <<<"$output")" "$(jq -cn '[null, false, [
    ".github/workflows/ci.yml is a guarded path (ci): a change there comes back to Daniel",
    ".github/workflows/ci.yml is outside the approved plan'"'"'s scope: src/, README.md"]]')"
  run_bin -0 team-state T14
  assert_equal "${output#*agent-review missing}" \
    " | checks waiting | default word does not cover it: .github/workflows/ci.yml is a guarded path (ci): a change there comes back to Daniel (and 1 more)"

  # A ledger reason is named alone, with no file list read.
  event T14 review "{verdict: \"fail\", head: \"1111111\", findings: {security: 1, \"real-data\": 0}, guarded: []}"
  : >"$STUB_CALLS/gh.log"
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c '.pr.merge_authority.words[1].reasons' <<<"$output")" "$(jq -cn '[
    "the review of the head 1111111, at 2026-10-22T02:00:00Z, counted 1 security finding: such a finding on the task, even fixed, comes back to Daniel"]')"
  run ! files_read

  # One reason alone has no count; a PR from another branch is one, as team-merge says it.
  : >"$TEAM_HOME/ledger.jsonl"
  awaiting_merge
  approved
  GH_VIEW=${GH_VIEW/feat\/T14-tooling/fix\/other}
  run_bin -0 team-state T14
  assert_equal "${output#*agent-review missing}" \
    " | checks waiting | default word does not cover it: PR #5 comes from fix/other, not feat/T14-tooling, T14's branch for proj"

  # GitHub it cannot read leaves it uncovered, saying why.
  : >"$TEAM_HOME/ledger.jsonl"
  awaiting_merge
  approved
  github_down
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c '.pr.merge_authority | [.word, .words[1].reasons]' <<<"$output")" \
    '[null,["GitHub cannot be read: gh pr view: error connecting to api.github.com"]]'
}

@test "a withdrawn default word is told as withdrawn, with no file list read, until it is given back" {
  awaiting_merge
  approved
  said merge-default-withdrawn proj 1563000000000000001 T9
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c '.pr.merge_authority.words[1] | [.holds, .reasons, .facts.withdrawn.discord_message]' <<<"$output")" \
    "$(jq -cn '[false,
      ["the default word was withdrawn for project proj at 2026-10-22T03:00:00Z in Discord message 1563000000000000001, and not given back since"],
      "1563000000000000001"]')"
  run ! files_read
  run_bin -0 team-state T14
  assert_equal "${output#*agent-review missing}" " | checks waiting | default word withdrawn"

  # Given back for every project, it covers the PR again; Daniel's message is team-merge's to read.
  said merge-default-restored all 1563000000000000002
  run_bin -0 team-state T14
  assert_equal "${output#*agent-review missing}" " | checks waiting | default word covers it"
}

@test "a task not awaiting merge, or with no plan approved, has no default word text and reads no file list" {
  awaiting_merge
  approved
  event T14 review "{verdict: \"fail\", head: \"$head\", findings: {blocking: 1}, guarded: []}"
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c '[.phase, .pr.merge_authority.words[1].applies, .pr.merge_authority.words[1].reasons]' <<<"$output")" \
    "$(jq -cn '["in-review", true, ["the latest review of the head a1b2c3d, at 2026-10-22T02:00:00Z, is fail, not pass"]]')"
  run ! files_read
  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature in-review | no live worker | review 2 fail | PR #5 a1b2c3d checks 1/1 agent-review missing"

  # With no plan approved, the default word does not apply, and the line says nothing of it.
  : >"$TEAM_HOME/ledger.jsonl"
  awaiting_merge
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c '.pr.merge_authority.words[1] | [.applies, .reasons]' <<<"$output")" \
    '[false,["T14 has no approved plan: no plan-approved is logged"]]'
  run ! files_read
  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature awaiting-merge | no live worker | review 1 pass | PR #5 a1b2c3d checks 1/1 agent-review missing | checks waiting"
}

@test "checks_wait is what the latest pass waits on, null with none, and the line says checks <state> while one stands" {
  awaiting_merge
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c .checks_wait <<<"$output")" \
    "$(jq -cn --arg head "$head" '{url: "https://github.com/owner/proj/pull/5", reviewed: $head[:8], head: $head[:8],
      since: "2026-10-22T02:00:00Z", state: "waiting", reruns: []}')"
  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature awaiting-merge | no live worker | review 1 pass | PR #5 a1b2c3d checks 1/1 agent-review missing | checks waiting"

  # The checks wait's ends, as team-next T14 --ci logs them, each the state shown.
  local outcome
  for outcome in pending infrastructure failed passed; do
    ledger_line --arg head "$head" --arg o "$outcome" \
      '{ts: "2026-10-22T03:00:00Z", task: "T14", event: "ci", url: "https://github.com/owner/proj/pull/5", head: $head, outcome: $o}'
    run_bin -0 team-state T14 --json
    assert_equal "$(jq -c '.checks_wait | [.state, .since]' <<<"$output")" "[\"$outcome\",\"2026-10-22T03:00:00Z\"]"
    run_bin -0 team-state T14
    assert_equal "$output" "T14 proj feature awaiting-merge | no live worker | review 1 pass | PR #5 a1b2c3d checks 1/1 agent-review missing | checks $outcome"
  done

  # A review that is not a pass stands no wait: null, and nothing on the line.
  event T14 review "{verdict: \"findings\", head: \"$head\", findings: {blocking: 1, correctness: 0, security: 0, \"real-data\": 0, \"note-change\": 0, \"note-before\": 0}, sent_back: [1], guarded: []}"
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c .checks_wait <<<"$output")" null
  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature in-review | no live worker | review 2 findings, sent back 1 | PR #5 a1b2c3d checks 1/1 agent-review missing"
}

# The task T14 of project proj opened in a worktree that is a real directory, with <n> tickets in
# its task directory, each blocked by none: progress_task <n>
progress_task() {
  local wt=$BATS_TEST_TMPDIR/wt n
  mkdir -p "$wt/.scratch/task/tickets"
  for ((n = 1; n <= $1; n++)); do
    printf '# %02d: ticket %d\n\nBlocked by: None\n' "$n" "$n" >"$wt/.scratch/task/tickets/$(printf %02d "$n")-ticket-$n.md"
  done
  event T14 opened "$(jq -cn --arg wt "$wt" '{project: "proj", path: "feature", type: "feat", title: "The tooling",
    branch: "feat/T14-tooling", base: "main", base_sha: "0123456", worktree: $wt}')"
  event T14 plan-approved '{by: "Daniel"}'
}

@test "progress says how many tickets are done of the task's ticket files, and the brief each live worker is on" {
  progress_task 7
  local n
  for n in 01 02 03; do
    event T14 launch "{role: \"builder\", session: \"1111111$n\", worktree: \"/w/1\", toolkits: [], brief: \"brief-build-$n\"}"
    event T14 ticket-done "{ticket: \"$n\", commits: [\"a0017cce\"]}"
  done
  event T14 launch '{role: "builder", session: "59709d99", worktree: "/w/1", toolkits: [], brief: "brief-build-04"}'
  event T14 launch '{role: "ops", session: "3ed2d1f2", worktree: "/w/1", toolkits: []}'
  stub_reply claude '[
    {"id": "59709d99", "sessionId": "59709d99-7687", "name": "T14-builder", "status": "idle", "state": "working"},
    {"id": "3ed2d1f2", "sessionId": "3ed2d1f2-1111", "name": "T14-ops", "status": "busy", "state": "working"}]'
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c .progress <<<"$output")" "$(jq -cn '{
    tickets: {done: ["01", "02", "03"], total: 7, graph: null},
    on: [{role: "builder", session: "59709d99", brief: "brief-build-04"}, {role: "ops", session: "3ed2d1f2", brief: null}],
    reviews: {count: 0, verdict: null, head: null, sent_back: null}}')"
  assert_equal "$(jq -c '[.workers[] | .brief]' <<<"$output")" \
    '["brief-build-01","brief-build-02","brief-build-03","brief-build-04",null]'
  assert_equal "$(jq -r .schema <<<"$output")" team-state/1
  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature building | T14-builder idle on build-04, T14-ops busy | tickets 3/7"
}

@test "a ticket done twice counts once, and a ticket set team-tickets refuses has no total" {
  progress_task 2
  event T14 ticket-done '{ticket: "01", commits: ["a0017cce"]}'
  event T14 ticket-done '{ticket: "01", commits: ["9e0e3990"]}'
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c .progress.tickets <<<"$output")" '{"done":["01"],"total":2,"graph":null}'
  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature building | no live worker | tickets 1/2"

  # A second Blocked by: line: team-tickets refuses the set, so the total is unknown.
  echo "Blocked by: 01" >>"$BATS_TEST_TMPDIR/wt/.scratch/task/tickets/02-ticket-2.md"
  run_bin -0 --separate-stderr team-state T14 --json
  assert_equal "$(jq -c .progress.tickets <<<"$output")" '{"done":["01"],"total":null,"graph":null}'
  assert_equal "$stderr" ""
  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature building | no live worker | tickets 1 done"
}

# A stub Chrome, by TEAM_CHROME, whose screenshot is a PNG's signature, for team-tickets --graph.
stub_chrome() {
  stub_command chrome
  export TEAM_CHROME=$BATS_TEST_TMPDIR/stubs/chrome
  stub_script chrome <<'SH'
for arg; do
  [[ $arg != --screenshot=* ]] || printf '\x89PNG\r\n\x1a\n' >"${arg#*=}"
done
SH
}

@test "the tickets' graph is null and unsaid with no tickets or no page" {
  progress_task 2
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c .progress.tickets <<<"$output")" '{"done":[],"total":2,"graph":null}'
  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature building | no live worker | tickets 0/2"

  # A page left in a task directory with no tickets names no graph.
  local dir=$BATS_TEST_TMPDIR/wt/.scratch/task
  rm "$dir"/tickets/*.md
  echo '<!doctype html>' >"$dir/tickets.html"
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c .progress.tickets <<<"$output")" '{"done":[],"total":0,"graph":null}'
  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature building | no live worker"
}

@test "the graph team-tickets --graph made is fresh until a ticket-done, and stale with its PNG missing or older" {
  progress_task 2
  stub_chrome
  local dir=$BATS_TEST_TMPDIR/wt/.scratch/task
  run_bin -0 team-tickets T14 --graph
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c .progress.tickets.graph <<<"$output")" \
    "$(jq -cn --arg dir "$dir" '{html: "\($dir)/tickets.html", png: "\($dir)/tickets.png", fresh: true}')"
  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature building | no live worker | tickets 0/2, graph fresh"

  # A ticket-done changes the tickets the page shows.
  event T14 ticket-done '{ticket: "01", commits: ["a0017cce"]}'
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c .progress.tickets.graph.fresh <<<"$output")" false
  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature building | no live worker | tickets 1/2, graph stale"

  # Remade, it is fresh again; a PNG older than its page is stale.
  run_bin -0 team-tickets T14 --graph
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c .progress.tickets.graph.fresh <<<"$output")" true
  touch -d '2026-10-01 00:00' "$dir/tickets.png"
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c .progress.tickets.graph.fresh <<<"$output")" false

  # With no PNG it is stale, and png is null.
  rm "$dir/tickets.png"
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c .progress.tickets.graph <<<"$output")" \
    "$(jq -cn --arg dir "$dir" '{html: "\($dir)/tickets.html", png: null, fresh: false}')"
  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature building | no live worker | tickets 1/2, graph stale"
}

@test "progress carries the review count and the latest review's verdict, head and sent-back findings" {
  progress_task 0
  event T14 review '{verdict: "findings", head: "1111111", sent_back: [1, 2]}'
  event T14 review '{verdict: "pass", head: "2222222"}'
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c .progress.reviews <<<"$output")" '{"count":2,"verdict":"pass","head":"2222222","sent_back":null}'
  # A review puts a building task in review, a PR logged or not (the lifecycle's review phase).
  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature in-review | no live worker | review 2 pass"

  event T14 review '{verdict: "findings", head: "3333333", sent_back: [], findings: {blocking: 0}}'
  event T14 review '{verdict: "findings", head: "4444444", sent_back: [5, 6]}'
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c .progress.reviews <<<"$output")" '{"count":4,"verdict":"findings","head":"4444444","sent_back":[5,6]}'
  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature in-review | no live worker | review 4 findings, sent back 5, 6"
}

@test "an open PR's behind_by is GitHub's compare of its base and head, null and unsaid when unreadable" {
  open_task
  event T14 pr "{url: \"https://github.com/owner/proj/pull/5\", head: \"$head\"}"
  view='{"number": 5, "state": "OPEN", "baseRefName": "dev", "headRefOid": "'"$head"'"}'
  checks='[{"name": "test", "bucket": "pass", "state": "SUCCESS"}]'
  required='[]' compare=16
  stub_github
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c '.pr.behind_by' <<<"$output")" 16
  assert_equal "$(stub_calls gh | tail -n 1)" "$(jq -cn --arg head "$head" '["api", "repos/owner/proj/compare/dev...\($head)", "--jq", ".behind_by"]')"
  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature in-review | no live worker | PR #5 a1b2c3d 16 behind dev checks 1/1 agent-review missing"

  # Up to date: 0, and nothing said.
  compare=0
  stub_github
  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature in-review | no live worker | PR #5 a1b2c3d checks 1/1 agent-review missing"

  # An unreadable compare: null, nothing said, and the rest of the PR part as before.
  compare=''
  stub_github
  run_bin -0 --separate-stderr team-state T14 --json
  assert_equal "$(jq -c '.pr | [.behind_by, .error, .checks.passed]' <<<"$output")" '[null,null,["test"]]'
  assert_equal "$stderr" ""
  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature in-review | no live worker | PR #5 a1b2c3d checks 1/1 agent-review missing"

  # A PR no longer open is not compared.
  stub_github '{"number": 5, "state": "MERGED", "baseRefName": "dev", "headRefOid": "'"$head"'"}' "$checks" "$required" 16
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c '.pr.behind_by' <<<"$output")" null
  assert_equal "$(stub_calls gh | tail -n 3 | jq -r '.[0]' | sort -u)" pr
}

@test "a task with no tickets, no review and no PR prints as before" {
  progress_task 0
  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature building | no live worker"
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c .progress <<<"$output")" \
    '{"tickets":{"done":[],"total":0,"graph":null},"on":[],"reviews":{"count":0,"verdict":null,"head":null,"sent_back":null}}'
}

@test "--help documents progress, the tickets' graph, each worker's brief, the PR's behind_by and caught_up, and checks_wait" {
  run_bin -0 team-state --help
  assert_contains "$output" "progress"
  assert_contains "$output" "behind_by"
  assert_contains "$output" "on build-04"
  assert_contains "$output" "tickets 3/7, graph stale"
  assert_contains "$output" "{html, png, fresh}"
  assert_contains "$output" "16 behind dev"
  assert_contains "$output" "caught_up"
  assert_contains "$output" "(caught up cleanly with <base>)"
  assert_contains "$output" "walk on since <ts>"
  assert_contains "$output" '{"since": "<ts>"}'
  assert_contains "$output" "checks_wait"
  assert_contains "$output" '"checks <state>"'
}

@test "T287: each worker is named by its session's name, T<n>-builder-NN for a builder in ticket NN's worktree" {
  open_task
  event T14 plan-approved '{by: "Daniel", parallel: "2"}'
  event T14 worktree-added '{project: "proj", branch: "feat/T14-tooling--02", base: "feat/T14-tooling", base_sha: "0123456",
    worktree: "/w/2", ticket: "02"}'
  event T14 launch '{role: "builder", session: "22222222", worktree: "/w/2", toolkits: [], project: "proj",
    branch: "feat/T14-tooling--02", brief: "brief-build-02", ticket: "02"}'
  event T14 worktree-added '{project: "proj", branch: "feat/T14-tooling--03", base: "feat/T14-tooling", base_sha: "0123456",
    worktree: "/w/3", ticket: "03"}'
  event T14 launch '{role: "builder", session: "33333333", worktree: "/w/3", toolkits: [], project: "proj",
    branch: "feat/T14-tooling--03", brief: "brief-build-03", ticket: "03"}'
  stub_reply claude '[{"id": "22222222", "cwd": "/w/2", "name": "T14-builder-02", "status": "busy", "state": "working"},
    {"id": "33333333", "cwd": "/w/3", "name": "T14-builder-03", "status": "idle", "state": "working"}]'
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c '[.workers[] | [.name, .ticket, .live]]' <<<"$output")" \
    '[["T14-builder",null,false],["T14-builder-02","02",true],["T14-builder-03","03",true]]'
  run_bin -0 team-state T14
  assert_equal "$output" "T14 proj feature building | T14-builder-02 busy on build-02, T14-builder-03 idle on build-03"
}
