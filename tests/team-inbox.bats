#!/usr/bin/env bats
# team-inbox: what waits on Daniel, numbered, written from the ledger to the team home's waiting.md
# and waiting.json, with a fake Discord (tests/helpers/inbox.bash) for the guild's read and the
# old Waiting on you message's retire.

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

# The list's items in waiting.json, one "<n> <key>" per line.
numbers() {
  jq -r '.items[] | "\(.n) \(.key)"' "$TEAM_HOME/waiting.json"
}

# Record the list as posted with the items <filter> picks from waiting.json's (all by default), as
# team-inbox --post records a post.
posted_as() {
  jq --arg at 2026-10-01T12:00:00Z "$(printf '.posted = {at: $at, messages: ["1569000000000000009"], items: [.items[] | %s]}' "${1:-.}")" \
    "$TEAM_HOME/waiting.json" >"$BATS_TEST_TMPDIR/waiting.json"
  mv "$BATS_TEST_TMPDIR/waiting.json" "$TEAM_HOME/waiting.json"
}

@test "with nothing waiting it writes waiting.md and waiting.json, reads the guild once and keeps it, and calls Discord for nothing after" {
  run_bin -0 --separate-stderr team-inbox
  assert_equal "$output" "wrote waiting.md: 0 items"
  assert_equal "$stderr" ""
  assert_equal "$(inbox_calls)" "GET channels/1562486564871995482"
  # With no record and no reading, the team is at manual full with no budget yet.
  assert_equal "$(waiting_shown)" "**Waiting on you**
Nothing waits on you.
Resources: manual, full (90%): no reading of the machine's load yet, so no budget"
  # The file ends with its newline.
  [[ -z $(tail -c 1 "$TEAM_HOME/waiting.md") ]]
  assert_equal "$(jq -c . "$TEAM_HOME/waiting.json")" '{"schema":"team-waiting/1","items":[],"standing":[],"posted":null}'
  assert_equal "$(jq -c . "$state")" "{\"channel\":\"1562486564871995482\",\"guild\":\"$INBOX_GUILD\"}"

  # The guild is kept, so the next run calls Discord for nothing.
  : >"$STUB_FIXTURES/inbox/calls"
  run_bin -0 team-inbox
  assert_equal "$output" "wrote waiting.md: 0 items"
  assert_equal "$(inbox_calls)" ""
}

