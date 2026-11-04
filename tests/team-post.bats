#!/usr/bin/env bats
# team-post: posting a file's text, and in an interview its images, to a task's Discord thread or
# #coordinator through the REST API, cut into parts as the Discord plugin cuts, and refused on a
# fenced machine or one that lost the lease.

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

# T7's interview thread, worktree and task directory, IMAGES, with a question in it; T17's thread
# and worktree, whose task directory is OTHER_IMAGES.
interview_task() {
  IMAGES=$BATS_TEST_TMPDIR/wt/.scratch/task OTHER_IMAGES=$BATS_TEST_TMPDIR/wt17/.scratch/task
  mkdir -p "$IMAGES" "$OTHER_IMAGES"
  cat >"$TEAM_HOME/projects.toml" <<'TOML'
[shop]
repo = "owner/shop"
path = "projects/shop"
base = "main"
delivery = "direct-pr"
merge_method = "merge"
required_checks = []
task_dir = ".scratch/task"
docs = []
toolkits = []

[shop.pool]
provider = "treehouse"
lease = "scripts/th-lease.sh"
return = "scripts/th-return.sh"
slots = ["wt"]
TOML
  cat >>"$TEAM_HOME/ledger.jsonl" <<LEDGER
{"ts":"2026-10-01T10:00:00Z","task":"T7","event":"opened","project":"shop","branch":"feat/x","base":"main","base_sha":"abc1234","worktree":"$BATS_TEST_TMPDIR/wt"}
{"ts":"2026-10-01T10:00:00Z","task":"T17","event":"opened","project":"shop","branch":"feat/y","base":"main","base_sha":"abc1234","worktree":"$BATS_TEST_TMPDIR/wt17"}
{"ts":"2026-10-01T10:00:03Z","task":"T7","event":"interview-thread","discord_thread":"5555"}
{"ts":"2026-10-01T10:00:04Z","task":"T17","event":"interview-thread","discord_thread":"6666"}
LEDGER
  echo "Tile 1 is the bar as it is, tile 2 the new one." >"$IMAGES/q.md"
}

# A PNG at <path>, of <size> bytes when given (a sparse file, which the stub curl never reads):
# png <path> [<size>]
png() {
  printf '\x89PNG\r\n\x1a\n\0\0\0\rIHDR' >"$1"
  [[ -z ${2:-} ]] || truncate -s "$2" "$1"
}

# Each post's multipart parts, one JSON array per line: payload_json's and each file's -F value.
forms() {
  stub_calls curl | jq -c '. as $args
    | [to_entries[] | select(.value == "--form-string" or .value == "-F") | $args[.key + 1]]'
}

# How many files each post holds, one number per line.
file_counts() {
  stub_calls curl | jq -c '[.[] | select(startswith("files["))] | length'
}

# Each post's text, one JSON string or null per line, whichever way it went.
post_texts() {
  stub_calls curl | jq -c '. as $args | first(to_entries[] | select(.value == "-d" or .value == "--form-string"))
    | $args[.key + 1] | ltrimstr("payload_json=") | fromjson | .content'
}

# The planner of T7 runs team-post: as_planner <run_bin's arguments>
as_planner() {
  AGENT_TEAM_ROLE=planner AGENT_TEAM_TASK=T7 run_bin "$@"
}

# The ledger's lines of <kind>, with no ts, one per line: logged <kind>
logged() {
  jq -c --arg kind "$1" 'select(.event == $kind) | del(.ts)' "$TEAM_HOME/ledger.jsonl"
}

# A ledger line for an image message <id> of <task> in <thread>: image_line <task> <thread> <id>
image_line() {
  jq -cn --arg task "$1" --arg thread "$2" --arg id "$3" \
    '{ts: "2026-10-01T10:00:05Z", task: $task, event: "image-posted", thread: "interview", discord_thread: $thread, discord_message: $id, file: "one.png"}' \
    >>"$TEAM_HOME/ledger.jsonl"
}

