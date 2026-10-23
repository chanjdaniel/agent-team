#!/usr/bin/env bats
# team-checkpoint: on the lease holder, each open task's task directories archived into the team
# home, each worktree's work (a snapshot of its uncommitted changes, or its head) pushed as
# wip/T<n> to its project's origin, and the records committed and pushed on the team home's dev.
# Two git-pool projects, home and site, on bare origins; home-pc holds the lease on the team
# home's bare origin.

load helpers/common

setup() {
  sandbox
  home=$(make_repo home)
  site=$(make_repo site)
  ignore_scratch "$home"
  ignore_scratch "$site"
  home_origin=$BATS_TEST_TMPDIR/origin/home.git site_origin=$BATS_TEST_TMPDIR/origin/site.git
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
slots = ["slots/home/1", "slots/home/2", "slots/home/3", "slots/home/4"]

[site]
repo = "owner/site"
path = "projects/site"
base = "main"
delivery = "direct-pr"
merge_method = "merge"
required_checks = []
task_dir = ".scratch/task"
docs = []
toolkits = []

[site.pool]
provider = "git"
slots = ["slots/site/1"]
TOML
  printf 'ledger.jsonl.lock\n' >"$TEAM_HOME/.gitignore"
  team_origin=$(hold_lease home-pc)
  stub_reply curl '{"id":"1563000000000000001"}'
  state=$HOME/.local/state/agent-team
}

# Commit and push a .gitignore with .scratch/ and .env in the primary checkout <path>.
ignore_scratch() {
  printf '.scratch/\n.env\n' >"$1/.gitignore"
  git -C "$1" add .gitignore
  git -C "$1" commit -q -m "chore: ignore scratch"
  git -C "$1" push -q origin main
}

# Every git push from here on is logged to $STUB_CALLS/git-push.log, one line per push.
log_pushes() {
  local real_git
  real_git=$(command -v git)
  cat >"$BATS_TEST_TMPDIR/stubs/git" <<EOF
#!/usr/bin/env bash
args=("\$@")
while [[ \${args[0]:-} == -* ]]; do
  case \${args[0]} in -C | -c) args=("\${args[@]:2}") ;; *) args=("\${args[@]:1}") ;; esac
done
[[ \${args[0]:-} != push ]] || echo "\$PWD \$*" >>"$STUB_CALLS/git-push.log"
exec "$real_git" "\$@"
EOF
  chmod +x "$BATS_TEST_TMPDIR/stubs/git"
}

# Everything a checkpoint must leave as it was in the worktree <wt>: its index's bytes, files,
# staged changes, index entries, stash, branch and head, all read without optional locks.
worktree_state() {
  local wt=$1
  sha256sum "$(git -C "$wt" rev-parse --path-format=absolute --git-path index)" | cut -d' ' -f1
  (cd "$wt" && find . -type f -not -path './.git/*' -print0 | sort -z | xargs -0 sha256sum)
  git --no-optional-locks -C "$wt" diff --cached
  git --no-optional-locks -C "$wt" ls-files -s
  git --no-optional-locks -C "$wt" stash list
  git --no-optional-locks -C "$wt" symbolic-ref HEAD
  git --no-optional-locks -C "$wt" rev-parse HEAD
}

# The commit at the tip of the team home's dev on its origin.
team_tip() {
  git -C "$team_origin" rev-parse dev
}

# The files the commit <rev> of the team home's origin changes, one per line.
changed_in() {
  git -C "$team_origin" diff-tree -r --no-commit-id --name-only "$1"
}

