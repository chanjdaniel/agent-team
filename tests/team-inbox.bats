#!/usr/bin/env bats
# team-inbox: the one Waiting on you message in #coordinator, rendered from the ledger and edited
# in place through a fake Discord (tests/helpers/inbox.bash), posted again only when it is gone.

load helpers/common
load helpers/inbox

STATE=inbox.json

# An opened event of task <task> titled <title>, as team-open logs it.
opened() {
  jq -nc --arg task "$1" --arg title "$2" '{ts: "2026-10-01T10:00:00Z", task: $task, event: "opened", project: "agent-team",
    path: "feature", type: "feat", title: $title, branch: "feat/\($task)", base: "dev", base_sha: "0123456", worktree: "/w/\($task)"}'
}

# Append the events given, one JSON object each, to the ledger, dated in order.
log_events() {
  local event
  for event; do jq -c '{ts: "2026-10-01T11:00:00Z"} + .' <<<"$event" >>"$TEAM_HOME/ledger.jsonl"; done
}

setup() {
  sandbox
  inbox_discord
  state=$HOME/.local/state/agent-team/$STATE
}

# A ledger with something of every kind waiting, and as much that does not: T3's two open asks
# (one with its question's message, one logged by hand) and its settled one, T5's ask with no
# thread to link, T4's PR ready to merge, T6's in review, T8's approved, T9's interview, T10's
# finished one, and closed T11's ask.
waiting_ledger() {
  opened T3 "Three" >>"$TEAM_HOME/ledger.jsonl"
  log_events '{"task":"T3","event":"thread","discord_thread":"3333"}' \
    '{"task":"T3","event":"asked","id":"plan","text":"Approve the plan?\nThe rest of it.","discord_message":"1564000000000000003"}' \
    '{"task":"T3","event":"asked","id":"port","text":"Which port?"}' \
    '{"task":"T3","event":"asked","id":"name","text":"Which name?"}' \
    '{"task":"T3","event":"answered","id":"name","answer":"Kim"}'
  opened T5 "Five" >>"$TEAM_HOME/ledger.jsonl"
  log_events '{"task":"T5","event":"asked","id":"keep","text":"Keep it?"}'
  opened T4 "Four" >>"$TEAM_HOME/ledger.jsonl"
  log_events '{"task":"T4","event":"thread","discord_thread":"4444"}' \
    '{"task":"T4","event":"pr","url":"https://github.com/owner/proj/pull/4","head":"abc1234def"}' \
    '{"task":"T4","event":"review","head":"abc1234def","verdict":"pass"}'
  opened T6 "Six" >>"$TEAM_HOME/ledger.jsonl"
  log_events '{"task":"T6","event":"pr","url":"https://github.com/owner/proj/pull/6","head":"6666666aaa"}'
  opened T8 "Eight" >>"$TEAM_HOME/ledger.jsonl"
  log_events '{"task":"T8","event":"pr","url":"https://github.com/owner/proj/pull/8","head":"8888888aaa"}' \
    '{"task":"T8","event":"review","head":"8888888aaa","verdict":"pass"}' \
    '{"task":"T8","event":"merge-approved","url":"https://github.com/owner/proj/pull/8/","discord_message":"1564000000000000008","head":"8888888aaa"}'
  opened T9 "Nine" >>"$TEAM_HOME/ledger.jsonl"
  log_events '{"task":"T9","event":"interview-thread","discord_thread":"9999"}'
  opened T10 "Ten" >>"$TEAM_HOME/ledger.jsonl"
  log_events '{"task":"T10","event":"interview-thread","discord_thread":"1010"}' \
    '{"task":"T10","event":"done","role":"planner","session":"abcd1234"}'
  opened T11 "Eleven" >>"$TEAM_HOME/ledger.jsonl"
  log_events '{"task":"T11","event":"asked","id":"gone","text":"Still there?"}' \
    '{"task":"T11","event":"closed","archive":[],"returned":[],"kept":[]}'
}

@test "with nothing waiting it posts the message once, says so, and edits the same message from then on" {
  run_bin -0 --separate-stderr team-inbox
  assert_equal "$output" "posted https://discord.com/channels/$INBOX_GUILD/1562486564871995482/1569000000000000001"
  assert_equal "$stderr" ""
  assert_equal "$(inbox_calls)" "GET channels/1562486564871995482
POST channels/1562486564871995482/messages"
  assert_equal "$(inbox_shown | head -n 2)" "**Waiting on you**
Nothing waits on you."
  [[ $(inbox_shown | tail -n 1) =~ ^"-# team-inbox keeps this current; updated <t:"[0-9]+":R>"$ ]]
  # Nothing in it ever pings, and a link shows no preview card.
  jq -e '.allowed_mentions == {parse: []} and .flags == 4' "$STUB_FIXTURES/inbox/1569000000000000001.json"
  assert_equal "$(jq -c . "$state")" \
    "{\"channel\":\"1562486564871995482\",\"guild\":\"$INBOX_GUILD\",\"message\":\"1569000000000000001\"}"

  # The guild is kept, so the next run only edits.
  : >"$STUB_FIXTURES/inbox/calls"
  run_bin -0 team-inbox
  assert_equal "$output" "edited https://discord.com/channels/$INBOX_GUILD/1562486564871995482/1569000000000000001"
  assert_equal "$(inbox_calls)" "PATCH channels/1562486564871995482/messages/1569000000000000001"
}