# The stand-in for Discord: the stub runs the real curl, sending the real request to a server on
# the loopback, which keeps its body in <file>, so a test reads what would reach Discord. The
# server takes one request, and stops within 30 s if none comes: real_discord <file>
real_discord() {
  local real port=$BATS_TEST_TMPDIR/port
  real=$(type -ap curl | grep -vF "$BATS_TEST_TMPDIR/stubs/" | head -n 1)
  python3 -I - "$1" "$port" 3>&- <<'PY' &
import http.server, os, sys
class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        with open(sys.argv[1], "wb") as out:
            out.write(self.rfile.read(int(self.headers["Content-Length"])))
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"id":"1564000000000000001"}')
    def log_message(self, *args):
        pass
server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
server.timeout = 30
with open(sys.argv[2] + ".new", "w") as out:
    out.write(str(server.server_address[1]))
os.rename(sys.argv[2] + ".new", sys.argv[2])
server.handle_request()
PY
  until [[ -s $port ]]; do sleep 0.05; done
  stub_script curl <<EOF
exec "$real" "\${@:1:\$#-1}" "http://127.0.0.1:$(<"$port")/"
EOF
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

@test "a worker session posts only a planner's question to its own task's interview thread" {
  interview_task
  AGENT_TEAM_ROLE=planner AGENT_TEAM_TASK=T7 run_bin -0 team-post T7 --thread interview --file "$IMAGES/q.md"
  assert_equal "$(channels)" "5555"

  AGENT_TEAM_ROLE=planner AGENT_TEAM_TASK=T7 run_bin -1 team-post T17 --thread interview --file "$IMAGES/q.md"
  assert_equal "$output" "team-post: a planner session of T7 posts to Discord for T17: a planner talks with Daniel only in its own task's interview thread"
  local role args
  for args in "T7 --file q.md" "T7 --thread task --file q.md" "--coordinator --file q.md"; do
    eval "AGENT_TEAM_ROLE=planner AGENT_TEAM_TASK=T7 run_bin -1 team-post ${args/q.md/$IMAGES/q.md}"
    assert_equal "$output" "team-post: a planner session posts to Discord: that is the coordinator's; send it your message"
  done
  for role in builder reviewer ops; do
    AGENT_TEAM_ROLE=$role AGENT_TEAM_TASK=T7 run_bin -1 team-post T7 --thread interview --file "$IMAGES/q.md"
    assert_equal "$output" "team-post: a $role session posts to Discord: that is the coordinator's; send it your message"
  done
  assert_equal "$(channels)" "5555"

  # The coordinator posts anywhere, as Daniel's own shell does.
  AGENT_TEAM_ROLE=coordinator run_bin -0 team-post --coordinator --file "$IMAGES/q.md"
  AGENT_TEAM_ROLE=coordinator run_bin -0 team-post T17 --thread interview --file "$IMAGES/q.md"
  assert_equal "$(channels)" "5555
1562486564871995482
6666"
}

@test "a malformed command line is a usage error, and nothing is posted" {
  local args
  for args in "" "T7" "--file q.md" "7 --file q.md" "T0 --file q.md" "T7 --coordinator --file q.md" \
    "--coordinator --thread task --file q.md" "--coordinator --thread interview --file q.md" \
    "T7 --thread interviews --file q.md" "T7 --file" \
    "T7 T8 --file q.md" "T7 --file q.md --channel 1111" \
    "T7 --file q.md --attach s.png" "T7 --thread task --file q.md --attach s.png" \
    "--coordinator --file q.md --attach s.png" "T7 --thread interview --attach s.png" \
    "T7 --thread interview --file q.md --attach" "T7 --retract 1" "T7 --thread task --retract 1" \
    "--coordinator --retract 1" "T7 --thread interview --retract" "T7 --thread interview --retract x" \
    "T7 --thread interview --retract 1 --file q.md" "T7 --thread interview --retract 1 --attach s.png"; do
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

@test "--attach sends the text and each image as multipart with payload_json and files[n]" {
  interview_task
  png "$IMAGES/one.png"
  png "$IMAGES/two.png"
  run_bin -0 --separate-stderr team-post T7 --thread interview --file "$IMAGES/q.md" --attach "$IMAGES/one.png" --attach "$IMAGES/two.png"
  assert_equal "$output" "1564000000000000001"
  assert_equal "$(channels)" "5555"
  assert_equal "$(forms)" "$(jq -cn --arg d "$IMAGES" '[
    "payload_json={\"content\":\"Tile 1 is the bar as it is, tile 2 the new one.\",\"allowed_mentions\":{\"parse\":[\"users\"]}}",
    "files[0]=@\"\($d)/one.png\";filename=\"one.png\";type=image/png",
    "files[1]=@\"\($d)/two.png\";filename=\"two.png\";type=image/png"]')"
  # curl sets multipart's own Content-Type, and -d would turn the post into JSON.
  [[ $(stub_calls curl) != *'"Content-Type: application/json"'* ]]
  [[ $(stub_calls curl) != *'"-d"'* ]]
  # An upload has longer than a text post has.
  assert_equal "$(stub_calls curl | jq -r 'index("--max-time") as $i | .[$i + 1]')" 120
}

