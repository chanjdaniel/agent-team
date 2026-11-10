#!/usr/bin/env bats
# shellcheck disable=SC2153 # LOCK and the other globals are helpers/doctor.bash's
# team-doctor: one PASS, WARN or FAIL line per thing this machine needs, on the machine
# tests/helpers/doctor.bash builds: every tool a version stub, the OS a stubbed uname.
# This file: the machine, team home, git hooks, guard hooks, records hooks, logins and Claude config
# lines, --json, and the checks of bin/lib/doctor.d/ in name order;
# team-doctor-*.bats hold the other lines.

load helpers/common
load helpers/doctor

setup() {
  sandbox
  doctor_machine
}

@test "without a machine name the machine line fails with the command that writes one" {
  only_checks 070-machine.sh 220-lease.sh
  tools_at arch
  rm "$HOME/.config/agent-team/machine"
  run_bin -1 team-doctor
  assert_equal "$(line_of machine)" "FAIL machine: this machine has no team name; fix: echo <name> > ~/.config/agent-team/machine"
  assert_equal "$(line_of lease)" "FAIL lease: this machine has no team name to read the lease with; fix: the machine line's fix, then run team-doctor again"
  echo Home_PC >"$HOME/.config/agent-team/machine"
  run_bin -1 team-doctor
  assert_equal "$(line_of machine)" "FAIL machine: ~/.config/agent-team/machine names 'Home_PC', not a lower-case kebab-case name like home-pc; fix: echo <name> > ~/.config/agent-team/machine"
}

@test "the git hooks line fails unless the code checkout's own core.hooksPath is bin/hooks/git, with Daniel's command" {
  only_checks 090-git-hooks.sh
  tools_at arch
  run_bin -0 team-doctor
  assert_equal "$(line_of 'git hooks')" "PASS git hooks: core.hooksPath is bin/hooks/git"
  local fix="fix: Daniel runs git -C $CODE_CHECKOUT config core.hooksPath bin/hooks/git"
  git -C "$CODE_CHECKOUT" config core.hooksPath .git/hooks
  run_bin -1 team-doctor
  assert_equal "$(line_of 'git hooks')" "FAIL git hooks: core.hooksPath is .git/hooks, not bin/hooks/git; $fix"
  # Set only globally, it does not count: the guard is the code checkout's.
  git -C "$CODE_CHECKOUT" config --unset core.hooksPath
  git config --global core.hooksPath bin/hooks/git
  run_bin -1 team-doctor
  assert_equal "$(line_of 'git hooks')" "FAIL git hooks: core.hooksPath is unset, so git runs none of bin/hooks/git; $fix"
  git config --global --unset core.hooksPath
  # Nor in the team home: the code checkout is the one the line reads.
  git -C "$TEAM_HOME" config core.hooksPath bin/hooks/git
  run_bin -1 team-doctor
  assert_equal "$(line_of 'git hooks')" "FAIL git hooks: core.hooksPath is unset, so git runs none of bin/hooks/git; $fix"
  # Under HOME, the command names the code checkout from ~.
  mv "$CODE_CHECKOUT" "$HOME/agent-team"
  CODE_CHECKOUT=$HOME/agent-team run_bin -1 team-doctor
  assert_equal "$(line_of 'git hooks')" \
    "FAIL git hooks: core.hooksPath is unset, so git runs none of bin/hooks/git; fix: Daniel runs git -C ~/agent-team config core.hooksPath bin/hooks/git"
}

# Put <hook> of the code checkout's bin/hooks/ in place of its shared copy, as the Bash read from
# stdin: guard_is <hook>
guard_is() {
  local hook=$CODE_CHECKOUT/bin/hooks/$1
  rm "$hook"
  { echo '#!/usr/bin/env bash'; cat; } >"$hook"
  chmod +x "$hook"
}

