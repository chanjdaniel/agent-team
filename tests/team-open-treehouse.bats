#!/usr/bin/env bats
# team-open: opening a task for a project with a treehouse pool, through fake lease and return
# commands in the fake project's primary checkout (helpers/treehouse).

load helpers/common
load helpers/treehouse

setup() {
  sandbox
  primary=$(make_repo proj)
  echo ".scratch/" >"$primary/.gitignore"
  git -C "$primary" add .gitignore
  git -C "$primary" commit -q -m "chore: ignore scratch"
  git -C "$primary" push -q origin main
  pool=$HOME/.treehouse/proj-abc123
  slots=("$pool/1/proj" "$pool/2/proj")
  local slot
  for slot in "${slots[@]}"; do git -C "$primary" worktree add -q --detach "$slot" origin/main; done
  printf '%s\n' "${slots[@]}" >"$BATS_TEST_TMPDIR/free"
  fake_pool_commands "$primary"
  cat >"$TEAM_HOME/projects.toml" <<'TOML'
[proj]
repo = "owner/proj"
path = "projects/proj"
base = "main"
delivery = "no-mistakes"
merge_method = "merge"
required_checks = []
task_dir = ".scratch/task"
docs = []
toolkits = []

[proj.pool]
provider = "treehouse"
lease = "scripts/th-lease.sh"
return = "scripts/th-return.sh"
slots = [".treehouse/proj-abc123/1/proj", ".treehouse/proj-abc123/2/proj"]
TOML
  stub_reply curl '{"id":"1563000000000000001"}'
}

events() {
  jq -c --arg e "$1" 'select(.event == $e)' "$TEAM_HOME/ledger.jsonl"
}

@test "a task opens in the leased slot, leased from the primary checkout with the task as holder" {
  git config --global branch.autoSetupMerge always
  run_bin -0 --separate-stderr team-open proj bug fix sign-in-limit "Rate-limit sign-in"
  local worktree=${slots[0]} base_sha
  base_sha=$(git -C "$primary" rev-parse origin/main)
  assert_equal "$(stub_calls th-lease.sh)" "$(jq -cn --arg cwd "$primary" '{cwd: $cwd, args: ["T1"]}')"
  assert_equal "$(stub_calls th-return.sh)" ""
  assert_equal "$stderr" ""

  assert_equal "$(jq -c . <<<"$output")" "$(jq -cn --arg wt "$worktree" --arg sha "$base_sha" --arg home "$TEAM_HOME" '{
    task: "T1", project: "proj", path: "bug", title: "Rate-limit sign-in",
    branch: "fix/T1-sign-in-limit", base: "main", base_sha: $sha, worktree: $wt,
    task_dir: "\($wt)/.scratch/task", thread: "1563000000000000001", plan: "\($home)/tasks/T1/plan.md"}')"
  assert_equal "$(git -C "$worktree" rev-parse --abbrev-ref HEAD)" "fix/T1-sign-in-limit"
  assert_equal "$(git -C "$worktree" rev-parse HEAD)" "$base_sha"
  run -128 git -C "$worktree" rev-parse --abbrev-ref '@{upstream}'
  [[ -d $worktree/.scratch/task ]]
  assert_equal "$(events opened | jq -r '"\(.task) \(.branch) \(.worktree)"')" "T1 fix/T1-sign-in-limit $worktree"
  run_bin -0 team-log --check
}

@test "the slot leaves whatever branch it was on for the new branch at the fetched base" {
  git -C "${slots[0]}" switch -q -c fix/T9-old origin/main
  git -C "${slots[0]}" commit -q --allow-empty -m "fix: old work"
  local other=$BATS_TEST_TMPDIR/other ahead
  git clone -q "$BATS_TEST_TMPDIR/origin/proj.git" "$other" 2>/dev/null
  git -C "$other" commit -q --allow-empty -m "feat: moved on"
  git -C "$other" push -q origin main
  ahead=$(git -C "$other" rev-parse HEAD)

  run_bin -0 --separate-stderr team-open proj feature feat next "Next"
  assert_equal "$(jq -r '"\(.worktree) \(.base_sha)"' <<<"$output")" "${slots[0]} $ahead"
  assert_equal "$(git -C "${slots[0]}" rev-parse --abbrev-ref HEAD)" "feat/T1-next"
  assert_equal "$(git -C "${slots[0]}" rev-parse HEAD)" "$ahead"
  git -C "$primary" show-ref -q --verify refs/heads/fix/T9-old
}

