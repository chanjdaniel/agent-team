#!/usr/bin/env bats
# hooks/git/pre-commit and pre-merge-commit: with core.hooksPath set to bin/hooks/git, a commit on
# dev may touch records only (bin/lib/records), a commit on main is refused, and any other branch
# commits freely. tests/pre-push.bats covers the commits that skip these hooks.

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

@test "on dev, a commit of records only goes through" {
  stage ledger.jsonl manual-steps.md projects.toml tasks/T1/plan.md tasks/T1/scratch/notes.md \
    projects/shop/backlog.md memory/agent-team/note.md machine/claude/settings.json
  commit -0
  assert_equal "$stderr" ""
  assert_equal "$(git -C "$repo" status --porcelain)" ""
}

@test "on dev, a commit touching anything else is refused, naming each path that is not a record" {
  local head
  head=$(git -C "$repo" rev-parse HEAD)
  stage tasks/T1/plan.md bin/team-open coordinator.settings.json "a dir/with space.md"
  commit -1
  assert_equal "$stderr" "pre-commit: refused: a direct commit on dev may touch records only \
(ledger.jsonl, manual-steps.md, projects.toml, tasks/, projects/, memory/, machine/, usage/); commit these \
on a task branch and open a PR to dev:
  a dir/with space.md
  bin/team-open
  coordinator.settings.json"
  assert_equal "$(git -C "$repo" rev-parse HEAD)" "$head"
}

@test "on dev, a rename names the path it leaves too" {
  mkdir "$repo/tasks"
  git -C "$repo" mv README.md tasks/README.md
  commit -1
  assert_contains "$stderr" $'\n  README.md'
  assert_equal "$(grep -c '^  ' <<<"$stderr")" 1
}

@test "on dev, a commit by pathspec is judged by what it commits, not by the rest of the index" {
  stage bin/team-open tasks/T1/plan.md
  commit -0 -- tasks/T1/plan.md
  assert_equal "$(git -C "$repo" diff --cached --name-only)" "bin/team-open"
  commit -1
}

@test "on main, every commit is refused, records too" {
  git -C "$repo" checkout -q -b main
  stage tasks/T1/plan.md
  commit -1
  assert_equal "$stderr" "pre-commit: refused: nothing is committed on main; a release reaches it \
by fast-forward from dev"
}

@test "any other branch, and a detached HEAD, commit freely" {
  git -C "$repo" checkout -q -b feat/T1-thing
  stage bin/team-open
  commit -0
  git -C "$repo" checkout -q --detach
  stage coordinator.settings.json
  commit -0
}

@test "a merge commit on dev is judged by what it brings in; on main it is refused" {
  git -C "$repo" checkout -q -b feat/T1-records
  stage tasks/T1/plan.md
  commit -0
  git -C "$repo" checkout -q -b feat/T1-code dev
  stage bin/team-open
  commit -0
  git -C "$repo" checkout -q dev
  run -1 --separate-stderr git -C "$repo" merge -q --no-ff -m "Merge feat/T1-code" feat/T1-code
  assert_contains "$stderr" "pre-merge-commit: refused: a direct commit on dev may touch records only"
  assert_contains "$stderr" "open a PR to dev, or, for a merge from origin/dev, rebase onto it \
instead (git pull --rebase):"$'\n  bin/team-open'
  git -C "$repo" merge --abort
  run -0 git -C "$repo" merge -q --no-ff -m "Merge feat/T1-records" feat/T1-records
  git -C "$repo" checkout -q -b main feat/T1-code
  run -1 --separate-stderr git -C "$repo" merge -q --no-ff -m "Merge dev" dev
  assert_contains "$stderr" "pre-merge-commit: refused: nothing is committed on main"
}

@test "a conflicted merge on dev, committed through pre-commit, gets the merge's advice too" {
  git -C "$repo" checkout -q -b feat/T1-code
  stage bin/team-open tasks/plan.md
  commit -0
  git -C "$repo" checkout -q dev
  stage tasks/plan.md
  commit -0
  run -1 git -C "$repo" merge -q feat/T1-code
  echo merged >"$repo/tasks/plan.md"
  git -C "$repo" add tasks/plan.md
  run -1 --separate-stderr git -C "$repo" commit -q --no-edit
  assert_contains "$stderr" "pre-commit: refused: a direct commit on dev may touch records only"
  assert_contains "$stderr" "or, for a merge from origin/dev, rebase onto it instead (git pull \
--rebase):"$'\n  bin/team-open'
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
  assert_contains "$stderr" $'\n  bin/team-open'
  git -C "$repo" worktree add -q "$wt" main
  echo x >"$wt/tasks.md"
  git -C "$wt" add tasks.md
  run -1 --separate-stderr git -C "$wt" commit -q -m "chore: test"
  assert_contains "$stderr" "nothing is committed on main"
}
