#!/usr/bin/env bats
# team-worker: starting a worker as a background session, only on the lease holder and in one of
# its task's open worktrees, with its role's settings, and logging the launch.

load helpers/common

setup() {
  sandbox
  # This machine, home-pc, holds the lease; make_machine laptop builds the other one.
  hold_lease home-pc >/dev/null
  primary=$(make_repo proj)
  wt1=$HOME/slots/proj/1 wt2=$HOME/slots/proj/2
  git -C "$primary" worktree add -q -b feat/T7-one "$wt1"
  git -C "$primary" worktree add -q -b feat/T8-two "$wt2"
  stub_script claude <<'EOF'
printf '%s\n' "$PWD" >>"$STUB_CALLS/claude.cwd"
echo "Started background session 4f2a9c1e (${*: -2:1}). Attach with: claude attach 4f2a9c1e"
EOF
}

# ledger_line [jq options...] <filter>: append the line jq builds, standing in for the script
# that writes it.
ledger_line() {
  jq -cn "$@" >>"$TEAM_HOME/ledger.jsonl"
}

thread() {
  ledger_line --arg t "$1" '{ts: (now | todate), task: $t, event: "thread", discord_thread: "1563"}'
}

# opened <task> <project> <branch> <worktree>
opened() {
  ledger_line --arg t "$1" --arg p "$2" --arg b "$3" --arg wt "$4" '{ts: (now | todate), task: $t,
    event: "opened", project: $p, path: "feature", type: "feat", title: "A task", branch: $b,
    base: "main", base_sha: "0123456", worktree: $wt}'
}

launches() {
  jq -c 'select(.event == "launch") | del(.ts)' "$TEAM_HOME/ledger.jsonl"
}

# A copy of bin/ in a checkout with roles, settings and toolkits written by the test, so the
# merge of settings and toolkits is checked against known inputs. Sets $code.
fake_checkout() {
  code=$BATS_TEST_TMPDIR/code
  mkdir -p "$code/roles" "$code/settings" "$code/toolkits/kit-a" "$code/toolkits/kit-b" "$code/toolkits/kit-c"
  copy_bin "$code/bin"
  echo "You plan." >"$code/roles/planner.md"
  cat >"$code/settings/worker.json" <<'JSON'
{"disableClaudeAiConnectors": true, "env": {"A": "worker", "B": "worker"},
 "permissions": {"deny": ["Bash(git clean*)", "Bash(gh pr merge*)"], "allow": ["Read"]},
 "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "@TEAM_CODE@/bin/hooks/w"}]}],
   "Stop": [{"hooks": [{"type": "command", "command": "s"}]}]}}
JSON
  cat >"$code/settings/planner.json" <<'JSON'
{"env": {"B": "planner"}, "permissions": {"deny": ["Bash(git push*)"], "allow": ["Edit"]},
 "hooks": {"PreToolUse": [{"hooks": [{"type": "command", "command": "@TEAM_CODE@/bin/hooks/x @TEAM_CODE@"}]}]}}
JSON
  echo '{"mcpServers": {"alpha": {"command": "a"}}}' >"$code/toolkits/kit-a/.mcp.json"
  echo '{"mcpServers": {"beta": {"command": "b"}, "gamma": {"command": "c"}}}' >"$code/toolkits/kit-c/.mcp.json"
}

run_fake() {
  guard_sandbox
  run "$code/bin/team-worker" "$@"
}

@test "a malformed command line is a usage error, with nothing started or logged" {
  thread T7
  run_bin -2 team-worker T7 builder
  assert_contains "$output" "usage: team-worker <task> <role> <worktree> [--toolkit <name>]... [--request <link>] -- <first prompt>"
  run_bin -2 team-worker 7 builder "$wt1" -- go
  assert_contains "$output" "task must look like T<n>, got '7'"
  run_bin -2 team-worker T7 builder "$wt1" go
  assert_contains "$output" "unexpected argument 'go'"
  run_bin -2 team-worker T7 builder "$wt1" --toolkit
  assert_contains "$output" "--toolkit needs a name"
  run_bin -2 team-worker T7 builder "$wt1"
  assert_contains "$output" "missing '--' before the first prompt"
  run_bin -2 team-worker T7 builder "$wt1" --
  assert_contains "$output" "missing first prompt"
  run_bin -2 team-worker T7 coordinator "$wt1" -- go
  assert_contains "$output" "unknown role 'coordinator'"
  run_bin -2 team-worker T7 builder "$wt1" --toolkit nope -- go
  assert_contains "$output" "unknown toolkit 'nope'"

  assert_equal "$(stub_calls claude)" ""
  assert_equal "$(launches)" ""
}