@test "it lists each open task's unsettled asks with their links, its PRs ready to merge and its interviews under way" {
  waiting_ledger
  run_bin -0 team-inbox
  assert_equal "$(inbox_items_shown)" "**Asks**
- T3 plan: Approve the plan? https://discord.com/channels/$INBOX_GUILD/3333/1564000000000000003
- T3 port: Which port? <#3333>
- T5 keep: Keep it?
**PRs ready to merge**
- T4 Four: https://github.com/owner/proj/pull/4
**Interviews under way**
- T9 Nine: <#9999>"
}

@test "a section with nothing in it is left out, and an ask settled by merge-approved goes with it" {
  opened T4 "Four" >>"$TEAM_HOME/ledger.jsonl"
  log_events '{"task":"T4","event":"pr","url":"https://github.com/owner/proj/pull/4","head":"abc1234def"}' \
    '{"task":"T4","event":"review","head":"abc1234def","verdict":"pass"}' \
    '{"task":"T4","event":"asked","id":"merge","text":"Merge https://github.com/owner/proj/pull/4?"}'
  run_bin -0 team-inbox
  assert_equal "$(inbox_items_shown)" "**Asks**
- T4 merge: Merge https://github.com/owner/proj/pull/4?
**PRs ready to merge**
- T4 Four: https://github.com/owner/proj/pull/4"
  log_events '{"task":"T4","event":"merge-approved","url":"https://github.com/owner/proj/pull/4","discord_message":"1564000000000000004","head":"abc1234def"}'
  run_bin -0 team-inbox
  assert_equal "$(inbox_items_shown)" "Nothing waits on you."
}

@test "a merged PR, a later commit under review, and a closed task leave the list" {
  opened T4 "Four" >>"$TEAM_HOME/ledger.jsonl"
  log_events '{"task":"T4","event":"pr","url":"https://github.com/owner/proj/pull/4","head":"abc1234def"}' \
    '{"task":"T4","event":"review","head":"abc1234def","verdict":"pass"}'
  opened T6 "Six" >>"$TEAM_HOME/ledger.jsonl"
  log_events '{"task":"T6","event":"pr","url":"https://github.com/owner/proj/pull/6","head":"6666666aaa"}' \
    '{"task":"T6","event":"review","head":"6666666aaa","verdict":"pass"}'
  opened T9 "Nine" >>"$TEAM_HOME/ledger.jsonl"
  log_events '{"task":"T9","event":"interview-thread","discord_thread":"9999"}'
  run_bin -0 team-inbox
  assert_equal "$(inbox_items_shown)" "**PRs ready to merge**
- T4 Four: https://github.com/owner/proj/pull/4
- T6 Six: https://github.com/owner/proj/pull/6
**Interviews under way**
- T9 Nine: <#9999>"
  # Approved at an older head, a PR still waits on Daniel's word for the new one.
  log_events '{"task":"T4","event":"merge-approved","url":"https://github.com/owner/proj/pull/4","discord_message":"1564000000000000004","head":"abc1234def"}' \
    '{"task":"T4","event":"merged","pr":4,"merge":"9999999aaa","head":"abc1234def","by":"x","url":"https://github.com/owner/proj/pull/4"}' \
    '{"task":"T6","event":"merge-approved","url":"https://github.com/owner/proj/pull/6","discord_message":"1564000000000000006","head":"5555555aaa"}' \
    '{"task":"T9","event":"plan-approved","by":"Daniel"}'
  run_bin -0 team-inbox
  assert_equal "$(inbox_items_shown)" "**PRs ready to merge**
- T6 Six: https://github.com/owner/proj/pull/6"
  log_events '{"task":"T6","event":"closed","archive":[],"returned":[],"kept":[]}'
  run_bin -0 team-inbox
  assert_equal "$(inbox_items_shown)" "Nothing waits on you."
}

