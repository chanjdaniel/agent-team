#!/usr/bin/env bats
# team-open --resume: this machine's worktree for an open task's open worktree in a project, across
# a git-pool project (home) and a treehouse-pool project (conv, through the fake commands of
# helpers/treehouse). This machine is laptop; a task "opened elsewhere" was recorded by a machine
# whose home is /home/someone.

load helpers/common
load helpers/treehouse

setup() {
  sandbox
  home=$(make_repo home)
  conv=$(make_repo conv)
  ignore_scratch "$home"
  ignore_scratch "$conv"
  home_slots=("$HOME/slots/home/1" "$HOME/slots/home/2")
  conv_slots=("$HOME/.treehouse/conv-abc123/1/conv" "$HOME/.treehouse/conv-abc123/2/conv")
  local slot
  for slot in "${conv_slots[@]}"; do git -C "$conv" worktree add -q --detach "$slot" origin/main; done
  printf '%s\n' "${conv_slots[@]}" >"$BATS_TEST_TMPDIR/free"
  fake_pool_commands "$conv"
  mkdir -p "$HOME/.config/agent-team"
  echo laptop >"$HOME/.config/agent-team/machine"
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
slots = ["slots/home/1", "slots/home/2"]

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
  team_origin=$(make_team_home laptop)
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

# Commit a new file <name> in the worktree <wt>; prints the new head.
work() {
  echo "$2" >"$1/$2"
  git -C "$1" add "$2"
  git -C "$1" commit -q -m "feat: $2"
  git -C "$1" rev-parse HEAD
}

# Push the worktree <wt>'s branch to origin.
push() {
  git -C "$1" push -q origin "HEAD:refs/heads/$(git -C "$1" rev-parse --abbrev-ref HEAD)"
}

# Run the salvage command team-open printed in $output, then check that it kept <commit> on the
# team home's origin as salvage/<project>/T1-laptop and put no salvage/ branch on any project's
# origin: salvaged <project> <commit>
salvaged() {
  local command
  command=$(sed -n 's/.*save them with: \(.*\), then make .*/\1/p' <<<"$output")
  [[ -n $command ]]
  eval "$command" 2>/dev/null
  assert_equal "$(git -C "$team_origin" rev-parse "refs/heads/salvage/$1/T1-laptop")" "$2"
  assert_equal "$(git -C "$BATS_TEST_TMPDIR/origin/home.git" for-each-ref refs/heads/salvage/)" ""
  assert_equal "$(git -C "$BATS_TEST_TMPDIR/origin/conv.git" for-each-ref refs/heads/salvage/)" ""
}

# Archive a task directory for T<n> in the team home's <folder> (scratch or scratch-<project>), as
# a checkpoint or a handoff left it: a spec and a ticket.
archive() {
  mkdir -p "$TEAM_HOME/tasks/$1/$2/tickets"
  echo "spec of $1" >"$TEAM_HOME/tasks/$1/$2/spec.md"
  echo "ticket 01" >"$TEAM_HOME/tasks/$1/$2/tickets/01.md"
}

# Forget the worktree <wt> of <primary> on <branch> here, as if it had only ever been on another
# machine: a git slot is removed, a treehouse slot is returned to its pool with its task directory
# gone; the branch and its remote-tracking ref are deleted.
forget_here() {
  local primary=$1 branch=$2 wt=$3
  if [[ $primary == "$conv" ]]; then
    rm -rf "$wt/.scratch"
    (cd "$conv" && scripts/th-return.sh "$wt") >/dev/null
  else
    git -C "$primary" worktree remove --force "$wt"
  fi
  git -C "$primary" branch -q -D "$branch"
  git -C "$primary" update-ref -d "refs/remotes/origin/$branch"
}

# The ledger as the machine with home /home/someone wrote it: recorded worktrees under this HOME
# are under /home/someone instead.
rehome_ledger() {
  jq -c --arg home "$HOME" \
    'if (.worktree // "" | startswith("\($home)/")) then .worktree |= "/home/someone" + .[($home | length):] else . end' \
    "$TEAM_HOME/ledger.jsonl" >"$BATS_TEST_TMPDIR/ledger"
  cp "$BATS_TEST_TMPDIR/ledger" "$TEAM_HOME/ledger.jsonl"
}

# open_elsewhere <project> <type> <slug>: T1 opened in <project> on the other machine, which
# committed one change, pushed the branch, archived the task directory (archive) and handed off;
# nothing of it is on this machine. Sets wt (the recorded slot, as a path here), branch and head.
open_elsewhere() {
  run_bin -0 --separate-stderr team-open "$1" feature "$2" "$3" "Work in $1"
  wt=$(jq -r .worktree <<<"$output") branch=$(jq -r .branch <<<"$output")
  head=$(work "$wt" feature.txt)
  push "$wt"
  archive T1 scratch
  forget_here "${!1}" "$branch" "$wt"
  rehome_ledger
}

# The facts --resume prints for T1's worktree <wt> of <project> on <branch> at <head>, recorded
# at <from>, restored from <archive> (a JSON string or null), with no snapshot (a task that did
# not crash).
facts() {
  jq -cn --arg project "$1" --arg branch "$2" --arg wt "$3" --arg head "$4" --arg from "$5" \
    --argjson archive "$6" '{task: "T1", project: $project, branch: $branch, worktree: $wt,
      task_dir: "\($wt)/.scratch/task", head: $head, from: $from, moved: ($wt != $from), archive: $archive,
      snapshot: null}'
}