@test "a task with no Discord thread is refused" {
  run_bin -1 team-worker T7 builder "$wt1" -- go
  assert_contains "$output" "T7 has no Discord thread; open one first with team-thread"
  thread T8
  run_bin -1 team-worker T7 builder "$wt1" -- go
  assert_contains "$output" "T7 has no Discord thread"
  assert_equal "$(stub_calls claude)" ""
}

@test "a primary checkout or a directory outside git is refused" {
  thread T7
  # From another directory, so git's relative answers would be read against the wrong one.
  cd "$HOME"
  run_bin -1 team-worker T7 builder "$primary" -- go
  assert_contains "$output" "$primary is a primary checkout, not a linked worktree"
  mkdir "$HOME/plain"
  run_bin -1 team-worker T7 builder "$HOME/plain" -- go
  assert_contains "$output" "$HOME/plain is not a git checkout"
  run_bin -1 team-worker T7 builder "$HOME/missing" -- go
  assert_contains "$output" "$HOME/missing does not exist"
  assert_equal "$(stub_calls claude)" ""
  assert_equal "$(launches)" ""
}

@test "the session starts in the worktree with the role's settings, an empty MCP config and the prompt last" {
  thread T7
  run_bin -0 --separate-stderr team-worker T7 builder "$wt1" -- Read your brief "at brief.md"
  assert_equal "$output" "4f2a9c1e"
  assert_equal "$(cat "$STUB_CALLS/claude.cwd")" "$wt1"

  local t=$TEAM_HOME/tasks/T7
  assert_equal "$(stub_calls claude)" "$(jq -cn --arg t "$t" --arg roles "$REPO_ROOT/roles" '["--bg",
    "--strict-mcp-config", "--mcp-config", "\($t)/mcp.builder.json",
    "--settings", "\($t)/settings.builder.json",
    "--append-system-prompt-file", "\($roles)/builder.md",
    "--permission-mode", "auto", "--name", "T7-builder", "Read your brief at brief.md"]')"
  assert_equal "$(jq -c . "$t/mcp.builder.json")" '{"mcpServers":{}}'
}

@test "role settings are layered on the worker settings, permission and hook lists concatenated" {
  fake_checkout
  thread T7
  run_fake T7 planner "$wt1" -- go
  assert_equal "$status" "0"
  assert_equal "$(jq -cS . "$TEAM_HOME/tasks/T7/settings.planner.json")" "$(jq -cnS --arg code "$code" '{
    disableClaudeAiConnectors: true, env: {A: "worker", B: "planner"},
    permissions: {deny: ["Bash(git clean*)", "Bash(gh pr merge*)", "Bash(git push*)"], allow: ["Read", "Edit"]},
    hooks: {PreToolUse: [{matcher: "Bash", hooks: [{type: "command", command: "\($code)/bin/hooks/w"}]},
        {hooks: [{type: "command", command: "\($code)/bin/hooks/x \($code)"}]}],
      Stop: [{hooks: [{type: "command", command: "s"}]}]}}')"
}

@test "every role's settings run the fence hook on Bash; the planner's and reviewer's add the edit hook" {
  thread T7
  local role settings
  for role in planner builder reviewer; do
    run_bin -0 team-worker T7 "$role" "$wt1" -- go
    settings=$TEAM_HOME/tasks/T7/settings.$role.json
    assert_equal "$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command' "$settings")" \
      "$REPO_ROOT/bin/hooks/lease-fence"
    if [[ $role == builder ]]; then
      assert_equal "$(jq '.hooks.PreToolUse | length' "$settings")" 1
    else
      assert_equal "$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Edit|Write|MultiEdit|NotebookEdit") | .hooks[].command' "$settings")" \
        "$REPO_ROOT/bin/hooks/scratch-only-edits"
      assert_equal "$(jq '.hooks.PreToolUse | length' "$settings")" 2
    fi
    assert_equal "$(jq -r '.permissions.deny | index("Bash(gh pr merge*)") != null' "$settings")" true
  done
  [[ -x $REPO_ROOT/bin/hooks/scratch-only-edits && -x $REPO_ROOT/bin/hooks/lease-fence ]]
}

@test "toolkits add their plugin directories and only their MCP servers" {
  fake_checkout
  thread T7
  run_fake T7 planner "$wt1" --toolkit kit-a --toolkit kit-b --toolkit kit-c -- go
  assert_equal "$status" "0"
  assert_equal "$(jq -cS . "$TEAM_HOME/tasks/T7/mcp.planner.json")" \
    '{"mcpServers":{"alpha":{"command":"a"},"beta":{"command":"b"},"gamma":{"command":"c"}}}'
  assert_equal "$(stub_calls claude | jq -c '[index("--plugin-dir") as $i | .[$i:$i + 6]]')" \
    "$(jq -cn --arg k "$code/toolkits" '[["--plugin-dir", "\($k)/kit-a", "--plugin-dir", "\($k)/kit-b", "--plugin-dir", "\($k)/kit-c"]]')"
  assert_equal "$(launches | jq -c .toolkits)" '["kit-a","kit-b","kit-c"]'
}

