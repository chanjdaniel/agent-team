#!/usr/bin/env bats
# team-post --attach of a walk's capture: an image of tasks/T<n>/ui/capture-<k>/ leaves in a
# planner's post only from a page proved clear of real data, its port one of the task's own stack,
# as the real team-stack env gives it on the stub docker, or the walk's start naming Daniel's word
# that the primary stack on that port was just reseeded, which the real team-ui reads from the stub
# Discord. The
# capture's text and the post's text are scanned for a real email address, with bin/lib/data-check's
# own rule. Every address at a real provider here is built from a variable, as CLAUDE.md's data rule
# says.

load helpers/common
load helpers/docker
load helpers/inbox

setup() {
  sandbox
  cp "$BATS_TEST_DIRNAME/fixtures/projects.toml" "$TEAM_HOME/projects.toml"
  stack_project shop
  docker_stub "$STACK_WORKTREE"
  capacity_room $((16 * 1073741824))
  task_events T22 "$STACK_WORKTREE" 5555
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --no-seed
  OWN_PORT=$(jq -r '.[] | select(.Name == "/stackfix-shop-1-web-1") | .NetworkSettings.Ports["80/tcp"][0].HostPort' "$DOCKER_STATE/containers.json")
  PRIMARY_PORT=5173
  UI=$TEAM_HOME/tasks/T22/ui
  TASK_DIR=$STACK_WORKTREE/.scratch/task
  mkdir -p "$TASK_DIR" "$UI"
  Q=$TASK_DIR/q.md
  echo "This is the page you are on." >"$Q"
  echo '{"allowFrom": ["757"]}' >"$HOME/.claude/channels/discord/access.json"
  # The refresh of the waiting list after a walk starts or stops calls Discord for nothing.
  inbox_guild_kept
  export DISCORD_DIR=$BATS_TEST_TMPDIR/discord
  mkdir -p "$DISCORD_DIR"
  # A post gets a new message id; a read of a message gets $DISCORD_DIR/<id>.json, or a 404.
  stub_script curl <<'EOF'
cat >/dev/null
url=${*: -1}
if [[ $url =~ /messages/([0-9]+)$ ]]; then
  if [[ -f $DISCORD_DIR/${BASH_REMATCH[1]}.json ]]; then cat "$DISCORD_DIR/${BASH_REMATCH[1]}.json"; exit 0; fi
  echo "curl: (22) The requested URL returned error: 404" >&2
  exit 22
fi
printf '{"id":"%d","channel_id":"5555"}\n' "$((1564000000000000000 + $(wc -l <"$STUB_CALLS/curl.log")))"
EOF
}

# The ledger events of an open task on <worktree> with the interview thread <thread>:
# task_events <task> <worktree> <thread>
task_events() {
  jq -cn --arg t "$1" --arg wt "$2" --arg th "$3" '
    {ts: "2026-10-24T09:00:00Z", task: $t, event: "opened", project: "shop", path: "feature", type: "feature",
     title: "A task", branch: "work", base: "main", base_sha: "0000000", worktree: $wt},
    {ts: "2026-10-24T09:00:01Z", task: $t, event: "interview-thread", discord_thread: $th}' >>"$TEAM_HOME/ledger.jsonl"
}

# A capture as ui-capture writes it, under <ui>/capture-<k>/, of the page at <url>, taken at
# <time> (now unless given), an element capture: capture <k> <url> [<time>] [<ui>]
capture() {
  local dir=${4:-$UI}/capture-$1
  mkdir -p "$dir"
  cat >"$dir/ui-page.md" <<PAGE
# The page capture

Captured ${3:-$(date -u +%FT%T.000Z)} by ui-capture from the Agent Chrome at http://127.0.0.1:9222.
Page: $2
Route: /events/7
Title: Import

Taken because: the visible localhost tab
Other localhost tabs: none
PAGE
  echo 'uid=1_0 RootWebArea "Import"' >"$dir/page-snapshot.txt"
  printf '# The selected element\n\nPage: %s\n' "$2" >"$dir/ui-pick.md"
  png "$dir/page.png"
  png "$dir/element.png"
}