@test "one checkpoint archives the scratch, pushes the worktree's changes as wip/T1 and commits the records" {
  run_bin -0 team-open home feature feat work "Do the work"
  local wt=$HOME/slots/home/1 head before
  echo "stashed" >>"$wt/README.md"
  git -C "$wt" stash -q
  echo "spec" >"$wt/.scratch/task/spec.md"
  echo "edited" >>"$wt/README.md"
  echo "staged" >"$wt/staged.txt"
  git -C "$wt" add staged.txt
  echo "new" >"$wt/new.txt"
  echo "SECRET=1" >"$wt/.env"
  head=$(git -C "$wt" rev-parse HEAD)
  before=$(worktree_state "$wt")
  # The team home's own records guard runs on its commit.
  git -C "$TEAM_HOME" config core.hooksPath "$REPO_ROOT/bin/hooks/git"

  run_bin -0 --separate-stderr team-checkpoint
  local snap
  snap=$(git -C "$home_origin" rev-parse wip/T1)
  assert_equal "$output" "T1 home: archived .scratch/task to tasks/T1/scratch
T1 home: pushed wip/T1 ${snap:0:7} (uncommitted changes on ${head:0:7})
team home: committed $(git -C "$TEAM_HOME" rev-parse --short HEAD) chore: checkpoint and pushed dev"
  assert_equal "$stderr" ""

  # The worktree is untouched, its stash included.
  assert_equal "$(worktree_state "$wt")" "$before"
  assert_equal "$(git -C "$wt" stash list | wc -l)" 1

  assert_equal "$(cat "$TEAM_HOME/tasks/T1/scratch/spec.md")" "spec"

  # The snapshot: the tracked edit, the staged and the untracked file, on the worktree's head;
  # never ignored files or the task directory.
  assert_equal "$(git -C "$home_origin" rev-parse wip/T1^)" "$head"
  assert_equal "$(git -C "$home_origin" show wip/T1:README.md)" "home
edited"
  assert_equal "$(git -C "$home_origin" show wip/T1:staged.txt)" "staged"
  assert_equal "$(git -C "$home_origin" show wip/T1:new.txt)" "new"
  run -128 git -C "$home_origin" cat-file -e wip/T1:.env
  run -128 git -C "$home_origin" cat-file -e wip/T1:.scratch/task/spec.md
  [[ $(git -C "$home_origin" log -1 --format=%s wip/T1) =~ ^"wip: T1 checkpoint on home-pc at "[0-9T:-]+Z$ ]]
  # Only that one ref is new on origin.
  assert_equal "$(git -C "$home_origin" for-each-ref --format='%(refname)')" "refs/heads/main
refs/heads/wip/T1"

  # The team home: one commit of the records alone, pushed; the plan team-open wrote stays out.
  assert_equal "$(team_tip)" "$(git -C "$TEAM_HOME" rev-parse HEAD)"
  assert_equal "$(git -C "$team_origin" log -1 --format=%s dev)" "chore: checkpoint"
  assert_equal "$(changed_in dev)" "ledger.jsonl
tasks/T1/scratch/spec.md"
  assert_equal "$(git -C "$TEAM_HOME" status --porcelain)" "?? tasks/T1/plan.md"
  [[ -f $state/last-checkpoint ]]
}

@test "a second checkpoint with nothing new makes no commit and no push; a new change pushes a new snapshot" {
  run_bin -0 team-open home feature feat work "Do the work"
  local wt=$HOME/slots/home/1 tip snap
  echo "spec" >"$wt/.scratch/task/spec.md"
  echo "new" >"$wt/new.txt"
  run_bin -0 team-checkpoint
  tip=$(team_tip) snap=$(git -C "$home_origin" rev-parse wip/T1)

  log_pushes
  run_bin -0 team-checkpoint --force
  assert_equal "$output" "T1 home: archived .scratch/task to tasks/T1/scratch
T1 home: wip/T1 is up to date (${snap:0:7})
team home: nothing to commit"
  assert_equal "$(stub_calls git-push)" ""
  assert_equal "$(team_tip)" "$tip"
  assert_equal "$(git -C "$home_origin" rev-parse wip/T1)" "$snap"

  # A new change replaces the snapshot; no record changed, so no team-home commit.
  echo "more" >>"$wt/new.txt"
  run_bin -0 team-checkpoint --force
  assert_contains "$output" "T1 home: pushed wip/T1"
  assert_contains "$output" "team home: nothing to commit"
  [[ $(git -C "$home_origin" rev-parse wip/T1) != "$snap" ]]
  assert_equal "$(git -C "$home_origin" show wip/T1:new.txt)" "new
more"
  assert_equal "$(team_tip)" "$tip"
  assert_equal "$(wc -l <"$STUB_CALLS/git-push.log")" 1

  # Everything committed: the branch head itself replaces the snapshot, so the commit (never
  # pushed to the branch) is on origin, and no stale snapshot is left; then nothing new again.
  local head
  git -C "$wt" add new.txt
  git -C "$wt" commit -q -m "feat: new"
  head=$(git -C "$wt" rev-parse HEAD)
  run_bin -0 team-checkpoint --force
  assert_contains "$output" "T1 home: pushed wip/T1 ${head:0:7} (the branch head, no uncommitted changes)"
  assert_equal "$(git -C "$home_origin" rev-parse wip/T1)" "$head"
  run -1 git -C "$home_origin" rev-parse -q --verify refs/heads/feat/T1-work
  assert_equal "$(wc -l <"$STUB_CALLS/git-push.log")" 2
  run_bin -0 team-checkpoint --force
  assert_contains "$output" "T1 home: wip/T1 is up to date (${head:0:7}, no uncommitted changes)"
  assert_equal "$(wc -l <"$STUB_CALLS/git-push.log")" 2
}