# launch <role> <worktree>: T1's worker launched on home-pc, as team-worker logs it.
launch() {
  jq -cn --arg role "$1" --arg wt "$2" '{ts: (now | todate), task: "T1", event: "launch", role: $role,
    session: "81f08540", worktree: $wt, toolkits: [], machine: "home-pc"}' >>"$TEAM_HOME/ledger.jsonl"
}

# checkpoint_of <wt>: home-pc's checkpoint of the worktree <wt> of T1, as team-checkpoint makes
# it: feature.txt edited, new.txt added and README.md deleted, uncommitted, pushed as wip/home/T1
# to the team home's origin with the worktree's HEAD as parent. Sets wip; the worktree keeps the changes.
checkpoint_of() {
  local wt=$1 index=$BATS_TEST_TMPDIR/wip-index tree
  echo "edited" >"$wt/feature.txt"
  echo "new" >"$wt/new.txt"
  rm "$wt/README.md"
  rm -f "$index"
  GIT_INDEX_FILE=$index git -C "$wt" read-tree HEAD
  GIT_INDEX_FILE=$index git -C "$wt" add -A
  tree=$(GIT_INDEX_FILE=$index git -C "$wt" write-tree)
  wip=$(git -C "$wt" commit-tree "$tree" -p HEAD -m "wip: T1 checkpoint on home-pc at 2026-10-23T10:00:00Z")
  git -C "$wt" push -q "$team_origin" "+$wip:refs/heads/wip/home/T1"
}

# crash_elsewhere: T1 opened in home on home-pc, with a pushed commit, a builder launched and a
# checkpoint (checkpoint_of) pushed, archived; then home-pc died, without a handoff, and nothing
# of it is on this machine. Sets wt, branch, head and wip.
crash_elsewhere() {
  run_bin -0 --separate-stderr team-open home feature feat work "Work in home"
  wt=$(jq -r .worktree <<<"$output") branch=$(jq -r .branch <<<"$output")
  head=$(work "$wt" feature.txt)
  push "$wt"
  launch builder "$wt"
  checkpoint_of "$wt"
  archive T1 scratch
  forget_here "$home" "$branch" "$wt"
  rehome_ledger
}

# The snapshot facts of wip/home/T1 <wip> on <parent>, applied (true or false) for <reason> (a JSON
# string or null).
snapshot_facts() {
  jq -cn --arg commit "$1" --arg parent "$2" --argjson applied "$3" --argjson reason "$4" \
    --arg at "$(git -C "$home" show -s --format=%ct "$1" | jq -r 'tonumber | todate')" \
    '{ref: "wip/home/T1", commit: $commit, parent: $parent, at: $at, applied: $applied, reason: $reason}'
}

# Fail unless the task directory <dir> holds exactly the archive <folder> of T1.
restored_from() {
  diff -r "$TEAM_HOME/tasks/T1/$2" "$1"
}