@test "a message deleted by hand, or kept for another channel, is posted again and its new id kept" {
  run_bin -0 team-inbox
  rm "$STUB_FIXTURES/inbox/1569000000000000001.json"
  : >"$STUB_FIXTURES/inbox/calls"
  run_bin -0 team-inbox
  assert_equal "$output" "posted https://discord.com/channels/$INBOX_GUILD/1562486564871995482/1569000000000000002"
  assert_equal "$(inbox_calls)" "PATCH channels/1562486564871995482/messages/1569000000000000001
POST channels/1562486564871995482/messages"
  assert_equal "$(jq -r .message "$state")" 1569000000000000002
  run_bin -0 team-inbox
  assert_equal "$output" "edited https://discord.com/channels/$INBOX_GUILD/1562486564871995482/1569000000000000002"

  # Moved to another channel, the run reads that channel's guild and posts there.
  : >"$STUB_FIXTURES/inbox/calls"
  TEAM_COORDINATOR_CHANNEL=1777 run_bin -0 team-inbox
  assert_equal "$output" "posted https://discord.com/channels/$INBOX_GUILD/1777/1569000000000000003"
  assert_equal "$(inbox_calls)" "GET channels/1777
POST channels/1777/messages"
}

@test "past 2000 characters the last items are left out and counted" {
  local n
  opened T3 "Three" >>"$TEAM_HOME/ledger.jsonl"
  log_events '{"task":"T3","event":"thread","discord_thread":"3333"}'
  for n in $(seq 1 30); do
    log_events "$(jq -nc --arg id "q$n" --arg text "$(printf "Question $n %.0s" {1..20})" \
      '{task: "T3", event: "asked", id: $id, text: $text, discord_message: "1564000000000000001"}')"
  done
  run_bin -0 team-inbox
  local shown
  shown=$(inbox_shown)
  ((${#shown} <= 2000))
  [[ $(sed -n 2p <<<"$shown") == "**Asks**" ]]
  [[ $(sed -n 3p <<<"$shown") == "- T3 q1: Question 1 Question 1 "* ]]
  # Every ask is either shown or counted.
  local listed more
  listed=$(grep -c '^- T3 q' <<<"$shown")
  more=$(sed -nE 's/^- and ([0-9]+) more, which team-snapshot lists$/\1/p' <<<"$shown")
  assert_equal "$((listed + more))" 30
  ((listed > 5))
}

@test "Discord refusing the edit leaves the kept message as it was: 429 is exit 75 with the wait, anything else exit 1" {
  run_bin -0 team-inbox
  echo "429 3" >"$STUB_FIXTURES/inbox/fail"
  run_bin -75 --separate-stderr team-inbox
  assert_equal "$output" ""
  assert_equal "$stderr" "team-inbox: Discord is rate-limiting the bot (429) on the edit of message 1569000000000000001: try again in 3 s"
  echo "500" >"$STUB_FIXTURES/inbox/fail"
  run_bin -1 --separate-stderr team-inbox
  assert_equal "$stderr" "team-inbox: Discord refused the edit of message 1569000000000000001: curl: (22) The requested URL returned error: 500"
  assert_equal "$(jq -r .message "$state")" 1569000000000000001
  assert_equal "$(grep -c POST "$STUB_FIXTURES/inbox/calls")" 1
}

@test "without the guild or the token it refuses and keeps nothing" {
  echo "403" >"$STUB_FIXTURES/inbox/fail"
  run_bin -1 --separate-stderr team-inbox
  assert_equal "$stderr" "team-inbox: Discord refused the read of #coordinator's channel: curl: (22) The requested URL returned error: 403"
  [[ ! -e $state ]]
  rm "$STUB_FIXTURES/inbox/fail" "$HOME/.claude/channels/discord/.env"
  : >"$STUB_FIXTURES/inbox/calls"
  run_bin -1 --separate-stderr team-inbox
  assert_equal "$stderr" "team-inbox: no DISCORD_BOT_TOKEN in ~/.claude/channels/discord/.env"
  assert_equal "$(inbox_calls)" ""
}

@test "a fenced machine refuses before any call to Discord" {
  mkdir -p "$HOME/.local/state/agent-team"
  echo '{"since": "2026-10-29T10:00:00Z"}' >"$HOME/.local/state/agent-team/fenced"
  run_bin -1 --separate-stderr team-inbox
  assert_contains "$stderr" "is fenced since 2026-10-29T10:00:00Z: a fenced machine posts nothing to Discord"
  assert_equal "$(stub_calls curl)" ""
}

@test "a worker session refuses before any call to Discord" {
  local role
  for role in planner builder reviewer ops; do
    AGENT_TEAM_ROLE=$role AGENT_TEAM_TASK=T7 run_bin -1 --separate-stderr team-inbox
    assert_equal "$stderr" "team-inbox: a $role session edits nothing in Discord: that is the coordinator's; send it your message"
  done
  assert_equal "$(stub_calls curl)" ""
}

@test "--help prints the header, and any argument is a usage error" {
  run_bin -0 team-inbox --help
  assert_contains "$output" "Usage: team-inbox"
  run_bin -2 team-inbox --now
  assert_contains "$output" "usage: team-inbox"
}
