#!/usr/bin/env bats
# team-open --ticket: a ticket worktree of an open task, cut from the task branch's local tip,
# across a git-pool project (home) and a treehouse-pool project (conv, through the fake commands
# of helpers/treehouse), and what the ledger and team-tickets make of it.

load helpers/common
load helpers/treehouse

setup() {
  sandbox
  home=$(make_repo home)
  conv=$(make_repo conv)
  ignore_scratch "$home"
  ignore_scratch "$conv"
  home_slots=("$HOME/slots/home/1" "$HOME/slots/home/2" "$HOME/slots/home/3")
  conv_slots=("$HOME/.treehouse/conv-abc123/1/conv" "$HOME/.treehouse/conv-abc123/2/conv")
  local slot
  for slot in "${conv_slots[@]}"; do git -C "$conv" worktree add -q --detach "$slot" origin/main; done
  printf '%s\n' "${conv_slots[@]}" >"$BATS_TEST_TMPDIR/free"
  fake_pool_commands "$conv"
  cat >"$TEAM_HOME/projects.toml" <<'TOML'
[home]
repo = "owner/home"
path = "projects/home"
base = "main"
delivery = "direct-pr"
merge_method = "merge"
required_checks = []
task_dir = ".scratch/task"
docs = []
toolkits = []

[home.pool]
provider = "git"
slots = ["slots/home/1", "slots/home/2", "slots/home/3"]

[conv]
repo = "owner/conv"
path = "projects/conv"
base = "main"
delivery = "no-mistakes"
merge_method = "merge"
required_checks = []
task_dir = ".scratch/task"
docs = []
toolkits = []

[conv.pool]
provider = "treehouse"
lease = "scripts/th-lease.sh"
return = "scripts/th-return.sh"
slots = [".treehouse/conv-abc123/1/conv", ".treehouse/conv-abc123/2/conv"]
TOML
  stub_reply curl '{"id":"1563000000000000001"}'
}

# Commit and push a .gitignore with .scratch/ in the primary checkout <path>.
ignore_scratch() {
  echo ".scratch/" >"$1/.gitignore"
  git -C "$1" add .gitignore
  git -C "$1" commit -q -m "chore: ignore scratch"
  git -C "$1" push -q origin main
}

events() {
  jq -c --arg e "$1" 'select(.event == $e)' "$TEAM_HOME/ledger.jsonl"
}

# ledger_line [jq options...] <filter>: append the line jq builds, standing in for the scripts
# that will write it.
ledger_line() {
  jq -cn "$@" >>"$TEAM_HOME/ledger.jsonl"
}

# open_task <project>: open T1 in <project> as feat/T1-one, give its task directory two tickets,
# a spec, a scope and a build note, and commit one change on the task branch that is not pushed.
# Sets wt (the task worktree) and tip (the task branch's tip).
open_task() {
  run_bin -0 --separate-stderr team-open "$1" feature feat one "One"
  wt=$(jq -r .worktree <<<"$output")
  local dir=$wt/.scratch/task
  mkdir -p "$dir/tickets" "$dir/build-notes"
  printf '# 01: a\n\nBlocked by: None\nTouches: a.txt\n' >"$dir/tickets/01-a.md"
  printf '# 02: b\n\nBlocked by: None\nTouches: b.txt\n' >"$dir/tickets/02-b.md"
  printf 'a.txt\nb.txt\n' >"$dir/scope.txt"
  printf '# spec\n\nParallel: 2\n' >"$dir/spec.md"
  echo "note one" >"$dir/build-notes/01.md"
  echo a >"$wt/a.txt"
  git -C "$wt" add a.txt
  git -C "$wt" commit -q -m "feat: a"
  tip=$(git -C "$wt" rev-parse HEAD)
}