@test "on a second machine, the recorded slot is free: it is added on the branch at origin's head" {
  open_elsewhere home feat work
  [[ ! -e $wt ]]
  run -1 git -C "$home" show-ref -q --verify "refs/heads/$branch"
  cp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/before"

  run_bin -0 --separate-stderr team-open --task T1 --resume home
  assert_equal "$stderr" ""
  assert_equal "$(jq -c . <<<"$output")" "$(facts home "$branch" "$wt" "$head" "$wt" '"tasks/T1/scratch"')"
  assert_equal "$(git -C "$wt" rev-parse --abbrev-ref HEAD)" "$branch"
  assert_equal "$(git -C "$wt" rev-parse HEAD)" "$head"
  run -128 git -C "$wt" rev-parse --abbrev-ref '@{upstream}'
  assert_equal "$(git -C "$wt" status --porcelain)" ""
  restored_from "$wt/.scratch/task" scratch
  cmp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/before"
}

@test "the recorded slot is taken by another task here: the next free slot, and worktree-moved" {
  open_elsewhere home feat work
  run_bin -0 team-open --task T2 home feature feat other "Other work"
  assert_equal "$(git -C "${home_slots[0]}" rev-parse --abbrev-ref HEAD)" "feat/T2-other"
  local moved=${home_slots[1]}

  run_bin -0 --separate-stderr team-open --task T1 --resume home
  assert_equal "$(jq -c . <<<"$output")" "$(facts home "$branch" "$moved" "$head" "$wt" '"tasks/T1/scratch"')"
  assert_equal "$(git -C "$moved" rev-parse --abbrev-ref HEAD)" "$branch"
  assert_equal "$(git -C "$moved" rev-parse HEAD)" "$head"
  assert_equal "$(git -C "$wt" rev-parse --abbrev-ref HEAD)" "feat/T2-other"
  restored_from "$moved/.scratch/task" scratch
  assert_equal "$(events worktree-moved | jq -c 'del(.ts)')" "$(jq -cn --arg b "$branch" --arg from "$wt" --arg wt "$moved" \
    '{task: "T1", event: "worktree-moved", project: "home", branch: $b, from: $from, worktree: $wt, machine: "laptop"}')"
  run_bin -0 team-log --check

  # The task's open worktree is the new one, for team-state and for team-open's own checks.
  stub_reply claude "[]"
  run_bin -0 team-state T1 --json
  assert_equal "$(jq -c '.worktrees' <<<"$output")" "$(jq -cn --arg b "$branch" --arg wt "$moved" \
    '[{project: "home", branch: $b, worktree: $wt, returned: false}]')"
  run_bin -1 team-open --task T1 --add home feat more
  assert_contains "$output" "T1 already has an open worktree in home: $moved ($branch)"

  # A second run finds the task's worktree where the first put it: nothing moves again.
  run_bin -0 --separate-stderr team-open --task T1 --resume home
  assert_equal "$(jq -c . <<<"$output")" "$(facts home "$branch" "$moved" "$head" "$moved" '"tasks/T1/scratch"')"
  assert_equal "$(events worktree-moved | wc -l)" "1"
}

@test "a treehouse pool leases another slot, switched to the branch, and logs worktree-moved" {
  open_elsewhere conv feat work
  # The other machine's slot is free here, but the lease hands out the other one first.
  assert_equal "$(cat "$BATS_TEST_TMPDIR/free")" "$(printf '%s\n' "${conv_slots[1]}" "${conv_slots[0]}")"
  local moved=${conv_slots[1]}
  : >"$STUB_CALLS/th-lease.sh.log"

  run_bin -0 --separate-stderr team-open --task T1 --resume conv
  assert_equal "$stderr" ""
  assert_equal "$(jq -c . <<<"$output")" "$(facts conv "$branch" "$moved" "$head" "$wt" '"tasks/T1/scratch"')"
  assert_equal "$(stub_calls th-lease.sh)" "$(jq -cn --arg cwd "$conv" '{cwd: $cwd, args: ["T1"]}')"
  assert_equal "$(git -C "$moved" rev-parse --abbrev-ref HEAD)" "$branch"
  assert_equal "$(git -C "$moved" rev-parse HEAD)" "$head"
  run -128 git -C "$moved" rev-parse --abbrev-ref '@{upstream}'
  restored_from "$moved/.scratch/task" scratch
  assert_equal "$(events worktree-moved | jq -r '"\(.from) \(.worktree) \(.machine)"')" "$wt $moved laptop"
  run_bin -0 team-log --check
}

