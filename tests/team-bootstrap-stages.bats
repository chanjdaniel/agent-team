#!/usr/bin/env bats
# shellcheck disable=SC2153 # TOOL_STUBS, CONVENTIONER and the other globals are helpers/doctor.bash's
# team-bootstrap: a fresh machine set up stage by stage, on the machine tests/helpers/bootstrap.bash
# builds. This file: the tools stage's gate config, and the projects, config and heartbeat stages.

load helpers/common
load helpers/doctor
load helpers/bootstrap

setup() {
  sandbox
  bootstrap_machine
}

@test "tools: config.yaml's agent_path_override names the gate's wrapper by its full path, that key alone, its mode kept and none of it printed (report F7)" {
  tools_at arch
  local config=$HOME/.no-mistakes/config.yaml wrapper=$HOME/.no-mistakes/bin/opencode-gate stamp
  # The config restored from home-pc's 1Password document: its path, and a token.
  printf '%s\n' 'agent: opencode' 'api_key: fake-gate-token-123' 'agent_path_override:' \
    '  opencode: /home/danielc/.no-mistakes/bin/opencode-gate  # the gate' 'log_level: info' >"$config"
  chmod 640 "$config"
  cp -p "$config" "$BATS_TEST_TMPDIR/before"
  sed "4s#/home/danielc/.no-mistakes/bin/opencode-gate#$wrapper#" "$config" >"$BATS_TEST_TMPDIR/expected"

  # The check stage leaves it to the tools stage, not to Daniel.
  run_bin -1 team-bootstrap --stage check
  assert_equal "$(stage_lines check | grep -c '^Daniel' || true)" 0
  assert_equal "$(stage_lines check | tail -n1)" "summary: not set up yet: besides Daniel's steps above, these failed: opencode-gate; fix them as their doctor lines say, then team-bootstrap again"
  assert_contains "$output" "fix: $CODE_CHECKOUT/bin/team-bootstrap --stage tools, which sets agent_path_override: {opencode: $wrapper} in ~/.no-mistakes/config.yaml, that key alone"

  run_bin -0 team-bootstrap --stage tools --dry-run
  assert_equal "$output" "tools: would set agent_path_override.opencode in ~/.no-mistakes/config.yaml to $wrapper"
  cmp "$BATS_TEST_TMPDIR/before" "$config"

  run_bin -0 team-bootstrap --stage tools
  assert_equal "$output" "tools: set agent_path_override.opencode in ~/.no-mistakes/config.yaml to $wrapper, that key alone"
  cmp "$BATS_TEST_TMPDIR/expected" "$config"
  assert_equal "$(stat -c %a "$config")" 640
  assert_equal "$(find "$HOME/.no-mistakes" -name '.config.yaml.*')" ""
  [[ -z $(grep -rlF fake-gate-token "$HOME/.local/state" 2>/dev/null) ]]
  run_bin -0 team-bootstrap --stage check
  assert_equal "$(stage_lines check | tail -n1)" "summary: set up, and this machine holds the lease"

  # A config already naming the wrapper is left untouched.
  stamp=$(stat -c '%i %s %Y %a' "$config")
  run_bin -0 team-bootstrap --stage tools
  assert_equal "$output" "tools: done: every tool is at its pin or above its minimum"
  assert_equal "$(stat -c '%i %s %Y %a' "$config")" "$stamp"

  # A link stays a link, the file it names edited; one without the key and a last newline gains it.
  mkdir -p "$HOME/dotfiles"
  printf 'agent: opencode\napi_key: fake-gate-token-123' >"$HOME/dotfiles/config.yaml"
  ln -sf "$HOME/dotfiles/config.yaml" "$config"
  run_bin -0 team-bootstrap --stage tools
  [[ -L $config ]]
  assert_equal "$(cat "$HOME/dotfiles/config.yaml")" "agent: opencode
api_key: fake-gate-token-123
agent_path_override:
  opencode: $wrapper"

  # A form it does not edit is Daniel's, the file untouched.
  printf '%s\n' 'agent_path_override: {codex: /x,' '  opencode: /old}' >"$HOME/dotfiles/config.yaml"
  cp "$HOME/dotfiles/config.yaml" "$BATS_TEST_TMPDIR/before"
  run_bin -1 team-bootstrap --stage tools
  assert_equal "$output" "tools: Daniel: set agent_path_override.opencode in ~/.no-mistakes/config.yaml to $wrapper by hand: its agent_path_override is in a form team-bootstrap does not edit (a flow mapping over several lines, or a scalar); then team-bootstrap again"
  cmp "$BATS_TEST_TMPDIR/before" "$HOME/dotfiles/config.yaml"
  assert_equal "$(find "$HOME/dotfiles" "$HOME/.no-mistakes" -name '.config.yaml.*')" ""

  # A missing config is team-secrets restore's: the tools stage is done, and check lists it.
  rm "$config"
  run_bin -0 team-bootstrap --stage tools
  assert_equal "$output" "tools: done: every tool is at its pin or above its minimum"
  run_bin -1 team-bootstrap --stage check
  assert_equal "$(stage_lines check | grep '^Daniel')" "Daniel 1: opencode-gate: Daniel runs team-secrets restore in their own terminal (the secret no-mistakes-config), then $CODE_CHECKOUT/bin/team-bootstrap --stage tools sets agent_path_override: {opencode: $wrapper} in it (~/.no-mistakes/config.yaml is not there)"
}

@test "check lists each failing secret with its reason, so a wrong mode is never called missing" {
  tools_at arch
  chmod 644 "$HOME/$(jq -r '.secrets[0].target' "$TEAM_HOME/machine/secrets.json")"
  rm "$HOME/$(jq -r '.secrets[1].target' "$TEAM_HOME/machine/secrets.json")"
  run_bin -1 team-bootstrap --stage check
  assert_equal "$(stage_lines check | grep '^Daniel')" "Daniel 1: secrets: with the 1Password app signed in and its CLI integration on, in your own terminal, not through an agent: $CODE_CHECKOUT/bin/team-secrets restore (discord-bot-env: mode 644; discord-access-json: missing)"
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
