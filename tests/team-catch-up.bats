#!/usr/bin/env bats
# team-catch-up: makes a clean merge of the base onto a task's reviewed, green PR head in the
# project's primary checkout, pushes it as a fast-forward, sets agent-review on it and logs
# caught-up; and the library's base-merge checks it and team-merge share (base_merge,
# clean_base_merges). proj's origin and primary checkout are real; GitHub is the stub gh, which
# shows origin's tip of PR #5's branch as its head.

load helpers/common

setup() {
  sandbox
  cat >"$TEAM_HOME/projects.toml" <<'TOML'
[proj]
repo = "owner/proj"
path = "projects/proj"
base = "dev"
delivery = "direct-pr"
merge_method = "squash"
required_checks = ["test"]
task_dir = ".scratch/task"
docs = []
toolkits = []

[proj.pool]
provider = "git"
slots = ["slots/proj/1", "slots/proj/2"]
TOML
  primary=$(make_repo proj dev)
  # The primary checkout's own identity, which every worktree of it commits with.
  git -C "$primary" config user.name "Proj Builder"
  git -C "$primary" config user.email builder@example.invalid
  export PROJ_ORIGIN=$BATS_TEST_TMPDIR/origin/proj.git GH_DIR=$BATS_TEST_TMPDIR/gh
  mkdir -p "$GH_DIR"
  url=https://github.com/owner/proj/pull/5 branch=feat/T14-tooling
  git -C "$primary" checkout -q -b "$branch"
  commit_file "$primary" src/tool.py "tool"
  git -C "$primary" push -q origin "$branch"
  git -C "$primary" checkout -q dev
  head=$(git -C "$primary" rev-parse "$branch")
  green_pr
  stub_gh
  event T14 opened '{project: "proj", path: "feature", type: "feat", title: "The tooling",
    branch: "feat/T14-tooling", base: "dev", base_sha: "0123456", worktree: "/w/1"}'
  event T14 pr "{url: \"$url\", head: \"$head\", project: \"proj\"}"
  review "$head" pass
}

# commit_file <checkout> <path> <content> [<message>]: commit <content> as <path>.
commit_file() {
  mkdir -p "$(dirname "$1/$2")"
  echo "$3" >"$1/$2"
  git -C "$1" add "$2"
  git -C "$1" commit -q -m "${4:-feat: change $2}"
}

# event <task> <kind> [<jq object of more fields>]
event() {
  jq -cn --arg t "$1" --arg e "$2" "{ts: \"2026-10-22T02:00:00Z\", task: \$t, event: \$e} + (${3:-{\}})" \
    >>"$TEAM_HOME/ledger.jsonl"
}

# review <head> <verdict>
review() {
  event T14 review "{verdict: \"$2\", head: \"$1\"}"
}

# Another task's merge lands on origin's dev, changing <path> (default src/other.py); prints it.
base_moves() {
  push_to_dev "$PROJ_ORIGIN" "${1:-src/other.py}"
}

# PR #5 as GitHub shows it, open on dev with every check green; edit $GH_DIR's files to break one.
green_pr() {
  jq -n --arg branch "$branch" '{number: 5, state: "OPEN", baseRefName: "dev", headRefName: $branch,
    changedFiles: 1}' >"$GH_DIR/pr.json"
  echo '[
    {"name": "test", "bucket": "pass", "state": "SUCCESS"},
    {"name": "lint", "bucket": "pass", "state": "SUCCESS"},
    {"name": "agent-review", "bucket": "pass", "state": "SUCCESS"}
  ]' >"$GH_DIR/checks.json"
  echo '[{"name": "lint", "bucket": "pass", "state": "SUCCESS"}]' >"$GH_DIR/required.json"
  echo '{"name": "dev", "protection": {"required_status_checks": {"contexts": ["lint"]}}}' >"$GH_DIR/branch.json"
}

