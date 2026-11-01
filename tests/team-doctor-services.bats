#!/usr/bin/env bats
# shellcheck disable=SC2153 # LOCK and the other globals are helpers/doctor.bash's
# team-doctor: one PASS, WARN or FAIL line per thing this machine needs, on the machine
# tests/helpers/doctor.bash builds: every tool a version stub, the OS a stubbed uname.
# This file: the docker, chrome, 1password, secret, discord access, interview channel, opencode-gate
# and records lines.

load helpers/common
load helpers/doctor

setup() {
  sandbox
  doctor_machine
}

# docker info fails as the CLI does when it cannot reach the daemon: daemon_refuses <stderr line>
daemon_refuses() {
  printf 'echo %q >&2\nexit 1\n' "$1" >"$TOOL_ANSWERS/docker/info_--format_{{.ServerVersion}}.sh"
}

@test "the docker line fails while the daemon does not answer this user, with Daniel's step for the OS" {
  tools_at arch
  run_bin -0 team-doctor
  assert_equal "$(line_of docker)" "PASS docker: the Docker daemon answers (server 28.3.3)"
  daemon_refuses "permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock: Get \"http://%2Fvar%2Frun%2Fdocker.sock/v1.51/info\": dial unix /var/run/docker.sock: connect: permission denied"
  run_bin -1 team-doctor
  assert_equal "$(grep -v '^PASS ' <<<"$output")" "FAIL docker: \`docker info\` cannot reach the daemon: permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock: Get \"http://%2Fvar%2Frun%2Fdocker.sock/v1.51/info\": dial unix /var/run/docker.sock: connect: permission denied; fix: Daniel runs sudo usermod -aG docker \$USER, then logs out and in"
  daemon_refuses "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?"
  run_bin -1 team-doctor
  assert_equal "$(line_of docker)" "FAIL docker: \`docker info\` cannot reach the daemon: Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?; fix: Daniel runs sudo systemctl enable --now docker.service"
  on_macos
  tools_at macos
  run_bin -1 team-doctor
  assert_equal "$(line_of docker)" "FAIL docker: \`docker info\` cannot reach the daemon: Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?; fix: Daniel opens Docker Desktop once and accepts its license"
}

@test "the chrome line warns without Google Chrome or Chromium, with this OS's install" {
  tools_at arch
  run_bin -0 team-doctor
  assert_equal "$(line_of chrome)" "PASS chrome: $TEAM_CHROME"
  rm "$TEAM_CHROME"
  run_bin -0 team-doctor
  assert_equal "$(line_of chrome)" "WARN chrome: neither Google Chrome nor Chromium is installed, so chrome-devtools-axi has no browser; fix: Daniel installs google-chrome from the AUR, or runs sudo pacman -S --needed chromium"
  # Without the seam, Arch looks for the browser's command.
  unset TEAM_CHROME
  printf '#!/bin/sh\n' >"$TOOL_STUBS/google-chrome-stable"
  chmod +x "$TOOL_STUBS/google-chrome-stable"
  run_bin -0 team-doctor
  assert_equal "$(line_of chrome)" "PASS chrome: $TOOL_STUBS/google-chrome-stable"
  on_macos
  tools_at macos
  run_bin -0 team-doctor
  [[ -e "/Applications/Google Chrome.app" ]] ||
    assert_equal "$(line_of chrome)" "WARN chrome: Google Chrome is not installed, so chrome-devtools-axi has no browser; fix: brew install --cask google-chrome"
}

