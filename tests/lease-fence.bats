#!/usr/bin/env bats
# hooks/lease-fence: the PreToolUse hook that keeps a machine that lost the lease quiet. It blocks
# the coordinator's Discord posts when this machine is fenced or the lease on origin names another
# holder, and a worker's git push when fenced. home-pc holds the lease on a bare origin; laptop is
# the other machine.

load helpers/common

setup() {
  sandbox
  hold_lease home-pc >/dev/null
  make_machine laptop
  state=$HOME/.local/state/agent-team
  # Every git call goes through this wrapper, which logs each ls-remote and fetch.
  local real_git
  real_git=$(command -v git)
  cat >"$BATS_TEST_TMPDIR/stubs/git" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  case \$arg in ls-remote | fetch) echo "\$arg" >>"$STUB_CALLS/git-net.log" ;; esac
done
exec "$real_git" "\$@"
EOF
  chmod +x "$BATS_TEST_TMPDIR/stubs/git"
}

# The hook on a call to <tool> with <input> (JSON), as Claude Code sends it:
# hook <status> <tool> [<input>]
hook() {
  run_bin "$1" --separate-stderr hooks/lease-fence <<<"$(jq -cn --arg tool "$2" --argjson input "${3:-"{}"}" \
    '{hook_event_name: "PreToolUse", cwd: env.HOME, tool_name: $tool, tool_input: $input}')"
}

reply() {
  hook "$1" mcp__plugin_discord_discord__reply '{"chat_id": "1563", "text": "on it"}'
}

bash_call() {
  hook "$1" Bash "$(jq -cn --arg c "$2" '{command: $c}')"
}

fence() {
  echo '{"since": "2026-10-22T14:00:00Z", "holder": "laptop", "epoch": 2}' >"$state/fenced"
}

# How many times the hook reached origin with git ls-remote.
probes() {
  cat "$STUB_CALLS/git-net.log" 2>/dev/null | grep -c ls-remote || true
}

# Make the cached probe <seconds> old.
age_probe() {
  jq --argjson s "$1" '.checked_at = (now - $s | floor | todate)' "$state/probe.json" >"$state/probe.json.new"
  mv "$state/probe.json.new" "$state/probe.json"
}

@test "a fenced machine's Discord reply, react and edit are blocked, with the reason on stderr" {
  fence
  reply -2
  assert_equal "$output" ""
  assert_equal "$stderr" "Blocked: home-pc is fenced since 2026-10-22T14:00:00Z (holder seen laptop, epoch 2): a fenced machine posts nothing to Discord; the coordinator on the holder answers there."
  hook -2 mcp__plugin_discord_discord__react '{"chat_id": "1563", "message_id": "9", "emoji": "x"}'
  hook -2 mcp__plugin_discord_discord__edit_message '{"chat_id": "1563", "message_id": "9", "text": "x"}'
  # The fence alone decides: origin is not asked.
  assert_equal "$(probes)" 0
}

@test "a reply is allowed while the lease on origin is this machine's own last write, its release included" {
  reply -0
  assert_equal "$stderr" ""
  run -0 "$REPO_ROOT/bin/team-lease" renew
  rm "$state/probe.json"
  reply -0
  run -0 "$REPO_ROOT/bin/team-lease" release
  rm "$state/probe.json"
  reply -0
}

@test "a reply is blocked when the lease on origin names another holder, before any fence" {
  steal_lease laptop home-pc
  local refs
  refs=$(git -C "$TEAM_HOME" for-each-ref)
  reply -2
  # The new lease was fetched without moving a ref: team-lease's refs are its own.
  assert_equal "$(git -C "$TEAM_HOME" for-each-ref)" "$refs"
  grep -qx fetch "$STUB_CALLS/git-net.log"
  assert_equal "$stderr" "Blocked: home-pc no longer holds the lease: origin names laptop (held, epoch 2): a machine that lost the lease posts nothing to Discord; the coordinator on the holder answers there."
  [[ ! -e $state/fenced ]]

  # Taken by laptop and released there: the epoch moved past this machine's.
  on_machine laptop run -0 "$REPO_ROOT/bin/team-lease" release
  rm "$state/probe.json"
  reply -2
  assert_contains "$stderr" "origin names laptop (released, epoch 2)"
}

@test "without its lease record the holder named decides; without a machine name only the fence does" {
  steal_lease laptop home-pc
  rm "$state/lease.json"
  reply -2
  assert_contains "$stderr" "home-pc no longer holds the lease: origin names laptop (held, epoch 2)"

  rm "$HOME/.config/agent-team/machine" "$state/probe.json"
  reply -0
  fence
  reply -2
  assert_contains "$stderr" "Blocked: this machine is fenced since 2026-10-22T14:00:00Z (holder seen laptop, epoch 2)"
}

@test "a reply is allowed when origin is unreachable: the heartbeat owns offline" {
  steal_lease laptop home-pc
  git -C "$TEAM_HOME" remote set-url origin https://127.0.0.1:9/agent-team.git
  reply -0
  assert_equal "$stderr" ""
  jq -e '.reachable == false' "$state/probe.json"
}

@test "origin is asked at most once a minute: a reply within it uses the cached probe" {
  reply -0
  assert_equal "$(probes)" 1
  jq -e '.reachable == true and (.tip | length) == 40 and ((.checked_at | fromdateiso8601) > now - 60)' "$state/probe.json"
  reply -0
  assert_equal "$(probes)" 1

  # A steal inside the minute goes unseen until the probe is a minute old.
  steal_lease laptop home-pc
  : >"$STUB_CALLS/git-net.log"
  age_probe 30
  reply -0
  assert_equal "$(probes)" 0
  age_probe 61
  reply -2
  assert_equal "$(probes)" 1
  reply -2
  assert_equal "$(probes)" 1
}

@test "a fenced worker's git push is blocked, in every form; other commands pass" {
  local command pushes=("git push" "git push -u origin feat/T7-x" "git -C /home/x/wt push origin HEAD"
    "cd wt && git push" "/usr/bin/git push" "git --no-pager push" $'git add -A\ngit push')
  for command in "${pushes[@]}"; do
    bash_call -0 "$command"
  done
  fence
  for command in "${pushes[@]}"; do
    bash_call -2 "$command"
    assert_equal "$stderr" "Blocked: home-pc is fenced since 2026-10-22T14:00:00Z (holder seen laptop, epoch 2): a fenced machine pushes nothing; commit locally and stop."
  done
  for command in "git status" "git commit -m 'push it later'" "git log --oneline origin/push" \
    "grep -rn 'git push' bin" "git stash push -m wip" "gh pr view 6"; do
    bash_call -0 "$command"
  done
  assert_equal "$(probes)" 0
}

@test "every other tool passes at once, fenced or not, and never asks origin" {
  fence
  hook -0 Read '{"file_path": "/etc/hosts"}'
  hook -0 mcp__plugin_discord_discord__fetch_messages '{"channel": "1563"}'
  hook -0 Edit '{"file_path": "x", "old_string": "a", "new_string": "b"}'
  rm "$state/fenced"
  hook -0 Bash '{"command": "git push"}'
  assert_equal "$(probes)" 0
}
