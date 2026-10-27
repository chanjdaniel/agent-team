#!/usr/bin/env bats
# hooks/git/pre-push: with core.hooksPath set to bin/hooks/git, a push to dev is refused, however
# its commits were made, a push to main may only fast-forward it to a commit already on origin/dev,
# and a tree holding records goes only to the team home's origin.

load helpers/common

setup() {
  sandbox
  repo=$(make_repo home dev)
  git -C "$repo" config core.hooksPath "$REPO_ROOT/bin/hooks/git"
  # The team home's origin is this repository's, so the records rule's one way out is origin.
  git -C "$TEAM_HOME" init -q
  git -C "$TEAM_HOME" remote add origin "$BATS_TEST_TMPDIR/origin/home.git"
}

# Write each path and commit it on the current branch, as <subject>, past pre-commit, whose refusals
# tests/pre-commit.bats covers: commit_paths <subject> <path>...
commit_paths() {
  local path
  for path in "${@:2}"; do
    mkdir -p "$(dirname "$repo/$path")"
    echo "$path $RANDOM" >>"$repo/$path"
    git -C "$repo" add -- "$path"
  done
  git -C "$repo" -c core.hooksPath= commit -q -m "$1"
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

# Push to <remote>'s dev without the hooks, as a pull request's merge on GitHub moves it:
# merge_on_github [<remote>]
merge_on_github() {
  git -C "$repo" -c core.hooksPath= push -q "${1:-origin}" dev
}

@test "every push to dev is refused, however its commits were made, a local merge and its creation too" {
  local start dev_refused="pre-push: refused: dev changes only through a pull request, merged on \
GitHub; push a task branch and open a PR to dev"
  start=$(origin_tip dev)
  git -C "$repo" checkout -q -b feat/T1-fix
  commit_paths "fix: the fix" bin/team-open
  git -C "$repo" format-patch -q -1 -o "$BATS_TEST_TMPDIR/patches"
  git -C "$repo" checkout -q dev
  # A cherry-pick, a revert and git am skip pre-commit.
  git -C "$repo" cherry-pick feat/T1-fix >/dev/null
  push -1
  assert_equal "$stderr" "$dev_refused"
  git -C "$repo" revert --no-edit HEAD >/dev/null
  push -1
  assert_equal "$stderr" "$dev_refused"
  git -C "$repo" reset -q --keep "$start"
  git -C "$repo" am -q "$BATS_TEST_TMPDIR"/patches/*.patch
  push -1
  assert_equal "$stderr" "$dev_refused"
  # A fast-forward merge, and a merge commit made without the hooks.
  git -C "$repo" reset -q --keep "$start"
  git -C "$repo" merge -q --ff-only feat/T1-fix
  push -1
  git -C "$repo" reset -q --keep "$start"
  git -C "$repo" -c core.hooksPath= merge -q --no-ff -m "Merge feat/T1-fix" feat/T1-fix
  push -1
  assert_equal "$stderr" "$dev_refused"
  # Deleted, and created on a remote that lacks it.
  push -1 origin :dev
  assert_equal "$stderr" "$dev_refused"
  git init -q --bare "$BATS_TEST_TMPDIR/new.git"
  git -C "$repo" remote add new "$BATS_TEST_TMPDIR/new.git"
  push -1 new feat/T1-fix:dev
  assert_equal "$stderr" "$dev_refused"
  assert_equal "$(origin_tip dev)" "$start"
  assert_equal "$(git -C "$BATS_TEST_TMPDIR/new.git" for-each-ref)" ""
}

@test "main only fast-forwards to a commit already on origin/dev, and is never deleted" {
  git -C "$repo" -c core.hooksPath= push -q origin dev:main
  commit_paths "feat: code" bin/team-open
  push -1 origin dev:main
  assert_equal "$stderr" "pre-push: refused: main only fast-forwards to a commit already on \
origin/dev, as a release does"
  merge_on_github
  push -0 origin dev:main
  assert_equal "$(origin_tip main)" "$(origin_tip dev)"
  # Over origin's main, and from behind it.
  git -C "$repo" -c core.hooksPath= push -q --force origin dev~1:main
  git -C "$repo" fetch -q
  push -0 origin dev:main
  # A main moved by another clone.
  local other=$HOME/projects/other
  git clone -q "$BATS_TEST_TMPDIR/origin/home.git" "$other"
  git -C "$other" checkout -q -B main origin/dev~1
  echo x >"$other/other.sh"
  git -C "$other" add other.sh
  git -C "$other" commit -q -m "feat: other"
  git -C "$other" push -q --force origin main
  push -1 --force origin dev:main
  assert_equal "$stderr" "pre-push: refused: origin's main is at $(origin_tip main), which this \
clone lacks; fetch it first (git fetch origin)"
  git -C "$repo" fetch -q
  push -1 --force origin dev:main
  assert_equal "$stderr" "pre-push: refused: main only fast-forwards; this push would drop commits \
origin has"
  push -1 origin :main
  assert_equal "$stderr" "pre-push: refused: main is never deleted"
}

@test "main is never created by a push, and any other branch pushes freely" {
  push -1 origin dev:main
  assert_equal "$stderr" "pre-push: refused: main is created only by a release, from dev, on GitHub"
  assert_equal "$(origin_tip main)" ""
  git -C "$repo" checkout -q -b feat/T1-code
  commit_paths "feat: code" bin/team-open
  push -0 origin feat/T1-code feat/T1-code:other
  push -0 origin feat/T1-code:refs/heads/dev2 feat/T1-code:refs/tags/dev
  push -0 origin :other
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

  # With no team home named, records go nowhere, and code goes anywhere.
  unset TEAM_HOME
  push -1 origin feat/T1-more
  assert_equal "$stderr" "pre-push: refused: feat/T1-more holds records (projects.toml), which go \
only to the team home's origin, and neither TEAM_HOME nor ~/.config/agent-team/home names the team home"
  git -C "$repo" checkout -q -b feat/T1-clean dev
  commit_paths "feat: clean" bin/team-open
  push -0 elsewhere feat/T1-clean
}

@test "records go to the team home's origin; a tree without them goes anywhere, and deleting a branch is no push of records" {
  elsewhere >/dev/null
  git -C "$repo" checkout -q -b feat/T1-plan
  commit_paths "chore: records" ledger.jsonl tasks/T1/plan.md
  push -0 origin feat/T1-plan feat/T1-plan:refs/tags/v1
  assert_equal "$(origin_tip feat/T1-plan)" "$(git -C "$repo" rev-parse feat/T1-plan)"

  git -C "$repo" checkout -q -b feat/T1-code dev
  commit_paths "feat: code" bin/team-open
  push -0 elsewhere feat/T1-code feat/T1-code:other
  assert_equal "$(elsewhere_refs)" "$(git -C "$repo" rev-parse feat/T1-code) refs/heads/feat/T1-code
$(git -C "$repo" rev-parse feat/T1-code) refs/heads/other"
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