@test "it numbers each open task's unsettled asks with their links, its PRs ready to merge and its interviews under way" {
  waiting_ledger
  run_bin -0 --separate-stderr team-inbox
  assert_equal "$output" "wrote waiting.md: 5 items"
  assert_equal "$stderr" ""
  assert_equal "$(waiting_items_shown)" "**Asks**
- **1** T3 plan: Approve the plan? <https://discord.com/channels/$INBOX_GUILD/3333/1564000000000000003>
- **2** T3 port: Which port? <#3333>
- **3** T5 keep: Keep it?
**PRs ready to merge**
- **4** T4 Four: <https://github.com/owner/proj/pull/4>
**Interviews under way**
- **5** T9 Nine: <#9999>"
  # waiting.json holds each item, its number, key and line, in the order waiting.md shows them.
  assert_equal "$(jq -c '.items[0], .items[3], .items[4]' "$TEAM_HOME/waiting.json")" \
    "{\"n\":1,\"key\":\"ask T3 plan 2026-10-01T11:00:00Z\",\"kind\":\"ask\",\"task\":\"T3\",\"title\":\"Three\",\"id\":\"plan\",\"text\":\"Approve the plan?\",\"thread\":\"3333\",\"message\":\"1564000000000000003\",\"line\":\"- **1** T3 plan: Approve the plan? <https://discord.com/channels/$INBOX_GUILD/3333/1564000000000000003>\"}
{\"n\":4,\"key\":\"pr https://github.com/owner/proj/pull/4\",\"kind\":\"pr\",\"task\":\"T4\",\"title\":\"Four\",\"url\":\"https://github.com/owner/proj/pull/4\",\"line\":\"- **4** T4 Four: <https://github.com/owner/proj/pull/4>\"}
{\"n\":5,\"key\":\"interview T9 9999\",\"kind\":\"interview\",\"task\":\"T9\",\"title\":\"Nine\",\"thread\":\"9999\",\"line\":\"- **5** T9 Nine: <#9999>\"}"
  assert_equal "$(jq -r '.items[] | .line' "$TEAM_HOME/waiting.json")" "$(waiting_items_shown | grep '^- ')"

  # One item is "1 item".
  log_events '{"task":"T3","event":"closed","archive":[],"returned":[],"kept":[]}' \
    '{"task":"T4","event":"closed","archive":[],"returned":[],"kept":[]}' \
    '{"task":"T9","event":"closed","archive":[],"returned":[],"kept":[]}'
  run_bin -0 team-inbox
  assert_equal "$output" "wrote waiting.md: 1 item"
}

@test "a section with nothing in it is left out, and an ask settled by merge-approved goes with it" {
  opened T4 "Four" >>"$TEAM_HOME/ledger.jsonl"
  log_events '{"task":"T4","event":"pr","url":"https://github.com/owner/proj/pull/4","head":"abc1234def"}' \
    '{"task":"T4","event":"review","head":"abc1234def","verdict":"pass"}' \
    '{"task":"T4","event":"asked","id":"merge","text":"Merge https://github.com/owner/proj/pull/4?"}'
  run_bin -0 team-inbox
  assert_equal "$(waiting_items_shown)" "**Asks**
- **1** T4 merge: Merge https://github.com/owner/proj/pull/4?
**PRs ready to merge**
- **2** T4 Four: <https://github.com/owner/proj/pull/4>"
  log_events '{"task":"T4","event":"merge-approved","url":"https://github.com/owner/proj/pull/4","discord_message":"1564000000000000004","head":"abc1234def"}'
  run_bin -0 team-inbox
  assert_equal "$(waiting_items_shown)" "Nothing waits on you."
}

@test "a PR whose latest review, a pass logged through team-log, sent findings back is not ready to merge until a pass sends none" {
  opened T4 "Four" >>"$TEAM_HOME/ledger.jsonl"
  log_events '{"task":"T4","event":"pr","url":"https://github.com/owner/proj/pull/4","head":"abc1234def"}'
  local counts='findings=blocking:0,correctness:1,security:0,real-data:0,note-change:0,note-before:0'
  run_bin -0 team-log T4 review verdict=pass head=abc1234def "$counts" sent_back=1 guarded=none
  run_bin -0 team-inbox
  assert_equal "$(waiting_items_shown)" "Nothing waits on you."
  run_bin -0 team-log T4 review verdict=pass head=abc1234def "$counts" sent_back=none guarded=none
  run_bin -0 team-inbox
  assert_equal "$(waiting_items_shown)" "**PRs ready to merge**
- **1** T4 Four: <https://github.com/owner/proj/pull/4>"
}

@test "a merged PR, a later commit under review, and a closed task leave the list, and what stands keeps its number" {
  opened T4 "Four" >>"$TEAM_HOME/ledger.jsonl"
  log_events '{"task":"T4","event":"pr","url":"https://github.com/owner/proj/pull/4","head":"abc1234def"}' \
    '{"task":"T4","event":"review","head":"abc1234def","verdict":"pass"}'
  opened T6 "Six" >>"$TEAM_HOME/ledger.jsonl"
  log_events '{"task":"T6","event":"pr","url":"https://github.com/owner/proj/pull/6/","head":"6666666aaa"}' \
    '{"task":"T6","event":"review","head":"6666666aaa","verdict":"pass"}'
  opened T9 "Nine" >>"$TEAM_HOME/ledger.jsonl"
  log_events '{"task":"T9","event":"interview-thread","discord_thread":"9999"}'
  run_bin -0 team-inbox
  assert_equal "$(waiting_items_shown)" "**PRs ready to merge**
- **1** T4 Four: <https://github.com/owner/proj/pull/4>
- **2** T6 Six: <https://github.com/owner/proj/pull/6/>
**Interviews under way**
- **3** T9 Nine: <#9999>"
  # A PR's key drops its URL's trailing slash.
  assert_equal "$(numbers | sed -n 2p)" "2 pr https://github.com/owner/proj/pull/6"
  # Approved at an older head, a PR still waits on Daniel's word for the new one.
  log_events '{"task":"T4","event":"merge-approved","url":"https://github.com/owner/proj/pull/4","discord_message":"1564000000000000004","head":"abc1234def"}' \
    '{"task":"T4","event":"merged","pr":4,"merge":"9999999aaa","head":"abc1234def","by":"x","url":"https://github.com/owner/proj/pull/4"}' \
    '{"task":"T6","event":"merge-approved","url":"https://github.com/owner/proj/pull/6","discord_message":"1564000000000000006","head":"5555555aaa"}' \
    '{"task":"T9","event":"plan-approved","by":"Daniel"}'
  run_bin -0 team-inbox
  assert_equal "$(waiting_items_shown)" "**PRs ready to merge**
- **2** T6 Six: <https://github.com/owner/proj/pull/6/>"
  log_events '{"task":"T6","event":"closed","archive":[],"returned":[],"kept":[]}'
  run_bin -0 team-inbox
  assert_equal "$(waiting_items_shown)" "Nothing waits on you."
}

@test "an item keeps its number while it stands, and a new item takes the lowest number no standing item holds" {
  opened T3 "Three" >>"$TEAM_HOME/ledger.jsonl"
  log_events '{"task":"T3","event":"thread","discord_thread":"3333"}' \
    '{"task":"T3","event":"asked","id":"a","text":"A?"}' \
    '{"task":"T3","event":"asked","id":"b","text":"B?"}' \
    '{"task":"T3","event":"asked","id":"c","text":"C?"}'
  run_bin -0 team-inbox
  assert_equal "$(numbers)" "1 ask T3 a 2026-10-01T11:00:00Z
2 ask T3 b 2026-10-01T11:00:00Z
3 ask T3 c 2026-10-01T11:00:00Z"
  log_events '{"task":"T3","event":"answered","id":"a","answer":"yes"}'
  run_bin -0 team-inbox
  assert_equal "$(waiting_items_shown)" "**Asks**
- **2** T3 b: B? <#3333>
- **3** T3 c: C? <#3333>"
  # T2's new ask, listed first by its task, takes the free 1; T3's next takes 4.
  opened T2 "Two" >>"$TEAM_HOME/ledger.jsonl"
  log_events '{"task":"T2","event":"asked","id":"d","text":"D?"}' \
    '{"task":"T3","event":"asked","id":"e","text":"E?"}'
  run_bin -0 team-inbox
  assert_equal "$(waiting_items_shown)" "**Asks**
- **1** T2 d: D?
- **2** T3 b: B? <#3333>
- **3** T3 c: C? <#3333>
- **4** T3 e: E? <#3333>"
}

@test "a number the latest post showed is not given to a new item until the next post frees it, and a re-asked id is a new item" {
  opened T3 "Three" >>"$TEAM_HOME/ledger.jsonl"
  log_events '{"task":"T3","event":"asked","id":"a","text":"A?"}' \
    '{"task":"T3","event":"asked","id":"b","text":"B?"}'
  run_bin -0 team-inbox
  posted_as
  # a settles and is asked again: the new ask is a new item, which skips the 1 the post showed.
  log_events '{"task":"T3","event":"answered","id":"a","answer":"no"}' \
    '{"ts":"2026-10-01T12:30:00Z","task":"T3","event":"asked","id":"a","text":"A, again?"}'
  run_bin -0 team-inbox
  assert_equal "$(numbers)" "2 ask T3 b 2026-10-01T11:00:00Z
3 ask T3 a 2026-10-01T12:30:00Z"
  # The run keeps the post as it was.
  assert_equal "$(jq -c '.posted | [.at, .messages, [.items[].n]]' "$TEAM_HOME/waiting.json")" \
    '["2026-10-01T12:00:00Z",["1569000000000000009"],[1,2]]'
  # A post showing 2 and 3 frees 1.
  posted_as
  log_events '{"task":"T3","event":"asked","id":"c","text":"C?"}'
  run_bin -0 team-inbox
  assert_equal "$(waiting_items_shown)" "**Asks**
- **1** T3 c: C?
- **2** T3 b: B?
- **3** T3 a: A, again?"
}

@test "an unreadable waiting.json, or one of another schema, numbers the list afresh and says so; a missing one says nothing" {
  opened T3 "Three" >>"$TEAM_HOME/ledger.jsonl"
  log_events '{"task":"T3","event":"asked","id":"a","text":"A?"}'
  # The numbers come from the file there.
  jq -n '{schema: "team-waiting/1", items: [{n: 7, key: "ask T3 a 2026-10-01T11:00:00Z"}], standing: [], posted: null}' \
    >"$TEAM_HOME/waiting.json"
  run_bin -0 --separate-stderr team-inbox
  assert_equal "$stderr" ""
  assert_equal "$(numbers)" "7 ask T3 a 2026-10-01T11:00:00Z"

  echo 'not json' >"$TEAM_HOME/waiting.json"
  run_bin -0 --separate-stderr team-inbox
  assert_equal "$stderr" "team-inbox: numbers the list afresh, since waiting.json cannot be read: jq: parse error: Invalid numeric literal at line 1, column 4"
  assert_equal "$(numbers)" "1 ask T3 a 2026-10-01T11:00:00Z"

  jq -n '{schema: "team-waiting/0", items: [{n: 7, key: "ask T3 a 2026-10-01T11:00:00Z"}]}' >"$TEAM_HOME/waiting.json"
  run_bin -0 --separate-stderr team-inbox
  assert_equal "$stderr" "team-inbox: numbers the list afresh, since waiting.json cannot be read: its schema is not team-waiting/1"
  assert_equal "$(numbers)" "1 ask T3 a 2026-10-01T11:00:00Z"

  rm "$TEAM_HOME/waiting.json"
  run_bin -0 --separate-stderr team-inbox
  assert_equal "$stderr" ""
  assert_equal "$(numbers)" "1 ask T3 a 2026-10-01T11:00:00Z"
}

@test "two runs over the same ledger and readings leave both files byte for byte the same, with no time of the run in them" {
  waiting_ledger
  hold_lease home-pc >/dev/null
  run_bin -0 team-inbox
  cp "$TEAM_HOME/waiting.md" "$TEAM_HOME/waiting.json" "$BATS_TEST_TMPDIR/"
  sleep 1
  run_bin -0 team-inbox
  cmp "$BATS_TEST_TMPDIR/waiting.md" "$TEAM_HOME/waiting.md"
  cmp "$BATS_TEST_TMPDIR/waiting.json" "$TEAM_HOME/waiting.json"
  run -1 grep -q '<t:' "$TEAM_HOME/waiting.md"
}

@test "when the guild cannot be read it links each ask to its thread alone, says why, and exits 0" {
  waiting_ledger
  standing merge-standing all 1564100000000000001
  echo "403" >"$STUB_FIXTURES/inbox/fail"
  run_bin -0 --separate-stderr team-inbox
  assert_contains "$stderr" "team-inbox: links each ask to its thread alone, since Discord refused the read of #coordinator's channel: curl: (22) The requested URL returned error: 403"
  assert_equal "$(waiting_items_shown | sed -n 2p)" "- **1** T3 plan: Approve the plan? <#3333>"
  assert_equal "$(waiting_items_shown | tail -n 1)" \
    "-# Standing merge word on every project since message 1564100000000000001 in <#1562486564871995482>"
  [[ ! -e $state ]]

  # With no token, it asks Discord nothing.
  rm "$STUB_FIXTURES/inbox/fail" "$HOME/.claude/channels/discord/.env"
  : >"$STUB_FIXTURES/inbox/calls"
  run_bin -0 --separate-stderr team-inbox
  assert_contains "$stderr" "team-inbox: links each ask to its thread alone, since no DISCORD_BOT_TOKEN in ~/.claude/channels/discord/.env"
  assert_equal "$(waiting_items_shown | sed -n 2p)" "- **1** T3 plan: Approve the plan? <#3333>"
  assert_equal "$(inbox_calls)" ""
}

@test "the old Waiting on you message is edited once to say it is no longer kept, and dropped from inbox.json" {
  inbox_kept
  : >"$STUB_FIXTURES/inbox/calls"
  run_bin -0 --separate-stderr team-inbox
  assert_equal "$output" "retired https://discord.com/channels/$INBOX_GUILD/1562486564871995482/1569000000000000000
wrote waiting.md: 0 items"
  assert_equal "$stderr" ""
  assert_equal "$(inbox_calls)" "PATCH channels/1562486564871995482/messages/1569000000000000000"
  assert_equal "$(jq -c . "$STUB_FIXTURES/inbox/1569000000000000000.json")" \
    '{"content":"**Waiting on you** is no longer kept here: ask the coordinator what waits on you, and it posts the list fresh, numbered so one reply answers several.","allowed_mentions":{"parse":[]},"flags":4}'
  assert_equal "$(jq -c . "$state")" "{\"channel\":\"1562486564871995482\",\"guild\":\"$INBOX_GUILD\"}"

  # A second run edits nothing.
  : >"$STUB_FIXTURES/inbox/calls"
  run_bin -0 team-inbox
  assert_equal "$output" "wrote waiting.md: 0 items"
  assert_equal "$(inbox_calls)" ""
}

@test "an old message Discord no longer has, or another channel's, is dropped with no edit and no line" {
  inbox_kept
  rm "$STUB_FIXTURES/inbox/1569000000000000000.json"
  run_bin -0 --separate-stderr team-inbox
  assert_equal "$output" "wrote waiting.md: 0 items"
  assert_equal "$stderr" ""
  assert_equal "$(inbox_calls)" "PATCH channels/1562486564871995482/messages/1569000000000000000"
  assert_equal "$(jq -c . "$state")" "{\"channel\":\"1562486564871995482\",\"guild\":\"$INBOX_GUILD\"}"

  # One kept for another channel is never edited; #coordinator's guild is read and kept.
  jq -n '{channel: "1777", guild: "1550000000000000000", message: "1569000000000000005"}' >"$state"
  : >"$STUB_FIXTURES/inbox/calls"
  run_bin -0 --separate-stderr team-inbox
  assert_equal "$output" "wrote waiting.md: 0 items"
  assert_equal "$stderr" ""
  assert_equal "$(inbox_calls)" "GET channels/1562486564871995482"
  assert_equal "$(jq -c . "$state")" "{\"channel\":\"1562486564871995482\",\"guild\":\"$INBOX_GUILD\"}"
}

@test "an old message Discord refuses to edit, or with no token, is kept for the next run, which retires it; the list is written and it exits 0" {
  inbox_kept
  echo "500" >"$STUB_FIXTURES/inbox/fail"
  run_bin -0 --separate-stderr team-inbox
  assert_equal "$output" "wrote waiting.md: 0 items"
  assert_equal "$stderr" "team-inbox: the old Waiting on you message https://discord.com/channels/$INBOX_GUILD/1562486564871995482/1569000000000000000 is not retired yet: Discord refused the edit of message 1569000000000000000: curl: (22) The requested URL returned error: 500; the next run tries again"
  assert_equal "$(jq -r .message "$state")" 1569000000000000000
  assert_equal "$(waiting_items_shown)" "Nothing waits on you."

  rm "$STUB_FIXTURES/inbox/fail"
  mv "$HOME/.claude/channels/discord/.env" "$BATS_TEST_TMPDIR/env"
  : >"$STUB_FIXTURES/inbox/calls"
  run_bin -0 --separate-stderr team-inbox
  assert_equal "$stderr" "team-inbox: the old Waiting on you message https://discord.com/channels/$INBOX_GUILD/1562486564871995482/1569000000000000000 is not retired yet: no DISCORD_BOT_TOKEN in ~/.claude/channels/discord/.env; the next run tries again"
  assert_equal "$(inbox_calls)" ""

  mv "$BATS_TEST_TMPDIR/env" "$HOME/.claude/channels/discord/.env"
  run_bin -0 team-inbox
  assert_equal "$output" "retired https://discord.com/channels/$INBOX_GUILD/1562486564871995482/1569000000000000000
wrote waiting.md: 0 items"
  assert_equal "$(jq -c 'has("message")' "$state")" false
}

@test "a list it cannot write is exit 1 naming the file" {
  mkdir "$TEAM_HOME/waiting.md"
  run_bin -1 --separate-stderr team-inbox
  assert_contains "$stderr" "team-inbox: cannot write $TEAM_HOME/waiting.md: "
  assert_equal "$output" ""
  # No temporary file is left in the team home.
  assert_equal "$(find "$TEAM_HOME" -maxdepth 1 -name '.waiting*')" ""
}

# A registry where proj opts in to plan-time merges, conv does not, and agent-team, the team's own
# project, has its key left out, as the registry must.
plan_registry() {
  local name with
  for name in proj conv agent-team; do
    with=''
    [[ $name != proj ]] || with=$'\nmerge_with_plan = true'
    cat >>"$TEAM_HOME/projects.toml" <<TOML
[$name]
repo = "owner/$name"
path = "projects/$name"
base = "main"
delivery = "direct-pr"
merge_method = "merge"$with
required_checks = []
task_dir = ".scratch/task"
docs = []
toolkits = []

[$name.pool]
provider = "git"
slots = ["slots/$name/1"]

TOML
  done
}

# Task <task> of <project>, its PR <n> in that project's repo reviewed and passed, and Daniel's
# plan-time word on it logged.
preapproved_pr() {
  jq -nc --arg task "$1" --arg project "$2" '{ts: "2026-10-01T10:00:00Z", task: $task, event: "opened",
    project: $project, path: "feature", type: "feat", title: "Task \($task)", branch: "feat/\($task)",
    base: "main", base_sha: "0123456", worktree: "/w/\($task)"}' >>"$TEAM_HOME/ledger.jsonl"
  log_events "{\"task\":\"$1\",\"event\":\"asked\",\"id\":\"plan\",\"text\":\"Approve the plan, and its merge?\"}" \
    "{\"task\":\"$1\",\"event\":\"merge-preapproved\",\"project\":\"$2\",\"ask\":\"plan\",\"discord_message\":\"1564000000000000001\",\"scope\":[\"src/\"]}" \
    "{\"task\":\"$1\",\"event\":\"pr\",\"url\":\"https://github.com/owner/$2/pull/$3\",\"head\":\"abc1234def\"}" \
    "{\"task\":\"$1\",\"event\":\"review\",\"head\":\"abc1234def\",\"verdict\":\"pass\"}"
}

@test "a PR with Daniel's plan-time word not withdrawn, in a project that opts in and is not the team's own, waits on no word of theirs" {
  plan_registry
  preapproved_pr T4 proj 4
  preapproved_pr T5 conv 5
  preapproved_pr T6 agent-team 6
  preapproved_pr T7 proj 7
  log_events '{"task":"T7","event":"merge-preapproval-withdrawn","project":"proj","discord_message":"1564000000000000002"}'
  run_bin -0 --separate-stderr team-inbox
  assert_equal "$stderr" ""
  assert_equal "$(waiting_items_shown)" "**PRs ready to merge**
- **1** T5 Task T5: <https://github.com/owner/conv/pull/5>
- **2** T6 Task T6: <https://github.com/owner/agent-team/pull/6>
- **3** T7 Task T7: <https://github.com/owner/proj/pull/7>"

  # A refused plan-time merge comes back as an ask naming the PR's URL, which merge-approved settles.
  log_events '{"task":"T4","event":"asked","id":"merge-4","text":"Merge https://github.com/owner/proj/pull/4 at abc1234?"}'
  run_bin -0 team-inbox
  assert_equal "$(waiting_items_shown | head -n 2)" "**Asks**
- **4** T4 merge-4: Merge https://github.com/owner/proj/pull/4 at abc1234?"
  assert_equal "$(waiting_items_shown | grep -c 'pull/4')" 1
  log_events '{"task":"T4","event":"merge-approved","url":"https://github.com/owner/proj/pull/4","discord_message":"1564000000000000003","head":"abc1234def"}'
  run_bin -0 team-inbox
  assert_equal "$(waiting_items_shown | grep -c 'pull/4')" 0

  # The registry is read at each run: proj no longer opting in brings its PR back.
  sed -i '/^merge_with_plan = true$/d' "$TEAM_HOME/projects.toml"
  log_events '{"task":"T4","event":"merged","pr":4,"merge":"9999999aaa","head":"abc1234def","by":"x","url":"https://github.com/owner/proj/pull/4"}'
  preapproved_pr T8 proj 8
  run_bin -0 team-inbox
  assert_equal "$(waiting_items_shown | grep 'pull/8')" "- **4** T8 Task T8: <https://github.com/owner/proj/pull/8>"
}

@test "with a plan-time word logged and the registry unreadable, every PR ready to merge is listed and stderr says why" {
  preapproved_pr T4 proj 4
  run_bin -0 --separate-stderr team-inbox
  assert_equal "$(waiting_items_shown)" "**PRs ready to merge**
- **1** T4 Task T4: <https://github.com/owner/proj/pull/4>"
  assert_equal "$stderr" "team-inbox: lists every PR ready to merge, Daniel's plan-time word aside, since the registry cannot be read: team-project: no registry at $TEAM_HOME/projects.toml"
}

# Task <task> of <project>, its PR <n> in that project's repo reviewed and passed, ready to merge.
ready_pr() {
  jq -nc --arg task "$1" --arg project "$2" '{ts: "2026-10-01T10:00:00Z", task: $task, event: "opened",
    project: $project, path: "feature", type: "feat", title: "Task \($task)", branch: "feat/\($task)",
    base: "main", base_sha: "0123456", worktree: "/w/\($task)"}' >>"$TEAM_HOME/ledger.jsonl"
  log_events "{\"task\":\"$1\",\"event\":\"pr\",\"url\":\"https://github.com/owner/$2/pull/$3\",\"head\":\"abc1234def\"}" \
    "{\"task\":\"$1\",\"event\":\"review\",\"head\":\"abc1234def\",\"verdict\":\"pass\"}"
}

