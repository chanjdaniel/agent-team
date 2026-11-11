#!/usr/bin/env bats
# team-ci-wait: a wait on a PR's GitHub checks that always ends, whatever GitHub shows.

load helpers/common

setup() {
  sandbox
  printf '%s\n' '[proj]' 'repo = "owner/proj"' 'path = "projects/proj"' 'base = "dev"' 'delivery = "direct-pr"' \
    'merge_method = "squash"' 'required_checks = []' 'task_dir = ".scratch/task"' 'docs = []' 'toolkits = []' \
    '[proj.pool]' 'provider = "git"' 'slots = ["slots/proj/1"]' >"$TEAM_HOME/projects.toml"
  head=a1b2c3d4e5f60718293a4b5c6d7e8f9012345678
  url=https://github.com/owner/proj/pull/217
  export GH_DIR=$BATS_TEST_TMPDIR/gh
  mkdir -p "$GH_DIR"
  echo 0 >"$GH_DIR/look"
  stub_gh
  stub_sleep
  pr OPEN "$head"
  head_runs 0
}

# answer <look> <what> <answer>: from look <look> on, gh answers <what> (view, checks, run-<run id>
# or job-<job id>) with <answer>: JSON, "fail" (gh cannot reach GitHub) or, for checks, "none" (gh's
# "no checks reported").
answer() {
  printf '%s\n' "$3" >"$GH_DIR/$2.$1"
}

# pr <state> <head> [<look>]: the PR as gh pr view shows it, from <look> on (default 0).
pr() {
  answer "${3:-0}" view "$(jq -cn --arg state "$1" --arg head "$2" '{state: $state, headRefOid: $head}')"
}

# check <name> <state> [<run id> [<job id>]]: one check as gh pr checks --json shows it, its bucket
# from its state, its link an Actions job link of run <run id> and job <job id> (default 9<run id>;
# no run given: a commit status's link).
check() {
  jq -cn --arg name "$1" --arg state "$2" --arg run "${3:-}" --arg job "${4:-9${3:-}}" '{name: $name, state: $state,
    bucket: ({SUCCESS: "pass", SKIPPED: "skipping", FAILURE: "fail", CANCELLED: "cancel"}[$state] // "pending"),
    link: (if $run == "" then "https://ci.example.invalid/\($name)"
      else "https://github.com/owner/proj/actions/runs/\($run)/job/\($job)" end),
    workflow: (if $run == "" then "" else "CI" end)}'
}

# checks <look> <check>...: the checks from <look> on.
checks() {
  local look=$1
  shift
  answer "$look" checks "$(jq -cs . <<<"$*")"
}

# workflow_run <look> <run id> <status> [<conclusion>]: the workflow run as gh api shows it, from <look> on.
workflow_run() {
  answer "$1" "run-$2" "$(jq -cn --argjson id "$2" --arg status "$3" --arg conclusion "${4:-}" '{id: $id,
    status: $status, conclusion: (if $conclusion == "" then null else $conclusion end),
    updated_at: "2026-10-30T18:52:11Z", name: "CI", display_title: "OUTPUT-MARKER"}')"
}

# job <look> <job id> <runner> [<step>=<conclusion>]...: the Actions job as gh api shows it, from
# <look> on: <runner> its runner_name ("null" for none), each step numbered in order, an empty
# conclusion a step that never concluded.
job() {
  local look=$1 id=$2 runner=$3
  shift 3
  answer "$look" "job-$id" "$(jq -cn --argjson id "$id" --arg runner "$runner" '{id: $id,
    runner_name: (if $runner == "null" then null else $runner end), status: "completed",
    html_url: "https://github.com/owner/proj/actions/runs/1/job/\($id)", workflow_name: "OUTPUT-MARKER",
    steps: [$ARGS.positional | to_entries[] | (.value | rindex("=")) as $i
      | {name: .value[:$i], status: "completed", number: (.key + 1),
         conclusion: (.value[$i + 1:] | if . == "" then null else . end)}]}' --args "$@")"
}

# head_runs <look> [<id>:<name>:<status>]...: the head's workflow runs as gh api lists them, from
# <look> on (none given: every one completed, so none listed here keeps the wait going).
head_runs() {
  local look=$1
  shift
  answer "$look" runs "$(jq -cn '{total_count: ($ARGS.positional | length), workflow_runs: [$ARGS.positional[] | split(":")
    | {id: (.[0] | tonumber), name: .[1], status: .[2], conclusion: null, display_title: "OUTPUT-MARKER"}]}' --args "$@")"
}

# gh answers each read (the PR, its checks, the head's runs, a run, a job) from the latest answer at
# or before the current look; gh pr checks exits 8 while a check is pending, as gh does. Anything
# unplanned fails.
stub_gh() {
  stub_script gh <<'EOF'
n=$(cat "$GH_DIR/look")
case "$*" in
  "pr view 217 --repo owner/proj --json state,headRefOid") what=view ;;
  "pr checks 217 --repo owner/proj --json name,state,bucket,link,workflow") what=checks ;;
  "api repos/owner/proj/actions/runs?head_sha="*"&per_page=100") what=runs ;;
  "api repos/owner/proj/actions/runs/"*) what=run-${2##*/} ;;
  "api repos/owner/proj/actions/jobs/"*) what=job-${2##*/} ;;
  *) echo "unplanned gh call: $*" >&2; exit 1 ;;
esac
m=$n
while ((m >= 0)) && [[ ! -e $GH_DIR/$what.$m ]]; do m=$((m - 1)); done
if ((m < 0)); then echo "no answer planned for $what at look $n" >&2; exit 1; fi
body=$(cat "$GH_DIR/$what.$m")
case $body in
  fail) echo "error connecting to api.github.com" >&2; echo "check your internet connection" >&2; exit 1 ;;
  none) echo "no checks reported on the 'feat/T14-work' branch" >&2; exit 1 ;;
esac
printf '%s\n' "$body"
if [[ $what == checks ]] && jq -e 'any(.[]; .bucket == "pending")' <<<"$body" >/dev/null; then exit 8; fi
EOF
}

# The stub sleep moves on to the next look and, after LOOK_LIMIT looks (default 200, 100 minutes),
# stops the wait with exit 99, so a wait that never ends shows as that exit. The uname stub keeps
# it ahead of Homebrew's GNU sleep on macOS.
stub_sleep() {
  stub_command sleep uname
  stub_reply uname Linux
  stub_script sleep <<EOF
n=\$(cat "$GH_DIR/look")
((n < \${LOOK_LIMIT:-200})) || exit 99
echo \$((n + 1)) >"$GH_DIR/look"
EOF
}

# The look the wait ended at.
ended_at() {
  cat "$GH_DIR/look"
}

# both <team-ci-wait arguments>...: run team-ci-wait with them, then again with --json first, each
# from look 0, and hold the two to each other: the same exit code and the look it ended at, one
# line of JSON with nothing else, schema team-ci-wait/1, and its text the text form without its
# starting line. The text form's status and output stay in text_status and text_output.
both() {
  local ended
  run_bin team-ci-wait "$@"
  text_status=$status text_output=$output ended=$(ended_at)
  echo 0 >"$GH_DIR/look"
  run_bin team-ci-wait --json "$@"
  assert_equal "$status" "$text_status"
  assert_equal "$(ended_at)" "$ended"
  assert_equal "${#lines[@]}" 1
  assert_equal "$(jq -r .schema <<<"$output")" team-ci-wait/1
  assert_equal "$(jq -r .text <<<"$output")" "$(sed '/^team-ci-wait: waiting on the checks of /d' <<<"$text_output")"
  assert_equal "$(jq -r 'keys | join(" ")' <<<"$output")" "failures head outcome schema text"
}

@test "T121: a summary check left in_progress on a run that completed ends the wait after 5 minutes, naming the re-run" {
  checks 0 "$(check test SUCCESS 41110572636)" "$(check e2e IN_PROGRESS 41110572636)"
  workflow_run 0 41110572636 completed success
  run_bin team-ci-wait "$url"
  assert_equal "$status" 1
  assert_equal "$(ended_at)" 10
  assert_contains "$output" "team-ci-wait: waiting on the checks of owner/proj#217 at a1b2c3d"
  assert_contains "$output" "
  infrastructure: e2e is still in_progress, but its run 41110572636 completed success at 2026-10-30T18:52:11Z: GitHub lost the job's status; re-run it with gh run rerun 41110572636 --repo owner/proj, then run team-ci-wait again, and report BLOCKED if it sticks again"
  [[ $output != *OUTPUT-MARKER* ]]
}

