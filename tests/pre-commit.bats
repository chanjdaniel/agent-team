#!/usr/bin/env bats
# hooks/git/pre-commit and pre-merge-commit: with core.hooksPath set to bin/hooks/git, the code
# repository changes only through pull requests and never takes records: every commit on dev or
# main is refused, and on any other branch a commit that adds or changes a records path
# (bin/lib/records). tests/pre-push.bats covers the commits that skip these hooks.

load helpers/common

setup() {
  sandbox
  repo=$(make_repo home dev)
  git -C "$repo" config core.hooksPath "$REPO_ROOT/bin/hooks/git"
}

# Write and stage each path, under the repo: stage <path>...
stage() {
  local path
  for path; do
    mkdir -p "$(dirname "$repo/$path")"
    echo "$path $RANDOM" >>"$repo/$path"
    git -C "$repo" add -- "$path"
  done
}

# Commit what is staged, with bats' run: commit <status> [git commit options...]
commit() {
  run "$1" --separate-stderr git -C "$repo" commit -q -m "chore: test" "${@:2}"
}

# Refused for the records named, one per line: assert_records <path>...
assert_records() {
  assert_equal "$stderr" "pre-commit: refused: records (ledger.jsonl, manual-steps.md, projects.toml, \
tasks/, projects/, memory/, machine/) live in the team home, never in the code repository; unstage \
them (git restore --staged -- <path>):$(printf '\n  %s' "$@")"
}

@test "on dev, every commit is refused, code or records, naming the way dev changes" {
  local head
  head=$(git -C "$repo" rev-parse HEAD)
  stage bin/team-open
  commit -1
  assert_equal "$stderr" "pre-commit: refused: nothing is committed on dev, which changes only \
through a pull request; commit on a task branch and open a PR to dev"
  stage tasks/T1/plan.md
  commit -1 -- tasks/T1/plan.md
  assert_contains "$stderr" "nothing is committed on dev"
  assert_equal "$(git -C "$repo" rev-parse HEAD)" "$head"
}

@test "on main, every commit is refused, records too" {
  git -C "$repo" checkout -q -b main
  stage tasks/T1/plan.md
  commit -1
  assert_equal "$stderr" "pre-commit: refused: nothing is committed on main; a release reaches it \
by fast-forward from dev"
}

@test "on any other branch, and on a detached HEAD, code commits freely" {
  git -C "$repo" checkout -q -b feat/T1-thing
  stage bin/team-open coordinator.settings.json "a dir/with space.md"
  commit -0
  assert_equal "$stderr" ""
  git -C "$repo" checkout -q --detach
  stage bin/team-close
  commit -0
}

@test "on any branch, a commit that adds or changes a record is refused, naming each record" {
  local head
  git -C "$repo" checkout -q -b feat/T1-thing
  head=$(git -C "$repo" rev-parse HEAD)
  stage bin/team-open ledger.jsonl manual-steps.md projects.toml tasks/T1/plan.md \
    projects/shop/backlog.md "memory/agent-team/a note.md" machine/claude/settings.json
  commit -1
  assert_records ledger.jsonl machine/claude/settings.json manual-steps.md "memory/agent-team/a note.md" \
    projects.toml projects/shop/backlog.md tasks/T1/plan.md
  assert_equal "$(git -C "$repo" rev-parse HEAD)" "$head"
  # A detached HEAD too.
  git -C "$repo" checkout -q --detach
  commit -1
  assert_contains "$stderr" "pre-commit: refused: records ("
}

@test "a commit is judged by what it commits: by pathspec, and a record deleted or renamed away goes through" {
  git -C "$repo" checkout -q -b feat/T1-thing
  stage bin/team-open tasks/T1/plan.md
  commit -0 -- bin/team-open
  assert_equal "$(git -C "$repo" diff --cached --name-only)" "tasks/T1/plan.md"
  commit -1
  assert_records tasks/T1/plan.md
  git -C "$repo" restore --staged -- tasks/T1/plan.md
  # A record already in the tree, from before the split, may leave it.
  git -C "$repo" -c core.hooksPath= commit -q -m "chore: old records" --allow-empty
  stage ledger.jsonl projects.toml
  git -C "$repo" -c core.hooksPath= commit -q -m "chore: old records"
  git -C "$repo" rm -q ledger.jsonl
  mkdir "$repo/sops"
  git -C "$repo" mv projects.toml sops/projects.md
  commit -0
  # A code path renamed into the records is refused by its new name.
  git -C "$repo" mv sops/projects.md tasks/projects.md
  commit -1
  assert_records tasks/projects.md
}