# standing <kind> <project> <message> [<channel>] [<task>]: Daniel's standing word on <project>
# (merge-standing) or its withdrawal (merge-standing-withdrawn), in #coordinator by default,
# logged under T4.
standing() {
  log_events "$(jq -nc --arg kind "$1" --arg project "$2" --arg message "$3" --arg channel "${4:-1562486564871995482}" \
    --arg task "${5:-T4}" '{task: $task, event: $kind, project: $project, discord_message: $message, discord_channel: $channel}')"
}

@test "a standing word on every project names each registered project but the team's own after the items, and leaves out their ready PRs" {
  plan_registry
  ready_pr T4 proj 4
  ready_pr T5 conv 5
  ready_pr T6 agent-team 6
  standing merge-standing all 1564100000000000001
  run_bin -0 --separate-stderr team-inbox
  assert_equal "$stderr" ""
  assert_equal "$(waiting_shown)" "**Waiting on you**
**PRs ready to merge**
- **1** T6 Task T6: <https://github.com/owner/agent-team/pull/6>
-# Standing merge word on proj, conv since <https://discord.com/channels/$INBOX_GUILD/1562486564871995482/1564100000000000001>
Resources: manual, full (90%): no reading of the machine's load yet, so no budget"
  assert_equal "$(jq -c '.standing | map([.projects, .word.discord_message])' "$TEAM_HOME/waiting.json")" \
    '[[["proj","conv"],"1564100000000000001"]]'

  # A merge team-merge refused comes back as the coordinator's ask, which names the PR.
  log_events '{"task":"T4","event":"asked","id":"merge-4","text":"Merge https://github.com/owner/proj/pull/4 at abc1234?"}'
  run_bin -0 team-inbox
  assert_equal "$(waiting_items_shown)" "**Asks**
- **2** T4 merge-4: Merge https://github.com/owner/proj/pull/4 at abc1234?
**PRs ready to merge**
- **1** T6 Task T6: <https://github.com/owner/agent-team/pull/6>
-# Standing merge word on proj, conv since <https://discord.com/channels/$INBOX_GUILD/1562486564871995482/1564100000000000001>"
}

