#!/usr/bin/env bats
# team-records-check: CI's check of a push to dev, where each commit the push adds along the first
# parent must touch records only (bin/lib/records) or be a pull request's merge into dev.

load helpers/common

setup() {
  sandbox
  repo=$(make_repo home dev)
  cd "$repo" || return
  start=$(git rev-parse HEAD)
}

# Commit a change to each path on the current branch: commit_paths <subject> <path>...
commit_paths() {
  local path
  for path in "${@:2}"; do
    mkdir -p "$(dirname "$path")"
    echo "$path $RANDOM" >>"$path"
    git add -- "$path"
  done
  git commit -q -m "$1"
}

# A branch feat/T1 off dev with one commit to bin/, merged into dev with a merge commit as GitHub
# makes it; sets merge and head.
merge_a_pr() {
  git checkout -q -b feat/T1 dev
  commit_paths "feat: a script" bin/team-thing
  head=$(git rev-parse HEAD)
  git checkout -q dev
  git merge -q --no-ff -m "Merge pull request #7 from o/feat/T1" feat/T1
  merge=$(git rev-parse HEAD)
}

# GitHub answers the commit's pulls with one PR: pr_reply <merge_commit_sha> <head sha> <base> <merged_at>
pr_reply() {
  stub_reply gh "$(jq -cn --arg m "$1" --arg h "$2" --arg b "$3" --arg at "$4" \
    '[{number: 7, merge_commit_sha: $m, head: {sha: $h}, base: {ref: $b}, merged_at: (if $at == "" then null else $at end)}]')"
}

@test "commits of records only pass, without asking GitHub" {
  commit_paths "chore(T1): opened" ledger.jsonl tasks/T1/plan.md
  commit_paths "chore: steps" manual-steps.md projects.toml projects/shop/backlog.md memory/a/n.md \
    machine/x.json
  run_bin -0 team-records-check --repo o/r "$start" HEAD
  assert_equal "$output" "2 commits on dev checked: each touches records only or is a pull request's merge into dev"
  assert_equal "$(stub_calls gh)" ""
}

@test "a commit touching anything else fails, naming the commit and each path that is not a record" {
  commit_paths "chore(T1): opened" tasks/T1/plan.md
  commit_paths "chore: a setting" coordinator.settings.json tasks/T1/plan.md
  local bad
  bad=$(git rev-parse --short HEAD)
  commit_paths "test: fix" tests/x.bats
  run_bin -1 --separate-stderr team-records-check --repo o/r "$start" HEAD
  assert_equal "$output" "refused $(git rev-parse --short HEAD) test: fix
  tests/x.bats
refused $bad chore: a setting
  coordinator.settings.json"
  assert_equal "$stderr" "team-records-check: 2 of 3 commits on dev refused: a direct commit on dev \
may touch records only (ledger.jsonl, manual-steps.md, projects.toml, tasks/, projects/, memory/, \
machine/), and anything else reaches dev through a pull request"
}

@test "a pull request's merge passes, and the pull request's own commits are not walked" {
  merge_a_pr
  pr_reply "$merge" "$head" dev 2026-10-22T12:00:00Z
  run_bin -0 team-records-check --repo o/r "$start" HEAD
  assert_equal "$output" "1 commit on dev checked: each touches records only or is a pull request's merge into dev"
  assert_equal "$(stub_calls gh)" "[\"api\",\"repos/o/r/commits/$merge/pulls\"]"
}

@test "a merge that is not a merged pull request's into dev, with this head, fails" {
  merge_a_pr
  local other
  other=$(git rev-parse dev~1)
  for reply in "$merge $other dev 2026-10-22T12:00:00Z" "$merge $head main 2026-10-22T12:00:00Z" \
    "$merge $head dev " "$other $head dev 2026-10-22T12:00:00Z"; do
    read -r m h b at <<<"$reply"
    pr_reply "$m" "$h" "$b" "${at:-}"
    run_bin -1 --separate-stderr team-records-check --repo o/r "$start" HEAD
    assert_equal "$output" "refused $(git rev-parse --short "$merge") Merge pull request #7 from o/feat/T1 (a merge, not a pull request's into dev)
  bin/team-thing"
  done
  stub_reply gh '[]'
  run_bin -1 team-records-check --repo o/r "$start" HEAD
}

@test "a merge that brings in records only passes, without asking GitHub" {
  git checkout -q -b elsewhere dev
  commit_paths "chore: there" tasks/T2/plan.md
  git checkout -q dev
  commit_paths "chore: here" tasks/T1/plan.md
  git merge -q --no-ff -m "Merge elsewhere" elsewhere
  run_bin -0 team-records-check --repo o/r "$start" HEAD
  assert_contains "$output" "2 commits on dev checked"
  assert_equal "$(stub_calls gh)" ""
}

@test "a GitHub failure fails the check with gh's reason" {
  merge_a_pr
  stub_script gh <<'FIXTURE'
echo "HTTP 502: Bad Gateway" >&2
exit 1
FIXTURE
  run_bin -1 --separate-stderr team-records-check --repo o/r "$start" HEAD
  assert_equal "$stderr" "team-records-check: cannot ask GitHub about merge $merge: gh api: HTTP 502: Bad Gateway"
}

@test "a new branch's push (before all zeros) checks its tip alone" {
  commit_paths "feat: code" bin/team-thing
  commit_paths "chore: records" tasks/T1/plan.md
  run_bin -0 team-records-check --repo o/r 0000000000000000000000000000000000000000 HEAD
  assert_contains "$output" "1 commit on dev checked"
}

@test "a before this clone lacks (a force-push) fails, and so does a malformed command line" {
  commit_paths "chore: records" tasks/T1/plan.md
  run_bin -1 --separate-stderr team-records-check --repo o/r 1111111111111111111111111111111111111111 HEAD
  assert_equal "$stderr" "team-records-check: the push's old tip 1111111111111111111111111111111111111111 is not in this clone: dev was force-pushed or the clone is shallow; check the push by hand"
  run_bin -2 team-records-check "$start" HEAD
  run_bin -2 team-records-check --repo o/r "$start"
  run_bin -2 team-records-check --repo o/r "$start" HEAD extra
}
