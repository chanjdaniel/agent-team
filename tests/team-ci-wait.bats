#!/usr/bin/env bats
# team-ci-wait: a wait on a PR's GitHub checks that always ends, whatever GitHub shows.

load helpers/common

setup() {
  sandbox
  printf '%s\n' '[proj]' 'repo = "owner/proj"' 'path = "projects/proj"' 'base = "dev"' 'delivery = "direct-pr"' \
    'merge_method = "squash"' 'required_checks = ["test"]' 'task_dir = ".scratch/task"' 'docs = []' 'toolkits = []' \
    '[proj.pool]' 'provider = "git"' 'slots = ["slots/proj/1"]' >"$TEAM_HOME/projects.toml"
  head=a1b2c3d4e5f60718293a4b5c6d7e8f9012345678
  url=https://github.com/owner/proj/pull/217
  export GH_DIR=$BATS_TEST_TMPDIR/gh
  mkdir -p "$GH_DIR"
  echo 0 >"$GH_DIR/look"
  stub_gh
  stub_sleep
  pr OPEN "$head"
}

# answer <look> <what> <answer>: from look <look> on, gh answers <what> (view, checks, or run-<run
# id>) with <answer>: JSON, "fail" (gh cannot reach GitHub) or, for checks, "none" (gh's "no
# checks reported").
answer() {
  printf '%s\n' "$3" >"$GH_DIR/$2.$1"
}

# pr <state> <head> [<look>]: the PR as gh pr view shows it, from <look> on (default 0).
pr() {
  answer "${3:-0}" view "$(jq -cn --arg state "$1" --arg head "$2" '{state: $state, headRefOid: $head}')"
}