@test "a run that completes while its check concludes within 5 minutes never reads as stuck" {
  checks 0 "$(check test IN_PROGRESS 7001)"
  workflow_run 0 7001 in_progress
  workflow_run 2 7001 completed success
  checks 11 "$(check test SUCCESS 7001)"
  run_bin team-ci-wait "$url"
  assert_equal "$status" 0
  assert_equal "$(ended_at)" 15
  assert_contains "$output" "team-ci-wait: every check passed on a1b2c3d: test passed"
  [[ $output != *"still"* ]]
}

# During a re-run's first seconds, or a push's, gh pr checks may list only another workflow's checks.
@test "a workflow run still open on the head holds the wait past checks that all passed" {
  checks 0 "$(check zizmor-online SUCCESS 7002)"
  head_runs 0 7001:CI:queued 7002:Zizmor:completed
  checks 2 "$(check zizmor-online SUCCESS 7002)" "$(check macos IN_PROGRESS 7001)"
  workflow_run 2 7001 in_progress
  head_runs 2 7001:CI:in_progress 7002:Zizmor:completed
  checks 4 "$(check zizmor-online SUCCESS 7002)" "$(check macos SUCCESS 7001)"
  head_runs 4 7001:CI:completed 7002:Zizmor:completed
  run_bin team-ci-wait --no-agent-review "$url" "$head"
  assert_equal "$status" 0
  assert_equal "$(ended_at)" 8
  assert_contains "$output" "team-ci-wait: every check passed on a1b2c3d: zizmor-online passed, macos passed"
  # It asks for the PR's head, and prints nothing of a run's text.
  assert_contains "$(stub_calls gh)" "repos/owner/proj/actions/runs?head_sha=$head&per_page=100"
  [[ $output != *OUTPUT-MARKER* ]]
}

@test "a workflow run still open on the head holds the wait past a failed check, which a re-run may replace" {
  checks 0 "$(check macos FAILURE 7001)"
  head_runs 0 7001:CI:queued
  checks 3 "$(check macos SUCCESS 7001)"
  head_runs 3 7001:CI:completed
  run_bin team-ci-wait "$url"
  assert_equal "$status" 0
  assert_equal "$(ended_at)" 7
}

@test "a workflow run still open on the head holds the wait past 2 minutes of no checks" {
  answer 0 checks none
  head_runs 0 7001:CI:queued
  checks 8 "$(check test SUCCESS 7001)"
  head_runs 8 7001:CI:completed
  run_bin team-ci-wait "$url"
  assert_equal "$status" 0
  assert_equal "$(ended_at)" 12
  assert_contains "$output" "every check passed on a1b2c3d: test passed"
  # With none open, the 2 minutes run again from the first look that saw none.
  echo 0 >"$GH_DIR/look"
  rm "$GH_DIR"/runs.* "$GH_DIR"/checks.*
  answer 0 checks none
  head_runs 0 7001:CI:queued
  head_runs 3
  run_bin team-ci-wait "$url"
  assert_equal "$status" 0
  assert_equal "$(ended_at)" 7
  assert_contains "$output" "has no GitHub checks: none reported for 2 minutes"
}

# A push run of the same head may have passed already, so its checks stand alone until the PR's
# run is listed: a reading counts only once it has stood for 2 minutes.
@test "checks that passed before another run is listed are waited past, for 2 minutes with nothing open" {
  checks 0 "$(check zizmor-online SUCCESS 7002)"
  head_runs 0 7002:Zizmor:completed
  head_runs 1 7002:Zizmor:completed 7001:CI:queued
  checks 4 "$(check zizmor-online SUCCESS 7002)" "$(check test SUCCESS 7001)"
  head_runs 4 7002:Zizmor:completed 7001:CI:completed
  run_bin team-ci-wait "$url"
  assert_equal "$status" 0
  assert_equal "$(ended_at)" 8
  assert_contains "$output" "every check passed on a1b2c3d: zizmor-online passed, test passed"
}

@test "a passed check newly listed restarts the 2 minutes" {
  checks 0 "$(check lint SUCCESS 7001)"
  checks 3 "$(check lint SUCCESS 7001)" "$(check test SUCCESS 7001)"
  run_bin team-ci-wait "$url"
  assert_equal "$status" 0
  assert_equal "$(ended_at)" 7
  assert_contains "$output" "lint passed, test passed"
}

# required <name>...: the project's required_checks.
required() {
  sed -i "s/^required_checks = .*/required_checks = $(jq -cn '$ARGS.positional' --args "$@")/" "$TEAM_HOME/projects.toml"
}

@test "a required check never reported ends the wait with exit 1 after 2 minutes with nothing open, naming it" {
  required test build
  checks 0 "$(check test SUCCESS 7001)"
  run_bin team-ci-wait "$url"
  assert_equal "$status" 1
  assert_equal "$(ended_at)" 4
  assert_equal "$output" "team-ci-wait: waiting on the checks of owner/proj#217 at a1b2c3d
team-ci-wait: the checks on a1b2c3d did not pass:
  the PR's: build was not reported for 2 minutes, and the project requires it"
}

@test "a head with no checks at all, in a project that requires some, is not called fine" {
  required test
  answer 0 checks none
  run_bin team-ci-wait "$url"
  assert_equal "$status" 1
  assert_equal "$(ended_at)" 4
  assert_contains "$output" "
  the PR's: test was not reported for 2 minutes, and the project requires it"
}

@test "a required check listed in time, skipped ones too, passes; agent-review, set at a reviewer's verdict, is never missed" {
  required test docs agent-review
  checks 0 "$(check test IN_PROGRESS 7001)"
  workflow_run 0 7001 in_progress
  checks 2 "$(check test SUCCESS 7001)" "$(check docs SKIPPED 7001)"
  run_bin team-ci-wait "$url"
  assert_equal "$status" 0
  assert_equal "$(ended_at)" 6
  assert_contains "$output" "every check passed on a1b2c3d: test passed, docs skipped"
}