@test "a session that started without its prompt, or printed no id, is refused and not logged" {
  thread T7
  rm "$STUB_FIXTURES/claude.sh"
  stub_reply claude "Started background session 4f2a9c1e. It is waiting: send a prompt to start."
  run_bin -1 team-worker T7 builder "$wt1" -- go
  assert_contains "$output" "the session started without its prompt"
  stub_reply claude "Something went wrong"
  run_bin -1 team-worker T7 builder "$wt1" -- go
  assert_contains "$output" "could not read the session id from: Something went wrong"
  assert_equal "$(launches)" ""
}

@test "T0, the load check, needs no thread and no lease, and is not logged" {
  # No lease anywhere: no origin to read one from, and no team name to hold one under.
  git -C "$TEAM_HOME" remote remove origin
  rm "$HOME/.config/agent-team/machine"
  run_bin -0 team-worker T0 planner "$wt1" -- go
  assert_equal "$output" "4f2a9c1e"
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" ""
}

@test "a legacy task with no opened event launches in any linked worktree, without project or branch" {
  thread T7
  run_bin -0 team-worker T7 builder "$wt2" -- go
  assert_equal "$(launches)" \
    "$(jq -cn --arg wt "$wt2" '{task: "T7", event: "launch", role: "builder", session: "4f2a9c1e", worktree: $wt, toolkits: [], machine: "home-pc"}')"
  run_bin -0 team-log --check
}

@test "an opened task launches in its own worktree, logging the project and branch" {
  thread T7
  opened T7 proj feat/T7-one "$wt1"
  # A relative path through a symlink still names the same worktree.
  ln -s "$HOME/slots" "$HOME/link"
  cd "$HOME"
  run_bin -0 team-worker T7 builder link/proj/1 -- go
  assert_equal "$(launches)" "$(jq -cn --arg wt "$wt1" '{task: "T7", event: "launch", role: "builder",
    session: "4f2a9c1e", worktree: $wt, toolkits: [], project: "proj", branch: "feat/T7-one", machine: "home-pc"}')"
  run_bin -0 team-log --check
}

@test "an opened task launches in a worktree added from a second project" {
  local other
  other=$(make_repo other)
  git -C "$other" worktree add -q -b chore/T7-two "$HOME/slots/other/1"
  thread T7
  opened T7 proj feat/T7-one "$wt1"
  ledger_line --arg wt "$HOME/slots/other/1" '{ts: (now | todate), task: "T7", event: "worktree-added",
    project: "other", branch: "chore/T7-two", base: "main", base_sha: "0123456", worktree: $wt}'
  run_bin -0 team-worker T7 builder "$HOME/slots/other/1" -- go
  assert_equal "$(launches | jq -c '[.project, .branch, .worktree]')" \
    "$(jq -cn --arg wt "$HOME/slots/other/1" '["other", "chore/T7-two", $wt]')"
}

@test "an opened task refuses a worktree that is not one of its open worktrees" {
  thread T7
  opened T7 proj feat/T7-one "$wt1"
  run_bin -1 team-worker T7 builder "$wt2" -- go
  assert_contains "$output" "$wt2 is not one of T7's open worktrees:"
  assert_contains "$output" "  $wt1 (proj, feat/T7-one)"

  ledger_line --arg wt "$wt1" '{ts: (now | todate), task: "T7", event: "worktree-returned", project: "proj", worktree: $wt}'
  run_bin -1 team-worker T7 builder "$wt1" -- go
  assert_contains "$output" "$wt1 is not one of T7's open worktrees: it has none"
  assert_equal "$(stub_calls claude)" ""
  assert_equal "$(launches)" ""
}

@test "a worktree recorded under another home launches as the same path under this HOME" {
  thread T7
  opened T7 proj feat/T7-one /home/someone/slots/proj/1
  cp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/before"
  run_bin -0 team-worker T7 builder "$wt1" -- go
  assert_equal "$(launches | jq -c '[.project, .branch, .worktree]')" \
    "$(jq -cn --arg wt "$wt1" '["proj", "feat/T7-one", $wt]')"
  # Returned on the other machine, under its own home: no longer open here either.
  ledger_line '{ts: (now | todate), task: "T7", event: "worktree-returned", project: "proj",
    worktree: "/Users/someone/slots/proj/1"}'
  run_bin -1 team-worker T7 builder "$wt1" -- go
  assert_contains "$output" "$wt1 is not one of T7's open worktrees: it has none"
  # The recorded events stay as they were written.
  assert_equal "$(head -n 2 "$TEAM_HOME/ledger.jsonl")" "$(cat "$BATS_TEST_TMPDIR/before")"
}