png() {
  printf '\x89PNG\r\n\x1a\n\0\0\0\rIHDR' >"$1"
}

# The planner of T22 runs a bin command, run_bin's status flag first: as_planner <-N> <command...>
as_planner() {
  AGENT_TEAM_ROLE=planner AGENT_TEAM_TASK=T22 run_bin "$@"
}

# The planner posts the question with these images: attach <-N> <image>...
attach() {
  local status=$1 args=() image
  shift
  for image in "$@"; do args+=(--attach "$image"); done
  as_planner "$status" team-post T22 --thread interview --file "$Q" "${args[@]}"
}

# The image files each post sends, one per line.
sent_files() {
  stub_calls curl | jq -r '.[] | select(startswith("files[")) | capture("filename=\"(?<name>[^\"]*)\"").name'
}

assert_nothing_sent() {
  assert_equal "$(stub_calls curl)" ""
  assert_equal "$(jq -c 'select(.event == "image-posted")' "$TEAM_HOME/ledger.jsonl")" ""
}

# Daniel's message <id> saying <text>, by <author> (757, one of allowFrom, unless given):
# daniel_says <id> <text> [<author>]
daniel_says() {
  jq -n --arg id "$1" --arg text "$2" --arg a "${3:-757}" \
    '{id: $id, content: $text, author: {id: $a, username: "daniel"}}' >"$DISCORD_DIR/$1.json"
}

# A Discord message id sent now.
fresh_id() {
  echo $(((($(date +%s) - 1420070400) * 1000) << 22))
}

# The coordinator starts T22's walk in its interview thread on Daniel's word just given.
start_walk_on_word() {
  WORD=$(fresh_id)
  daniel_says "$WORD" "I just reseeded the primary stack on $PRIMARY_PORT with the fixture."
  run_bin -0 team-ui T22 --walk start --in interview --reseeded "$WORD"
  : >"$STUB_CALLS/curl.log"
}

@test "an image of a capture from the task's own stack leaves, by localhost or 127.0.0.1, and only under its base name" {
  capture 1 "http://127.0.0.1:$OWN_PORT/events/7?tab=a#b"
  capture 2 "http://localhost:$OWN_PORT/"
  attach -0 "$UI/capture-1/page.png" "$UI/capture-1/element.png" "$UI/capture-2/page.png"
  assert_equal "$(sent_files)" "page.png
element.png
page.png"
  assert_equal "$(jq -r 'select(.event == "image-posted") | .file' "$TEAM_HOME/ledger.jsonl")" "page.png
element.png
page.png"
}

@test "a capture from the primary's port with no word from Daniel is refused, posts nothing and stays in place" {
  capture 1 "http://127.0.0.1:$PRIMARY_PORT/events/7"
  attach -1 "$UI/capture-1/page.png"
  assert_equal "$output" "team-post: cannot attach $UI/capture-1/page.png: capture-1's page is on port $PRIMARY_PORT, no port of T22's own stack, and its walk's start names no word of Daniel's that the primary stack was just reseeded"
  assert_nothing_sent
  assert_equal "$(find "$UI/capture-1" -type f -printf '%f\n' | LC_ALL=C sort)" "element.png
page-snapshot.txt
page.png
ui-page.md
ui-pick.md"
  # An interview walk with no word clears nothing either, and one image refused sends no other.
  run_bin -0 team-ui T22 --walk start --in interview
  capture 2 "http://127.0.0.1:$OWN_PORT/"
  attach -1 "$UI/capture-2/page.png" "$UI/capture-1/page.png"
  assert_contains "$output" "capture-1's page is on port $PRIMARY_PORT"
  assert_nothing_sent
}