@test "the guard hooks line runs each guard on a harmless Bash call and fails naming each one that does not pass" {
  only_checks 092-guard-hooks.sh
  tools_at arch
  local passes="PASS guard hooks: scratch-only-edits, command-guard, lease-fence and lease-fence --coordinator each pass a harmless Bash call (ls)"
  run_bin -0 team-doctor
  assert_equal "$(line_of 'guard hooks')" "$passes"
  # --json gives the line too.
  run_bin -0 --separate-stderr team-doctor --json
  jq -e '.[] | select(.check == "guard hooks") | .verdict == "PASS" and .fix == ""' <<<"$output"
  # With no team home named, each still decides on ls: lease-fence refuses only what the lease decides.
  rm "$HOME/.config/agent-team/home"
  run env -u TEAM_HOME "$CODE_CHECKOUT/bin/team-doctor"
  assert_equal "$(line_of 'guard hooks')" "$passes"
  echo "$TEAM_HOME" >"$HOME/.config/agent-team/home"
  # A command of its own that fails inside scratch-only-edits (its read of the cwd) ends as the
  # guard's refusal, which the line quotes; the other guards still pass.
  fails_on_call jq '.cwd // empty'
  run_bin -1 team-doctor
  local fix="fix: fix each hook named in $CODE_CHECKOUT/bin/hooks, then run team-doctor again"
  assert_equal "$(line_of 'guard hooks')" "FAIL guard hooks: on a harmless Bash call (ls), scratch-only-edits exited 2 (\"Blocked by scratch-only-edits: it failed with exit 5 before it could decide, and a guard that cannot decide refuses; report it as BLOCKED and do not reach it another way.\"), so each blocks every call it guards; $fix"
  rm "$BATS_TEST_TMPDIR/stubs/jq"
  # A guard that dies on its own, with or without a word on stderr, and one past its timeout.
  guard_is scratch-only-edits <<<'echo "line 3: broken" >&2; echo more >&2; exit 1'
  guard_is command-guard <<<'exit 127'
  guard_is lease-fence <<<'[[ $# -eq 0 ]] || exit 124; exit 0'
  run_bin -1 team-doctor
  assert_equal "$(line_of 'guard hooks')" "FAIL guard hooks: on a harmless Bash call (ls), scratch-only-edits exited 1 (\"line 3: broken\"); command-guard exited 127; lease-fence --coordinator did not answer within its 60 s, so each blocks every call it guards; $fix"
}

@test "the team home line names the team home and what named it: TEAM_HOME or ~/.config/agent-team/home" {
  only_checks 080-team-home.sh
  tools_at arch
  run_bin -0 team-doctor
  assert_equal "$(line_of 'team home')" "PASS team home: $TEAM_HOME, named by TEAM_HOME: a checkout of its own on dev, with an origin"
  # The setting, relative to HOME: the doctor finds the team home as every script does.
  mv "$TEAM_HOME" "$HOME/agent-team-records"
  echo agent-team-records >"$HOME/.config/agent-team/home"
  unset TEAM_HOME
  run "$CODE_CHECKOUT/bin/team-doctor"
  assert_equal "$(line_of 'team home')" \
    "PASS team home: ~/agent-team-records, named by ~/.config/agent-team/home: a checkout of its own on dev, with an origin"
  # TEAM_HOME wins over the setting.
  echo elsewhere >"$HOME/.config/agent-team/home"
  TEAM_HOME=$HOME/agent-team-records run "$CODE_CHECKOUT/bin/team-doctor"
  assert_equal "$(line_of 'team home')" \
    "PASS team home: ~/agent-team-records, named by TEAM_HOME: a checkout of its own on dev, with an origin"
}

@test "the records hooks line fails unless the team home's own core.hooksPath is the code's records-git, by absolute path" {
  only_checks 095-records-hooks.sh
  tools_at arch
  local want=$CODE_CHECKOUT/bin/hooks/records-git
  local fix="fix: Daniel runs git -C $TEAM_HOME config core.hooksPath $want"
  git -C "$TEAM_HOME" config --unset core.hooksPath || true
  run_bin -1 team-doctor
  assert_equal "$(line_of 'records hooks')" \
    "FAIL records hooks: the team home's core.hooksPath is unset, so git runs no data check on its commits; $fix"
  # The code's own hooks are the wrong ones for the records.
  git -C "$TEAM_HOME" config core.hooksPath bin/hooks/git
  run_bin -1 team-doctor
  assert_equal "$(line_of 'records hooks')" \
    "FAIL records hooks: the team home's core.hooksPath is bin/hooks/git, not $want; $fix"
  git -C "$TEAM_HOME" config core.hooksPath "$want/"
  run_bin -0 team-doctor
  assert_equal "$(line_of 'records hooks')" "PASS records hooks: the team home's core.hooksPath is $want"
  # Run from a worktree of the code, the line still names the primary checkout's hooks.
  git -C "$CODE_CHECKOUT" checkout -q -b feat/T1-thing
  git -C "$CODE_CHECKOUT" add -A
  git -C "$CODE_CHECKOUT" commit -q -m "chore: the code"
  git -C "$CODE_CHECKOUT" worktree add -q "$BATS_TEST_TMPDIR/wt" -b feat/T2-other
  CODE_CHECKOUT=$BATS_TEST_TMPDIR/wt run_bin team-doctor
  assert_equal "$(line_of 'records hooks')" "PASS records hooks: the team home's core.hooksPath is $want"
}

