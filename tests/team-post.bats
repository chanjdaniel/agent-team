#!/usr/bin/env bats
# team-post: posting a file's text to a task's Discord thread or #coordinator through the REST
# API, cut into parts as the Discord plugin cuts, and refused on a fenced machine or one that
# lost the lease.

load helpers/common

setup() {
  sandbox
  cat >"$TEAM_HOME/ledger.jsonl" <<'LEDGER'
{"ts":"2026-10-01T10:00:00Z","task":"T7","event":"thread","discord_thread":"1111"}
{"ts":"2026-10-01T10:00:01Z","task":"T17","event":"thread","discord_thread":"9999"}
{"ts":"2026-10-01T10:00:02Z","task":"T7","event":"thread","discord_thread":"2222"}
LEDGER
  echo "Which of the two sign-in limits stays?" >"$BATS_TEST_TMPDIR/q.md"
  discord_posts
}

# The stub curl answers each post with a new message id (1564000000000000001 for the first, and
# so on), keeping the token it read on stdin in curl.stdin.
discord_posts() {
  stub_script curl <<'EOF'
cat >>"$STUB_CALLS/curl.stdin"
printf '{"id":"%d","channel_id":"1111"}\n' "$((1564000000000000000 + $(wc -l <"$STUB_CALLS/curl.log")))"
EOF
}

# The content of each post, one JSON string per line.
posted() {
  stub_calls curl | jq -c 'index("-d") as $i | .[$i + 1] | fromjson | .content'
}

# The channel each post went to, one per line.
channels() {
  stub_calls curl | jq -r '.[] | select(startswith("https://")) | capture("channels/(?<c>[0-9]+)/messages$").c'
}

# A file holding <text> exactly, no line break added: body <text>
body() {
  printf '%s' "$1" >"$BATS_TEST_TMPDIR/body.md"
}

# <n> copies of the character <c>: run_of <c> <n>
run_of() {
  local s
  printf -v s '%*s' "$2" ''
  printf '%s' "${s// /$1}"
}

@test "a post goes to the task's latest thread, and the message id is printed" {
  run_bin -0 --separate-stderr team-post T7 --file "$BATS_TEST_TMPDIR/q.md"
  assert_equal "$output" "1564000000000000001"
  assert_equal "$stderr" ""
  assert_equal "$(channels)" "2222"
  assert_equal "$(stub_calls curl | jq -r 'index("-d") as $i | .[$i + 1]')" \
    '{"content":"Which of the two sign-in limits stays?","allowed_mentions":{"parse":["users"]}}'
  assert_contains "$(stub_calls curl)" '"-X","POST"'

  run_bin -0 team-post T7 --thread task --file "$BATS_TEST_TMPDIR/q.md"
  assert_equal "$output" "1564000000000000002"
  assert_equal "$(channels | tail -n 1)" "2222"
}

@test "--coordinator posts to #coordinator" {
  run_bin -0 team-post --coordinator --file "$BATS_TEST_TMPDIR/q.md"
  assert_equal "$output" "1564000000000000001"
  assert_equal "$(channels)" "1562486564871995482"
}

@test "a task with no thread is refused, naming it, and nothing is posted" {
  run_bin -1 team-post T8 --file "$BATS_TEST_TMPDIR/q.md"
  assert_equal "$output" "team-post: T8 has no Discord thread in the ledger; team-thread opens one"
  assert_equal "$(stub_calls curl)" ""
}

@test "--thread interview posts to the task's interview thread, never its task thread" {
  run_bin -1 team-post T7 --thread interview --file "$BATS_TEST_TMPDIR/q.md"
  assert_equal "$output" "team-post: T7 has no interview thread in the ledger; team-thread T7 --interview opens one"
  assert_equal "$(stub_calls curl)" ""

  echo '{"ts":"2026-10-01T10:00:03Z","task":"T7","event":"interview-thread","discord_thread":"5555"}' >>"$TEAM_HOME/ledger.jsonl"
  echo '{"ts":"2026-10-01T10:00:04Z","task":"T17","event":"interview-thread","discord_thread":"6666"}' >>"$TEAM_HOME/ledger.jsonl"
  run_bin -0 team-post T7 --thread interview --file "$BATS_TEST_TMPDIR/q.md"
  assert_equal "$output" "1564000000000000001"
  run_bin -0 team-post T7 --file "$BATS_TEST_TMPDIR/q.md"
  assert_equal "$(channels)" "5555
2222"
}

@test "a malformed command line is a usage error, and nothing is posted" {
  local args
  for args in "" "T7" "--file q.md" "7 --file q.md" "T0 --file q.md" "T7 --coordinator --file q.md" \
    "--coordinator --thread task --file q.md" "--coordinator --thread interview --file q.md" \
    "T7 --thread interviews --file q.md" "T7 --file" \
    "T7 T8 --file q.md" "T7 --file q.md --channel 1111"; do
    # shellcheck disable=SC2086 # each case is its words
    run_bin -2 team-post $args
    assert_contains "$output" "usage: team-post"
  done
  assert_equal "$(stub_calls curl)" ""
}

