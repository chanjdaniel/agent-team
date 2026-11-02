#!/usr/bin/env bats
# team-ask: a question put to Daniel in one call: posted in the task's thread with a ping in
# #coordinator, then question, asked and waiting logged, and nothing logged when a post fails.

load helpers/common
load helpers/inbox

setup() {
  sandbox
  cat >"$TEAM_HOME/ledger.jsonl" <<'LEDGER'
{"ts":"2026-10-01T10:00:00Z","task":"T7","event":"opened","project":"agent-team","path":"feature","type":"feat","title":"x","branch":"feat/T7-x","base":"dev","base_sha":"0123456","worktree":"/w/7"}
{"ts":"2026-10-01T10:00:01Z","task":"T7","event":"thread","discord_thread":"2222"}
{"ts":"2026-10-01T10:00:02Z","task":"T8","event":"opened","project":"agent-team","path":"feature","type":"feat","title":"y","branch":"feat/T8-y","base":"dev","base_sha":"0123456","worktree":"/w/8"}
{"ts":"2026-10-01T10:00:03Z","task":"T9","event":"opened","project":"agent-team","path":"feature","type":"feat","title":"z","branch":"feat/T9-z","base":"dev","base_sha":"0123456","worktree":"/w/9"}
{"ts":"2026-10-01T10:00:04Z","task":"T9","event":"thread","discord_thread":"3333"}
{"ts":"2026-10-01T10:00:05Z","task":"T9","event":"closed","archive":[],"returned":[],"kept":[]}
LEDGER
  echo '{"dmPolicy": "allowlist", "allowFrom": ["757"], "groups": {}, "pending": {}}' \
    >"$HOME/.claude/channels/discord/access.json"
  printf '\n  Which of the two sign-in limits stays?  \n\nFive tries a minute, or ten an hour.\n' >"$BATS_TEST_TMPDIR/q.md"
  discord_posts
  inbox_discord
}

# The stub curl answers each post with a new message id (1564000000000000001 for the first, and
# so on); with FAIL_POST=<n>, the n-th post fails as curl -f does on a 403. team-inbox's calls go
# to the fake Discord of helpers/inbox.
discord_posts() {
  stub_script curl <<'EOF'
cat >>"$STUB_CALLS/curl.stdin"
[[ ! -f $STUB_FIXTURES/inbox.sh ]] || source "$STUB_FIXTURES/inbox.sh"
n=$(wc -l <"$STUB_CALLS/curl.log")
if [[ $n == "${FAIL_POST:-}" ]]; then
  echo "curl: (22) The requested URL returned error: 403" >&2
  exit 22
fi
printf '{"id":"%d"}\n' "$((1564000000000000000 + n))"
EOF
}

# The content of each post team-post sent, one JSON string per line.
posted() {
  stub_calls curl | jq -c 'index("-d") as $i | select($i) | .[$i + 1] | fromjson | .content'
}

# The channel each post team-post sent went to, one per line.
channels() {
  stub_calls curl | jq -r 'select(index("-d")) | .[] | select(startswith("https://")) | capture("channels/(?<c>[0-9]+)/messages$").c'
}

# The ledger's events after the setup's, without their ts.
logged() {
  tail -n +7 "$TEAM_HOME/ledger.jsonl" | jq -c 'del(.ts)'
}

