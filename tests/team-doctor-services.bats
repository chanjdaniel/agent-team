#!/usr/bin/env bats
# shellcheck disable=SC2153 # LOCK and the other globals are helpers/doctor.bash's
# team-doctor: one PASS, WARN or FAIL line per thing this machine needs, on the machine
# tests/helpers/doctor.bash builds: every tool a version stub, the OS a stubbed uname.
# This file: the docker, chrome, power, 1password, secret, discord access, interview channel,
# gate-agent and records lines.

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
  only_checks 040-docker.sh
  tools_at arch
  run_bin -0 team-doctor
  assert_equal "$(line_of docker)" "PASS docker: the Docker daemon answers (server 28.3.3)"
  daemon_refuses "permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock: Get \"http://%2Fvar%2Frun%2Fdocker.sock/v1.51/info\": dial unix /var/run/docker.sock: connect: permission denied"
  # The whole doctor, since the next assertion reads every line.
  TEAM_DOCTOR_CHECKS='' run_bin -1 team-doctor
  assert_equal "$(grep -v '^PASS ' <<<"$output")" "FAIL docker: \`docker info\` cannot reach the daemon: permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock: Get \"http://%2Fvar%2Frun%2Fdocker.sock/v1.51/info\": dial unix /var/run/docker.sock: connect: permission denied; fix: Daniel runs sudo usermod -aG docker \$USER, then logs out and in"
  daemon_refuses "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?"
  run_bin -1 team-doctor
  assert_equal "$(line_of docker)" "FAIL docker: \`docker info\` cannot reach the daemon: Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?; fix: Daniel runs sudo systemctl enable --now docker.service"
  on_macos
  tools_at macos
  run_bin -1 team-doctor
  assert_equal "$(line_of docker)" "FAIL docker: \`docker info\` cannot reach the daemon: Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?; fix: Daniel opens Docker Desktop once and accepts its license"
}