@test "a text-only post is the same request as ever, with no multipart and no ledger line" {
  run_bin -0 team-post T7 --file "$BATS_TEST_TMPDIR/q.md"
  assert_equal "$(stub_calls curl | jq -c 'index("-D") as $i | del(.[$i + 1])')" \
    '["-fsS","-H","@-","-X","POST","-H","Content-Type: application/json","--max-time","20","-D","-d","{\"content\":\"Which of the two sign-in limits stays?\",\"allowed_mentions\":{\"parse\":[\"users\"]}}","https://discord.com/api/v10/channels/2222/messages"]'
  assert_equal "$(logged image-posted)" ""
}

@test "only the file's base name reaches Discord, whatever the path or the name holds" {
  interview_task
  local sent=$BATS_TEST_TMPDIR/sent dir="$IMAGES/a;b,c"
  mkdir -p "$dir"
  png "$dir/ti;le,1.png"
  real_discord "$sent"
  run_bin -0 team-post T7 --thread interview --file "$IMAGES/q.md" --attach "$dir/ti;le,1.png"
  assert_equal "$output" "1564000000000000001"
  wait
  grep -aqF 'name="payload_json"' "$sent"
  grep -aqF '{"content":"Tile 1 is the bar as it is, tile 2 the new one.","allowed_mentions":{"parse":["users"]}}' "$sent"
  grep -aqF 'name="files[0]"; filename="ti;le,1.png"' "$sent"
  grep -aqF 'Content-Type: image/png' "$sent"
  grep -aqF 'IHDR' "$sent"
  if grep -aqF "$BATS_TEST_TMPDIR" "$sent"; then
    echo "the path reached Discord" >&2
    return 1
  fi
}

@test "a message holds at most 10 files: more go on the text's next parts, then on messages of their own" {
  interview_task
  local i files=()
  for i in {1..23}; do
    png "$IMAGES/$i.png"
    files+=(--attach "$IMAGES/$i.png")
  done
  run_bin -0 team-post T7 --thread interview --file "$IMAGES/q.md" "${files[@]}"
  assert_equal "$output" $'1564000000000000001\n1564000000000000002\n1564000000000000003'
  assert_equal "$(file_counts)" $'10\n10\n3'
  assert_equal "$(post_texts)" $'"Tile 1 is the bar as it is, tile 2 the new one."\nnull\nnull'
  # In order, and each message's files number from 0.
  assert_equal "$(forms | jq -r '.[1] | sub(";.*"; "") | sub("=@.*/"; " ")')" $'files[0] 1.png"\nfiles[0] 11.png"\nfiles[0] 21.png"'

  # A long text keeps its parts, the images on the first ones.
  : >"$STUB_CALLS/curl.log"
  body "$(run_of a 1500)"$'\n\n'"$(run_of b 1500)"$'\n\n'"$(run_of c 1500)"
  mv "$BATS_TEST_TMPDIR/body.md" "$IMAGES/body.md"
  run_bin -0 team-post T7 --thread interview --file "$IMAGES/body.md" "${files[@]:0:24}"
  assert_equal "$(file_counts)" $'10\n2\n0'
  assert_equal "$(post_texts | jq -r '.[0:1]' | paste -sd ' ')" "a b c"
}