@test "a crashed task gets its checkpoint's uncommitted changes applied on origin's head, once" {
  crash_elsewhere
  cp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/before"

  run_bin -0 --separate-stderr team-open --task T1 --resume home
  assert_equal "$stderr" "team-open: applied wip/home/T1 ${wip:0:7} (the checkpoint of $(jq -r .snapshot.at <<<"$output")) to $wt as uncommitted changes"
  assert_equal "$(jq -c .snapshot <<<"$output")" "$(snapshot_facts "$wip" "$head" true null)"
  assert_equal "$(jq -c 'del(.snapshot)' <<<"$output")" \
    "$(facts home "$branch" "$wt" "$head" "$wt" '"tasks/T1/scratch"' | jq -c 'del(.snapshot)')"
  # On the branch at origin's head, the checkpoint's changes uncommitted: nothing staged, the new
  # file untracked, and the task directory the archive's.
  assert_equal "$(git -C "$wt" rev-parse HEAD)" "$head"
  assert_equal "$(git -C "$wt" status --porcelain)" "$(printf '%s\n' " D README.md" " M feature.txt" "?? new.txt")"
  assert_equal "$(cat "$wt/feature.txt")" "edited"
  assert_equal "$(cat "$wt/new.txt")" "new"
  assert_equal "$(git -C "$wt" diff --cached --name-only)" ""
  restored_from "$wt/.scratch/task" scratch
  # The snapshot stays readable here, as team-home/wip/home/T1, and nothing counts it as on origin.
  assert_equal "$(git -C "$home" rev-parse team-home/wip/home/T1)" "$wip"
  assert_equal "$(git -C "$home" for-each-ref --contains "$wip" refs/remotes/origin)" ""
  assert_equal "$(git -C "$BATS_TEST_TMPDIR/origin/home.git" for-each-ref refs/heads/wip/)" ""
  cmp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/before"

  # A second run finds it applied and changes nothing.
  run_bin -0 --separate-stderr team-open --task T1 --resume home
  assert_equal "$stderr" "team-open: wip/home/T1 ${wip:0:7} (the checkpoint of $(jq -r .snapshot.at <<<"$output")) is already applied in $wt"
  assert_equal "$(jq -c .snapshot <<<"$output")" "$(snapshot_facts "$wip" "$head" true null)"
  assert_equal "$(git -C "$wt" status --porcelain)" "$(printf '%s\n' " D README.md" " M feature.txt" "?? new.txt")"

  # Other uncommitted changes in the worktree are never mixed with it.
  echo "mine" >"$wt/mine.txt"
  run_bin -0 --separate-stderr team-open --task T1 --resume home
  local reason="$wt has uncommitted changes other than the snapshot's, so it is not applied over them"
  assert_equal "$stderr" "team-open: wip/home/T1 ${wip:0:7} not applied: $reason"
  assert_equal "$(jq -c .snapshot <<<"$output")" "$(snapshot_facts "$wip" "$head" false "$(jq -n --arg r "$reason" '$r')")"
  assert_equal "$(git -C "$wt" status --porcelain | wc -l)" 4
}

