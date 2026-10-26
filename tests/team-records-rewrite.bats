#!/usr/bin/env bats
# team-records-rewrite: the records repository's history rewritten in a work directory, on a
# sandbox origin standing in for GitHub whose dev holds records, tier 1's bulk, tier 2's plan-era
# pages and screenshots, the S02 story with an applicant's address and a commit message naming
# one, beside a lease branch, a wip/* branch and a pull ref. The vendored git filter-repo runs for
# real, as at the cutover.

load helpers/common

S02=projects/conventioner/backlog/E01-csv-vendor-intake/F04-real-export-shapes/S02-a-timestamp-is-a-moment.md

setup() {
  sandbox
  origin=$(hold_lease home-pc)
  cd "$TEAM_HOME" || return
  commit_paths "docs: the plan" tasks/T1/plan.md ledger.jsonl
  commit_paths "chore: archive T1's scratch" tasks/T1/scratch/notes.md tasks/T1/scratch/tools/node_modules/left-pad/index.js \
    tasks/T1/scratch/mirror.git/HEAD tasks/T31/scratch/dl/gitleaks/gitleaks tasks/T31/scratch/dl/gitleaks.sha256
  bulk=$(git rev-parse --short=8 HEAD)
  mkdir -p "$(dirname "$S02")"
  printf 'From the export: applicant@mail.test wrote in.\nThe fixture: vendor@example.com\n' >"$S02"
  commit_paths "docs: the S02 story" projects/conventioner/lavish/qc.html projects/conventioner/lavish/shots/a.png \
    shots/b.png mvp-findings.html "$S02" projects/conventioner/wayfinding/map.png
  pr_head=$(git rev-parse HEAD)
  git push -q origin "$pr_head:refs/pull/1/head"
  git commit -q --allow-empty -m "docs: as applicant@mail.test asked

Co-Authored-By: Someone <noreply@anthropic.com>"
  git rm -q -r projects/conventioner/lavish
  commit_paths "docs: the S02 story names the fixture only, after $bulk" tasks/T1/plan.md
  git push -q origin dev
  git -C "$origin" branch wip/home/T1 "$pr_head"
  refs_before=$(git -C "$origin" for-each-ref --format='%(refname) %(objectname)')
  work=$BATS_TEST_TMPDIR/rewrite
}

# Commit a change to each path in the team home: commit_paths <subject> <path>...
commit_paths() {
  local path
  for path in "${@:2}"; do
    mkdir -p "$(dirname "$path")"
    [[ $path == "$S02" ]] || echo "$path $RANDOM" >>"$path"
    git add -- "$path"
  done
  git commit -q -m "$1"
}

# Rewrite a copy of origin's dev and lease by hand with the vendored filter-repo and <args>, as the
# script would but with other inputs, into $check/new.git beside $check/old.git, a mirror of origin.
rewrite_by_hand() {
  check=$BATS_TEST_TMPDIR/check
  git clone -q --no-local --mirror "$origin" "$check/old.git"
  git clone -q --no-local --mirror "$check/old.git" "$check/new.git"
  git -C "$check/new.git" for-each-ref --format='%(refname)' | { grep -vxE 'refs/heads/(dev|lease)' || true; } |
    xargs -r -n1 git -C "$check/new.git" update-ref -d
  (cd "$check/new.git" && python3 "$REPO_ROOT/bin/lib/vendor/git-filter-repo/git-filter-repo" --sensitive-data-removal \
    --no-fetch "$@" --prune-empty never --prune-degenerate never) >/dev/null 2>&1
}

# verify.py over rewrite_by_hand's two repositories, with the script's inputs.
verify_by_hand() {
  python3 "$REPO_ROOT/bin/lib/records-rewrite/verify.py" "$check/old.git" "$check/new.git" \
    "$REPO_ROOT/bin/lib/records-rewrite/drop.txt" "$REPO_ROOT/bin/lib/records-rewrite/message-expressions.txt" \
    --changed F04-real-export-shapes/S02-a-timestamp-is-a-moment.md
}

# What the summary says after <prefix>: , one line each.
said() {
  sed -n "s/^$1: //p" <<<"$output"
}