@test "a message holds at most 25 MiB in all with its text, and a file over 20 MiB is refused before anything is sent" {
  interview_task
  png "$IMAGES/twenty.png" 20M
  png "$IMAGES/five.png" 5M
  png "$IMAGES/four.png" 4M
  png "$IMAGES/over.png" $((20 * 1024 * 1024 + 1))
  # 20 and 5 MiB fill the request with no room for its text, so they go apart.
  run_bin -0 team-post T7 --thread interview --file "$IMAGES/q.md" --attach "$IMAGES/twenty.png" --attach "$IMAGES/five.png"
  assert_equal "$(file_counts)" $'1\n1'
  : >"$STUB_CALLS/curl.log"
  run_bin -0 team-post T7 --thread interview --file "$IMAGES/q.md" --attach "$IMAGES/twenty.png" --attach "$IMAGES/four.png"
  assert_equal "$(file_counts)" "2"
  : >"$STUB_CALLS/curl.log"

  local role
  for role in planner coordinator; do
    AGENT_TEAM_ROLE=$role AGENT_TEAM_TASK=T7 run_bin -1 team-post T7 --thread interview --file "$IMAGES/q.md" --attach "$IMAGES/four.png" --attach "$IMAGES/over.png"
    assert_equal "$output" "team-post: cannot attach $IMAGES/over.png: 20971521 bytes is over Discord's 20971520 on one file"
  done
  assert_equal "$(stub_calls curl)" ""
}

@test "a worker's attachment must be its task's own image, no link; each refusal names the path and sends nothing" {
  interview_task
  local ui=$TEAM_HOME/tasks/T7/ui outside=$BATS_TEST_TMPDIR/outside q=$IMAGES/q.md
  mkdir -p "$ui/capture-1" "$outside" "$TEAM_HOME/tasks/T17/ui"
  png "$outside/real.png"
  png "$OTHER_IMAGES/theirs.png"
  png "$TEAM_HOME/tasks/T17/ui/theirs.png"
  png "$TEAM_HOME/tasks/T7/beside-ui.png"
  png "$BATS_TEST_TMPDIR/wt/beside-task.png"
  png "$ui/capture-1/page.png"
  png "$IMAGES/fine.png"
  ln -s "$outside/real.png" "$IMAGES/link.png"
  ln -s "$IMAGES/fine.png" "$IMAGES/inner-link.png"
  ln -s "$outside" "$IMAGES/linked-dir"
  # A hard link has its real path here, whatever else names the same file.
  png "$ui/capture-1/element.png"
  ln "$ui/capture-1/element.png" "$IMAGES/hard-link.png"
  # The top of ui/ holds what no one can vouch for: a flat capture an older team-ui left, a file
  # team-ui --attach copied from another channel, and Daniel's own images.
  png "$ui/flat-page.png"
  echo "just text" >"$IMAGES/text.png"
  : >"$IMAGES/empty.png"
  printf 'BM\0\0\0\0\0\0\0\0\0\0\0\0' >"$IMAGES/bitmap.png"
  printf '\x89PNG not quite' >"$IMAGES/almost.png"
  printf 'RIFF\0\0\0\0WAVEfmt ' >"$IMAGES/sound.png"

  local from="a worker session attaches only from T7's task directory"
  local bytes="not a PNG, JPEG, WebP or GIF by its first bytes"
  local refused=(
    "$ui/flat-page.png|$from" "$IMAGES/hard-link.png|it is a link"
    "$outside/real.png|$from" "$OTHER_IMAGES/theirs.png|$from"
    "$TEAM_HOME/tasks/T17/ui/theirs.png|$from" "$TEAM_HOME/tasks/T7/beside-ui.png|$from"
    "$BATS_TEST_TMPDIR/wt/beside-task.png|$from" "$IMAGES/../../beside-task.png|$from"
    "$IMAGES/linked-dir/real.png|$from"
    "$IMAGES/link.png|it is a link" "$IMAGES/inner-link.png|it is a link"
    "$IMAGES/text.png|$bytes" "$IMAGES/empty.png|$bytes" "$IMAGES/bitmap.png|$bytes"
    "$IMAGES/almost.png|$bytes" "$IMAGES/sound.png|$bytes"
    "$ui/capture-1/page.png|it is in a capture of the page Daniel is on, and nothing proves that page held no real data"
  )
  local case
  for case in "${refused[@]}"; do
    as_planner -1 team-post T7 --thread interview --file "$q" --attach "$IMAGES/fine.png" --attach "${case%%|*}"
    assert_equal "$output" "team-post: cannot attach ${case%%|*}: ${case#*|}"
  done
  as_planner -1 team-post T7 --thread interview --file "$q" --attach "$IMAGES/none.png"
  assert_equal "$output" "team-post: no image to attach: $IMAGES/none.png"
  assert_equal "$(stub_calls curl)" ""
  assert_equal "$(logged image-posted)" ""
}

