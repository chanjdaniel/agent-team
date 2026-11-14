#!/usr/bin/env bats
# hooks/lease-fence: the PreToolUse hook that keeps a machine that lost the lease quiet. It blocks
# the coordinator's Discord posts, and its git push, team-merge, team-catch-up, team-open and
# team-close, when this machine is fenced or the lease on origin names another holder, the
# assistant's git push, team-assistant and team-current then too, a worker's git push when fenced,
# and a worker's git push, gh and team-thread wait, and the assistant's git push and gh, while the
# team holds offline. home-pc holds the lease on a bare origin; laptop is the other machine.

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

# The hook on the coordinator's Bash call <command>, with --coordinator: coordinator_call <status> <command>
coordinator_call() {
  run_bin "$1" --separate-stderr hooks/lease-fence --coordinator <<<"$(jq -cn --arg c "$2" \
    '{hook_event_name: "PreToolUse", cwd: env.HOME, tool_name: "Bash", tool_input: {command: $c}}')"
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

@test "with no team home named, a call the lease decides is blocked, saying the hook cannot tell; the others are judged as ever" {
  homeless() {
    run --separate-stderr env -u TEAM_HOME "$REPO_ROOT/bin/hooks/lease-fence" "${@:3}" <<<"$(jq -cn --arg tool "$1" \
      --argjson input "$2" '{hook_event_name: "PreToolUse", cwd: env.HOME, tool_name: $tool, tool_input: $input}')"
  }
  local cannot="Blocked: lease-fence cannot tell whether home-pc holds the lease, since neither TEAM_HOME nor ~/.config/agent-team/home names the team home; "
  [[ ! -e $HOME/.config/agent-team/home ]]
  homeless mcp__plugin_discord_discord__reply '{"chat_id": "1563", "text": "on it"}'
  assert_equal "$status" 2
  assert_contains "$stderr" "$cannot"
  assert_contains "$stderr" "; a guard that cannot decide refuses, so report it as BLOCKED and do not reach it another way."
  homeless Bash '{"command": "team-post T1 hi"}'
  assert_equal "$status" 2
  assert_contains "$stderr" "$cannot"
  homeless Bash '{"command": "git push"}' --coordinator
  assert_equal "$status" 2
  assert_contains "$stderr" "$cannot"
  homeless Bash '{"command": "team-current"}' --assistant
  assert_equal "$status" 2
  assert_contains "$stderr" "$cannot"
  # The assistant's gh reads only the offline hold.
  homeless Bash '{"command": "gh pr view 6"}' --assistant
  assert_equal "$status:$stderr" 0:
  # A worker's push reads only this machine's fence, and other calls nothing.
  homeless Bash '{"command": "git push"}'
  assert_equal "$status:$stderr" 0:
  homeless Bash '{"command": "ls"}' --coordinator
  assert_equal "$status:$stderr" 0:
  fence
  homeless Bash '{"command": "git push"}'
  assert_equal "$status" 2
  assert_contains "$stderr" "Blocked: home-pc is fenced since 2026-10-22T14:00:00Z"
  # A team home that is not a directory is named so.
  run --separate-stderr env TEAM_HOME="$BATS_TEST_TMPDIR/gone" "$REPO_ROOT/bin/hooks/lease-fence" \
    <<<'{"tool_name": "mcp__plugin_discord_discord__react", "tool_input": {}}'
  assert_equal "$status" 2
  assert_contains "$stderr" "since the team home $BATS_TEST_TMPDIR/gone is not a directory; a guard"
}

@test "input it cannot read is refused, naming why" {
  local input
  for input in 'not json' '' '[]' '{}' '{"tool_input": {"command": "git push"}}' '{"tool_name": 5}' '"Bash"'; do
    run_bin -2 --separate-stderr hooks/lease-fence <<<"$input"
    [[ $stderr == "Blocked: lease-fence could not read the hook's input (JSON with a tool_name); a guard that cannot decide refuses, so report it as BLOCKED and do not reach it another way." ]] ||
      { printf 'input %s: stderr %s\n' "$input" "$stderr" >&2; return 1; }
  done
}

@test "a command failing inside it is a refusal that names the hook and the exit code" {
  # The read of the Bash call's command fails, after its input was read.
  fails_on_call jq .tool_input.command
  bash_call -2 ls
  assert_equal "$output" ""
  assert_equal "$stderr" "Blocked by lease-fence: it failed with exit 5 before it could decide, and a guard that cannot decide refuses; report it as BLOCKED and do not reach it another way."
  assert_equal "$(wc -l <"$STUB_CALLS/jq.failed")" 1
}

@test "a wrong argument on its command line refuses every call" {
  run_bin -2 --separate-stderr hooks/lease-fence --bogus <<<'{"tool_name": "Read", "tool_input": {}}'
  assert_equal "$stderr" "lease-fence: usage: lease-fence [--coordinator | --assistant]"
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

@test "while the team holds offline, a worker's git push, gh and gh-axi are blocked with the hold; other commands pass" {
  mkdir -p "$state"
  echo '{"since": "2026-10-22T13:05:00Z", "posted": true}' >"$state/offline"
  local command hold
  hold="Blocked: GitHub is unreachable (since $(date -d 2026-10-22T13:05:00Z +%H:%M)); the team is holding: commit locally, write handoff.md, send T<n> PAUSED offline, and wait."
  for command in "git push" "git -C /home/x/wt push origin HEAD" "cd wt && git push" "gh pr create --fill" \
    "gh-axi pr view 6" "cd wt && gh pr checks 6 --watch" "GH_REPO=a/b gh issue list" "/usr/bin/gh api user" \
    $'git commit -m wip\ngh pr view' "echo x | gh pr comment 6 -F -" "(gh pr view)" '$(gh api user)' \
    "{ gh pr view 6; }" "if true; then gh pr view 6; fi" "! gh pr view 6" "for n in 6; do gh pr view \$n; done"; do
    bash_call -2 "$command"
    assert_equal "$stderr" "$hold"
  done
  for command in "git status" "git commit -m 'gh pr later'" "grep -rn 'gh pr' bin" "ls ~/.config/gh" \
    "cat high.txt" "git log --grep gh" "ghost run" "echo gh-axi" "git commit -m 'then gh later'"; do
    bash_call -0 "$command"
  done
  # The hold is read from the flag alone: origin is never asked.
  assert_equal "$(probes)" 0
  rm "$state/offline"
  bash_call -0 "gh pr view 6"
}

@test "while the team holds offline, a worker's team-ci-wait is blocked with the hold, as gh is; otherwise it passes" {
  local command pr=https://github.com/me/shop/pull/6
  local waits=("team-ci-wait $pr" "/home/x/agent-team/bin/team-ci-wait $pr" "cd wt && team-ci-wait $pr"
    "GH_REPO=a/b team-ci-wait $pr" $'git commit -m wip\nteam-ci-wait '"$pr" "(team-ci-wait $pr)")
  local others=("echo team-ci-wait" "grep -rn 'team-ci-wait' bin" "team-ci-waiter $pr" "cat bin/team-ci-wait")
  for command in "${waits[@]}" "${others[@]}"; do
    bash_call -0 "$command"
    coordinator_call -0 "$command"
  done
  # A fenced machine's hold is on its pushes only.
  fence
  for command in "${waits[@]}"; do bash_call -0 "$command"; done
  rm "$state/fenced"

  echo '{"since": "2026-10-22T13:05:00Z", "posted": true}' >"$state/offline"
  for command in "${waits[@]}"; do
    bash_call -2 "$command"
    assert_equal "$stderr" "Blocked: GitHub is unreachable (since $(date -d 2026-10-22T13:05:00Z +%H:%M)); the team is holding: commit locally, write handoff.md, send T<n> PAUSED offline, and wait."
    coordinator_call -0 "$command"
  done
  for command in "${others[@]}"; do bash_call -0 "$command"; done
  assert_equal "$(probes)" 0
}

@test "the coordinator's push, team-merge, team-catch-up, team-open and team-close are blocked when fenced or when origin names another holder" {
  local command writes=("git push origin dev" "git -C ~/agent-team push" "team-merge T7" "team-catch-up T7"
    "/home/x/agent-team/bin/team-catch-up T7 --pr https://github.com/o/p/pull/6"
    "/home/x/agent-team/bin/team-merge T7 --method merge" "TEAM_HOME=x team-open conv feature feat x 'X'"
    "cd ~/agent-team && team-close T7" $'team-log T7 merged\nteam-close T7 --force')
  local others=("git status" "team-log T7 note" "team-snapshot" "gh pr view 6" "echo team-merge"
    "grep -rn 'team-open' bin" "team-opener" "git log --grep push" "team-catch-upper T7" "echo team-catch-up")
  # Held here: everything passes, origin asked once in the minute.
  for command in "${writes[@]}" "${others[@]}"; do
    coordinator_call -0 "$command"
  done
  assert_equal "$(probes)" 1

  # laptop takes the lease: once the probe is a minute old, the writes are blocked; the rest pass.
  run_bin -0 team-lease release
  on_machine laptop run_bin -0 team-lease take
  age_probe 61
  for command in "${writes[@]}"; do
    coordinator_call -2 "$command"
    assert_equal "$stderr" "Blocked: home-pc no longer holds the lease: origin names laptop (held, epoch 2): a machine that lost the lease pushes, merges, opens and closes nothing; the coordinator on the holder does."
  done
  for command in "${others[@]}"; do
    coordinator_call -0 "$command"
  done

  # Fenced: blocked from the fence alone, before origin is asked.
  fence
  age_probe 61
  : >"$STUB_CALLS/git-net.log"
  coordinator_call -2 "team-catch-up T7"
  assert_equal "$stderr" "Blocked: home-pc is fenced since 2026-10-22T14:00:00Z (holder seen laptop, epoch 2): a fenced machine pushes, merges, opens and closes nothing; the coordinator on the holder does."
  coordinator_call -2 "team-merge T7"
  assert_equal "$stderr" "Blocked: home-pc is fenced since 2026-10-22T14:00:00Z (holder seen laptop, epoch 2): a fenced machine pushes, merges, opens and closes nothing; the coordinator on the holder does."
  assert_equal "$(probes)" 0

  # A worker's Bash is not the coordinator's: its team commands are not its own to gate.
  rm "$state/fenced"
  bash_call -0 "team-merge T7"
  bash_call -0 "team-catch-up T7"
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

@test "team-post, team-ask and team-inbox are blocked for workers and the coordinator alike when fenced or when origin names another holder" {
  local command posts=("team-post T7 --file q.md" "/home/x/agent-team/bin/team-post --coordinator --file q.md"
    "cd wt && team-post T7 --thread task --file q.md" $'team-log T7 note\nteam-post T7 --file q.md'
    "team-post T7 --thread interview --file q.md --attach a.png --attach b.png"
    "/home/x/agent-team/bin/team-post T7 --thread interview --retract 1564000000000000001"
    "team-ask T7 sign-in --file q.md" "TZ=UTC ~/agent-team/bin/team-ask T7 sign-in --file q.md --from planner"
    "team-inbox" "/home/x/agent-team/bin/team-inbox")
  local others=("echo team-post" "grep -rn 'team-post' bin" "team-poster T7" "team-log T7 note"
    "team-asked T7" "team-inboxes" "cat bin/team-inbox")
  for command in "${posts[@]}" "${others[@]}"; do
    bash_call -0 "$command"
    coordinator_call -0 "$command"
  done

  steal_lease laptop home-pc
  age_probe 61
  for command in "${posts[@]}"; do
    bash_call -2 "$command"
    assert_equal "$stderr" "Blocked: home-pc no longer holds the lease: origin names laptop (held, epoch 2): a machine that lost the lease posts nothing to Discord; the coordinator on the holder answers there."
    coordinator_call -2 "$command"
    assert_equal "$stderr" "Blocked: home-pc no longer holds the lease: origin names laptop (held, epoch 2): a machine that lost the lease posts nothing to Discord; the coordinator on the holder answers there."
  done
  for command in "${others[@]}"; do
    bash_call -0 "$command"
    coordinator_call -0 "$command"
  done

  fence
  for command in "${posts[@]}"; do
    bash_call -2 "$command"
    assert_equal "$stderr" "Blocked: home-pc is fenced since 2026-10-22T14:00:00Z (holder seen laptop, epoch 2): a fenced machine posts nothing to Discord; the coordinator on the holder answers there."
    coordinator_call -2 "$command"
  done
}

@test "team-answer is blocked for workers and the coordinator alike when fenced or when origin names another holder" {
  local command answers=("team-answer T7 sign-in 1564000000000000001"
    "/home/x/agent-team/bin/team-answer T7 sign-in 1564000000000000001"
    "cd wt && TZ=UTC ~/agent-team/bin/team-answer T7 sign-in 1564000000000000001")
  local others=("echo team-answer" "grep -rn 'team-answer' bin" "team-answered T7" "cat bin/team-answer")
  for command in "${answers[@]}" "${others[@]}"; do
    bash_call -0 "$command"
    coordinator_call -0 "$command"
  done

  steal_lease laptop home-pc
  age_probe 61
  for command in "${answers[@]}"; do
    bash_call -2 "$command"
    assert_equal "$stderr" "Blocked: home-pc no longer holds the lease: origin names laptop (held, epoch 2): a machine that lost the lease logs no answer; the coordinator on the holder takes Daniel's answers."
    coordinator_call -2 "$command"
  done
  for command in "${others[@]}"; do
    bash_call -0 "$command"
    coordinator_call -0 "$command"
  done

  fence
  for command in "${answers[@]}"; do
    bash_call -2 "$command"
    assert_equal "$stderr" "Blocked: home-pc is fenced since 2026-10-22T14:00:00Z (holder seen laptop, epoch 2): a fenced machine logs no answer; the coordinator on the holder takes Daniel's answers."
    coordinator_call -2 "$command"
  done
}

@test "team-thread wait is blocked when fenced or when origin names another holder, and a worker's while the team holds offline" {
  local command waits=("team-thread wait T7" "/home/x/agent-team/bin/team-thread wait T7 --after 1564000000000000001"
    "cd wt && team-thread  wait T7" $'team-log T7 note\nteam-thread wait T7')
  local others=("team-thread T7 --interview" "team-thread T7 conventioner 'wait for it'" "echo team-thread wait"
    "grep -rn 'team-thread wait' bin" "team-threads wait T7")
  for command in "${waits[@]}" "${others[@]}"; do
    bash_call -0 "$command"
    coordinator_call -0 "$command"
  done

  mkdir -p "$state"
  echo '{"since": "2026-10-22T13:05:00Z", "posted": true}' >"$state/offline"
  for command in "${waits[@]}"; do
    bash_call -2 "$command"
    assert_equal "$stderr" "Blocked: GitHub is unreachable (since $(date -d 2026-10-22T13:05:00Z +%H:%M)); the team is holding: commit locally, write handoff.md, send T<n> PAUSED offline, and wait."
  done
  for command in "${others[@]}"; do bash_call -0 "$command"; done
  rm "$state/offline"

  steal_lease laptop home-pc
  age_probe 61
  for command in "${waits[@]}"; do
    bash_call -2 "$command"
    assert_equal "$stderr" "Blocked: home-pc no longer holds the lease: origin names laptop (held, epoch 2): a machine that lost the lease waits on no interview; stop, since the coordinator on the holder takes the task on."
    coordinator_call -2 "$command"
  done
  for command in "${others[@]}"; do bash_call -0 "$command"; done

  fence
  for command in "${waits[@]}"; do
    bash_call -2 "$command"
    assert_equal "$stderr" "Blocked: home-pc is fenced since 2026-10-22T14:00:00Z (holder seen laptop, epoch 2): a fenced machine waits on no interview; stop, since the coordinator on the holder takes the task on."
  done
}

# The hook on the assistant's Bash call <command>, with --assistant: assistant_call <status> <command>
assistant_call() {
  run_bin "$1" --separate-stderr hooks/lease-fence --assistant <<<"$(jq -cn --arg c "$2" \
    '{hook_event_name: "PreToolUse", cwd: env.TEAM_HOME, tool_name: "Bash", tool_input: {command: $c}}')"
}

@test "the assistant's push, team-assistant and team-current are blocked when fenced or when origin names another holder" {
  local command lost fenced writes=("git push" "git -C ~/agent-team-records push origin dev" "cd x && git push"
    "team-assistant note --file n.md" "/home/x/agent-team/bin/team-assistant thread 'A topic'"
    "TZ=UTC ~/agent-team/bin/team-current add --file x.md" $'team-log T7 note\nteam-current' "(team-assistant list)")
  local others=("git status" "git log --grep push" "echo team-assistant" "grep -rn 'team-current' bin"
    "team-assistants list" "cat bin/team-current" "gh pr view 6" "team-lease status")
  for command in "${writes[@]}" "${others[@]}"; do
    assistant_call -0 "$command"
  done
  assert_equal "$(probes)" 1

  lost="Blocked: home-pc no longer holds the lease: origin names laptop (held, epoch 2): a machine that lost the lease pushes, hands off and keeps no list; another machine runs the team now, and the assistant there takes Daniel's messages."
  steal_lease laptop home-pc
  age_probe 61
  for command in "${writes[@]}"; do
    assistant_call -2 "$command"
    assert_equal "$stderr" "$lost"
  done
  for command in "${others[@]}"; do assistant_call -0 "$command"; done

  # Fenced: blocked from the fence alone, before origin is asked.
  fenced="Blocked: home-pc is fenced since 2026-10-22T14:00:00Z (holder seen laptop, epoch 2): a fenced machine pushes, hands off and keeps no list; another machine runs the team now, and the assistant there takes Daniel's messages."
  fence
  age_probe 61
  : >"$STUB_CALLS/git-net.log"
  for command in "${writes[@]}"; do
    assistant_call -2 "$command"
    assert_equal "$stderr" "$fenced"
  done
  for command in "${others[@]}"; do assistant_call -0 "$command"; done
  assert_equal "$(probes)" 0
  # The posts every role is held to hold for the assistant too.
  assistant_call -2 "team-post --coordinator --file q.md"
  assert_contains "$stderr" "a fenced machine posts nothing to Discord"

  # A worker's and the coordinator's Bash are not the assistant's: its scripts are not theirs to gate.
  rm "$state/fenced"
  bash_call -0 "team-current"
  coordinator_call -0 "team-assistant list"
}

@test "while the team holds offline, the assistant's gh, gh-axi and git push are blocked with the hold; other commands pass" {
  mkdir -p "$state"
  echo '{"since": "2026-10-22T13:05:00Z", "posted": true}' >"$state/offline"
  local command hold
  hold="Blocked: GitHub is unreachable (since $(date -d 2026-10-22T13:05:00Z +%H:%M)); the team is holding: commit locally, write handoff.md, send T<n> PAUSED offline, and wait."
  for command in "git push" "git -C ~/agent-team-records push" "gh pr view 6" "gh-axi pr list" \
    "cd x && gh api repos/o/p" "GH_REPO=a/b gh issue list" "(gh pr view 6)"; do
    assistant_call -2 "$command"
    assert_equal "$stderr" "$hold"
  done
  for command in "git status" "grep -rn 'gh pr' bin" "echo gh-axi" "ghost run" "team-assistant list" \
    "team-current" "team-ci-wait https://github.com/o/p/pull/6"; do
    assistant_call -0 "$command"
  done
  # Origin is unreachable while offline, so the lease part passes; the hold is read from the flag.
  rm "$state/offline"
  assistant_call -0 "gh pr view 6"
  assistant_call -0 "git push"
}