@test "a rehearsal drops the bulk and the scrubbed pages, keeps every record byte-identical, and prints no push while the lease is held" {
  local old
  old=$(git -C "$origin" rev-parse dev)
  run_bin -0 team-records-rewrite "$work"
  assert_equal "$(said origin)" "$origin, dev at $old, lease at $(git -C "$origin" rev-parse lease)"
  assert_equal "$(said verify | grep -v '^passed')" "commits compared: 7
commits whose tree is unchanged: 3
dropped paths, summed over commits: 26
callback-changed paths, summed over commits: 3
messages changed only by hash rewriting: 1
messages changed by the message expressions: 1
drop-list paths left in the new history: 0
pull refs whose history holds a dropped path: 1 of 1
failures: 0"
  assert_equal "$(said lease)" "unchanged at $(git -C "$origin" rev-parse lease)"
  [[ $(said 'pack before') =~ ^[0-9.]+\ MiB,\ [0-9]+\ objects$ ]]
  [[ $(said 'pack after') =~ ^[0-9.]+\ MiB,\ [0-9]+\ objects$ ]]
  assert_equal "$(said rehearsal)" "origin's lease is held, not released, so the team was not frozen: no push from this run"
  [[ $output != *"--force-with-lease"* ]]
  assert_equal "$(cat "$work/summary.txt")" "$output"

  # The rewritten dev: only the records, the S02 story naming the fixture alone, the message scrubbed.
  local rw=$work/rewrite.git
  assert_equal "$(git -C "$rw" for-each-ref --format='%(refname)')" "refs/heads/dev
refs/heads/lease"
  assert_equal "$(git -C "$rw" log --format= --name-only dev | sort -u | grep .)" "$(printf '%s\n' "$S02" \
    ledger.jsonl projects/conventioner/wayfinding/map.png tasks/T1/plan.md tasks/T1/scratch/notes.md | sort)"
  assert_equal "$(git -C "$rw" show "dev:$S02")" "From the export: vendor@example.com wrote in.
The fixture: vendor@example.com"
  assert_equal "$(git -C "$rw" log --format=%B -n1 dev~1)" "docs: as [email removed] asked

Co-Authored-By: Someone <noreply@anthropic.com>"
  # Every kept file is the same blob at the tip, and lease is the same commit.
  assert_equal "$(git -C "$rw" rev-parse dev:tasks/T1/plan.md dev:ledger.jsonl)" \
    "$(git -C "$origin" rev-parse dev:tasks/T1/plan.md dev:ledger.jsonl)"
  assert_equal "$(git -C "$rw" rev-parse lease)" "$(git -C "$origin" rev-parse lease)"
  [[ -s $rw/filter-repo/first-changed-commits ]]

  # Nothing on origin moved, and nothing new is in the team home.
  assert_equal "$(git -C "$origin" for-each-ref --format='%(refname) %(objectname)')" "$refs_before"
  assert_equal "$(cat "$work/refs-before.txt")" "$refs_before"
  # The mirror keeps every ref but no origin, so no bare push there reaches GitHub.
  assert_equal "$(git -C "$work/mirror.git" for-each-ref --format='%(refname) %(objectname)')" "$refs_before"
  assert_equal "$(git -C "$work/mirror.git" remote)" ""
  run ! git -C "$work/mirror.git" push
  assert_equal "$(git -C "$TEAM_HOME" status --porcelain)" ""
}

@test "with the lease released, it prints the force push with its lease on the old dev, which pushes dev alone; the rollback restores it" {
  local old new lease
  "$REPO_ROOT/bin/team-lease" release >/dev/null
  refs_before=$(git -C "$origin" for-each-ref --format='%(refname) %(objectname)')
  old=$(git -C "$origin" rev-parse dev)
  lease=$(git -C "$origin" rev-parse lease)
  run_bin -0 team-records-rewrite "$work"
  new=$(git -C "$work/rewrite.git" rev-parse dev)
  [[ $new != "$old" ]]
  assert_equal "$(said rehearsal)" ""
  local push rollback
  push=$(grep -A1 '^The force push' <<<"$output" | tail -n1)
  rollback=$(grep -A1 '^Rollback' <<<"$output" | tail -n1)
  assert_equal "$push" "  git -C $work/rewrite.git push --force-with-lease=refs/heads/dev:$old $origin refs/heads/dev:refs/heads/dev"
  assert_contains "$output" "Then: git ls-remote $origin shows dev at $new, lease at $lease, and every other ref as in $work/refs-before.txt."
  assert_equal "$rollback" "  git -C $work/mirror.git push --force-with-lease=refs/heads/dev:$new $origin $old:refs/heads/dev"

  # Daniel's push: dev moves, every other ref stays.
  eval "$push" 2>/dev/null
  assert_equal "$(git -C "$origin" rev-parse dev)" "$new"
  assert_equal "$(git -C "$origin" for-each-ref --format='%(refname) %(objectname)' | grep -v '^refs/heads/dev ')" \
    "$(grep -v '^refs/heads/dev ' <<<"$refs_before")"
  # Its lease refuses a dev that moved since.
  push_to_dev "$origin" tasks/T2/plan.md >/dev/null
  run ! eval "$push"
  # The rollback, onto the pushed dev, puts the old history back.
  git -C "$origin" update-ref refs/heads/dev "$new"
  eval "$rollback" 2>/dev/null
  assert_equal "$(git -C "$origin" rev-parse dev)" "$old"
}

@test "it refuses a work directory inside a checkout or one not empty, before reading origin" {
  run_bin -1 team-records-rewrite "$TEAM_HOME/tasks/T1/rewrite"
  assert_equal "$output" "team-records-rewrite: $TEAM_HOME/tasks/T1/rewrite is inside the git repository $TEAM_HOME/.git: make the work directory outside every checkout, where no checkpoint archives it"
  [[ ! -e $TEAM_HOME/tasks/T1/rewrite ]]
  mkdir -p "$work"
  touch "$work/left"
  run_bin -1 team-records-rewrite "$work"
  assert_equal "$output" "team-records-rewrite: $work is not empty: give a new directory"
  [[ ! -e $work/mirror.git ]]
  run_bin -2 team-records-rewrite
  run_bin -2 team-records-rewrite "$work" more
}