@test "after a worktree-moved the task launches in the new worktree, not the recorded one" {
  thread T7
  opened T7 proj feat/T7-one /home/someone/slots/proj/1
  git -C "$primary" worktree remove "$wt2"
  git -C "$primary" worktree move "$wt1" "$wt2"
  ledger_line --arg wt "$wt2" '{ts: (now | todate), task: "T7", event: "worktree-moved", project: "proj",
    branch: "feat/T7-one", from: "/home/someone/slots/proj/1", worktree: $wt, machine: "home-pc"}'
  run_bin -0 team-worker T7 builder "$wt2" -- go
  assert_equal "$(launches | jq -c '[.project, .branch, .worktree]')" \
    "$(jq -cn --arg wt "$wt2" '["proj", "feat/T7-one", $wt]')"
  git -C "$primary" worktree add -q -b feat/T9-other "$wt1"
  run_bin -1 team-worker T7 builder "$wt1" -- go
  assert_contains "$output" "$wt1 is not one of T7's open worktrees:"$'\n'"  $wt2 (proj, feat/T7-one)"
  run_bin -0 team-log --check
}

@test "the launch names this machine" {
  thread T7
  opened T7 proj feat/T7-one "$wt1"
  run_bin -0 team-worker T7 builder "$wt1" -- go
  assert_equal "$(launches | jq -r .machine)" "home-pc"
  run_bin -0 team-log --check
}

@test "with the lease held by the other machine it refuses, naming the holder: no session, no ledger line" {
  thread T7
  opened T7 proj feat/T7-one "$wt1"
  cp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/before"
  make_machine laptop
  run_bin -0 team-lease release
  on_machine laptop run_bin -0 team-lease take
  run_bin -1 --separate-stderr team-worker T7 builder "$wt1" -- go
  assert_equal "$output" ""
  assert_contains "$stderr" "team-lease: home-pc no longer holds the lease: laptop holds it (epoch 2"
  assert_contains "$stderr" "team-worker: laptop holds the lease: hand off there, then team-resume here"
  assert_equal "$(stub_calls claude)" ""
  cmp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/before"
  [[ ! -e $TEAM_HOME/tasks/T7/settings.builder.json ]]
}

@test "with GitHub unreachable it refuses: a worker never starts offline" {
  thread T7
  cp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/before"
  git -C "$TEAM_HOME" remote set-url origin https://127.0.0.1:9/agent-team.git
  run_bin -1 --separate-stderr team-worker T7 planner "$wt1" -- go
  assert_equal "$output" ""
  assert_contains "$stderr" "team-lease: GitHub is unreachable"
  assert_contains "$stderr" "team-worker: GitHub unreachable; a worker never starts offline"
  assert_equal "$(stub_calls claude)" ""
  cmp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/before"
}

@test "with the lease released, or no team name for this machine, it refuses" {
  thread T7
  run_bin -0 team-lease release
  run_bin -1 --separate-stderr team-worker T7 builder "$wt1" -- go
  assert_contains "$stderr" "team-lease: the lease is released (last held by home-pc, epoch 1)"
  assert_contains "$stderr" "team-worker: a worker starts only on the machine that holds the lease"

  run_bin -0 team-lease take
  echo Home-PC >"$HOME/.config/agent-team/machine"
  run_bin -1 --separate-stderr team-worker T7 builder "$wt1" -- go
  assert_contains "$stderr" "not a lower-case kebab-case name like home-pc"
  assert_contains "$stderr" "team-worker: a worker starts only on the machine that holds the lease"
  assert_equal "$(stub_calls claude)" ""
  assert_equal "$(launches)" ""
}

@test "every role's generated settings isolate peer machines" {
  thread T7
  local role
  for role in planner builder reviewer; do
    run_bin -0 team-worker T7 "$role" "$wt1" -- go
    assert_equal "$(jq .isolatePeerMachines "$TEAM_HOME/tasks/T7/settings.$role.json")" true
  done
}