@test "--ticket gives a ticket a git-pool worktree on its ticket branch from the task branch's local tip, offline" {
  open_task home
  # Nothing reaches origin: it is gone.
  mv "$BATS_TEST_TMPDIR/origin/home.git" "$BATS_TEST_TMPDIR/away.git"
  run_bin -0 --separate-stderr team-open --task T1 --ticket 02
  local ticket_wt=${home_slots[1]}
  assert_equal "$(jq -c . <<<"$output")" "$(jq -cn --arg wt "$ticket_wt" --arg sha "$tip" '{
    task: "T1", project: "home", branch: "feat/T1-one--02", base: "feat/T1-one", base_sha: $sha,
    worktree: $wt, task_dir: "\($wt)/.scratch/task", ticket: "02"}')"
  assert_equal "$stderr" ""
  assert_equal "$(git -C "$ticket_wt" rev-parse --abbrev-ref HEAD)" "feat/T1-one--02"
  assert_equal "$(git -C "$ticket_wt" rev-parse HEAD)" "$tip"
  run -128 git -C "$ticket_wt" rev-parse --abbrev-ref '@{upstream}'

  # The task directory is a copy of the task worktree's.
  local file
  for file in spec.md scope.txt tickets/01-a.md tickets/02-b.md build-notes/01.md; do
    assert_equal "$(cat "$ticket_wt/.scratch/task/$file")" "$(cat "$wt/.scratch/task/$file")"
  done

  assert_equal "$(events worktree-added | jq -c 'del(.ts)')" "$(jq -cn --arg wt "$ticket_wt" --arg sha "$tip" '{
    task: "T1", event: "worktree-added", project: "home", branch: "feat/T1-one--02",
    base: "feat/T1-one", base_sha: $sha, worktree: $wt, ticket: "02"}')"
  mv "$BATS_TEST_TMPDIR/away.git" "$BATS_TEST_TMPDIR/origin/home.git"
  run_bin -0 team-log --check

  # team-tickets reads the tickets from the task worktree alone, each once.
  run_bin -0 --separate-stderr team-tickets T1
  assert_equal "$(tr -s ' ' <<<"$output")" "$(printf '%s\n' "01 ready a" "02 ready b")"
  run_bin -0 team-tickets T1 --check
  # The task's branch is still the task worktree's.
  run_bin -0 --separate-stderr team-brief T1 builder-ticket --set ticket=01 --name build-01
  assert_contains "$(cat "$TEAM_HOME/tasks/T1/brief-build-01.md")" "feat/T1-one"
  run grep -c 'feat/T1-one--02' "$TEAM_HOME/tasks/T1/brief-build-01.md"
  assert_equal "$output" "0"
}

@test "--ticket leases a treehouse slot held as T<n>--NN" {
  open_task conv
  run_bin -0 --separate-stderr team-open --task T1 --ticket 01
  local ticket_wt=${conv_slots[1]}
  assert_equal "$(jq -r '"\(.branch) \(.worktree) \(.base_sha) \(.ticket)"' <<<"$output")" \
    "feat/T1-one--01 $ticket_wt $tip 01"
  assert_equal "$(stub_calls th-lease.sh | jq -c .args)" "$(printf '%s\n' '["T1"]' '["T1--01"]')"
  assert_equal "$(pool_leases | awk '{ print $2 }' | sort | paste -sd " ")" "T1 T1--01"
  assert_equal "$(git -C "$ticket_wt" rev-parse --abbrev-ref HEAD)" "feat/T1-one--01"
  assert_equal "$(git -C "$ticket_wt" rev-parse HEAD)" "$tip"
  assert_equal "$(cat "$ticket_wt/.scratch/task/build-notes/01.md")" "note one"
  assert_equal "$(events worktree-added | jq -r '"\(.ticket) \(.worktree)"')" "01 $ticket_wt"
}

@test "a second --ticket for the same ticket prints its open worktree and says so, exit 0" {
  open_task home
  run_bin -0 --separate-stderr team-open --task T1 --ticket 02
  local first=$output
  # The task branch moves on; the open ticket worktree is the one there is.
  git -C "$wt" commit -q --allow-empty -m "feat: more"
  run_bin -0 --separate-stderr team-open --task T1 --ticket 02
  assert_equal "$(jq -c . <<<"$output")" "$(jq -c . <<<"$first")"
  assert_equal "$stderr" "team-open: T1's ticket 02 already has its worktree ${home_slots[1]}"
  assert_equal "$(events worktree-added | wc -l)" "1"
  [[ ! -e ${home_slots[2]} ]]
}

@test "an existing ticket branch the task branch holds is moved to its tip; one with other commits is refused" {
  open_task home
  git -C "$home" branch feat/T1-one--02 origin/main
  run_bin -0 --separate-stderr team-open --task T1 --ticket 02
  assert_equal "$stderr" "team-open: moved feat/T1-one--02 from $(git -C "$home" rev-parse origin/main | cut -c 1-8) to the task branch's tip ${tip:0:8}"
  assert_equal "$(git -C "${home_slots[1]}" rev-parse HEAD)" "$tip"
  assert_equal "$(jq -r .base_sha <<<"$output")" "$tip"

  # Ticket 01's branch was left with a commit of its own.
  git -C "$home" branch feat/T1-one--01 "$tip"
  local other=$BATS_TEST_TMPDIR/other
  git -C "$home" worktree add -q "$other" feat/T1-one--01
  git -C "$other" commit -q --allow-empty -m "feat: lost work"
  local head
  head=$(git -C "$other" rev-parse HEAD)
  git -C "$home" worktree remove "$other"
  run_bin -1 --separate-stderr team-open --task T1 --ticket 01
  assert_equal "$stderr" "team-open: the branch feat/T1-one--01 exists at ${head:0:8} with commits the task branch lacks; integrate or remove it first"
  assert_equal "$(git -C "$home" rev-parse feat/T1-one--01)" "$head"
  [[ ! -e ${home_slots[2]} ]]
  assert_equal "$(events worktree-added | jq -r .ticket)" "02"
}