@test "a snapshot whose head moved is pushed again, though its tree is the same" {
  run_bin -0 team-open home feature feat work "Do the work"
  local wt=$HOME/slots/home/1 snap
  echo "a" >"$wt/a.txt"
  echo "b" >"$wt/b.txt"
  run_bin -0 team-checkpoint
  snap=$(git -C "$home_origin" rev-parse wip/T1)
  git -C "$wt" add a.txt
  git -C "$wt" commit -q -m "feat: a"

  run_bin -0 team-checkpoint --force
  assert_contains "$output" "T1 home: pushed wip/T1"
  assert_equal "$(git -C "$home_origin" rev-parse 'wip/T1^{tree}')" "$(git -C "$home_origin" rev-parse "$snap^{tree}")"
  assert_equal "$(git -C "$home_origin" rev-parse wip/T1^)" "$(git -C "$wt" rev-parse HEAD)"
}

@test "a task with worktrees in two projects archives to scratch/ and scratch-<project>/ and pushes wip/T1 to each origin" {
  run_bin -0 team-open home feature feat work "Do the work"
  run_bin -0 team-open --task T1 --add site feat move
  local home_wt=$HOME/slots/home/1 site_wt=$HOME/slots/site/1
  echo "home spec" >"$home_wt/.scratch/task/spec.md"
  echo "site notes" >"$site_wt/.scratch/task/notes.md"
  echo "home change" >"$home_wt/change.txt"
  echo "site change" >"$site_wt/change.txt"

  run_bin -0 team-checkpoint
  assert_equal "$(cat "$TEAM_HOME/tasks/T1/scratch/spec.md")" "home spec"
  assert_equal "$(cat "$TEAM_HOME/tasks/T1/scratch-site/notes.md")" "site notes"
  assert_equal "$(git -C "$home_origin" show wip/T1:change.txt)" "home change"
  assert_equal "$(git -C "$site_origin" show wip/T1:change.txt)" "site change"
  assert_equal "$(git -C "$site_origin" rev-parse wip/T1^)" "$(git -C "$site_wt" rev-parse HEAD)"
  assert_equal "$(changed_in dev)" "ledger.jsonl
tasks/T1/scratch-site/notes.md
tasks/T1/scratch/spec.md"
}

@test "a missing worktree, one on another branch and one a git command holds are skipped with why; the rest are checkpointed" {
  local n
  for n in 1 2 3 4; do run_bin -0 team-open home feature feat "work-$n" "Work $n"; done
  for n in 1 2 3 4; do
    echo "spec $n" >"$HOME/slots/home/$n/.scratch/task/spec.md"
    echo "change $n" >"$HOME/slots/home/$n/change.txt"
  done
  rm -rf "$HOME/slots/home/1"
  git -C "$HOME/slots/home/2" switch -q -c other
  local lock
  lock=$(git -C "$HOME/slots/home/3" rev-parse --path-format=absolute --git-path index.lock)
  touch "$lock"

  run_bin -0 --separate-stderr team-checkpoint
  assert_equal "$(head -n 4 <<<"$output")" "T1 home: skipped: $HOME/slots/home/1 is missing
T2 home: skipped: $HOME/slots/home/2 is on other, not feat/T2-work-2
T3 home: skipped: a git command is running in $HOME/slots/home/3 (index.lock)
T4 home: archived .scratch/task to tasks/T4/scratch"
  assert_contains "$output" "T4 home: pushed wip/T4"
  [[ ! -e $TEAM_HOME/tasks/T1/scratch && ! -e $TEAM_HOME/tasks/T2/scratch && ! -e $TEAM_HOME/tasks/T3/scratch ]]
  assert_equal "$(git -C "$home_origin" for-each-ref --format='%(refname)' 'refs/heads/wip/*')" "refs/heads/wip/T4"
  # The lock is the running command's: left in place.
  [[ -e $lock ]]
  [[ -f $state/last-checkpoint ]]
}