@test "every role's generated settings deny sudo and starting a Claude session of its own" {
  thread T7
  local role settings command
  for role in planner builder reviewer; do
    run_bin -0 team-worker T7 "$role" "$wt1" -- go
    settings=$TEAM_HOME/tasks/T7/settings.$role.json
    # shellcheck disable=SC2088 # ~ is part of the command as an agent types it
    for command in "sudo" "sudo -n true" "sudo pacman -S jq" "claude --bg --name x go" \
      "claude --background go" "claude -p hi" "claude --print hi" "claude --model opus -p hi" \
      "claude --settings s.json --bg go" "claude --model opus --print hi" "claude agents" \
      "claude agents --json" "claude respawn --all" "$HOME/.local/bin/claude -p hi" \
      "~/.local/bin/claude --bg go" "/usr/bin/claude --model opus --print hi" \
      "$HOME/.local/bin/claude agents"; do
      denied_in "$settings" "$command" || { echo "$role allows: $command" >&2; return 1; }
    done
    for command in "claude --version" "claude auth status --json" "claude mcp list" \
      "grep -n 'claude --bg' bin/team-worker" "grep -rn sudo tests" "git commit -m 'deny sudo'" \
      "ls ~/.claude/projects" "pseudo-tool -p"; do
      if denied_in "$settings" "$command"; then echo "$role denies: $command" >&2; return 1; fi
    done
  done
}

@test "a closed task is refused, opened or legacy" {
  thread T7
  opened T7 proj feat/T7-one "$wt1"
  ledger_line '{ts: (now | todate), task: "T7", event: "closed", archive: [], returned: [], kept: []}'
  run_bin -1 team-worker T7 builder "$wt1" -- go
  assert_contains "$output" "T7 is closed"
  thread T8
  ledger_line '{ts: "2026-10-01T00:00:00Z", task: "T8", event: "closed"}'
  run_bin -1 team-worker T8 builder "$wt2" -- go
  assert_contains "$output" "T8 is closed"
  assert_equal "$(stub_calls claude)" ""
  assert_equal "$(launches)" ""
}

# The claude stub for an ops launch: claude agents --json lists $STUB_FIXTURES/agents.json (no
# session by default), and claude --bg starts a session.
ops_stub() {
  echo "${1:-[]}" >"$STUB_FIXTURES/agents.json"
  stub_script claude <<'SH'
if [[ $1 == agents ]]; then cat "$STUB_FIXTURES/agents.json"; exit 0; fi
printf '%s\n' "$PWD" >>"$STUB_CALLS/claude.cwd"
echo "Started background session 5b3c0d2f (${*: -2:1}). Attach with: claude attach 5b3c0d2f"
SH
}

request=https://discord.com/channels/1/2/3

# The claude --bg calls made, without claude agents.
bg_calls() {
  stub_calls claude | jq -c 'select(.[0] == "--bg")'
}

# prod-write's tools in both naming forms: the --mcp-config form and the plugin form.
PROD_WRITE_TOOLS=(insert-many update-many delete-many create-index drop-index)
prod_write_names() {
  local tool
  for tool in "${PROD_WRITE_TOOLS[@]}"; do
    echo "mcp__prod-write__$tool"
    echo "mcp__plugin_prod-write_prod-write__$tool"
  done
}

# assert_prod_write_gated <settings>: an ask rule names every prod-write tool in both forms, the
# glob proven live (T16 ticket 02) covers them all, and no allow rule matches any of them, read
# as a glob the way Claude Code reads a rule's *.
assert_prod_write_gated() {
  local name rule
  while IFS= read -r name; do
    jq -e --arg n "$name" '.permissions.ask | index($n) != null' "$1" >/dev/null ||
      { echo "no ask rule names $name" >&2; return 1; }
    # shellcheck disable=SC2053 # the rules are globs
    [[ $name == mcp__*prod-write* ]] || { echo "the ask glob misses $name" >&2; return 1; }
    while IFS= read -r rule; do
      # shellcheck disable=SC2053
      [[ $name != $rule ]] || { echo "allow rule $rule matches $name" >&2; return 1; }
    done < <(jq -r '.permissions.allow[]?' "$1")
  done < <(prod_write_names)
  jq -e '.permissions.ask | index("mcp__*prod-write*") != null' "$1" >/dev/null
}

@test "an ops launch is restricted to the allowlisted tools and logs Daniel's request" {
  thread T7
  opened T7 proj feat/T7-one "$wt1"
  ops_stub
  run_bin -0 --separate-stderr team-worker T7 ops "$wt1" --toolkit prod-read --request "$request" -- Answer the request
  assert_equal "$output" "5b3c0d2f"
  assert_equal "$(cat "$STUB_CALLS/claude.cwd")" "$wt1"

  local t=$TEAM_HOME/tasks/T7
  assert_equal "$(stub_calls claude | head -n 1)" '["agents","--json"]'
  assert_equal "$(bg_calls)" "$(jq -cn --arg t "$t" --arg code "$REPO_ROOT" '["--bg",
    "--restricted", "--tools", "Read,Glob,Grep,Edit,Write,ToolSearch,SendMessage,ListAgents,Skill",
    "--strict-mcp-config", "--mcp-config", "\($t)/mcp.ops.json",
    "--plugin-dir", "\($code)/toolkits/prod-read",
    "--settings", "\($t)/settings.ops.json",
    "--append-system-prompt-file", "\($code)/roles/ops.md",
    "--permission-mode", "auto", "--name", "T7-ops", "Answer the request"]')"
  assert_equal "$(launches)" "$(jq -cn --arg wt "$wt1" --arg r "$request" '{task: "T7", event: "launch",
    role: "ops", session: "5b3c0d2f", worktree: $wt, toolkits: ["prod-read"], project: "proj",
    branch: "feat/T7-one", machine: "home-pc", request: $r}')"
  run_bin -0 team-log --check
}

