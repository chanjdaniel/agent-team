#!/usr/bin/env bats
# team-answer: Daniel's answer to an ask, read from Discord by message id and checked to be
# theirs, logged with its verbatim text, the ask's wait cleared, and the text printed.

load helpers/common
load helpers/inbox

setup() {
  sandbox
  cat >"$TEAM_HOME/ledger.jsonl" <<'LEDGER'
{"ts":"2026-10-01T10:00:00Z","task":"T7","event":"opened","project":"agent-team","path":"feature","type":"feat","title":"x","branch":"feat/T7-x","base":"dev","base_sha":"0123456","worktree":"/w/7"}
{"ts":"2026-10-01T10:00:01Z","task":"T7","event":"thread","discord_thread":"2222"}
{"ts":"2026-10-01T10:00:02Z","task":"T7","event":"asked","id":"sign-in","text":"Which of the two sign-in limits stays?"}
{"ts":"2026-10-01T10:00:03Z","task":"T7","event":"waiting","on":"Daniel","reason":"ask sign-in"}
LEDGER
  echo '{"dmPolicy": "allowlist", "allowFrom": ["757"], "groups": {}, "pending": {}}' \
    >"$HOME/.claude/channels/discord/access.json"
  discord=$BATS_TEST_TMPDIR/discord
  mkdir -p "$discord"
  export DISCORD_DIR=$discord
  stub_discord
  inbox_discord
  message 2222 1564000000000000001 757 $'Five a minute.\n\n  Keep "ten an hour" for the API, `not` the site.  '
}

# The fake Discord API: GET channels/<c>/messages/<m> answers $DISCORD_DIR/<c>-<m>.json, a
# missing one fails as curl -f does on a 404. The headers curl read from stdin are kept.
# team-inbox's calls go to the fake Discord of helpers/inbox.
stub_discord() {
  stub_script curl <<'EOF'
[[ ! -f $STUB_FIXTURES/inbox.sh ]] || source "$STUB_FIXTURES/inbox.sh"
cat >>"$DISCORD_DIR/stdin"
url=${*: -1}
if [[ $url =~ ^https://discord\.com/api/v10/channels/([0-9]+)/messages/([0-9]+)$ &&
  -f $DISCORD_DIR/${BASH_REMATCH[1]}-${BASH_REMATCH[2]}.json ]]; then
  cat "$DISCORD_DIR/${BASH_REMATCH[1]}-${BASH_REMATCH[2]}.json"
else
  echo "curl: (22) The requested URL returned error: 404" >&2
  exit 22
fi
EOF
}

# Message <id> in channel <channel> by author <author id>, saying <content>:
# message <channel> <id> <author> <content>
message() {
  jq -n --arg c "$1" --arg id "$2" --arg a "$3" --arg text "$4" \
    '{id: $id, channel_id: $c, content: $text, author: {id: $a, username: "daniel"}}' >"$discord/$1-$2.json"
}

# The ledger's events after the setup's, without their ts.
logged() {
  tail -n +5 "$TEAM_HOME/ledger.jsonl" | jq -c 'del(.ts)'
}

# The reads of a message by id, team-inbox's calls left out.
reads() {
  stub_calls curl | jq -c 'select(.[-1] | test("/messages/[0-9]+$")) | select(index("-X") | not)'
}

# The channels the message was looked for in, in order.
looked_in() {
  reads | jq -r '.[-1] | capture("channels/(?<c>[0-9]+)/messages/").c'
}

@test "an answer is logged with its verbatim text and message, the ask's wait is cleared, and the text printed" {
  run_bin -0 --separate-stderr team-answer T7 sign-in 1564000000000000001
  assert_equal "$output" $'Five a minute.\n\n  Keep "ten an hour" for the API, `not` the site.  '
  assert_equal "$stderr" ""
  assert_equal "$(logged)" '{"task":"T7","event":"answered","id":"sign-in","answer":"Five a minute.\n\n  Keep \"ten an hour\" for the API, `not` the site.  ","discord_message":"1564000000000000001"}
{"task":"T7","event":"resumed"}'
  assert_equal "$(looked_in)" "2222"
  TEAM_HOME=$TEAM_HOME run "$REPO_ROOT/bin/team-log" --check
  assert_equal "$status" 0
  # The Waiting on you message no longer lists the ask by the end of the command.
  assert_equal "$(inbox_items_shown)" "Nothing waits on you."
}