@test "with neither TEAM_HOME nor the setting, the team home line fails with the setting's fix" {
  only_checks 080-team-home.sh 085-team-home-fetch.sh 087-team-home-pack.sh 095-records-hooks.sh 180-records.sh 185-trust-team-home.sh 240-heartbeat.sh
  tools_at arch
  rm "$HOME/.config/agent-team/home"
  unset TEAM_HOME
  run -1 "$CODE_CHECKOUT/bin/team-doctor"
  # With no ~/agent-team-records the fix clones it first, since the setting would name a missing directory.
  assert_equal "$(line_of 'team home')" \
    "FAIL team home: neither TEAM_HOME nor ~/.config/agent-team/home names one; fix: clone the team home, then name it: git clone --single-branch --branch dev https://github.com/chanjdaniel/agent-team-records.git ~/agent-team-records && git -C ~/agent-team-records remote set-branches --add origin lease && echo agent-team-records > ~/.config/agent-team/home"
  # With no team home there is no fetch or pack to check.
  assert_equal "$(line_of 'team home fetch')" ""
  assert_equal "$(line_of 'team home pack')" ""
  mkdir "$HOME/agent-team-records"
  # The whole doctor, since the heartbeat line shows every check before it ran to its end with no
  # team home.
  TEAM_DOCTOR_CHECKS='' run -1 "$CODE_CHECKOUT/bin/team-doctor"
  assert_equal "$(line_of 'team home')" \
    "FAIL team home: neither TEAM_HOME nor ~/.config/agent-team/home names one; fix: name the team home's checkout, relative to your home directory: echo agent-team-records > ~/.config/agent-team/home"
  # The doctor goes on, the lines that read the team home failing with the same refusal.
  assert_contains "$(line_of records)" "FAIL records: "
  assert_equal "$(line_of 'records hooks')" \
    "FAIL records hooks: no team home to read it from (the team home line); fix: the team home line's fix, then run team-doctor again"
  assert_equal "$(line_of 'trust team home')" "WARN trust team home: not probed, since no team home is named; fix: the team home line's fix"
  assert_contains "$(line_of heartbeat)" "heartbeat: "
  assert_contains "$output" "neither TEAM_HOME nor ~/.config/agent-team/home names the team home; name its checkout there"
}

@test "a team home that is missing, no checkout of its own, without an origin or on a detached HEAD fails the team home line" {
  only_checks 080-team-home.sh
  tools_at arch
  local home=$TEAM_HOME named="named by TEAM_HOME" tmp
  tmp=$BATS_TEST_TMPDIR
  # Missing, named by the variable or by the setting (which no other script gets past).
  TEAM_HOME=$tmp/gone run_bin -1 team-doctor
  assert_equal "$(line_of 'team home')" \
    "FAIL team home: $tmp/gone, $named, is not a directory; fix: clone the team home to $tmp/gone, or set TEAM_HOME to its checkout"
  echo agent-team-records >"$HOME/.config/agent-team/home"
  run -1 env -u TEAM_HOME "$CODE_CHECKOUT/bin/team-doctor"
  assert_equal "$(line_of 'team home')" \
    "FAIL team home: ~/agent-team-records, named by ~/.config/agent-team/home, is not a directory; fix: clone the team home to ~/agent-team-records, or name the team home's checkout, relative to your home directory: echo agent-team-records > ~/.config/agent-team/home"
  : >"$HOME/.config/agent-team/home"
  run -1 env -u TEAM_HOME "$CODE_CHECKOUT/bin/team-doctor"
  assert_equal "$(line_of 'team home')" \
    "FAIL team home: the setting ~/.config/agent-team/home names no team home; fix: name the team home's checkout, relative to your home directory: echo agent-team-records > ~/.config/agent-team/home"
  # The code checkout, a checkout with an origin of its own, holds no records.
  git -C "$CODE_CHECKOUT" remote add origin https://github.com/chanjdaniel/agent-team.git
  TEAM_HOME=$CODE_CHECKOUT run_bin -1 team-doctor
  assert_equal "$(line_of 'team home')" \
    "FAIL team home: $CODE_CHECKOUT, $named, is the code checkout, which holds no records; fix: clone the team home to ~/agent-team-records, then name the team home's checkout, relative to your home directory: echo agent-team-records > ~/.config/agent-team/home"
  # A plain directory, a subdirectory of a checkout, and a worktree of another checkout.
  mkdir -p "$tmp/plain" "$home/tasks"
  TEAM_HOME=$tmp/plain run_bin -1 team-doctor
  assert_equal "$(line_of 'team home')" \
    "FAIL team home: $tmp/plain, $named, is not a git checkout of its own; fix: move it aside, then clone the team home to $tmp/plain"
  TEAM_HOME=$home/tasks run_bin -1 team-doctor
  assert_equal "$(line_of 'team home')" \
    "FAIL team home: $home/tasks, $named, is not a git checkout of its own; fix: move it aside, then clone the team home to $home/tasks"
  git -C "$home" worktree add -q "$tmp/wt"
  TEAM_HOME=$tmp/wt run_bin -1 team-doctor
  assert_equal "$(line_of 'team home')" \
    "FAIL team home: $tmp/wt, $named, is a worktree of $home, not a checkout of its own; fix: move it aside, then clone the team home to $tmp/wt"
  # No origin, then a detached HEAD.
  git -C "$home" remote rename origin elsewhere
  run_bin -1 team-doctor
  assert_equal "$(line_of 'team home')" \
    "FAIL team home: $home, $named, has no remote origin; fix: git -C $home remote add origin <the team home's repository URL>"
  git -C "$home" remote rename elsewhere origin
  git -C "$home" checkout -q --detach
  run_bin -1 team-doctor
  assert_equal "$(line_of 'team home')" \
    "FAIL team home: $home, $named, is on a detached HEAD, so its records would be committed on no branch; fix: git -C $home switch dev"
}