@test "the generated ops MCP config starts the real prod-read launcher and holds no secret" {
  thread T7
  ops_stub
  run_bin -0 team-worker T7 ops "$wt1" --toolkit prod-read --request "$request" -- go
  local mcp=$TEAM_HOME/tasks/T7/mcp.ops.json
  assert_equal "$(jq -c . "$mcp")" "$(jq -cn --arg code "$REPO_ROOT" '{mcpServers: {"prod-read": {command: "node",
    args: ["\($code)/toolkits/prod-read/scripts/start-server.mjs"]}}}')"
  run -1 grep -Eq '@TEAM_CODE@|@TASK@|mongodb(\+srv)?://|MDB_MCP|op://|password' "$mcp"
  # The worker settings' deny rules name mongodb+srv:// themselves.
  run -1 grep -Eq 'mongodb(\+srv)?://|MDB_MCP_CONNECTION|op://|password' \
    <(jq 'del(.permissions.deny)' "$TEAM_HOME/tasks/T7/settings.ops.json")
}

@test "the generated ops settings allow only prod-read and .scratch edits, ask for every prod-write tool, and deny every outbound tool" {
  thread T7
  ops_stub
  run_bin -0 team-worker T7 ops "$wt1" --toolkit prod-read --request "$request" -- go
  local s=$TEAM_HOME/tasks/T7/settings.ops.json rule
  assert_equal "$(jq -c .permissions.allow "$s")" '["mcp__prod-read__*","Edit(./.scratch/**)"]'
  # The write rules hold even in a read session, where prod-write is not loaded.
  assert_prod_write_gated "$s"
  assert_equal "$(jq '.permissions.ask | length' "$s")" 11
  for rule in Bash WebFetch WebSearch Agent NotebookEdit Artifact ArtifactComments ArtifactData SendUserFile \
    PushNotification SendFeedback DesignSync EnterWorktree CronCreate RemoteTrigger ScheduleWakeup \
    'Read(//proc/**)' 'Bash(op *)' 'Bash(gh pr merge*)'; do
    jq -e --arg r "$rule" '.permissions.deny | index($r) != null' "$s" >/dev/null ||
      { echo "missing deny rule $rule" >&2; return 1; }
  done
  # A worktree's .env files (Conventioner's back-end/.env among them) at any depth. Claude Code
  # applies Read rules to Grep and Glob too, and never matches a Grep(path) or Glob(path) rule.
  jq -e '.permissions.deny | index("Read(**/.env*)") != null' "$s" >/dev/null
  assert_equal "$(jq -r '.permissions.deny[] | select(test("^(Grep|Glob)\\("))' "$s")" ""
  assert_equal "$(jq -c .env "$s")" '{"MCP_TIMEOUT":"120000"}'
  # --restricted ignores the user settings, and without this the coordinator's replies (the
  # write protocol's answers) never reach the session (T16 ticket 04's live check).
  assert_equal "$(jq -r .crossSessionInbound "$s")" accept
  # The same for the push of a permission prompt to Daniel's phone: without these no write
  # prompt reached it (T16 ticket 08's first live run).
  assert_equal "$(jq -c '[.remoteControlAtStartup, .inputNeededNotifEnabled]' "$s")" '[true,true]'
  # The Skill tool is there for the toolkits' skills only: without this the bundled skills and the
  # built-in commands the Skill tool reaches (/init, /security-review) came too (T16 ticket 09's
  # live check).
  assert_equal "$(jq -r .disableBundledSkills "$s")" true
  # A skill's inline shell would run a command in a role that has no shell.
  assert_equal "$(jq -r .disableSkillShellExecution "$s")" true
  # disableBundledSkills leaves the built-in plugin that carries the plugin-authoring skill (T16
  # ticket 09's second live check); the worker settings' own plugin entries stay.
  assert_equal "$(jq -c .enabledPlugins "$s")" \
    '{"discord@claude-plugins-official":false,"mongodb-atlas@claude-plugins-official":false,"cc-plugin-plugin-authoring@builtin":false}'
  # The shared hooks come first (lease-fence on Bash, a tool ops lacks), then the role's own.
  assert_equal "$(jq -r '.hooks.PreToolUse[] | "\(.matcher) \(.hooks[0].command)"' "$s" | sed -n 1,2p)" \
    "Bash $REPO_ROOT/bin/hooks/lease-fence
Edit|Write|MultiEdit|NotebookEdit $REPO_ROOT/bin/hooks/scratch-only-edits"
  # The ops log goes to the team home's task directory, which is not this checkout's in a test.
  local event
  for event in PreToolUse PostToolUse PostToolUseFailure; do
    assert_equal "$(jq -c --arg e "$event" '[.hooks[$e][].hooks[0] | select(.command | endswith("/ops-log"))
      | [.command, .args]]' "$s")" \
      "$(jq -cn --arg c "$REPO_ROOT/bin/hooks/ops-log" --arg t "$TEAM_HOME/tasks/T7" '[[$c, [$t]]]')"
  done
}