@test "a Waiting on you message Discord refuses is a line on stderr, and the answer stands" {
  echo 500 >"$STUB_FIXTURES/inbox/fail"
  run_bin -0 --separate-stderr team-answer T7 sign-in 1564000000000000001
  assert_equal "$output" $'Five a minute.\n\n  Keep "ten an hour" for the API, `not` the site.  '
  assert_equal "$stderr" "team-answer: the Waiting on you message is not updated: Discord refused the read of #coordinator's channel: curl: (22) The requested URL returned error: 500"
  assert_equal "$(logged | jq -r .event)" "answered
resumed"
}

@test "the message is read with the bot token on stdin, never on the command line or in the output" {
  run_bin -0 team-answer T7 sign-in 1564000000000000001
  assert_equal "$(reads)" \
    '["-fsS","-H","@-","https://discord.com/api/v10/channels/2222/messages/1564000000000000001"]'
  assert_equal "$(cat "$discord/stdin")" "Authorization: Bot $FAKE_DISCORD_TOKEN"
  [[ $output != *"$FAKE_DISCORD_TOKEN"* ]]
}

@test "an answer in #coordinator counts when it is not in the task's thread" {
  rm "$discord"/*.json
  message 1562486564871995482 1564000000000000001 757 "Five a minute."
  run_bin -0 team-answer T7 sign-in 1564000000000000001
  assert_equal "$output" "Five a minute."
  assert_equal "$(looked_in)" "2222
1562486564871995482"
  assert_equal "$(logged | jq -r .event)" "answered
resumed"
}

@test "a message by anyone not in allowFrom is refused, naming the author, and nothing is logged" {
  message 2222 1564000000000000001 999 "Five a minute."
  run_bin -1 --separate-stderr team-answer T7 sign-in 1564000000000000001
  assert_equal "$output" ""
  assert_equal "$stderr" "team-answer: Discord message 1564000000000000001 is by daniel (999), who is not in allowFrom of ~/.claude/channels/discord/access.json"
  assert_equal "$(logged)" ""
}

@test "a message no place has is refused, naming where it was looked for, and nothing is logged" {
  run_bin -1 --separate-stderr team-answer T7 sign-in 1564000000000000009
  assert_equal "$stderr" "team-answer: Discord message 1564000000000000009 cannot be fetched from the task's thread 2222 or #coordinator 1562486564871995482: curl: (22) The requested URL returned error: 404"
  assert_equal "$(logged)" ""
}

@test "an answer that cannot be checked, with no allowFrom or no token, is refused without asking Discord" {
  rm "$HOME/.claude/channels/discord/access.json"
  run_bin -1 --separate-stderr team-answer T7 sign-in 1564000000000000001
  assert_equal "$stderr" "team-answer: cannot read allowFrom from ~/.claude/channels/discord/access.json, so the answer cannot be checked"
  echo '{"allowFrom": ["757"]}' >"$HOME/.claude/channels/discord/access.json"
  : >"$HOME/.claude/channels/discord/.env"
  run_bin -1 --separate-stderr team-answer T7 sign-in 1564000000000000001
  assert_equal "$stderr" "team-answer: no DISCORD_BOT_TOKEN in ~/.claude/channels/discord/.env, so the answer cannot be checked"
  assert_equal "$(stub_calls curl)" ""
  assert_equal "$(logged)" ""
}

@test "a message with no text is refused, and nothing is logged" {
  message 2222 1564000000000000001 757 "  "
  run_bin -1 --separate-stderr team-answer T7 sign-in 1564000000000000001
  assert_equal "$stderr" "team-answer: Discord message 1564000000000000001 has no text to log as the answer"
  assert_equal "$(logged)" ""
}

@test "an ask the task never asked, or a task that is not open, is refused without asking Discord" {
  echo '{"ts":"2026-10-01T10:00:00Z","task":"T8","event":"opened","project":"agent-team","path":"feature","type":"feat","title":"y","branch":"feat/T8-y","base":"dev","base_sha":"0123456","worktree":"/w/8"}' \
    >>"$TEAM_HOME/ledger.jsonl"
  local before
  before=$(cat "$TEAM_HOME/ledger.jsonl")
  run_bin -1 --separate-stderr team-answer T7 reset 1564000000000000001
  assert_equal "$stderr" "team-answer: T7 never asked reset; its asks: sign-in"
  run_bin -1 --separate-stderr team-answer T8 sign-in 1564000000000000001
  assert_equal "$stderr" "team-answer: T8 never asked sign-in; it has asked nothing"
  run_bin -1 --separate-stderr team-answer T9 sign-in 1564000000000000001
  assert_equal "$stderr" "team-answer: T9 is not open: the ledger has no opened event for it"
  assert_equal "$(stub_calls curl)" ""
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" "$before"
}

@test "the same message for the same ask is refused the second time; another message adds to the answer" {
  run_bin -0 team-answer T7 sign-in 1564000000000000001
  run_bin -1 --separate-stderr team-answer T7 sign-in 1564000000000000001
  assert_equal "$stderr" "team-answer: T7 already logged answered id=sign-in from Discord message 1564000000000000001"
  assert_equal "$(reads | wc -l)" "1"
  message 2222 1564000000000000002 757 "(added) And reset it daily."
  run_bin -0 team-answer T7 sign-in 1564000000000000002
  assert_equal "$output" "(added) And reset it daily."
  # The wait was cleared by the first answer, so the addition logs no second resumed.
  assert_equal "$(logged | jq -r '[.event, .discord_message // "-"] | join(" ")')" "answered 1564000000000000001
resumed -
answered 1564000000000000002"
}

@test "resumed is logged only while the ask's own wait is the task's standing park" {
  local park
  for park in \
    '{"event":"launch","role":"builder","session":"s","worktree":"/w/7","toolkits":[]}' \
    '{"event":"paused","reason":"stowed"}' \
    '{"event":"waiting","on":"Daniel","reason":"ask reset"}' \
    '{"event":"waiting","on":"Daniel","reason":"merge"}' \
    '{"event":"resumed"}'; do
    head -n 4 "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/l"
    jq -c '. + {ts: "2026-10-01T10:00:04Z", task: "T7"}' <<<"$park" >>"$TEAM_HOME/l"
    mv "$TEAM_HOME/l" "$TEAM_HOME/ledger.jsonl"
    run_bin -0 team-answer T7 sign-in 1564000000000000001
    assert_equal "$(tail -n +6 "$TEAM_HOME/ledger.jsonl" | jq -r .event)" "answered"
  done
  # Events that are not parks leave the wait standing.
  head -n 4 "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/l"
  echo '{"ts":"2026-10-01T10:00:04Z","task":"T7","event":"pr","url":"https://github.com/o/r/pull/1","head":"a1b2c3d"}' >>"$TEAM_HOME/l"
  mv "$TEAM_HOME/l" "$TEAM_HOME/ledger.jsonl"
  run_bin -0 team-answer T7 sign-in 1564000000000000001
  assert_equal "$(tail -n +6 "$TEAM_HOME/ledger.jsonl" | jq -r .event)" "answered
resumed"
}

@test "a message sent before the ask's question, or before its asked when no question is logged, is refused without asking Discord" {
  # team-ask logs the question's message: an answer must come after it.
  echo '{"ts":"2026-10-30T10:00:00Z","task":"T7","event":"asked","id":"sign-in","text":"Again: which limit stays?","discord_message":"1564000000000000005"}' \
    >>"$TEAM_HOME/ledger.jsonl"
  local before
  before=$(cat "$TEAM_HOME/ledger.jsonl")
  run_bin -1 --separate-stderr team-answer T7 sign-in 1564000000000000001
  assert_equal "$stderr" "team-answer: Discord message 1564000000000000001 was sent at 2026-10-25T19:37:37Z, before T7's question sign-in (Discord message 1564000000000000005), so it is not Daniel's answer to it"
  message 2222 1564000000000000006 757 "Five a minute."
  run_bin -0 team-answer T7 sign-in 1564000000000000006
  assert_equal "$output" "Five a minute."
  # An asked team-log wrote, with no message: the answer must be sent no earlier than its ts.
  echo "$before" >"$TEAM_HOME/ledger.jsonl"
  echo '{"ts":"2026-10-30T10:00:00Z","task":"T7","event":"asked","id":"reset","text":"Reset it daily?"}' >>"$TEAM_HOME/ledger.jsonl"
  before=$(cat "$TEAM_HOME/ledger.jsonl")
  run_bin -1 --separate-stderr team-answer T7 reset 1564000000000000001
  assert_equal "$stderr" "team-answer: Discord message 1564000000000000001 was sent at 2026-10-25T19:37:37Z, before T7 asked reset at 2026-10-30T10:00:00Z, so it is not Daniel's answer to it"
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" "$before"
  assert_equal "$(reads | wc -l)" "1"
}

@test "an edited message is refused, and nothing is logged" {
  jq '. + {edited_timestamp: "2026-10-25T19:40:00.000000+00:00"}' "$discord/2222-1564000000000000001.json" >"$discord/m"
  mv "$discord/m" "$discord/2222-1564000000000000001.json"
  run_bin -1 --separate-stderr team-answer T7 sign-in 1564000000000000001
  assert_equal "$stderr" "team-answer: Discord message 1564000000000000001 was edited at 2026-10-25T19:40:00.000000+00:00, so its text may not be what Daniel first sent: ask them to send the answer again as a new message"
  assert_equal "$(logged)" ""
}

@test "a fenced machine, or one that lost the lease, reads nothing and logs nothing" {
  mkdir -p "$HOME/.local/state/agent-team"
  echo '{"since": "2026-10-22T14:00:00Z", "holder": "laptop", "epoch": 2}' >"$HOME/.local/state/agent-team/fenced"
  run_bin -1 --separate-stderr team-answer T7 sign-in 1564000000000000001
  assert_contains "$stderr" "a fenced machine logs no answer; the coordinator on the holder takes Daniel's answers."
  rm "$HOME/.local/state/agent-team/fenced"
  hold_lease home-pc >/dev/null
  make_machine laptop
  steal_lease laptop home-pc
  rm -f "$HOME/.local/state/agent-team/probe.json"
  run_bin -1 --separate-stderr team-answer T7 sign-in 1564000000000000001
  assert_contains "$stderr" "home-pc no longer holds the lease: origin names laptop"
  assert_contains "$stderr" "a machine that lost the lease logs no answer"
  assert_equal "$(stub_calls curl)" ""
  assert_equal "$(logged)" ""
}

@test "a worker session is refused, and the coordinator's and Daniel's own shell are not" {
  local role
  for role in planner builder reviewer ops; do
    AGENT_TEAM_ROLE=$role AGENT_TEAM_TASK=T7 run_bin -1 --separate-stderr team-answer T7 sign-in 1564000000000000001
    assert_equal "$stderr" "team-answer: a $role session logs no answer of Daniel's: that is the coordinator's; send it your message"
  done
  assert_equal "$(stub_calls curl)" ""
  assert_equal "$(logged)" ""
  AGENT_TEAM_ROLE=coordinator run_bin -0 team-answer T7 sign-in 1564000000000000001
  assert_equal "$(logged | jq -r .event)" "answered
resumed"
}

@test "a malformed command line is a usage error, and nothing is read or logged" {
  local args
  for args in "" "T7" "T7 sign-in" "7 sign-in 1564000000000000001" "T7 'sign in' 1564000000000000001" \
    "T7 sign-in 1564/../x" "T7 sign-in 0" "T7 sign-in 1564000000000000001 more" "T7 -x 1564000000000000001"; do
    eval "run_bin -2 team-answer $args"
    assert_contains "$output" "usage: team-answer T<n> <id> <discord message id>"
  done
  assert_equal "$(stub_calls curl)" ""
  assert_equal "$(logged)" ""
}

@test "--help prints the header" {
  run_bin -0 team-answer --help
  assert_equal "${lines[0]}" "$(sed -n '2s/^# //p' "$REPO_ROOT/bin/team-answer")"
  assert_contains "$output" "Usage: team-answer T<n> <id> <discord message id>"
}