@test "a worker may attach a PNG, JPEG, WebP or GIF from its task directory, each sent as its type" {
  interview_task
  mkdir -p "$IMAGES/shots"
  png "$IMAGES/shots/a.png"
  printf '\xff\xd8\xff\xe0\0\x10JFIF' >"$IMAGES/shots/b.jpg"
  printf 'RIFF\x24\0\0\0WEBPVP8 ' >"$IMAGES/shots/c.webp"
  printf 'GIF87a\x01\0\x01\0' >"$IMAGES/shots/d.gif"
  printf 'GIF89a\x01\0\x01\0' >"$IMAGES/shots/e.gif"
  as_planner -0 team-post T7 --thread interview --file "$IMAGES/q.md" --attach "$IMAGES/shots/a.png" \
    --attach "$IMAGES/shots/b.jpg" --attach "$IMAGES/shots/c.webp" --attach "$IMAGES/shots/d.gif" \
    --attach "$IMAGES/shots/e.gif"
  assert_equal "$(forms | jq -r '.[1:][] | sub(".*filename="; "")')" '"a.png";type=image/png
"b.jpg";type=image/jpeg
"c.webp";type=image/webp
"d.gif";type=image/gif
"e.gif";type=image/gif'

  # The type is the first bytes', whatever the name says.
  : >"$STUB_CALLS/curl.log"
  mv "$IMAGES/shots/b.jpg" "$IMAGES/shots/b.png"
  as_planner -0 team-post T7 --thread interview --file "$IMAGES/q.md" --attach "$IMAGES/shots/b.png"
  assert_equal "$(forms | jq -r '.[1] | sub(".*filename="; "")')" '"b.png";type=image/jpeg'
}

@test "the coordinator's attachment needs no worker's path or bytes, but a name that could break the form or an empty file is refused" {
  interview_task
  echo "a text file" >"$BATS_TEST_TMPDIR/notes.txt"
  AGENT_TEAM_ROLE=coordinator run_bin -0 team-post T7 --thread interview --file "$BATS_TEST_TMPDIR/q.md" --attach "$BATS_TEST_TMPDIR/notes.txt"
  assert_equal "$(forms | jq -r '.[1] | sub(".*filename="; "")')" '"notes.txt"'

  : >"$STUB_CALLS/curl.log"
  local bad=$BATS_TEST_TMPDIR/$'two\nlines.png'
  png "$bad"
  : >"$BATS_TEST_TMPDIR/empty.png"
  run_bin -1 team-post T7 --thread interview --file "$BATS_TEST_TMPDIR/q.md" --attach "$bad"
  assert_equal "$output" "team-post: cannot attach $bad: its name holds a control character"
  run_bin -1 team-post T7 --thread interview --file "$BATS_TEST_TMPDIR/q.md" --attach "$BATS_TEST_TMPDIR/empty.png"
  assert_equal "$output" "team-post: cannot attach $BATS_TEST_TMPDIR/empty.png: it is empty"
  assert_equal "$(stub_calls curl)" ""
}

@test "a worker's --file must be inside its own task directory, by its real path; another session's need not" {
  interview_task
  local outside=$BATS_TEST_TMPDIR/q.md refusal="a worker session posts only a file in T7's task directory"
  ln -s "$outside" "$IMAGES/link.md"
  ln -s "$IMAGES/q.md" "$IMAGES/inner.md"
  echo "the other task's" >"$OTHER_IMAGES/q.md"
  echo "the worktree's" >"$BATS_TEST_TMPDIR/wt/q.md"
  local path
  for path in "$outside" "$IMAGES/link.md" "$OTHER_IMAGES/q.md" "$BATS_TEST_TMPDIR/wt/q.md" "$IMAGES/../../q.md"; do
    as_planner -1 team-post T7 --thread interview --file "$path"
    assert_equal "$output" "team-post: cannot post $path: $refusal"
  done
  assert_equal "$(stub_calls curl)" ""

  as_planner -0 team-post T7 --thread interview --file "$IMAGES/inner.md"
  assert_equal "$(post_texts)" '"Tile 1 is the bar as it is, tile 2 the new one."'

  # A worktree the task returned is no longer its own.
  echo "{\"ts\":\"2026-10-02T10:00:00Z\",\"task\":\"T7\",\"event\":\"worktree-returned\",\"project\":\"shop\",\"worktree\":\"$BATS_TEST_TMPDIR/wt\"}" >>"$TEAM_HOME/ledger.jsonl"
  as_planner -1 team-post T7 --thread interview --file "$IMAGES/q.md"
  assert_equal "$output" "team-post: cannot post $IMAGES/q.md: $refusal"

  AGENT_TEAM_ROLE=coordinator run_bin -0 team-post T7 --thread interview --file "$outside"
  run_bin -0 team-post T7 --thread interview --file "$outside"
}