@test "a write launch adds prod-write's plugin and server beside prod-read's, every write tool behind an ask rule" {
  thread T7
  opened T7 proj feat/T7-one "$wt1"
  ops_stub
  run_bin -0 team-worker T7 ops "$wt1" --toolkit prod-read --toolkit prod-write --request "$request" -- Make the change
  local t=$TEAM_HOME/tasks/T7
  assert_equal "$(bg_calls)" "$(jq -cn --arg t "$t" --arg code "$REPO_ROOT" '["--bg",
    "--restricted", "--tools", "Read,Glob,Grep,Edit,Write,ToolSearch,SendMessage,ListAgents,Skill",
    "--strict-mcp-config", "--mcp-config", "\($t)/mcp.ops.json",
    "--plugin-dir", "\($code)/toolkits/prod-read", "--plugin-dir", "\($code)/toolkits/prod-write",
    "--settings", "\($t)/settings.ops.json",
    "--append-system-prompt-file", "\($code)/roles/ops.md",
    "--permission-mode", "auto", "--name", "T7-ops", "Make the change"]')"

  local mcp=$t/mcp.ops.json
  assert_equal "$(jq -c . "$mcp")" "$(jq -cn --arg code "$REPO_ROOT" '{mcpServers: {
    "prod-read": {command: "node", args: ["\($code)/toolkits/prod-read/scripts/start-server.mjs"]},
    "prod-write": {command: "node", args: ["\($code)/toolkits/prod-write/scripts/start-server.mjs"]}}}')"
  run -1 grep -Eq '@TEAM_CODE@|@TASK@|mongodb(\+srv)?://|MDB_MCP|op://|password' "$mcp"

  local s=$t/settings.ops.json
  assert_prod_write_gated "$s"
  assert_equal "$(jq -c .permissions.allow "$s")" '["mcp__prod-read__*","Edit(./.scratch/**)"]'
  # The ops log's hooks cover both toolkits' tools, and block a write whose line is lost.
  assert_equal "$(jq -r '.hooks.PreToolUse[] | select(.hooks[0].command | endswith("/ops-log"))
    | "\(.matcher) \(.hooks[0].onFailure)"' "$s")" '^mcp__.*prod-(read|write).*__ block'
  run -1 grep -Eq 'mongodb(\+srv)?://|MDB_MCP_CONNECTION|op://|password' <(jq 'del(.permissions.deny)' "$s")

  assert_equal "$(launches | jq -c '[.toolkits, .request]')" "$(jq -cn --arg r "$request" '[["prod-read", "prod-write"], $r]')"
  run_bin -0 team-log --check
}

@test "only the ops role is restricted" {
  thread T7
  local role
  for role in planner builder reviewer; do
    : >"$STUB_CALLS/claude.log"
    run_bin -0 team-worker T7 "$role" "$wt1" -- go
    assert_equal "$(stub_calls claude | jq -c 'map(select(. == "--restricted" or . == "--tools"))')" '[]'
  done
}

@test "production toolkits are refused for every role but ops, with nothing started or logged" {
  thread T7
  ops_stub
  local role
  for role in planner builder reviewer; do
    run_bin -1 team-worker T7 "$role" "$wt1" --toolkit prod-read -- go
    assert_contains "$output" "toolkit 'prod-read' is for the ops role only"
    run_bin -1 team-worker T7 "$role" "$wt1" --toolkit prod-write -- go
    assert_contains "$output" "toolkit 'prod-write' is for the ops role only"
  done
  run_bin -2 team-worker T7 builder "$wt1" --request "$request" -- go
  assert_contains "$output" "--request is for the ops role only"
  assert_equal "$(stub_calls claude)" ""
  assert_equal "$(launches)" ""
}