@test "the team's own project is left out of a standing word by its repo or its path as well as by its name" {
  plan_registry
  ready_pr T4 proj 4
  ready_pr T5 conv 5
  standing merge-standing all 1564100000000000001
  # conv's path is the code checkout run_bin runs from, whose origin is proj's repo.
  export CODE_CHECKOUT
  CODE_CHECKOUT=$(make_repo conv)
  copy_bin "$CODE_CHECKOUT/bin"
  git -C "$CODE_CHECKOUT" remote set-url origin https://github.com/Owner/proj/
  run_bin -0 --separate-stderr team-inbox
  assert_equal "$stderr" ""
  assert_equal "$(waiting_items_shown)" "**PRs ready to merge**
- **1** T4 Task T4: <https://github.com/owner/proj/pull/4>
- **2** T5 Task T5: <https://github.com/owner/conv/pull/5>"
}

@test "only the projects a standing word stands for are named, one line per word, and only their PRs are left out" {
  plan_registry
  ready_pr T4 proj 4
  ready_pr T5 conv 5
  ready_pr T6 agent-team 6
  log_events '{"task":"T5","event":"thread","discord_thread":"5555"}'
  standing merge-standing proj 1564100000000000001
  standing merge-standing conv 1564100000000000002 5555 T5
  run_bin -0 team-inbox
  assert_equal "$(waiting_items_shown)" "**PRs ready to merge**
- **1** T6 Task T6: <https://github.com/owner/agent-team/pull/6>
-# Standing merge word on proj since <https://discord.com/channels/$INBOX_GUILD/1562486564871995482/1564100000000000001>
-# Standing merge word on conv since <https://discord.com/channels/$INBOX_GUILD/5555/1564100000000000002>"

  # T5's PR comes back with the next free number, shown after T6's, which keeps its own.
  standing merge-standing-withdrawn conv 1564100000000000003
  run_bin -0 team-inbox
  assert_equal "$(waiting_items_shown)" "**PRs ready to merge**
- **1** T6 Task T6: <https://github.com/owner/agent-team/pull/6>
- **2** T5 Task T5: <https://github.com/owner/conv/pull/5>
-# Standing merge word on proj since <https://discord.com/channels/$INBOX_GUILD/1562486564871995482/1564100000000000001>"

  # A word on every project, withdrawn for one, stands for the others but the team's own under
  # its own message.
  standing merge-standing all 1564100000000000004
  standing merge-standing-withdrawn conv 1564100000000000005
  run_bin -0 team-inbox
  assert_equal "$(waiting_items_shown)" "**PRs ready to merge**
- **1** T6 Task T6: <https://github.com/owner/agent-team/pull/6>
- **2** T5 Task T5: <https://github.com/owner/conv/pull/5>
-# Standing merge word on proj since <https://discord.com/channels/$INBOX_GUILD/1562486564871995482/1564100000000000004>"

  # An old ledger's word on the team's own project names it nowhere and leaves its PR listed.
  standing merge-standing agent-team 1564100000000000006
  run_bin -0 team-inbox
  assert_equal "$(waiting_items_shown)" "**PRs ready to merge**
- **1** T6 Task T6: <https://github.com/owner/agent-team/pull/6>
- **2** T5 Task T5: <https://github.com/owner/conv/pull/5>
-# Standing merge word on proj since <https://discord.com/channels/$INBOX_GUILD/1562486564871995482/1564100000000000004>"
}