@test "a merge commit on a task branch is judged by the records it brings in; on dev and main it is refused" {
  git -C "$repo" checkout -q -b feat/T1-records
  stage tasks/T1/plan.md
  git -C "$repo" -c core.hooksPath= commit -q -m "chore: records"
  git -C "$repo" checkout -q -b feat/T1-code dev
  stage bin/team-open
  commit -0
  git -C "$repo" checkout -q -b feat/T1-work dev
  run -1 --separate-stderr git -C "$repo" merge -q --no-ff -m "Merge feat/T1-records" feat/T1-records
  assert_equal "${stderr%$'\n'Not committing merge*}" "pre-merge-commit: refused: records (ledger.jsonl, manual-steps.md, \
projects.toml, tasks/, projects/, memory/, machine/) live in the team home, never in the code \
repository; unstage them (git restore --staged -- <path>):
  tasks/T1/plan.md"
  git -C "$repo" merge --abort
  run -0 git -C "$repo" merge -q --no-ff -m "Merge feat/T1-code" feat/T1-code
  git -C "$repo" checkout -q dev
  run -1 --separate-stderr git -C "$repo" merge -q --no-ff -m "Merge feat/T1-code" feat/T1-code
  assert_equal "${stderr%$'\n'Not committing merge*}" "pre-merge-commit: refused: nothing is committed on dev, which changes \
only through a pull request; commit on a task branch and open a PR to dev, or, to bring in \
origin/dev, fast-forward to it (git pull --ff-only)"
  git -C "$repo" merge --abort
  git -C "$repo" checkout -q -b main feat/T1-code
  run -1 --separate-stderr git -C "$repo" merge -q --no-ff -m "Merge dev" feat/T1-work
  assert_contains "$stderr" "pre-merge-commit: refused: nothing is committed on main"
}

@test "a conflicted merge on dev, committed through pre-commit, gets the merge's advice too" {
  git -C "$repo" checkout -q -b feat/T1-code
  stage bin/team-open sops/plan.md
  commit -0
  git -C "$repo" checkout -q dev
  stage sops/plan.md
  git -C "$repo" -c core.hooksPath= commit -q -m "chore: on dev"
  run -1 git -C "$repo" merge -q feat/T1-code
  echo merged >"$repo/sops/plan.md"
  git -C "$repo" add sops/plan.md
  run -1 --separate-stderr git -C "$repo" commit -q --no-edit
  assert_equal "$stderr" "pre-commit: refused: nothing is committed on dev, which changes only \
through a pull request; commit on a task branch and open a PR to dev, or, to bring in origin/dev, \
fast-forward to it (git pull --ff-only)"
}

@test "the documented setup, a relative hooks path, holds in every worktree with its own checkout's hooks" {
  local wt=$HOME/projects/home-wt
  git -C "$repo" config --unset core.hooksPath
  cp -R "$REPO_ROOT/bin" "$repo/bin"
  git -C "$repo" add bin
  commit -0
  git -C "$repo" branch main
  git -C "$repo" config core.hooksPath bin/hooks/git
  stage bin/team-open
  commit -1
  assert_contains "$stderr" "nothing is committed on dev"
  git -C "$repo" worktree add -q "$wt" main
  echo x >"$wt/tasks.md"
  git -C "$wt" add tasks.md
  run -1 --separate-stderr git -C "$wt" commit -q -m "chore: test"
  assert_contains "$stderr" "nothing is committed on main"
  git -C "$wt" switch -q -c feat/T1-x
  mkdir "$wt/tasks"
  echo x >"$wt/tasks/plan.md"
  git -C "$wt" add tasks
  run -1 --separate-stderr git -C "$wt" commit -q -m "chore: test"
  assert_contains "$stderr" $'\n  tasks/plan.md'
}

@test "with no team home named, the hooks still guard the code" {
  unset TEAM_HOME
  git -C "$repo" checkout -q -b feat/T1-thing
  stage bin/team-open
  commit -0
  stage tasks/T1/plan.md
  commit -1
  assert_records tasks/T1/plan.md
  git -C "$repo" checkout -q dev
  commit -1
  assert_contains "$stderr" "nothing is committed on dev"
}