@test "the 1password line warns without op or the app, never asking the vault" {
  tools_at arch
  run_bin -0 team-doctor
  assert_equal "$(line_of 1password)" "PASS 1password: op and the 1Password app are installed (the vault is not asked)"
  rm "$TEAM_1PASSWORD_APP"
  run_bin -0 team-doctor
  assert_equal "$(line_of 1password)" "WARN 1password: the 1Password app is not at $TEAM_1PASSWORD_APP, so team-secrets restore can only ask for each secret to be pasted; fix: install the native 1password package from the AUR (not the Snap or Flatpak), then turn on its Settings > Developer > Integrate with 1Password CLI"
  answer "op --version"
  run_bin -1 team-doctor
  assert_equal "$(line_of 1password)" "WARN 1password: op is not installed and the 1Password app is not at $TEAM_1PASSWORD_APP, so team-secrets restore can only ask for each secret to be pasted; fix: the tool op line's fix; install the native 1password package from the AUR (not the Snap or Flatpak), then turn on its Settings > Developer > Integrate with 1Password CLI"
  on_macos
  tools_at macos
  touch "$TEAM_1PASSWORD_APP"
  run_bin -0 team-doctor
  assert_equal "$(line_of 1password)" "PASS 1password: op and the 1Password app are installed (the vault is not asked)"
  unset TEAM_1PASSWORD_APP
  run_bin -0 team-doctor
  [[ -e /Applications/1Password.app ]] ||
    assert_equal "$(line_of 1password)" "WARN 1password: the 1Password app is not at /Applications/1Password.app, so team-secrets restore can only ask for each secret to be pasted; fix: brew install --cask 1password, then turn on its Settings > Developer > Integrate with 1Password CLI"
  # op was asked its version alone, by its tool line, never the vault.
  assert_equal "$(stub_calls op)" ""
}

@test "the secret lines fail per missing, empty, open or misplaced secret with team-secrets restore; a broken manifest fails" {
  tools_at arch
  rm "$HOME/.claude/channels/discord/.env"
  : >"$HOME/.claude/channels/discord/access.json"
  chmod 644 "$HOME/Documents/projects/personal/Conventioner/.env"
  rm "$HOME/Documents/projects/personal/Conventioner/back-end/.env"
  mkdir "$HOME/Documents/projects/personal/Conventioner/back-end/.env"
  run_bin -1 team-doctor
  assert_equal "$(grep -E '^.... secret' <<<"$output")" "FAIL secret discord-bot-env: missing; fix: Daniel runs team-secrets restore in their own terminal
FAIL secret discord-access-json: empty; fix: Daniel runs team-secrets restore in their own terminal
FAIL secret conventioner-env: mode 644; fix: Daniel runs team-secrets restore in their own terminal
PASS secret conventioner-front-end-env: in place
FAIL secret conventioner-back-end-env: not a file; fix: move aside what is at its target in machine/secrets.json, then Daniel runs team-secrets restore in their own terminal"
  # Nothing else fails but the discord access line, which reads the emptied access.json, and the
  # interview channel line, which needs the missing bot token.
  assert_equal "$(grep -v '^PASS ' <<<"$output" | grep -v '^FAIL secret ' || true)" \
    "FAIL discord access: ~/.claude/channels/discord/access.json is empty, so the plugin delivers nothing from #coordinator; fix: the secret discord-access-json line's fix
FAIL interview channel: no DISCORD_BOT_TOKEN in ~/.claude/channels/discord/.env, so the bot's access to the interview channel cannot be checked; fix: the secret discord-bot-env line's fix"
  echo '[]' >"$TEAM_HOME/machine/secrets.json"
  run_bin -1 team-doctor
  assert_equal "$(grep -E '^.... secret' <<<"$output")" "FAIL secrets: machine/secrets.json: it has no secrets array; fix: fix what team-secrets names, then run team-doctor again"
  rm "$TEAM_HOME/machine/secrets.json"
  run_bin -1 team-doctor
  assert_equal "$(line_of secrets)" "FAIL secrets: no machine/secrets.json in $TEAM_HOME; fix: fix what team-secrets names, then run team-doctor again"
}

