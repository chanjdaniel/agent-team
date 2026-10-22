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
  cp -R "$REPO_ROOT/bin" "$code/bin"
  echo "You plan." >"$code/roles/planner.md"
  cat >"$code/settings/worker.json" <<'JSON'
{"disableClaudeAiConnectors": true, "env": {"A": "worker", "B": "worker"},
 "permissions": {"deny": ["Bash(git clean*)", "Bash(gh pr merge*)"], "allow": ["Read"]}}
JSON
  cat >"$code/settings/planner.json" <<'JSON'
{"env": {"B": "planner"}, "permissions": {"deny": ["Bash(git push*)"], "allow": ["Edit"]},
 "hooks": {"PreToolUse": [{"hooks": [{"type": "command", "command": "@TEAM_HOME@/bin/hooks/x @TEAM_HOME@"}]}]}}
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
  assert_contains "$output" "usage: team-worker <task> <role> <worktree> [--toolkit <name>]... -- <first prompt>"
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
  assert_contains "$output" "T7 has no Discord thread; open one first with bin/team-thread"
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

@test "role settings are layered on the worker settings, permission lists concatenated" {
  fake_checkout
  thread T7
  run_fake T7 planner "$wt1" -- go
  assert_equal "$status" "0"
  assert_equal "$(jq -cS . "$TEAM_HOME/tasks/T7/settings.planner.json")" "$(jq -cnS --arg code "$code" '{
    disableClaudeAiConnectors: true, env: {A: "worker", B: "planner"},
    permissions: {deny: ["Bash(git clean*)", "Bash(gh pr merge*)", "Bash(git push*)"], allow: ["Read", "Edit"]},
    hooks: {PreToolUse: [{hooks: [{type: "command", command: "\($code)/bin/hooks/x \($code)"}]}]}}')"
}

@test "the real planner and reviewer settings point the edit hook at this checkout" {
  thread T7
  local role
  for role in planner reviewer; do
    run_bin -0 team-worker T7 "$role" "$wt1" -- go
    assert_equal "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$TEAM_HOME/tasks/T7/settings.$role.json")" \
      "$REPO_ROOT/bin/hooks/scratch-only-edits"
    assert_equal "$(jq -r '.permissions.deny | index("Bash(gh pr merge*)") != null' "$TEAM_HOME/tasks/T7/settings.$role.json")" true
  done
  [[ -x $REPO_ROOT/bin/hooks/scratch-only-edits ]]
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