@test "an ask posts the question in the thread and a ping in #coordinator, logs question, asked and waiting, and prints the ids" {
  run_bin -0 --separate-stderr team-ask T7 sign-in --file "$BATS_TEST_TMPDIR/q.md" --from planner
  assert_equal "$output" '{"task":"T7","id":"sign-in","question":["1564000000000000001"],"ping":"1564000000000000002"}'
  assert_equal "$stderr" ""
  assert_equal "$(channels)" "2222
1562486564871995482"
  assert_equal "$(posted)" '"Which of the two sign-in limits stays?  \n\nFive tries a minute, or ten an hour."
"<@757> T7 has a question for you in <#2222>: Which of the two sign-in limits stays?"'
  assert_equal "$(logged)" '{"task":"T7","event":"question","role":"planner","text":"Which of the two sign-in limits stays?  \n\nFive tries a minute, or ten an hour."}
{"task":"T7","event":"asked","id":"sign-in","text":"Which of the two sign-in limits stays?","discord_message":"1564000000000000001"}
{"task":"T7","event":"waiting","on":"Daniel","reason":"ask sign-in"}'
  TEAM_HOME=$TEAM_HOME run "$REPO_ROOT/bin/team-log" --check
  assert_equal "$status" 0
  # The Waiting on you message lists it by the end of the command, linked to the question.
  assert_equal "$(inbox_items_shown)" "**Asks**
- T7 sign-in: Which of the two sign-in limits stays? https://discord.com/channels/$INBOX_GUILD/2222/1564000000000000001"
}

@test "--script hashes the script first, ends the question with its path and sha256, and logs one asked with both" {
  mkdir -p "$TEAM_HOME/tasks/T7/scripts"
  printf 'echo fixing\n' >"$TEAM_HOME/tasks/T7/scripts/fix.sh"
  ln -s "$TEAM_HOME/tasks/T7/scripts/fix.sh" "$BATS_TEST_TMPDIR/link.sh"
  local hash path=$TEAM_HOME/tasks/T7/scripts/fix.sh
  hash=$(sha256sum "$path" | cut -d' ' -f1)
  (cd "$BATS_TEST_TMPDIR" && run_bin -0 team-ask T7 fix --file q.md --script link.sh --from builder)
  assert_equal "$(posted | head -n 1 | jq -r .)" "Which of the two sign-in limits stays?  

Five tries a minute, or ten an hour.

Script: $path
sha256: $hash"
  assert_equal "$(logged | jq -c 'select(.event == "asked")')" \
    "$(jq -cn --arg path "$path" --arg hash "$hash" '{task: "T7", event: "asked", id: "fix",
      text: "Which of the two sign-in limits stays?", script: $path, sha256: $hash,
      discord_message: "1564000000000000001"}')"
  assert_equal "$(logged | jq -r .event)" "question
asked
waiting"
  TEAM_HOME=$TEAM_HOME run "$REPO_ROOT/bin/team-log" --check
  assert_equal "$status" 0

  # A script that is not a readable file is refused before any post.
  local before
  before=$(stub_calls curl)
  run_bin -1 team-ask T7 gone --file "$BATS_TEST_TMPDIR/q.md" --script "$BATS_TEST_TMPDIR/none.sh"
  assert_equal "$output" "team-ask: no script to ask about: $BATS_TEST_TMPDIR/none.sh"
  run_bin -1 team-ask T7 gone --file "$BATS_TEST_TMPDIR/q.md" --script "$TEAM_HOME/tasks/T7/scripts"
  assert_equal "$output" "team-ask: no script to ask about: $TEAM_HOME/tasks/T7/scripts"
  # So is a script team-run-approved would never run: one outside the task's worktrees and its
  # task directory, there through a link, or in another task's directory.
  local places="$TEAM_HOME/tasks/T7"
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere" "$TEAM_HOME/tasks/T8"
  printf 'echo fixing\n' | tee "$BATS_TEST_TMPDIR/elsewhere/fix.sh" >"$TEAM_HOME/tasks/T8/fix.sh"
  ln -s "$BATS_TEST_TMPDIR/elsewhere/fix.sh" "$TEAM_HOME/tasks/T7/scripts/out.sh"
  run_bin -1 team-ask T7 out --file "$BATS_TEST_TMPDIR/q.md" --script "$BATS_TEST_TMPDIR/elsewhere/fix.sh"
  assert_equal "$output" "team-ask: $BATS_TEST_TMPDIR/elsewhere/fix.sh is not under T7's worktrees or its task directory, so team-run-approved would never run it: $places"
  run_bin -1 team-ask T7 out --file "$BATS_TEST_TMPDIR/q.md" --script "$TEAM_HOME/tasks/T7/scripts/out.sh"
  assert_equal "$output" "team-ask: $TEAM_HOME/tasks/T7/scripts/out.sh is not under T7's worktrees or its task directory, so team-run-approved would never run it: $places"
  run_bin -1 team-ask T7 out --file "$BATS_TEST_TMPDIR/q.md" --script "$TEAM_HOME/tasks/T8/fix.sh"
  assert_equal "$output" "team-ask: $TEAM_HOME/tasks/T8/fix.sh is not under T7's worktrees or its task directory, so team-run-approved would never run it: $places"
  assert_equal "$(stub_calls curl)" "$before"
  assert_equal "$(logged | jq -r .event)" "question