@test "a crashed task's snapshot is not applied when origin's branch has moved past its parent" {
  crash_elsewhere
  # After the checkpoint, the branch was pushed on: the snapshot's parent is behind origin's head.
  local other=$BATS_TEST_TMPDIR/other later
  git clone -q -b "$branch" "$BATS_TEST_TMPDIR/origin/home.git" "$other" 2>/dev/null
  later=$(work "$other" later.txt)
  push "$other"

  run_bin -0 --separate-stderr team-open --task T1 --resume home
  local reason="origin's $branch is at ${later:0:7}, past the snapshot's parent ${head:0:7}"
  assert_equal "$stderr" "team-open: wip/home/T1 ${wip:0:7} not applied: $reason"
  assert_equal "$(jq -c .snapshot <<<"$output")" "$(snapshot_facts "$wip" "$head" false "$(jq -n --arg r "$reason" '$r')")"
  assert_equal "$(git -C "$wt" rev-parse HEAD)" "$later"
  assert_equal "$(git -C "$wt" status --porcelain)" ""

  # A parent origin's branch never had (commits lost with the machine) is said too.
  git -C "$other" reset -q --hard "$head~1"
  work "$other" elsewhere.txt >/dev/null
  git -C "$other" push -q -f origin "HEAD:refs/heads/$branch"
  git -C "$home" fetch -q origin "$branch"
  git -C "$wt" reset -q --hard "$(git -C "$other" rev-parse HEAD)"
  run_bin -0 --separate-stderr team-open --task T1 --resume home
  assert_equal "$(jq -r .snapshot.reason <<<"$output")" \
    "the snapshot's parent ${head:0:7} is not on origin's $branch, which is at $(git -C "$other" rev-parse --short=7 HEAD)"
  assert_equal "$(jq -r .snapshot.applied <<<"$output")" false
}

@test "a task stowed after its last launch did not crash: its snapshot is left alone" {
  crash_elsewhere
  # home-pc handed off: its stowed came after the launch.
  jq -cn --arg b "$branch" --arg h "$head" '{ts: (now | todate), task: "T1", event: "stowed", machine: "home-pc",
    worktrees: [{project: "home", branch: $b, head: $h}], roles: ["builder"]}' >>"$TEAM_HOME/ledger.jsonl"

  run_bin -0 --separate-stderr team-open --task T1 --resume home
  assert_equal "$stderr" ""
  assert_equal "$(jq -c . <<<"$output")" "$(facts home "$branch" "$wt" "$head" "$wt" '"tasks/T1/scratch"')"
  assert_equal "$(git -C "$wt" status --porcelain)" ""
  run -1 git -C "$home" rev-parse -q --verify refs/remotes/team-home/wip/home/T1

  # A launch after that stowed, with no handoff since, is a crash again.
  launch reviewer "$wt"
  run_bin -0 --separate-stderr team-open --task T1 --resume home
  assert_equal "$(jq -r .snapshot.applied <<<"$output")" true
}

@test "a task stowed with uncommitted changes in its worktree gets the handoff's snapshot applied, as after a crash" {
  crash_elsewhere
  # home-pc handed off a builder that never stowed: its stowed records the uncommitted changes the
  # handoff's checkpoint kept, and only for that project.
  jq -cn --arg b "$branch" --arg h "$head" '{ts: (now | todate), task: "T1", event: "stowed", machine: "home-pc",
    worktrees: [{project: "home", branch: $b, head: $h, uncommitted: true}], roles: ["builder"]}' >>"$TEAM_HOME/ledger.jsonl"

  run_bin -0 --separate-stderr team-open --task T1 --resume home
  assert_equal "$stderr" "team-open: applied wip/home/T1 ${wip:0:7} (the checkpoint of $(jq -r .snapshot.at <<<"$output")) to $wt as uncommitted changes"
  assert_equal "$(jq -c .snapshot <<<"$output")" "$(snapshot_facts "$wip" "$head" true null)"
  assert_equal "$(git -C "$wt" rev-parse HEAD)" "$head"
  assert_equal "$(git -C "$wt" status --porcelain)" "$(printf '%s\n' " D README.md" " M feature.txt" "?? new.txt")"

  # A stowed whose worktree in home was clean leaves wip/home/T1 alone.
  git -C "$wt" reset -q --hard && git -C "$wt" clean -qfd
  jq -cn --arg b "$branch" --arg h "$head" '{ts: (now | todate), task: "T1", event: "stowed", machine: "home-pc",
    worktrees: [{project: "home", branch: $b, head: $h}], roles: ["builder"]}' >>"$TEAM_HOME/ledger.jsonl"
  run_bin -0 --separate-stderr team-open --task T1 --resume home
  assert_equal "$stderr" ""
  assert_equal "$(jq -c .snapshot <<<"$output")" null
  assert_equal "$(git -C "$wt" status --porcelain)" ""
}