@test "the team home pack line counts the loose objects, and warns at twice the heartbeat's 200 with the fix" {
  only_checks 087-team-home-pack.sh
  tools_at arch
  local home=$TEAM_HOME
  run_bin -0 team-doctor
  [[ $(line_of 'team home pack') =~ ^"PASS team home pack: "[0-9]+" loose objects (the heartbeat packs it at 200), "[0-9.]+" "(bytes|KiB)" in packs"$ ]]
  add_loose 400
  run_bin -0 team-doctor
  [[ $(line_of 'team home pack') =~ ^"WARN team home pack: "[0-9]+" loose objects, ".*" in packs; the lease holder's heartbeat packs it at 200 (team-timers run's pack step); fix: git -C $home gc --quiet"$ ]]
  eval "$(line_of 'team home pack' | sed 's/.*; fix: //')"
  run_bin -0 team-doctor
  [[ $(line_of 'team home pack') =~ ^"PASS team home pack: 0 loose objects (the heartbeat packs it at 200), "[0-9.]+" KiB in packs"$ ]]
}

@test "the team home fetch line passes on a team home cloned to fetch only dev and lease, as SETUP.md clones it" {
  only_checks 085-team-home-fetch.sh
  tools_at arch
  local origin=$BATS_TEST_TMPDIR/origin/agent-team.git clone=$HOME/agent-team-records
  git -C "$origin" branch wip/home/T1 dev
  git clone -q --single-branch --branch dev "$origin" "$clone"
  git -C "$clone" remote set-branches --add origin lease
  git -C "$clone" fetch -q origin
  assert_equal "$(git -C "$clone" for-each-ref --format='%(refname)' refs/remotes | grep -v '/HEAD$')" "refs/remotes/origin/dev
refs/remotes/origin/lease"
  TEAM_HOME=$clone run_bin team-doctor
  assert_equal "$(line_of 'team home fetch')" "PASS team home fetch: fetches only dev and lease"
}