@test "each image posted is one ledger line, with its thread, message and name, under the contract" {
  interview_task
  local i files=()
  for i in {1..11}; do
    png "$IMAGES/$i.png"
    files+=(--attach "$IMAGES/$i.png")
  done
  as_planner -0 team-post T7 --thread interview --file "$IMAGES/q.md" "${files[@]}"
  assert_equal "$(logged image-posted | jq -c 'select(.file == "1.png" or .file == "11.png")')" \
    '{"task":"T7","event":"image-posted","thread":"interview","discord_thread":"5555","discord_message":"1564000000000000001","file":"1.png"}
{"task":"T7","event":"image-posted","thread":"interview","discord_thread":"5555","discord_message":"1564000000000000002","file":"11.png"}'
  assert_equal "$(logged image-posted | wc -l)" 11
  assert_equal "$(jq -r 'select(.event == "image-posted") | .ts' "$TEAM_HOME/ledger.jsonl" | grep -cE '^[0-9-]+T[0-9:]+Z$')" 11
  run_bin -0 team-log --check

  # A post with no image logs nothing.
  as_planner -0 team-post T7 --thread interview --file "$IMAGES/q.md"
  assert_equal "$(logged image-posted | wc -l)" 11
}

@test "a failed message logs only what was sent, says so, and sends nothing after it" {
  interview_task
  local i files=()
  for i in {1..21}; do
    png "$IMAGES/$i.png"
    files+=(--attach "$IMAGES/$i.png")
  done
  stub_script curl <<'EOF'
if (($(wc -l <"$STUB_CALLS/curl.log") == 1)); then
  echo '{"id":"1564000000000000001"}'
  exit 0
fi
echo "curl: (22) The requested URL returned error: 413" >&2
exit 22
EOF
  as_planner -1 --separate-stderr team-post T7 --thread interview --file "$IMAGES/q.md" "${files[@]}"
  assert_equal "$output" "1564000000000000001"
  assert_equal "$stderr" "team-post: Discord refused the post: curl: (22) The requested URL returned error: 413; 1 of 3 parts was posted, its id above"
  assert_equal "$(stub_calls curl | wc -l)" 2
  assert_equal "$(logged image-posted | jq -r .discord_message | sort -u)" 1564000000000000001
  assert_equal "$(logged image-posted | wc -l)" 10
}

@test "--retract deletes a post the ledger records for the task as carrying images, once, and logs it" {
  interview_task
  png "$IMAGES/one.png"
  as_planner -0 team-post T7 --thread interview --file "$IMAGES/q.md" --attach "$IMAGES/one.png"
  : >"$STUB_CALLS/curl.log"

  as_planner -0 team-post T7 --thread interview --retract 1564000000000000001
  assert_equal "$output" "retracted 1564000000000000001"
  assert_equal "$(stub_calls curl | jq -c '[.[3:5], .[-1]]')" \
    '[["-X","DELETE"],"https://discord.com/api/v10/channels/5555/messages/1564000000000000001"]'
  assert_equal "$(logged image-retracted)" \
    '{"task":"T7","event":"image-retracted","thread":"interview","discord_thread":"5555","discord_message":"1564000000000000001"}'
  # The record of what left stays.
  assert_equal "$(logged image-posted | wc -l)" 1
  run_bin -0 team-log --check

  : >"$STUB_CALLS/curl.log"
  as_planner -1 team-post T7 --thread interview --retract 1564000000000000001
  assert_equal "$output" "team-post: message 1564000000000000001 of T7 is already retracted"
  assert_equal "$(stub_calls curl)" ""
}