@test "the discord access line fails unless #coordinator's group lets in only Daniel's id, naming no id but the channel's" {
  local file=$HOME/.claude/channels/discord/access.json
  local fix="fix: Daniel runs /discord:access group add 1562486564871995482 --no-mention --allow <their id> in their own Claude Code session"
  local open="so any server member's message there or in a task thread reaches the coordinator"
  local seen=''
  tools_at arch
  run_bin -0 team-doctor
  assert_equal "$(line_of 'discord access')" "PASS discord access: #coordinator's group allowFrom names only Daniel's id, so only their messages there and in task threads reach the coordinator"
  seen+=$output
  access_json "[\"$DANIEL_ID\"]" '[]'
  run_bin -1 team-doctor
  assert_equal "$(grep -v '^PASS ' <<<"$output")" "FAIL discord access: #coordinator's group allowFrom is empty, $open; $fix"
  seen+=$output
  # A group with no allowFrom at all is the plugin's empty one.
  jq 'del(.groups[].allowFrom)' "$file" >"$BATS_TEST_TMPDIR/access.json"
  cat "$BATS_TEST_TMPDIR/access.json" >"$file"
  jq -e '.groups[] | has("allowFrom") | not' "$file"
  run_bin -1 team-doctor
  assert_equal "$(line_of 'discord access')" "FAIL discord access: #coordinator's group allowFrom is empty, $open; $fix"
  access_json "[\"$DANIEL_ID\"]" "[\"$DANIEL_ID\", \"$OTHER_ID\"]"
  run_bin -1 team-doctor
  assert_equal "$(line_of 'discord access')" "FAIL discord access: #coordinator's group allowFrom names Daniel's id and 1 other id, so another member's messages there and in task threads reach the coordinator; $fix"
  seen+=$output
  access_json "[\"$DANIEL_ID\"]" "[\"$OTHER_ID\", \"700000000000000003\"]"
  run_bin -1 team-doctor
  assert_equal "$(line_of 'discord access')" "FAIL discord access: #coordinator's group allowFrom names 2 other ids and not Daniel's, so another member's messages there and in task threads reach the coordinator; $fix"
  seen+=$output
  # Ids written as numbers are the same ids.
  access_json "[$DANIEL_ID]" "[\"$DANIEL_ID\"]"
  run_bin -0 team-doctor
  assert_contains "$(line_of 'discord access')" "PASS discord access: "
  # Daniel's id is the top-level allowFrom's: with none, it is unknown.
  access_json '[]' "[\"$DANIEL_ID\"]"
  run_bin -1 team-doctor
  assert_equal "$(line_of 'discord access')" "FAIL discord access: access.json's top-level allowFrom is empty, so no id is known as Daniel's; fix: Daniel runs /discord:access allow <their id>, then /discord:access group add 1562486564871995482 --no-mention --allow <their id>, in their own Claude Code session"
  seen+=$output
  access_json "[\"$DANIEL_ID\"]" '[]'
  jq '.groups = {"1": .groups[]}' "$file" >"$BATS_TEST_TMPDIR/access.json"
  cat "$BATS_TEST_TMPDIR/access.json" >"$file"
  run_bin -1 team-doctor
  assert_equal "$(line_of 'discord access')" "FAIL discord access: access.json has no group for #coordinator, so the plugin delivers nothing from it or its threads; $fix"
  # The channel is the library's: TEAM_COORDINATOR_CHANNEL names it.
  TEAM_COORDINATOR_CHANNEL=1 run_bin -1 team-doctor
  assert_equal "$(line_of 'discord access')" "FAIL discord access: #coordinator's group allowFrom is empty, $open; ${fix/1562486564871995482/1}"
  echo '{"allowFrom": "nobody"}' >"$file"
  run_bin -1 team-doctor
  assert_equal "$(line_of 'discord access')" "FAIL discord access: ~/.claude/channels/discord/access.json is not the plugin's access file (an object whose allowFrom lists are arrays), so the line cannot tell who #coordinator lets in; fix: Daniel moves it aside and runs team-secrets restore in their own terminal"
  echo 'not json' >"$file"
  run_bin -1 team-doctor
  assert_equal "$(line_of 'discord access')" "FAIL discord access: ~/.claude/channels/discord/access.json is not JSON, so the plugin moves it aside and delivers nothing from #coordinator; fix: Daniel moves it aside and runs team-secrets restore in their own terminal"
  : >"$file"
  run_bin -1 team-doctor
  assert_equal "$(line_of 'discord access')" "FAIL discord access: ~/.claude/channels/discord/access.json is empty, so the plugin delivers nothing from #coordinator; fix: the secret discord-access-json line's fix"
  rm "$file"
  run_bin -1 team-doctor
  assert_equal "$(line_of 'discord access')" "FAIL discord access: ~/.claude/channels/discord/access.json is missing, so the plugin delivers nothing from #coordinator; fix: the secret discord-access-json line's fix"
  # No line names a member's id.
  [[ $seen != *70000000000000000* ]] || { echo "the doctor printed a member's id" >&2; return 1; }
}