@test "an ops launch without prod-read, prod-write without prod-read, or a launch without Daniel's request is refused" {
  fake_checkout
  mkdir -p "$code/toolkits/prod-read" "$code/toolkits/prod-write"
  cp "$REPO_ROOT/roles/ops.md" "$code/roles/" && cp "$REPO_ROOT/settings/ops.json" "$code/settings/"
  thread T7
  ops_stub
  run_fake T7 ops "$wt1" --request "$request" -- go
  assert_equal "$status" 1
  assert_contains "$output" "the ops role needs --toolkit prod-read"
  run_fake T7 ops "$wt1" --toolkit prod-write --request "$request" -- go
  assert_equal "$status" 1
  assert_contains "$output" "prod-write needs --toolkit prod-read beside it"
  run_fake T7 ops "$wt1" --toolkit prod-read -- go
  assert_equal "$status" 1
  assert_contains "$output" "the ops role needs --request <the link to Daniel's Discord message>"
  run_fake T7 ops "$wt1" --toolkit prod-read --request "" -- go
  assert_equal "$status" 2
  assert_contains "$output" "--request needs Daniel's Discord message link"
  assert_equal "$(stub_calls claude)" ""
  assert_equal "$(launches)" ""
}

@test "an ops launch is refused while any task's ops session is listed" {
  thread T7
  ops_stub '[{"id": "11111111", "name": "T7-builder"}, {"id": "22222222", "name": "T5-ops", "state": "done"}]'
  run_bin -1 team-worker T7 ops "$wt1" --toolkit prod-read --request "$request" -- go
  assert_contains "$output" "an ops session is already listed: T5-ops (22222222); end it with team-ops-end first"
  assert_equal "$(bg_calls)" ""
  assert_equal "$(launches)" ""

  stub_reply claude "not json"
  rm "$STUB_FIXTURES/claude.sh"
  run_bin -1 team-worker T7 ops "$wt1" --toolkit prod-read --request "$request" -- go
  assert_contains "$output" "cannot read the live session list"
  assert_equal "$(bg_calls)" ""
}

@test "no placeholder is left in any role's generated settings and MCP config from this checkout" {
  thread T7
  local role
  for role in planner builder reviewer; do
    run_bin -0 team-worker T7 "$role" "$wt1" -- go
    run -1 grep -Eq '@[A-Z_]+@' "$TEAM_HOME/tasks/T7/settings.$role.json" "$TEAM_HOME/tasks/T7/mcp.$role.json"
  done
  ops_stub
  run_bin -0 team-worker T7 ops "$wt1" --toolkit prod-read --toolkit prod-write --request "$request" -- go
  grep -q "$REPO_ROOT/bin/hooks/ops-log" "$TEAM_HOME/tasks/T7/settings.ops.json"
  grep -q "$REPO_ROOT/toolkits/prod-write/" "$TEAM_HOME/tasks/T7/mcp.ops.json"
  run -1 grep -Eq '@[A-Z_]+@' "$TEAM_HOME/tasks/T7/settings.ops.json" "$TEAM_HOME/tasks/T7/mcp.ops.json"
}

@test "@TEAM_CODE@, @TASK@ and @TASK_DIR@ are substituted in the settings and the MCP config" {
  fake_checkout
  echo '{"hooks": {"PreToolUse": [{"hooks": [{"type": "command", "command": "@TEAM_CODE@/bin/hooks/x @TASK@", "args": ["@TASK_DIR@"]}]}]}}' \
    >"$code/settings/planner.json"
  echo '{"mcpServers": {"alpha": {"command": "@TEAM_CODE@/a", "args": ["--task", "@TASK@", "@TASK_DIR@"]}}}' >"$code/toolkits/kit-a/.mcp.json"
  thread T7
  run_fake T7 planner "$wt1" --toolkit kit-a -- go
  assert_equal "$status" 0
  # The role's hook comes after the shared settings' own.
  assert_equal "$(jq -c '.hooks.PreToolUse[-1].hooks[0] | [.command, .args[0]]' "$TEAM_HOME/tasks/T7/settings.planner.json")" \
    "$(jq -cn --arg code "$code" --arg t "$TEAM_HOME/tasks/T7" '["\($code)/bin/hooks/x T7", $t]')"
  assert_equal "$(jq -c . "$TEAM_HOME/tasks/T7/mcp.planner.json")" \
    "$(jq -cn --arg code "$code" --arg t "$TEAM_HOME/tasks/T7" '{mcpServers: {alpha: {command: "\($code)/a", args: ["--task", "T7", $t]}}}')"
}