@test "an empty task directory is reported and archives nothing" {
  run_bin -0 team-open home feature feat work "Do the work"
  run_bin -0 --separate-stderr team-checkpoint
  assert_equal "$stderr" "team-checkpoint: $HOME/slots/home/1/.scratch/task is empty, so nothing was archived from home"
  assert_equal "$output" "T1 home: pushed wip/T1 $(git -C "$HOME/slots/home/1" rev-parse --short=7 HEAD) (the branch head, no uncommitted changes)
team home: committed $(git -C "$TEAM_HOME" rev-parse --short HEAD) chore: checkpoint and pushed dev"
  [[ ! -e $TEAM_HOME/tasks/T1/scratch ]]
}

@test "the team-home commit holds only the scratch archives, memory and the ledger, whatever else is staged" {
  run_bin -0 team-open home feature feat work "Do the work"
  echo "spec" >"$HOME/slots/home/1/.scratch/task/spec.md"
  mkdir -p "$TEAM_HOME/memory/home"
  echo "- a note" >"$TEAM_HOME/memory/home/MEMORY.md"
  echo "# changed" >>"$TEAM_HOME/projects.toml"
  echo "steps" >"$TEAM_HOME/manual-steps.md"
  git -C "$TEAM_HOME" add projects.toml manual-steps.md tasks/T1/plan.md
  local staged
  staged=$(git -C "$TEAM_HOME" diff --cached)

  run_bin -0 team-checkpoint
  assert_equal "$(changed_in dev)" "ledger.jsonl
memory/home/MEMORY.md
tasks/T1/scratch/spec.md"
  # What was staged is still staged, exactly.
  assert_equal "$(git -C "$TEAM_HOME" diff --cached)" "$staged"
  assert_equal "$(git -C "$TEAM_HOME" diff --cached --name-only)" "manual-steps.md
projects.toml
tasks/T1/plan.md"
}

@test "a rejected push is replayed onto origin's dev and pushed, keeping what is staged" {
  run_bin -0 team-open home feature feat work "Do the work"
  echo "spec" >"$HOME/slots/home/1/.scratch/task/spec.md"
  echo "# changed" >>"$TEAM_HOME/projects.toml"
  git -C "$TEAM_HOME" add projects.toml
  echo "untracked" >"$TEAM_HOME/notes.txt"
  make_machine laptop
  on_machine laptop bash -c 'echo "from laptop" >"$TEAM_HOME/manual-steps.md" &&
    git -C "$TEAM_HOME" add manual-steps.md && git -C "$TEAM_HOME" commit -q -m "docs: a manual step" &&
    git -C "$TEAM_HOME" push -q origin dev'
  local theirs staged
  theirs=$(team_tip) staged=$(git -C "$TEAM_HOME" diff --cached)

  run_bin -0 team-checkpoint
  assert_contains "$output" "team home: committed"
  assert_contains "$output" "origin's dev had moved; replayed onto it and pushed dev"
  assert_equal "$(git -C "$team_origin" rev-parse dev^)" "$theirs"
  assert_equal "$(team_tip)" "$(git -C "$TEAM_HOME" rev-parse HEAD)"
  assert_equal "$(changed_in dev)" "ledger.jsonl
tasks/T1/scratch/spec.md"
  assert_equal "$(cat "$TEAM_HOME/manual-steps.md")" "from laptop"
  assert_equal "$(git -C "$TEAM_HOME" diff --cached)" "$staged"
  assert_equal "$(git -C "$TEAM_HOME" status --porcelain)" "M  projects.toml
?? notes.txt
?? tasks/T1/plan.md"
}

@test "a rejected push that cannot be replayed cleanly is left unpushed with a message, and goes out once it can" {
  run_bin -0 team-open home feature feat work "Do the work"
  echo "spec" >"$HOME/slots/home/1/.scratch/task/spec.md"
  # A local change in the way of origin's new commit.
  echo "local steps" >"$TEAM_HOME/manual-steps.md"
  make_machine laptop
  on_machine laptop bash -c 'echo "from laptop" >"$TEAM_HOME/manual-steps.md" &&
    git -C "$TEAM_HOME" add manual-steps.md && git -C "$TEAM_HOME" commit -q -m "docs: a manual step" &&
    git -C "$TEAM_HOME" push -q origin dev'
  local theirs mine
  theirs=$(team_tip)

  run_bin -1 --separate-stderr team-checkpoint
  mine=$(git -C "$TEAM_HOME" rev-parse HEAD)
  assert_contains "$output" "team home: committed ${mine:0:7} chore: checkpoint"
  assert_contains "$stderr" "team-checkpoint: team home: origin's dev has moved and the commits not on it cannot be replayed onto it (local changes to manual-steps.md are in the way); they stay unpushed"
  assert_equal "$(team_tip)" "$theirs"
  assert_equal "$(git -C "$TEAM_HOME" log -1 --format=%s)" "chore: checkpoint"
  assert_equal "$(cat "$TEAM_HOME/manual-steps.md")" "local steps"
  [[ ! -e $state/last-checkpoint ]]

  # Out of the way: nothing new to commit, and the commit left behind goes out.
  rm "$TEAM_HOME/manual-steps.md"
  run_bin -0 team-checkpoint
  assert_contains "$output" "team home: nothing to commit"
  assert_contains "$output" "origin's dev had moved; replayed onto it and pushed dev"
  assert_equal "$(git -C "$team_origin" rev-parse dev^)" "$theirs"
  assert_equal "$(git -C "$team_origin" log -1 --format=%s dev)" "chore: checkpoint"
  assert_equal "$(cat "$TEAM_HOME/manual-steps.md")" "from laptop"
}