@test "an origin with only dev and lease rewrites and verifies, with no pull ref to count" {
  git -C "$origin" update-ref -d refs/heads/wip/home/T1
  git -C "$origin" update-ref -d refs/pull/1/head
  run_bin -0 team-records-rewrite "$work"
  assert_contains "$output" "verify: pull refs whose history holds a dropped path: 0 of 0"
  assert_contains "$output" "verify: failures: 0"
  [[ $(said 'pack after') =~ ^[0-9.]+\ MiB ]]
}

@test "a dropped path with a non-ASCII name is matched as it is: dropped, it passes; left behind, verify.py finds it" {
  cd "$TEAM_HOME" || return
  commit_paths "docs: a screenshot" $'shots/caf\303\251 "q".png' $'tasks/T1/scratch/node_modules/\303\244/index.js'
  git push -q origin dev
  run_bin -0 team-records-rewrite "$work"
  assert_contains "$output" "verify: drop-list paths left in the new history: 0"
  assert_contains "$output" "verify: failures: 0"
  [[ -z $(git -C "$work/rewrite.git" ls-tree -r --name-only dev -- shots tasks/T1/scratch/node_modules) ]]
  # A rewrite that dropped everything but those two names: verify sees them left.
  printf '%s\n' 'glob:tasks/*/node_modules/left-pad/*' 'regex:^tasks/.+\.git/' tasks/T31/scratch/dl/ \
    projects/conventioner/lavish/ mvp-findings.html shots/b.png >"$BATS_TEST_TMPDIR/narrower.txt"
  rewrite_by_hand --invert-paths --paths-from-file "$BATS_TEST_TMPDIR/narrower.txt" \
    --replace-message "$REPO_ROOT/bin/lib/records-rewrite/message-expressions.txt" \
    --file-info-callback "$REPO_ROOT/bin/lib/records-rewrite/s02-callback.py"
  run -1 verify_by_hand
  assert_contains "$output" "drop-list paths left in the new history: 2"
}

@test "verify.py fails a rewrite that dropped a path off its drop list, naming the commit and the path" {
  printf 'tasks/T1/scratch/\n' >"$BATS_TEST_TMPDIR/wider.txt"
  rewrite_by_hand --invert-paths --paths-from-file "$BATS_TEST_TMPDIR/wider.txt" \
    --replace-message "$REPO_ROOT/bin/lib/records-rewrite/message-expressions.txt"
  run -1 verify_by_hand
  assert_contains "$output" ": unexpected D tasks/T1/scratch/notes.md"
  # The rewrite it checked was never written to.
  assert_equal "$(git -C "$check/new.git" for-each-ref --format='%(refname)')" "refs/heads/dev
refs/heads/lease"
}

@test "verify.py fails a rewrite whose messages are not the old ones through the message expressions" {
  rewrite_by_hand --invert-paths --paths-from-file "$REPO_ROOT/bin/lib/records-rewrite/drop.txt" \
    --file-info-callback "$REPO_ROOT/bin/lib/records-rewrite/s02-callback.py"
  run -1 verify_by_hand
  assert_contains "$output" "failures: 1"
  assert_contains "$output" ": the message is not the old one through the message expressions and the commit map"
  # With them, the same rewrite passes.
  rm -rf "$check"
  rewrite_by_hand --invert-paths --paths-from-file "$REPO_ROOT/bin/lib/records-rewrite/drop.txt" \
    --replace-message "$REPO_ROOT/bin/lib/records-rewrite/message-expressions.txt" \
    --file-info-callback "$REPO_ROOT/bin/lib/records-rewrite/s02-callback.py"
  run -0 verify_by_hand
  assert_contains "$output" "messages changed by the message expressions: 1"
  assert_contains "$output" "messages changed only by hash rewriting: 1"
  # filter-repo leaves the hash of a commit it has not rewritten yet as written, which passes too.
  rm -rf "$check"
  rewrite_by_hand --invert-paths --paths-from-file "$REPO_ROOT/bin/lib/records-rewrite/drop.txt" \
    --replace-message "$REPO_ROOT/bin/lib/records-rewrite/message-expressions.txt" \
    --file-info-callback "$REPO_ROOT/bin/lib/records-rewrite/s02-callback.py" --preserve-commit-hashes
  run -0 verify_by_hand
  assert_contains "$output" "messages changed only by hash rewriting: 0"
}

@test "the vendored git filter-repo is 2.47.0, by the checksum the script's header names" {
  local sum
  sum=$(sha256sum "$REPO_ROOT/bin/lib/vendor/git-filter-repo/git-filter-repo" | cut -d' ' -f1)
  grep -qF "(sha256 $sum)" "$REPO_ROOT/bin/team-records-rewrite"
  assert_equal "$(python3 "$REPO_ROOT/bin/lib/vendor/git-filter-repo/git-filter-repo" --version)" a40bce548d2c
}