asked
waiting"
}

@test "a Waiting on you message Discord refuses is a line on stderr, and the ask stands" {
  echo 500 >"$STUB_FIXTURES/inbox/fail"
  run_bin -0 --separate-stderr team-ask T7 sign-in --file "$BATS_TEST_TMPDIR/q.md"
  assert_equal "$output" '{"task":"T7","id":"sign-in","question":["1564000000000000001"],"ping":"1564000000000000002"}'
  assert_equal "$stderr" "team-ask: the Waiting on you message is not updated: Discord refused the read of #coordinator's channel: curl: (22) The requested URL returned error: 500"
  assert_equal "$(logged | jq -r .event)" "asked
waiting"
}

@test "with no --from the ask is the coordinator's own, so no question is logged" {
  run_bin -0 team-ask T7 sign-in --file "$BATS_TEST_TMPDIR/q.md"
  assert_equal "$(logged | jq -r .event)" "asked
waiting"
}

@test "the ping mentions each of Daniel's ids and cuts a long first line" {
  echo '{"allowFrom": ["757", 758], "groups": {}}' >"$HOME/.claude/channels/discord/access.json"
  local long
  long=$(printf 'word %.0s' {1..60})
  printf '%s\nmore\n' "$long" >"$BATS_TEST_TMPDIR/q.md"
  run_bin -0 team-ask T7 long --file "$BATS_TEST_TMPDIR/q.md"
  assert_equal "$(posted | tail -n 1 | jq -r .)" "<@757> <@758> T7 has a question for you in <#2222>: ${long:0:197}..."
  # asked keeps the whole first line.
  assert_equal "$(logged | jq -r 'select(.event == "asked") | .text')" "${long% }"
}

@test "a refused question posts no ping and logs nothing" {
  FAIL_POST=1 run_bin -1 --separate-stderr team-ask T7 sign-in --file "$BATS_TEST_TMPDIR/q.md" --from planner
  assert_equal "$output" ""
  assert_contains "$stderr" "team-post: Discord refused the post: curl: (22) The requested URL returned error: 403; nothing was posted"
  assert_contains "$stderr" "team-ask: the question was not posted, so nothing is logged"
  assert_equal "$(channels)" "2222"
  assert_equal "$(logged)" ""
}

@test "a refused ping logs nothing and names the question's id, posted already" {
  FAIL_POST=2 run_bin -1 --separate-stderr team-ask T7 sign-in --file "$BATS_TEST_TMPDIR/q.md" --from planner
  assert_equal "$output" ""
  assert_contains "$stderr" "team-ask: the question is posted in T7's thread as 1564000000000000001, but the ping in #coordinator was not, so nothing is logged"
  assert_equal "$(logged)" ""
}