@test "with every standing word withdrawn no standing line shows and every ready PR is listed" {
  plan_registry
  ready_pr T4 proj 4
  ready_pr T5 conv 5
  standing merge-standing all 1564100000000000001
  standing merge-standing proj 1564100000000000002
  standing merge-standing-withdrawn all 1564100000000000003
  run_bin -0 --separate-stderr team-inbox
  assert_equal "$stderr" ""
  assert_equal "$(waiting_items_shown)" "**PRs ready to merge**
- **1** T4 Task T4: <https://github.com/owner/proj/pull/4>
- **2** T5 Task T5: <https://github.com/owner/conv/pull/5>"
}

@test "with a standing word logged and the registry unreadable, every PR is listed, the word as logged, and stderr says why" {
  ready_pr T4 proj 4
  standing merge-standing all 1564100000000000001
  run_bin -0 --separate-stderr team-inbox
  assert_equal "$(waiting_items_shown)" "**PRs ready to merge**
- **1** T4 Task T4: <https://github.com/owner/proj/pull/4>
-# Standing merge word on every project since <https://discord.com/channels/$INBOX_GUILD/1562486564871995482/1564100000000000001>"
  assert_equal "$stderr" "team-inbox: lists every PR ready to merge, Daniel's standing word aside, since the registry cannot be read: team-project: no registry at $TEAM_HOME/projects.toml"

  preapproved_pr T5 proj 5
  run_bin -0 --separate-stderr team-inbox
  assert_equal "$stderr" "team-inbox: lists every PR ready to merge, Daniel's plan-time and standing words aside, since the registry cannot be read: team-project: no registry at $TEAM_HOME/projects.toml"
}