@test "a stack that is not running, or is another task's, gives the capture no port" {
  capture 1 "http://127.0.0.1:$OWN_PORT/"
  run_bin -0 team-stack stop --worktree "$STACK_WORKTREE"
  attach -1 "$UI/capture-1/page.png"
  assert_contains "$output" "capture-1's page is on port $OWN_PORT, no port of T22's own stack (team-stack: stackfix-shop-1 is not running"
  assert_nothing_sent
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --no-seed
  attach -0 "$UI/capture-1/page.png"
  : >"$STUB_CALLS/curl.log"
  docker_state containers 'map(if .Name == "/stackfix-shop-1-web-1" then .Config.Labels["io.github.chanjdaniel.team.task"] = "T99" else . end)'
  attach -1 "$UI/capture-1/page.png"
  assert_contains "$output" "capture-1's page is on port $OWN_PORT, no port of T22's own stack (its stack is T99's)"
  assert_equal "$(stub_calls curl)" ""
}

@test "a page a capture cannot place at one local port is refused, however the rest of its ui-page.md reads" {
  local url
  for url in "https://127.0.0.1:$OWN_PORT/" "http://127.0.0.1/" "http://localhost/events" \
    "http://example.com:$OWN_PORT/" "http://127.0.0.1:$OWN_PORT@example.com/" "http://127.0.0.1:$OWN_PORT.example.com/"; do
    capture 1 "$url"
    attach -1 "$UI/capture-1/page.png"
    assert_equal "$output" "team-post: cannot attach $UI/capture-1/page.png: capture-1's ui-page.md names no page on a local port"
  done
  assert_nothing_sent

  # Only the fixed line counts: a page's title or a console line may say anything.
  capture 1 "http://127.0.0.1:$PRIMARY_PORT/"
  sed -i "s#^Title: .*#Page: http://127.0.0.1:$OWN_PORT/#" "$UI/capture-1/ui-page.md"
  attach -1 "$UI/capture-1/page.png"
  assert_contains "$output" "capture-1's page is on port $PRIMARY_PORT"
  sed -i '4d' "$UI/capture-1/ui-page.md"
  attach -1 "$UI/capture-1/page.png"
  assert_contains "$output" "capture-1's ui-page.md names no page on a local port"

  rm "$UI/capture-1/ui-page.md"
  attach -1 "$UI/capture-1/page.png"
  assert_equal "$output" "team-post: cannot attach $UI/capture-1/page.png: capture-1 holds no ui-page.md, so nothing says where its page came from"
  assert_nothing_sent
}

@test "on Daniel's word at the walk's start, a capture of that walk from the primary's port leaves; before or after the walk it does not" {
  capture 1 "http://127.0.0.1:$PRIMARY_PORT/" "2026-10-24T09:30:00.000Z"
  start_walk_on_word
  capture 2 "http://127.0.0.1:$PRIMARY_PORT/events/7"
  attach -0 "$UI/capture-2/page.png"
  assert_equal "$(sent_files)" "page.png"
  : >"$STUB_CALLS/curl.log"

  # Taken before the word, when the page may have held the real import.
  attach -1 "$UI/capture-1/page.png"
  assert_equal "$output" "team-post: cannot attach $UI/capture-1/page.png: capture-1 was taken before the walk that Daniel's word $WORD clears began"
  assert_equal "$(stub_calls curl)" ""

  # The word ends with its walk, and a new walk needs a new word.
  run_bin -0 team-ui T22 --walk stop
  attach -1 "$UI/capture-2/page.png"
  assert_contains "$output" "its walk's start names no word of Daniel's"
  run_bin -0 team-ui T22 --walk start --in interview
  capture 3 "http://127.0.0.1:$PRIMARY_PORT/"
  attach -1 "$UI/capture-3/page.png"
  assert_contains "$output" "its walk's start names no word of Daniel's"
  assert_equal "$(stub_calls curl)" ""
}

@test "Daniel's word clears only the port it names: a capture of any other local port is refused, and stays" {
  local other=$((PRIMARY_PORT + 1))
  start_walk_on_word
  capture 1 "http://127.0.0.1:$other/"
  capture 2 "http://localhost:$other/events/7"
  attach -1 "$UI/capture-1/page.png"
  assert_equal "$output" "team-post: cannot attach $UI/capture-1/page.png: capture-1's page is on port $other, no port of T22's own stack, and Daniel's word $WORD clears only port $PRIMARY_PORT"
  assert_nothing_sent
  attach -1 "$UI/capture-2/page.png"
  assert_nothing_sent
  [[ -f $UI/capture-1/page.png && -f $UI/capture-2/page.png ]]
  # The port it names still leaves.
  capture 3 "http://localhost:$PRIMARY_PORT/"
  attach -0 "$UI/capture-3/page.png"
  assert_equal "$(sent_files)" "page.png"
}