@test "the team home fetch line warns on a team home that fetches every branch, or keeps another's remote-tracking branch, with the fix" {
  only_checks 085-team-home-fetch.sh
  tools_at arch
  local origin=$BATS_TEST_TMPDIR/origin/agent-team.git home=$TEAM_HOME
  run_bin -0 team-doctor
  assert_equal "$(line_of 'team home fetch')" "PASS team home fetch: fetches only dev and lease"
  # A default clone's refspec, and the wip/* and salvage/* branches it fetched.
  git -C "$origin" branch wip/home/T1 dev
  git -C "$origin" branch salvage/home/T1-laptop dev
  git -C "$home" config --replace-all remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  git -C "$home" fetch -q origin
  run_bin -0 team-doctor
  assert_equal "$(line_of 'team home fetch')" \
    "WARN team home fetch: fetches +refs/heads/*:refs/remotes/origin/*, not only dev and lease, and keeps origin/salvage/home/T1-laptop, origin/wip/home/T1; fix: git -C $home remote set-branches origin dev lease && git -C $home branch -r -d origin/salvage/home/T1-laptop origin/wip/home/T1"
  # The fix, run: the line passes, and a fetch brings no wip/* again.
  eval "$(line_of 'team home fetch' | sed 's/.*; fix: //')"
  git -C "$home" fetch -q origin
  run_bin -0 team-doctor
  assert_equal "$(line_of 'team home fetch')" "PASS team home fetch: fetches only dev and lease"
  assert_equal "$(git -C "$home" for-each-ref --format='%(refname)' refs/remotes | grep -v '/HEAD$')" "refs/remotes/origin/dev
refs/remotes/origin/lease"
  # Narrowed, but a leftover branch kept, or a refspec missing.
  git -C "$home" update-ref refs/remotes/origin/wip/home/T1 dev
  git -C "$home" remote set-branches origin dev
  run_bin -0 team-doctor
  assert_equal "$(line_of 'team home fetch')" \
    "WARN team home fetch: fetches +refs/heads/dev:refs/remotes/origin/dev, not only dev and lease, and keeps origin/wip/home/T1; fix: git -C $home remote set-branches origin dev lease && git -C $home branch -r -d origin/wip/home/T1"
  git -C "$home" remote set-branches origin dev lease
  run_bin -0 team-doctor
  assert_equal "$(line_of 'team home fetch')" \
    "WARN team home fetch: keeps origin/wip/home/T1; fix: git -C $home branch -r -d origin/wip/home/T1"
  git -C "$home" config --unset-all remote.origin.fetch
  git -C "$home" branch -q -r -d origin/wip/home/T1
  run_bin -0 team-doctor
  assert_equal "$(line_of 'team home fetch')" \
    "WARN team home fetch: fetches no branch, not only dev and lease; fix: git -C $home remote set-branches origin dev lease"
}

@test "the team home fetch line is left out while the team home line fails" {
  only_checks 085-team-home-fetch.sh
  tools_at arch
  git -C "$TEAM_HOME" remote rename origin elsewhere
  run_bin -1 team-doctor
  assert_equal "$(line_of 'team home fetch')" ""
}

@test "Claude Code signed out, or signed in without a claude.ai account, fails the claude login line" {
  only_checks 100-claude-login.sh
  tools_at arch
  stub_script claude <<'EOF'
echo '{"loggedIn": false, "authMethod": "none"}'
exit 1
EOF
  run_bin -1 team-doctor
  assert_equal "$(line_of 'claude login')" "FAIL claude login: not signed in; fix: claude auth login --claudeai"

  stub_script claude <<'EOF'
echo '{"loggedIn": true, "authMethod": "api_key", "apiProvider": "firstParty"}'
EOF
  run_bin -1 team-doctor
  assert_equal "$(line_of 'claude login')" "FAIL claude login: signed in through api_key, not a claude.ai account; fix: claude auth logout, then claude auth login --claudeai"

  stub_script claude <<'EOF'
echo "unexpected" >&2
exit 3
EOF
  run_bin -1 team-doctor
  assert_equal "$(line_of 'claude login')" "FAIL claude login: \`claude auth status\` did not answer (exit 3); fix: install Claude Code (see tool claude), then claude auth login --claudeai"
}

@test "gh signed out fails the github login line" {
  only_checks 110-github-login.sh
  tools_at arch
  stub_script gh <<'EOF'
echo "You are not logged into any GitHub hosts. To log in, run: gh auth login" >&2
exit 1
EOF
  run_bin -1 team-doctor
  assert_equal "$(line_of 'github login')" "FAIL github login: gh auth status finds no working login for github.com; fix: gh auth login --hostname github.com --git-protocol https --web"
}

@test "the config line warns on each difference but the plugins, with team-config's commands" {
  only_checks 120-config.sh
  tools_at arch
  run_bin -0 team-doctor
  assert_equal "$(line_of config)" "PASS config: this machine's Claude config is the team home's"
  echo '{"model": "sonnet"}' >"$HOME/.claude/settings.json"
  rm -r "$HOME/.claude/skills/tdd"
  echo '[{"id": "discord@claude-plugins-official", "scope": "user", "enabled": false}]' >"$STUB_FIXTURES/plugins.json"
  run_bin -1 team-doctor
  assert_equal "$(line_of config)" "WARN config: settings.json differs, skill tdd missing; fix: team-config diff --full, then team-config apply (take the team home's) or team-config capture (keep this machine's)"
  # Without the team home's config, the line says what team-config said.
  rm -r "$TEAM_HOME/machine/claude"
  run_bin -1 team-doctor
  assert_equal "$(line_of config)" "WARN config: no machine/claude/ in $TEAM_HOME; run team-config capture on the machine whose config the team shares; fix: fix what team-config names, then run team-doctor again"
  assert_contains "$(line_of plugins)" "FAIL plugins: unknown, since team-config diff did not answer: no machine/claude/"
}