@test "the resources line follows the items, naming the open tasks stowed, waiting to resume" {
  waiting_ledger
  # Manual minor on a 32 GiB machine with 12 GiB left to the team: 9.6 GiB and 3.6 cores.
  capacity_room $((12 * 1073741824)) minor
  export TEAM_READING_CPUS=12
  # T5 and T12 were stowed for the level and T6 for a handoff, all three waiting to resume; T9 was
  # relaunched since, and closed T11 is gone.
  local task
  opened T12 "Twelve" >>"$TEAM_HOME/ledger.jsonl"
  for task in T5 T6 T9 T11 T12; do
    log_events "$(jq -nc --arg task "$task" --arg cause "$([[ $task == T6 ]] && echo handoff || echo level)" \
      '{task: $task, event: "stowed", machine: "home-pc", worktrees: [], roles: ["builder"], cause: $cause}')"
  done
  log_events '{"task":"T9","event":"launch","role":"builder","session":"99999999","worktree":"/w/T9","toolkits":[]}'
  run_bin -0 --separate-stderr team-inbox
  assert_equal "$stderr" ""
  assert_equal "$(waiting_shown | tail -n 2)" "- **5** T9 Nine: <#9999>
Resources: manual, minor (30%): 9.6 GiB and 3.6 cores for the team; 0.0 GiB reserved; T5, T6 and T12 stowed, waiting to resume"
  assert_equal "$(inbox_resources_shown)" "Resources: manual, minor (30%): 9.6 GiB and 3.6 cores for the team; 0.0 GiB reserved; T5, T6 and T12 stowed, waiting to resume"
}