@test "a pool the registry spells otherwise than treehouse and git list it is the same pool (report F6)" {
  local other
  other=$(other_spelling "$HOME/.treehouse")
  sed -i "s#\".treehouse/#\"${other##*/}/#g" "$TEAM_HOME/projects.toml"
  run_bin -0 --separate-stderr team-open proj bug fix one "One"
  assert_equal "$(jq -r .worktree <<<"$output")" "$other/proj-abc123/1/proj"
  assert_equal "$(git -C "${slots[0]}" rev-parse --abbrev-ref HEAD)" "fix/T1-one"
  # A slot leased to a task is named by its holder, the next lease is the free slot, and a
  # re-run takes the slot it left leased again.
  echo changed >>"${slots[1]}/README.md"
  run_bin -1 --separate-stderr team-open proj bug fix two "Two"
  assert_contains "$stderr" "the leased slot $other/proj-abc123/2/proj is not clean"
  run_bin -1 --separate-stderr team-open --task T2 proj bug fix two "Two"
  assert_contains "$stderr" "${slots[1]} is already leased to T2, by an earlier run; it is taken again"
  git -C "${slots[1]}" checkout -q -- README.md
  run_bin -75 --separate-stderr team-open proj bug fix three "Three"
  assert_contains "$stderr" "  $other/proj-abc123/1/proj: T1 (leased; fix/T1-one)
  $other/proj-abc123/2/proj: T2 (leased; detached HEAD)"
}

@test "a leased path outside the trusted slots is returned at once and refused" {
  local stray=$HOME/.treehouse/proj-zzz999/1/proj
  git -C "$primary" worktree add -q --detach "$stray" origin/main
  echo "$stray" >"$BATS_TEST_TMPDIR/free"
  run_bin -1 --separate-stderr team-open proj feature feat stray "Stray"
  assert_contains "$stderr" "the lease command handed out $stray, which is not one of proj's slots"
  assert_contains "$stderr" "handed $stray back to $primary/scripts/th-return.sh, discarding what its lease changed"
  assert_equal "$(stub_calls th-return.sh)" "$(jq -cn --arg cwd "$primary" --arg p "$stray" \
    '{cwd: $cwd, args: [$p, "--force", "--if-lease-holder", "T1"]}')"
  assert_equal "$(git -C "$stray" rev-parse --abbrev-ref HEAD)" "HEAD"
  assert_equal "$(pool_leases)" ""
  [[ ! -e $TEAM_HOME/tasks/T1 ]]
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" ""
  assert_equal "$(stub_calls curl)" ""
}

@test "a slot its lease's pre-warm changed is refused naming the changes, and forced back so no lease is left" {
  echo 'echo rewritten >>README.md' >"$BATS_TEST_TMPDIR/prewarm"
  run_bin -1 --separate-stderr team-open proj feature feat dirty "Dirty"
  assert_contains "$stderr" "the leased slot ${slots[0]} is not clean: changes to tracked files: README.md;" \
    "it was clean before this lease, so the lease command's pre-warm made these changes, which the return discards"
  assert_contains "$stderr" "handed ${slots[0]} back to $primary/scripts/th-return.sh, discarding what its lease changed"
  # Only the changed paths are said, never their content.
  [[ $stderr != *rewritten* ]]
  assert_equal "$(pool_calls th-return.sh)" "${slots[0]} --force --if-lease-holder T1"
  assert_equal "$(pool_leases)" ""
  assert_equal "$(git -C "${slots[0]}" status --porcelain)" ""
  assert_equal "$(git -C "${slots[0]}" rev-parse --abbrev-ref HEAD)" "HEAD"
  [[ ! -e $TEAM_HOME/tasks/T1 ]]
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" ""
}

