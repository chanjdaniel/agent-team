#!/usr/bin/env bats
# hooks/git/pre-push: with core.hooksPath set to bin/hooks/git, a push to dev may only fast-forward
# it with commits that touch records only, however they were made, a push to main may only
# fast-forward it to a commit already on origin/dev, and a tree holding records goes only to the
# team home's origin.

load helpers/common

setup() {
  sandbox
  repo=$(make_repo home dev)
  git -C "$repo" config core.hooksPath "$REPO_ROOT/bin/hooks/git"
  # The team home is a clone of the same repository, as every checkout is before the split.
  git -C "$TEAM_HOME" init -q
  git -C "$TEAM_HOME" remote add origin "$BATS_TEST_TMPDIR/origin/home.git"
}

# Write each path and commit it on the current branch, as <subject>: commit_paths <subject> <path>...
commit_paths() {
  local path
  for path in "${@:2}"; do
    mkdir -p "$(dirname "$repo/$path")"
    echo "$path $RANDOM" >>"$repo/$path"
    git -C "$repo" add -- "$path"
  done
  git -C "$repo" commit -q -m "$1"
}

# Push with bats' run, stderr without git's closing error line: push <status> [git push
# arguments...] (default: origin dev)
push() {
  local args=("${@:2}")
  ((${#args[@]})) || args=(origin dev)
  run "$1" --separate-stderr git -C "$repo" push -q "${args[@]}"
  stderr=${stderr%$'\n'error: failed to push some refs to *}
}

# origin's tip of <branch>, or nothing: origin_tip <branch>
origin_tip() {
  git -C "$BATS_TEST_TMPDIR/origin/home.git" rev-parse -q --verify "refs/heads/$1" || true
}

# Refused, naming the commits and their paths that are not records: assert_refused <expected list>
assert_refused() {
  assert_equal "$stderr" "pre-push: refused: a push to dev may add only commits that touch \
records only (ledger.jsonl, manual-steps.md, projects.toml, tasks/, projects/, memory/, \
machine/); put these on a task branch and open a PR to dev:$1"
}

@test "a push to dev of commits that touch records only goes through, a local merge of records too" {
  commit_paths "chore: ledger" ledger.jsonl tasks/T1/plan.md
  git -C "$repo" checkout -q -b records
  commit_paths "chore: notes" projects/shop/backlog.md
  git -C "$repo" checkout -q dev
  commit_paths "chore: steps" manual-steps.md
  git -C "$repo" merge -q --no-ff -m "Merge records" records
  push -0
  assert_equal "$(origin_tip dev)" "$(git -C "$repo" rev-parse dev)"
}

@test "a cherry-pick, a revert, a fast-forward merge and git am skip pre-commit; the push to dev refuses each" {
  local start
  start=$(origin_tip dev)
  git -C "$repo" checkout -q -b feat/T1-fix
  commit_paths "fix: the fix" bin/team-open
  commit_paths "fix: more" coordinator.settings.json
  git -C "$repo" format-patch -q -1 -o "$BATS_TEST_TMPDIR/patches"
  git -C "$repo" checkout -q dev
  git -C "$repo" cherry-pick feat/T1-fix~1 >/dev/null
  commit_paths "chore: ledger" ledger.jsonl
  git -C "$repo" revert --no-edit HEAD~1 >/dev/null
  git -C "$repo" am -q "$BATS_TEST_TMPDIR"/patches/*.patch
  push -1
  assert_refused "
  $(git -C "$repo" rev-parse --short HEAD) fix: more
    coordinator.settings.json
  $(git -C "$repo" rev-parse --short HEAD~1) Revert \"fix: the fix\"
    bin/team-open
  $(git -C "$repo" rev-parse --short HEAD~3) fix: the fix
    bin/team-open"
  assert_equal "$(origin_tip dev)" "$start"

  git -C "$repo" reset -q --keep "$start"
  git -C "$repo" merge -q --ff-only feat/T1-fix
  push -1
  assert_contains "$stderr" $'\n    bin/team-open'
  assert_contains "$stderr" $'\n    coordinator.settings.json'
  assert_equal "$(origin_tip dev)" "$start"
}

@test "a local merge on dev that brings in more than records is refused like any other commit" {
  git -C "$repo" checkout -q -b feat/T1-code
  commit_paths "feat: code" bin/team-open
  git -C "$repo" checkout -q dev
  commit_paths "chore: ledger" ledger.jsonl
  git -C "$repo" -c core.hooksPath= merge -q --no-ff -m "Merge feat/T1-code" feat/T1-code
  push -1
  assert_refused "
  $(git -C "$repo" rev-parse --short HEAD) Merge feat/T1-code
    bin/team-open"
}

@test "dev only fast-forwards: a push behind origin or over it is refused" {
  local other=$HOME/projects/other
  git clone -q "$BATS_TEST_TMPDIR/origin/home.git" "$other"
  echo x >"$other/ledger.jsonl"
  git -C "$other" add ledger.jsonl
  git -C "$other" commit -q -m "chore: ledger"
  git -C "$other" push -q origin dev
  commit_paths "chore: plan" tasks/T1/plan.md
  push -1 --force origin dev
  assert_equal "$stderr" "pre-push: refused: origin's dev is at $(origin_tip dev), which this \
clone lacks; fetch and rebase onto it first (git pull --rebase)"
  git -C "$repo" fetch -q
  push -1 --force origin dev
  assert_equal "$stderr" "pre-push: refused: dev only fast-forwards; this push would drop \
commits origin has"
  git -C "$repo" pull -q --rebase
  push -0
}

@test "main only fast-forwards to a commit already on origin/dev, and neither branch is deleted" {
  git -C "$repo" -c core.hooksPath= push -q origin dev:main
  commit_paths "chore: ledger" ledger.jsonl
  push -1 origin dev:main
  assert_equal "$stderr" "pre-push: refused: main only fast-forwards to a commit already on \
origin/dev, as a release does"
  push -0 origin dev
  push -0 origin dev:main
  assert_equal "$(origin_tip main)" "$(origin_tip dev)"
  push -1 origin :main
  assert_equal "$stderr" "pre-push: refused: main is never deleted"
  push -1 origin :dev
  assert_equal "$stderr" "pre-push: refused: dev is never deleted"
}

@test "main is never created by a push; dev is, and any other branch pushes freely" {
  push -1 origin dev:main
  assert_equal "$stderr" "pre-push: refused: main is created only by a release, from dev, on GitHub"
  assert_equal "$(origin_tip main)" ""
  git -C "$repo" checkout -q -b feat/T1-code
  commit_paths "feat: code" bin/team-open
  push -0 origin feat/T1-code feat/T1-code:other
  push -0 origin feat/T1-code:refs/heads/dev2
  git init -q --bare "$BATS_TEST_TMPDIR/new.git"
  git -C "$repo" remote add new "$BATS_TEST_TMPDIR/new.git"
  push -0 new feat/T1-code:dev
}

# A bare repository that is not the team home's origin, as the remote elsewhere; prints its path.
elsewhere() {
  git init -q --bare "$BATS_TEST_TMPDIR/elsewhere.git"
  git -C "$repo" remote add elsewhere "$BATS_TEST_TMPDIR/elsewhere.git"
  echo "$BATS_TEST_TMPDIR/elsewhere.git"
}

# elsewhere's refs, one "<sha> <ref>" per line, or nothing
elsewhere_refs() {
  git -C "$BATS_TEST_TMPDIR/elsewhere.git" for-each-ref --format='%(objectname) %(refname)'
}

@test "a tree holding records goes to no remote but the team home's origin, whatever the branch, named or by URL" {
  local other home=$BATS_TEST_TMPDIR/origin/home.git
  other=$(elsewhere)
  git -C "$repo" checkout -q -b feat/T1-plan
  commit_paths "chore: records" ledger.jsonl tasks/T1/plan.md tasks/T1/brief.md projects/shop/backlog.md \
    memory/agent-team/MEMORY.md
  push -1 elsewhere feat/T1-plan
  assert_equal "$stderr" "pre-push: refused: feat/T1-plan holds records (ledger.jsonl, \
memory/agent-team/MEMORY.md, projects/shop/backlog.md and 2 more), which go only to the team \
home's origin, $home, not to elsewhere ($other)"
  push -1 "$other" feat/T1-plan:dev feat/T1-plan:refs/tags/v1
  assert_equal "$stderr" "pre-push: refused: dev holds records (ledger.jsonl, \
memory/agent-team/MEMORY.md, projects/shop/backlog.md and 2 more), which go only to the team \
home's origin, $home, not to $other"
  assert_equal "$(elsewhere_refs)" ""

  # One record is enough, the one the commit left alone included.
  git -C "$repo" checkout -q -b feat/T1-code dev
  commit_paths "feat: code" bin/team-open projects.toml
  git -C "$repo" checkout -q -b feat/T1-more
  commit_paths "feat: more" bin/team-close
  push -1 elsewhere feat/T1-more
  assert_equal "$stderr" "pre-push: refused: feat/T1-more holds records (projects.toml), which go \
only to the team home's origin, $home, not to elsewhere ($other)"
  assert_equal "$(elsewhere_refs)" ""

  # With no origin for the team home, records go nowhere.
  git -C "$TEAM_HOME" remote remove origin
  push -1 origin feat/T1-more
  assert_equal "$stderr" "pre-push: refused: feat/T1-more holds records (projects.toml), which go \
only to the team home's origin, and the team home $TEAM_HOME has none"
  assert_equal "$(origin_tip feat/T1-more)" ""
}

@test "records go to the team home's origin; a tree without them goes anywhere, and deleting a branch is no push of records" {
  elsewhere >/dev/null
  git -C "$repo" checkout -q -b feat/T1-plan
  commit_paths "chore: records" ledger.jsonl tasks/T1/plan.md
  push -0 origin feat/T1-plan feat/T1-plan:refs/tags/v1
  assert_equal "$(origin_tip feat/T1-plan)" "$(git -C "$repo" rev-parse feat/T1-plan)"

  git -C "$repo" checkout -q -b feat/T1-code dev
  commit_paths "feat: code" bin/team-open
  push -0 elsewhere feat/T1-code feat/T1-code:dev
  assert_equal "$(elsewhere_refs)" "$(git -C "$repo" rev-parse feat/T1-code) refs/heads/dev
$(git -C "$repo" rev-parse feat/T1-code) refs/heads/feat/T1-code"
  git -C "$BATS_TEST_TMPDIR/elsewhere.git" fetch -q "$repo" feat/T1-plan:refs/heads/old
  push -0 elsewhere :old
  assert_equal "$(git -C "$BATS_TEST_TMPDIR/elsewhere.git" rev-parse -q --verify refs/heads/old || true)" ""
}

@test "the team home's origin URL matches with or without a trailing .git or slash, on either side" {
  local home=$BATS_TEST_TMPDIR/origin/home.git
  git -C "$repo" checkout -q -b feat/T1-plan
  commit_paths "chore: records" ledger.jsonl
  git -C "$TEAM_HOME" remote set-url origin "${home%.git}"
  push -0 origin feat/T1-plan
  git -C "$TEAM_HOME" remote set-url origin "$home/"
  commit_paths "chore: more" tasks/T1/plan.md
  push -0 "${home%.git}/" feat/T1-plan
  assert_equal "$(origin_tip feat/T1-plan)" "$(git -C "$repo" rev-parse feat/T1-plan)"

  # The team home's push URL counts as well as its fetch URL; another name does not.
  git -C "$TEAM_HOME" remote set-url origin "$BATS_TEST_TMPDIR/origin/fetch.git"
  git -C "$TEAM_HOME" remote set-url --push origin "$home"
  commit_paths "chore: again" tasks/T1/brief.md
  push -0 origin feat/T1-plan
  git -C "$TEAM_HOME" remote set-url origin "${home%.git}-records.git"
  git -C "$TEAM_HOME" remote set-url --push origin "${home%.git}-records.git"
  commit_paths "chore: once more" tasks/T2/plan.md
  push -1 origin feat/T1-plan
  assert_contains "$stderr" "which go only to the team home's origin, ${home%.git}-records.git, not to origin ($home)"
}