@test "the plugins line fails on each marketplace or plugin of plugins.txt missing here, with the commands that add them" {
  only_checks 120-config.sh
  tools_at arch
  run_bin -0 team-doctor
  assert_equal "$(line_of plugins)" "PASS plugins: every marketplace and plugin of plugins.txt is installed"
  echo '[]' >"$STUB_FIXTURES/marketplaces.json"
  echo '[{"id": "discord@claude-plugins-official", "scope": "user", "enabled": false},
    {"id": "ponder@claude-plugins-official", "scope": "user", "enabled": true}]' >"$STUB_FIXTURES/plugins.json"
  run_bin -1 team-doctor
  assert_equal "$(line_of plugins)" "FAIL plugins: missing marketplace anthropics/claude-plugins-official, plugin mongodb-atlas@claude-plugins-official; fix: claude plugin marketplace add anthropics/claude-plugins-official; claude plugin install mongodb-atlas@claude-plugins-official --scope user"
  # A plugin installed here only is a config difference, not a failure.
  assert_equal "$(line_of config)" "WARN config: plugin ponder@claude-plugins-official not in plugins.txt; fix: team-config diff --full, then team-config apply (take the team home's) or team-config capture (keep this machine's)"
  echo 'not json' >"$STUB_FIXTURES/plugins.json"
  run_bin -1 team-doctor
  assert_equal "$(line_of plugins)" "FAIL plugins: \`claude plugin list\` did not answer; fix: install Claude Code and sign in (the tool claude and claude login lines)"
}

@test "the memory line warns on each project whose auto memory is not in the team home, with team-config apply" {
  only_checks 120-config.sh
  tools_at arch
  run_bin -0 team-doctor
  assert_equal "$(line_of memory)" "PASS memory: every project here keeps its auto memory in the team home"
  local conv=$HOME/projects/conv key
  register conv owner/conv direct-pr git
  key=${conv//[^A-Za-z0-9]/-}
  mkdir -p "$HOME/.claude/projects/$key/memory"
  echo "Deploys go through CI." >"$HOME/.claude/projects/$key/memory/deploys.md"
  run_bin -0 team-doctor
  assert_equal "$(line_of memory)" "WARN memory: memory conv setting missing, memory conv settings.local.json not ignored by git, memory conv notes left in ~/.claude/projects/$key/memory/; fix: team-config apply"
  # The config line is about the Claude config alone.
  assert_equal "$(line_of config)" "PASS config: this machine's Claude config is the team home's"
  "$REPO_ROOT/bin/team-config" apply >/dev/null
  run_bin -0 team-doctor
  assert_equal "$(line_of memory)" "PASS memory: every project here keeps its auto memory in the team home"
  # team-config not answering leaves the line unknown.
  echo 'junk = [' >>"$TEAM_HOME/projects.toml"
  run_bin -1 team-doctor
  assert_contains "$(line_of memory)" "WARN memory: unknown, since team-config diff did not answer: "
}

@test "the discord line fails while user settings turn the Discord plugin on, and asks claude from /" {
  # With the plugins line, whose FAIL is the third run's exit 1.
  only_checks 120-config.sh 130-discord.sh
  tools_at arch
  run_bin -0 team-doctor
  assert_equal "$(line_of discord)" "PASS discord: the Discord plugin is off in user settings"
  echo '[{"id": "discord@claude-plugins-official", "scope": "user", "enabled": true},
    {"id": "mongodb-atlas@claude-plugins-official", "scope": "user", "enabled": true}]' >"$STUB_FIXTURES/plugins.json"
  echo 'echo "$PWD" >>"$STUB_CALLS/claude.pwd"' >>"$STUB_FIXTURES/claude.sh"
  run_bin -1 team-doctor
  assert_equal "$(line_of discord)" "FAIL discord: the Discord plugin is on in user settings, so every session logs in to Discord; fix: claude plugin disable discord@claude-plugins-official --scope user"
  grep -qx / "$STUB_CALLS/claude.pwd"
  echo '[{"id": "mongodb-atlas@claude-plugins-official", "scope": "user", "enabled": true}]' >"$STUB_FIXTURES/plugins.json"
  run_bin -1 team-doctor
  assert_equal "$(line_of discord)" "PASS discord: the Discord plugin is not installed, so it is off (the plugins line says whether it should be)"
  echo 'not json' >"$STUB_FIXTURES/plugins.json"
  run_bin -1 team-doctor
  assert_equal "$(line_of discord)" "FAIL discord: \`claude plugin list\` printed no plugin list (exit 0); fix: install Claude Code and sign in (the tool claude and claude login lines)"
}