@test "--retract goes to the thread that holds the post, not the task's latest" {
  interview_task
  image_line T7 4444 900
  run_bin -0 team-post T7 --thread interview --retract 900
  assert_equal "$(stub_calls curl | jq -r '.[-1]')" "https://discord.com/api/v10/channels/4444/messages/900"
}

@test "--retract refuses any other id: a text post, another task's image, an unknown one, and another session's" {
  interview_task
  image_line T17 6666 900
  as_planner -0 team-post T7 --thread interview --file "$IMAGES/q.md"
  local text_post=$output id
  : >"$STUB_CALLS/curl.log"
  for id in "$text_post" 900 123; do
    as_planner -1 team-post T7 --thread interview --retract "$id"
    assert_equal "$output" "team-post: the ledger records no image post $id for T7, so nothing was retracted"
    AGENT_TEAM_ROLE=coordinator run_bin -1 team-post T7 --thread interview --retract "$id"
    assert_equal "$output" "team-post: the ledger records no image post $id for T7, so nothing was retracted"
  done
  as_planner -1 team-post T17 --thread interview --retract 900
  assert_equal "$output" "team-post: a planner session of T7 posts to Discord for T17: a planner talks with Daniel only in its own task's interview thread"
  AGENT_TEAM_ROLE=builder AGENT_TEAM_TASK=T17 run_bin -1 team-post T17 --thread interview --retract 900
  assert_equal "$output" "team-post: a builder session posts to Discord: that is the coordinator's; send it your message"
  assert_equal "$(stub_calls curl)" ""
  assert_equal "$(logged image-retracted)" ""
}

@test "a refused or rate-limited --retract logs nothing and can be run again" {
  interview_task
  image_line T7 5555 900
  stub_script curl <<'EOF'
dump=$(jq -r 'index("-D") as $i | .[$i + 1]' <<<"$(jq -cn '$ARGS.positional' --args -- "$@")")
printf 'HTTP/2 429\r\nretry-after: 3\r\n\r\n' >"$dump"
exit 22
EOF
  run_bin -75 --separate-stderr team-post T7 --thread interview --retract 900
  assert_equal "$stderr" "team-post: Discord is rate-limiting the bot (429): try again in 3 s; nothing was retracted"
  assert_equal "$(logged image-retracted)" ""

  stub_script curl <<'EOF'
dump=$(jq -r 'index("-D") as $i | .[$i + 1]' <<<"$(jq -cn '$ARGS.positional' --args -- "$@")")
printf 'HTTP/2 403\r\n\r\n' >"$dump"
echo "curl: (22) The requested URL returned error: 403" >&2
exit 22
EOF
  run_bin -1 team-post T7 --thread interview --retract 900
  assert_equal "$output" "team-post: Discord refused the retract: curl: (22) The requested URL returned error: 403; nothing was retracted"
  assert_equal "$(logged image-retracted)" ""

  discord_posts
  run_bin -0 team-post T7 --thread interview --retract 900
  assert_equal "$output" "retracted 900"
}

@test "a fenced machine attaches and retracts nothing" {
  interview_task
  png "$IMAGES/one.png"
  image_line T7 5555 900
  mkdir -p "$HOME/.local/state/agent-team"
  echo '{"since": "2026-10-22T14:00:00Z", "holder": "laptop", "epoch": 2}' >"$HOME/.local/state/agent-team/fenced"
  local refusal="team-post: this machine is fenced since 2026-10-22T14:00:00Z (holder seen laptop, epoch 2): a fenced machine posts nothing to Discord; the coordinator on the holder answers there."
  as_planner -1 team-post T7 --thread interview --file "$IMAGES/q.md" --attach "$IMAGES/one.png"
  assert_equal "$output" "$refusal"
  as_planner -1 team-post T7 --thread interview --retract 900
  assert_equal "$output" "$refusal"
  assert_equal "$(stub_calls curl)" ""
  assert_equal "$(logged image-retracted)" ""
}

@test "--help prints the header" {
  run_bin -0 team-post --help
  assert_contains "$output" "Usage: team-post T<n> [--thread task|interview] --file <path>"
}

