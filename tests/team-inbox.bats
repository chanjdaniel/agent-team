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
  # With no record and no reading, the team is at manual full with no budget yet.
  assert_equal "$(inbox_shown | head -n 3)" "**Waiting on you**
Nothing waits on you.
Resources: manual, full (90%): no reading of the machine's load yet, so no budget"
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

@test "a PR whose latest review, a pass logged through team-log, sent findings back is not ready to merge until a pass sends none" {
  opened T4 "Four" >>"$TEAM_HOME/ledger.jsonl"
  log_events '{"task":"T4","event":"pr","url":"https://github.com/owner/proj/pull/4","head":"abc1234def"}'
  local counts='findings=blocking:0,correctness:1,security:0,real-data:0,note-change:0,note-before:0'
  run_bin -0 team-log T4 review verdict=pass head=abc1234def "$counts" sent_back=1 guarded=none
  run_bin -0 team-inbox
  assert_equal "$(inbox_items_shown)" "Nothing waits on you."
  run_bin -0 team-log T4 review verdict=pass head=abc1234def "$counts" sent_back=none guarded=none
  run_bin -0 team-inbox
  assert_equal "$(inbox_items_shown)" "**PRs ready to merge**
- T4 Four: https://github.com/owner/proj/pull/4"
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

@test "a PR with Daniel's standing plan-time word, in a project that opts in and is not the team's own, waits on no word of theirs" {
  plan_registry
  preapproved_pr T4 proj 4
  preapproved_pr T5 conv 5
  preapproved_pr T6 agent-team 6
  preapproved_pr T7 proj 7
  log_events '{"task":"T7","event":"merge-preapproval-withdrawn","project":"proj","discord_message":"1564000000000000002"}'
  run_bin -0 --separate-stderr team-inbox
  assert_equal "$stderr" ""
  assert_equal "$(inbox_items_shown)" "**PRs ready to merge**
- T5 Task T5: https://github.com/owner/conv/pull/5
- T6 Task T6: https://github.com/owner/agent-team/pull/6
- T7 Task T7: https://github.com/owner/proj/pull/7"

  # A refused plan-time merge comes back as an ask naming the PR's URL, which merge-approved settles.
  log_events '{"task":"T4","event":"asked","id":"merge-4","text":"Merge https://github.com/owner/proj/pull/4 at abc1234?"}'
  run_bin -0 team-inbox
  assert_equal "$(inbox_items_shown | head -n 2)" "**Asks**
- T4 merge-4: Merge https://github.com/owner/proj/pull/4 at abc1234?"
  assert_equal "$(inbox_items_shown | grep -c 'pull/4')" 1
  log_events '{"task":"T4","event":"merge-approved","url":"https://github.com/owner/proj/pull/4","discord_message":"1564000000000000003","head":"abc1234def"}'
  run_bin -0 team-inbox
  assert_equal "$(inbox_items_shown | grep -c 'pull/4')" 0

  # The registry is read at each run: proj no longer opting in brings its PR back.
  sed -i '/^merge_with_plan = true$/d' "$TEAM_HOME/projects.toml"
  log_events '{"task":"T4","event":"merged","pr":4,"merge":"9999999aaa","head":"abc1234def","by":"x","url":"https://github.com/owner/proj/pull/4"}'
  preapproved_pr T8 proj 8
  run_bin -0 team-inbox
  assert_equal "$(inbox_items_shown | grep 'pull/8')" "- T8 Task T8: https://github.com/owner/proj/pull/8"
}

@test "with a plan-time word logged and the registry unreadable, every PR ready to merge is listed and stderr says why" {
  preapproved_pr T4 proj 4
  run_bin -0 --separate-stderr team-inbox
  assert_equal "$(inbox_items_shown)" "**PRs ready to merge**
- T4 Task T4: https://github.com/owner/proj/pull/4"
  assert_equal "$stderr" "team-inbox: lists every PR ready to merge, Daniel's plan-time word aside, since the registry cannot be read: team-project: no registry at $TEAM_HOME/projects.toml"
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

@test "the resources line follows the items, naming the open tasks stowed, waiting to resume" {
  waiting_ledger
  # Manual minor on a 32 GiB machine with 12 GiB left to the team: 9.6 GiB and 3.6 cores.
  capacity_room $((12 * 1073741824)) minor
  export TEAM_SLOTS_CPUS=12
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
  assert_equal "$(inbox_shown | sed '1d;$d' | tail -n 2)" "- T9 Nine: <#9999>
Resources: manual, minor (30%): 9.6 GiB and 3.6 cores for the team; 0.0 GiB reserved; T5, T6 and T12 stowed, waiting to resume"
}

@test "when team-level fails the resources line is left out, and stderr says why" {
  echo 'not json' >"$TEAM_HOME/level.jsonl"
  run_bin -0 --separate-stderr team-inbox
  assert_contains "$stderr" "team-inbox: leaves out the resources line, since team-level status failed: team-level: "
  assert_contains "$stderr" "level.jsonl has lines that are not level records"
  assert_equal "$(inbox_shown | sed '$d')" "**Waiting on you**
Nothing waits on you."
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
  # The resources line stays, after the count.
  assert_equal "$(tail -n 2 <<<"$shown" | head -n 1)" "Resources: manual, full (90%): no reading of the machine's load yet, so no budget"
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