@test "a commit that conflicts with origin's is left unpushed with a message" {
  run_bin -0 team-open home feature feat work "Do the work"
  make_machine laptop
  on_machine laptop bash -c 'echo "{}" >>"$TEAM_HOME/ledger.jsonl" &&
    git -C "$TEAM_HOME" commit -q -am "chore: a ledger line" && git -C "$TEAM_HOME" push -q origin dev'
  local theirs
  theirs=$(team_tip)

  run_bin -1 --separate-stderr team-checkpoint
  assert_contains "$stderr" "team-checkpoint: team home: origin's dev has moved and the commits not on it cannot be replayed onto it (a conflict in ledger.jsonl); they stay unpushed"
  assert_equal "$(team_tip)" "$theirs"
  assert_equal "$(git -C "$TEAM_HOME" log -1 --format=%s)" "chore: checkpoint"
}

@test "without the lease it exits 1, and offline 75, changing nothing" {
  run_bin -0 team-open home feature feat work "Do the work"
  echo "spec" >"$HOME/slots/home/1/.scratch/task/spec.md"
  echo "new" >"$HOME/slots/home/1/new.txt"
  local tip head
  tip=$(team_tip) head=$(git -C "$TEAM_HOME" rev-parse HEAD)

  make_machine laptop
  run -0 "$REPO_ROOT/bin/team-lease" release
  on_machine laptop run -0 "$REPO_ROOT/bin/team-lease" take
  run_bin -1 --separate-stderr team-checkpoint --force
  assert_contains "$stderr" "team-checkpoint: only the machine that holds the lease checkpoints"

  # Offline: GitHub unreachable from the team home.
  on_machine laptop run -0 "$REPO_ROOT/bin/team-lease" release
  run -0 "$REPO_ROOT/bin/team-lease" take
  git -C "$TEAM_HOME" remote set-url origin https://127.0.0.1:9/agent-team.git
  run_bin -75 --separate-stderr team-checkpoint --force
  assert_contains "$stderr" "team-checkpoint: GitHub unreachable; no checkpoint while offline"

  [[ ! -e $TEAM_HOME/tasks/T1/scratch ]]
  run -1 git -C "$home_origin" rev-parse -q --verify refs/heads/wip/T1
  assert_equal "$(git -C "$TEAM_HOME" rev-parse HEAD)" "$head"
  assert_equal "$(team_tip)" "$tip"
  [[ ! -e $state/last-checkpoint ]]
}

@test "without --force it checkpoints only once the last checkpoint is 15 minutes old" {
  run_bin -0 team-open home feature feat work "Do the work"
  local wt=$HOME/slots/home/1
  echo "new" >"$wt/new.txt"
  mkdir -p "$state"
  touch -d '-10 minutes' "$state/last-checkpoint"
  run_bin -0 team-checkpoint
  assert_equal "$output" "not due: the last checkpoint was 10 minutes ago (--force makes one now)"
  run -1 git -C "$home_origin" rev-parse -q --verify refs/heads/wip/T1

  touch -d '-15 minutes' "$state/last-checkpoint"
  run_bin -0 team-checkpoint
  assert_contains "$output" "T1 home: pushed wip/T1"
  (($(date +%s) - $(date -r "$state/last-checkpoint" +%s) < 60))
}

@test "it needs a machine name, and refuses a malformed command line" {
  run_bin -2 team-checkpoint --now
  assert_equal "$output" "team-checkpoint: usage: team-checkpoint [--force]"
  rm "$HOME/.config/agent-team/machine"
  run_bin -1 team-checkpoint
  assert_contains "$output" "this machine has no team name"
}
