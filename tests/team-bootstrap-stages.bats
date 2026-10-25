#!/usr/bin/env bats
# shellcheck disable=SC2153 # TOOL_STUBS, CONVENTIONER and the other globals are helpers/doctor.bash's
# team-bootstrap: a fresh machine set up stage by stage, on the machine tests/helpers/bootstrap.bash
# builds. This file: the projects, config and heartbeat stages.

load helpers/common
load helpers/doctor
load helpers/bootstrap

setup() {
  sandbox
  bootstrap_machine
}

@test "projects are cloned from https://github.com/<repo>.git to their registry paths; a task directory git ignores is left alone; the gate is only no-mistakes'" {
  tools_at arch
  # site ignores its task directory itself.
  local work=$BATS_TEST_TMPDIR/site-work
  git clone -q "$BATS_TEST_TMPDIR/origin/site.git" "$work"
  echo /.scratch/ >"$work/.gitignore"
  git -C "$work" add .gitignore
  git -C "$work" commit -q -m "chore: ignore the task directory"
  git -C "$work" push -q origin HEAD
  rm -rf "$CONVENTIONER" "$SITE"
  : >"$STUB_FIXTURES/gates"
  run_bin -0 team-bootstrap
  assert_equal "$(stage_lines projects)" "running: git clone -q https://github.com/chanjdaniel/Conventioner.git ~/projects/Conventioner
running: echo /.scratch/task/ >>~/projects/Conventioner/.git/info/exclude
running: cd ~/projects/Conventioner && no-mistakes init
conventioner is set up in ~/projects/Conventioner
running: git clone -q https://github.com/owner/site.git ~/projects/site
site is set up in ~/projects/site"
  assert_equal "$(git -C "$CONVENTIONER" remote get-url origin)" https://github.com/chanjdaniel/Conventioner.git
  assert_equal "$(git -C "$SITE" remote get-url origin)" https://github.com/owner/site.git
  assert_equal "$(cat "$SITE/.git/info/exclude" | grep -c scratch)" 0
  assert_equal "$(git -C "$CONVENTIONER" status --porcelain)$(git -C "$SITE" status --porcelain)" ""
  # The new clones keep their auto memory in the team home, which the config stage sets up.
  assert_equal "$(stage_lines config)" "running: team-config apply"
  assert_equal "$(jq -r .autoMemoryDirectory "$SITE/.claude/settings.local.json")" "$TEAM_HOME/memory/site"
  [[ $output != *"WARN memory"* ]]

  # An origin set elsewhere is put back to the exact URL treehouse names its pool from.
  git -C "$SITE" remote set-url origin git@github.com:owner/site.git
  run_bin -0 team-bootstrap
  assert_equal "$(stage_lines projects)" "running: git -C ~/projects/site remote set-url origin https://github.com/owner/site.git
site is set up in ~/projects/site"
}

@test "a git pool's slots inside the checkout are ignored there once, so they never show as untracked in it" {
  tools_at arch
  register fork owner/fork direct-pr git projects/fork/.claude/worktrees/1 projects/fork/.claude/worktrees/2
  local fork=$HOME/projects/fork
  rm -rf "$fork"
  run_bin -0 team-bootstrap
  assert_equal "$(stage_lines projects)" "running: git clone -q https://github.com/owner/fork.git ~/projects/fork
running: echo /.scratch/task/ >>~/projects/fork/.git/info/exclude
running: echo /.claude/worktrees/ >>~/projects/fork/.git/info/exclude
fork is set up in ~/projects/fork"
  git -C "$fork" worktree add -q "$fork/.claude/worktrees/1"
  assert_equal "$(git -C "$fork" status --porcelain)" ""
  # A pool outside the checkout (site's) adds nothing.
  assert_equal "$(grep -c worktrees "$SITE/.git/info/exclude" || true)" 0
  # A dry run says so before the clone.
  rm -rf "$fork"
  run_bin -1 team-bootstrap --dry-run
  assert_contains "$output" "projects: would then set up fork's task directory exclude, its pool slots' exclude"
}

@test "config: the plugins first, apply only to add what is missing, and Discord off; a file changed here is Daniel's call" {
  tools_at arch
  # Discord on, mongodb-atlas missing.
  echo '[{"id": "discord@claude-plugins-official", "scope": "user", "enabled": true}]' >"$STUB_FIXTURES/plugins.json"
  rm -rf "$HOME/.claude/skills/tdd"
  run_bin -0 team-bootstrap
  assert_equal "$(stage_lines config)" "running: claude plugin install mongodb-atlas@claude-plugins-official --scope user
running: team-config apply
running: claude plugin disable discord@claude-plugins-official --scope user"
  [[ -f $HOME/.claude/skills/tdd/SKILL.md ]]
  assert_contains "$output" "check: Daniel 1: restart: exit this Claude Code session"

  # settings.json changed here: apply would replace it, so nothing is applied and it is listed.
  echo '{"model": "sonnet"}' >"$HOME/.claude/settings.json"
  rm -rf "$HOME/.claude/skills/tdd"
  run_bin -0 team-bootstrap
  assert_equal "$(stage_lines config)" "left as it is: settings.json differs here, and whether to apply or capture is Daniel's call
nothing to add: what differs is Daniel's call (the check stage lists it)"
  [[ ! -e $HOME/.claude/skills/tdd ]]
  assert_equal "$(jq -r .model "$HOME/.claude/settings.json")" sonnet
  assert_contains "$output" "check: Daniel 2: config: team-config diff --full, then team-config apply (take the team home's) or team-config capture (keep this machine's) (settings.json differs, skill tdd missing)"
}

@test "the heartbeat is left disabled on a machine that does not hold the lease, and the lease is never taken" {
  tools_at arch
  make_machine laptop
  "$REPO_ROOT/bin/team-lease" release >/dev/null
  on_machine laptop "$REPO_ROOT/bin/team-lease" take >/dev/null
  local lease
  lease=$(git -C "$BATS_TEST_TMPDIR/origin/agent-team.git" rev-parse lease)
  run_bin -0 team-bootstrap
  assert_equal "$(stage_lines heartbeat)" "running: team-timers disable"
  [[ ! -e $HOME/.config/systemd/user/agent-team-heartbeat.timer ]]
  assert_equal "$(tail -n1 <<<"$output")" "check: summary: ready as a standby; team-load-check proves a worker here, and to move the team here run team-resume --wait here, then say \"hand off\" to the coordinator on laptop once it says this machine is ready"
  run_bin -0 team-bootstrap
  assert_equal "$(stage_lines heartbeat)" "done: disabled until this machine takes the lease (team-resume enables it)"
  assert_equal "$(git -C "$BATS_TEST_TMPDIR/origin/agent-team.git" rev-parse lease)" "$lease"
}
