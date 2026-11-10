#!/usr/bin/env bats
# team-checkpoint: on the lease holder, each open task's task directories archived into the team
# home, each worktree's work (a snapshot of its uncommitted changes, or its head) pushed as
# wip/<project>/T<n> to the team home's origin, never the project's, and the records committed and
# pushed on the team home's dev.
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

# A pre-push hook that refuses, says so on stdout and stderr, and leaves the marker
# $BATS_TEST_TMPDIR/<name>.ran: refusing_hook <name>
refusing_hook() {
  printf '#!/bin/sh\ntouch "%s/%s.ran"\necho "HOOK SAYS NO on stdout"\necho "HOOK SAYS NO on stderr" >&2\nexit 1\n' \
    "$BATS_TEST_TMPDIR" "$1"
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

@test "one checkpoint pushes the ledger first, archives the scratch, pushes the worktree's changes as wip/home/T1 to the team home's origin and commits the rest of the records" {
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
  # Daniel's level, which holds across restarts and handoffs.
  echo '{"ts":"2026-11-01T14:05:00Z","mode":"manual","level":"minor","by":"Daniel","machine":"home-pc"}' >"$TEAM_HOME/level.jsonl"

  run_bin -0 --separate-stderr team-checkpoint
  local snap
  snap=$(git -C "$team_origin" rev-parse wip/home/T1)
  assert_equal "$output" "team home: committed $(git -C "$TEAM_HOME" rev-parse --short HEAD^) chore: checkpoint ledger and pushed dev
T1 home: archived .scratch/task to tasks/T1/scratch
T1 home: pushed wip/home/T1 ${snap:0:7} (uncommitted changes on ${head:0:7})
usage: read 0 of 0 transcripts; no day file changed
team home: committed $(git -C "$TEAM_HOME" rev-parse --short HEAD) chore: checkpoint and pushed dev"
  assert_equal "$stderr" ""

  # The worktree is untouched, its stash included.
  assert_equal "$(worktree_state "$wt")" "$before"
  assert_equal "$(git -C "$wt" stash list | wc -l)" 1

  assert_equal "$(cat "$TEAM_HOME/tasks/T1/scratch/spec.md")" "spec"

  # The snapshot: the tracked edit, the staged and the untracked file, on the worktree's head;
  # never ignored files or the task directory.
  assert_equal "$(git -C "$team_origin" rev-parse wip/home/T1^)" "$head"
  assert_equal "$(git -C "$team_origin" show wip/home/T1:README.md)" "home
edited"
  assert_equal "$(git -C "$team_origin" show wip/home/T1:staged.txt)" "staged"
  assert_equal "$(git -C "$team_origin" show wip/home/T1:new.txt)" "new"
  run -128 git -C "$team_origin" cat-file -e wip/home/T1:.env
  run -128 git -C "$team_origin" cat-file -e wip/home/T1:.scratch/task/spec.md
  [[ $(git -C "$team_origin" log -1 --format=%s wip/home/T1) =~ ^"wip: T1 checkpoint on home-pc at "[0-9T:-]+Z$ ]]
  # Only that one ref is new on the team home's origin, and nothing is new on the project's.
  assert_equal "$(git -C "$team_origin" for-each-ref --format='%(refname)')" "refs/heads/dev
refs/heads/lease
refs/heads/wip/home/T1"
  assert_equal "$(git -C "$home_origin" for-each-ref --format='%(refname)')" "refs/heads/main"

  # The team home: the ledger files alone, then the rest of the records, the plan team-open wrote
  # among them, both pushed.
  assert_equal "$(team_tip)" "$(git -C "$TEAM_HOME" rev-parse HEAD)"
  assert_equal "$(git -C "$team_origin" log -2 --format=%s dev)" "chore: checkpoint
chore: checkpoint ledger"
  assert_equal "$(changed_in dev^)" "ledger.jsonl
level.jsonl"
  assert_equal "$(changed_in dev)" "tasks/T1/plan.md
tasks/T1/scratch/spec.md"
  assert_equal "$(git -C "$TEAM_HOME" status --porcelain)" ""
  [[ -f $state/last-checkpoint ]]
}

@test "untracked files that may hold a secret are left out of the snapshot, each named" {
  run_bin -0 team-open home feature feat work "Do the work"
  local wt=$HOME/slots/home/1
  echo "spec" >"$wt/.scratch/task/spec.md"
  mkdir -p "$wt/back-end" "$wt/certs"
  echo "new" >"$wt/new.txt"
  echo "DB=1" >"$wt/back-end/.env.test"
  echo "pem" >"$wt/certs/server.pem"
  echo "key" >"$wt/certs/server.key"
  echo "keys" >"$wt/keys.txt"
  echo '{}' >"$wt/access.json"
  mkdir -p "$TEAM_HOME/machine"
  echo '{"secrets": [{"id": "discord-access-json", "target": ".claude/channels/discord/access.json"}]}' \
    >"$TEAM_HOME/machine/secrets.json"

  run_bin -0 --separate-stderr team-checkpoint
  assert_contains "$output" "T1 home: left out of wip/home/T1, as files that may hold a secret: access.json back-end/.env.test certs/server.key certs/server.pem"
  assert_equal "$(git -C "$team_origin" ls-tree -r --name-only wip/home/T1 | paste -sd ' ')" ".gitignore README.md keys.txt new.txt"

  # Only secrets left untracked: the worktree is clean as far as the snapshot goes.
  rm "$wt/new.txt" "$wt/keys.txt"
  run_bin -0 --separate-stderr team-checkpoint --force
  assert_contains "$output" "T1 home: pushed wip/home/T1 $(git -C "$wt" rev-parse --short HEAD) (the branch head, no uncommitted changes)"
}

@test "a second checkpoint with nothing new makes no commit and no push; a new change pushes a new snapshot" {
  run_bin -0 team-open home feature feat work "Do the work"
  local wt=$HOME/slots/home/1 tip snap
  echo "spec" >"$wt/.scratch/task/spec.md"
  echo "new" >"$wt/new.txt"
  run_bin -0 team-checkpoint
  tip=$(team_tip) snap=$(git -C "$team_origin" rev-parse wip/home/T1)

  log_pushes
  run_bin -0 team-checkpoint --force
  assert_equal "$output" "team home: nothing new in the ledger
T1 home: archived .scratch/task to tasks/T1/scratch
T1 home: wip/home/T1 is up to date (${snap:0:7})
usage: read 0 of 0 transcripts; no day file changed
team home: nothing to commit"
  assert_equal "$(stub_calls git-push)" ""
  assert_equal "$(team_tip)" "$tip"
  assert_equal "$(git -C "$team_origin" rev-parse wip/home/T1)" "$snap"

  # A new change replaces the snapshot; no record changed, so no team-home commit.
  echo "more" >>"$wt/new.txt"
  run_bin -0 team-checkpoint --force
  assert_contains "$output" "T1 home: pushed wip/home/T1"
  assert_contains "$output" "team home: nothing to commit"
  [[ $(git -C "$team_origin" rev-parse wip/home/T1) != "$snap" ]]
  assert_equal "$(git -C "$team_origin" show wip/home/T1:new.txt)" "new
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
  assert_contains "$output" "T1 home: pushed wip/home/T1 ${head:0:7} (the branch head, no uncommitted changes)"
  assert_equal "$(git -C "$team_origin" rev-parse wip/home/T1)" "$head"
  run -1 git -C "$home_origin" rev-parse -q --verify refs/heads/feat/T1-work
  assert_equal "$(wc -l <"$STUB_CALLS/git-push.log")" 2
  run_bin -0 team-checkpoint --force
  assert_contains "$output" "T1 home: wip/home/T1 is up to date (${head:0:7}, no uncommitted changes)"
  assert_equal "$(wc -l <"$STUB_CALLS/git-push.log")" 2
}

@test "a snapshot whose head moved is pushed again, though its tree is the same" {
  run_bin -0 team-open home feature feat work "Do the work"
  local wt=$HOME/slots/home/1 snap
  echo "a" >"$wt/a.txt"
  echo "b" >"$wt/b.txt"
  run_bin -0 team-checkpoint
  snap=$(git -C "$team_origin" rev-parse wip/home/T1)
  git -C "$wt" add a.txt
  git -C "$wt" commit -q -m "feat: a"

  run_bin -0 team-checkpoint --force
  assert_contains "$output" "T1 home: pushed wip/home/T1"
  assert_equal "$(git -C "$team_origin" rev-parse 'wip/home/T1^{tree}')" "$(git -C "$team_origin" rev-parse "$snap^{tree}")"
  assert_equal "$(git -C "$team_origin" rev-parse wip/home/T1^)" "$(git -C "$wt" rev-parse HEAD)"
}

@test "a task with worktrees in two projects archives to scratch/ and scratch-<project>/ and pushes wip/<project>/T1 for each to the team home's origin" {
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
  assert_equal "$(git -C "$team_origin" show wip/home/T1:change.txt)" "home change"
  assert_equal "$(git -C "$team_origin" show wip/site/T1:change.txt)" "site change"
  assert_equal "$(git -C "$team_origin" rev-parse wip/site/T1^)" "$(git -C "$site_wt" rev-parse HEAD)"
  assert_equal "$(git -C "$home_origin" for-each-ref --format='%(refname)' refs/heads/wip/)" ""
  assert_equal "$(git -C "$site_origin" for-each-ref --format='%(refname)' refs/heads/wip/)" ""
  assert_equal "$(changed_in dev)" "tasks/T1/plan.md
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
  assert_equal "$(sed -n 2,5p <<<"$output")" "T1 home: skipped: $HOME/slots/home/1 is missing
T2 home: skipped: $HOME/slots/home/2 is on other, not feat/T2-work-2
T3 home: skipped: a git command is running in $HOME/slots/home/3 (index.lock)
T4 home: archived .scratch/task to tasks/T4/scratch"
  assert_contains "$output" "T4 home: pushed wip/home/T4"
  [[ ! -e $TEAM_HOME/tasks/T1/scratch && ! -e $TEAM_HOME/tasks/T2/scratch && ! -e $TEAM_HOME/tasks/T3/scratch ]]
  assert_equal "$(git -C "$team_origin" for-each-ref --format='%(refname)' refs/heads/wip/)" "refs/heads/wip/home/T4"
  # The lock is the running command's: left in place.
  [[ -e $lock ]]
  [[ -f $state/last-checkpoint ]]
}

@test "a worktree the ledger spells otherwise than git is checkpointed, not skipped as missing (report F6)" {
  local other
  mkdir -p "$HOME/slots"
  other=$(other_spelling "$HOME/slots")
  sed -i "s#\"slots/home/#\"${other##*/}/home/#g" "$TEAM_HOME/projects.toml"
  run_bin -0 team-open home feature feat work "Work"
  assert_equal "$(jq -r .worktree <<<"$output")" "$other/home/1"
  echo spec >"$other/home/1/.scratch/task/spec.md"
  run_bin -0 --separate-stderr team-checkpoint
  assert_equal "$(sed -n 2p <<<"$output")" "T1 home: archived .scratch/task to tasks/T1/scratch"
}

@test "a worktree whose snapshot git cannot build is that worktree's failure alone: the next is pushed and the records committed" {
  [[ $(id -u) != 0 ]] || skip "root reads a file whatever its mode"
  run_bin -0 team-open home feature feat work1 "Work 1"
  run_bin -0 team-open home feature feat work2 "Work 2"
  local one=$HOME/slots/home/1 two=$HOME/slots/home/2
  echo "unreadable" >"$one/locked.txt"
  chmod 000 "$one/locked.txt"
  echo "change" >"$two/change.txt"

  run_bin -1 --separate-stderr team-checkpoint
  assert_equal "$stderr" "team-checkpoint: T1 home: cannot snapshot wip/home/T1: open(\"locked.txt\"): Permission denied"
  assert_contains "$output" "T2 home: pushed wip/home/T2"
  assert_equal "$(git -C "$team_origin" for-each-ref --format='%(refname)' refs/heads/wip/)" "refs/heads/wip/home/T2"
  assert_equal "$(git -C "$team_origin" show wip/home/T2:change.txt)" "change"
  assert_contains "$output" "team home: committed"
  assert_equal "$(team_tip)" "$(git -C "$TEAM_HOME" rev-parse HEAD)"
  [[ ! -e $state/last-checkpoint ]]
}

@test "an untracked nested repository with no commit fails that worktree's snapshot with git's own line; the others still run" {
  run_bin -0 team-open home feature feat work1 "Work 1"
  run_bin -0 team-open home feature feat work2 "Work 2"
  local one=$HOME/slots/home/1 two=$HOME/slots/home/2
  echo "spec" >"$one/.scratch/task/spec.md"
  git init -q "$one/nested"
  echo "change" >"$two/change.txt"
  local before
  before=$(worktree_state "$one")

  run_bin -1 --separate-stderr team-checkpoint
  assert_equal "$(worktree_state "$one")" "$before"
  assert_equal "$stderr" "team-checkpoint: T1 home: cannot snapshot wip/home/T1: 'nested/' does not have a commit checked out"
  # Its archive is kept apart from its snapshot: still made.
  assert_contains "$output" "T1 home: archived .scratch/task to tasks/T1/scratch"
  assert_contains "$output" "T2 home: pushed wip/home/T2"
  assert_equal "$(git -C "$team_origin" for-each-ref --format='%(refname)' refs/heads/wip/)" "refs/heads/wip/home/T2"
  assert_equal "$(git -C "$team_origin" show dev:tasks/T1/scratch/spec.md)" "spec"
  [[ ! -e $state/last-checkpoint ]]
}

@test "a mirror that fails is that worktree's failure with rsync's reason; its snapshot is still pushed and the next task still runs" {
  [[ $(id -u) != 0 ]] || skip "root reads a file whatever its mode"
  run_bin -0 team-open home feature feat work1 "Work 1"
  run_bin -0 team-open home feature feat work2 "Work 2"
  local one=$HOME/slots/home/1 two=$HOME/slots/home/2
  echo "unreadable" >"$one/.scratch/task/locked.md"
  chmod 000 "$one/.scratch/task/locked.md"
  echo "change 1" >"$one/change.txt"
  echo "spec 2" >"$two/.scratch/task/spec.md"

  run_bin -1 --separate-stderr team-checkpoint
  [[ $stderr =~ ^"team-checkpoint: T1 home: cannot mirror $one/.scratch/task into tasks/T1/scratch: rsync".*"locked.md".*"Permission denied"[^$'\n']*$ ]]
  assert_contains "$output" "T1 home: pushed wip/home/T1"
  assert_equal "$(git -C "$team_origin" show wip/home/T1:change.txt)" "change 1"
  assert_contains "$output" "T2 home: archived .scratch/task to tasks/T2/scratch"
  assert_equal "$(git -C "$team_origin" show dev:tasks/T2/scratch/spec.md)" "spec 2"
  [[ ! -e $state/last-checkpoint ]]
}

@test "a worktree whose project is gone from the registry is that worktree's failure; its snapshot is pushed and the next task still runs" {
  run_bin -0 team-open site feature feat work1 "Work 1"
  run_bin -0 team-open home feature feat work2 "Work 2"
  echo "change 1" >"$HOME/slots/site/1/change.txt"
  echo "spec 2" >"$HOME/slots/home/1/.scratch/task/spec.md"
  sed -i '/^\[site/,$d' "$TEAM_HOME/projects.toml"

  run_bin -1 --separate-stderr team-checkpoint
  assert_equal "$stderr" "team-checkpoint: T1 site: cannot read site from the registry: unknown project 'site'; known: home"
  assert_contains "$output" "T1 site: pushed wip/site/T1"
  assert_contains "$output" "T2 home: archived .scratch/task to tasks/T2/scratch"
  assert_contains "$output" "T2 home: pushed wip/home/T2"
  assert_contains "$output" "team home: committed"
  [[ ! -e $state/last-checkpoint ]]
}

@test "a failed read or push of one worktree's wip ref is that worktree's failure alone" {
  run_bin -0 team-open site feature feat work1 "Work 1"
  run_bin -0 team-open home feature feat work2 "Work 2"
  run_bin -0 team-open home feature feat work3 "Work 3"
  echo "change 1" >"$HOME/slots/site/1/change.txt"
  echo "change 2" >"$HOME/slots/home/1/change.txt"
  echo "change 3" >"$HOME/slots/home/2/change.txt"
  # The read of the team home's origin fails for site's objects alone (the checkpoint reads none
  # of site's repository config, so a git that refuses it stands in); the origin refuses wip/home/T2.
  local real_git
  real_git=$(command -v git)
  cat >"$BATS_TEST_TMPDIR/stubs/git" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  case \$arg in --git-dir=*) dir=\${arg#--git-dir=} ;; ls-remote) read=1 ;; esac
done
if [[ -n \${read:-} && -n \${dir:-} ]] && grep -q "/site/" "\$dir/objects/info/alternates" 2>/dev/null; then
  echo "fatal: the test refuses site's read" >&2
  exit 128
fi
exec "$real_git" "\$@"
EOF
  chmod +x "$BATS_TEST_TMPDIR/stubs/git"
  printf '#!/bin/sh\nwhile read -r old new ref; do [ "$ref" != refs/heads/wip/home/T2 ] || { echo "the test refuses T2" >&2; exit 1; }; done\n' \
    >"$team_origin/hooks/pre-receive"
  chmod +x "$team_origin/hooks/pre-receive"

  run_bin -1 --separate-stderr team-checkpoint
  [[ $stderr =~ ^"team-checkpoint: T1 site: cannot read wip/site/T1 on the team home's origin: the test refuses site's read"$'\n'"team-checkpoint: T2 home: cannot push wip/home/T2 to the team home's origin: "[^$'\n']+$ ]]
  assert_contains "$output" "T3 home: pushed wip/home/T3"
  assert_equal "$(git -C "$team_origin" for-each-ref --format='%(refname)' refs/heads/wip/)" "refs/heads/wip/home/T3"
  assert_contains "$output" "team home: committed"
  [[ ! -e $state/last-checkpoint ]]
}

@test "the snapshot push runs none of the project's hooks, from .git/hooks or a relative core.hooksPath" {
  run_bin -0 team-open home feature feat work1 "Work 1"
  run_bin -0 team-open site feature feat work2 "Work 2"
  local one=$HOME/slots/home/1 two=$HOME/slots/site/1 hooks
  hooks=$(git -C "$home" rev-parse --path-format=absolute --git-common-dir)/hooks
  git -C "$site" config core.hooksPath .githooks
  mkdir -p "$two/.githooks"
  refusing_hook home >"$hooks/pre-push"
  refusing_hook site >"$two/.githooks/pre-push"
  chmod +x "$hooks/pre-push" "$two/.githooks/pre-push"
  echo "change 1" >"$one/change.txt"
  echo "change 2" >"$two/change.txt"

  run_bin -0 --separate-stderr team-checkpoint
  assert_contains "$output" "T1 home: pushed wip/home/T1"
  assert_contains "$output" "T2 site: pushed wip/site/T2"
  assert_equal "$(git -C "$team_origin" show wip/home/T1:change.txt)" "change 1"
  assert_equal "$(git -C "$team_origin" show wip/site/T2:change.txt)" "change 2"
  [[ $output$stderr != *"HOOK SAYS NO"* ]]
  [[ ! -e $BATS_TEST_TMPDIR/home.ran && ! -e $BATS_TEST_TMPDIR/site.ran ]]

  # Each hook is live: a plain push from either worktree runs it and is refused.
  run git -C "$one" push "$team_origin" HEAD:refs/heads/probe-1
  ((status != 0))
  run git -C "$two" push "$team_origin" HEAD:refs/heads/probe-2
  ((status != 0))
  [[ -e $BATS_TEST_TMPDIR/home.ran && -e $BATS_TEST_TMPDIR/site.ran ]]
}

@test "a worktree's repository config runs no command of its own: no fsmonitor and no clean filter" {
  run_bin -0 team-open home feature feat work1 "Work 1"
  run_bin -0 team-open site feature feat work2 "Work 2"
  local one=$HOME/slots/home/1 two=$HOME/slots/site/1 cmd
  # Each command leaves its marker, then does what git asks of it: no fsmonitor answer, the
  # content as it is.
  for cmd in fsmonitor clean; do
    printf '#!/bin/sh\ntouch "%s/%s.ran"\n%s\n' "$BATS_TEST_TMPDIR" "$cmd" \
      "$([[ $cmd == clean ]] && echo cat || echo 'exit 1')" >"$BATS_TEST_TMPDIR/$cmd"
    chmod +x "$BATS_TEST_TMPDIR/$cmd"
  done
  git -C "$home" config core.fsmonitor "$BATS_TEST_TMPDIR/fsmonitor"
  git -C "$site" config filter.Mark.clean "$BATS_TEST_TMPDIR/clean"
  git -C "$site" config filter.Mark.required true
  echo '*.txt filter=Mark' >"$two/.gitattributes"
  echo "change 1" >"$one/change.txt"
  echo "change 2" >"$two/change.txt"

  run_bin -0 --separate-stderr team-checkpoint
  assert_equal "$stderr" ""
  assert_contains "$output" "T1 home: pushed wip/home/T1"
  assert_contains "$output" "T2 site: pushed wip/site/T2"
  assert_equal "$(git -C "$team_origin" show wip/home/T1:change.txt)" "change 1"
  assert_equal "$(git -C "$team_origin" show wip/site/T2:change.txt)" "change 2"
  [[ ! -e $BATS_TEST_TMPDIR/fsmonitor.ran && ! -e $BATS_TEST_TMPDIR/clean.ran ]]

  # Each command is live: git's own commands in the worktree run it.
  git -C "$one" status --short >/dev/null
  git -C "$two" hash-object --path change.txt change.txt >/dev/null
  [[ -e $BATS_TEST_TMPDIR/fsmonitor.ran && -e $BATS_TEST_TMPDIR/clean.ran ]]
}

@test "the wip ref goes to the team home's origin whatever URL rewrite the worktree's repository config names" {
  run_bin -0 team-open home feature feat work1 "Work 1"
  run_bin -0 team-open site feature feat work2 "Work 2"
  local one=$HOME/slots/home/1 two=$HOME/slots/site/1 elsewhere=$BATS_TEST_TMPDIR/elsewhere.git url
  git init -q --bare "$elsewhere"
  url=$(git -C "$TEAM_HOME" remote get-url origin)
  git -C "$home" config "url.$elsewhere.insteadOf" "$url"
  git -C "$site" config "url.$elsewhere.pushInsteadOf" "$url"
  echo "change 1" >"$one/change.txt"
  echo "change 2" >"$two/change.txt"

  run_bin -0 --separate-stderr team-checkpoint
  assert_equal "$stderr" ""
  assert_contains "$output" "T1 home: pushed wip/home/T1"
  assert_contains "$output" "T2 site: pushed wip/site/T2"
  assert_equal "$(git -C "$team_origin" show wip/home/T1:change.txt)" "change 1"
  assert_equal "$(git -C "$team_origin" show wip/site/T2:change.txt)" "change 2"
  assert_equal "$(git -C "$elsewhere" for-each-ref)" ""
  # The worktree's config is untouched, and a second run sees both up to date.
  assert_equal "$(git -C "$home" config "url.$elsewhere.insteadOf")" "$url"
  run_bin -0 team-checkpoint --force
  assert_contains "$output" "T1 home: wip/home/T1 is up to date"
  assert_contains "$output" "T2 site: wip/site/T2 is up to date"

  # The rewrite is live: a plain push from either worktree goes elsewhere.
  git -C "$one" push -q "$url" HEAD:refs/heads/probe-1
  git -C "$two" push -q "$url" HEAD:refs/heads/probe-2
  assert_equal "$(git -C "$elsewhere" for-each-ref --format='%(refname)' | paste -sd ' ')" "refs/heads/probe-1 refs/heads/probe-2"
}

@test "with --deadline, worktrees not begun by it are skipped as failures, the records still committed, and taken first next time; without it every one runs" {
  local n real_rsync
  for n in 1 2 3; do
    run_bin -0 team-open home feature feat "work$n" "Work $n"
    echo "spec $n" >"$HOME/slots/home/$n/.scratch/task/spec.md"
  done
  # T1's archive takes 4 s, so it ends past a 3 s deadline; the others' are quick.
  real_rsync=$(command -v rsync)
  printf '#!/usr/bin/env bash\n[[ "$*" != *"/slots/home/1/"* ]] || command -p sleep 4\nexec "%s" "$@"\n' "$real_rsync" \
    >"$BATS_TEST_TMPDIR/stubs/rsync"
  chmod +x "$BATS_TEST_TMPDIR/stubs/rsync"

  run_bin -1 --separate-stderr team-checkpoint --deadline 3
  assert_contains "$output" "T1 home: pushed wip/home/T1"
  [[ $stderr =~ ^"team-checkpoint: T2 home: skipped: the checkpoint has run "[0-9]+" s, past its 3 s deadline for worktrees, so the records are committed in time; the next checkpoint takes it first"$'\n'"team-checkpoint: T3 home: skipped: "[^$'\n']*$ ]]
  # The records are committed and pushed all the same: T1's archive with them.
  assert_equal "$(git -C "$team_origin" show dev:tasks/T1/scratch/spec.md)" "spec 1"
  assert_equal "$(git -C "$team_origin" log -1 --format=%s dev)" "chore: checkpoint"
  [[ -z $(git -C "$team_origin" rev-parse -q --verify refs/heads/wip/home/T2) ]]
  [[ ! -e $state/last-checkpoint ]]

  # The next checkpoint, with no deadline (as team-stow and team-handoff run it), takes the
  # skipped first, in their order, then the rest, and every one runs, however long: T2's archive,
  # the first, now takes 4 s, so T3 and T1 begin past those 3 s and are still taken.
  printf '#!/usr/bin/env bash\n[[ "$*" != *"/slots/home/2/"* ]] || command -p sleep 4\nexec "%s" "$@"\n' "$real_rsync" \
    >"$BATS_TEST_TMPDIR/stubs/rsync"
  run_bin -0 --separate-stderr team-checkpoint --force
  assert_equal "$stderr" ""
  assert_equal "$(grep -oE '^T[0-9] home: (pushed|wip/home/T[0-9] is up to date)' <<<"$output" | cut -c1-2 | paste -sd ' ')" "T2 T3 T1"
  assert_equal "$(git -C "$team_origin" show dev:tasks/T3/scratch/spec.md)" "spec 3"
  [[ -e $state/last-checkpoint && ! -e $state/checkpoint-first ]]
}

@test "an empty or a missing task directory is one line under the worktree's label, archives nothing and is no problem" {
  run_bin -0 team-open home feature feat work "Do the work"
  run_bin -0 --separate-stderr team-checkpoint
  assert_equal "$stderr" ""
  assert_equal "$output" "team home: committed $(git -C "$TEAM_HOME" rev-parse --short HEAD^) chore: checkpoint ledger and pushed dev
T1 home: $HOME/slots/home/1/.scratch/task is empty, so nothing was archived from home
T1 home: pushed wip/home/T1 $(git -C "$HOME/slots/home/1" rev-parse --short=7 HEAD) (the branch head, no uncommitted changes)
usage: read 0 of 0 transcripts; no day file changed
team home: committed $(git -C "$TEAM_HOME" rev-parse --short HEAD) chore: checkpoint and pushed dev"
  [[ ! -e $TEAM_HOME/tasks/T1/scratch ]]
  [[ -f $state/last-checkpoint ]]

  rmdir "$HOME/slots/home/1/.scratch/task"
  run_bin -0 --separate-stderr team-checkpoint --force
  assert_equal "$stderr" ""
  assert_equal "$(head -n 2 <<<"$output")" "team home: nothing new in the ledger
T1 home: $HOME/slots/home/1/.scratch/task is missing, so nothing was archived from home"
  [[ ! -e $TEAM_HOME/tasks/T1/scratch ]]
}

@test "the archive leaves out nested repositories, files over 1 MiB and names that may hold a secret, each named" {
  run_bin -0 team-open home feature feat work "Do the work"
  local dir=$HOME/slots/home/1/.scratch/task
  echo "notes" >"$dir/notes.md"
  git init -q "$dir/clone"
  head -c 3M /dev/zero >"$dir/clone/tool.bin"
  git -C "$dir/clone" add tool.bin
  git -C "$dir/clone" commit -q -m "feat: tool"
  head -c 2M /dev/zero >"$dir/big.bin"
  echo "SECRET=1" >"$dir/.env.local"
  echo '{}' >"$dir/access.json"
  mkdir -p "$TEAM_HOME/machine"
  echo '{"secrets": [{"id": "discord-access-json", "target": ".claude/channels/discord/access.json"}]}' \
    >"$TEAM_HOME/machine/secrets.json"
  # An archive made before these were left out loses them on the next mirror.
  mkdir -p "$TEAM_HOME/tasks/T1/scratch"
  echo "old" >"$TEAM_HOME/tasks/T1/scratch/big.bin"

  run_bin -0 --separate-stderr team-checkpoint
  assert_equal "$stderr" ""
  assert_contains "$output" "T1 home: left out of tasks/T1/scratch: clone (nested repository)
T1 home: left out of tasks/T1/scratch: big.bin (over 1 MiB)
T1 home: left out of tasks/T1/scratch: .env.local (may hold a secret)
T1 home: left out of tasks/T1/scratch: access.json (may hold a secret)
T1 home: archived .scratch/task to tasks/T1/scratch"
  assert_equal "$(cd "$TEAM_HOME/tasks/T1/scratch" && find . -mindepth 1 | sort)" "./notes.md"
  # The checkpoint's commit holds the notes alone: no gitlink, no large file, no secret.
  assert_equal "$(git -C "$team_origin" ls-tree -r dev tasks/T1/scratch)" \
    "100644 blob $(git -C "$TEAM_HOME" hash-object "$dir/notes.md")	tasks/T1/scratch/notes.md"
  # A file of exactly 1 MiB is not over it.
  head -c 1M /dev/zero >"$dir/big.bin"
  run_bin -0 --separate-stderr team-checkpoint --force
  assert_equal "$(cd "$TEAM_HOME/tasks/T1/scratch" && find . -mindepth 1 | sort)" "./big.bin
./notes.md"
}

@test "the archive leaves out bare repositories, dependency trees, directories of over 200 files and links, each named" {
  run_bin -0 team-open home feature feat work "Do the work"
  local dir=$HOME/slots/home/1/.scratch/task
  echo "notes" >"$dir/notes.md"
  git init -q --bare "$dir/mirror.git"
  mkdir -p "$dir/tools/node_modules/a" "$dir/trial/front-end/src" "$dir/kept"
  touch "$dir/tools/node_modules/a/1.js" "$dir/tools/node_modules/a/2.js" "$dir/tools/node_modules/3.js"
  # 201 files, counted through trial/'s subdirectories; kept/ holds exactly 200.
  touch "$dir/trial/front-end/src/"{1..150}.ts "$dir/trial/"{1..51}.txt "$dir/kept/"{1..200}.txt
  ln -s ../../front-end/node_modules "$dir/node_modules"
  ln -s notes.md "$dir/latest.md"

  run_bin -0 --separate-stderr team-checkpoint
  assert_equal "$stderr" ""
  assert_contains "$output" "T1 home: left out of tasks/T1/scratch: mirror.git (nested repository)
T1 home: left out of tasks/T1/scratch: tools/node_modules (dependencies)
T1 home: left out of tasks/T1/scratch: trial (over 200 files)
T1 home: left out of tasks/T1/scratch: latest.md (link)
T1 home: left out of tasks/T1/scratch: node_modules (link)
T1 home: archived .scratch/task to tasks/T1/scratch"
  assert_equal "$(cd "$TEAM_HOME/tasks/T1/scratch" && find . -mindepth 1 -not -path './kept/*' | sort)" "./kept
./notes.md
./tools"
  assert_equal "$(find "$TEAM_HOME/tasks/T1/scratch/kept" -type f | wc -l)" "200"
}

@test "the archive leaves out every image anywhere in the task directory, named, and keeps the text beside it" {
  run_bin -0 team-open home feature feat work "Do the work"
  local dir=$HOME/slots/home/1/.scratch/task
  mkdir -p "$dir/ui-check/reviewer-abc1234"
  echo "findings" >"$dir/ui-check/reviewer-abc1234/findings.md"
  echo "png" >"$dir/ui-check/reviewer-abc1234/menu-390x844.png"
  echo "webp" >"$dir/ui-check/reviewer-abc1234/dialog-1440x810.WEBP"
  # An archive made before images were left out loses them on the next mirror.
  mkdir -p "$TEAM_HOME/tasks/T1/scratch/ui-check/reviewer-abc1234"
  echo "old" >"$TEAM_HOME/tasks/T1/scratch/ui-check/reviewer-abc1234/menu-390x844.png"

  run_bin -0 --separate-stderr team-checkpoint
  assert_equal "$stderr" ""
  assert_contains "$output" "T1 home: left out of tasks/T1/scratch: ui-check/reviewer-abc1234/dialog-1440x810.WEBP (image)
T1 home: left out of tasks/T1/scratch: ui-check/reviewer-abc1234/menu-390x844.png (image)
T1 home: archived .scratch/task to tasks/T1/scratch"
  assert_equal "$(cd "$TEAM_HOME/tasks/T1/scratch" && find . -mindepth 1 | sort)" "./ui-check
./ui-check/reviewer-abc1234
./ui-check/reviewer-abc1234/findings.md"
  # The records hook, which refuses any image, takes the checkpoint's commit.
  assert_equal "$(git -C "$team_origin" ls-tree -r --name-only dev tasks/T1/scratch)" "tasks/T1/scratch/ui-check/reviewer-abc1234/findings.md"
}

@test "the archive leaves out a ui-check run's Lighthouse reports, an image among them named once, and keeps the run's text" {
  run_bin -0 team-open home feature feat work "Do the work"
  local run=$HOME/slots/home/1/.scratch/task/ui-check/reviewer-abc1234
  mkdir -p "$run/lighthouse/dialog"
  echo "findings" >"$run/findings.md"
  echo "{}" >"$run/lighthouse/dialog/report.json"
  echo "png" >"$run/lighthouse/dialog/screenshot.png"
  # An archive made before the reports were left out loses them on the next mirror.
  mkdir -p "$TEAM_HOME/tasks/T1/scratch/ui-check/reviewer-abc1234/lighthouse/dialog"
  echo "{}" >"$TEAM_HOME/tasks/T1/scratch/ui-check/reviewer-abc1234/lighthouse/dialog/report.json"

  run_bin -0 --separate-stderr team-checkpoint
  assert_equal "$stderr" ""
  assert_contains "$output" "T1 home: left out of tasks/T1/scratch: ui-check/reviewer-abc1234/lighthouse (Lighthouse reports)
T1 home: archived .scratch/task to tasks/T1/scratch"
  assert_equal "$(git -C "$team_origin" ls-tree -r --name-only dev tasks/T1/scratch)" "tasks/T1/scratch/ui-check/reviewer-abc1234/findings.md"
}

@test "the archive leaves out the task's stack logs, and an older archive loses them" {
  run_bin -0 team-open home feature feat work "Do the work"
  local dir=$HOME/slots/home/1/.scratch/task
  mkdir -p "$dir/stack-logs"
  echo "notes" >"$dir/notes.md"
  echo "backend started" >"$dir/stack-logs/T1-home-1-backend.log"
  mkdir -p "$TEAM_HOME/tasks/T1/scratch/stack-logs"
  echo "backend started" >"$TEAM_HOME/tasks/T1/scratch/stack-logs/home-1-backend.log"

  run_bin -0 --separate-stderr team-checkpoint
  assert_equal "$stderr" ""
  assert_contains "$output" "T1 home: left out of tasks/T1/scratch: stack-logs (stack logs)
T1 home: archived .scratch/task to tasks/T1/scratch"
  assert_equal "$(git -C "$team_origin" ls-tree -r --name-only dev tasks/T1/scratch)" "tasks/T1/scratch/notes.md"
}

@test "the team-home commits hold every records path, the ledger files in their own, never another path staged or ignored" {
  run_bin -0 team-open home feature feat work "Do the work"
  echo "spec" >"$HOME/slots/home/1/.scratch/task/spec.md"
  printf 'ledger.jsonl.lock\ntasks/*/settings.*.json\ntasks/*/mcp.*.json\ntasks/*/ui/\n' >"$TEAM_HOME/.gitignore"
  mkdir -p "$TEAM_HOME/memory/home" "$TEAM_HOME/projects/p/backlog"
  echo "- a note" >"$TEAM_HOME/memory/home/MEMORY.md"
  printf '# Current items\n- owe - the T1 summary | tasks/T1/plan.md\n' >"$TEAM_HOME/tasks/current.md"
  echo "a story" >"$TEAM_HOME/projects/p/backlog/s.md"
  echo "steps" >"$TEAM_HOME/manual-steps.md"
  # A path outside the records, staged, and ignored files beside the records.
  echo "readme" >"$TEAM_HOME/README.md"
  git -C "$TEAM_HOME" add README.md
  echo '{}' >"$TEAM_HOME/tasks/T1/settings.builder.json"
  echo '{}' >"$TEAM_HOME/tasks/T1/mcp.builder.json"
  mkdir -p "$TEAM_HOME/tasks/T1/ui"
  echo "capture" >"$TEAM_HOME/tasks/T1/ui/state.txt"
  local staged
  staged=$(git -C "$TEAM_HOME" diff --cached)

  run_bin -0 team-checkpoint
  assert_equal "$(git -C "$team_origin" log -1 --format=%s dev)" "chore: checkpoint"
  assert_equal "$(changed_in dev^)" "ledger.jsonl"
  assert_equal "$(changed_in dev)" "manual-steps.md
memory/home/MEMORY.md
projects/p/backlog/s.md
tasks/T1/plan.md
tasks/T1/scratch/spec.md
tasks/current.md"

  # A changed plan, a new brief and its record, a queue item, a changed story, steps and registry.
  echo "- a plan change" >>"$TEAM_HOME/tasks/T1/plan.md"
  echo "the brief" >"$TEAM_HOME/tasks/T1/brief-build-01.md"
  echo '{"template": "builder"}' >"$TEAM_HOME/tasks/T1/brief-build-01.json"
  mkdir -p "$TEAM_HOME/tasks/queued"
  echo "a queued task" >"$TEAM_HOME/tasks/queued/x.md"
  echo "a changed story" >"$TEAM_HOME/projects/p/backlog/s.md"
  echo "more steps" >>"$TEAM_HOME/manual-steps.md"
  echo "# changed" >>"$TEAM_HOME/projects.toml"
  jq -cn '{ts: (now | todate), task: "T1", event: "waiting", on: "Daniel", reason: "a test"}' >>"$TEAM_HOME/ledger.jsonl"
  run_bin -0 team-checkpoint --force
  assert_equal "$(git -C "$team_origin" log -1 --format=%s dev)" "chore: checkpoint"
  assert_equal "$(changed_in dev^)" "ledger.jsonl"
  assert_equal "$(changed_in dev)" "manual-steps.md
projects.toml
projects/p/backlog/s.md
tasks/T1/brief-build-01.json
tasks/T1/brief-build-01.md
tasks/T1/plan.md
tasks/queued/x.md"

  # The next checkpoint carries an emptied list, and its removal.
  echo "# Current items" >"$TEAM_HOME/tasks/current.md"
  run_bin -0 team-checkpoint --force
  assert_equal "$(changed_in dev)" "tasks/current.md"
  rm "$TEAM_HOME/tasks/current.md"
  run_bin -0 team-checkpoint --force
  assert_equal "$(changed_in dev)" "tasks/current.md"
  run -128 git -C "$team_origin" cat-file -e dev:tasks/current.md
  # What was staged is still staged, exactly, and the ignored files were never committed.
  assert_equal "$(git -C "$TEAM_HOME" diff --cached)" "$staged"
  assert_equal "$(git -C "$TEAM_HOME" diff --cached --name-only)" "README.md"
  assert_equal "$(git -C "$team_origin" ls-tree -r --name-only dev | grep -c -e settings -e mcp -e /ui/)" 0
  assert_equal "$(git -C "$TEAM_HOME" status --porcelain --untracked-files=all)" " M .gitignore
A  README.md"
}

@test "a drill team-drill records is committed and pushed by the next checkpoint, a record file of its own" {
  run_bin -0 team-checkpoint
  stub_reply claude '2.1.321 (Claude Code)'
  run_bin -0 team-drill record compaction --verdict pass
  run_bin -0 team-checkpoint --force
  assert_equal "$(git -C "$team_origin" log -1 --format=%s dev)" "chore: checkpoint"
  assert_equal "$(changed_in dev)" "drills.jsonl"
  assert_equal "$(git -C "$team_origin" show dev:drills.jsonl)" "$(cat "$TEAM_HOME/drills.jsonl")"
  # A second run's line goes in the next checkpoint.
  run_bin -0 team-drill record compaction --verdict fail
  run_bin -0 team-checkpoint --force
  assert_equal "$(changed_in dev)" "drills.jsonl"
  assert_equal "$(git -C "$team_origin" show dev:drills.jsonl | jq -r .verdict | paste -sd ' ')" "pass fail"
  assert_equal "$(git -C "$TEAM_HOME" status --porcelain)" ""
}

@test "a checkpoint stopped while it archives has already pushed the new ledger line" {
  run_bin -0 team-open home feature feat work "Do the work"
  echo "spec" >"$HOME/slots/home/1/.scratch/task/spec.md"
  local tip pid rc=0 n
  tip=$(team_tip)
  # An rsync that hangs, saying it started, until the test lets it go.
  cat >"$BATS_TEST_TMPDIR/stubs/rsync" <<STUB
#!/usr/bin/env bash
touch "$BATS_TEST_TMPDIR/rsync.started"
until [[ -e "$BATS_TEST_TMPDIR/rsync.release" ]]; do sleep 0.1; done
STUB
  chmod +x "$BATS_TEST_TMPDIR/stubs/rsync"

  timeout 60 "$REPO_ROOT/bin/team-checkpoint" >"$BATS_TEST_TMPDIR/out" 2>&1 &
  pid=$!
  for ((n = 0; n < 600; n++)); do [[ ! -e $BATS_TEST_TMPDIR/rsync.started ]] || break; sleep 0.1; done
  [[ -e $BATS_TEST_TMPDIR/rsync.started ]]
  # While the archive hangs, origin already has the ledger, alone, and nothing else.
  assert_equal "$(git -C "$team_origin" log -1 --format=%s dev)" "chore: checkpoint ledger"
  assert_equal "$(git -C "$team_origin" rev-parse dev^)" "$tip"
  assert_equal "$(changed_in dev)" "ledger.jsonl"
  assert_equal "$(git -C "$team_origin" show dev:ledger.jsonl | jq -r 'select(.event == "opened") | .task')" "T1"
  # Stopped there, as the heartbeat's time limit stops it: the ledger stays pushed.
  kill -TERM "$pid"
  wait "$pid" || rc=$?
  touch "$BATS_TEST_TMPDIR/rsync.release"
  ((rc != 0))
  assert_equal "$(git -C "$team_origin" log -1 --format=%s dev)" "chore: checkpoint ledger"
  [[ ! -e $state/last-checkpoint ]]
}

@test "a file the records hook refuses keeps only its task's group out: the ledger and the other task are pushed, and it goes in once fixed" {
  run_bin -0 team-open home feature feat work1 "Work 1"
  run_bin -0 team-open home feature feat work2 "Work 2"
  git -C "$TEAM_HOME" config core.hooksPath "$REPO_ROOT/bin/hooks/records-git"
  # No address at a real provider is written out (ci.yml's data job would refuse this file).
  local provider=gmail.com notes=$HOME/slots/home/1/.scratch/task/notes.md
  echo "reply to ann.applicant@$provider" >"$notes"
  echo "spec 2" >"$HOME/slots/home/2/.scratch/task/spec.md"
  echo "readme" >"$TEAM_HOME/README.md"
  git -C "$TEAM_HOME" add README.md

  run_bin -1 --separate-stderr team-checkpoint
  [[ $stderr == "team-checkpoint: team home: cannot commit tasks/T1/: data-check: refused: tasks/T1/scratch/notes.md adds an email address at a public provider"* ]]
  assert_equal "$(wc -l <<<"$stderr")" 1
  assert_contains "$output" "T1 home: pushed wip/home/T1"
  assert_contains "$output" "T2 home: pushed wip/home/T2"
  assert_equal "$(tail -n 1 <<<"$output")" "team home: committed $(git -C "$TEAM_HOME" rev-parse --short HEAD) chore: checkpoint tasks/T2/ and pushed dev"
  assert_equal "$(team_tip)" "$(git -C "$TEAM_HOME" rev-parse HEAD)"
  assert_equal "$(git -C "$team_origin" log -2 --format=%s dev)" "chore: checkpoint tasks/T2/
chore: checkpoint ledger"
  assert_equal "$(changed_in dev^)" "ledger.jsonl"
  assert_equal "$(changed_in dev)" "tasks/T2/plan.md
tasks/T2/scratch/spec.md"
  assert_equal "$(git -C "$team_origin" ls-tree -r --name-only dev tasks/T1)" ""
  [[ ! -e $state/last-checkpoint ]]
  assert_contains "$(git -C "$TEAM_HOME" diff --cached --name-only)" "README.md"

  # Fixed, the next checkpoint commits T1's task directory in the one commit, and exits 0.
  echo "reply to the applicant" >"$notes"
  run_bin -0 --separate-stderr team-checkpoint
  assert_equal "$stderr" ""
  assert_equal "$(git -C "$team_origin" log -1 --format=%s dev)" "chore: checkpoint"
  assert_equal "$(changed_in dev)" "tasks/T1/plan.md
tasks/T1/scratch/notes.md"
  assert_equal "$(git -C "$TEAM_HOME" diff --cached --name-only)" "README.md"
  [[ -f $state/last-checkpoint ]]
}

@test "a first commit that fails is said, and the worktrees are still checkpointed and the rest committed" {
  run_bin -0 team-open home feature feat work "Do the work"
  echo "spec" >"$HOME/slots/home/1/.scratch/task/spec.md"
  echo "new" >"$HOME/slots/home/1/new.txt"
  git -C "$TEAM_HOME" config core.hooksPath "$REPO_ROOT/bin/hooks/records-git"
  local provider=gmail.com tip refused
  tip=$(team_tip)
  jq -cn --arg reason "write to bo@$provider" '{ts: (now | todate), task: "T1", event: "waiting", on: "Daniel", reason: $reason}' \
    >>"$TEAM_HOME/ledger.jsonl"

  run_bin -1 --separate-stderr team-checkpoint
  refused="data-check: refused: ledger.jsonl adds an email address at a public provider"
  [[ $(sed -n 1p <<<"$stderr") == "team-checkpoint: team home: cannot commit the records: $refused"* ]]
  # The one commit fails on the ledger too, so its group is the one left out.
  [[ $(sed -n 2p <<<"$stderr") == "team-checkpoint: team home: cannot commit ledger: $refused"* ]]
  assert_equal "$(wc -l <<<"$stderr")" 2
  assert_contains "$output" "T1 home: archived .scratch/task to tasks/T1/scratch"
  assert_contains "$output" "T1 home: pushed wip/home/T1"
  assert_equal "$(git -C "$team_origin" show wip/home/T1:new.txt)" "new"
  assert_equal "$(git -C "$team_origin" log -1 --format=%s dev)" "chore: checkpoint tasks/T1/"
  assert_equal "$(git -C "$team_origin" rev-parse dev^)" "$tip"
  assert_equal "$(changed_in dev)" "tasks/T1/plan.md
tasks/T1/scratch/spec.md"
  [[ ! -e $state/last-checkpoint ]]
}

@test "it exports this machine's usage of each complete day into usage/<machine>/ and commits it" {
  cp -R "$BATS_TEST_DIRNAME/fixtures/team-tokens/projects" "$HOME/.claude/projects"
  run_bin -0 --separate-stderr team-checkpoint
  assert_equal "$output" "team home: nothing new in the ledger
usage: usage/home-pc/2026-10-20.jsonl: 1 reply, 1 new
usage: usage/home-pc/2026-10-21.jsonl: 3 replies, 3 new
usage: read 3 of 3 transcripts; wrote 2 day files
team home: committed $(git -C "$TEAM_HOME" rev-parse --short HEAD) chore: checkpoint and pushed dev"
  assert_equal "$(changed_in dev)" "usage/home-pc/2026-10-20.jsonl
usage/home-pc/2026-10-21.jsonl"
  # Nothing new: no commit.
  local tip
  tip=$(team_tip)
  run_bin -0 team-checkpoint --force
  assert_equal "$output" "team home: nothing new in the ledger
usage: read 0 of 3 transcripts; no day file changed
team home: nothing to commit"
  assert_equal "$(team_tip)" "$tip"
}

@test "a failed export is a warning and fails nothing: the records are still committed and pushed" {
  run_bin -0 team-open home feature feat work "Do the work"
  echo "spec" >"$HOME/slots/home/1/.scratch/task/spec.md"
  cp -R "$BATS_TEST_DIRNAME/fixtures/team-tokens/projects" "$HOME/.claude/projects"
  mkdir -p "$TEAM_HOME/usage/home-pc"
  echo "not json" >"$TEAM_HOME/usage/home-pc/2026-10-21.jsonl"
  run_bin -0 --separate-stderr team-checkpoint
  assert_equal "$stderr" "team-checkpoint: warning: usage: cannot export: $TEAM_HOME/usage/home-pc/2026-10-21.jsonl holds a line that is no usage line; fix or remove it; the next checkpoint exports it"
  assert_contains "$output" "team home: committed"
  assert_equal "$(changed_in dev)" "tasks/T1/plan.md
tasks/T1/scratch/spec.md
usage/home-pc/2026-10-20.jsonl
usage/home-pc/2026-10-21.jsonl"
  [[ -f $state/last-checkpoint ]]
}

@test "a rejected push is replayed onto origin's dev and pushed, keeping what is staged" {
  run_bin -0 team-open home feature feat work "Do the work"
  echo "spec" >"$HOME/slots/home/1/.scratch/task/spec.md"
  echo "readme" >"$TEAM_HOME/README.md"
  git -C "$TEAM_HOME" add README.md
  echo "untracked" >"$TEAM_HOME/notes.txt"
  make_machine laptop
  on_machine laptop bash -c 'echo "from laptop" >"$TEAM_HOME/manual-steps.md" &&
    git -C "$TEAM_HOME" add manual-steps.md && git -C "$TEAM_HOME" commit -q -m "docs: a manual step" &&
    git -C "$TEAM_HOME" push -q origin dev'
  local theirs staged
  theirs=$(team_tip) staged=$(git -C "$TEAM_HOME" diff --cached)

  run_bin -0 team-checkpoint
  assert_contains "$output" "team home: committed"
  # The ledger's commit, the first pushed, is the one replayed; the rest goes on top of it.
  assert_contains "$output" " chore: checkpoint ledger; origin's dev had moved; replayed onto it and pushed dev"
  assert_equal "$(git -C "$team_origin" rev-parse dev~2)" "$theirs"
  assert_equal "$(team_tip)" "$(git -C "$TEAM_HOME" rev-parse HEAD)"
  assert_equal "$(changed_in dev^)" "ledger.jsonl"
  assert_equal "$(changed_in dev)" "tasks/T1/plan.md
tasks/T1/scratch/spec.md"
  assert_equal "$(cat "$TEAM_HOME/manual-steps.md")" "from laptop"
  assert_equal "$(git -C "$TEAM_HOME" diff --cached)" "$staged"
  assert_equal "$(git -C "$TEAM_HOME" status --porcelain)" "A  README.md
?? notes.txt"
}

@test "a rejected push that cannot be replayed cleanly is left unpushed with a message, and goes out once it can" {
  run_bin -0 team-open home feature feat work "Do the work"
  echo "spec" >"$HOME/slots/home/1/.scratch/task/spec.md"
  # A local change outside the records, in the way of origin's new commit.
  echo "local readme" >"$TEAM_HOME/README.md"
  make_machine laptop
  on_machine laptop bash -c 'echo "from laptop" >"$TEAM_HOME/README.md" &&
    git -C "$TEAM_HOME" add README.md && git -C "$TEAM_HOME" commit -q -m "docs: a readme" &&
    git -C "$TEAM_HOME" push -q origin dev'
  local theirs mine
  theirs=$(team_tip)

  run_bin -1 --separate-stderr team-checkpoint
  mine=$(git -C "$TEAM_HOME" rev-parse HEAD)
  assert_contains "$output" "team home: committed ${mine:0:7} chore: checkpoint"
  assert_contains "$stderr" "team-checkpoint: team home: origin's dev has moved and the commits not on it cannot be replayed onto it (local changes to README.md are in the way); they stay unpushed"
  assert_equal "$(team_tip)" "$theirs"
  assert_equal "$(git -C "$TEAM_HOME" log -1 --format=%s)" "chore: checkpoint"
  assert_equal "$(cat "$TEAM_HOME/README.md")" "local readme"
  [[ ! -e $state/last-checkpoint ]]

  # Out of the way: nothing new to commit, and the commit left behind goes out.
  rm "$TEAM_HOME/README.md"
  run_bin -0 team-checkpoint
  assert_contains "$output" "team home: nothing new in the ledger; origin's dev had moved; replayed onto it and pushed dev"
  assert_contains "$output" "team home: nothing to commit"
  assert_equal "$(git -C "$team_origin" rev-parse dev~2)" "$theirs"
  assert_equal "$(git -C "$team_origin" log -2 --format=%s dev^)" "chore: checkpoint ledger
docs: a readme"
  assert_equal "$(git -C "$team_origin" log -1 --format=%s dev)" "chore: checkpoint"
  assert_equal "$(cat "$TEAM_HOME/README.md")" "from laptop"
}

@test "a replay whose branch moved between its build and its lock is refused, moving nothing, and the next push replays it" {
  run_bin -0 team-open home feature feat work "Do the work"
  make_machine laptop
  on_machine laptop bash -c 'echo "from laptop" >"$TEAM_HOME/manual-steps.md" &&
    git -C "$TEAM_HOME" add manual-steps.md && git -C "$TEAM_HOME" commit -q -m "docs: a manual step" &&
    git -C "$TEAM_HOME" push -q origin dev'
  # Another script commits on the branch once the replay has built its commits, before its lock.
  local real_git theirs
  real_git=$(command -v git)
  cat >"$BATS_TEST_TMPDIR/stubs/git" <<STUB
#!/usr/bin/env bash
"$real_git" "\$@"
rc=\$?
if [[ " \$* " == *" commit-tree "* && ! -e "$BATS_TEST_TMPDIR/moved" ]]; then
  touch "$BATS_TEST_TMPDIR/moved"
  echo "meanwhile" >"$TEAM_HOME/tasks/current.md"
  "$real_git" -C "$TEAM_HOME" add tasks/current.md
  "$real_git" -C "$TEAM_HOME" commit -q -m "chore: current" -- tasks/current.md
fi
exit \$rc
STUB
  chmod +x "$BATS_TEST_TMPDIR/stubs/git"
  theirs=$(team_tip)

  run_bin -0 --separate-stderr team-log T1 plan-approved by=Daniel
  assert_equal "$stderr" "team-log: the ledger is not on origin yet (origin's dev has moved and the commits not on it cannot be replayed onto it (the branch moved meanwhile; the next push replays it); they stay unpushed); the next checkpoint pushes it"
  [[ -e $BATS_TEST_TMPDIR/moved ]]
  # The branch is the other script's commit on the ledger's, and the working tree has none of origin's.
  assert_equal "$(git -C "$TEAM_HOME" log -2 --format=%s)" "chore: current
chore: ledger T1 plan-approved"
  [[ ! -e $TEAM_HOME/manual-steps.md ]]
  assert_equal "$(git -C "$TEAM_HOME" status --porcelain --untracked-files=no)" ""
  assert_equal "$(team_tip)" "$theirs"

  run_bin -0 team-checkpoint --force
  assert_contains "$output" "origin's dev had moved; replayed onto it and pushed dev"
  assert_equal "$(git -C "$team_origin" log --format=%s "$theirs..dev" | tail -n 2)" "chore: current
chore: ledger T1 plan-approved"
  assert_equal "$(cat "$TEAM_HOME/manual-steps.md")" "from laptop"
  assert_equal "$(team_tip)" "$(git -C "$TEAM_HOME" rev-parse HEAD)"
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
  run -1 git -C "$team_origin" rev-parse -q --verify refs/heads/wip/home/T1
  assert_equal "$(git -C "$TEAM_HOME" rev-parse HEAD)" "$head"
  assert_equal "$(team_tip)" "$tip"
  [[ ! -e $state/last-checkpoint ]]
}

@test "without --force it checkpoints only once the last checkpoint is 5 minutes old" {
  run_bin -0 team-open home feature feat work "Do the work"
  local wt=$HOME/slots/home/1
  echo "new" >"$wt/new.txt"
  mkdir -p "$state"
  touch -d '-3 minutes' "$state/last-checkpoint"
  run_bin -0 team-checkpoint
  assert_equal "$output" "not due: the last checkpoint was 3 minutes ago (--force makes one now)"
  run -1 git -C "$team_origin" rev-parse -q --verify refs/heads/wip/home/T1

  touch -d '-5 minutes' "$state/last-checkpoint"
  run_bin -0 team-checkpoint
  assert_contains "$output" "T1 home: pushed wip/home/T1"
  (($(date +%s) - $(date -r "$state/last-checkpoint" +%s) < 60))
}

@test "it needs a machine name, and refuses a malformed command line" {
  local args
  for args in --now "--deadline" "--deadline 1.5" "--deadline x" "--force --force" "--deadline 3 --deadline 4"; do
    # shellcheck disable=SC2086 # each case is its words
    run_bin -2 team-checkpoint $args
    assert_equal "$output" "team-checkpoint: usage: team-checkpoint [--force] [--deadline <seconds>]"
  done
  rm "$HOME/.config/agent-team/machine"
  run_bin -1 team-checkpoint
  assert_contains "$output" "this machine has no team name"
}