@test "the own settings line warns while this machine has no autoMode.environment of its own" {
  only_checks 140-own-settings.sh
  tools_at arch
  run_bin -0 team-doctor
  assert_equal "$(line_of 'own settings')" "PASS own settings: autoMode.environment set for this machine"
  echo '{"model": "opus"}' >"$HOME/.claude/settings.json"
  run_bin -0 team-doctor
  assert_equal "$(line_of 'own settings')" "WARN own settings: autoMode.environment not set here, so auto mode's classifier knows nothing of this machine; fix: write this machine's own in ~/.claude/settings.json (\`claude auto-mode defaults\` shows the form); team-config keeps it"
  echo 'not json' >"$HOME/.claude/settings.json"
  run_bin -0 team-doctor
  assert_equal "$(line_of 'own settings')" "WARN own settings: $HOME/.claude/settings.json is not JSON; fix: fix what team-config names, then run team-doctor again"
}

@test "--json prints one array of {check, verdict, reason, fix}, the same verdicts as the lines" {
  tools_at arch
  answer "jq --version" "jq-1.6"
  run_bin -1 team-doctor
  local text=$output
  run_bin -1 --separate-stderr team-doctor --json
  jq -e 'type == "array" and all(.[]; keys == ["check", "fix", "reason", "verdict"] and (.verdict | IN("PASS", "WARN", "FAIL")))' <<<"$output"
  assert_equal "$(jq -r '.[] | "\(.verdict) \(.check)"' <<<"$output")" "$(sed -E 's/^(....) ([^:]+): .*/\1 \2/' <<<"$text")"
  jq -e '.[] | select(.check == "tool jq") == {check: "tool jq", verdict: "FAIL", reason: "1.6, below the minimum 1.7.1", fix: "sudo pacman -S --needed jq"}' <<<"$output"
  jq -e '.[] | select(.check == "machine") == {check: "machine", verdict: "PASS", reason: "home-pc", fix: ""}' <<<"$output"
}