# gh answers from $GH_DIR, PR #5's head origin's tip of its branch; a read of the head alone shows
# the PR's first head while $GH_DIR/lag counts down, as GitHub may for a moment after a push. A
# status POST is kept in $GH_DIR/statuses, or refused once $GH_DIR/refuse exists.
stub_gh() {
  echo "$head" >"$GH_DIR/first-head"
  stub_script gh <<'EOF'
tip=$(git --git-dir="$PROJ_ORIGIN" rev-parse "refs/heads/feat/T14-tooling")
case "$*" in
  "pr view 5 --repo owner/proj --json headRefOid --jq .headRefOid")
    lag=$(cat "$GH_DIR/lag" 2>/dev/null || echo 0)
    if ((lag > 0)); then
      echo $((lag - 1)) >"$GH_DIR/lag"
      cat "$GH_DIR/first-head"
    else
      echo "$tip"
    fi ;;
  "pr view 5 --repo owner/proj --json "*) jq --arg tip "$tip" '.headRefOid = $tip' "$GH_DIR/pr.json" ;;
  "pr checks 5 --repo owner/proj --required "*) cat "$GH_DIR/required.json" ;;
  "pr checks 5 --repo owner/proj "*) cat "$GH_DIR/checks.json" ;;
  "api repos/owner/proj/compare/"*) echo 1 ;;
  "api repos/owner/proj/branches/dev") cat "$GH_DIR/branch.json" ;;
  "api --method POST repos/owner/proj/statuses/"*)
    if [[ -e $GH_DIR/refuse ]]; then echo "HTTP 422: Unprocessable Entity" >&2; exit 1; fi
    jq -cn '$ARGS.positional' --args -- "$@" >>"$GH_DIR/statuses"
    echo '{}' ;;
  *) echo "unplanned gh call: $*" >&2; exit 1 ;;
esac
EOF
}

# The state a run must leave alone: origin's branch, the primary checkout's refs, HEAD, index and
# working tree, and every worktree of it.
state() {
  git --git-dir="$PROJ_ORIGIN" rev-parse "refs/heads/$branch"
  git -C "$primary" for-each-ref refs/heads refs/tags
  git -C "$primary" rev-parse HEAD
  git -C "$primary" status --porcelain=v1 --untracked-files=all
  git -C "$primary" worktree list --porcelain
  local wt
  for wt in $(git -C "$primary" worktree list --porcelain | sed -n 's/^worktree //p'); do
    git -C "$wt" status --porcelain=v1 --untracked-files=all
  done
}

# Run team-catch-up T14 expecting a refusal: exit <status> (default 1), stdout empty, stderr
# holding each line given, nothing pushed, set or logged.
refused() {
  local before ledger
  before=$(state) ledger=$(cat "$TEAM_HOME/ledger.jsonl")
  run_bin -1 --separate-stderr team-catch-up T14
  assert_equal "$output" ""
  local line
  for line in "$@"; do assert_contains "$stderr" "$line"; done
  assert_equal "$(state)" "$before"
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" "$ledger"
  [[ ! -e $GH_DIR/statuses ]]
}

# Run the library's <function> with <arguments>: library <function> <arguments>...
library() {
  run --separate-stderr bash -c 'source "$1/bin/lib/team.sh"; "${@:2}"' _ "$REPO_ROOT" "$@"
}