@test "a crashed task with no snapshot on the team home's origin says so" {
  crash_elsewhere
  git -C "$team_origin" update-ref -d refs/heads/wip/home/T1

  run_bin -0 --separate-stderr team-open --task T1 --resume home
  local reason="the team home's origin has no wip/home/T1: no checkpoint saved this task's work"
  assert_equal "$stderr" "team-open: wip/home/T1 not applied: $reason"
  assert_equal "$(jq -c .snapshot <<<"$output")" \
    "$(jq -cn --arg r "$reason" '{ref: "wip/home/T1", commit: null, parent: null, at: null, applied: false, reason: $r}')"
  assert_equal "$(git -C "$wt" status --porcelain)" ""
}

@test "a crashed task whose branch was never pushed is made from wip/home/T1: its commits, and its snapshot uncommitted" {
  crash_elsewhere
  # home-pc committed more without pushing, then checkpointed: the snapshot's parent is a head
  # origin's branch lacks. Then the branch never reached origin at all.
  git -C "$home" push -q origin --delete "$branch"
  local mine
  git -C "$home" worktree add -q "$wt" "$wip^"
  mine=$(work "$wt" mine.txt)
  checkpoint_of "$wt"
  git -C "$home" worktree remove --force "$wt"

  run_bin -0 --separate-stderr team-open --task T1 --resume home
  assert_contains "$stderr" "team-open: $branch is not on origin; it is taken from wip/home/T1, at ${mine:0:7}"
  assert_contains "$stderr" "team-open: applied wip/home/T1 ${wip:0:7}"
  assert_equal "$(jq -c .snapshot <<<"$output")" "$(snapshot_facts "$wip" "$mine" true null)"
  assert_equal "$(git -C "$wt" rev-parse HEAD)" "$mine"
  assert_equal "$(git -C "$wt" rev-parse --abbrev-ref HEAD)" "$branch"
  assert_equal "$(git -C "$wt" status --porcelain)" "$(printf '%s\n' " D README.md" " M feature.txt" "?? new.txt")"

  # A re-run finds the branch here, at wip/home/T1's head: nothing to salvage, nothing applied twice.
  run_bin -0 --separate-stderr team-open --task T1 --resume home
  assert_contains "$stderr" "is already applied in $wt"
  assert_equal "$(git -C "$wt" rev-parse HEAD)" "$mine"
}

@test "a clean checkpoint's wip/home/T1 is the branch head: a branch origin lacks or is behind is taken from it" {
  crash_elsewhere
  # home-pc committed the checkpoint's changes, and a clean checkpoint pushed that head as
  # wip/home/T1.
  local committed
  git -C "$home" worktree add -q "$wt" "$head"
  echo "edited" >"$wt/feature.txt"
  git -C "$wt" commit -q -am "feat: edited"
  committed=$(git -C "$wt" rev-parse HEAD)
  git -C "$wt" push -q "$team_origin" "+$committed:refs/heads/wip/home/T1"
  git -C "$home" worktree remove --force "$wt"

  run_bin -0 --separate-stderr team-open --task T1 --resume home
  assert_contains "$stderr" "team-open: wip/home/T1 has commits origin's $branch lacks; $branch is taken from it, at ${committed:0:7}"
  assert_contains "$stderr" "team-open: wip/home/T1 ${committed:0:7} not applied: the checkpoint saw no uncommitted changes"
  assert_equal "$(jq -c '.snapshot | {commit, parent, applied}' <<<"$output")" \
    "$(jq -cn --arg c "$committed" '{commit: $c, parent: null, applied: false}')"
  assert_equal "$(git -C "$wt" rev-parse HEAD)" "$committed"
  assert_equal "$(git -C "$wt" status --porcelain)" ""
  assert_equal "$(jq -r .head <<<"$output")" "$committed"
}

@test "a leased treehouse slot that is not clean is handed back and refused" {
  open_elsewhere conv feat work
  echo "left over" >"${conv_slots[1]}/stray.txt"
  cp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/before"

  run_bin -1 team-open --task T1 --resume conv
  assert_contains "$output" "the leased slot ${conv_slots[1]} is not clean: untracked files: stray.txt"
  assert_equal "$(stub_calls th-return.sh | tail -n 1 | jq -r '.args[0]')" "${conv_slots[1]}"
  run -1 git -C "${conv_slots[1]}" symbolic-ref -q HEAD
  cmp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/before"
}