@test "no line carries a secret, and the doctor reads no credential file, ~/.claude.json or ~/.claude/channels/ but access.json" {
  tools_at arch
  echo '{"claudeAiOauth": {"accessToken": "sk-ant-oat-fake-secret"}}' >"$HOME/.claude/.credentials.json"
  echo '{"oauthAccount": {"emailAddress": "daniel@example.invalid"}}' >"$HOME/.claude.json"
  mkdir -p "$HOME/.config/gh"
  echo 'github.com: {oauth_token: gho_fakefakefakefake}' >"$HOME/.config/gh/hosts.yml"
  run_bin -0 team-doctor
  local text=$output
  run_bin -0 team-doctor --json
  local secret
  for secret in sk-ant-oat-fake-secret daniel@example.invalid org-secret-0000 gho_fakefakefakefake "$FAKE_DISCORD_TOKEN" dummy-secret-value "$DANIEL_ID"; do
    [[ $text$output != *"$secret"* ]] || { echo "the doctor printed $secret" >&2; return 1; }
  done
  # The code, its comments aside, names none of them, but the Discord plugin's access.json, whose
  # ids the discord access line never prints.
  local interview=$REPO_ROOT/bin/lib/doctor.d/167-interview-channel.sh
  run -1 grep -nE 'credentials|\.claude\.json|channels|hosts\.yml|discord_|[Kk]eychain|security find' \
    <(for file in "$REPO_ROOT/bin/team-doctor" "$REPO_ROOT"/bin/lib/doctor.d/*.sh; do
      [[ $file == "$interview" ]] || grep -hv '^[[:space:]]*#' "$file"; done |
      sed 's|~/\.claude/channels/discord/access\.json||g; s|\$HOME/\.claude/channels/discord/access\.json||g')
  # The interview channel line alone uses the bot token, only through the library's Discord calls.
  run -1 grep -nE 'credentials|\.claude\.json|hosts\.yml|[Kk]eychain|security find|DISCORD_BOT_TOKEN=|\.env"' "$interview"
  assert_equal "$(grep -v '^[[:space:]]*#' "$interview" | grep -oE 'discord_[a-z_]+' | sort -u | paste -sd ' ')" "discord_api discord_token"
}

@test "each file of bin/lib/doctor.d/ is a check, run in the order of its name, with its lines of --help" {
  tools_at arch
  # The sandbox's doctor.d/ is a directory of its own, its files links: add files, never edit one.
  local checks_dir=$CODE_CHECKOUT/bin/lib/doctor.d
  printf '%s\n' '# early         A check dropped in between the first two.' '# shellcheck shell=bash' '' \
    'report early PASS "after os"' >"$checks_dir/015-early.sh"
  printf '%s\n' '# late          A check dropped in after the last,' '#               on two lines.' '# shellcheck shell=bash' '' \
    'report late WARN "after offline" "nothing"' >"$checks_dir/999-late.sh"
  run_bin -0 team-doctor
  assert_equal "$(checks | head -n 2)" $'os\nearly'
  assert_equal "$(checks | tail -n 2)" $'offline\nlate'
  assert_equal "$(line_of late)" "WARN late: after offline; fix: nothing"
  local order
  order=$(checks)
  run_bin -0 --separate-stderr team-doctor --json
  assert_equal "$(jq -r '.[].check' <<<"$output")" "$order"
  run_bin -0 team-doctor --help
  assert_equal "$(grep -A 2 '^  os  ' <<<"$output" | tail -n 1)" "  early         A check dropped in between the first two."
  assert_equal "$(tail -n 2 <<<"$output")" $'  late          A check dropped in after the last,\n                on two lines.'
}

@test "TEAM_DOCTOR_CHECKS runs the checks it names and those they read state from, each line as in a whole run, and refuses a name that is no check" {
  tools_at arch
  run_bin -0 team-doctor
  local whole=$output check read reads own declared
  local -A alone=()
  # Each check alone prints lines of the whole run, in its order: its own (none for the Homebrew
  # and power checks on Arch, nor the salvage check with nothing to salvage) and those it reads
  # state from. A check that prints nothing without its state (the docker check with no os, say)
  # shows a lost reads line by printing no line of its own, so each other check must print one
  # beyond those its declared checks print alone.
  for check in "$CODE_CHECKOUT"/bin/lib/doctor.d/*.sh; do
    TEAM_DOCTOR_CHECKS=${check##*/} run_bin -0 team-doctor
    assert_equal "$(grep -xFf <(printf '%s\n' "$output") <<<"$whole")" "$output"
    alone[${check##*/}]=$output
    reads=''
    read -ra declared <<<"$(sed -n '/^#/!q; s/^# reads state from: //p' "$check")"
    for read in "${declared[@]}"; do
      reads+=${alone[$read]}$'\n'
    done
    own=$(printf '%s' "$output" | grep -cvxFf <(printf '%s' "$reads") || true)
    [[ ${check##*/} == @(020-homebrew|230-salvage|248-power).sh ]] || ((own > 0)) || {
      echo "${check##*/} alone prints no line of its own: $output" >&2
      return 1
    }
  done
  # The heartbeat line reads the lease line's holding, which reads the machine line's name: on the
  # holder it passes only with both, run once each in name order, however named.
  TEAM_DOCTOR_CHECKS='240-heartbeat.sh 070-machine.sh 240-heartbeat.sh' run_bin -0 team-doctor
  assert_equal "$(checks)" $'machine\nlease\nheartbeat'
  assert_equal "$(line_of heartbeat)" "$(grep '^PASS heartbeat: ' <<<"$whole")"
  # So does a check dropped in, by the line that declares it; a declared check that is no file is
  # refused as a named one is.
  local checks_dir=$CODE_CHECKOUT/bin/lib/doctor.d
  printf '%s\n' '# early         Leaves its state.' '# shellcheck shell=bash' '' 'early_state=left' \
    'report early PASS "left"' >"$checks_dir/015-early.sh"
  printf '%s\n' '# reader        Reads it.' '# shellcheck shell=bash' '# reads state from: 015-early.sh' '' \
    'report reader PASS "${early_state:-none}"' >"$checks_dir/016-reader.sh"
  printf '%s\n' '# typo          Reads a check that is not there.' '# reads state from: 011-none.sh' '' \
    'report typo PASS "never"' >"$checks_dir/017-typo.sh"
  TEAM_DOCTOR_CHECKS=016-reader.sh run_bin -0 team-doctor
  assert_equal "$output" $'PASS early: left\nPASS reader: left'
  run_bin -0 team-doctor --help
  assert_equal "$(grep -A 1 '^  reader  ' <<<"$output" | tail -n 1)" "  typo          Reads a check that is not there."
  local name
  for name in 999-none.sh 070-machine ../team.sh 017-typo.sh; do
    TEAM_DOCTOR_CHECKS="070-machine.sh $name" run_bin -2 --separate-stderr team-doctor
    assert_equal "$output" ""
    assert_equal "$stderr" "team-doctor: TEAM_DOCTOR_CHECKS names ${name/017-typo.sh/011-none.sh}, no check file of bin/lib/doctor.d/"
  done
}

@test "team-doctor refuses arguments other than --json" {
  run_bin -2 --separate-stderr team-doctor --yes
  assert_equal "$stderr" "team-doctor: usage: team-doctor [--json]"
}