@test "a worker cannot give the word: team-ui refuses it, and a message that is not Daniel's logs no walk" {
  local id
  id=$(fresh_id)
  daniel_says "$id" "I just reseeded the primary stack." 999
  as_planner -1 team-ui T22 --walk start --in interview --reseeded "$id"
  assert_contains "$output" "a planner session runs no team-ui"
  run_bin -1 --separate-stderr team-ui T22 --walk start --in interview --reseeded "$id"
  assert_contains "$stderr" "is by daniel (999), who is not in allowFrom"
  assert_equal "$(jq -c 'select(.event == "walk")' "$TEAM_HOME/ledger.jsonl")" ""
}

@test "of a capture only page.png and element.png may leave; everything else under ui/ stays refused" {
  capture 1 "http://127.0.0.1:$OWN_PORT/"
  echo "words" >"$UI/capture-1/note.md"
  png "$UI/capture-1/other.png"
  local name
  for name in ui-page.md ui-pick.md page-snapshot.txt note.md other.png; do
    attach -1 "$UI/capture-1/$name"
    assert_equal "$output" "team-post: cannot attach $UI/capture-1/$name: only page.png and element.png of a capture may be attached"
  done

  # Daniel's own images and a flat capture at the top of ui/, a capture-like name that is not one,
  # a directory inside a capture, and another task's capture: none of them is cleared by this rule.
  local from="a worker session attaches only from T22's task directory"
  png "$UI/flat-page.png"
  capture x "http://127.0.0.1:$OWN_PORT/"
  capture 0 "http://127.0.0.1:$OWN_PORT/"
  capture 01 "http://127.0.0.1:$OWN_PORT/"
  mkdir "$UI/capture-1/deep"
  png "$UI/capture-1/deep/page.png"
  capture 1 "http://127.0.0.1:$OWN_PORT/" "" "$TEAM_HOME/tasks/T17/ui"
  local path
  for path in "$UI/flat-page.png" "$UI/capture-x/page.png" "$UI/capture-0/page.png" "$UI/capture-01/page.png" \
    "$UI/capture-1/deep/page.png" "$TEAM_HOME/tasks/T17/ui/capture-1/page.png"; do
    attach -1 "$path"
    assert_equal "$output" "team-post: cannot attach $path: $from"
  done
  assert_nothing_sent
}

@test "a link stays refused, a capture's included" {
  local outside=$BATS_TEST_TMPDIR/outside
  mkdir -p "$outside"
  png "$outside/real.png"
  capture 1 "http://127.0.0.1:$OWN_PORT/"
  capture 2 "http://127.0.0.1:$OWN_PORT/"
  capture 3 "http://127.0.0.1:$OWN_PORT/"
  capture 4 "http://127.0.0.1:$OWN_PORT/"
  rm "$UI/capture-1/page.png"
  ln -s "$outside/real.png" "$UI/capture-1/page.png"
  attach -1 "$UI/capture-1/page.png"
  assert_equal "$output" "team-post: cannot attach $UI/capture-1/page.png: it is a link"
  rm "$UI/capture-2/page.png"
  ln "$outside/real.png" "$UI/capture-2/page.png"
  attach -1 "$UI/capture-2/page.png"
  assert_equal "$output" "team-post: cannot attach $UI/capture-2/page.png: it is a link"
  # A capture's directory that is a link has its real path elsewhere.
  ln -s "$outside" "$UI/capture-8"
  png "$outside/page.png"
  cp "$UI/capture-3/ui-page.md" "$outside/ui-page.md"
  attach -1 "$UI/capture-8/page.png"
  assert_equal "$output" "team-post: cannot attach $UI/capture-8/page.png: a worker session attaches only from T22's task directory"
  # What says where the page came from, or what the scan reads, is no link either.
  mv "$UI/capture-3/ui-page.md" "$outside/kept.md"
  ln -s "$outside/kept.md" "$UI/capture-3/ui-page.md"
  attach -1 "$UI/capture-3/page.png"
  assert_equal "$output" "team-post: cannot attach $UI/capture-3/page.png: capture-3's ui-page.md is a link"
  rm "$UI/capture-4/page-snapshot.txt"
  echo "elsewhere" >"$outside/snapshot.txt"
  ln -s "$outside/snapshot.txt" "$UI/capture-4/page-snapshot.txt"
  attach -1 "$UI/capture-4/page.png"
  assert_equal "$output" "team-post: cannot attach $UI/capture-4/page.png: capture-4's page-snapshot.txt is a link or no plain file"
  assert_nothing_sent
}