@test "when team-level fails the resources line is left out, and stderr says why" {
  echo 'not json' >"$TEAM_HOME/level.jsonl"
  run_bin -0 --separate-stderr team-inbox
  assert_contains "$stderr" "team-inbox: leaves out the resources line, since team-level status failed: team-level: "
  assert_contains "$stderr" "level.jsonl has lines that are not level records"
  assert_equal "$(waiting_shown)" "**Waiting on you**
Nothing waits on you."
}

# Replace team-timers with the bash read from stdin, in a code checkout of the test's own.
fake_timers() {
  CODE_CHECKOUT=$BATS_TEST_TMPDIR/code
  mkdir -p "$CODE_CHECKOUT"
  copy_bin "$CODE_CHECKOUT/bin"
  rm -f "$CODE_CHECKOUT/bin/team-timers"
  { echo '#!/usr/bin/env bash'; cat; } >"$CODE_CHECKOUT/bin/team-timers"
  chmod +x "$CODE_CHECKOUT/bin/team-timers"
}

@test "on the lease holder the health line follows the resources line, and before any record it is an unknown health" {
  hold_lease home-pc >/dev/null
  run_bin -0 --separate-stderr team-inbox
  assert_equal "$stderr" ""
  assert_equal "$(waiting_shown)" "**Waiting on you**
Nothing waits on you.
Resources: manual, full (90%): no reading of the machine's load yet, so no budget
**Health**: unknown - no health record yet; the heartbeat writes one each run"
  assert_equal "$(inbox_health_shown)" "**Health**: unknown - no health record yet; the heartbeat writes one each run"
  assert_equal "$(waiting_items_shown)" "Nothing waits on you."
}

@test "on a machine that is named but does not hold the lease the view has no line, so the list is as it was" {
  run_bin -0 team-inbox
  local before
  before=$(waiting_shown)
  mkdir -p "$HOME/.config/agent-team"
  echo home-pc >"$HOME/.config/agent-team/machine"
  run_bin -0 --separate-stderr team-inbox
  assert_equal "$stderr" ""
  assert_equal "$(waiting_shown)" "$before"
  assert_equal "$(inbox_health_shown)" ""
}