@test "the chrome line warns without Google Chrome or Chromium that runs, with this OS's install" {
  only_checks 050-chrome.sh
  tools_at arch
  run_bin -0 team-doctor
  assert_equal "$(line_of chrome)" "PASS chrome: $TEAM_CHROME"
  local warn="WARN chrome: neither Google Chrome nor Chromium is installed, so chrome-devtools-axi has no browser; fix: Daniel installs google-chrome from the AUR, or runs sudo pacman -S --needed chromium"
  # A TEAM_CHROME that is no executable is no browser, as team-tickets --graph finds none there.
  chmod -x "$TEAM_CHROME"
  run_bin -0 team-doctor
  assert_equal "$(line_of chrome)" "$warn"
  rm "$TEAM_CHROME"
  run_bin -0 team-doctor
  assert_equal "$(line_of chrome)" "$warn"
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

@test "on macOS the power line passes on AC power and warns on battery power or an unread source, never failing; Linux has no power line" {
  only_checks 248-power.sh
  tools_at arch
  run_bin -0 team-doctor
  assert_equal "$(line_of power)" ""
  on_macos
  tools_at macos
  # as_macos's pmset answers AC power.
  run_bin -0 team-doctor
  assert_equal "$(line_of power)" "PASS power: on AC power; keep the lid open while this Mac holds the team, since caffeinate keeps it from idle sleep only"
  assert_equal "$(stub_calls pmset)" '["-g","batt"]'
  stub_reply pmset "Now drawing from 'Battery Power'
 -InternalBattery-0 (id=4653155)	81%; discharging; 5:12 remaining present: true"
  run_bin -0 team-doctor
  assert_equal "$(line_of power)" "WARN power: on battery power: a closed lid or a flat battery sleeps this Mac and stops the team, and the lease goes stale after 60 minutes; fix: plug this Mac in, and keep its lid open while it holds the team"
  stub_reply pmset "Now drawing from 'UPS Power'"
  run_bin -0 team-doctor
  assert_equal "$(line_of power)" "WARN power: could not read the power source (pmset -g batt: Now drawing from 'UPS Power'); fix: run pmset -g batt and read its first line"
  stub_script pmset <<'EOF'
echo "pmset: no power source information" >&2
exit 1
EOF
  run_bin -0 team-doctor
  assert_equal "$(line_of power)" "WARN power: could not read the power source (pmset -g batt: pmset: no power source information); fix: run pmset -g batt and read its first line"
  rm "$STUB_FIXTURES/pmset.sh"
  stub_reply pmset '' 1
  run_bin -0 team-doctor
  assert_equal "$(line_of power)" "WARN power: could not read the power source (pmset -g batt: no output); fix: run pmset -g batt and read its first line"
  # With no pmset at all, on a machine that has none of its own to find instead.
  rm "$BATS_TEST_TMPDIR/stubs/pmset"
  if ! command -v pmset >/dev/null; then
    run_bin -0 team-doctor
    assert_equal "$(line_of power)" "WARN power: could not read the power source (pmset -g batt: no output); fix: run pmset -g batt and read its first line"
  fi
  # --help lists the line from its file's header, between the resources and the offline lines.
  run_bin -0 team-doctor --help
  assert_equal "$(grep '^  power  ' <<<"$output")" "  power         macOS only: the power source, from pmset -g batt's first line. Passes on AC"
  [[ $(grep -n '^  resources  ' <<<"$output" | cut -d: -f1) -lt $(grep -n '^  power  ' <<<"$output" | cut -d: -f1) ]]
  [[ $(grep -n '^  power  ' <<<"$output" | cut -d: -f1) -lt $(grep -n '^  offline  ' <<<"$output" | cut -d: -f1) ]]
}

@test "the 1password line warns without op or the app, never asking the vault" {
  only_checks 150-1password.sh
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
  only_checks 160-secrets.sh
  tools_at arch
  rm "$HOME/.claude/channels/discord/.env"
  : >"$HOME/.claude/channels/discord/access.json"
  chmod 644 "$HOME/Documents/projects/personal/Conventioner/.env"
  rm "$HOME/Documents/projects/personal/Conventioner/back-end/.env"
  mkdir "$HOME/Documents/projects/personal/Conventioner/back-end/.env"
  # The whole doctor, since the lines but the secret ones are asserted below.
  TEAM_DOCTOR_CHECKS='' run_bin -1 team-doctor
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
  only_checks 165-discord-access.sh 167-interview-channel.sh
  local file=$HOME/.claude/channels/discord/access.json
  local fix="fix: Daniel runs /discord:access group add 1562486564871995482 --no-mention --allow <their id> in their own Claude Code session"
  local open="so any server member's message there or in a task thread reaches the coordinator"
  local seen=''
  tools_at arch
  run_bin -0 team-doctor
  assert_equal "$(line_of 'discord access')" "PASS discord access: #coordinator's group allowFrom names only Daniel's id, so only their messages there and in task threads reach the coordinator"
  seen+=$output
  access_json "[\"$DANIEL_ID\"]" '[]'
  # The whole doctor, since the assertion reads every line.
  TEAM_DOCTOR_CHECKS='' run_bin -1 team-doctor
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

@test "the interview channel line fails unless the channel is set, has no access.json group and lets the bot read, open threads, post in them and attach images" {
  only_checks 167-interview-channel.sh
  local line="interview channel" give="fix: Daniel gives the bot's role"
  local make="fix: Daniel makes a text channel for interviews, with no access.json group, and a PR sets its id as INTERVIEW_CHANNEL in bin/lib/team.sh"
  tools_at arch
  run_bin -0 team-doctor
  assert_equal "$(line_of "$line")" "PASS interview channel: $INTERVIEW_ID has no access.json group, so the coordinator never hears an interview, and the bot may read it, open threads, post in them and attach images"
  # Its reads, each with the token on stdin.
  assert_equal "$(stub_calls curl | jq -r '.[-1] | select(startswith("https://discord.com/")) | ltrimstr("https://discord.com/api/v10/")')" "channels/$INTERVIEW_ID
users/@me
guilds/$GUILD_ID/members/$BOT_ID
guilds/$GUILD_ID/roles"
  [[ $(stub_calls curl) != *"$FAKE_DISCORD_TOKEN"* ]]

  # The whole doctor, since the assertion reads every line.
  TEAM_INTERVIEW_CHANNEL='' TEAM_DOCTOR_CHECKS='' run_bin -1 team-doctor
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
  assert_equal "$(line_of "$line")" "FAIL interview channel: Discord refused the bot's read of channels/1 (curl: (22) The requested URL returned error: 404), so the bot cannot reach the interview channel 1; $give View Channel, Read Message History, Create Public Threads, Send Messages in Threads, Attach Files in the interview channel's permissions"

  jq '.type = 2' "$STUB_FIXTURES/discord/channels/$INTERVIEW_ID.json" >"$BATS_TEST_TMPDIR/channel.json"
  cp "$BATS_TEST_TMPDIR/channel.json" "$STUB_FIXTURES/discord/channels/$INTERVIEW_ID.json"
  run_bin -1 team-doctor
  assert_equal "$(line_of "$line")" "FAIL interview channel: $INTERVIEW_ID is not a text channel (type 2), so no thread opens under it; $make"

  # The bot's role, then the channel's overwrites for @everyone, the bot's roles and the bot.
  interview_server "$(interview_bits 10 11 16)" '[]'
  run_bin -1 team-doctor
  assert_equal "$(line_of "$line")" "FAIL interview channel: the bot lacks Create Public Threads, Send Messages in Threads, Attach Files in the interview channel $INTERVIEW_ID; $give Create Public Threads, Send Messages in Threads, Attach Files in the interview channel's permissions"
  interview_server "$(interview_bits 10 15 16 35 38)" "[{\"id\": \"$GUILD_ID\", \"type\": 0, \"allow\": \"0\", \"deny\": \"$(interview_bits 10)\"}]"
  run_bin -1 team-doctor
  assert_equal "$(line_of "$line")" "FAIL interview channel: the bot lacks View Channel in the interview channel $INTERVIEW_ID; $give View Channel in the interview channel's permissions"
  interview_server "$(interview_bits 10 15 16 35 38)" "[{\"id\": \"$GUILD_ID\", \"type\": 0, \"allow\": \"0\", \"deny\": \"$(interview_bits 10)\"},
    {\"id\": \"$BOT_ROLE\", \"type\": 0, \"allow\": \"$(interview_bits 10)\", \"deny\": \"0\"}]"
  run_bin -0 team-doctor
  assert_contains "$(line_of "$line")" "PASS interview channel: "
  # Another role's overwrite is not the bot's; the bot's own deny comes last.
  interview_server "$(interview_bits 10 15 16)" "[{\"id\": \"$BOT_ROLE\", \"type\": 0, \"allow\": \"$(interview_bits 35 38)\", \"deny\": \"0\"},
    {\"id\": \"$BOT_ID\", \"type\": 1, \"allow\": \"0\", \"deny\": \"$(interview_bits 38)\"},
    {\"id\": \"700000000000000049\", \"type\": 0, \"allow\": \"0\", \"deny\": \"$(interview_bits 10 15 16 35 38)\"}]"
  run_bin -1 team-doctor
  assert_equal "$(line_of "$line")" "FAIL interview channel: the bot lacks Send Messages in Threads in the interview channel $INTERVIEW_ID; $give Send Messages in Threads in the interview channel's permissions"
  # Attach Files is bit 15, for team-post --attach, as the channel's overwrites may deny it alone.
  interview_server "$(interview_bits 10 16 35 38)" '[]'
  run_bin -1 team-doctor
  assert_equal "$(line_of "$line")" "FAIL interview channel: the bot lacks Attach Files in the interview channel $INTERVIEW_ID; $give Attach Files in the interview channel's permissions"
  interview_server "$(interview_bits 10 15 16 35 38)" "[{\"id\": \"$BOT_ROLE\", \"type\": 0, \"allow\": \"0\", \"deny\": \"32768\"}]"
  run_bin -1 team-doctor
  assert_equal "$(line_of "$line")" "FAIL interview channel: the bot lacks Attach Files in the interview channel $INTERVIEW_ID; $give Attach Files in the interview channel's permissions"
  # Administrator allows everything, whatever the overwrites deny.
  interview_server "$(interview_bits 3)" "[{\"id\": \"$BOT_ID\", \"type\": 1, \"allow\": \"0\", \"deny\": \"$(interview_bits 10 15 16 35 38)\"}]"
  run_bin -0 team-doctor
  assert_contains "$(line_of "$line")" "PASS interview channel: "
  # A permission that is not a number is never read as one.
  interview_server '$(touch pwned)' '[]'
  run_bin -1 team-doctor
  assert_contains "$(line_of "$line")" "FAIL interview channel: the bot lacks View Channel, Read Message History, Create Public Threads, Send Messages in Threads, Attach Files"
  [[ ! -e pwned && ! -e $HOME/pwned ]]

  # Discord not answering warns.
  stub_script curl <<'EOF'
echo "curl: (6) Could not resolve host: discord.com" >&2
exit 6
EOF
  run_bin -0 team-doctor
  assert_equal "$(line_of "$line")" "WARN interview channel: Discord did not answer (curl: (6) Could not resolve host: discord.com), so the bot's access to the interview channel is unchecked; fix: check the network, then run team-doctor again"
}

@test "on an opencode gate the gate-agent line fails while its wrapper is missing, stale or not executable, opencode is missing, or config.yaml does not run the gate on it" {
  only_checks 170-gate-agent.sh
  local wrapper=$HOME/.no-mistakes/bin/opencode-gate config=$HOME/.no-mistakes/config.yaml
  local install="mkdir -p ~/.no-mistakes/bin && install -m 755 $CODE_CHECKOUT/bin/lib/opencode-gate ~/.no-mistakes/bin/opencode-gate"
  local setting="agent_path_override: {opencode: $wrapper}" tools="$CODE_CHECKOUT/bin/team-bootstrap --stage tools"
  tools_at arch
  run_bin -0 team-doctor
  assert_equal "$(line_of gate-agent)" "PASS gate-agent: config.yaml runs the gate on opencode through ~/.no-mistakes/bin/opencode-gate, the code's bin/lib/opencode-gate, and opencode is installed"
  # The flow form, quoted, is read too; a comment after it is not part of the path.
  printf '%s\n' 'agent: opencode' "agent_path_override: {codex: /x/codex, opencode: \"$wrapper\"} # the gate's" >"$config"
  run_bin -0 team-doctor
  assert_contains "$(line_of gate-agent)" "PASS gate-agent: "

  printf '%s\n' 'agent: opencode' 'agent_path_override:' '  opencode: /usr/bin/opencode' 'log_level: info' >"$config"
  run_bin -1 team-doctor
  assert_equal "$(line_of gate-agent)" "FAIL gate-agent: ~/.no-mistakes/config.yaml's agent_path_override does not name ~/.no-mistakes/bin/opencode-gate for opencode, so the gate's opencode reads Claude Code's config and not the gate's own; fix: $tools, which sets $setting in ~/.no-mistakes/config.yaml, that key alone"
  # A key of that name under another block is not the setting.
  printf '%s\n' 'agent: opencode' 'agent_args_override:' "  opencode: $wrapper" >"$config"
  run_bin -1 team-doctor
  assert_contains "$(line_of gate-agent)" "FAIL gate-agent: ~/.no-mistakes/config.yaml's agent_path_override does not name"
  # The gate's agent must be opencode or claude: auto, another agent or none runs the gate on a
  # setup the team does not check.
  local agent_fix="Daniel sets agent: opencode in ~/.no-mistakes/config.yaml (then $tools names the wrapper in it), or agent: claude with agent_args_override: {claude: [--setting-sources, \"project,local\", --strict-mcp-config, --settings, $CODE_CHECKOUT/bin/lib/gate-claude-settings.json]}"
  printf '%s\n' 'agent: auto # first found' 'agent_path_override:' "  opencode: $wrapper" >"$config"
  run_bin -1 team-doctor
  assert_equal "$(line_of gate-agent)" "FAIL gate-agent: ~/.no-mistakes/config.yaml's agent is auto, neither opencode nor claude, so the gate runs on neither setup the team checks; fix: $agent_fix"
  printf '%s\n' 'agent: [claude, opencode]' 'agent_path_override:' "  opencode: $wrapper" >"$config"
  run_bin -1 team-doctor
  assert_contains "$(line_of gate-agent)" "FAIL gate-agent: ~/.no-mistakes/config.yaml's agent is [claude, opencode], neither opencode nor claude,"
  printf '%s\n' 'agent: codex' 'agent_path_override:' "  opencode: $wrapper" >"$config"
  run_bin -1 team-doctor
  assert_contains "$(line_of gate-agent)" "FAIL gate-agent: ~/.no-mistakes/config.yaml's agent is codex, neither opencode nor claude,"
  printf '%s\n' 'agent_path_override:' "  opencode: $wrapper" 'review:' '  agent: opencode' >"$config"
  run_bin -1 team-doctor
  assert_equal "$(line_of gate-agent)" "FAIL gate-agent: ~/.no-mistakes/config.yaml names no agent, so the gate runs on whichever agent no-mistakes finds first; fix: $agent_fix"
  printf '%s\n' "agent: 'opencode'" 'agent_path_override:' "  opencode: $wrapper" >"$config"
  run_bin -0 team-doctor
  assert_contains "$(line_of gate-agent)" "PASS gate-agent: "
  # opencode itself missing: the wrapper has nothing to run, whatever config.yaml says.
  answer "opencode --version"
  run_bin -1 team-doctor
  assert_equal "$(line_of gate-agent)" "FAIL gate-agent: opencode is not installed, so the wrapper has nothing to run; fix: the tool opencode line's fix"
  assert_equal "$(line_of 'tool opencode')" "FAIL tool opencode: not installed; fix: npm install -g opencode-ai@$(lock_pin opencode)"
  tools_at arch
  rm "$config"
  run_bin -1 team-doctor
  assert_equal "$(line_of gate-agent)" "FAIL gate-agent: ~/.no-mistakes/config.yaml is not there; fix: Daniel runs team-secrets restore in their own terminal (the secret no-mistakes-config), then $tools sets $setting in it"

  chmod 644 "$wrapper"
  run_bin -1 team-doctor
  assert_equal "$(line_of gate-agent)" "FAIL gate-agent: ~/.no-mistakes/bin/opencode-gate is not executable; fix: $install"
  echo 'exec opencode "$@"' >>"$wrapper"
  chmod 755 "$wrapper"
  run_bin -1 team-doctor
  assert_equal "$(line_of gate-agent)" "FAIL gate-agent: ~/.no-mistakes/bin/opencode-gate is not the code's bin/lib/opencode-gate; fix: $install"
  rm "$wrapper"
  # The whole doctor, since the assertion after the next reads every line.
  TEAM_DOCTOR_CHECKS='' run_bin -1 team-doctor
  assert_equal "$(line_of gate-agent)" "FAIL gate-agent: ~/.no-mistakes/bin/opencode-gate is not installed; fix: $install"
  # Nothing else fails, on macOS alike.
  assert_equal "$(grep -v '^PASS ' <<<"$output" || true)" "$(line_of gate-agent)"
  on_macos
  tools_at macos
  run_bin -1 team-doctor
  assert_equal "$(line_of gate-agent)" "FAIL gate-agent: ~/.no-mistakes/bin/opencode-gate is not installed; fix: $install"
}

@test "on a Claude gate the gate-agent line requires --settings naming a file with commit attribution off" {
  only_checks 170-gate-agent.sh
  tools_at arch
  rm "$HOME/.no-mistakes/bin/opencode-gate"
  local config=$HOME/.no-mistakes/config.yaml settings=$BATS_TEST_TMPDIR/gate-settings.json
  local off=$CODE_CHECKOUT/bin/lib/gate-claude-settings.json
  local sources='--setting-sources, "project,local", --strict-mcp-config'
  local fail="FAIL gate-agent: ~/.no-mistakes/config.yaml runs the gate on claude, but its agent_args_override.claude lacks --settings naming a file whose attribution.commit is empty, so the gate's own commits carry no agent line; fix: Daniel sets agent_args_override: {claude: [--setting-sources, \"project,local\", --strict-mcp-config, --settings, $off]} in ~/.no-mistakes/config.yaml"
  jq -e '.attribution.commit == ""' "$off" >/dev/null

  # The code's file passes.
  printf '%s\n' 'agent: claude' "agent_args_override: {claude: [$sources, --settings, $off]}" >"$config"
  run_bin -0 team-doctor
  assert_equal "$(line_of gate-agent)" "PASS gate-agent: config.yaml runs the gate on claude with --setting-sources project,local, --strict-mcp-config and commit attribution off, and claude is installed"

  # With no --settings at all and nothing else lacking, it only warns, so a resume goes on until
  # Daniel adds it: team-merge still refuses a commit that carries the line.
  printf '%s\n' 'agent: claude' "agent_args_override: {claude: [$sources]}" >"$config"
  run_bin -0 team-doctor
  local fix=${fail##*; fix: }
  assert_equal "$(line_of gate-agent)" "WARN gate-agent: config.yaml runs the gate on claude with --setting-sources project,local and --strict-mcp-config, but its agent_args_override.claude has no --settings naming a file whose attribution.commit is empty, so the gate's own commits may carry an agent line, which team-merge refuses; fix: $fix"
  # With a stray item too, the warning names both.
  printf '%s\n' 'agent: claude' 'agent_args_override: {claude: [--setting-sources, project,local, --strict-mcp-config]}' >"$config"
  run_bin -0 team-doctor
  assert_contains "$(line_of gate-agent)" "WARN gate-agent: config.yaml runs the gate on claude with --setting-sources project and --strict-mcp-config, but its agent_args_override.claude has no --settings naming"
  assert_contains "$(line_of gate-agent)" "which team-merge refuses, and it has local right after --setting-sources project, which claude takes as an argument of its own"
  # --settings last, with no value.
  printf '%s\n' 'agent: claude' "agent_args_override: {claude: [$sources, --settings]}" >"$config"
  run_bin -1 team-doctor
  assert_equal "$(line_of gate-agent)" "$fail"
  # A file that is not there, is not JSON, or leaves attribution on or unset fails.
  local content
  for content in '' 'not json' '{}' '{"attribution": {"commit": "Co-Authored-By: Claude"}}' '{"attribution": {"sessionUrl": false}}'; do
    printf '%s' "$content" >"$settings"
    printf '%s\n' 'agent: claude' "agent_args_override: {claude: [$sources, --settings, $settings]}" >"$config"
    run_bin -1 team-doctor
    assert_equal "$(line_of gate-agent)" "$fail"
  done
  printf '%s\n' 'agent: claude' "agent_args_override: {claude: [$sources, --settings, $BATS_TEST_TMPDIR/no-such.json]}" >"$config"
  run_bin -1 team-doctor
  assert_equal "$(line_of gate-agent)" "$fail"
  # One of two with attribution on is enough, and the = form counts.
  printf '%s' '{}' >"$settings"
  printf '%s\n' 'agent: claude' "agent_args_override: {claude: [$sources, --settings, $off, \"--settings=$settings\"]}" >"$config"
  run_bin -1 team-doctor
  assert_equal "$(line_of gate-agent)" "$fail"
  # Any file with attribution off passes.
  printf '%s' '{"attribution": {"commit": ""}}' >"$settings"
  printf '%s\n' 'agent: claude' "agent_args_override: {claude: [$sources, \"--settings=$settings\"]}" >"$config"
  run_bin -0 team-doctor
  assert_contains "$(line_of gate-agent)" "PASS gate-agent:"

  # An opencode gate never reads it.
  printf '%s\n' 'agent: opencode' "agent_path_override: {opencode: $HOME/.no-mistakes/bin/opencode-gate}" >"$config"
  install -m 755 "$CODE_CHECKOUT/bin/lib/opencode-gate" "$HOME/.no-mistakes/bin/opencode-gate"
  run_bin -0 team-doctor
  assert_contains "$(line_of gate-agent)" "PASS gate-agent: config.yaml runs the gate on opencode"
}

@test "on a Claude gate the gate-agent line passes only while claude is installed and its flags keep it off Daniel's user settings and MCP servers" {
  only_checks 170-gate-agent.sh
  local config=$HOME/.no-mistakes/config.yaml
  local off=$CODE_CHECKOUT/bin/lib/gate-claude-settings.json
  local args="agent_args_override: {claude: [--setting-sources, \"project,local\", --strict-mcp-config, --settings, $off]}"
  local pass="PASS gate-agent: config.yaml runs the gate on claude with --setting-sources project,local, --strict-mcp-config and commit attribution off, and claude is installed"
  local user_lack="--setting-sources with sources that leave out user, so the gate's claude loads Daniel's user settings (their hooks, the Discord plugin, Remote Control)"
  local strict_lack="--strict-mcp-config, so the gate's claude loads Daniel's MCP servers"
  local settings_lack="--settings naming a file whose attribution.commit is empty, so the gate's own commits carry no agent line"
  local lacks="FAIL gate-agent: ~/.no-mistakes/config.yaml runs the gate on claude, but its agent_args_override.claude lacks"
  local fix="fix: Daniel sets $args in ~/.no-mistakes/config.yaml"
  tools_at arch
  # Claude's setup needs no wrapper and no agent_path_override; the token is never printed.
  rm "$HOME/.no-mistakes/bin/opencode-gate"
  printf '%s\n' 'agent: claude' 'api_token: fake-token-123' 'agent_config:' '  claude:' '    model: claude-haiku-5-5' \
    'agent_args_override:' '  claude:' '    - --setting-sources' '    - project,local' '    - --strict-mcp-config' '    - --settings' "    - $off" >"$config"
  # The whole doctor, since the token's absence is asserted of every line.
  TEAM_DOCTOR_CHECKS='' run_bin -0 team-doctor
  assert_equal "$(line_of gate-agent)" "$pass"
  [[ $output != *fake-token-123* ]]
  # The flow form, and the = form, quoted.
  printf '%s\n' "agent: 'claude'  # the trial" "$args" >"$config"
  run_bin -0 team-doctor
  assert_equal "$(line_of gate-agent)" "$pass"
  printf '%s\n' 'agent: claude' 'agent_args_override:' "  claude: [--strict-mcp-config, \"--setting-sources=project\", \"--settings=$off\"]" >"$config"
  run_bin -0 team-doctor
  assert_equal "$(line_of gate-agent)" "PASS gate-agent: config.yaml runs the gate on claude with --setting-sources project, --strict-mcp-config and commit attribution off, and claude is installed"
  # Unquoted in a flow sequence, project,local is two items: claude gets project alone, and local
  # as an argument of its own, which warns.
  printf '%s\n' 'agent: claude' "agent_args_override: {claude: [--setting-sources, project,local, --strict-mcp-config, --settings, $off]}" >"$config"
  run_bin -0 team-doctor
  assert_equal "$(line_of gate-agent)" "WARN gate-agent: config.yaml runs the gate on claude with --setting-sources project, --strict-mcp-config and commit attribution off, but agent_args_override.claude has local right after --setting-sources project, which claude takes as an argument of its own (an unquoted project,local in a flow list is two items); fix: Daniel quotes the sources as one item in ~/.no-mistakes/config.yaml: $args"
  printf '%s\n' 'agent: claude' "agent_args_override: {claude: [--setting-sources=project,local, --strict-mcp-config, --settings, $off]}" >"$config"
  run_bin -0 team-doctor
  assert_equal "$(line_of gate-agent)" "WARN gate-agent: config.yaml runs the gate on claude with --setting-sources project, --strict-mcp-config and commit attribution off, but agent_args_override.claude has local right after --setting-sources=project, which claude takes as an argument of its own (an unquoted project,local in a flow list is two items); fix: Daniel quotes the sources as one item in ~/.no-mistakes/config.yaml: $args"
  # A comment inside a flow mapping leaves it open on its line: a form left to Daniel.
  printf '%s\n' 'agent: claude' 'agent_args_override: {claude: [--strict-mcp-config # , --setting-sources, project]}' '  ]}' >"$config"
  run_bin -1 team-doctor
  assert_contains "$(line_of gate-agent)" "FAIL gate-agent: ~/.no-mistakes/config.yaml's agent_args_override is in a form team-doctor does not read"
  # A flag after the sources is no stray argument.
  printf '%s\n' 'agent: claude' 'agent_args_override:' "  claude: [--setting-sources, project, --model, sonnet, --strict-mcp-config, --settings, $off]" >"$config"
  run_bin -0 team-doctor
  assert_equal "$(line_of gate-agent)" "PASS gate-agent: config.yaml runs the gate on claude with --setting-sources project, --strict-mcp-config and commit attribution off, and claude is installed"
  # A claude key at the top level, not agent_args_override's child, gives claude no flags; nor
  # does one in a comment or nested in another agent's list.
  local both="$lacks --setting-sources with sources that leave out user, so the gate's claude loads Daniel's user settings (their hooks, the Discord plugin, Remote Control); --strict-mcp-config, so the gate's claude loads Daniel's MCP servers; $settings_lack; $fix"
  printf '%s\n' 'agent: claude' 'agent_args_override:' 'claude: [--setting-sources, project, --strict-mcp-config]' >"$config"
  run_bin -1 team-doctor
  assert_equal "$(line_of gate-agent)" "$both"
  printf '%s\n' 'agent: claude' 'agent_args_override: {codex: [-c]} # , claude: [--setting-sources, project, --strict-mcp-config]' >"$config"
  run_bin -1 team-doctor
  assert_equal "$(line_of gate-agent)" "$both"
  printf '%s\n' 'agent: claude' 'agent_args_override: {codex: [-c, claude: [--setting-sources, project, --strict-mcp-config]]}' >"$config"
  run_bin -1 team-doctor
  assert_equal "$(line_of gate-agent)" "$both"

  # Either flag missing fails, naming what it lets in.
  printf '%s\n' 'agent: claude' 'agent_args_override:' '  claude:' '    - --setting-sources' '    - project,local' >"$config"
  run_bin -1 team-doctor
  assert_equal "$(line_of gate-agent)" "$lacks $strict_lack; $settings_lack; $fix"
  printf '%s\n' 'agent: claude' 'agent_args_override:' '  claude: [--strict-mcp-config]' '  codex: [--setting-sources, project]' >"$config"
  run_bin -1 team-doctor
  assert_equal "$(line_of gate-agent)" "$lacks $user_lack; $settings_lack; $fix"
  # Sources that take in user, or none, are the user settings again; one such of two is enough.
  local sources
  for sources in user 'project,user' 'local, user' '' ','; do
    printf '%s\n' 'agent: claude' 'agent_args_override:' '  claude:' '    - --setting-sources' "    - \"$sources\"" \
      '    - --strict-mcp-config' >"$config"
    run_bin -1 team-doctor
    assert_equal "$(line_of gate-agent)" "$lacks $user_lack; $settings_lack; $fix"
  done
  printf '%s\n' 'agent: claude' 'agent_args_override:' '  claude: [--setting-sources, project, --setting-sources=user, --strict-mcp-config]' >"$config"
  run_bin -1 team-doctor
  assert_equal "$(line_of gate-agent)" "$lacks $user_lack; $settings_lack; $fix"
  # --setting-sources last, with no value.
  printf '%s\n' 'agent: claude' 'agent_args_override:' '  claude: [--strict-mcp-config, --setting-sources]' >"$config"
  run_bin -1 team-doctor
  assert_equal "$(line_of gate-agent)" "$lacks $user_lack; $settings_lack; $fix"
  # No agent_args_override, or none for claude: both.
  printf '%s\n' 'agent: claude' 'agent_path_override:' '  claude: /usr/bin/claude' >"$config"
  run_bin -1 team-doctor
  assert_equal "$(line_of gate-agent)" "$lacks $user_lack; $strict_lack; $settings_lack; $fix"
  # A form the read leaves to Daniel.
  printf '%s\n' 'agent: claude' 'agent_args_override:' '  claude: [--setting-sources,' '    project, --strict-mcp-config]' >"$config"
  run_bin -1 team-doctor
  assert_equal "$(line_of gate-agent)" "FAIL gate-agent: ~/.no-mistakes/config.yaml's agent_args_override is in a form team-doctor does not read (a flow collection over several lines, a nested one, or a scalar); fix: Daniel writes its claude list as a block or a one-line flow sequence: $args"

  # claude itself missing.
  printf '%s\n' 'agent: claude' "$args" >"$config"
  answer "claude --version"
  run_bin -1 team-doctor
  assert_equal "$(line_of gate-agent)" "FAIL gate-agent: claude is not installed, so the gate has no agent to run; fix: the tool claude line's fix"
}

@test "the servers line fails while servers/node_modules is missing or not the install of servers/package-lock.json" {
  only_checks 060-servers.sh
  local fix="$CODE_CHECKOUT/servers/install"
  tools_at arch
  run_bin -0 team-doctor
  assert_equal "$(line_of servers)" "PASS servers: servers/node_modules is the install of servers/package-lock.json"
  echo '{"lockfileVersion": 3}' >"$CODE_CHECKOUT/servers/package-lock.json"
  run_bin -1 team-doctor
  assert_equal "$(line_of servers)" "FAIL servers: servers/node_modules is not the install of servers/package-lock.json, so a toolkit or chrome-devtools-axi may run another server; fix: $fix"
  rm -r "$CODE_CHECKOUT/servers/node_modules"
  # The whole doctor, since the last assertion reads every line.
  TEAM_DOCTOR_CHECKS='' run_bin -1 team-doctor
  assert_equal "$(line_of servers)" "FAIL servers: servers/node_modules is missing, so the toolkits' servers and the sessions' chrome-devtools-mcp cannot start; fix: $fix"
  assert_equal "$(grep -v '^PASS ' <<<"$output" || true)" "$(line_of servers)"
}

# The records line's fix, after the problems it names.
RECORDS_FIX="fix what it names in the team home (team-log --check and team-project --check list every problem), then run team-doctor again"

@test "the records line fails on a ledger that breaks its contract, naming its first problem and the count" {
  only_checks 180-records.sh
  tools_at arch
  printf '%s\n' '{"ts": "2026-10-24T01:00:00Z", "task": "T1", "event": "launch", "role": "builder", "session": "a1", "worktree": "/w"}' \
    'not json' >>"$TEAM_HOME/ledger.jsonl"
  # The whole doctor, since "nothing else fails" reads every line.
  TEAM_DOCTOR_CHECKS='' run_bin -1 team-doctor
  assert_equal "$(line_of records)" "FAIL records: $TEAM_HOME/ledger.jsonl:1: launch needs toolkits (2 of 2 lines break the ledger contract); fix: $RECORDS_FIX"
  # Nothing else fails.
  assert_equal "$(grep -v '^PASS ' <<<"$output" | grep -v '^FAIL records: ' || true)" ""
  rm "$TEAM_HOME/ledger.jsonl"
  run_bin -1 team-doctor
  assert_equal "$(line_of records)" "FAIL records: no ledger at $TEAM_HOME/ledger.jsonl; fix: $RECORDS_FIX"
}

@test "the records line warns on a ledger whose sent_back holds whole numbers as strings, naming the conversion, and fails nothing" {
  only_checks 180-records.sh
  tools_at arch
  local strict
  strict=$(jq -r .strict_from "$REPO_ROOT/bin/lib/ledger-contract.json")
  printf '%s\n' "{\"ts\": \"$strict\", \"task\": \"T1\", \"event\": \"review\", \"verdict\": \"findings\", \"head\": \"a1b2c3d\", \"sent_back\": [\"5\"]}" \
    >>"$TEAM_HOME/ledger.jsonl"
  # The whole doctor, since the second assertion reads every line.
  TEAM_DOCTOR_CHECKS='' run_bin -0 team-doctor
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
  only_checks 180-records.sh
  tools_at arch
  sed -i -e '/^| `conventioner-env` |/d' -e '/^| `discord-bot-env` |/d' -e '/^| `hub-env` |/d' "$TEAM_HOME/machine/secrets.md"
  # The whole doctor, since the second assertion reads every line.
  TEAM_DOCTOR_CHECKS='' run_bin -1 team-doctor
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
  only_checks 195-heavy-runs.sh
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

captures_pass="PASS captures: the team home's git ignores tasks/*/ui/, every capture belongs to an open task, and no slot held by no open task holds .scratch/shots/"

@test "the captures line warns while the team home's git does not ignore tasks/*/ui/, or a capture is left by a task that is not open or in an archive" {
  only_checks 190-captures.sh
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
  assert_equal "$(line_of captures)" "$captures_pass"
  sed -i '\#^tasks/\*/ui/$#d' "$TEAM_HOME/.git/info/exclude"
  run_bin team-doctor
  assert_equal "$(line_of captures)" "WARN captures: the team home's git does not ignore tasks/*/ui/, so a checkpoint or handoff could carry a capture off this machine; fix: add tasks/*/ui/ to the team home's .gitignore, a records commit on dev"
}

# A slot <slot> of Conventioner's pool (its folder's number) with a screenshot in .scratch/shots/,
# detached as a returned slot is; prints its path: slot_with_shots <n>
slot_with_shots() {
  local slot=$HOME/.treehouse/Conventioner-d4c77a/$1/Conventioner
  git -C "$CONVENTIONER" worktree add -q --detach "$slot"
  mkdir -p "$slot/.scratch/shots/builder"
  touch "$slot/.scratch/shots/builder/page.png"
  echo "$slot"
}

# An event of Conventioner's slot <slot> in T<n>'s life, as team-open and team-close log them.
slot_opened() {
  jq -cn --arg task "$1" --arg wt "$2" '{ts: "2026-10-24T10:00:00Z", task: $task, event: "opened",
    project: "conventioner", path: "feature", type: "feat", title: "Work", branch: "feat/\($task)-work",
    base: "main", base_sha: "0000000", worktree: $wt}' >>"$TEAM_HOME/ledger.jsonl"
}
slot_closed() {
  jq -cn --arg task "$1" --arg wt "$2" --arg how "$3" '{ts: "2026-10-25T10:00:00Z", task: $task, event: "closed", archive: [],
    returned: (if $how == "returned" then [$wt] else [] end), kept: (if $how == "kept" then [$wt] else [] end)}' >>"$TEAM_HOME/ledger.jsonl"
}

@test "the captures line warns about .scratch/shots/ in a slot held by no open task, with the fix" {
  only_checks 190-captures.sh
  tools_at arch
  local shown one two
  # A slot of Conventioner's a closed task left: nothing removed it before team-close did.
  one=$(slot_with_shots 1)
  slot_opened T5 "$one"
  slot_closed T5 "$one" returned
  # shellcheck disable=SC2088 # the doctor's lines name HOME as ~
  shown='~/.treehouse/Conventioner-d4c77a'
  run_bin team-doctor
  assert_equal "$(line_of captures)" "WARN captures: $shown/1/Conventioner/.scratch/shots/ is left behind, in a slot held by no open task (team-close removes .scratch/shots/ from each worktree it returns); fix: rm -rf $one/.scratch/shots"

  # A slot past the registered ones counts, a slot no ledger line names too, and each is listed
  # with its path quoted.
  two=$(slot_with_shots 7)
  run_bin team-doctor
  assert_equal "$(line_of captures)" "WARN captures: $shown/1/Conventioner/.scratch/shots/, $shown/7/Conventioner/.scratch/shots/ are left behind, in slots held by no open task (team-close removes .scratch/shots/ from each worktree it returns); fix: rm -rf $one/.scratch/shots $two/.scratch/shots"

  # A git pool's slot counts as well.
  rm -r "$one/.scratch/shots" "$two/.scratch/shots"
  git -C "$SITE" worktree add -q --detach "$HOME/projects/site-slots/1"
  mkdir -p "$HOME/projects/site-slots/1/.scratch/shots"
  touch "$HOME/projects/site-slots/1/.scratch/shots/page.png"
  run_bin team-doctor
  assert_equal "$(line_of captures)" "WARN captures: ~/projects/site-slots/1/.scratch/shots/ is left behind, in a slot held by no open task (team-close removes .scratch/shots/ from each worktree it returns); fix: rm -rf $HOME/projects/site-slots/1/.scratch/shots"

  # So does a git pool's numbered worktree that no slot lists, made on demand.
  rm -r "$HOME/projects/site-slots/1/.scratch/shots"
  git -C "$SITE" worktree add -q --detach "$SITE/.claude/worktrees/4"
  mkdir -p "$SITE/.claude/worktrees/4/.scratch/shots"
  touch "$SITE/.claude/worktrees/4/.scratch/shots/page.png"
  run_bin team-doctor
  assert_equal "$(line_of captures)" "WARN captures: ~/projects/site/.claude/worktrees/4/.scratch/shots/ is left behind, in a slot held by no open task (team-close removes .scratch/shots/ from each worktree it returns); fix: rm -rf $SITE/.claude/worktrees/4/.scratch/shots"
}

@test "the captures line says nothing of .scratch/shots/ that is empty, or in the slot of an open task" {
  only_checks 190-captures.sh
  tools_at arch
  local slot other
  slot=$(slot_with_shots 1)
  # Held by T5, under another spelling of its path, and earlier held by a closed task.
  slot_opened T4 "$slot"
  slot_closed T4 "$slot" returned
  other=$(other_spelling "$HOME/.treehouse")
  slot_opened T5 "${other}/Conventioner-d4c77a/1/Conventioner"
  run_bin team-doctor
  assert_equal "$(line_of captures)" "$captures_pass"

  # A legacy task, one with no opened event, holds what it launched in.
  slot=$(slot_with_shots 3)
  jq -cn --arg wt "$slot" '{ts: "2026-10-24T10:00:00Z", task: "T6", event: "launch", role: "builder", session: "4f2a9c1e", worktree: $wt, toolkits: []}' >>"$TEAM_HOME/ledger.jsonl"
  run_bin team-doctor
  assert_equal "$(line_of captures)" "$captures_pass"

  # An empty folder holds nothing to warn about.
  slot=$HOME/.treehouse/Conventioner-d4c77a/4/Conventioner
  git -C "$CONVENTIONER" worktree add -q --detach "$slot"
  mkdir -p "$slot/.scratch/shots"
  run_bin team-doctor
  assert_equal "$(line_of captures)" "$captures_pass"

  # A linked .scratch points at what may be another slot's, which its fix must not remove.
  other=$BATS_TEST_TMPDIR/elsewhere
  mkdir -p "$other/shots"
  touch "$other/shots/page.png"
  rm -r "$slot/.scratch"
  ln -s "$other" "$slot/.scratch"
  run_bin team-doctor
  assert_equal "$(line_of captures)" "$captures_pass"
}

@test "the captures line leaves a kept worktree's .scratch/shots/ while it is on a branch, and warns once it is returned" {
  only_checks 190-captures.sh
  tools_at arch
  local slot
  slot=$(slot_with_shots 1)
  git -C "$slot" switch -q -c feat/T5-work
  slot_opened T5 "$slot"
  slot_closed T5 "$slot" kept
  run_bin team-doctor
  assert_equal "$(line_of captures)" "$captures_pass"

  # Daniel returned it by hand, so no team-close will remove them.
  git -C "$slot" switch -q --detach
  run_bin team-doctor
  assert_contains "$(line_of captures)" "WARN captures: ~/.treehouse/Conventioner-d4c77a/1/Conventioner/.scratch/shots/ is left behind"
}

@test "the captures line leaves another clone's worktree in the pool, and judges nothing without a ledger or a registry" {
  only_checks 190-captures.sh
  tools_at arch
  local slot other=$HOME/firstmate/projects/Conventioner
  # A clone sharing the pool owns slot 1, whose screenshots are that clone's.
  git clone -q "$CONVENTIONER" "$other"
  slot=$HOME/.treehouse/Conventioner-d4c77a/1/Conventioner
  git -C "$other" worktree add -q --detach "$slot"
  mkdir -p "$slot/.scratch/shots"
  touch "$slot/.scratch/shots/page.png"
  # A folder holding no worktree at all is the slots line's.
  mkdir -p "$HOME/.treehouse/Conventioner-d4c77a/2/Conventioner/.scratch/shots"
  touch "$HOME/.treehouse/Conventioner-d4c77a/2/Conventioner/.scratch/shots/page.png"
  run_bin team-doctor
  assert_equal "$(line_of captures)" "$captures_pass"

  # With no ledger to read, no slot is known to be free; with no registry, no slot is known.
  slot_with_shots 3 >/dev/null
  run_bin team-doctor
  assert_contains "$(line_of captures)" "/3/Conventioner/.scratch/shots/ is left behind"
  mv "$TEAM_HOME/ledger.jsonl" "$TEAM_HOME/ledger.jsonl.aside"
  run_bin team-doctor
  assert_equal "$(line_of captures)" "$captures_pass"
  mv "$TEAM_HOME/ledger.jsonl.aside" "$TEAM_HOME/ledger.jsonl"
  mv "$TEAM_HOME/projects.toml" "$TEAM_HOME/projects.toml.aside"
  run_bin team-doctor
  assert_equal "$(line_of captures)" "$captures_pass"
}