@test "a missing, empty or blank file is refused, and nothing is posted" {
  run_bin -1 team-post T7 --file "$BATS_TEST_TMPDIR/none.md"
  assert_equal "$output" "team-post: no file to post: $BATS_TEST_TMPDIR/none.md"
  body ""
  run_bin -1 team-post T7 --file "$BATS_TEST_TMPDIR/body.md"
  assert_equal "$output" "team-post: nothing to post: $BATS_TEST_TMPDIR/body.md is blank"
  body $'\n  \n\n'
  run_bin -1 team-post T7 --file "$BATS_TEST_TMPDIR/body.md"
  assert_contains "$output" "is blank"
  assert_equal "$(stub_calls curl)" ""
}

@test "trailing blank lines and spaces are dropped; the rest is posted as written" {
  body $'  Two lines,\n\n*kept* as `written` <@123>  \n\n\n'
  run_bin -0 team-post T7 --file "$BATS_TEST_TMPDIR/body.md"
  assert_equal "$(posted)" '"  Two lines,\n\n*kept* as `written` <@123>"'
}

@test "a body over 2000 characters is posted as several messages cut at paragraph breaks, in order" {
  body "$(run_of a 1500)"$'\n\n'"$(run_of b 1500)"$'\n\n'"$(run_of c 1500)"$'\n'
  run_bin -0 team-post T7 --file "$BATS_TEST_TMPDIR/body.md"
  assert_equal "$output" $'1564000000000000001\n1564000000000000002\n1564000000000000003'
  assert_equal "$(posted | jq -r .)" "$(run_of a 1500)"$'\n'"$(run_of b 1500)"$'\n'"$(run_of c 1500)"
}

@test "a part is cut at a paragraph break past half the limit, else a line break, else a space, else at 2000" {
  # A paragraph break before 1000 is passed over for the last line break.
  body "$(run_of x 400)"$'\n\n'"$(run_of y 900)"$'\n'"$(run_of z 900)"$'\n'"$(run_of w 900)"
  run_bin -0 team-post T7 --file "$BATS_TEST_TMPDIR/body.md"
  assert_equal "$(posted | jq -c 'length')" $'1302\n1801'
  assert_equal "$(posted | jq -r 'split("\n") | map(.[0:1]) | join("")' | paste -sd ' ')" "xy zw"

  # No line break: the last space, which starts the next part, as the plugin leaves it.
  : >"$STUB_CALLS/curl.log"
  body "$(run_of a 1500) $(run_of b 1000)"
  run_bin -0 team-post T7 --file "$BATS_TEST_TMPDIR/body.md"
  assert_equal "$(posted)" "\"$(run_of a 1500)\""$'\n'"\" $(run_of b 1000)\""

  # Nothing to cut at: 2000 characters a part, counted in characters, not bytes.
  : >"$STUB_CALLS/curl.log"
  body "$(run_of é 4500)"
  run_bin -0 team-post T7 --file "$BATS_TEST_TMPDIR/body.md"
  assert_equal "$(posted | jq -c 'length')" $'2000\n2000\n500'
  assert_equal "$(posted | jq -j .)" "$(run_of é 4500)"
}

@test "a fenced machine posts nothing" {
  mkdir -p "$HOME/.local/state/agent-team"
  echo '{"since": "2026-10-22T14:00:00Z", "holder": "laptop", "epoch": 2}' >"$HOME/.local/state/agent-team/fenced"
  run_bin -1 team-post T7 --file "$BATS_TEST_TMPDIR/q.md"
  assert_equal "$output" "team-post: this machine is fenced since 2026-10-22T14:00:00Z (holder seen laptop, epoch 2): a fenced machine posts nothing to Discord; the coordinator on the holder answers there."
  run_bin -1 team-post --coordinator --file "$BATS_TEST_TMPDIR/q.md"
  assert_equal "$(stub_calls curl)" ""
}

@test "a machine whose lease on origin names another holder posts nothing; the holder posts" {
  hold_lease home-pc >/dev/null
  run_bin -0 team-post T7 --file "$BATS_TEST_TMPDIR/q.md"
  assert_equal "$(stub_calls curl | wc -l)" "1"

  make_machine laptop
  steal_lease laptop home-pc
  rm "$HOME/.local/state/agent-team/probe.json"
  run_bin -1 team-post T7 --file "$BATS_TEST_TMPDIR/q.md"
  assert_equal "$output" "team-post: home-pc no longer holds the lease: origin names laptop (held, epoch 2): a machine that lost the lease posts nothing to Discord; the coordinator on the holder answers there."
  assert_equal "$(stub_calls curl | wc -l)" "1"

  on_machine laptop run_bin -0 team-post --coordinator --file "$BATS_TEST_TMPDIR/q.md"
  assert_equal "$(stub_calls curl | wc -l)" "2"
}