@test "a slot its lease's pre-warm left untracked files in is refused naming them, and forced back" {
  echo 'touch stray.txt notes.md' >"$BATS_TEST_TMPDIR/prewarm"
  run_bin -1 --separate-stderr team-open proj feature feat untracked "Untracked"
  assert_contains "$stderr" "untracked files: notes.md stray.txt"
  [[ $stderr != *"changes to tracked files"* ]]
  assert_equal "$(pool_calls th-return.sh)" "${slots[0]} --force --if-lease-holder T1"
  assert_equal "$(pool_leases)" ""
  [[ ! -e ${slots[0]}/stray.txt ]]
}

@test "a slot the pool reported dirty before its lease is refused and stays leased, for Daniel to look at" {
  echo changed >>"${slots[0]}/README.md"
  run_bin -1 --separate-stderr team-open proj feature feat dirty "Dirty"
  assert_contains "$stderr" "the leased slot ${slots[0]} is not clean: changes to tracked files: README.md;" \
    "the pool reported it dirty before this lease, so the changes may be someone's work"
  assert_contains "$stderr" "worktree not returned: it has uncommitted changes"
  assert_contains "$stderr" "${slots[0]} stays leased to T1, which is Daniel's word: once nothing in it is needed," \
    "return it in a terminal, which asks before discarding: cd $primary && $primary/scripts/th-return.sh ${slots[0]}"
  assert_equal "$(pool_calls th-return.sh)" "${slots[0]}"
  assert_equal "$(pool_leases)" "${slots[0]} T1"
  assert_equal "$(cat "${slots[0]}/README.md")" "$(printf 'proj\nchanged')"
  [[ ! -e $TEAM_HOME/tasks/T1 ]]
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" ""
}

@test "a re-run takes the slot an earlier run left leased to the task, and never leases another" {
  echo changed >>"${slots[0]}/README.md"
  run_bin -1 team-open proj feature feat dirty "Dirty"
  # Again while it is dirty: refused again, and still the one lease.
  run_bin -1 --separate-stderr team-open proj feature feat dirty "Dirty"
  assert_contains "$stderr" "${slots[0]} is already leased to T1, by an earlier run; it is taken again"
  assert_contains "$stderr" "an earlier run leased it, so the changes may be someone's work"
  assert_equal "$(pool_calls th-lease.sh)" "T1"
  assert_equal "$(pool_leases)" "${slots[0]} T1"

  # Daniel discarded the changes: the next run opens the task there.
  git -C "${slots[0]}" checkout -q -- README.md
  run_bin -0 --separate-stderr team-open proj feature feat dirty "Dirty"
  assert_equal "$(jq -r .worktree <<<"$output")" "${slots[0]}"
  assert_equal "$(pool_calls th-lease.sh)" "T1"
  assert_equal "$(pool_leases)" "${slots[0]} T1"
  assert_equal "$(git -C "${slots[1]}" rev-parse --abbrev-ref HEAD)" "HEAD"
}

@test "a pool treehouse cannot read is refused before any lease" {
  stub_reply treehouse "not in a git or jj repository" 1
  rm "$STUB_FIXTURES/treehouse.sh"
  run_bin -1 --separate-stderr team-open proj feature feat blind "Blind"
  assert_contains "$stderr" "cannot read proj's pool: treehouse status --json did not answer in $primary"
  assert_equal "$(stub_calls th-lease.sh)" ""
  [[ ! -e $TEAM_HOME/tasks/T1 ]]
}

@test "a slot with a non-empty task directory is returned and refused, naming it" {
  mkdir -p "${slots[0]}/.scratch/task/tickets"
  touch "${slots[0]}/.scratch/task/spec.md"
  run_bin -1 --separate-stderr team-open proj feature feat leftover "Leftover"
  assert_contains "$stderr" "a non-empty task directory .scratch/task: spec.md tickets"
  # git ignores it, so the pool saw the slot clean, and --force keeps what git ignores.
  assert_equal "$(pool_calls th-return.sh)" "${slots[0]} --force --if-lease-holder T1"
  assert_equal "$(pool_leases)" ""
  [[ -e ${slots[0]}/.scratch/task/spec.md ]]
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" ""
}