@test "a clean catch-up merges the base onto the reviewed head, pushes it, sets agent-review and logs caught-up" {
  local base wt merge before
  base=$(base_moves)
  # A builder's worktree on the branch, which the run must not touch.
  wt=$BATS_TEST_TMPDIR/builder
  git -C "$primary" worktree add -q "$wt" "$branch"
  echo "half done" >"$wt/wip.txt"
  before=$(git -C "$primary" for-each-ref refs/heads; git -C "$primary" rev-parse HEAD
    git -C "$primary" status --porcelain=v1; git -C "$wt" rev-parse HEAD; git -C "$wt" status --porcelain=v1)

  run_bin -0 --separate-stderr team-catch-up T14
  merge=$(git --git-dir="$PROJ_ORIGIN" rev-parse "refs/heads/$branch")
  [[ $merge != "$head" ]]
  assert_equal "${lines[-2]}" "$merge"
  assert_equal "${lines[-1]}" "next: wait for the checks on ${merge:0:7} (team-ci-wait $url $merge, in the background), then ask Daniel to merge $url at $head, whose word holds through this merge, or run team-merge T14 when team-state says a plan-time or standing word covers it"
  assert_contains "$output" "merged dev ${base:0:7} cleanly onto ${head:0:7} as ${merge:0:7} and pushed it to $branch"

  # The merge: the head and origin's dev as parents, git's own message, the checkout's identity.
  assert_equal "$(git --git-dir="$PROJ_ORIGIN" rev-list --parents -n 1 "$merge")" "$merge $head $base"
  assert_equal "$(git --git-dir="$PROJ_ORIGIN" log -1 --format=%B "$merge")" "Merge remote-tracking branch 'origin/dev' into $branch"
  assert_equal "$(git --git-dir="$PROJ_ORIGIN" log -1 --format='%an <%ae>|%cn <%ce>' "$merge")" \
    "Proj Builder <builder@example.invalid>|Proj Builder <builder@example.invalid>"
  assert_equal "$(git --git-dir="$PROJ_ORIGIN" show "$merge:src/tool.py")" tool
  [[ -n $(git --git-dir="$PROJ_ORIGIN" show "$merge:src/other.py") ]]

  # agent-review on the merge, through team-review-status.
  assert_equal "$(cat "$GH_DIR/statuses")" \
    "$(jq -cn --arg m "$merge" --arg d "clean merge of dev ${base:0:7} onto ${head:0:7}, reviewed" \
      '["api", "--method", "POST", "repos/owner/proj/statuses/\($m)", "-f", "state=success", "-f", "context=agent-review", "-f", "description=\($d)"]')"
  assert_contains "$stderr" "agent-review success on owner/proj@$merge"

  # caught-up, with the reviewed head, the merge and the base merged.
  assert_equal "$(jq -c 'select(.event == "caught-up") | del(.ts)' "$TEAM_HOME/ledger.jsonl")" \
    "$(jq -cn --arg url "$url" --arg from "$head" --arg m "$merge" --arg b "$base" \
      '{task: "T14", event: "caught-up", url: $url, from: $from, head: $m, base: $b}')"
  run_bin -0 team-log --check

  # No branch, HEAD, index or worktree of the primary checkout changed.
  assert_equal "$(git -C "$primary" for-each-ref refs/heads; git -C "$primary" rev-parse HEAD
    git -C "$primary" status --porcelain=v1; git -C "$wt" rev-parse HEAD; git -C "$wt" status --porcelain=v1)" "$before"

}

@test "GitHub still showing the old head for a moment after the push is waited out" {
  base_moves >/dev/null
  echo 2 >"$GH_DIR/lag"
  run_bin -0 --separate-stderr team-catch-up T14
  assert_equal "$(cat "$GH_DIR/lag")" 0
  [[ -s $GH_DIR/statuses ]]
  assert_equal "$(jq -c 'select(.event == "caught-up") | .head' "$TEAM_HOME/ledger.jsonl" | wc -l)" 1
}

@test "an agent-review that cannot be set is said with its command; the pushed merge is still logged, exit 1" {
  local merge base
  base=$(base_moves)
  touch "$GH_DIR/refuse"
  run_bin -1 --separate-stderr team-catch-up T14
  merge=$(git --git-dir="$PROJ_ORIGIN" rev-parse "refs/heads/$branch")
  [[ $merge != "$head" ]]
  assert_contains "$stderr" "team-catch-up: pushed ${merge:0:7} to $branch, but agent-review could not be set on it: team-review-status: GitHub refused the status on owner/proj@$merge"
  assert_contains "$stderr" "run: team-review-status $url $merge success 'clean merge of dev ${base:0:7} onto ${head:0:7}, reviewed'"
  assert_equal "$(jq -c 'select(.event == "caught-up") | .head' "$TEAM_HOME/ledger.jsonl")" "\"$merge\""

  # When GitHub never shows the merge as the head, the wait ends too.
  rm "$GH_DIR/refuse"
  base_moves src/third.py >/dev/null
  review "$merge" pass
  echo 99 >"$GH_DIR/lag" && echo "$merge" >"$GH_DIR/first-head"
  export TEAM_CATCH_UP_WAIT=1
  run_bin -1 --separate-stderr team-catch-up T14
  assert_contains "$stderr" "but agent-review could not be set on it: GitHub still shows ${merge:0:7} as the head of $url after 1s"
  assert_equal "$(jq -c 'select(.event == "caught-up")' "$TEAM_HOME/ledger.jsonl" | wc -l)" 2
}

@test "a merge that conflicts makes nothing, naming the files and the builder's step" {
  base_moves src/tool.py >/dev/null
  refused "team-catch-up: $url conflicts with dev on src/tool.py: the holder merges it (builder-merge-base), then a rereview"
}

