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
{"task":"T7","event":"resumed","id":"waiting-1"}'
  assert_equal "$(looked_in)" "2222"
  TEAM_HOME=$TEAM_HOME run "$REPO_ROOT/bin/team-log" --check
  assert_equal "$status" 0
  # waiting.md no longer lists the ask by the end of the command.
  assert_equal "$(waiting_items_shown)" "Nothing waits on you."
}

@test "a waiting list team-inbox cannot write is a line on stderr, and the answer stands" {
  waiting_unwritable
  run_bin -0 --separate-stderr team-answer T7 sign-in 1564000000000000001
  assert_equal "$output" $'Five a minute.\n\n  Keep "ten an hour" for the API, `not` the site.  '
  assert_equal "$stderr" "team-answer: waiting.md is not updated: cannot write $TEAM_HOME/waiting.md: it is a directory"
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

@test "an answered whose message id the ledger holds as a number, as team-log once wrote one, is a repeat too" {
  echo '{"ts":"2026-10-01T10:00:04Z","task":"T7","event":"answered","id":"sign-in","answer":"Five","discord_message":1564000000000000001}' \
    >>"$TEAM_HOME/ledger.jsonl"
  run_bin -1 --separate-stderr team-answer T7 sign-in 1564000000000000001
  assert_equal "$stderr" "team-answer: T7 already logged answered id=sign-in from Discord message 1564000000000000001"
  assert_equal "$(reads)" ""
}

@test "an old wait on the ask still standing is ended by a resumed naming it, whatever stands beside it" {
  # The setup's wait has no cause, as team-ask logged it before it typed one: a resumed id= ends it
  # alone, past any later park, which stays.
  local park
  for park in \
    '{"event":"paused","cause":"stow","reason":"stowed"}' \
    '{"event":"waiting","on":"Daniel","reason":"ask reset"}' \
    '{"event":"pr","url":"https://github.com/o/r/pull/1","head":"a1b2c3d"}'; do
    head -n 4 "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/l"
    jq -c '. + {ts: "2026-10-01T10:00:04Z", task: "T7"}' <<<"$park" >>"$TEAM_HOME/l"
    mv "$TEAM_HOME/l" "$TEAM_HOME/ledger.jsonl"
    run_bin -0 team-answer T7 sign-in 1564000000000000001
    assert_equal "$(tail -n +6 "$TEAM_HOME/ledger.jsonl" | jq -c 'del(.ts)' | jq -sc 'map([.event, .id])')" '[["answered","sign-in"],["resumed","waiting-1"]]'
  done
  # A launch, or an old resumed, ended it already: no resumed is logged.
  for park in \
    '{"event":"launch","role":"builder","session":"s","worktree":"/w/7","toolkits":[]}' \
    '{"event":"resumed"}'; do
    head -n 4 "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/l"
    jq -c '. + {ts: "2026-10-01T10:00:04Z", task: "T7"}' <<<"$park" >>"$TEAM_HOME/l"
    mv "$TEAM_HOME/l" "$TEAM_HOME/ledger.jsonl"
    run_bin -0 team-answer T7 sign-in 1564000000000000001
    assert_equal "$(tail -n +6 "$TEAM_HOME/ledger.jsonl" | jq -r .event)" "answered"
  done
}

@test "a typed wait on the ask is ended by the answered alone, with no resumed" {
  head -n 3 "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/l"
  echo '{"ts":"2026-10-01T10:00:03Z","task":"T7","event":"waiting","on":"Daniel","cause":"ask","ask":"sign-in","reason":"ask sign-in"}' >>"$TEAM_HOME/l"
  mv "$TEAM_HOME/l" "$TEAM_HOME/ledger.jsonl"
  run_bin -0 --separate-stderr team-answer T7 sign-in 1564000000000000001
  assert_equal "$stderr" ""
  assert_equal "$(logged | jq -r .event)" "answered"
  assert_equal "$(jq -L "$REPO_ROOT/bin/lib" -sc 'include "ledger"; [waiting, lifecycle.parks, pending_asks]' "$TEAM_HOME/ledger.jsonl")" '[null,[],[]]'
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

COORDINATOR=1562486564871995482

# A waiting list as a post left it: T7's ask sign-in numbered 3, T8's ask port 5, T9's PR ready
# to merge 2 and T10's interview 4, as team-inbox wrote it; the ledger's lines so far are kept in
# $BATS_TEST_TMPDIR/ledger and waiting.json in $BATS_TEST_TMPDIR/waiting.json, for listed_again.
listed() {
  cat >>"$TEAM_HOME/ledger.jsonl" <<'LEDGER'
{"ts":"2026-10-01T10:00:00Z","task":"T8","event":"opened","project":"agent-team","path":"feature","type":"feat","title":"y","branch":"feat/T8-y","base":"dev","base_sha":"0123456","worktree":"/w/8"}
{"ts":"2026-10-01T10:00:01Z","task":"T8","event":"thread","discord_thread":"8888"}
{"ts":"2026-10-01T10:00:02Z","task":"T8","event":"asked","id":"port","text":"Which port?"}
{"ts":"2026-10-01T10:00:03Z","task":"T8","event":"waiting","on":"Daniel","reason":"ask port"}
{"ts":"2026-10-01T10:00:00Z","task":"T9","event":"opened","project":"agent-team","path":"feature","type":"feat","title":"Nine","branch":"feat/T9-z","base":"dev","base_sha":"0123456","worktree":"/w/9"}
{"ts":"2026-10-01T10:00:01Z","task":"T9","event":"pr","url":"https://github.com/o/r/pull/9","head":"9999999aaa"}
{"ts":"2026-10-01T10:00:02Z","task":"T9","event":"review","head":"9999999aaa","verdict":"pass"}
{"ts":"2026-10-01T10:00:00Z","task":"T10","event":"opened","project":"agent-team","path":"feature","type":"feat","title":"Ten","branch":"feat/T10-w","base":"dev","base_sha":"0123456","worktree":"/w/10"}
{"ts":"2026-10-01T10:00:01Z","task":"T10","event":"interview-thread","discord_thread":"1010"}
LEDGER
  TEAM_HOME=$TEAM_HOME "$REPO_ROOT/bin/team-inbox" >/dev/null
  jq '.items |= map(.n = ({T7: 3, T8: 5, T9: 2, T10: 4}[.task]))' "$TEAM_HOME/waiting.json" >"$BATS_TEST_TMPDIR/waiting.json"
  cp "$BATS_TEST_TMPDIR/waiting.json" "$TEAM_HOME/waiting.json"
  cp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/ledger"
  rm -f "$STUB_CALLS/curl.log"
}

# Put the ledger and the waiting list back as listed left them.
listed_again() {
  cp "$BATS_TEST_TMPDIR/ledger" "$TEAM_HOME/ledger.jsonl"
  cp "$BATS_TEST_TMPDIR/waiting.json" "$TEAM_HOME/waiting.json"
}

# The ledger's events since listed, without their ts.
logged_since() {
  tail -n +"$(($(wc -l <"$BATS_TEST_TMPDIR/ledger") + 1))" "$TEAM_HOME/ledger.jsonl" | jq -c 'del(.ts)'
}

@test "one reply answering asks of two tasks by number logs each answer whole with its item, and prints each its own part" {
  listed
  message "$COORDINATOR" 1564000000000000010 757 "3 yes, 5 no"
  run_bin -0 --separate-stderr team-answer --item 3 1564000000000000010
  assert_equal "$output" "yes"
  assert_equal "$stderr" ""
  run_bin -0 --separate-stderr team-answer --item 5 1564000000000000010
  assert_equal "$output" "no"
  assert_equal "$stderr" ""
  assert_equal "$(logged_since)" '{"task":"T7","event":"answered","id":"sign-in","answer":"3 yes, 5 no","discord_message":"1564000000000000010","item":3}
{"task":"T7","event":"resumed","id":"waiting-1"}
{"task":"T8","event":"answered","id":"port","answer":"3 yes, 5 no","discord_message":"1564000000000000010","item":5}
{"task":"T8","event":"resumed","id":"waiting-1"}'
  # Each task's thread is looked in first, then #coordinator.
  assert_equal "$(looked_in)" "2222
$COORDINATOR
8888
$COORDINATOR"
  TEAM_HOME=$TEAM_HOME run "$REPO_ROOT/bin/team-log" --check
  assert_equal "$status" 0
  # The answered asks leave the list, and what stands keeps its number.
  assert_equal "$(jq -r '[.items[] | "\(.n) \(.task)"] | join(", ")' "$TEAM_HOME/waiting.json")" "2 T9, 4 T10"
  # A number answered leaves the list.
  run_bin -1 --separate-stderr team-answer --item 5 1564000000000000010
  assert_equal "$stderr" "team-answer: no item 5 waits; the list holds 2 and 4"
}

@test "a reply's numbered parts are read as Daniel types them, each number's part printed" {
  listed
  local reply want
  while IFS='|' read -r reply want; do
    listed_again
    message "$COORDINATOR" 1564000000000000010 757 "$(printf '%b' "$reply")"
    run_bin -0 --separate-stderr team-answer --item 3 1564000000000000010
    assert_equal "$output" "$(printf '%b' "$want")"
    assert_equal "$(logged_since | jq -c 'select(.event == "answered") | [.item, .answer]')" \
      "$(jq -nc --arg reply "$(printf '%b' "$reply")" '[3, $reply]')"
  done <<'TABLE'
3 yes, 5 no|yes
3 yes\n5 no|yes
3 yes\r\n5 no|yes
#3 yes|yes
3. yes|yes
3) yes|yes
3: yes|yes
3 - yes|yes
- 3 yes|yes
* 3 yes|yes
3 yes, run it, 5 no|yes, run it
3 and 5 yes|yes
3, 5: yes|yes
5 no; 3 & 4 yes|yes
3 yes\n3 and run it twice|yes\nand run it twice
TABLE
  # "3 and 5 yes" answers item 5 as well.
  listed_again
  message "$COORDINATOR" 1564000000000000010 757 "3 and 5 yes"
  run_bin -0 team-answer --item 5 1564000000000000010
  assert_equal "$output" "yes"
}

@test "a reply that names no part with the number is refused, naming the numbers it does, and nothing is logged" {
  listed
  local reply
  while IFS= read -r reply; do
    message "$COORDINATOR" 1564000000000000010 757 "$reply"
    run_bin -1 --separate-stderr team-answer --item 3 1564000000000000010
    assert_equal "$output" ""
    assert_equal "$stderr" "team-answer: Discord message 1564000000000000010 names no item 3 (it names no item by number); log it with team-answer T7 sign-in 1564000000000000010 if it answers that ask"
  done <<'TABLE'
yes
T7 yes
yes to 3
1-2 yes
2026 was busy
3yes
TABLE
  message "$COORDINATOR" 1564000000000000010 757 "5 yes, 4 no, 5 again"
  run_bin -1 --separate-stderr team-answer --item 3 1564000000000000010
  assert_equal "$stderr" "team-answer: Discord message 1564000000000000010 names no item 3 (it names 4 and 5); log it with team-answer T7 sign-in 1564000000000000010 if it answers that ask"
  assert_equal "$(logged_since)" ""
}

@test "a reply that may mean otherwise is read by the rule alone: a number with a space after it starts a part, and a part with no text prints an empty line" {
  listed
  # "approve 3 and 5" names 5 alone, with no text of its own, and not 3, since a part starts with its number.
  message "$COORDINATOR" 1564000000000000010 757 "approve 3 and 5"
  run_bin -1 --separate-stderr team-answer --item 3 1564000000000000010
  assert_equal "$stderr" "team-answer: Discord message 1564000000000000010 names no item 3 (it names 5); log it with team-answer T7 sign-in 1564000000000000010 if it answers that ask"
  run_bin -0 --separate-stderr team-answer --item 5 1564000000000000010
  assert_equal "$output" ""
  assert_equal "$(logged_since | jq -c 'select(.event == "answered") | [.task, .item, .answer]')" '["T8",5,"approve 3 and 5"]'
  # A number after a comma, with a space after it, is a part, whatever follows.
  local reply want
  while IFS='|' read -r reply want; do
    listed_again
    message "$COORDINATOR" 1564000000000000010 757 "$reply"
    run_bin -0 --separate-stderr team-answer --item 3 1564000000000000010
    assert_equal "$output" "$want"
  done <<'TABLE'
yes, 3 more questions first|more questions first
ok, 3 minutes|minutes
TABLE
  # "3, yes" names nothing: a comma right after a number is no marker.
  listed_again
  message "$COORDINATOR" 1564000000000000010 757 "3, yes"
  run_bin -1 --separate-stderr team-answer --item 3 1564000000000000010
  assert_equal "$stderr" "team-answer: Discord message 1564000000000000010 names no item 3 (it names no item by number); log it with team-answer T7 sign-in 1564000000000000010 if it answers that ask"
}

@test "a PR's or an interview's number is refused, naming what to do instead, with nothing read or logged" {
  listed
  message "$COORDINATOR" 1564000000000000010 757 "2 yes, 4 yes"
  run_bin -1 --separate-stderr team-answer --item 2 1564000000000000010
  assert_equal "$stderr" "team-answer: item 2 is T9's PR https://github.com/o/r/pull/9, which Daniel's word merges: on a merge word, log team-log T9 merge-approved url=https://github.com/o/r/pull/9 discord_message=1564000000000000010 head=<the full sha you asked on>, then run team-merge T9"
  run_bin -1 --separate-stderr team-answer --item 4 1564000000000000010
  assert_equal "$stderr" "team-answer: item 4 is T10's interview, which Daniel answers in <#1010>; nothing is logged"
  assert_equal "$(reads)" ""
  assert_equal "$(logged_since)" ""
}

@test "a walk's number is refused, naming the thread its notes go to, with nothing read or logged" {
  cat >>"$TEAM_HOME/ledger.jsonl" <<'LEDGER'
{"ts":"2026-10-01T10:00:00Z","task":"T11","event":"opened","project":"agent-team","path":"feature","type":"feat","title":"Eleven","branch":"feat/T11-v","base":"dev","base_sha":"0123456","worktree":"/w/11"}
{"ts":"2026-10-01T10:00:01Z","task":"T11","event":"thread","discord_thread":"1111"}
{"ts":"2026-10-01T10:00:02Z","task":"T11","event":"walk","state":"on"}
{"ts":"2026-10-01T10:00:00Z","task":"T12","event":"opened","project":"agent-team","path":"feature","type":"feat","title":"Twelve","branch":"feat/T12-u","base":"dev","base_sha":"0123456","worktree":"/w/12"}
{"ts":"2026-10-01T10:00:02Z","task":"T12","event":"walk","state":"on"}
LEDGER
  TEAM_HOME=$TEAM_HOME "$REPO_ROOT/bin/team-inbox" >/dev/null
  cp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/ledger"
  rm -f "$STUB_CALLS/curl.log"
  # T7's ask is item 1, and the walks follow it.
  message "$COORDINATOR" 1564000000000000010 757 "2 yes, 3 yes"
  run_bin -1 --separate-stderr team-answer --item 2 1564000000000000010
  assert_equal "$stderr" "team-answer: item 2 is T11's walk, whose notes Daniel posts in <#1111>; nothing is logged"
  run_bin -1 --separate-stderr team-answer --item 3 1564000000000000010
  assert_equal "$stderr" "team-answer: item 3 is T12's walk, whose notes Daniel posts in its task's thread; nothing is logged"
  assert_equal "$(reads)" ""
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" "$(cat "$BATS_TEST_TMPDIR/ledger")"
}

@test "a number team-inbox --item refuses is refused with its reason, with nothing read or logged" {
  message "$COORDINATOR" 1564000000000000010 757 "3 yes"
  run_bin -1 --separate-stderr team-answer --item 3 1564000000000000010
  assert_equal "$stderr" "team-answer: no waiting list yet; team-inbox writes it"
  listed
  run_bin -1 --separate-stderr team-answer --item 7 1564000000000000010
  assert_equal "$stderr" "team-answer: no item 7 waits; the list holds 2, 3, 4 and 5"
  assert_equal "$(reads)" ""
  assert_equal "$(logged_since)" ""
}

@test "an answer by number is held to the plain form's checks" {
  listed
  # Not Daniel's, and with no text.
  message "$COORDINATOR" 1564000000000000010 757 "3 yes"
  jq '.author.id = "999"' "$discord/$COORDINATOR-1564000000000000010.json" >"$discord/m"
  mv "$discord/m" "$discord/$COORDINATOR-1564000000000000010.json"
  run_bin -1 --separate-stderr team-answer --item 3 1564000000000000010
  assert_equal "$stderr" "team-answer: Discord message 1564000000000000010 is by daniel (999), who is not in allowFrom of ~/.claude/channels/discord/access.json"
  message "$COORDINATOR" 1564000000000000010 757 "   "
  run_bin -1 --separate-stderr team-answer --item 3 1564000000000000010
  assert_equal "$stderr" "team-answer: Discord message 1564000000000000010 has no text to log as the answer"
  assert_equal "$(logged_since)" ""
  # A message the plain form logged for the ask is a repeat by number too.
  message "$COORDINATOR" 1564000000000000010 757 "3 yes"
  run_bin -0 team-answer T7 sign-in 1564000000000000010
  cp "$BATS_TEST_TMPDIR/waiting.json" "$TEAM_HOME/waiting.json"
  run_bin -1 --separate-stderr team-answer --item 3 1564000000000000010
  assert_equal "$stderr" "team-answer: T7 already logged answered id=sign-in from Discord message 1564000000000000010"
  # A message sent before the ask it numbers: 1564000000000000010 was sent on 2026-10-25.
  listed_again
  echo '{"ts":"2026-10-30T10:00:00Z","task":"T7","event":"asked","id":"sign-in","text":"Again?"}' >>"$TEAM_HOME/ledger.jsonl"
  TEAM_HOME=$TEAM_HOME "$REPO_ROOT/bin/team-inbox" >/dev/null
  local n before
  n=$(jq -r '.items[] | select(.text == "Again?") | .n' "$TEAM_HOME/waiting.json")
  before=$(cat "$TEAM_HOME/ledger.jsonl")
  message "$COORDINATOR" 1564000000000000010 757 "$n yes"
  run_bin -1 --separate-stderr team-answer --item "$n" 1564000000000000010
  assert_equal "$stderr" "team-answer: Discord message 1564000000000000010 was sent at 2026-10-25T19:37:37Z, before T7 asked sign-in at 2026-10-30T10:00:00Z, so it is not Daniel's answer to it"
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" "$before"
}

@test "an answer by number in a worker session is refused, and a malformed one is a usage error" {
  listed
  message "$COORDINATOR" 1564000000000000010 757 "3 yes"
  AGENT_TEAM_ROLE=builder AGENT_TEAM_TASK=T7 run_bin -1 --separate-stderr team-answer --item 3 1564000000000000010
  assert_equal "$stderr" "team-answer: a builder session logs no answer of Daniel's: that is the coordinator's; send it your message"
  local args
  for args in "--item" "--item 3" "--item 0 1564000000000000010" "--item 1000 1564000000000000010" \
    "--item x 1564000000000000010" "--item 3 0" "--item 3 1564000000000000010 more" "--item 03 1564000000000000010"; do
    # shellcheck disable=SC2086 # each word an argument
    run_bin -2 team-answer $args
    assert_contains "$output" "usage: team-answer T<n> <id> <discord message id>, or team-answer --item <n> <discord message id>"
  done
  assert_equal "$(reads)" ""
  assert_equal "$(logged_since)" ""
}

@test "--help prints the header" {
  run_bin -0 team-answer --help
  assert_equal "${lines[0]}" "$(sed -n '2s/^# //p' "$REPO_ROOT/bin/team-answer")"
  assert_contains "$output" "Usage: team-answer T<n> <id> <discord message id>"
  assert_contains "$output" "team-answer --item <n> <discord message id>"
}

@test "the answered and the resumed logged with it are pushed to origin at once, in one commit" {
  printf 'ledger.jsonl.lock\n' >"$TEAM_HOME/.gitignore"
  local team_origin tip
  team_origin=$(hold_lease home-pc)
  tip=$(git -C "$team_origin" rev-parse dev)
  run_bin -0 --separate-stderr team-answer T7 sign-in 1564000000000000001
  assert_equal "$output" $'Five a minute.\n\n  Keep "ten an hour" for the API, `not` the site.  '
  assert_equal "$stderr" ""
  assert_equal "$(git -C "$team_origin" rev-parse dev^)" "$tip"
  assert_equal "$(git -C "$team_origin" log -1 --format=%s dev)" "chore: ledger T7 answered resumed"
  assert_equal "$(git -C "$team_origin" diff-tree -r --no-commit-id --name-only dev)" "ledger.jsonl"
  assert_equal "$(git -C "$team_origin" show dev:ledger.jsonl | tail -n 2 | jq -r .event)" "answered
resumed"
}
