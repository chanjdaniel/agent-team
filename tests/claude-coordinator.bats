#!/usr/bin/env bats
# bin/claude-coordinator: one coordinator at a time, only on the lease holder, launched as before.
load helpers/common

setup() {
  sandbox
  # This machine, home-pc, holds the lease; make_machine laptop builds the other one.
  hold_lease home-pc >/dev/null
  lock=$HOME/.local/state/agent-team/coordinator-launch.lock
  # claude answers `agents` from $BATS_TEST_TMPDIR/sessions.json; a launch records its cwd and
  # whether the launch lock was free while it ran, and whether it inherited the lock's file.
  echo '[]' >"$BATS_TEST_TMPDIR/sessions.json"
  # `claude mcp list` answers from $BATS_TEST_TMPDIR/mcp-list.txt: today's servers on home-pc.
  cat >"$BATS_TEST_TMPDIR/mcp-list.txt" <<'TXT'
Checking MCP server health…

claude.ai Claude Docs: https://api.anthropic.com/v1/pages/mcp - ✔ Connected
plugin:mongodb-atlas:mongodb-atlas: https://mcp.mongodb.com/ (HTTP) - ! Needs authentication
codegraph: codegraph serve --mcp - ✔ Connected
vercel: https://mcp.vercel.com (HTTP) - ✔ Connected
resend: https://mcp.resend.com/mcp (HTTP) - ✔ Connected
playwright: npx -y @playwright/mcp@0.0.83 - ✗ Failed to connect
TXT
  stub_script claude <<'EOF'
lock=$HOME/.local/state/agent-team/coordinator-launch.lock
if flock -n "$lock" true; then held=free; else held=held; fi
if [[ $1 == agents ]]; then
  echo "agents $held" >>"$STUB_CALLS/claude.lock"
  cat "$BATS_TEST_TMPDIR/sessions.json"
  exit "$(cat "$BATS_TEST_TMPDIR/agents.status" 2>/dev/null || echo 0)"
fi
if [[ $1 == mcp ]]; then
  echo "mcp $held" >>"$STUB_CALLS/claude.lock"
  printf '%s\n' "$PWD" >>"$STUB_CALLS/claude.mcp-cwd"
  cat "$BATS_TEST_TMPDIR/mcp-list.txt"
  exit "$(cat "$BATS_TEST_TMPDIR/mcp.status" 2>/dev/null || echo 0)"
fi
echo "launch $held" >>"$STUB_CALLS/claude.lock"
printf '%s\n' "$PWD" >>"$STUB_CALLS/claude.cwd"
printf '%s\n' "$PATH" >>"$STUB_CALLS/claude.path"
# Each open file by device and inode, through /dev/fd as both Linux and macOS have it.
for fd in /dev/fd/*; do
  if [[ $(stat -L -c %d:%i "$fd" 2>/dev/null) == "$(stat -c %d:%i "$lock")" ]]; then
    echo "launch inherited the lock" >>"$STUB_CALLS/claude.lock"
  fi
done
echo "Started background session 7c3e9a10 (coordinator). Attach with: claude attach 7c3e9a10"
exit "$(cat "$BATS_TEST_TMPDIR/launch.status" 2>/dev/null || echo 0)"
EOF
}

# session <id|-> <sessionId> <name> <status> [<kind>]: one listed session as JSON.
session() {
  jq -cn --arg id "$1" --arg sid "$2" --arg name "$3" --arg status "$4" --arg kind "${5:-background}" \
    '{pid: 4242, cwd: "/somewhere", kind: $kind, startedAt: 1761100000000, sessionId: $sid,
      name: $name, status: $status} + (if $id == "-" then {} else {id: $id, state: "working"} end)'
}

# sessions <session json>...: the list `claude agents --json` prints.
sessions() {
  printf '%s\n' "$@" | jq -s . >"$BATS_TEST_TMPDIR/sessions.json"
}

# The launch command line: today's, plus this checkout's manual, the coordinator's skills and its
# toolkit's MCP servers.
launch_argv() {
  jq -cn --arg state "$HOME/.local/state/agent-team" --arg code "$REPO_ROOT" \
    '["--bg", "--name", "coordinator",
    "--autocompact", "200k",
    "--mcp-config", "\($state)/coordinator.mcp.json",
    "--channels", "plugin:discord@claude-plugins-official",
    "--dangerously-skip-permissions",
    "--append-system-prompt-file", "\($code)/roles/coordinator.md",
    "--plugin-dir", "\($code)/plugins/coordinator-skills",
    "--settings", "\($state)/coordinator.settings.json",
    "You are the coordinator. Daniel talks to you on Discord. Wait for their messages."]'
}

assert_not_launched() {
  if [[ -e $STUB_CALLS/claude.cwd ]] || grep -q -- '"--bg"' "$STUB_CALLS/claude.log" 2>/dev/null; then
    echo "claude --bg was called: $(stub_calls claude)" >&2
    return 1
  fi
}

@test "--help prints the header" {
  run_bin -0 claude-coordinator --help
  assert_contains "$output" "Start the one session that owns Discord: the team's coordinator."
  assert_contains "$output" "Usage: claude-coordinator [--prompt <text>] [working-directory]"
  assert_equal "$(stub_calls claude)" ""
}

@test "with no coordinator live it launches as before, from the team home by default" {
  sessions "$(session 0a1b2c3d 0a1b2c3d-1111 T14-builder busy)" "$(session - 9f9f9f9f-2222 '' idle interactive)"
  run_bin -0 claude-coordinator
  assert_contains "$output" "Started background session 7c3e9a10"
  assert_equal "$(stub_calls claude)" "$(printf '%s\n%s\n%s' '["agents","--json"]' '["mcp","list"]' "$(launch_argv)")"
  assert_equal "$(cat "$STUB_CALLS/claude.cwd")" "$TEAM_HOME"
}

@test "the session gets the library's PATH: the tool directories from tools.lock first" {
  # Arch, where uname says Linux; Bun installed under HOME, which the caller's PATH lacks.
  export TEAM_OS_RELEASE=$BATS_TEST_TMPDIR/os-release
  echo ID=arch >"$TEAM_OS_RELEASE"
  mkdir -p "$HOME/.bun/bin"
  run_bin -0 claude-coordinator
  [[ :$(cat "$STUB_CALLS/claude.path"): == *":$HOME/.bun/bin:"*"$BATS_TEST_TMPDIR/stubs:"* ]] ||
    { echo "claude's PATH: $(cat "$STUB_CALLS/claude.path")" >&2; return 1; }
}

@test "the launch appends the manual and loads the skills plugin, both from its own checkout" {
  run_bin -0 claude-coordinator
  local argv manual plugin
  argv=$(stub_calls claude | tail -n 1)
  manual=$(jq -r 'index("--append-system-prompt-file") as $i | .[$i + 1]' <<<"$argv")
  plugin=$(jq -r 'index("--plugin-dir") as $i | .[$i + 1]' <<<"$argv")
  assert_equal "$manual" "$REPO_ROOT/roles/coordinator.md"
  assert_equal "$plugin" "$REPO_ROOT/plugins/coordinator-skills"
  [[ -f $manual && -f $plugin/.claude-plugin/plugin.json ]]
}

@test "its settings are the checkout's, with the hooks of the same checkout" {
  run_bin -0 claude-coordinator
  local settings=$HOME/.local/state/agent-team/coordinator.settings.json
  # All but the servers denied, which the launch adds (the toolkit's tests below).
  assert_equal "$(jq -c 'del(.deniedMcpServers)' "$settings")" \
    "$(jq -c --arg code "$REPO_ROOT" 'walk(if type == "string" then gsub("@TEAM_CODE@"; $code) else . end)' \
      "$REPO_ROOT/coordinator.settings.json")"
  assert_equal "$(jq -r '[.hooks[][].hooks[].command] | .[]' "$settings")" \
    "\"$REPO_ROOT/bin/hooks/session-digest\""$'\n'"\"$REPO_ROOT/bin/hooks/stop-sweep\""$'\n'"\"$REPO_ROOT/bin/hooks/lease-fence\""$'\n'"\"$REPO_ROOT/bin/hooks/lease-fence\" --coordinator"
  [[ -x $REPO_ROOT/bin/hooks/session-digest && -x $REPO_ROOT/bin/hooks/stop-sweep && -x $REPO_ROOT/bin/hooks/lease-fence ]]
  [[ $(cat "$settings") != *"@TEAM_CODE@"* ]]
  assert_equal "$(jq .isolatePeerMachines "$settings")" true
  assert_equal "$(find "${settings%/*}" -name '*.json.*')" ""
}

@test "its settings name it in AGENT_TEAM_ROLE, the signal a hook sees in a team session" {
  run_bin -0 claude-coordinator
  assert_equal "$(jq -r .env.AGENT_TEAM_ROLE "$HOME/.local/state/agent-team/coordinator.settings.json")" coordinator
}

@test "its settings keep every tool and skill its manual and skills name, and what it uses with Daniel" {
  run_bin -0 claude-coordinator
  local settings=$HOME/.local/state/agent-team/coordinator.settings.json skill tool
  keeps_named "$settings" "$REPO_ROOT/roles/coordinator.md" "$REPO_ROOT"/plugins/coordinator-skills/skills/*/SKILL.md
  # Its own skills, by their bare names too, which an override might reach.
  for skill in "$REPO_ROOT"/plugins/coordinator-skills/skills/*/; do
    skill=$(basename "$skill")
    assert_equal "$(jq -r --arg s "$skill" '.skillOverrides[$s] // "on"' "$settings")" on
  done
  # Discord, the claude.ai docs connector (its toolkit keeps it) and the synced docs skill that
  # guides it, and artifacts.
  assert_equal "$(jq -c '[.enabledPlugins["discord@claude-plugins-official"], .disableClaudeAiConnectors, .syncClaudeAiSkills,
    .syncClaudeAiPlugins, .enabledPlugins["cc-plugin-plugin-authoring@builtin"]]' "$settings")" '[true,null,null,false,false]'
  for tool in Artifact ArtifactComments ArtifactData SendUserFile PushNotification CronCreate CronList CronDelete \
    ScheduleWakeup Monitor SendMessage ListAgents Agent WebFetch WebSearch; do
    if jq -e --arg t "$tool" '.permissions.deny | index($t) != null' "$settings" >/dev/null; then
      echo "denies $tool, which the coordinator may use with Daniel" >&2 && return 1
    fi
  done
  for skill in artifact-design artifact-capabilities artifact-diagramming dataviz writing-for-agents grilling; do
    assert_equal "$(jq -r --arg s "$skill" '.skillOverrides[$s] // "on"' "$settings")" on
  done
  # A background session nobody watches cannot answer a question or leave plan mode.
  for tool in AskUserQuestion EnterPlanMode ExitPlanMode SendFeedback; do
    jq -e --arg t "$tool" '.permissions.deny | index($t) != null' "$settings" >/dev/null ||
      { echo "no deny rule for $tool" >&2; return 1; }
  done
}

# The names in the settings' deniedMcpServers, one per line, sorted.
denied() {
  jq -r '.deniedMcpServers[].serverName' "$HOME/.local/state/agent-team/coordinator.settings.json" | sort
}

@test "its MCP servers come only from its toolkit, by --mcp-config, never --strict-mcp-config, which would cut Discord" {
  run_bin -0 claude-coordinator
  local argv mcp=$HOME/.local/state/agent-team/coordinator.mcp.json
  argv=$(stub_calls claude | tail -n 1)
  assert_equal "$(jq -r 'index("--mcp-config") as $i | .[$i + 1]' <<<"$argv")" "$mcp"
  assert_equal "$(jq -r 'map(select(. == "--mcp-config")) | length' <<<"$argv")" 1
  assert_equal "$(jq 'index("--strict-mcp-config")' <<<"$argv")" null
  assert_equal "$(jq -c . "$mcp")" "$(jq -c . "$REPO_ROOT/toolkits/coordinator/.mcp.json")"
  assert_equal "$(jq -c .mcpServers "$mcp")" '{}'
  assert_equal "$(find "${mcp%/*}" -name '*.json.*')" ""
}

@test "its settings deny every server claude mcp list names in its working directory, but the claude.ai connectors its toolkit keeps" {
  printf '%s\n' 'claude.ai Gmail: https://gmail.mcp.claude.com/mcp - ✔ Connected' >>"$BATS_TEST_TMPDIR/mcp-list.txt"
  run_bin -0 claude-coordinator
  assert_equal "$(cat "$STUB_CALLS/claude.mcp-cwd")" "$TEAM_HOME"
  assert_equal "$(denied)" "$(printf '%s\n' 'claude.ai Gmail' codegraph playwright plugin:mongodb-atlas:mongodb-atlas resend vercel)"
  assert_equal "$(jq -c . "$REPO_ROOT/toolkits/coordinator/connectors.json")" '["claude.ai Claude Docs"]'
  # The connectors stay on, so a kept one loads; every other is denied by name.
  local settings=$HOME/.local/state/agent-team/coordinator.settings.json
  assert_equal "$(jq 'has("disableClaudeAiConnectors")' "$settings")" false
  # The checkout's own settings name no server: the list is the launch's.
  assert_equal "$(jq 'has("deniedMcpServers")' "$REPO_ROOT/coordinator.settings.json")" false
}

@test "a connector its toolkit keeps is kept by its exact name, and with none kept every connector is denied" {
  code_checkout
  echo '[]' >"$CODE_CHECKOUT/toolkits/coordinator/connectors.json"
  run_bin -0 claude-coordinator
  assert_equal "$(denied | grep -c '^claude\.ai ')" 1
  echo '["claude.ai Claude"]' >"$CODE_CHECKOUT/toolkits/coordinator/connectors.json"
  run_bin -0 claude-coordinator
  assert_equal "$(denied | grep '^claude\.ai ')" 'claude.ai Claude Docs'
}

@test "the Discord plugin and its channel stay on, and its servers are never denied" {
  printf '%s\n' 'plugin:discord:discord: bun run start - ✔ Connected' 'other: x - ✔ Connected' \
    >"$BATS_TEST_TMPDIR/mcp-list.txt"
  run_bin -0 claude-coordinator
  local argv settings=$HOME/.local/state/agent-team/coordinator.settings.json
  argv=$(stub_calls claude | tail -n 1)
  assert_equal "$(jq -r 'index("--channels") as $i | .[$i + 1]' <<<"$argv")" plugin:discord@claude-plugins-official
  assert_equal "$(jq '.enabledPlugins["discord@claude-plugins-official"]' "$settings")" true
  assert_equal "$(denied)" other
}

@test "a server in its toolkit reaches it and is not denied, with @TEAM_CODE@ naming the checkout" {
  code_checkout
  cat >"$CODE_CHECKOUT/toolkits/coordinator/.mcp.json" <<'JSON'
{"mcpServers": {"notes": {"command": "node", "args": ["@TEAM_CODE@/servers/notes.mjs"]}}}
JSON
  printf '%s\n' 'notes: node x - ✔ Connected' 'vercel: https://mcp.vercel.com (HTTP) - ✔ Connected' \
    >"$BATS_TEST_TMPDIR/mcp-list.txt"
  run_bin -0 claude-coordinator
  assert_equal "$(jq -c .mcpServers "$HOME/.local/state/agent-team/coordinator.mcp.json")" \
    "$(jq -cn --arg code "$CODE_CHECKOUT" '{notes: {command: "node", args: ["\($code)/servers/notes.mjs"]}}')"
  assert_equal "$(denied)" vercel
}

@test "with no server listed it denies none" {
  echo 'No MCP servers configured. Use `claude mcp add` to add a server.' >"$BATS_TEST_TMPDIR/mcp-list.txt"
  run_bin -0 claude-coordinator
  assert_equal "$(jq -c .deniedMcpServers "$HOME/.local/state/agent-team/coordinator.settings.json")" '[]'
}

@test "a failed claude mcp list refuses the launch, so no coordinator starts with servers it should not have" {
  echo 1 >"$BATS_TEST_TMPDIR/mcp.status"
  run_bin -1 --separate-stderr claude-coordinator
  assert_contains "$stderr" "claude-coordinator: claude mcp list failed, so the servers to deny are unknown"
  assert_not_launched
}

@test "it compacts at 200k tokens, by the launch flag, which no settings scope preempts" {
  run_bin -0 claude-coordinator
  local argv
  argv=$(stub_calls claude | tail -n 1)
  assert_equal "$(jq -r 'index("--autocompact") as $i | .[$i + 1]' <<<"$argv")" 200k
  assert_equal "$(jq -r 'map(select(. == "--autocompact")) | length' <<<"$argv")" 1
  # The prompt stays last, so no flag can take it as a value.
  assert_equal "$(jq -r '.[-1]' <<<"$argv")" "You are the coordinator. Daniel talks to you on Discord. Wait for their messages."
}

@test "its settings compact it while idle from 100k tokens, and leave the compaction window to the flag" {
  run_bin -0 claude-coordinator
  local settings=$HOME/.local/state/agent-team/coordinator.settings.json
  assert_equal "$(jq .idleCompaction "$settings")" true
  assert_equal "$(jq -r '.env.CLAUDE_CODE_IDLE_COMPACT_MIN_TOKENS' "$settings")" 100000
  assert_equal "$(jq '.env.CLAUDE_CODE_IDLE_COMPACT_MIN_TOKENS | type' "$settings")" '"string"'
  assert_equal "$(jq 'has("autoCompactWindow")' "$settings")" false
  assert_equal "$(jq '.env | has("CLAUDE_CODE_AUTO_COMPACT_WINDOW")' "$settings")" false
}

@test "its Discord reply, react and edit_message, and its Bash, and nothing else, go through the fence hook" {
  run_bin -0 claude-coordinator
  local settings=$HOME/.local/state/agent-team/coordinator.settings.json tool
  # A matcher of names and | lists those tools exactly.
  for tool in reply react edit_message; do
    assert_equal "$(jq -r --arg tool "mcp__plugin_discord_discord__$tool" '.hooks.PreToolUse[]
      | select(.matcher | split("|") | index($tool)) | .hooks[].command' "$settings")" "\"$REPO_ROOT/bin/hooks/lease-fence\""
  done
  assert_equal "$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command' "$settings")" \
    "\"$REPO_ROOT/bin/hooks/lease-fence\" --coordinator"
  assert_equal "$(jq -r '[.hooks.PreToolUse[].matcher | split("|") | length] | add' "$settings")" 4
  jq -e '.hooks.PreToolUse[].matcher | test("^[A-Za-z0-9_|]+$")' "$settings"
}

@test "its settings deny sudo, and leave it free to start Claude sessions" {
  run_bin -0 claude-coordinator
  local settings=$HOME/.local/state/agent-team/coordinator.settings.json command
  for command in "sudo" "sudo -n true" "sudo pacman -S jq"; do
    denied_in "$settings" "$command" || { echo "allows: $command" >&2; return 1; }
  done
  for command in "claude --bg --name x go" "claude -p hi" "claude agents" "grep -rn sudo tests"; do
    if denied_in "$settings" "$command"; then echo "denies: $command" >&2; return 1; fi
  done
}

@test "it launches from the working directory it is given" {
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
  run_bin -0 claude-coordinator "$BATS_TEST_TMPDIR/elsewhere"
  assert_equal "$(cat "$STUB_CALLS/claude.cwd")" "$BATS_TEST_TMPDIR/elsewhere"
  assert_equal "$(stub_calls claude | tail -n 1)" "$(launch_argv)"
}

@test "--prompt replaces the first prompt, as team-resume starts it" {
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
  run_bin -0 claude-coordinator --prompt "Follow the resume skill." "$BATS_TEST_TMPDIR/elsewhere"
  assert_equal "$(cat "$STUB_CALLS/claude.cwd")" "$BATS_TEST_TMPDIR/elsewhere"
  assert_equal "$(stub_calls claude | tail -n 1)" "$(launch_argv | jq -c '.[-1] = "Follow the resume skill."')"
}

@test "a malformed command line is a usage error, launching nothing" {
  local args
  for args in "--prompt" "--prompt ''" "a b" "--other" "$HOME/agent-team --prompt x"; do
    eval "run_bin -2 --separate-stderr claude-coordinator $args"
    assert_contains "$stderr" "usage: claude-coordinator [--prompt <text>] [working-directory]"
  done
  assert_equal "$(stub_calls claude)" ""
}

@test "a live coordinator refuses the launch, naming its session id" {
  sessions "$(session 0a1b2c3d 0a1b2c3d-1111 T14-builder busy)" "$(session 5e6f7a8b 5e6f7a8b-3333 coordinator idle)"
  run_bin -1 --separate-stderr claude-coordinator
  assert_equal "$output" ""
  assert_contains "$stderr" "claude-coordinator: a coordinator is already live: session 5e6f7a8b"
  assert_equal "$(stub_calls claude)" '["agents","--json"]'
  assert_not_launched
}

@test "a busy coordinator refuses the launch too" {
  sessions "$(session 5e6f7a8b 5e6f7a8b-3333 coordinator busy)"
  run_bin -1 claude-coordinator
  assert_contains "$output" "session 5e6f7a8b"
  assert_not_launched
}

@test "an interactive coordinator, which has no short id, is named by its session id" {
  sessions "$(session - d4c3b2a1-4444-5555 coordinator idle interactive)"
  run_bin -1 claude-coordinator
  assert_contains "$output" "session d4c3b2a1"
  assert_not_launched
}

@test "only a session named exactly coordinator counts" {
  sessions "$(session 11111111 11111111-a T14-coordinator busy)" "$(session 22222222 22222222-b coordinator-old idle)" \
    "$(session 33333333 33333333-c Coordinator idle)"
  run_bin -0 claude-coordinator
  assert_equal "$(stub_calls claude | tail -n 1)" "$(launch_argv)"
}

@test "an unreadable session list refuses the launch" {
  echo 'not json' >"$BATS_TEST_TMPDIR/sessions.json"
  run_bin -1 claude-coordinator
  assert_contains "$output" "cannot read the live session list"
  assert_not_launched

  echo '[]' >"$BATS_TEST_TMPDIR/sessions.json"
  echo 1 >"$BATS_TEST_TMPDIR/agents.status"
  run_bin -1 claude-coordinator
  assert_contains "$output" "cannot read the live session list"
  assert_not_launched
}

@test "it holds the launch lock across the check and the launch, and the session does not inherit it" {
  run_bin -0 claude-coordinator
  assert_equal "$(cat "$STUB_CALLS/claude.lock")" "$(printf 'agents held\nmcp held\nlaunch held')"
  [[ -f $lock ]]
}

@test "a second launch while the lock is held exits 1 at once, without asking claude anything" {
  mkdir -p "${lock%/*}"
  exec {held}>"$lock"
  flock -n "$held"
  guard_sandbox
  run -1 --separate-stderr timeout 10 "$REPO_ROOT/bin/claude-coordinator"
  exec {held}>&-
  assert_contains "$stderr" "claude-coordinator: another claude-coordinator is launching right now"
  assert_contains "$stderr" "$lock"
  assert_equal "$(stub_calls claude)" ""
}

@test "the lock is released when it exits, so the next launch passes" {
  sessions "$(session 5e6f7a8b 5e6f7a8b-3333 coordinator idle)"
  run_bin -1 claude-coordinator
  echo '[]' >"$BATS_TEST_TMPDIR/sessions.json"
  run_bin -0 claude-coordinator
  run_bin -0 claude-coordinator
  assert_equal "$(grep -c -- '"--bg"' "$STUB_CALLS/claude.log")" 2
}

@test "a failed launch exits with claude's status" {
  echo 3 >"$BATS_TEST_TMPDIR/launch.status"
  run_bin -3 claude-coordinator
}

@test "with the lease held by the other machine it refuses, naming the holder and the next step" {
  make_machine laptop
  run_bin -0 team-lease release
  on_machine laptop run_bin -0 team-lease take
  run_bin -1 --separate-stderr claude-coordinator
  assert_equal "$output" ""
  assert_contains "$stderr" "team-lease: home-pc no longer holds the lease: laptop holds it (epoch 2"
  assert_contains "$stderr" "claude-coordinator: laptop holds the lease: run team-resume --wait here, then hand off there once it says this machine is ready"
  assert_not_launched
  [[ ! -e $HOME/.local/state/agent-team/coordinator.settings.json ]]
}

@test "with GitHub unreachable it refuses: a coordinator never starts offline" {
  git -C "$TEAM_HOME" remote set-url origin https://127.0.0.1:9/agent-team.git
  run_bin -1 --separate-stderr claude-coordinator
  assert_contains "$stderr" "team-lease: GitHub is unreachable"
  assert_contains "$stderr" "claude-coordinator: GitHub unreachable; a coordinator never starts offline"
  assert_not_launched
}

@test "with the lease released, or held at an epoch this machine has no record of, it refuses with the lease's reason" {
  run_bin -0 team-lease release
  run_bin -1 --separate-stderr claude-coordinator
  assert_contains "$stderr" "team-lease: the lease is released (last held by home-pc, epoch 1); take it with team-lease take"
  assert_contains "$stderr" "claude-coordinator: a coordinator starts only on the machine that holds the lease"
  assert_not_launched

  run_bin -0 team-lease take
  rm "$HOME/.local/state/agent-team/lease.json"
  run_bin -1 --separate-stderr claude-coordinator
  assert_contains "$stderr" "but this machine has no record of taking it"
  assert_contains "$stderr" "claude-coordinator: a coordinator starts only on the machine that holds the lease"
  assert_not_launched
}

@test "without a team name for this machine it refuses" {
  rm "$HOME/.config/agent-team/machine"
  run_bin -1 --separate-stderr claude-coordinator
  assert_contains "$stderr" "this machine has no team name"
  assert_not_launched
}

@test "the lease is checked under the launch lock, and no git the check runs inherits the lock's file" {
  local real_git
  real_git=$(command -v git)
  # git, first on PATH: records whether the launch lock is held and whether it has the lock's
  # file open, then runs the real git.
  {
    echo '#!/usr/bin/env bash'
    printf 'lock=%q calls=%q real=%q\n' "$lock" "$STUB_CALLS/git.lock" "$real_git"
    cat <<'SH'
for fd in /dev/fd/*; do
  if [[ $(stat -L -c %d:%i "$fd" 2>/dev/null) == "$(stat -c %d:%i "$lock")" ]]; then
    echo "git inherited the lock" >>"$calls"
  fi
done
if flock -n "$lock" true; then echo "git: lock free" >>"$calls"; else echo "git: lock held" >>"$calls"; fi
exec "$real" "$@"
SH
  } >"$BATS_TEST_TMPDIR/stubs/git"
  chmod +x "$BATS_TEST_TMPDIR/stubs/git"
  run_bin -0 claude-coordinator
  assert_equal "$(sort -u "$STUB_CALLS/git.lock")" "git: lock held"
}