@test "an empty task directory in the slot is fine" {
  mkdir -p "${slots[0]}/.scratch/task"
  run_bin -0 --separate-stderr team-open proj feature feat empty "Empty"
  assert_equal "$(jq -r .worktree <<<"$output")" "${slots[0]}"
  assert_equal "$(stub_calls th-return.sh)" ""
}

@test "a failing lease command is exit 75 with its message, and gives the number back" {
  : >"$BATS_TEST_TMPDIR/free"
  git -C "${slots[0]}" switch -q -c feat/T3-busy origin/main
  run_bin -75 --separate-stderr team-open proj feature feat late "Late"
  assert_equal "$output" ""
  assert_contains "$stderr" "team-open: proj's lease command found no free slot:"
  assert_contains "$stderr" "all 2 worktrees are in use or dirty (max_trees = 2)"
  assert_contains "$stderr" "$(printf '%s\n' "team-open: proj's slots:" \
    "  ${slots[0]}: T3 (feat/T3-busy)" "  ${slots[1]}: no task (detached HEAD)")"

  # A leased slot is named by its lease holder, detached or not.
  printf '%s\tT7\n%s\tT3\n' "${slots[1]}" "${slots[0]}" >"$BATS_TEST_TMPDIR/leases"
  run_bin -75 --separate-stderr team-open proj feature feat late "Late"
  assert_contains "$stderr" "$(printf '%s\n' "team-open: proj's slots:" \
    "  ${slots[0]}: T3 (leased; feat/T3-busy)" "  ${slots[1]}: T7 (leased; detached HEAD)")"
  : >"$BATS_TEST_TMPDIR/leases"
  assert_equal "$(stub_calls th-return.sh)" ""
  [[ ! -e $TEAM_HOME/tasks/T1 ]]
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" ""
  assert_equal "$(stub_calls curl)" ""
}

@test "re-running with --task reuses the slot holding the task's branch instead of leasing again" {
  stub_reply curl '{"message":"Missing Access"}'
  run_bin -1 --separate-stderr team-open proj feature feat flaky "Flaky"
  assert_contains "$stderr" "T1 is half open in ${slots[0]}; finish it with: team-open --task T1 proj feature feat flaky Flaky"
  assert_equal "$(stub_calls th-return.sh)" ""

  stub_reply curl '{"id":"1563000000000000009"}'
  run_bin -0 --separate-stderr team-open --task T1 proj feature feat flaky "Flaky"
  assert_equal "$(jq -r '"\(.worktree) \(.thread)"' <<<"$output")" "${slots[0]} 1563000000000000009"
  assert_equal "$(pool_calls th-lease.sh)" "T1"
  assert_equal "$(stub_calls th-return.sh)" ""
  assert_equal "$(git -C "${slots[1]}" rev-parse --abbrev-ref HEAD)" "HEAD"
  assert_equal "$(events opened | jq -r .worktree)" "${slots[0]}"
}

@test "a task directory git does not ignore is refused, the branch dropped and the slot returned" {
  git -C "$primary" rm -q .gitignore
  git -C "$primary" commit -q -m "chore: stop ignoring scratch"
  git -C "$primary" push -q origin main
  run_bin -1 --separate-stderr team-open proj feature feat leak "Leak"
  assert_contains "$stderr" "git does not ignore .scratch/task in proj"
  assert_equal "$(pool_calls th-return.sh)" "${slots[0]}"
  assert_equal "$(git -C "${slots[0]}" rev-parse --abbrev-ref HEAD)" "HEAD"
  assert_equal "$(git -C "${slots[0]}" status --porcelain --ignored)" ""
  run git -C "$primary" branch --list 'feat/T1-leak'
  assert_equal "$output" ""
  [[ ! -e $TEAM_HOME/tasks/T1 ]]
}

@test "a lease command that is not executable is refused without leasing" {
  chmod -x "$primary/scripts/th-lease.sh"
  run_bin -1 team-open proj feature feat nolease "No lease"
  assert_contains "$output" "the lease command $primary/scripts/th-lease.sh is not executable"
  [[ ! -e $TEAM_HOME/tasks/T1 ]]
}