@test "Discord's 429 exits 75 and logs nothing" {
  stub_script curl <<'EOF'
while (($#)); do [[ $1 == -D ]] && printf 'HTTP/2 429\r\nretry-after: 3\r\n\r\n' >"$2"; shift; done
exit 22
EOF
  run_bin -75 --separate-stderr team-ask T7 sign-in --file "$BATS_TEST_TMPDIR/q.md"
  assert_contains "$stderr" "team-post: Discord is rate-limiting the bot (429): try again in 3 s; nothing was posted"
  assert_equal "$(logged)" ""
}

@test "a fenced machine posts nothing and logs nothing" {
  mkdir -p "$HOME/.local/state/agent-team"
  echo '{"since": "2026-10-22T14:00:00Z", "holder": "laptop", "epoch": 2}' >"$HOME/.local/state/agent-team/fenced"
  run_bin -1 --separate-stderr team-ask T7 sign-in --file "$BATS_TEST_TMPDIR/q.md" --from planner
  assert_contains "$stderr" "a fenced machine posts nothing to Discord"
  assert_equal "$(stub_calls curl)" ""
  assert_equal "$(logged)" ""
}

@test "a worker session, a planner's included, asks nothing and logs nothing" {
  local role
  for role in planner builder reviewer ops; do
    AGENT_TEAM_ROLE=$role AGENT_TEAM_TASK=T7 run_bin -1 --separate-stderr team-ask T7 sign-in --file "$BATS_TEST_TMPDIR/q.md"
    assert_equal "$stderr" "team-ask: a $role session asks Daniel nothing in Discord: that is the coordinator's; send it your message"
  done
  assert_equal "$(stub_calls curl)" ""
  assert_equal "$(logged)" ""
}

@test "a task with no thread, a closed or unknown task, a blank file or no allowFrom is refused before any post" {
  run_bin -1 team-ask T8 sign-in --file "$BATS_TEST_TMPDIR/q.md"
  assert_equal "$output" "team-ask: T8 has no Discord thread in the ledger; team-thread opens one"
  run_bin -1 team-ask T9 sign-in --file "$BATS_TEST_TMPDIR/q.md"
  assert_equal "$output" "team-ask: T9 is closed"
  run_bin -1 team-ask T10 sign-in --file "$BATS_TEST_TMPDIR/q.md"
  assert_equal "$output" "team-ask: T10 is not open: the ledger has no opened event for it"
  printf ' \n\n' >"$BATS_TEST_TMPDIR/blank.md"
  run_bin -1 team-ask T7 sign-in --file "$BATS_TEST_TMPDIR/blank.md"
  assert_equal "$output" "team-ask: nothing to ask: $BATS_TEST_TMPDIR/blank.md is blank"
  run_bin -1 team-ask T7 sign-in --file "$BATS_TEST_TMPDIR/none.md"
  assert_equal "$output" "team-ask: no file to ask: $BATS_TEST_TMPDIR/none.md"
  local access
  for access in '' '{"allowFrom": []}' '{"allowFrom": "757"}' '{"allowFrom": ["@everyone"]}'; do
    printf '%s' "$access" >"$HOME/.claude/channels/discord/access.json"
    run_bin -1 team-ask T7 sign-in --file "$BATS_TEST_TMPDIR/q.md"
    assert_equal "$output" "team-ask: no Discord user id in allowFrom of ~/.claude/channels/discord/access.json, so the ping cannot name Daniel"
  done
  assert_equal "$(stub_calls curl)" ""
  assert_equal "$(logged)" ""
}

@test "a malformed command line is a usage error, and nothing is posted or logged" {
  local args
  for args in "" "T7" "T7 sign-in" "T7 sign-in --file" "7 sign-in --file q.md" "T7 --file q.md" \
    "T7 'sign in' --file q.md" "T7 -x --file q.md" "T7 sign-in --file q.md --from" \
    "T7 sign-in --file q.md --from Planner" "T7 sign-in more --file q.md" "T7 sign-in --file q.md --to 1111" \
    "T7 sign-in --file q.md --script" "T7 sign-in --file q.md --script ''"; do
    eval "run_bin -2 team-ask $args"
    assert_contains "$output" "usage: team-ask T<n> <id> --file <question> [--from <role>] [--script <path>]"
  done
  assert_equal "$(stub_calls curl)" ""
  assert_equal "$(logged)" ""
}

@test "--help prints the header" {
  run_bin -0 team-ask --help
  assert_equal "${lines[0]}" "$(sed -n '2s/^# //p' "$REPO_ROOT/bin/team-ask")"
  assert_contains "$output" "Usage: team-ask T<n> <id> --file <question> [--from <role>] [--script <path>]"
}