# The no-runner pattern, as run 41904778858 showed it: a job GitHub never started ends cancelled
# with no runner and no step, and the run with it, its roll-up failed beside it.
@test "a failure held past an open run ends the wait once that run completes: a job never started is infrastructure, its roll-up left out" {
  checks 0 "$(check "macos-shards (1)" QUEUED 7001 81)" "$(check test SUCCESS 7001 83)"
  workflow_run 0 7001 in_progress
  head_runs 0 7001:CI:in_progress
  checks 3 "$(check "macos-shards (1)" CANCELLED 7001 81)" "$(check macos FAILURE 7001 82)" "$(check test SUCCESS 7001 83)"
  head_runs 3 7001:CI:completed
  job 0 81 ""
  run_bin team-ci-wait "$url"
  assert_equal "$status" 1
  assert_equal "$(ended_at)" 3
  assert_equal "$output" "team-ci-wait: waiting on the checks of owner/proj#217 at a1b2c3d
team-ci-wait: the checks on a1b2c3d did not pass:
  infrastructure: macos-shards (1) never started: no runner took it (https://github.com/owner/proj/actions/runs/7001/job/81); rerun it with gh run rerun 7001 --job 81 --repo owner/proj, then run team-ci-wait again
  roll-up: macos, of macos-shards (1), left out"
  # Its job is read once, at the end; the roll-up's never.
  assert_equal "$(stub_calls gh | jq -c 'select(.[1] | contains("/jobs/"))')" '["api","repos/owner/proj/actions/jobs/81"]'
}

@test "a reading still standing at the deadline ends within its 2 minutes, and the wait always ends" {
  checks 0 "$(check test IN_PROGRESS 7001)"
  workflow_run 0 7001 in_progress
  checks 20 "$(check test SUCCESS 7001)"
  TEAM_CI_WAIT_DEADLINE_SECONDS=600 run_bin team-ci-wait "$url"
  assert_equal "$status" 0
  assert_equal "$(ended_at)" 24
  # Open and closed in turn, it never stands, and the deadline ends it.
  echo 0 >"$GH_DIR/look"
  checks 0 "$(check test SUCCESS 7001)"
  checks 20 "$(check test SUCCESS 7001)"
  local n
  for ((n = 0; n < 30; n += 2)); do
    head_runs "$n" 7001:CI:queued
    head_runs "$((n + 1))"
  done
  TEAM_CI_WAIT_DEADLINE_SECONDS=600 run_bin team-ci-wait "$url"
  assert_equal "$status" 75
  assert_contains "$output" "CI (workflow run 7001 queued)"
}

@test "a workflow run that never ends still ends the wait at the deadline, naming that run once" {
  checks 0 "$(check lint SUCCESS 7002)" "$(check test IN_PROGRESS 7001)"
  workflow_run 0 7001 in_progress
  head_runs 0 7001:CI:in_progress 7003:Deploy:waiting
  TEAM_CI_WAIT_DEADLINE_SECONDS=600 run_bin team-ci-wait "$url"
  assert_equal "$status" 75
  assert_contains "$output" "checks still pending on a1b2c3d: test (in_progress, run 7001 in_progress); Deploy (workflow run 7003 waiting)"
  [[ $output != *"CI (workflow run"* ]]
}

@test "a look whose list of the head's workflow runs fails reads no state" {
  checks 0 "$(check test SUCCESS 7001)"
  answer 0 runs fail
  head_runs 2
  run_bin team-ci-wait "$url"
  assert_equal "$status" 0
  assert_equal "$(ended_at)" 6
}

@test "every check passed or skipped ends the wait with exit 0, naming each" {
  checks 0 "$(check test QUEUED 7001)" "$(check lint IN_PROGRESS 7001)" "$(check docs SKIPPED 7001)" \
    "$(check agent-review PENDING)"
  workflow_run 0 7001 in_progress
  checks 3 "$(check test SUCCESS 7001)" "$(check lint SUCCESS 7001)" "$(check docs SKIPPED 7001)" \
    "$(check agent-review SUCCESS)"
  run_bin team-ci-wait "$url"
  assert_equal "$status" 0
  assert_equal "$(ended_at)" 7
  assert_equal "$output" "team-ci-wait: waiting on the checks of owner/proj#217 at a1b2c3d
team-ci-wait: every check passed on a1b2c3d: test passed, lint passed, docs skipped, agent-review passed"
}

@test "a failed agent-review is a failed check like any other, but --no-agent-review leaves it out of every look" {
  # The builder's wait runs while the reviewer delivers, so the reviewer's agent-review may fail
  # before the builder's wait takes its last look: the builder's wait passes on CI alone.
  checks 0 "$(check test IN_PROGRESS 7001)" "$(check lint SUCCESS 7001)"
  workflow_run 0 7001 in_progress
  checks 2 "$(check test SUCCESS 7001)" "$(check lint SUCCESS 7001)" "$(check agent-review FAILURE)"
  run_bin team-ci-wait "$url" "$head"
  assert_equal "$status" 1
  assert_contains "$output" "
  the PR's: agent-review failed: https://ci.example.invalid/agent-review"
  echo 0 >"$GH_DIR/look"
  run_bin team-ci-wait --no-agent-review "$url" "$head"
  assert_equal "$status" 0
  assert_equal "$(ended_at)" 6
  assert_equal "$output" "team-ci-wait: waiting on the checks of owner/proj#217 at a1b2c3d
team-ci-wait: every check passed on a1b2c3d: test passed, lint passed"
}

@test "an earlier review's failed agent-review, with no link, is the PR's unless --no-agent-review leaves it out" {
  # A rereview or verify of a head an earlier review failed: the status GitHub shows is that
  # review's own, set by team-review-status with no link, which the wait would name as the PR's.
  local review
  review=$(jq -cn '{name: "agent-review", state: "FAILURE", bucket: "fail", link: "", workflow: ""}')
  checks 0 "$(check test SUCCESS 7001)" "$(check lint SUCCESS 7001)" "$review"
  run_bin team-ci-wait "$url" "$head"
  assert_equal "$status" 1
  assert_contains "$output" "
  the PR's: agent-review failed: no link"
  echo 0 >"$GH_DIR/look"
  run_bin team-ci-wait --no-agent-review "$url" "$head"
  assert_equal "$status" 0
  assert_equal "$output" "team-ci-wait: waiting on the checks of owner/proj#217 at a1b2c3d
team-ci-wait: every check passed on a1b2c3d: test passed, lint passed"
}

@test "--no-agent-review ends the wait on CI's own checks, with agent-review still pending or the only check" {
  checks 0 "$(check test SUCCESS 7001)" "$(check agent-review PENDING)"
  run_bin team-ci-wait --no-agent-review "$url"
  assert_equal "$status" 0
  assert_equal "$(ended_at)" 4
  assert_contains "$output" "every check passed on a1b2c3d: test passed"
  [[ $output != *agent-review* ]]
  echo 0 >"$GH_DIR/look"
  checks 0 "$(check agent-review FAILURE)"
  run_bin team-ci-wait --no-agent-review "$url"
  assert_equal "$status" 0
  assert_equal "$(ended_at)" 4
  assert_contains "$output" "a1b2c3d has no GitHub checks: none reported for 2 minutes"
}

# A cancel after a step ran is a timeout or a hang, or a re-push's concurrency cancel: the PR's.
@test "failed and cancelled checks end the wait with exit 1 once nothing else is pending, each the PR's with its link" {
  checks 0 "$(check test FAILURE 7001)" "$(check lint IN_PROGRESS 7002)" "$(check docs PENDING)"
  workflow_run 0 7002 in_progress
  checks 4 "$(check test FAILURE 7001)" "$(check lint CANCELLED 7002)" "$(check docs PENDING)"
  checks 6 "$(check test FAILURE 7001)" "$(check lint CANCELLED 7002)" "$(check docs SUCCESS)"
  job 0 97001 "GitHub Actions 12" "Set up job=success" "Run actions/checkout@v4=success" "Run the tests=failure" \
    "Post Run actions/checkout@v4=success" "Complete job=success"
  job 0 97002 "GitHub Actions 13" "Set up job=success" "Run the linter=cancelled" "Complete job="
  run_bin team-ci-wait "$url"
  assert_equal "$status" 1
  assert_equal "$(ended_at)" 6
  assert_equal "$output" "team-ci-wait: waiting on the checks of owner/proj#217 at a1b2c3d
team-ci-wait: the checks on a1b2c3d did not pass:
  the PR's: test failed: https://github.com/owner/proj/actions/runs/7001/job/97001
  the PR's: lint was cancelled: https://github.com/owner/proj/actions/runs/7002/job/97002"
}

@test "a head with no checks reported for 2 minutes ends the wait with exit 0" {
  answer 0 checks none
  run_bin team-ci-wait "$url"
  assert_equal "$status" 0
  assert_equal "$(ended_at)" 4
  assert_contains "$output" "team-ci-wait: a1b2c3d has no GitHub checks: none reported for 2 minutes"
}

@test "checks that appear within 2 minutes are waited on" {
  answer 0 checks none
  checks 3 "$(check test SUCCESS 7001)"
  run_bin team-ci-wait "$url"
  assert_equal "$status" 0
  assert_equal "$(ended_at)" 7
  assert_contains "$output" "every check passed on a1b2c3d: test passed"
}

@test "a head that moves ends the wait with exit 1, naming both heads" {
  checks 0 "$(check test PENDING)"
  pr OPEN 9f8e7d6c5b4a39281706f5e4d3c2b1a098765432 2
  run_bin team-ci-wait "$url"
  assert_equal "$status" 1
  assert_equal "$(ended_at)" 2
  assert_contains "$output" "team-ci-wait: the head of owner/proj#217 moved from a1b2c3d to 9f8e7d6: the new head's checks need a wait of their own"
}

@test "a head other than the one the worker means for 2 minutes of looks ends the wait with exit 1, naming both and the report" {
  checks 0 "$(check test SUCCESS)"
  run_bin team-ci-wait "$url" 9f8e7d6c5b4a39281706f5e4d3c2b1a098765432
  assert_equal "$status" 1
  assert_equal "$(ended_at)" 4
  assert_equal "$output" "team-ci-wait: the head of owner/proj#217 is a1b2c3d, not 9f8e7d6, after 2 minutes of looks: it is another commit, and its checks are not the ones to wait on; if a1b2c3d is not your own, report it to the coordinator"
}

@test "the grace's seam shortens it, and names it in seconds when they are not whole minutes" {
  checks 0 "$(check test SUCCESS)"
  TEAM_CI_WAIT_GRACE_SECONDS=30 run_bin team-ci-wait "$url" 9f8e7d6c5b4a39281706f5e4d3c2b1a098765432
  assert_equal "$status" 1
  assert_equal "$(ended_at)" 1
  assert_contains "$output" "is a1b2c3d, not 9f8e7d6, after 30 seconds of looks: it is another commit"
  echo 0 >"$GH_DIR/look"
  TEAM_CI_WAIT_GRACE_SECONDS=0 run_bin team-ci-wait "$url" 9f8e7d6c5b4a39281706f5e4d3c2b1a098765432
  assert_equal "$status" 1
  assert_equal "$(ended_at)" 0
  TEAM_CI_WAIT_GRACE_SECONDS=2m run_bin team-ci-wait "$url"
  assert_equal "$status" 2
  assert_contains "$output" "TEAM_CI_WAIT_GRACE_SECONDS must be a number of seconds"
}

@test "a push GitHub shows within the grace is waited on, and its checks end the wait" {
  other=9f8e7d6c5b4a39281706f5e4d3c2b1a098765432
  checks 0 "$(check test FAILURE)"
  pr OPEN "$other" 2
  checks 2 "$(check test PENDING)"
  checks 5 "$(check test SUCCESS)"
  run_bin team-ci-wait "$url" "$other"
  assert_equal "$status" 0
  assert_equal "$(ended_at)" 9
  assert_equal "$output" "team-ci-wait: waiting on the checks of owner/proj#217 at 9f8e7d6
team-ci-wait: every check passed on 9f8e7d6: test passed"
}

@test "a head that moves after the grace's first matching look still ends the wait, naming both heads" {
  other=9f8e7d6c5b4a39281706f5e4d3c2b1a098765432
  checks 0 "$(check test PENDING)"
  pr OPEN "$other" 1
  pr OPEN 0123456789abcdef0123456789abcdef01234567 3
  run_bin team-ci-wait "$url" "$other"
  assert_equal "$status" 1
  assert_equal "$(ended_at)" 3
  assert_contains "$output" "team-ci-wait: the head of owner/proj#217 moved from 9f8e7d6 to 0123456: the new head's checks need a wait of their own"
}

@test "a PR merged or closed while the grace waits for its head ends the wait at once, naming its state" {
  checks 0 "$(check test PENDING)"
  pr MERGED "$head" 1
  run_bin team-ci-wait "$url" 9f8e7d6c5b4a39281706f5e4d3c2b1a098765432
  assert_equal "$status" 1
  assert_equal "$(ended_at)" 1
  assert_equal "$output" "team-ci-wait: owner/proj#217 is merged: its checks no longer matter"
}

@test "the head the worker means, in full or short, is waited on" {
  checks 0 "$(check test PENDING)"
  checks 1 "$(check test SUCCESS)"
  run_bin team-ci-wait "$url" "$head"
  assert_equal "$status" 0
  assert_contains "$output" "team-ci-wait: waiting on the checks of owner/proj#217 at a1b2c3d"
  assert_contains "$output" "every check passed on a1b2c3d: test passed"
  echo 0 >"$GH_DIR/look"
  run_bin team-ci-wait "$url" "${head:0:7}"
  assert_equal "$status" 0
  assert_contains "$output" "every check passed on a1b2c3d: test passed"
}

@test "a merged or closed PR ends the wait with exit 1, naming its state" {
  checks 0 "$(check test PENDING)"
  pr MERGED "$head" 1
  run_bin team-ci-wait "$url"
  assert_equal "$status" 1
  assert_contains "$output" "team-ci-wait: owner/proj#217 is merged: its checks no longer matter"
  echo 0 >"$GH_DIR/look"
  rm "$GH_DIR/view.1"
  pr CLOSED "$head" 1
  run_bin team-ci-wait "$url"
  assert_equal "$status" 1
  assert_contains "$output" "team-ci-wait: owner/proj#217 is closed: its checks no longer matter"
}

@test "the deadline's looks with checks pending end the wait with exit 75, naming each with its run; its seam shortens it" {
  checks 0 "$(check test IN_PROGRESS 7001)" "$(check lint SUCCESS 7001)" "$(check deploy PENDING)"
  workflow_run 0 7001 in_progress
  TEAM_CI_WAIT_DEADLINE_SECONDS=600 run_bin team-ci-wait "$url"
  assert_equal "$status" 75
  assert_equal "$(ended_at)" 20
  assert_contains "$output" "team-ci-wait: 10 minutes, and checks still pending on a1b2c3d: test (in_progress, run 7001 in_progress); deploy (pending, not an Actions run): run team-ci-wait again to wait on them, or report BLOCKED"
  TEAM_CI_WAIT_DEADLINE_SECONDS=90m run_bin team-ci-wait "$url"
  assert_equal "$status" 2
  assert_contains "$output" "TEAM_CI_WAIT_DEADLINE_SECONDS must be a number of seconds"
}

@test "gh failing at every look for 5 minutes ends the wait with exit 75 and gh's last reason" {
  answer 0 view fail
  run_bin team-ci-wait "$url"
  assert_equal "$status" 75
  assert_equal "$(ended_at)" 10
  assert_equal "$output" "team-ci-wait: GitHub could not be read for 5 minutes running: gh pr view: error connecting to api.github.com"
}

@test "one failing look between good ones neither ends the wait nor advances the stuck clock" {
  checks 0 "$(check e2e IN_PROGRESS 41110572636)"
  workflow_run 0 41110572636 completed success
  answer 4 run-41110572636 fail
  workflow_run 5 41110572636 completed success
  run_bin team-ci-wait "$url"
  assert_equal "$status" 1
  assert_equal "$(ended_at)" 11
  assert_contains "$output" "e2e is still in_progress, but its run 41110572636 completed success"
}

@test "a run that is no longer completed at a look restarts the stuck clock" {
  checks 0 "$(check e2e IN_PROGRESS 7001)"
  workflow_run 0 7001 completed failure
  workflow_run 4 7001 in_progress
  workflow_run 5 7001 completed success
  run_bin team-ci-wait "$url"
  assert_equal "$status" 1
  assert_equal "$(ended_at)" 15
  assert_contains "$output" "e2e is still in_progress, but its run 7001 completed success"
}

@test "while the team holds offline, the wait ends at once with exit 75 and the hold, before any gh call" {
  mkdir -p "$HOME/.local/state/agent-team"
  echo '{"since": "2026-10-22T13:05:00Z", "posted": true}' >"$HOME/.local/state/agent-team/offline"
  run_bin team-ci-wait "$url"
  assert_equal "$status" 75
  assert_equal "$output" "team-ci-wait: GitHub is unreachable (since $(date -d 2026-10-22T13:05:00Z +%H:%M)); the team is holding: commit locally, write handoff.md, send T<n> PAUSED offline, and wait."
  assert_equal "$(stub_calls gh)" ""
}

@test "a hold that starts during the wait ends it at the next look" {
  checks 0 "$(check test PENDING)"
  stub_script sleep <<EOF
mkdir -p "$HOME/.local/state/agent-team"
echo '{"since": "2026-10-22T13:05:00Z"}' >"$HOME/.local/state/agent-team/offline"
EOF
  run_bin team-ci-wait "$url"
  assert_equal "$status" 75
  assert_contains "$output" "the team is holding"
  assert_equal "$(stub_calls gh | grep -c .)" 3
}

@test "a malformed command line is a usage error, and a repo no project has is refused" {
  run_bin team-ci-wait
  assert_equal "$status" 2
  assert_contains "$output" "usage: team-ci-wait [--no-agent-review] [--json] [--look] <pr url> [<sha>]"
  run_bin team-ci-wait "$url" extra
  assert_equal "$status" 2
  run_bin team-ci-wait "$url" a1b2c3
  assert_equal "$status" 2
  run_bin team-ci-wait "$url" "$head" extra
  assert_equal "$status" 2
  run_bin team-ci-wait --no-such-option "$url"
  assert_equal "$status" 2
  run_bin team-ci-wait "$url" --no-agent-review
  assert_equal "$status" 2
  # The options come before the URL, and a refused command line prints no JSON object.
  run_bin team-ci-wait --json "$url" --look
  assert_equal "$status" 2
  assert_contains "$output" "usage: team-ci-wait [--no-agent-review] [--json] [--look] <pr url> [<sha>]"
  run_bin team-ci-wait --look --json --bogus "$url"
  assert_equal "$status" 2
  run_bin team-ci-wait --json "$url" "$head" extra
  assert_equal "$status" 2
  [[ $output != *'{'* ]]
  run_bin team-ci-wait https://github.com/owner/proj/issues/217
  assert_equal "$status" 2
  assert_contains "$output" "not a GitHub pull request URL"
  run_bin team-ci-wait https://github.com/someone/else/pull/3
  assert_equal "$status" 1
  assert_contains "$output" "someone/else is no registered project's repo"
  assert_equal "$(stub_calls gh)" ""
}

@test "the wait only reads GitHub, and prints no run's or check's text" {
  checks 0 "$(check test SUCCESS 7001)" "$(check e2e IN_PROGRESS 7002)" "$(check unit QUEUED 7002)"
  workflow_run 0 7002 in_progress
  checks 2 "$(check test SUCCESS 7001)" "$(check e2e FAILURE 7002)" "$(check unit SUCCESS 7002 8)"
  job 0 97002 "GitHub Actions 12" "Set up job=success" "Run the e2e tests=failure"
  run_bin team-ci-wait "$url"
  assert_equal "$status" 1
  [[ $output != *OUTPUT-MARKER* ]]
  assert_equal "$(stub_calls gh | jq -r '.[0:2] | join(" ")' | LC_ALL=C sort -u)" "api repos/owner/proj/actions/jobs/97002
api repos/owner/proj/actions/runs/7002
api repos/owner/proj/actions/runs?head_sha=$head&per_page=100
pr checks
pr view"
  # One read of each distinct run per look and of the failed job at the end, with nothing that writes.
  assert_equal "$(stub_calls gh | jq -c 'select(.[0] == "api" and (.[1] | contains("head_sha") | not))' | LC_ALL=C sort -u)" '["api","repos/owner/proj/actions/jobs/97002"]
["api","repos/owner/proj/actions/runs/7002"]'
  assert_equal "$(stub_calls gh | jq -c 'select(.[0] == "api" and (.[1] | contains("head_sha") | not))' | grep -c .)" 3
  assert_equal "$(stub_calls gh | jq -c 'select(.[0] == "api" and length != 2)')" ""
}

# The classes of a failed check: the PR's own, infrastructure, or a roll-up left out beside its
# failed shard. Each fixture is a real run's shape, read from GitHub's jobs API (T295).

@test "a roll-up beside its failed shard of the same run is left out, after the shard's line" {
  checks 0 "$(check test FAILURE 7001 71)" "$(check "test-shards (1)" SUCCESS 7001 72)" "$(check "test-shards (2)" FAILURE 7001 73)"
  job 0 73 "GitHub Actions 3" "Set up job=success" "Run tests/run bats --shard 2/3=failure"
  run_bin team-ci-wait "$url"
  assert_equal "$status" 1
  assert_equal "$output" "team-ci-wait: waiting on the checks of owner/proj#217 at a1b2c3d
team-ci-wait: the checks on a1b2c3d did not pass:
  the PR's: test-shards (2) failed: https://github.com/owner/proj/actions/runs/7001/job/73
  roll-up: test, of test-shards (2), left out"
}

@test "a roll-up whose shards all passed is the PR's" {
  checks 0 "$(check test FAILURE 7001 71)" "$(check "test-shards (1)" SUCCESS 7001 72)" "$(check "test-shards (2)" SUCCESS 7001 73)"
  job 0 71 "GitHub Actions 3" "Set up job=success" "Every shard passed=failure"
  run_bin team-ci-wait "$url"
  assert_equal "$status" 1
  assert_equal "$output" "team-ci-wait: waiting on the checks of owner/proj#217 at a1b2c3d
team-ci-wait: the checks on a1b2c3d did not pass:
  the PR's: test failed: https://github.com/owner/proj/actions/runs/7001/job/71"
}

@test "the shard-name rule takes -shard, -shards, ' shard' and ' shards' after the roll-up's name, within one run only" {
  checks 0 "$(check test FAILURE 7001 71)" "$(check test-shard-1 FAILURE 7001 72)" \
    "$(check macos CANCELLED 7001 73)" "$(check "macos-shards (1)" FAILURE 7001 74)" \
    "$(check e2e FAILURE 7001 75)" "$(check "e2e shard 3/6" FAILURE 7001 76)" "$(check "e2e shard 4/6" FAILURE 7001 77)" \
    "$(check unit FAILURE 7001 78)" "$(check "unit shards 2" FAILURE 7001 79)" \
    "$(check lint FAILURE 7001 80)" "$(check lintshard FAILURE 7001 81)" "$(check "lint-check" FAILURE 7001 82)" \
    "$(check docs FAILURE 7002 83)" "$(check "docs-shards (1)" FAILURE 7001 84)"
  local id
  for id in 72 74 76 77 79 80 81 82 83 84; do job 0 "$id" "GitHub Actions 3" "Run the tests=failure"; done
  run_bin team-ci-wait "$url"
  assert_equal "$status" 1
  assert_equal "$output" "team-ci-wait: waiting on the checks of owner/proj#217 at a1b2c3d
team-ci-wait: the checks on a1b2c3d did not pass:
  the PR's: test-shard-1 failed: https://github.com/owner/proj/actions/runs/7001/job/72
  the PR's: macos-shards (1) failed: https://github.com/owner/proj/actions/runs/7001/job/74
  the PR's: e2e shard 3/6 failed: https://github.com/owner/proj/actions/runs/7001/job/76
  the PR's: e2e shard 4/6 failed: https://github.com/owner/proj/actions/runs/7001/job/77
  the PR's: unit shards 2 failed: https://github.com/owner/proj/actions/runs/7001/job/79
  the PR's: lint failed: https://github.com/owner/proj/actions/runs/7001/job/80
  the PR's: lintshard failed: https://github.com/owner/proj/actions/runs/7001/job/81
  the PR's: lint-check failed: https://github.com/owner/proj/actions/runs/7001/job/82
  the PR's: docs failed: https://github.com/owner/proj/actions/runs/7002/job/83
  the PR's: docs-shards (1) failed: https://github.com/owner/proj/actions/runs/7001/job/84
  roll-up: test, of test-shard-1, left out
  roll-up: macos, of macos-shards (1), left out
  roll-up: e2e, of e2e shard 3/6, e2e shard 4/6, left out
  roll-up: unit, of unit shards 2, left out"
}

@test "a job with no runner and no step that ran is infrastructure, failed or cancelled, with its rerun" {
  checks 0 "$(check "macos-shards (1)" CANCELLED 7001 81)" "$(check "macos-shards (2)" FAILURE 7001 82)"
  job 0 81 null
  job 0 82 "" "Set up job=skipped" "Run the tests="
  run_bin team-ci-wait "$url"
  assert_equal "$status" 1
  assert_equal "$output" "team-ci-wait: waiting on the checks of owner/proj#217 at a1b2c3d
team-ci-wait: the checks on a1b2c3d did not pass:
  infrastructure: macos-shards (1) never started: no runner took it (https://github.com/owner/proj/actions/runs/7001/job/81); rerun it with gh run rerun 7001 --job 81 --repo owner/proj, then run team-ci-wait again
  infrastructure: macos-shards (2) never started: no runner took it (https://github.com/owner/proj/actions/runs/7001/job/82); rerun it with gh run rerun 7001 --job 82 --repo owner/proj, then run team-ci-wait again"
  [[ $output != *OUTPUT-MARKER* ]]
}

@test "a job with no runner but a step that ran, or a runner but no step, is the PR's" {
  checks 0 "$(check lint CANCELLED 7001 81)" "$(check test CANCELLED 7001 82)"
  job 0 81 "" "Set up job=success" "Run the linter=cancelled"
  job 0 82 "GitHub Actions 4"
  run_bin team-ci-wait "$url"
  assert_equal "$status" 1
  assert_equal "$output" "team-ci-wait: waiting on the checks of owner/proj#217 at a1b2c3d
team-ci-wait: the checks on a1b2c3d did not pass:
  the PR's: lint was cancelled: https://github.com/owner/proj/actions/runs/7001/job/81
  the PR's: test was cancelled: https://github.com/owner/proj/actions/runs/7001/job/82"
}

@test "a failure at GitHub's own step or a stock action's is infrastructure in setup, naming the step" {
  local step
  for step in "Set up job" "Set up runner" "Initialize containers" "Complete job" "Run actions/checkout@v4" \
    "Post Run actions/cache@v4"; do
    echo 0 >"$GH_DIR/look"
    checks 0 "$(check test FAILURE 7001 71)"
    job 0 71 "GitHub Actions 2" "Set up job=success" "$step=failure" "Run the tests=skipped" "Run the lint=failure"
    run_bin team-ci-wait "$url"
    assert_equal "$status" 1
    assert_equal "$output" "team-ci-wait: waiting on the checks of owner/proj#217 at a1b2c3d
team-ci-wait: the checks on a1b2c3d did not pass:
  infrastructure: test failed in setup, at its step \"$step\" (https://github.com/owner/proj/actions/runs/7001/job/71); rerun it with gh run rerun 7001 --job 71 --repo owner/proj, then run team-ci-wait again"
  done
}

@test "a failure at a custom-named setup step, a test step, or no step at all is the PR's" {
  local step
  for step in "Install the Homebrew packages" "Run tests/run bats" "Run my-org/actions/setup@v1" "Set up job, again"; do
    echo 0 >"$GH_DIR/look"
    checks 0 "$(check test FAILURE 7001 71)"
    job 0 71 "GitHub Actions 2" "Set up job=success" "$step=failure" "Run actions/checkout@v4=failure"
    run_bin team-ci-wait "$url"
    assert_equal "$status" 1
    assert_equal "$output" "team-ci-wait: waiting on the checks of owner/proj#217 at a1b2c3d
team-ci-wait: the checks on a1b2c3d did not pass:
  the PR's: test failed: https://github.com/owner/proj/actions/runs/7001/job/71"
  done
  echo 0 >"$GH_DIR/look"
  job 0 71 "GitHub Actions 2" "Set up job=success" "Run the tests=success"
  run_bin team-ci-wait "$url"
  assert_equal "$status" 1
  assert_contains "$output" "
  the PR's: test failed: https://github.com/owner/proj/actions/runs/7001/job/71"
}

@test "a check whose job cannot be read is the PR's, and so said; one with no Actions link reads no job" {
  checks 0 "$(check test FAILURE 7001 71)" "$(check deploy FAILURE)"
  answer 0 job-71 fail
  run_bin team-ci-wait "$url"
  assert_equal "$status" 1
  assert_equal "$output" "team-ci-wait: waiting on the checks of owner/proj#217 at a1b2c3d
team-ci-wait: the checks on a1b2c3d did not pass:
  the PR's: test failed: https://github.com/owner/proj/actions/runs/7001/job/71 (its job could not be read)
  the PR's: deploy failed: https://ci.example.invalid/deploy"
  assert_equal "$(stub_calls gh | jq -c 'select(.[1] | contains("/jobs/"))')" '["api","repos/owner/proj/actions/jobs/71"]'
}

@test "a check queued with no runner for 20 minutes of looks is infrastructure and no longer holds the wait" {
  checks 0 "$(check lint SUCCESS 7001 70)" "$(check "macos-shards (1)" QUEUED 7001 71)"
  workflow_run 0 7001 queued
  head_runs 0 7001:CI:queued
  run_bin team-ci-wait "$url"
  assert_equal "$status" 1
  assert_equal "$(ended_at)" 40
  assert_equal "$output" "team-ci-wait: waiting on the checks of owner/proj#217 at a1b2c3d
team-ci-wait: the checks on a1b2c3d did not pass:
  infrastructure: macos-shards (1) is still queued after 20 minutes of looks: no runner took it (https://github.com/owner/proj/actions/runs/7001/job/71); cancel its run with gh run cancel 7001 --repo owner/proj, then rerun the job with gh run rerun 7001 --job 71 --repo owner/proj, then run team-ci-wait again"
  # Its job is never read: its link and state say it all.
  [[ $(stub_calls gh) != *"/jobs/"* ]]
}

@test "the queued clock counts any pending state but in_progress, restarts when one starts, and its seam replaces the 20 minutes" {
  checks 0 "$(check test WAITING 7001)"
  workflow_run 0 7001 in_progress
  head_runs 0 7001:CI:in_progress
  checks 6 "$(check test IN_PROGRESS 7001)"
  checks 7 "$(check test PENDING 7001)"
  TEAM_CI_WAIT_QUEUED_SECONDS=300 run_bin team-ci-wait "$url"
  assert_equal "$status" 1
  assert_equal "$(ended_at)" 17
  assert_contains "$output" "
  infrastructure: test is still pending after 5 minutes of looks: no runner took it"
  TEAM_CI_WAIT_QUEUED_SECONDS=20m run_bin team-ci-wait "$url"
  assert_equal "$status" 2
  assert_contains "$output" "TEAM_CI_WAIT_QUEUED_SECONDS must be a number of seconds"
}

@test "a check that starts within the queued limit is waited on to its end" {
  checks 0 "$(check test QUEUED 7001)"
  workflow_run 0 7001 queued
  head_runs 0 7001:CI:queued
  checks 30 "$(check test IN_PROGRESS 7001)"
  workflow_run 30 7001 in_progress
  checks 60 "$(check test SUCCESS 7001)"
  head_runs 60
  run_bin team-ci-wait "$url"
  assert_equal "$status" 0
  assert_equal "$(ended_at)" 64
}

@test "a pending commit status from outside Actions is never called queued, and is waited on to the deadline" {
  checks 0 "$(check test SUCCESS 7001)" "$(check deploy PENDING)"
  TEAM_CI_WAIT_DEADLINE_SECONDS=1800 run_bin team-ci-wait "$url"
  assert_equal "$status" 75
  assert_equal "$(ended_at)" 60
  assert_contains "$output" "deploy (pending, not an Actions run)"
}

@test "a mixed failure prints the PR's first, then infrastructure, then roll-ups, reading only the failed jobs, once" {
  checks 0 "$(check test FAILURE 7001 71)" "$(check docs FAILURE 7001 72)" "$(check "test-shards (1)" FAILURE 7001 73)" \
    "$(check e2e IN_PROGRESS 7002 74)" "$(check deploy CANCELLED)" "$(check "macos-shards (1)" QUEUED 7003 75)"
  workflow_run 0 7002 completed failure
  workflow_run 0 7003 queued
  head_runs 0 7003:macOS:queued
  job 0 72 "GitHub Actions 2" "Set up job=success" "Run actions/checkout@v4=failure"
  job 0 73 "GitHub Actions 3" "Set up job=success" "Run tests/run bats --shard 1/3=failure"
  TEAM_CI_WAIT_QUEUED_SECONDS=600 run_bin team-ci-wait "$url"
  assert_equal "$status" 1
  assert_equal "$(ended_at)" 20
  assert_equal "$output" "team-ci-wait: waiting on the checks of owner/proj#217 at a1b2c3d
team-ci-wait: the checks on a1b2c3d did not pass:
  the PR's: test-shards (1) failed: https://github.com/owner/proj/actions/runs/7001/job/73
  the PR's: deploy was cancelled: https://ci.example.invalid/deploy
  infrastructure: docs failed in setup, at its step \"Run actions/checkout@v4\" (https://github.com/owner/proj/actions/runs/7001/job/72); rerun it with gh run rerun 7001 --job 72 --repo owner/proj, then run team-ci-wait again
  infrastructure: e2e is still in_progress, but its run 7002 completed failure at 2026-10-30T18:52:11Z: GitHub lost the job's status; re-run it with gh run rerun 7002 --repo owner/proj, then run team-ci-wait again, and report BLOCKED if it sticks again
  infrastructure: macos-shards (1) is still queued after 10 minutes of looks: no runner took it (https://github.com/owner/proj/actions/runs/7003/job/75); cancel its run with gh run cancel 7003 --repo owner/proj, then rerun the job with gh run rerun 7003 --job 75 --repo owner/proj, then run team-ci-wait again
  roll-up: test, of test-shards (1), left out"
  assert_equal "$(stub_calls gh | jq -c 'select(.[1] | contains("/jobs/"))')" '["api","repos/owner/proj/actions/jobs/72"]
["api","repos/owner/proj/actions/jobs/73"]'
  [[ $output != *OUTPUT-MARKER* ]]
}

# --json: one object on every end, its text the text form's end and its exit code the same (T295).

@test "--json on checks that passed is outcome passed with no failures; on no checks, none" {
  checks 0 "$(check test SUCCESS 7001)" "$(check docs SKIPPED 7001)"
  both "$url"
  assert_equal "$status" 0
  assert_equal "$(jq -c '[.outcome, .head, .failures, .text]' <<<"$output")" \
    "[\"passed\",\"$head\",[],\"team-ci-wait: every check passed on a1b2c3d: test passed, docs skipped\"]"
  echo 0 >"$GH_DIR/look"
  rm "$GH_DIR"/checks.*
  answer 0 checks none
  both "$url"
  assert_equal "$status" 0
  assert_equal "$(jq -c '[.outcome, .failures]' <<<"$output")" '["none",[]]'
  assert_equal "$(jq -r .text <<<"$output")" "team-ci-wait: a1b2c3d has no GitHub checks: none reported for 2 minutes"
}

@test "--json on a failure gives each failure's class, kind, state, link, run, job, step and rerun, in the text's order" {
  required test docs "test-shards (1)" e2e deploy "macos-shards (1)" build
  checks 0 "$(check test FAILURE 7001 71)" "$(check docs FAILURE 7001 72)" "$(check "test-shards (1)" FAILURE 7001 73)" \
    "$(check e2e IN_PROGRESS 7002 74)" "$(check deploy CANCELLED)" "$(check "macos-shards (1)" QUEUED 7003 75)"
  workflow_run 0 7002 completed failure
  workflow_run 0 7003 queued
  head_runs 0 7003:macOS:queued
  job 0 72 "GitHub Actions 2" "Set up job=success" "Run actions/checkout@v4=failure"
  job 0 73 "GitHub Actions 3" "Set up job=success" "Run tests/run bats --shard 1/3=failure"
  TEAM_CI_WAIT_QUEUED_SECONDS=600 both "$url"
  assert_equal "$status" 1
  assert_equal "$(jq -r .outcome <<<"$output")" failed
  assert_equal "$(jq -c '.failures[]' <<<"$output")" \
'{"name":"test-shards (1)","state":"failure","link":"https://github.com/owner/proj/actions/runs/7001/job/73","run":7001,"job":73,"step":"Run tests/run bats --shard 1/3","rerun":null,"class":"pr","kind":"failed"}
{"name":"deploy","state":"cancelled","link":"https://ci.example.invalid/deploy","run":null,"job":null,"step":null,"rerun":null,"class":"pr","kind":"cancelled"}
{"name":"docs","state":"failure","link":"https://github.com/owner/proj/actions/runs/7001/job/72","run":7001,"job":72,"step":"Run actions/checkout@v4","rerun":"gh run rerun 7001 --job 72 --repo owner/proj","class":"infrastructure","kind":"setup"}
{"name":"e2e","state":"in_progress","link":"https://github.com/owner/proj/actions/runs/7002/job/74","run":7002,"job":74,"step":null,"rerun":"gh run rerun 7002 --repo owner/proj","class":"infrastructure","kind":"stuck"}
{"name":"macos-shards (1)","state":"queued","link":"https://github.com/owner/proj/actions/runs/7003/job/75","run":7003,"job":75,"step":null,"rerun":"gh run rerun 7003 --job 75 --repo owner/proj","class":"infrastructure","kind":"queued"}
{"name":"test","state":"failure","link":"https://github.com/owner/proj/actions/runs/7001/job/71","run":7001,"job":71,"step":null,"rerun":null,"class":"rollup","kind":"rollup"}'
  # Each failure's line in the text is in the same order, the first line before them.
  assert_equal "$(jq -r '.text | split("\n") | map(split(":")[0] | ltrimstr("  ")) | join(",")' <<<"$output")" \
    "team-ci-wait,the PR's,the PR's,infrastructure,infrastructure,infrastructure,roll-up"
  [[ $output != *OUTPUT-MARKER* ]]
}

@test "--json names a required check not reported as missing, and a job never started with its rerun" {
  required build
  checks 0 "$(check "macos-shards (1)" CANCELLED 7001 81)" "$(check macos FAILURE 7001 82)"
  job 0 81 ""
  both "$url"
  assert_equal "$status" 1
  assert_equal "$(jq -c '.failures[] | [.name, .class, .kind, .state, .link, .run, .job, .rerun]' <<<"$output")" \
'["macos-shards (1)","infrastructure","never-started","cancelled","https://github.com/owner/proj/actions/runs/7001/job/81",7001,81,"gh run rerun 7001 --job 81 --repo owner/proj"]
["macos","rollup","rollup","failure","https://github.com/owner/proj/actions/runs/7001/job/82",7001,82,null]'
  echo 0 >"$GH_DIR/look"
  rm "$GH_DIR"/checks.*
  checks 0 "$(check test SUCCESS 7001)"
  both "$url"
  assert_equal "$status" 1
  assert_equal "$(jq -c '[.outcome, .failures]' <<<"$output")" \
    '["failed",[{"name":"build","class":"pr","kind":"missing","state":null,"link":null,"run":null,"job":null,"step":null,"rerun":null}]]'
}

@test "--json ends as other-head, moved and closed with the PR's head and no failures" {
  other=9f8e7d6c5b4a39281706f5e4d3c2b1a098765432
  checks 0 "$(check test SUCCESS)"
  both "$url" "$other"
  assert_equal "$status" 1
  assert_equal "$(jq -c '[.outcome, .head, .failures]' <<<"$output")" "[\"other-head\",\"$head\",[]]"
  assert_contains "$(jq -r .text <<<"$output")" "is a1b2c3d, not 9f8e7d6, after 2 minutes of looks"
  echo 0 >"$GH_DIR/look"
  rm "$GH_DIR"/checks.*
  checks 0 "$(check test PENDING)"
  pr OPEN "$other" 2
  both "$url"
  assert_equal "$status" 1
  assert_equal "$(jq -c '[.outcome, .head, .failures]' <<<"$output")" "[\"moved\",\"$other\",[]]"
  echo 0 >"$GH_DIR/look"
  pr MERGED "$head" 2
  both "$url"
  assert_equal "$status" 1
  assert_equal "$(jq -c '[.outcome, .head, .text]' <<<"$output")" \
    "[\"closed\",\"$head\",\"team-ci-wait: owner/proj#217 is merged: its checks no longer matter\"]"
}

@test "--json ends as deadline, unreadable and offline, each with exit 75" {
  checks 0 "$(check test IN_PROGRESS 7001)"
  workflow_run 0 7001 in_progress
  TEAM_CI_WAIT_DEADLINE_SECONDS=600 both "$url"
  assert_equal "$status" 75
  assert_equal "$(jq -c '[.outcome, .head, .failures]' <<<"$output")" "[\"deadline\",\"$head\",[]]"
  assert_contains "$(jq -r .text <<<"$output")" "checks still pending on a1b2c3d: test (in_progress, run 7001 in_progress)"
  echo 0 >"$GH_DIR/look"
  answer 0 view fail
  both "$url"
  assert_equal "$status" 75
  assert_equal "$(jq -c '[.outcome, .head, .text]' <<<"$output")" \
    '["unreadable",null,"team-ci-wait: GitHub could not be read for 5 minutes running: gh pr view: error connecting to api.github.com"]'
  echo 0 >"$GH_DIR/look"
  mkdir -p "$HOME/.local/state/agent-team"
  echo '{"since": "2026-10-22T13:05:00Z", "posted": true}' >"$HOME/.local/state/agent-team/offline"
  both "$url"
  assert_equal "$status" 75
  assert_equal "$(jq -c '[.outcome, .head, .failures]' <<<"$output")" '["offline",null,[]]'
  assert_contains "$(jq -r .text <<<"$output")" "the team is holding"
  # A deadline shorter than gh's 5 minutes, with no look read yet, is unreadable too.
  rm "$HOME/.local/state/agent-team/offline"
  echo 0 >"$GH_DIR/look"
  TEAM_CI_WAIT_DEADLINE_SECONDS=60 both "$url"
  assert_equal "$status" 75
  assert_equal "$(ended_at)" 2
  assert_equal "$(jq -c '[.outcome, .head, .text]' <<<"$output")" \
    '["unreadable",null,"team-ci-wait: 1 minute, and GitHub not read yet: gh pr view: error connecting to api.github.com: run team-ci-wait again to wait, or report BLOCKED"]'
}

# --look: one readable look at the head, what has failed so far, classed, with no wait (T295).

@test "--look on a failed check, its roll-up and pending checks exits 1 at the first look, naming each" {
  checks 0 "$(check test FAILURE 7001 71)" "$(check "test-shards (2)" FAILURE 7001 73)" \
    "$(check "test-shards (1)" SUCCESS 7001 72)" "$(check e2e IN_PROGRESS 7002 74)" "$(check lint QUEUED 7002 76)"
  workflow_run 0 7002 in_progress
  head_runs 0 7002:E2E:in_progress
  job 0 73 "GitHub Actions 3" "Set up job=success" "Run tests/run bats --shard 2/3=failure"
  run_bin team-ci-wait --look "$url" "$head"
  assert_equal "$status" 1
  assert_equal "$(ended_at)" 0
  assert_equal "$output" "team-ci-wait: the checks on a1b2c3d did not pass:
  the PR's: test-shards (2) failed: https://github.com/owner/proj/actions/runs/7001/job/73
  roll-up: test, of test-shards (2), left out
  still pending: e2e (in_progress, run 7002 in_progress); lint (queued, run 7002 in_progress)"
  echo 0 >"$GH_DIR/look"
  run_bin team-ci-wait --look --json "$url" "$head"
  assert_equal "$status" 1
  assert_equal "$(jq -c '[.outcome, .head, [.failures[] | [.name, .class, .kind, .step]]]' <<<"$output")" \
    "[\"failed\",\"$head\",[[\"test-shards (2)\",\"pr\",\"failed\",\"Run tests/run bats --shard 2/3\"],[\"test\",\"rollup\",\"rollup\",null]]]"
  assert_contains "$(jq -r .text <<<"$output")" "  still pending: e2e (in_progress, run 7002 in_progress)"
}

@test "--look with nothing failed exits 0: pending, passed or none" {
  checks 0 "$(check test SUCCESS 7001)" "$(check e2e IN_PROGRESS 7002)"
  workflow_run 0 7002 in_progress
  both --look "$url"
  assert_equal "$status" 0
  assert_equal "$(ended_at)" 0
  assert_equal "$(jq -c '[.outcome, .failures, .text]' <<<"$output")" \
    '["pending",[],"team-ci-wait: no check has failed on a1b2c3d so far; still pending: e2e (in_progress, run 7002 in_progress)"]'
  # A workflow run still open with no check pending is pending too: a rerun may replace a check.
  echo 0 >"$GH_DIR/look"
  checks 1 "$(check test SUCCESS 7001)"
  head_runs 1 7003:Docs:queued
  echo 1 >"$GH_DIR/look"
  run_bin team-ci-wait --look "$url"
  assert_equal "$status" 0
  assert_equal "$output" "team-ci-wait: no check has failed on a1b2c3d so far; still pending: Docs (workflow run 7003 queued)"
  echo 0 >"$GH_DIR/look"
  rm "$GH_DIR"/checks.* "$GH_DIR"/runs.*
  head_runs 0
  checks 0 "$(check test SUCCESS 7001)" "$(check docs SKIPPED 7001)"
  both --look "$url"
  assert_equal "$status" 0
  assert_equal "$(jq -c '[.outcome, .text]' <<<"$output")" '["passed","team-ci-wait: every check passed on a1b2c3d: test passed, docs skipped"]'
  echo 0 >"$GH_DIR/look"
  answer 0 checks none
  both --look "$url"
  assert_equal "$status" 0
  assert_equal "$(jq -c '[.outcome, .text]' <<<"$output")" '["none","team-ci-wait: a1b2c3d has no GitHub checks reported so far"]'
  # A look reads no job but a failed one's, and nothing that writes.
  assert_equal "$(stub_calls gh | jq -c 'select(.[1] | contains("/jobs/"))')" ""
}

@test "--look names no stuck, queued or missing check, only pending ones, since each needs a clock" {
  required test build
  checks 0 "$(check test SUCCESS 7001)" "$(check e2e IN_PROGRESS 7002 74)" "$(check "macos-shards (1)" QUEUED 7003 75)"
  workflow_run 0 7002 completed success
  workflow_run 0 7003 queued
  head_runs 0 7003:macOS:queued
  run_bin team-ci-wait --look "$url"
  assert_equal "$status" 0
  assert_equal "$output" "team-ci-wait: no check has failed on a1b2c3d so far; still pending: e2e (in_progress, run 7002 completed); macos-shards (1) (queued, run 7003 queued)"
  [[ $output != *infrastructure* && $output != *build* ]]
}

@test "--look keeps the grace for a push, then ends as another head; merged, offline and unreadable end as the wait does" {
  other=9f8e7d6c5b4a39281706f5e4d3c2b1a098765432
  checks 0 "$(check test SUCCESS)"
  checks 2 "$(check test FAILURE)"
  pr OPEN "$other" 2
  run_bin team-ci-wait --look "$url" "$other"
  assert_equal "$status" 1
  assert_equal "$(ended_at)" 2
  assert_equal "$output" "team-ci-wait: the checks on 9f8e7d6 did not pass:
  the PR's: test failed: https://ci.example.invalid/test"
  echo 0 >"$GH_DIR/look"
  rm "$GH_DIR/view.2"
  both --look "$url" "$other"
  assert_equal "$status" 1
  assert_equal "$(ended_at)" 4
  assert_equal "$(jq -r .outcome <<<"$output")" other-head
  assert_contains "$text_output" "the head of owner/proj#217 is a1b2c3d, not 9f8e7d6, after 2 minutes of looks"
  echo 0 >"$GH_DIR/look"
  pr MERGED "$head" 1
  both --look "$url" "$other"
  assert_equal "$status" 1
  assert_equal "$(jq -r .outcome <<<"$output")" closed
  # GitHub not read for the grace is exit 75; read within it, the look ends as it would.
  echo 0 >"$GH_DIR/look"
  rm "$GH_DIR"/view.*
  answer 0 view fail
  both --look "$url"
  assert_equal "$status" 75
  assert_equal "$(ended_at)" 4
  assert_equal "$(jq -c '[.outcome, .text]' <<<"$output")" \
    '["unreadable","team-ci-wait: GitHub could not be read for 2 minutes running: gh pr view: error connecting to api.github.com"]'
  echo 0 >"$GH_DIR/look"
  pr OPEN "$head" 2
  both --look "$url"
  assert_equal "$status" 1
  assert_equal "$(ended_at)" 2
  echo 0 >"$GH_DIR/look"
  mkdir -p "$HOME/.local/state/agent-team"
  echo '{"since": "2026-10-22T13:05:00Z", "posted": true}' >"$HOME/.local/state/agent-team/offline"
  both --look "$url"
  assert_equal "$status" 75
  assert_equal "$(jq -r .outcome <<<"$output")" offline
}

@test "--json, --look and --no-agent-review combine in any order" {
  checks 0 "$(check test SUCCESS 7001)" "$(check agent-review FAILURE)"
  local order
  for order in "--look --json --no-agent-review" "--no-agent-review --look --json" "--json --no-agent-review --look"; do
    echo 0 >"$GH_DIR/look"
    # shellcheck disable=SC2086 # each order is split into its options
    run_bin team-ci-wait $order "$url" "${head:0:7}"
    assert_equal "$status" 0
    assert_equal "$(jq -c '[.outcome, .text]' <<<"$output")" '["passed","team-ci-wait: every check passed on a1b2c3d: test passed"]'
  done
  echo 0 >"$GH_DIR/look"
  run_bin team-ci-wait --json --look "$url"
  assert_equal "$status" 1
  assert_equal "$(jq -c '[.failures[] | [.name, .class, .kind]]' <<<"$output")" '[["agent-review","pr","failed"]]'
}