@test "a slot here holding a stale copy behind origin is reused and fast-forwarded, its task directory replaced" {
  run_bin -0 team-open home feature feat work "Work in home"
  local slot=${home_slots[0]} br=feat/T1-work
  work "$slot" one.txt >/dev/null
  push "$slot"
  echo "stale" >"$slot/.scratch/task/stale.md"
  # The other machine carried on from origin's branch and handed off.
  local other=$BATS_TEST_TMPDIR/other theirs
  git clone -q -b "$br" "$BATS_TEST_TMPDIR/origin/home.git" "$other" 2>/dev/null
  theirs=$(work "$other" two.txt)
  push "$other"
  archive T1 scratch
  cp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/before"

  run_bin -0 --separate-stderr team-open --task T1 --resume home
  assert_equal "$(jq -c . <<<"$output")" "$(facts home "$br" "$slot" "$theirs" "$slot" '"tasks/T1/scratch"')"
  assert_equal "$(git -C "$slot" rev-parse HEAD)" "$theirs"
  assert_equal "$(git -C "$slot" status --porcelain)" ""
  [[ ! -e $slot/.scratch/task/stale.md ]]
  restored_from "$slot/.scratch/task" scratch
  cmp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/before"
}

@test "a slot whose branch has commits origin lacks is refused with the salvage command" {
  run_bin -0 team-open home feature feat work "Work in home"
  local slot=${home_slots[0]} br=feat/T1-work
  work "$slot" one.txt >/dev/null
  push "$slot"
  local mine
  mine=$(work "$slot" mine.txt)
  echo "mine" >"$slot/.scratch/task/notes.md"
  archive T1 scratch
  cp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/before"

  run_bin -1 team-open --task T1 --resume home
  assert_contains "$output" "$br here has commits that origin's $br lacks"
  assert_contains "$output" "save them with: git -C $slot push $team_origin HEAD:refs/heads/salvage/home/T1-laptop, then"
  assert_equal "$(git -C "$slot" rev-parse HEAD)" "$mine"
  assert_equal "$(cat "$slot/.scratch/task/notes.md")" "mine"
  cmp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/before"

  # Diverged from origin is refused the same way.
  local other=$BATS_TEST_TMPDIR/other
  git clone -q -b "$br" "$BATS_TEST_TMPDIR/origin/home.git" "$other" 2>/dev/null
  work "$other" theirs.txt >/dev/null
  push "$other"
  run_bin -1 team-open --task T1 --resume home
  assert_contains "$output" "save them with: git -C $slot push $team_origin HEAD:refs/heads/salvage/home/T1-laptop, then"
  assert_equal "$(git -C "$slot" rev-parse HEAD)" "$mine"
  salvaged home "$mine"
}

@test "a local branch no slot holds, with commits origin lacks, is refused with the salvage command" {
  open_elsewhere home feat work
  git -C "$home" update-ref "refs/heads/$branch" "$(git -C "$home" commit-tree -p "$head" -m "feat: mine" "$head^{tree}")"

  run_bin -1 team-open --task T1 --resume home
  assert_contains "$output" "save them with: git -C $home push $team_origin refs/heads/$branch:refs/heads/salvage/home/T1-laptop, then"
  [[ ! -e $wt ]]
  salvaged home "$(git -C "$home" rev-parse "refs/heads/$branch")"
}

@test "a stale slot with uncommitted changes is refused rather than fast-forwarded under them" {
  run_bin -0 team-open home feature feat work "Work in home"
  local slot=${home_slots[0]} br=feat/T1-work
  local mine
  mine=$(work "$slot" one.txt)
  push "$slot"
  echo "edited" >"$slot/one.txt"
  local other=$BATS_TEST_TMPDIR/other
  git clone -q -b "$br" "$BATS_TEST_TMPDIR/origin/home.git" "$other" 2>/dev/null
  work "$other" two.txt >/dev/null
  push "$other"

  run_bin -1 team-open --task T1 --resume home
  assert_contains "$output" "$slot has uncommitted changes (changes to tracked files: one.txt)"
  assert_equal "$(git -C "$slot" rev-parse HEAD)" "$mine"
  assert_equal "$(cat "$slot/one.txt")" "edited"
}