# check <name> <state> [<run id>]: one check as gh pr checks --json shows it, its bucket from its
# state, its link an Actions job link of run <run id> (none given: a commit status's link).
check() {
  jq -cn --arg name "$1" --arg state "$2" --arg run "${3:-}" '{name: $name, state: $state,
    bucket: ({SUCCESS: "pass", SKIPPED: "skipping", FAILURE: "fail", CANCELLED: "cancel"}[$state] // "pending"),
    link: (if $run == "" then "https://ci.example.invalid/\($name)"
      else "https://github.com/owner/proj/actions/runs/\($run)/job/9\($run)" end),
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

# gh answers each read from the latest answer at or before the current look; gh pr checks exits 8
# while a check is pending, as gh does. Anything unplanned fails.
stub_gh() {
  stub_script gh <<'EOF'
n=$(cat "$GH_DIR/look")
case "$*" in
  "pr view 217 --repo owner/proj --json state,headRefOid") what=view ;;
  "pr checks 217 --repo owner/proj --json name,state,bucket,link,workflow") what=checks ;;
  "api repos/owner/proj/actions/runs/"*) what=run-${2##*/} ;;
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

@test "T121: a summary check left in_progress on a run that completed ends the wait after 5 minutes, naming the re-run" {
  checks 0 "$(check test SUCCESS 41110572636)" "$(check e2e IN_PROGRESS 41110572636)"
  workflow_run 0 41110572636 completed success
  run_bin team-ci-wait "$url"
  assert_equal "$status" 1
  assert_equal "$(ended_at)" 10
  assert_contains "$output" "team-ci-wait: waiting on the checks of owner/proj#217 at a1b2c3d"
  assert_contains "$output" "e2e is still in_progress, but its run 41110572636 completed success at 2026-10-30T18:52:11Z: GitHub lost the job's status; re-run it with gh run rerun 41110572636 --repo owner/proj, then run team-ci-wait again, and report BLOCKED if it sticks again"
  [[ $output != *OUTPUT-MARKER* ]]
}

@test "a run that completes while its check concludes within 5 minutes never reads as stuck" {
  checks 0 "$(check test IN_PROGRESS 7001)"
  workflow_run 0 7001 in_progress
  workflow_run 2 7001 completed success
  checks 11 "$(check test SUCCESS 7001)"
  run_bin team-ci-wait "$url"
  assert_equal "$status" 0
  assert_equal "$(ended_at)" 11
  assert_contains "$output" "team-ci-wait: every check passed on a1b2c3d: test passed"
  [[ $output != *"still"* ]]
}

@test "every check passed or skipped ends the wait with exit 0, naming each" {
  checks 0 "$(check test QUEUED 7001)" "$(check lint IN_PROGRESS 7001)" "$(check docs SKIPPED 7001)" \
    "$(check agent-review PENDING)"
  workflow_run 0 7001 in_progress
  checks 3 "$(check test SUCCESS 7001)" "$(check lint SUCCESS 7001)" "$(check docs SKIPPED 7001)" \
    "$(check agent-review SUCCESS)"
  run_bin team-ci-wait "$url"
  assert_equal "$status" 0
  assert_equal "$(ended_at)" 3
  assert_equal "$output" "team-ci-wait: waiting on the checks of owner/proj#217 at a1b2c3d
team-ci-wait: every check passed on a1b2c3d: test passed, lint passed, docs skipped, agent-review passed"
}

@test "failed and cancelled checks end the wait with exit 1 once nothing else is pending, each with its link" {
  checks 0 "$(check test FAILURE 7001)" "$(check lint IN_PROGRESS 7002)" "$(check docs PENDING)"
  workflow_run 0 7002 in_progress
  checks 4 "$(check test FAILURE 7001)" "$(check lint CANCELLED 7002)" "$(check docs PENDING)"
  checks 6 "$(check test FAILURE 7001)" "$(check lint CANCELLED 7002)" "$(check docs SUCCESS)"
  run_bin team-ci-wait "$url"
  assert_equal "$status" 1
  assert_equal "$(ended_at)" 6
  assert_equal "$output" "team-ci-wait: waiting on the checks of owner/proj#217 at a1b2c3d
team-ci-wait: the checks on a1b2c3d did not pass:
  test failed: https://github.com/owner/proj/actions/runs/7001/job/97001
  lint was cancelled: https://github.com/owner/proj/actions/runs/7002/job/97002"
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
  assert_equal "$(ended_at)" 3
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

@test "90 minutes of looks with checks pending end the wait with exit 75, naming each with its run" {
  checks 0 "$(check test IN_PROGRESS 7001)" "$(check lint SUCCESS 7001)" "$(check deploy PENDING)"
  workflow_run 0 7001 in_progress
  run_bin team-ci-wait "$url"
  assert_equal "$status" 75
  assert_equal "$(ended_at)" 180
  assert_contains "$output" "team-ci-wait: 90 minutes, and checks still pending on a1b2c3d: test (in_progress, run 7001 in_progress); deploy (pending, not an Actions run): run team-ci-wait again to wait on them, or report BLOCKED"
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
  assert_equal "$(stub_calls gh | grep -c .)" 2
}

@test "a malformed command line is a usage error, and a repo no project has is refused" {
  run_bin team-ci-wait
  assert_equal "$status" 2
  assert_contains "$output" "usage: team-ci-wait <pr url>"
  run_bin team-ci-wait "$url" extra
  assert_equal "$status" 2
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
  checks 2 "$(check test SUCCESS 7001)" "$(check e2e FAILURE 7002)" "$(check unit SUCCESS 7002)"
  run_bin team-ci-wait "$url"
  assert_equal "$status" 1
  [[ $output != *OUTPUT-MARKER* ]]
  assert_equal "$(stub_calls gh | jq -r '.[0:2] | join(" ")' | sort -u)" "api repos/owner/proj/actions/runs/7002
pr checks
pr view"
  # One read of each distinct run per look, with nothing that writes.
  assert_equal "$(stub_calls gh | jq -c 'select(.[0] == "api")' | sort -u)" '["api","repos/owner/proj/actions/runs/7002"]'
  assert_equal "$(stub_calls gh | jq -c 'select(.[0] == "api")' | grep -c .)" 2
}