@test "an address in any of the capture's text files refuses it, naming the capture and the kind, never the value" {
  local at=@ name=ada.lovelace provider=gmail.com company=acme-events.ca file
  for file in ui-page.md page-snapshot.txt ui-pick.md note.md; do
    capture 1 "http://127.0.0.1:$OWN_PORT/"
    echo "Applicant: $name$at$provider" >>"$UI/capture-1/$file"
    attach -1 "$UI/capture-1/page.png"
    assert_equal "$output" "team-post: cannot attach $UI/capture-1/page.png: capture-1's $file holds 1 email address at a public provider"
    assert_nothing_sent
    assert_contains "$(cat "$UI/capture-1/$file")" "$name$at$provider"
    rm "$UI/capture-1/note.md" 2>/dev/null || true
  done
  capture 1 "http://127.0.0.1:$OWN_PORT/"
  printf '%s\n' "$name$at$company" "b$at$company" "$name$at$provider" >>"$UI/capture-1/page-snapshot.txt"
  attach -1 "$UI/capture-1/element.png"
  assert_equal "$output" "team-post: cannot attach $UI/capture-1/element.png: capture-1's page-snapshot.txt holds 1 email address at a public provider and 2 email addresses outside the fixture domains"
  assert_nothing_sent
}

@test "the scan holds a capture on Daniel's word too, and takes the fixture domains and services as data-check does" {
  local at=@ name=ada provider=outlook.com
  capture 1 "http://127.0.0.1:$OWN_PORT/"
  printf '%s\n' "alex${at}example.com" "sam${at}qa.test" "noreply${at}acme.ca" "logo${at}2x.png" >>"$UI/capture-1/page-snapshot.txt"
  attach -0 "$UI/capture-1/page.png"
  : >"$STUB_CALLS/curl.log"
  start_walk_on_word
  capture 2 "http://127.0.0.1:$PRIMARY_PORT/"
  echo "$name$at$provider" >>"$UI/capture-2/ui-pick.md"
  attach -1 "$UI/capture-2/page.png"
  assert_contains "$output" "capture-2's ui-pick.md holds 1 email address at a public provider"
  assert_equal "$(stub_calls curl)" ""
}

@test "a worker's post text is scanned by the same rule, with an image or without, and the coordinator's is not" {
  local at=@ name=ada provider=gmail.com
  echo "Is $name$at$provider the applicant?" >"$Q"
  as_planner -1 team-post T22 --thread interview --file "$Q"
  assert_equal "$output" "team-post: cannot post $Q: it holds 1 email address at a public provider"
  capture 1 "http://127.0.0.1:$OWN_PORT/"
  attach -1 "$UI/capture-1/page.png"
  assert_equal "$output" "team-post: cannot post $Q: it holds 1 email address at a public provider"
  assert_nothing_sent
  run_bin -0 team-post T22 --thread interview --file "$Q"
  : >"$STUB_CALLS/curl.log"
  echo "Is alex${at}example.com the applicant?" >"$Q"
  as_planner -0 team-post T22 --thread interview --file "$Q"
}

@test "the coordinator's attachment meets none of a worker's checks" {
  capture 1 "http://127.0.0.1:$PRIMARY_PORT/"
  run_bin -0 team-post T22 --thread interview --file "$Q" --attach "$UI/capture-1/page.png"
  assert_equal "$(sent_files)" "page.png"
}
