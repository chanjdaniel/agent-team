#!/usr/bin/env bats
# hooks/assistant-discord-guard: the PreToolUse hook on the assistant's Discord tools. It passes a
# call in #assistant and in a thread whose parent is #assistant (read from Discord once, then
# from its cache), refuses every other channel, a reply file outside the assistant's two
# directories, input it cannot read and a Discord read that fails. Discord is a fake: GET
# channels/<id> answers $DISCORD_DIR/channel-<id>.json, a missing one fails as curl -f does.

load helpers/common

ASSISTANT=1570000000000000100
THREAD=1570000000000000201
OTHER_THREAD=1570000000000000301
COORDINATOR=1562486564871995482

setup() {
  sandbox
  export TEAM_ASSISTANT_CHANNEL=$ASSISTANT
  export DISCORD_DIR=$BATS_TEST_TMPDIR/discord
  mkdir -p "$DISCORD_DIR"
  state=$HOME/.local/state/agent-team
  files=$state/assistant-files
  mkdir -p "$files" "$TEAM_HOME/assistant/research"
  stub_script curl <<'EOF'
url=${*: -1}
if [[ $url =~ ^https://discord\.com/api/v10/channels/([0-9]+)$ && -f $DISCORD_DIR/channel-${BASH_REMATCH[1]}.json ]]; then
  cat "$DISCORD_DIR/channel-${BASH_REMATCH[1]}.json"
else
  echo "curl: (22) The requested URL returned error: 404" >&2
  exit 22
fi
EOF
  channel "$THREAD" 11 "$ASSISTANT"
  channel "$OTHER_THREAD" 11 "$COORDINATOR"
  channel "$COORDINATOR" 0 1562000000000000000
}

# Discord's channel <id> of type <type> under <parent>: channel <id> <type> <parent>
channel() {
  jq -n --arg id "$1" --argjson type "$2" --arg parent "$3" \
    '{id: $id, type: $type, parent_id: $parent, name: "x"}' >"$DISCORD_DIR/channel-$1.json"
}

# The hook on a call to the Discord tool <tool> with <input> (JSON), as Claude Code sends it:
# hook <status> <tool> <input>
hook() {
  run_bin "$1" --separate-stderr hooks/assistant-discord-guard <<<"$(jq -cn --arg tool "mcp__plugin_discord_discord__$2" \
    --argjson input "$3" '{hook_event_name: "PreToolUse", cwd: env.TEAM_HOME, tool_name: $tool, tool_input: $input}')"
}

# The hook on a reply in <chat> attaching each <file>: reply <status> <chat> [<file>...]
reply() {
  hook "$1" reply "$(jq -cn --arg chat "$2" '{chat_id: $chat, text: "here", files: $ARGS.positional}' --args "${@:3}")"
}

# The channels the hook read from Discord, one id a line.
reads() {
  stub_calls curl | jq -r '.[-1] | capture("/channels/(?<id>[0-9]+)$").id'
}

@test "every Discord tool passes in #assistant itself, without asking Discord" {
  reply -0 "$ASSISTANT"
  assert_equal "$stderr" ""
  hook -0 react "{\"chat_id\": \"$ASSISTANT\", \"message_id\": \"9\", \"emoji\": \"x\"}"
  hook -0 edit_message "{\"chat_id\": \"$ASSISTANT\", \"message_id\": \"9\", \"text\": \"x\"}"
  hook -0 download_attachment "{\"chat_id\": \"$ASSISTANT\", \"message_id\": \"9\"}"
  hook -0 fetch_messages "{\"channel\": \"$ASSISTANT\", \"limit\": 20}"
  assert_equal "$(reads)" ""
  [[ ! -e $state/assistant-threads ]]
}

@test "a thread of #assistant passes, read from Discord once and then from the cache" {
  reply -0 "$THREAD"
  assert_equal "$stderr" ""
  assert_equal "$(reads)" "$THREAD"
  assert_equal "$(cat "$state/assistant-threads")" "$THREAD"
  # The token reached curl on stdin, never its arguments.
  stub_calls curl | jq -e --arg t "$FAKE_DISCORD_TOKEN" 'map(select(contains($t))) | length == 0' >/dev/null
  # Every later call, whatever its tool, reads the cache: Discord is not asked again.
  rm "$DISCORD_DIR/channel-$THREAD.json"
  hook -0 fetch_messages "{\"channel\": \"$THREAD\"}"
  hook -0 react "{\"chat_id\": \"$THREAD\", \"message_id\": \"9\", \"emoji\": \"x\"}"
  assert_equal "$(reads)" "$THREAD"
  assert_equal "$(cat "$state/assistant-threads")" "$THREAD"
  # A thread team-assistant thread recorded is known-good without a read; only whole lines count.
  echo 1570000000000000202 >>"$state/assistant-threads"
  hook -0 download_attachment '{"chat_id": "1570000000000000202", "message_id": "9"}'
  hook -2 download_attachment '{"chat_id": "157000000000000020", "message_id": "9"}'
  assert_equal "$(reads)" "$THREAD
157000000000000020"
}

@test "another channel and a thread of another parent are refused, and neither is kept" {
  local each
  reply -2 "$COORDINATOR"
  assert_equal "$output" ""
  assert_equal "$stderr" "Blocked: channel $COORDINATOR is not #assistant ($ASSISTANT) or a thread of it; the assistant reaches only #assistant and its threads."
  hook -2 fetch_messages "{\"channel\": \"$OTHER_THREAD\"}"
  assert_equal "$stderr" "Blocked: channel $OTHER_THREAD is a thread of $COORDINATOR, not of #assistant ($ASSISTANT); the assistant reaches only #assistant and its threads."
  # A channel whose parent is #assistant but is no thread is not one of its threads.
  channel 1570000000000000400 0 "$ASSISTANT"
  for each in react edit_message download_attachment; do
    hook -2 "$each" '{"chat_id": "1570000000000000400", "message_id": "9", "emoji": "x", "text": "x"}'
    assert_equal "$stderr" "Blocked: channel 1570000000000000400 is not #assistant ($ASSISTANT) or a thread of it; the assistant reaches only #assistant and its threads."
  done
  [[ ! -e $state/assistant-threads ]]
  # Each refusal reads Discord again: a refused channel is never cached.
  assert_equal "$(reads | sort | uniq -c | awk '{print $1}' | paste -sd ' ')" "1 1 3"
  # An id that is no snowflake never reaches a URL.
  : >"$STUB_CALLS/curl.log"
  for each in '../users/@me' "$ASSISTANT/messages" '' '0123' '1 2'; do
    hook -2 react "$(jq -cn --arg c "$each" '{chat_id: $c, message_id: "9", emoji: "x"}')"
    assert_equal "$stderr" "Blocked: '$each' is not a Discord channel id; the assistant reaches only #assistant ($ASSISTANT) and its threads."
  done
  assert_equal "$(stub_calls curl)" ""
}

@test "a Discord read that fails is refused, saying the guard cannot tell" {
  rm "$DISCORD_DIR/channel-$THREAD.json"
  hook -2 react "{\"chat_id\": \"$THREAD\", \"message_id\": \"9\", \"emoji\": \"x\"}"
  assert_equal "$stderr" "Blocked: assistant-discord-guard could not read channel $THREAD from Discord (curl: (22) The requested URL returned error: 404), so it cannot tell whether it is a thread of #assistant; a guard that cannot decide refuses, so tell Daniel and do not reach it another way."
  # Without the bot token, no call is made.
  channel "$THREAD" 11 "$ASSISTANT"
  rm "$HOME/.claude/channels/discord/.env"
  : >"$STUB_CALLS/curl.log"
  hook -2 react "{\"chat_id\": \"$THREAD\", \"message_id\": \"9\", \"emoji\": \"x\"}"
  assert_contains "$stderr" "could not read channel $THREAD from Discord (no DISCORD_BOT_TOKEN in ~/.claude/channels/discord/.env), so"
  assert_equal "$(stub_calls curl)" ""
  # An answer that is not a channel object is no thread of #assistant.
  echo 'not json' >"$DISCORD_DIR/channel-$THREAD.json"
  echo "DISCORD_BOT_TOKEN=$FAKE_DISCORD_TOKEN" >"$HOME/.claude/channels/discord/.env"
  hook -2 react "{\"chat_id\": \"$THREAD\", \"message_id\": \"9\", \"emoji\": \"x\"}"
  assert_equal "$stderr" "Blocked: channel $THREAD is not #assistant ($ASSISTANT) or a thread of it; the assistant reaches only #assistant and its threads."
  [[ ! -e $state/assistant-threads ]]
}

@test "a reply attaches files under assistant-files and the team home's assistant/ only, symlinks resolved" {
  local rule="Blocked: the assistant attaches only files under ~/.local/state/agent-team/assistant-files/ or the team home's assistant/, and"
  echo png >"$files/shot.png"
  mkdir "$files/run"
  echo report >"$files/run/report.md"
  echo note >"$TEAM_HOME/assistant/research/2026-11-14-x.md"
  reply -0 "$ASSISTANT" "$files/shot.png" "$files/run/report.md" "$TEAM_HOME/assistant/research/2026-11-14-x.md"
  assert_equal "$stderr" ""
  # A link inside to a file inside passes, as its target does.
  ln -s "$files/shot.png" "$files/link.png"
  reply -0 "$THREAD" "$files/link.png"

  # The Discord state, through a link from inside or by its own path, is refused, naming it.
  ln -s "$HOME/.claude/channels/discord/.env" "$files/token.png"
  reply -2 "$ASSISTANT" "$files/shot.png" "$files/token.png"
  assert_equal "$stderr" "$rule $files/token.png is not one (it resolves to $HOME/.claude/channels/discord/.env)."
  reply -2 "$ASSISTANT" "$HOME/.claude/channels/discord/.env"
  assert_equal "$stderr" "$rule $HOME/.claude/channels/discord/.env is not one."
  # A directory linked in carries its outside files with it.
  mkdir -p "$HOME/.claude/channels/discord-assistant"
  echo '{}' >"$HOME/.claude/channels/discord-assistant/access.json"
  ln -s "$HOME/.claude/channels" "$files/channels"
  reply -2 "$ASSISTANT" "$files/channels/discord-assistant/access.json"
  assert_equal "$stderr" "$rule $files/channels/discord-assistant/access.json is not one (it resolves to $HOME/.claude/channels/discord-assistant/access.json)."
  # .. out of a directory, the records beside assistant/, and a sibling whose name starts alike.
  reply -2 "$ASSISTANT" "$files/../../../../.claude/channels/discord/.env"
  assert_contains "$stderr" "(it resolves to $HOME/.claude/channels/discord/.env)."
  reply -2 "$ASSISTANT" "$TEAM_HOME/ledger.jsonl"
  assert_equal "$stderr" "$rule $TEAM_HOME/ledger.jsonl is not one."
  mkdir "$state/assistant-files-x"
  echo x >"$state/assistant-files-x/a.png"
  reply -2 "$ASSISTANT" "$state/assistant-files-x/a.png"
  assert_equal "$stderr" "$rule $state/assistant-files-x/a.png is not one."
  # A relative path, a missing file and a directory are no absolute path to a file.
  local each
  for each in shot.png "$files/missing.png" "$files/run" "$files"; do
    reply -2 "$ASSISTANT" "$each"
    assert_equal "$stderr" "$rule $each is not an absolute path to a file."
  done
  # The file rule holds in a thread too, after the chat rule passes.
  reply -2 "$THREAD" "$TEAM_HOME/ledger.jsonl"
  assert_equal "$stderr" "$rule $TEAM_HOME/ledger.jsonl is not one."
}

@test "input it cannot read is refused, naming why" {
  local input cannot="; a guard that cannot decide refuses, so tell Daniel and do not reach it another way."
  for input in 'not json' '' '[]' '{}' '{"tool_input": {"chat_id": "1"}}' '{"tool_name": 5}' '"x"'; do
    run_bin -2 --separate-stderr hooks/assistant-discord-guard <<<"$input"
    [[ $stderr == "Blocked: assistant-discord-guard could not read the hook's input (JSON with a tool_name)$cannot" ]] ||
      { printf 'input %s: stderr %s\n' "$input" "$stderr" >&2; return 1; }
  done
  hook -2 reply '{"text": "x"}'
  assert_equal "$stderr" "Blocked: assistant-discord-guard could not read the call's chat_id from the hook's input$cannot"
  hook -2 react '{"chat_id": 1570000000000000100}'
  assert_equal "$stderr" "Blocked: assistant-discord-guard could not read the call's chat_id from the hook's input$cannot"
  hook -2 fetch_messages "{\"chat_id\": \"$ASSISTANT\"}"
  assert_equal "$stderr" "Blocked: assistant-discord-guard could not read the call's channel from the hook's input$cannot"
  local list
  for list in '"/x.png"' '[1]' '{"a": "b"}' '["/a\n/b"]'; do
    hook -2 reply "{\"chat_id\": \"$ASSISTANT\", \"text\": \"x\", \"files\": $list}"
    assert_equal "$stderr" "Blocked: assistant-discord-guard could not read the reply's files (a list of paths, none with a newline)$cannot"
  done
  # A tool it does not judge means its settings entry matches too much.
  run_bin -2 --separate-stderr hooks/assistant-discord-guard <<<'{"tool_name": "Bash", "tool_input": {"command": "ls"}}'
  assert_equal "$stderr" "Blocked: assistant-discord-guard judges only the Discord plugin's tools, not Bash, so its settings entry matches too much$cannot"
  run_bin -2 --separate-stderr hooks/assistant-discord-guard x <<<'{"tool_name": "Bash", "tool_input": {}}'
  assert_equal "$stderr" "assistant-discord-guard: usage: assistant-discord-guard"
}

@test "with no assistant channel set, or files and no team home, it refuses, saying it cannot tell" {
  local cannot="; a guard that cannot decide refuses, so tell Daniel and do not reach it another way."
  TEAM_ASSISTANT_CHANNEL='' hook -2 react "{\"chat_id\": \"$ASSISTANT\", \"message_id\": \"9\", \"emoji\": \"x\"}"
  assert_equal "$stderr" "Blocked: no assistant channel is set (TEAM_ASSISTANT_CHANNEL is empty), so assistant-discord-guard cannot tell #assistant$cannot"
  # With no team home named, the chat rule still decides; files cannot be judged.
  echo png >"$files/shot.png"
  homeless() {
    run --separate-stderr env -u TEAM_HOME "$REPO_ROOT/bin/hooks/assistant-discord-guard" <<<"$1"
  }
  [[ ! -e $HOME/.config/agent-team/home ]]
  homeless "{\"tool_name\": \"mcp__plugin_discord_discord__reply\", \"tool_input\": {\"chat_id\": \"$ASSISTANT\", \"text\": \"x\"}}"
  assert_equal "$status:$stderr" 0:
  homeless "{\"tool_name\": \"mcp__plugin_discord_discord__reply\", \"tool_input\": {\"chat_id\": \"$COORDINATOR\", \"text\": \"x\"}}"
  assert_equal "$status" 2
  homeless "{\"tool_name\": \"mcp__plugin_discord_discord__reply\", \"tool_input\": {\"chat_id\": \"$ASSISTANT\", \"text\": \"x\", \"files\": [\"$files/shot.png\"]}}"
  assert_equal "$status" 2
  assert_contains "$stderr" "Blocked: assistant-discord-guard cannot judge the reply's files, since neither TEAM_HOME nor ~/.config/agent-team/home names the team home"
  assert_contains "$stderr" "$cannot"
  TEAM_HOME=$BATS_TEST_TMPDIR/gone reply -2 "$ASSISTANT" "$files/shot.png"
  assert_equal "$stderr" "Blocked: assistant-discord-guard cannot judge the reply's files, since the team home $BATS_TEST_TMPDIR/gone is not a directory$cannot"
}

@test "a command failing inside it is a refusal that names the hook and the exit code" {
  # The read of the reply's files fails, after the chat rule passed.
  fails_on_call jq .tool_input.files
  reply -2 "$ASSISTANT"
  assert_equal "$output" ""
  assert_equal "$stderr" "Blocked by assistant-discord-guard: it failed with exit 5 before it could decide, and a guard that cannot decide refuses; report it as BLOCKED and do not reach it another way."
}
