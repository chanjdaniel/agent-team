#!/usr/bin/env bats
# team-open: opening a task for a project with a treehouse pool, through fake lease and return
# commands in the fake project's primary checkout. They behave like Conventioner's
# scripts/th-lease.sh and scripts/th-return.sh over treehouse v2.0.0: the lease hands out the
# next free pre-made worktree (detached), the return detaches a clean worktree and frees it, and
# answers a dirty one with treehouse's prompt, aborted, leaving it leased.

load helpers/common

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
  fake_pool_commands
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

# Write the fake lease and return commands into the primary checkout (untracked there, so no
# worktree sees them). Each logs {cwd, args} per call to $STUB_CALLS/<file name>.log, read with
# stub_calls. The lease hands out the first line of $BATS_TEST_TMPDIR/free; the return puts a
# clean worktree back at its end.
fake_pool_commands() {
  mkdir -p "$primary/scripts"
  cat >"$primary/scripts/th-lease.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
jq -cn --arg cwd "$PWD" '{cwd: $cwd, args: $ARGS.positional}' --args "$@" >>"$STUB_CALLS/${0##*/}.log"
free=$BATS_TEST_TMPDIR/free
echo "🌳 Setting up worktree..." >&2
path=$(head -n 1 "$free")
if [[ -z $path ]]; then
  echo "all 2 worktrees are in use or dirty (max_trees = 2). Run 'treehouse status' to see details, or increase max_trees in treehouse.toml" >&2
  exit 1
fi
sed -i 1d "$free"
echo "[setup] installing node_modules (pre-warm)" >&2
echo "$path"
SH
  cat >"$primary/scripts/th-return.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
jq -cn --arg cwd "$PWD" '{cwd: $cwd, args: $ARGS.positional}' --args "$@" >>"$STUB_CALLS/${0##*/}.log"
if [[ -n $(git -C "$1" status --porcelain) ]]; then
  echo "Worktree has uncommitted changes. Clean and return? [Y/n] 🌳 Aborted."
  exit 0
fi
git -C "$1" switch -q --detach
echo "$1" >>"$BATS_TEST_TMPDIR/free"
echo "🌳 Worktree returned to pool."
SH
  chmod +x "$primary/scripts/th-lease.sh" "$primary/scripts/th-return.sh"
}

events() {
  jq -c --arg e "$1" 'select(.event == $e)' "$TEAM_HOME/ledger.jsonl"
}

# The arguments of each call to a fake pool command, one line per call.
pool_calls() {
  stub_calls "$1" | jq -r '.args | join(" ")'
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

@test "a leased path outside the trusted slots is returned at once and refused" {
  local stray=$HOME/.treehouse/proj-zzz999/1/proj
  git -C "$primary" worktree add -q --detach "$stray" origin/main
  echo "$stray" >"$BATS_TEST_TMPDIR/free"
  run_bin -1 --separate-stderr team-open proj feature feat stray "Stray"
  assert_contains "$stderr" "the lease command handed out $stray, which is not one of proj's slots"
  assert_contains "$stderr" "handed $stray back to $primary/scripts/th-return.sh"
  assert_equal "$(stub_calls th-return.sh)" "$(jq -cn --arg cwd "$primary" --arg p "$stray" '{cwd: $cwd, args: [$p]}')"
  assert_equal "$(git -C "$stray" rev-parse --abbrev-ref HEAD)" "HEAD"
  [[ ! -e $TEAM_HOME/tasks/T1 ]]
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" ""
  assert_equal "$(stub_calls curl)" ""
}

@test "a slot with changes to tracked files is returned and refused, naming them" {
  echo changed >>"${slots[0]}/README.md"
  run_bin -1 --separate-stderr team-open proj feature feat dirty "Dirty"
  assert_contains "$stderr" "the leased slot ${slots[0]} is not clean"
  assert_contains "$stderr" "changes to tracked files: README.md"
  assert_contains "$stderr" "Clean and return? [Y/n] 🌳 Aborted."
  assert_equal "$(pool_calls th-return.sh)" "${slots[0]}"
  assert_equal "$(git -C "${slots[0]}" rev-parse --abbrev-ref HEAD)" "HEAD"
  assert_equal "$(cat "${slots[0]}/README.md")" "$(printf 'proj\nchanged')"
  [[ ! -e $TEAM_HOME/tasks/T1 ]]
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" ""
}

@test "a slot with untracked files is returned and refused, naming them" {
  touch "${slots[0]}/stray.txt" "${slots[0]}/notes.md"
  run_bin -1 --separate-stderr team-open proj feature feat untracked "Untracked"
  assert_contains "$stderr" "untracked files: notes.md stray.txt"
  [[ $stderr != *"changes to tracked files"* ]]
  assert_equal "$(pool_calls th-return.sh)" "${slots[0]}"
  [[ -e ${slots[0]}/stray.txt ]]
}

@test "a slot with a non-empty task directory is returned and refused, naming it" {
  mkdir -p "${slots[0]}/.scratch/task/tickets"
  touch "${slots[0]}/.scratch/task/spec.md"
  run_bin -1 --separate-stderr team-open proj feature feat leftover "Leftover"
  assert_contains "$stderr" "a non-empty task directory .scratch/task: spec.md tickets"
  assert_equal "$(pool_calls th-return.sh)" "${slots[0]}"
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