@test "--ticket refuses a task that is not open, a ticket the task lacks and a malformed command line" {
  run_bin -2 team-open --ticket 01
  assert_contains "$output" "--ticket needs --task T<n>"
  run_bin -2 team-open --task T1 --ticket 1
  assert_contains "$output" "ticket must be a two-digit number like 03, got '1'"
  run_bin -2 team-open --task T1 --ticket 01 home
  assert_contains "$output" "usage: team-open --task T<n> --ticket <NN>"
  run_bin -2 team-open --task T1 --ticket 01 --add home feat two
  assert_contains "$output" "--ticket goes only with --task, not with --add, --resume or --story"
  run_bin -2 team-open --task T1 --ticket 01 --resume home
  assert_contains "$output" "--ticket goes only with --task, not with --add, --resume or --story"

  run_bin -1 team-open --task T7 --ticket 01
  assert_contains "$output" "T7 is not open: the ledger has no opened event for it"

  open_task home
  run_bin -1 --separate-stderr team-open --task T1 --ticket 05
  assert_equal "$stderr" "team-open: T1 has no ticket 05; its tickets: 01, 02"
  ledger_line '{ts: (now | todate), task: "T1", event: "closed", archive: [], returned: [], kept: []}'
  run_bin -1 team-open --task T1 --ticket 01
  assert_contains "$output" "T1 is closed"
  assert_equal "$(events worktree-added)" ""
  [[ ! -e ${home_slots[1]} ]]
}

@test "--ticket refuses a task whose tickets team-tickets refuses, with its problems" {
  open_task home
  printf '# 03: c\n\nBlocked by: 09\n' >"$wt/.scratch/task/tickets/03-c.md"
  run_bin -1 --separate-stderr team-open --task T1 --ticket 01
  assert_contains "$stderr" "03-c.md:3: blocker 09 is no ticket of T1"
  assert_equal "$(events worktree-added)" ""
}

@test "--ticket on a full git pool exits 75 naming the holders, the ticket branch made nowhere" {
  open_task home
  run_bin -0 --separate-stderr team-open --task T1 --ticket 01
  git -C "$home" worktree add -q --detach "${home_slots[2]}" origin/main
  run_bin -75 --separate-stderr team-open --task T1 --ticket 02
  assert_equal "$output" ""
  assert_equal "$stderr" "$(printf '%s\n' "team-open: every slot of home is taken:" \
    "  ${home_slots[0]}: T1 (feat/T1-one)" "  ${home_slots[1]}: T1 (feat/T1-one--01)" \
    "  ${home_slots[2]}: no task (detached HEAD)")"
  run git -C "$home" branch --list 'feat/T1-one--02'
  assert_equal "$output" ""
}

@test "after a failure once the slot holds the ticket branch, re-running --ticket finishes in that slot" {
  [[ $EUID -ne 0 ]] || skip "root ignores the lock file's permissions"
  open_task home
  chmod 000 "$TEAM_HOME/ledger.jsonl.lock"
  run_bin -1 --separate-stderr team-open --task T1 --ticket 02
  assert_contains "$stderr" "T1's ticket 02 is half open in ${home_slots[1]}; finish it with: team-open --task T1 --ticket 02"
  chmod 644 "$TEAM_HOME/ledger.jsonl.lock"
  # The task branch moved on meanwhile: the base the slot was cut from is what is logged.
  git -C "$wt" commit -q --allow-empty -m "feat: more"

  run_bin -0 --separate-stderr team-open --task T1 --ticket 02
  assert_equal "$(jq -r '"\(.worktree) \(.base_sha)"' <<<"$output")" "${home_slots[1]} $tip"
  [[ ! -e ${home_slots[2]} ]]
  assert_equal "$(events worktree-added | jq -r '"\(.ticket) \(.worktree)"')" "02 ${home_slots[1]}"
  [[ -f ${home_slots[1]}/.scratch/task/spec.md ]]
}