@test "the interview channel line fails unless the channel is set, has no access.json group and lets the bot read, open threads and post in them" {
  local line="interview channel" give="fix: Daniel gives the bot's role"
  local make="fix: Daniel makes a text channel for interviews, with no access.json group, and a PR sets its id as INTERVIEW_CHANNEL in bin/lib/team.sh"
  tools_at arch
  run_bin -0 team-doctor
  assert_equal "$(line_of "$line")" "PASS interview channel: $INTERVIEW_ID has no access.json group, so the coordinator never hears an interview, and the bot may read it, open threads and post in them"
  # Its reads, each with the token on stdin.
  assert_equal "$(stub_calls curl | jq -r '.[-1] | select(startswith("https://discord.com/")) | ltrimstr("https://discord.com/api/v10/")')" "channels/$INTERVIEW_ID
users/@me
guilds/$GUILD_ID/members/$BOT_ID
guilds/$GUILD_ID/roles"
  [[ $(stub_calls curl) != *"$FAKE_DISCORD_TOKEN"* ]]

  TEAM_INTERVIEW_CHANNEL='' run_bin -1 team-doctor
  assert_equal "$(grep -v '^PASS ' <<<"$output")" "FAIL interview channel: no interview channel is set, so no planner can interview Daniel; $make"

  jq --arg c "$INTERVIEW_ID" '.groups[$c] = {requireMention: false, allowFrom: []}' "$HOME/.claude/channels/discord/access.json" >"$BATS_TEST_TMPDIR/access.json"
  cp "$BATS_TEST_TMPDIR/access.json" "$HOME/.claude/channels/discord/access.json"
  run_bin -1 team-doctor
  assert_equal "$(line_of "$line")" "FAIL interview channel: access.json has a group for the interview channel $INTERVIEW_ID, so the plugin delivers every interview to the coordinator; fix: Daniel runs /discord:access group rm $INTERVIEW_ID in their own Claude Code session"
  access_json "[\"$DANIEL_ID\"]" "[\"$DANIEL_ID\"]"

  echo "TOKEN=dummy-secret-value" >"$HOME/.claude/channels/discord/.env"
  run_bin -1 team-doctor
  assert_equal "$(line_of "$line")" "FAIL interview channel: no DISCORD_BOT_TOKEN in ~/.claude/channels/discord/.env, so the bot's access to the interview channel cannot be checked; fix: the secret discord-bot-env line's fix"
  echo "DISCORD_BOT_TOKEN=$FAKE_DISCORD_TOKEN" >"$HOME/.claude/channels/discord/.env"

  TEAM_INTERVIEW_CHANNEL=1 run_bin -1 team-doctor
  assert_equal "$(line_of "$line")" "FAIL interview channel: Discord refused the bot's read of channels/1 (curl: (22) The requested URL returned error: 404), so the bot cannot reach the interview channel 1; $give View Channel, Read Message History, Create Public Threads, Send Messages in Threads in the interview channel's permissions"

  jq '.type = 2' "$STUB_FIXTURES/discord/channels/$INTERVIEW_ID.json" >"$BATS_TEST_TMPDIR/channel.json"
  cp "$BATS_TEST_TMPDIR/channel.json" "$STUB_FIXTURES/discord/channels/$INTERVIEW_ID.json"
  run_bin -1 team-doctor
  assert_equal "$(line_of "$line")" "FAIL interview channel: $INTERVIEW_ID is not a text channel (type 2), so no thread opens under it; $make"

  # The bot's role, then the channel's overwrites for @everyone, the bot's roles and the bot.
  interview_server "$(interview_bits 10 11 16)" '[]'
  run_bin -1 team-doctor
  assert_equal "$(line_of "$line")" "FAIL interview channel: the bot lacks Create Public Threads, Send Messages in Threads in the interview channel $INTERVIEW_ID; $give Create Public Threads, Send Messages in Threads in the interview channel's permissions"
  interview_server "$(interview_bits 10 16 35 38)" "[{\"id\": \"$GUILD_ID\", \"type\": 0, \"allow\": \"0\", \"deny\": \"$(interview_bits 10)\"}]"
  run_bin -1 team-doctor
  assert_equal "$(line_of "$line")" "FAIL interview channel: the bot lacks View Channel in the interview channel $INTERVIEW_ID; $give View Channel in the interview channel's permissions"
  interview_server "$(interview_bits 10 16 35 38)" "[{\"id\": \"$GUILD_ID\", \"type\": 0, \"allow\": \"0\", \"deny\": \"$(interview_bits 10)\"},
    {\"id\": \"$BOT_ROLE\", \"type\": 0, \"allow\": \"$(interview_bits 10)\", \"deny\": \"0\"}]"
  run_bin -0 team-doctor
  assert_contains "$(line_of "$line")" "PASS interview channel: "
  # Another role's overwrite is not the bot's; the bot's own deny comes last.
  interview_server "$(interview_bits 10 16)" "[{\"id\": \"$BOT_ROLE\", \"type\": 0, \"allow\": \"$(interview_bits 35 38)\", \"deny\": \"0\"},
    {\"id\": \"$BOT_ID\", \"type\": 1, \"allow\": \"0\", \"deny\": \"$(interview_bits 38)\"},
    {\"id\": \"700000000000000049\", \"type\": 0, \"allow\": \"0\", \"deny\": \"$(interview_bits 10 16 35 38)\"}]"
  run_bin -1 team-doctor
  assert_equal "$(line_of "$line")" "FAIL interview channel: the bot lacks Send Messages in Threads in the interview channel $INTERVIEW_ID; $give Send Messages in Threads in the interview channel's permissions"
  # Administrator allows everything, whatever the overwrites deny.
  interview_server "$(interview_bits 3)" "[{\"id\": \"$BOT_ID\", \"type\": 1, \"allow\": \"0\", \"deny\": \"$(interview_bits 10 16 35 38)\"}]"
  run_bin -0 team-doctor
  assert_contains "$(line_of "$line")" "PASS interview channel: "
  # A permission that is not a number is never read as one.
  interview_server '$(touch pwned)' '[]'
  run_bin -1 team-doctor
  assert_contains "$(line_of "$line")" "FAIL interview channel: the bot lacks View Channel, Read Message History, Create Public Threads, Send Messages in Threads"
  [[ ! -e pwned && ! -e $HOME/pwned ]]

  # Discord not answering warns.
  stub_script curl <<'EOF'
echo "curl: (6) Could not resolve host: discord.com" >&2
exit 6
EOF
  run_bin -0 team-doctor
  assert_equal "$(line_of "$line")" "WARN interview channel: Discord did not answer (curl: (6) Could not resolve host: discord.com), so the bot's access to the interview channel is unchecked; fix: check the network, then run team-doctor again"
}

@test "the opencode-gate line fails while the gate's opencode wrapper is missing, stale or not executable, opencode is missing, or config.yaml does not run the gate on it" {
  local wrapper=$HOME/.no-mistakes/bin/opencode-gate config=$HOME/.no-mistakes/config.yaml
  local install="mkdir -p ~/.no-mistakes/bin && install -m 755 $CODE_CHECKOUT/bin/lib/opencode-gate ~/.no-mistakes/bin/opencode-gate"
  local setting="agent_path_override: {opencode: $wrapper}" tools="$CODE_CHECKOUT/bin/team-bootstrap --stage tools"
  local step="as manual-steps.md's install of the no-mistakes fork says"
  tools_at arch
  run_bin -0 team-doctor
  assert_equal "$(line_of opencode-gate)" "PASS opencode-gate: ~/.no-mistakes/bin/opencode-gate is the code's bin/lib/opencode-gate, config.yaml runs the gate on opencode through it, and opencode is installed"
  # The flow form, quoted, is read too; a comment after it is not part of the path.
  printf '%s\n' 'agent: opencode' "agent_path_override: {codex: /x/codex, opencode: \"$wrapper\"} # the gate's" >"$config"
  run_bin -0 team-doctor
  assert_contains "$(line_of opencode-gate)" "PASS opencode-gate: "

  printf '%s\n' 'agent: opencode' 'agent_path_override:' '  opencode: /usr/bin/opencode' 'log_level: info' >"$config"
  run_bin -1 team-doctor
  assert_equal "$(line_of opencode-gate)" "FAIL opencode-gate: ~/.no-mistakes/config.yaml's agent_path_override does not name ~/.no-mistakes/bin/opencode-gate for opencode, so the gate's opencode reads Claude Code's config and not the gate's own; fix: $tools, which sets $setting in ~/.no-mistakes/config.yaml, that key alone"
  # A key of that name under another block is not the setting.
  printf '%s\n' 'agent: opencode' 'agent_args_override:' "  opencode: $wrapper" >"$config"
  run_bin -1 team-doctor
  assert_contains "$(line_of opencode-gate)" "FAIL opencode-gate: ~/.no-mistakes/config.yaml's agent_path_override does not name"
  # The gate's agent must be opencode: auto, another agent or none runs the gate on whatever
  # no-mistakes finds first, never through the wrapper.
  local agent_fix="Daniel sets agent: opencode in ~/.no-mistakes/config.yaml, $step"
  printf '%s\n' 'agent: auto # first found' 'agent_path_override:' "  opencode: $wrapper" >"$config"
  run_bin -1 team-doctor
  assert_equal "$(line_of opencode-gate)" "FAIL opencode-gate: ~/.no-mistakes/config.yaml's agent is auto, not opencode, so the gate runs on whichever agent no-mistakes finds first and not through the wrapper; fix: $agent_fix"
  printf '%s\n' 'agent: [claude, opencode]' 'agent_path_override:' "  opencode: $wrapper" >"$config"
  run_bin -1 team-doctor
  assert_contains "$(line_of opencode-gate)" "FAIL opencode-gate: ~/.no-mistakes/config.yaml's agent is [claude, opencode], not opencode,"
  printf '%s\n' 'agent_path_override:' "  opencode: $wrapper" 'review:' '  agent: opencode' >"$config"
  run_bin -1 team-doctor
  assert_equal "$(line_of opencode-gate)" "FAIL opencode-gate: ~/.no-mistakes/config.yaml names no agent, so the gate runs on whichever agent no-mistakes finds first and not through the wrapper; fix: $agent_fix"
  printf '%s\n' "agent: 'opencode'" 'agent_path_override:' "  opencode: $wrapper" >"$config"
  run_bin -0 team-doctor
  assert_contains "$(line_of opencode-gate)" "PASS opencode-gate: "
  # opencode itself missing: the wrapper has nothing to run, whatever config.yaml says.
  answer "opencode --version"
  run_bin -1 team-doctor
  assert_equal "$(line_of opencode-gate)" "FAIL opencode-gate: opencode is not installed, so the wrapper has nothing to run; fix: the tool opencode line's fix"
  assert_equal "$(line_of 'tool opencode')" "FAIL tool opencode: not installed; fix: npm install -g opencode-ai@1.18.30"
  tools_at arch
  rm "$config"
  run_bin -1 team-doctor
  assert_equal "$(line_of opencode-gate)" "FAIL opencode-gate: ~/.no-mistakes/config.yaml is not there; fix: Daniel runs team-secrets restore in their own terminal (the secret no-mistakes-config), then $tools sets $setting in it"

  chmod 644 "$wrapper"
  run_bin -1 team-doctor
  assert_equal "$(line_of opencode-gate)" "FAIL opencode-gate: ~/.no-mistakes/bin/opencode-gate is not executable; fix: $install"
  echo 'exec opencode "$@"' >>"$wrapper"
  chmod 755 "$wrapper"
  run_bin -1 team-doctor
  assert_equal "$(line_of opencode-gate)" "FAIL opencode-gate: ~/.no-mistakes/bin/opencode-gate is not the code's bin/lib/opencode-gate; fix: $install"
  rm "$wrapper"
  run_bin -1 team-doctor
  assert_equal "$(line_of opencode-gate)" "FAIL opencode-gate: ~/.no-mistakes/bin/opencode-gate is not installed; fix: $install"
  # Nothing else fails, on macOS alike.
  assert_equal "$(grep -v '^PASS ' <<<"$output" || true)" "$(line_of opencode-gate)"
  on_macos
  tools_at macos
  run_bin -1 team-doctor
  assert_equal "$(line_of opencode-gate)" "FAIL opencode-gate: ~/.no-mistakes/bin/opencode-gate is not installed; fix: $install"
}

@test "the servers line fails while servers/node_modules is missing or not the install of servers/package-lock.json" {
  local fix="$CODE_CHECKOUT/servers/install"
  tools_at arch
  run_bin -0 team-doctor
  assert_equal "$(line_of servers)" "PASS servers: servers/node_modules is the install of servers/package-lock.json"
  echo '{"lockfileVersion": 3}' >"$CODE_CHECKOUT/servers/package-lock.json"
  run_bin -1 team-doctor
  assert_equal "$(line_of servers)" "FAIL servers: servers/node_modules is not the install of servers/package-lock.json, so a toolkit or chrome-devtools-axi may run another server; fix: $fix"
  rm -r "$CODE_CHECKOUT/servers/node_modules"
  run_bin -1 team-doctor
  assert_equal "$(line_of servers)" "FAIL servers: servers/node_modules is missing, so the toolkits' servers and the sessions' chrome-devtools-mcp cannot start; fix: $fix"
  assert_equal "$(grep -v '^PASS ' <<<"$output" || true)" "$(line_of servers)"
}

# The records line's fix, after the problems it names.
RECORDS_FIX="fix what it names in the team home (team-log --check and team-project --check list every problem), then run team-doctor again"

@test "the records line fails on a ledger that breaks its contract, naming its first problem and the count" {
  tools_at arch
  printf '%s\n' '{"ts": "2026-10-24T01:00:00Z", "task": "T1", "event": "launch", "role": "builder", "session": "a1", "worktree": "/w"}' \
    'not json' >>"$TEAM_HOME/ledger.jsonl"
  run_bin -1 team-doctor
  assert_equal "$(line_of records)" "FAIL records: $TEAM_HOME/ledger.jsonl:1: launch needs toolkits (2 of 2 lines break the ledger contract); fix: $RECORDS_FIX"
  # Nothing else fails.
  assert_equal "$(grep -v '^PASS ' <<<"$output" | grep -v '^FAIL records: ' || true)" ""
  rm "$TEAM_HOME/ledger.jsonl"
  run_bin -1 team-doctor
  assert_equal "$(line_of records)" "FAIL records: no ledger at $TEAM_HOME/ledger.jsonl; fix: $RECORDS_FIX"
}

@test "the records line warns on a ledger whose sent_back holds whole numbers as strings, naming the conversion, and fails nothing" {
  tools_at arch
  local strict
  strict=$(jq -r .strict_from "$REPO_ROOT/bin/lib/ledger-contract.json")
  printf '%s\n' "{\"ts\": \"$strict\", \"task\": \"T1\", \"event\": \"review\", \"verdict\": \"findings\", \"head\": \"a1b2c3d\", \"sent_back\": [\"5\"]}" \
    >>"$TEAM_HOME/ledger.jsonl"
  run_bin -0 team-doctor
  assert_equal "$(line_of records)" "WARN records: the ledger meets its contract (1 line), but 1 of its lines holds whole numbers as strings in a sent_back or before, the registry passes (2 projects) and machine/secrets.md describes every enabled secret; fix: run team-log --fix-sent-back, which stores them as numbers"
  assert_equal "$(grep -v '^PASS ' <<<"$output" | grep -v '^WARN records: ' || true)" ""
  printf '%s\n' "{\"ts\": \"$strict\", \"task\": \"T1\", \"event\": \"review\", \"verdict\": \"findings\", \"head\": \"a1b2c3d\", \"sent_back\": [\"6\", 7]}" \
    >>"$TEAM_HOME/ledger.jsonl"
  run_bin -0 team-doctor
  assert_contains "$(line_of records)" "WARN records: the ledger meets its contract (2 lines), but 2 of its lines hold whole numbers as strings in a sent_back or before,"
  run_bin -0 team-log --fix-sent-back
  run_bin -0 team-doctor
  assert_equal "$(line_of records)" "PASS records: the ledger meets its contract (2 lines), the registry passes (2 projects) and machine/secrets.md describes every enabled secret"
}

@test "the records line fails on a registry team-project --check refuses, naming its first problem and the count" {
  tools_at arch
  sed -i 's/^base = "main"$/base = 5/' "$TEAM_HOME/projects.toml"
  run_bin -1 team-doctor
  assert_equal "$(line_of records)" "FAIL records: $TEAM_HOME/projects.toml: conventioner.base: must be a string (2 problems); fix: $RECORDS_FIX"
  # team-config diff and the projects line refuse the same registry; nothing else fails.
  assert_equal "$(grep -v '^PASS ' <<<"$output" | grep -v '^FAIL records: ' | cut -d: -f1 | paste -sd , || true)" \
    "WARN config,FAIL plugins,WARN memory,FAIL projects"
}

@test "the records line fails on each enabled secret machine/secrets.md has no row for; a disabled one needs none" {
  tools_at arch
  sed -i -e '/^| `conventioner-env` |/d' -e '/^| `discord-bot-env` |/d' -e '/^| `hub-env` |/d' "$TEAM_HOME/machine/secrets.md"
  run_bin -1 team-doctor
  assert_equal "$(line_of records)" "FAIL records: machine/secrets.md has no row for discord-bot-env, conventioner-env; fix: $RECORDS_FIX"
  assert_equal "$(grep -v '^PASS ' <<<"$output" | grep -v '^FAIL records: ' || true)" ""
  # Every problem at once, one after another.
  echo 'not json' >>"$TEAM_HOME/ledger.jsonl"
  rm "$TEAM_HOME/machine/secrets.md"
  run_bin -1 team-doctor
  assert_equal "$(line_of records)" "FAIL records: $TEAM_HOME/ledger.jsonl:1: not JSON (1 of 1 lines break the ledger contract); no machine/secrets.md in $TEAM_HOME; fix: $RECORDS_FIX"
}

# A UI capture (team-ui) stays on the machine that took it: the team home's git ignores it, and
# team-close removes it, so one left behind by a task that is not open is reported.
@test "the heavy runs line names the heavy-run lock's holder, or says it is free" {
  run_bin team-doctor
  assert_equal "$(line_of 'heavy runs')" "PASS heavy runs: free (team-heavy queues full test suites and local checks)"
  mkdir -p "$HOME/.local/state/agent-team"
  exec {held}<>"$HOME/.local/state/agent-team/heavy.lock"
  echo "tests/run all in ~/agent-team (pid 1) since 2026-10-25 10:00:00 +0000" >"$HOME/.local/state/agent-team/heavy.lock"
  flock -x "$held"
  run_bin team-doctor
  exec {held}<&-
  assert_equal "$(line_of 'heavy runs')" "PASS heavy runs: held by tests/run all in ~/agent-team (pid 1) since 2026-10-25 10:00:00 +0000"
}

@test "the captures line warns while the team home's git does not ignore tasks/*/ui/, or a capture is left by a task that is not open or in an archive" {
  tools_at arch
  mkdir -p "$TEAM_HOME/tasks/T4/ui" "$TEAM_HOME/tasks/T5/ui" "$TEAM_HOME/tasks/T6/ui"
  touch "$TEAM_HOME/tasks/T4/ui/ui-pick.md" "$TEAM_HOME/tasks/T5/ui/page.png"
  jq -cn '{ts: "2026-10-25T10:00:00Z", task: "T4", event: "opened", project: "conventioner", path: "small",
    type: "fix", title: "t", branch: "fix/T4-t", base: "dev", base_sha: "aba9d074", worktree: "/x/T4"}' >>"$TEAM_HOME/ledger.jsonl"
  run_bin team-doctor
  assert_equal "$(line_of captures)" "WARN captures: tasks/T5/ui/ is left behind, by a task that is not open or in an archive (team-close removes a task's captures, and archives leave them out); fix: rm -rf $TEAM_HOME/tasks/T5/ui"
  # One in an archive is left whatever its task, and the fix quotes each path.
  mkdir -p "$TEAM_HOME/tasks/T4/scratch-my site/ui"
  touch "$TEAM_HOME/tasks/T4/scratch-my site/ui/element.png"
  run_bin team-doctor
  assert_equal "$(line_of captures)" "WARN captures: tasks/T5/ui/, tasks/T4/scratch-my site/ui/ are left behind, by a task that is not open or in an archive (team-close removes a task's captures, and archives leave them out); fix: rm -rf $TEAM_HOME/tasks/T5/ui $TEAM_HOME/tasks/T4/scratch-my\\ site/ui"
  rm -r "$TEAM_HOME/tasks/T5/ui" "$TEAM_HOME/tasks/T4/scratch-my site/ui"
  run_bin team-doctor
  assert_equal "$(line_of captures)" "PASS captures: the team home's git ignores tasks/*/ui/, and every capture belongs to an open task"
  sed -i '\#^tasks/\*/ui/$#d' "$TEAM_HOME/.git/info/exclude"
  run_bin team-doctor
  assert_equal "$(line_of captures)" "WARN captures: the team home's git does not ignore tasks/*/ui/, so a checkpoint or handoff could carry a capture off this machine; fix: add tasks/*/ui/ to the team home's .gitignore, a records commit on dev"
}