@test "with no archive the task directory is left as it is, and said so" {
  run_bin -0 team-open home feature feat work "Work in home"
  local slot=${home_slots[0]}
  echo "notes" >"$slot/.scratch/task/notes.md"

  run_bin -0 --separate-stderr team-open --task T1 --resume home
  assert_equal "$(jq -c .archive <<<"$output")" "null"
  assert_equal "$stderr" "team-open: T1 has no archive at tasks/T1/scratch; $slot/.scratch/task is left as it is"
  assert_equal "$(cat "$slot/.scratch/task/notes.md")" "notes"
}

@test "what the archive leaves out of the task directory stays in the worktree when the archive replaces it" {
  run_bin -0 team-open home feature feat work "Work in home"
  local dir=${home_slots[0]}/.scratch/task
  echo "stale" >"$dir/stale.md"
  git init -q "$dir/clone"
  echo "tool" >"$dir/clone/tool.txt"
  head -c 2M /dev/zero >"$dir/big[1].bin"
  echo "SECRET=1" >"$dir/.env.local"
  archive T1 scratch

  run_bin -0 --separate-stderr team-open --task T1 --resume home
  assert_equal "$stderr" ""
  assert_equal "$(cd "$dir" && find . -mindepth 1 -not -path './clone/.git/*' | LC_ALL=C sort)" "./.env.local
./big[1].bin
./clone
./clone/.git
./clone/tool.txt
./spec.md
./tickets
./tickets/01.md"
}

@test "an added project's worktree is restored from its own archive" {
  run_bin -0 team-open conv feature feat work "Work in conv"
  run_bin -0 team-open --task T1 --add home feat home-side
  archive T1 scratch-home
  archive T1 scratch
  echo "conv only" >"$TEAM_HOME/tasks/T1/scratch/conv.md"

  run_bin -0 --separate-stderr team-open --task T1 --resume home
  assert_equal "$(jq -r .archive <<<"$output")" "tasks/T1/scratch-home"
  restored_from "${home_slots[0]}/.scratch/task" scratch-home
}

@test "a task that is not open, or has no open worktree in the project, is refused" {
  run_bin -1 team-open --task T9 --resume home
  assert_contains "$output" "T9 is not open"
  run_bin -0 team-open home feature feat work "Work in home"
  run_bin -1 team-open --task T1 --resume conv
  assert_contains "$output" "T1 has no open worktree in conv"
  printf '%s\n' '{"ts":"2026-10-23T00:00:00Z","task":"T1","event":"closed","archive":[],"returned":[],"kept":[]}' \
    >>"$TEAM_HOME/ledger.jsonl"
  run_bin -1 team-open --task T1 --resume home
  assert_contains "$output" "T1 is closed"
}

@test "a branch that is neither here nor on origin is refused" {
  run_bin -0 team-open home feature feat work "Work in home"
  local slot=${home_slots[0]}
  forget_here "$home" feat/T1-work "$slot"
  run_bin -1 team-open --task T1 --resume home
  assert_contains "$output" "feat/T1-work is neither on origin nor here"
  [[ ! -e $slot ]]
}

@test "--resume needs --task, exactly a project and a machine name" {
  run_bin -2 team-open --resume home
  assert_contains "$output" "--resume needs --task T<n>"
  run_bin -2 team-open --task T1 --resume home extra
  assert_contains "$output" "usage: team-open --task T<n> --resume <project>"
  run_bin -2 team-open --task T1 --resume --add home feat slug
  assert_contains "$output" "--add and --resume do not go together"
  run_bin -2 team-open --task T1 --resume nowhere
  assert_contains "$output" "unknown project 'nowhere'"
  rm "$HOME/.config/agent-team/machine"
  run_bin -0 team-open home feature feat work "Work in home"
  run_bin -1 team-open --task T1 --resume home
  assert_contains "$output" "echo <name> > ~/.config/agent-team/machine"
}

@test "--help documents the resume mode" {
  run_bin -0 team-open --help
  assert_contains "$output" "team-open --task T<n> --resume <project>"
  assert_contains "$output" "worktree-moved"
  assert_contains "$output" "wip/<project>/T<n>"
}