@test "a 429 exits 75 with the retry time from Discord's headers" {
  stub_script curl <<'EOF'
dump=$(jq -r 'index("-D") as $i | .[$i + 1]' <<<"$(jq -cn '$ARGS.positional' --args -- "$@")")
printf 'HTTP/2 429\r\ncontent-type: application/json\r\nretry-after: 3\r\nx-ratelimit-reset-after: 2.5\r\n\r\n' >"$dump"
echo "curl: (22) The requested URL returned error: 429" >&2
exit 22
EOF
  run_bin -75 --separate-stderr team-post T7 --file "$BATS_TEST_TMPDIR/q.md"
  assert_equal "$output" ""
  assert_equal "$stderr" "team-post: Discord is rate-limiting the bot (429): try again in 3 s; nothing was posted"

  # Without a retry time in the headers.
  sed -i 's/retry-after: 3\\r\\nx-ratelimit-reset-after: 2.5\\r\\n//' "$STUB_FIXTURES/curl.sh"
  run_bin -75 --separate-stderr team-post T7 --file "$BATS_TEST_TMPDIR/q.md"
  assert_equal "$stderr" "team-post: Discord is rate-limiting the bot (429): try again later; nothing was posted"
}

@test "a 429 on a later part names the parts already posted, whose ids were printed" {
  stub_script curl <<'EOF'
if (($(wc -l <"$STUB_CALLS/curl.log") == 1)); then
  echo '{"id":"1564000000000000001"}'
  exit 0
fi
dump=$(jq -r 'index("-D") as $i | .[$i + 1]' <<<"$(jq -cn '$ARGS.positional' --args -- "$@")")
printf 'HTTP/2 429\r\nx-ratelimit-reset-after: 1.25\r\n\r\n' >"$dump"
exit 22
EOF
  body "$(run_of a 1500)"$'\n\n'"$(run_of b 1500)"
  run_bin -75 --separate-stderr team-post T7 --file "$BATS_TEST_TMPDIR/body.md"
  assert_equal "$output" "1564000000000000001"
  assert_equal "$stderr" "team-post: Discord is rate-limiting the bot (429): try again in 1.25 s; 1 of 2 parts was posted, its id above"
}

@test "any other failure exits 1 with curl's reason, and no output ever holds the token" {
  stub_script curl <<'EOF'
cat >"$STUB_CALLS/curl.stdin"
dump=$(jq -r 'index("-D") as $i | .[$i + 1]' <<<"$(jq -cn '$ARGS.positional' --args -- "$@")")
printf 'HTTP/2 403\r\n\r\n' >"$dump"
echo "curl: (22) The requested URL returned error: 403" >&2
exit 22
EOF
  run_bin -1 team-post T7 --file "$BATS_TEST_TMPDIR/q.md"
  assert_equal "$output" "team-post: Discord refused the post: curl: (22) The requested URL returned error: 403; nothing was posted"
  [[ $output != *"$FAKE_DISCORD_TOKEN"* ]]

  # A reply with no message id is a failure too.
  rm "$STUB_FIXTURES/curl.sh"
  stub_reply curl '{"message":"Missing Access","code":50001}'
  run_bin -1 team-post T7 --file "$BATS_TEST_TMPDIR/q.md"
  assert_equal "$output" "team-post: Discord refused the post: no message id in its answer; nothing was posted"

  # The token reaches curl on stdin alone.
  discord_posts
  run_bin -0 team-post T7 --file "$BATS_TEST_TMPDIR/q.md"
  [[ $output != *"$FAKE_DISCORD_TOKEN"* ]]
  [[ $(stub_calls curl) != *"$FAKE_DISCORD_TOKEN"* ]]
  assert_equal "$(stub_calls curl | tail -n 1 | jq -r '.[1:3] | join(" ")')" "-H @-"
  assert_equal "$(tail -n 1 "$STUB_CALLS/curl.stdin")" "Authorization: Bot $FAKE_DISCORD_TOKEN"
}

@test "a missing token is refused, and nothing is posted" {
  : >"$HOME/.claude/channels/discord/.env"
  run_bin -1 team-post T7 --file "$BATS_TEST_TMPDIR/q.md"
  assert_equal "$output" "team-post: no DISCORD_BOT_TOKEN in ~/.claude/channels/discord/.env"
  assert_equal "$(stub_calls curl)" ""
}

@test "--help prints the header" {
  run_bin -0 team-post --help
  assert_contains "$output" "Usage: team-post T<n> [--thread task|interview] --file <path>"
}