@test "with the health view unreadable, the health line is an unknown health with its reason, stderr says why, and it exits 0" {
  hold_lease home-pc >/dev/null
  fake_timers <<'EOF'
echo "not a view"
echo "team-timers: something first" >&2
echo "team-timers: cannot read the health record $HOME/.local/state/agent-team/health.json" >&2
exit 1
EOF
  run_bin -0 --separate-stderr team-inbox
  assert_equal "$stderr" "team-inbox: shows the health as unknown, since team-timers health printed no view: team-timers: cannot read the health record ~/.local/state/agent-team/health.json"
  assert_equal "$(waiting_shown | tail -n 1)" \
    "**Health**: unknown - team-timers: cannot read the health record ~/.local/state/agent-team/health.json"

  # A view printed with exit 1, a view with problems, is shown as it is.
  fake_timers <<'EOF'
echo '{"schema": "team-health/1", "machine": "home-pc", "holding": true, "ok": false, "line": "**Health**: the heartbeat last ran <t:1:R>", "problems": []}'
exit 1
EOF
  run_bin -0 --separate-stderr team-inbox
  assert_equal "$stderr" ""
  assert_equal "$(inbox_health_shown)" "**Health**: the heartbeat last ran <t:1:R>"

  # A team-timers that prints nothing and says nothing.
  fake_timers <<<'exit 3'
  run_bin -0 --separate-stderr team-inbox
  assert_equal "$stderr" "team-inbox: shows the health as unknown, since team-timers health printed no view: team-timers health exited 3 with no view"
  assert_equal "$(inbox_health_shown)" "**Health**: unknown - team-timers health exited 3 with no view"
}

@test "a list longer than one Discord message is written whole, each line cut as its clip says" {
  local n
  opened T3 "$(printf 'Title %.0s' {1..30})" >>"$TEAM_HOME/ledger.jsonl"
  log_events '{"task":"T3","event":"thread","discord_thread":"3333"}' \
    '{"task":"T3","event":"pr","url":"https://github.com/owner/proj/pull/3","head":"abc1234def"}' \
    '{"task":"T3","event":"review","head":"abc1234def","verdict":"pass"}'
  for n in $(seq 1 30); do
    log_events "$(jq -nc --arg id "q$n" --arg text "$(printf "Question $n %.0s" {1..20})" \
      '{task: "T3", event: "asked", id: $id, text: $text, discord_message: "1564000000000000001"}')"
  done
  run_bin -0 team-inbox
  assert_equal "$output" "wrote waiting.md: 31 items"
  (($(wc -c <"$TEAM_HOME/waiting.md") > 2000))
  assert_equal "$(grep -c '^- \*\*[0-9]*\*\* T3 q' "$TEAM_HOME/waiting.md")" 30
  # An ask's text is cut to 150 characters, a title to 80.
  [[ $(grep -m 1 '^- \*\*1\*\* ' "$TEAM_HOME/waiting.md") == "- **1** T3 q1: $(printf "Question 1 %.0s" {1..20} | cut -c 1-147)... <https://discord.com/channels/$INBOX_GUILD/3333/1564000000000000001>" ]]
  assert_equal "$(grep 'pull/3' "$TEAM_HOME/waiting.md")" "- **31** T3 $(printf 'Title %.0s' {1..30} | cut -c 1-77)...: <https://github.com/owner/proj/pull/3>"
}

@test "another run holding the lock for the wait is exit 75" {
  local lock
  mkdir -p "$HOME/.local/state/agent-team"
  exec {lock}>>"$HOME/.local/state/agent-team/inbox.lock"
  flock "$lock"
  TEAM_INBOX_LOCK_SECONDS=0 run_bin -75 --separate-stderr team-inbox
  assert_equal "$stderr" "team-inbox: another run has held $HOME/.local/state/agent-team/inbox.lock for 0s; try again later"
  [[ ! -e $TEAM_HOME/waiting.md ]]
  exec {lock}>&-
}

@test "a fenced machine refuses before any call to Discord, and writes nothing" {
  mkdir -p "$HOME/.local/state/agent-team"
  echo '{"since": "2026-10-29T10:00:00Z"}' >"$HOME/.local/state/agent-team/fenced"
  run_bin -1 --separate-stderr team-inbox
  assert_contains "$stderr" "is fenced since 2026-10-29T10:00:00Z: a fenced machine posts nothing to Discord"
  assert_equal "$(stub_calls curl)" ""
  [[ ! -e $TEAM_HOME/waiting.md ]]
}

@test "a worker session refuses before any call to Discord, and writes nothing" {
  local role
  for role in planner builder reviewer ops; do
    AGENT_TEAM_ROLE=$role AGENT_TEAM_TASK=T7 run_bin -1 --separate-stderr team-inbox
    assert_equal "$stderr" "team-inbox: a $role session edits nothing in Discord: that is the coordinator's; send it your message"
  done
  assert_equal "$(stub_calls curl)" ""
  [[ ! -e $TEAM_HOME/waiting.md ]]
}

@test "--help prints the header, and any argument is a usage error" {
  run_bin -0 team-inbox --help
  assert_contains "$output" "Usage: team-inbox"
  run_bin -2 team-inbox --now
  assert_contains "$output" "usage: team-inbox"
}