@test "a head that holds the base already is nothing to merge, and changes nothing" {
  local before
  before=$(state)
  run_bin -0 --separate-stderr team-catch-up T14
  assert_equal "$output" "team-catch-up: $url holds dev already; nothing to merge"
  assert_equal "$(state)" "$before"
  [[ $(jq -c 'select(.event == "caught-up")' "$TEAM_HOME/ledger.jsonl") == "" ]]
  [[ ! -e $GH_DIR/statuses ]]
}

@test "a head whose latest review did not pass on it exactly is refused" {
  base_moves >/dev/null
  review "$head" findings
  refused "team-catch-up: T14 cannot catch up PR #5, so nothing changed:" \
    "  the latest review of T14 (of ${head:0:7}) found something, not a pass: fix and review it first"

  review 1234567 pass
  refused "  the latest review of T14 passed on 1234567, not on the head ${head:0:7}: review the head first"

  # The head moved past the review: a commit pushed since.
  review "$head" pass
  local clone=$BATS_TEST_TMPDIR/moved
  git clone -q "$PROJ_ORIGIN" "$clone"
  git -C "$clone" checkout -q "$branch"
  commit_file "$clone" src/tool.py "tool 2"
  git -C "$clone" push -q origin "$branch"
  local moved
  moved=$(git -C "$clone" rev-parse HEAD)
  refused "  the latest review of T14 passed on ${head:0:7}, not on the head ${moved:0:7}: review the head first"

  jq -c 'select(.event != "review")' "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/l" && mv "$TEAM_HOME/l" "$TEAM_HOME/ledger.jsonl"
  refused "  no review of T14 is logged: review the head first"
}

@test "a red, pending or missing required check, a closed PR or another base is refused with every reason at once" {
  base_moves >/dev/null
  echo '[
    {"name": "test", "bucket": "pending", "state": "PENDING"},
    {"name": "docs", "bucket": "fail", "state": "FAILURE"}
  ]' >"$GH_DIR/checks.json"
  jq '.state = "CLOSED" | .baseRefName = "main"' "$GH_DIR/pr.json" >"$GH_DIR/pr.next" && mv "$GH_DIR/pr.next" "$GH_DIR/pr.json"
  refused "team-catch-up: T14 cannot catch up PR #5, so nothing changed:" \
    "  PR #5 is closed, not open" \
    "  PR #5 targets main, not proj's base dev" \
    "  required check lint is missing on the head" \
    "  required check test has not passed on the head" \
    "  checks failing on the head: docs" \
    "  checks pending on the head: test"
}

@test "a branch that moves on origin while the merge is made refuses the push, and nothing is logged" {
  base_moves >/dev/null
  # Another push lands on the branch just before this one reaches origin.
  cat >"$primary/.git/hooks/pre-push" <<EOF
#!/usr/bin/env bash
clone=\$(mktemp -d "$BATS_TEST_TMPDIR/race.XXXXXX")
git clone -q "$PROJ_ORIGIN" "\$clone"
git -C "\$clone" checkout -q "$branch"
echo race >"\$clone/race.txt"
git -C "\$clone" add race.txt
git -C "\$clone" commit -q -m "fix: a builder's push"
git -C "\$clone" push -q origin "$branch"
git -C "\$clone" rev-parse HEAD >"$BATS_TEST_TMPDIR/raced"
EOF
  chmod +x "$primary/.git/hooks/pre-push"
  local ledger
  ledger=$(cat "$TEAM_HOME/ledger.jsonl")
  run_bin -1 --separate-stderr team-catch-up T14
  assert_equal "$output" ""
  assert_contains "$stderr" "team-catch-up: $branch moved on origin while the merge was made; nothing pushed: run it again"
  assert_equal "$(git --git-dir="$PROJ_ORIGIN" rev-parse "refs/heads/$branch")" "$(cat "$BATS_TEST_TMPDIR/raced")"
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" "$ledger"
  [[ ! -e $GH_DIR/statuses ]]
}

@test "--pr names one of the task's PRs; anything else is refused" {
  run_bin -1 --separate-stderr team-catch-up T14 --pr https://github.com/owner/proj/pull/6
  assert_contains "$stderr" "https://github.com/owner/proj/pull/6 is not one of T14's pr events:"
  run_bin -2 team-catch-up
  run_bin -2 team-catch-up T14 --pr
  run_bin -2 team-catch-up 14
  run_bin -1 --separate-stderr team-catch-up T15
}

@test "base_merge prints a clean merge's tree, a conflict's paths, and git's error, changing no ref" {
  local base refs
  base_moves >/dev/null
  git -C "$primary" fetch -q origin
  refs=$(git -C "$primary" for-each-ref)
  library base_merge "$primary" "$head" origin/dev
  assert_equal "$status" 0
  assert_equal "$(git -C "$primary" cat-file -t "$output")" tree
  assert_equal "$(git -C "$primary" ls-tree -r --name-only "$output" | tr '\n' ' ')" "README.md src/other.py src/tool.py "

  base_moves src/tool.py >/dev/null
  git -C "$primary" fetch -q origin
  refs=$(git -C "$primary" for-each-ref)
  library base_merge "$primary" "$head" origin/dev
  assert_equal "$status" 1
  assert_equal "$output" src/tool.py

  library base_merge "$primary" "$head" origin/nothing
  assert_equal "$status" 2
  assert_contains "$output" "origin/nothing"
  assert_equal "$(git -C "$primary" for-each-ref)" "$refs"
}

@test "clean_base_merges holds for clean merges of the base alone, naming the first commit that is not" {
  local wt=$BATS_TEST_TMPDIR/wt from clean conflicted evil own stray
  git -C "$primary" worktree add -q "$wt" "$branch"
  from=$head
  # Clean merges of the base hold, however many.
  base_moves >/dev/null
  git -C "$wt" pull -q --no-rebase --no-edit origin dev
  base_moves src/more.py >/dev/null
  git -C "$wt" pull -q --no-rebase --no-edit origin dev
  clean=$(git -C "$wt" rev-parse HEAD)
  git -C "$primary" fetch -q origin
  library clean_base_merges "$primary" "$from" "$clean" origin/dev
  assert_equal "$status" 0
  assert_equal "$output" ""
  library clean_base_merges "$primary" "$from" "$from" origin/dev
  assert_equal "$status" 0

  # A commit of the branch's own.
  commit_file "$wt" src/tool.py "tool 2"
  own=$(git -C "$wt" rev-parse HEAD)
  library clean_base_merges "$primary" "$from" "$own" origin/dev
  assert_equal "$status" 1
  assert_equal "$output" "${own:0:7} is a commit of its own"

  # An "evil" merge: clean, with a change of its own folded in.
  git -C "$wt" reset -q --hard "$clean"
  base_moves src/evil.py >/dev/null
  git -C "$primary" fetch -q origin
  git -C "$wt" merge -q --no-commit origin/dev
  echo sneaked >"$wt/src/sneaked.py"
  git -C "$wt" add src/sneaked.py
  git -C "$wt" commit -q --no-edit
  evil=$(git -C "$wt" rev-parse HEAD)
  library clean_base_merges "$primary" "$from" "$evil" origin/dev
  assert_equal "$status" 1
  assert_equal "$output" "${evil:0:7} changes more than the merge of its parents"

  # A merge of a branch that is not the base: that branch's commit is one of its own.
  git -C "$wt" reset -q --hard "$clean"
  git -C "$primary" checkout -q -b stray origin/dev
  commit_file "$primary" src/stray.py stray
  git -C "$primary" checkout -q dev
  git -C "$wt" merge -q --no-edit --no-ff stray
  stray=$(git -C "$wt" rev-parse HEAD)
  library clean_base_merges "$primary" "$from" "$stray" origin/dev
  assert_equal "$status" 1
  assert_equal "$output" "$(git -C "$primary" rev-parse stray | cut -c1-7) is a commit of its own"

  # A merge whose conflict was resolved.
  git -C "$wt" reset -q --hard "$clean"
  base_moves src/tool.py >/dev/null
  git -C "$primary" fetch -q origin
  git -C "$wt" pull -q --no-rebase --no-edit origin dev >/dev/null 2>&1 || true
  echo resolved >"$wt/src/tool.py"
  git -C "$wt" add src/tool.py
  git -C "$wt" commit -q --no-edit
  conflicted=$(git -C "$wt" rev-parse HEAD)
  library clean_base_merges "$primary" "$from" "$conflicted" origin/dev
  assert_equal "$status" 1
  assert_equal "$output" "${conflicted:0:7} conflicted when merged"

  # A head that does not hold the one it is judged from.
  library clean_base_merges "$primary" "$own" "$clean" origin/dev
  assert_equal "$status" 1
  assert_equal "$output" "${clean:0:7} does not hold ${own:0:7}"
}
