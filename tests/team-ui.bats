#!/usr/bin/env bats
# team-ui: what Daniel pointed at for a UI fix, kept in tasks/T<n>/ui/ (the frontend toolkit's
# captures of the page Daniel is on and the element selected in the Agent Chrome, each in a
# capture-<k>/ directory of its own, and the screenshots Daniel attached), and named by team-brief
# in the briefs that follow. ui-capture is a stub in the test's own code checkout; its real
# behaviour is tests/toolkits/frontend.test.mjs's.

load helpers/common

setup() {
  sandbox
  code_checkout
  capture=$CODE_CHECKOUT/toolkits/frontend/scripts/ui-capture
  # The stub capture: writes the files the real one writes, an element and page capture unless
  # $STUB_FIXTURES/capture-kind says page, prints its line as the real one does, or fails with the
  # line in $STUB_FIXTURES/capture-fails, writing nothing; it logs its arguments.
  cat >"$capture" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$STUB_CALLS/ui-capture.log"
if [[ -f $STUB_FIXTURES/capture-fails ]]; then
  echo "ui-capture: $(cat "$STUB_FIXTURES/capture-fails")" >&2
  exit 1
fi
mkdir -p "$1"
printf '# The page capture\n\nPage: http://localhost:5173/events/7/import\n' >"$1/ui-page.md"
printf 'png' >"$1/page.png"
printf 'uid=1_0 RootWebArea "Import"\n' >"$1/page-snapshot.txt"
if [[ $(cat "$STUB_FIXTURES/capture-kind" 2>/dev/null) == page ]]; then
  echo "ui-capture: page http://localhost:5173/events/7/import (the visible localhost tab), no element selected -> $1/ui-page.md"
  exit 0
fi
printf '# The selected element\n\n- button src/components/PhaseRail.vue:529:13\n' >"$1/ui-pick.md"
printf 'png' >"$1/element.png"
echo "ui-capture: button \"More...\" at button src/components/PhaseRail.vue:529:13 on http://localhost:5173/events/7 -> $1/ui-pick.md, $1/ui-page.md"
EOF
  chmod +x "$capture"
  open_task T7
  ui=$TEAM_HOME/tasks/T7/ui
  inbox=$HOME/.claude/channels/discord/inbox
  mkdir -p "$inbox"
  printf 'shot' >"$inbox/1563-screenshot.png"
  printf 'other' >"$inbox/notes.txt"
}

# open_task <task>: the events team-open writes for a Conventioner task, with its thread.
open_task() {
  mkdir -p "$TEAM_HOME/tasks/$1"
  jq -cn --arg task "$1" --arg wt "$HOME/wt/$1" '{ts: "2026-10-25T10:00:00Z", task: $task, event: "opened",
    project: "conventioner", path: "small", type: "fix", title: "the More... button height",
    branch: "fix/\($task)-more-button", base: "dev", base_sha: "aba9d074", worktree: $wt}' >>"$TEAM_HOME/ledger.jsonl"
}

# interview_thread <task>: the event team-thread --interview writes.
interview_thread() {
  jq -cn --arg task "$1" '{ts: "2026-10-25T10:01:00Z", task: $task, event: "interview-thread", discord_thread: "1563000000000000009"}' >>"$TEAM_HOME/ledger.jsonl"
}

# register_conventioner: the registry naming Conventioner, with its task directory.
register_conventioner() {
  cat >"$TEAM_HOME/projects.toml" <<'TOML'
[conventioner]
repo = "chanjdaniel/Conventioner"
path = "Documents/projects/personal/Conventioner"
base = "dev"
delivery = "no-mistakes"
merge_method = "merge"
required_checks = []
task_dir = ".scratch/task"
docs = []
toolkits = []

[conventioner.pool]
provider = "git"
slots = ["wt/T7"]
TOML
}

@test "--capture runs ui-capture into a new capture-<k>/ each time and says which kind it took" {
  run_bin -0 --separate-stderr team-ui T7 --capture
  assert_equal "$(cat "$STUB_CALLS/ui-capture.log")" "$ui/capture-1"
  assert_equal "$output" "ui-capture: button \"More...\" at button src/components/PhaseRail.vue:529:13 on http://localhost:5173/events/7 -> $ui/capture-1/ui-pick.md, $ui/capture-1/ui-page.md
captured: element and page
tasks/T7/ui/ holds:
$ui/capture-1/element.png
$ui/capture-1/page-snapshot.txt
$ui/capture-1/page.png
$ui/capture-1/ui-page.md
$ui/capture-1/ui-pick.md"
  assert_equal "$stderr" ""
  # The second capture, a page with nothing selected, never touches the first.
  echo page >"$STUB_FIXTURES/capture-kind"
  run_bin -0 --separate-stderr team-ui T7 --capture
  assert_equal "$(tail -n 1 "$STUB_CALLS/ui-capture.log")" "$ui/capture-2"
  assert_equal "$output" "ui-capture: page http://localhost:5173/events/7/import (the visible localhost tab), no element selected -> $ui/capture-2/ui-page.md
captured: page
tasks/T7/ui/ holds:
$ui/capture-1/element.png
$ui/capture-1/page-snapshot.txt
$ui/capture-1/page.png
$ui/capture-1/ui-page.md
$ui/capture-1/ui-pick.md
$ui/capture-2/page-snapshot.txt
$ui/capture-2/page.png
$ui/capture-2/ui-page.md"
}

@test "the next capture's number is one more than the highest there, and the listing orders them by number" {
  mkdir -p "$ui/capture-9" "$ui/capture-10" "$ui/capture-x"
  printf 'png' >"$ui/capture-9/page.png"
  printf 'png' >"$ui/capture-10/page.png"
  echo page >"$STUB_FIXTURES/capture-kind"
  run_bin -0 team-ui T7 --capture
  assert_equal "$(cat "$STUB_CALLS/ui-capture.log")" "$ui/capture-11"
  assert_equal "$(sed -n '/holds:$/,$p' <<<"$output")" "tasks/T7/ui/ holds:
$ui/capture-9/page.png
$ui/capture-10/page.png
$ui/capture-11/page-snapshot.txt
$ui/capture-11/page.png
$ui/capture-11/ui-page.md"
}

@test "--note-file keeps Daniel's words and the time beside the capture they go with" {
  echo page >"$STUB_FIXTURES/capture-kind"
  # The coordinator writes each note with the Write tool, under a dot name team-ui lists nowhere.
  mkdir -p "$ui"
  printf "preview import is blocked. check the page state\n" >"$ui/.note-1"
  printf 'the `Import` button ```stays``` grey, and Daniel'"'"'s "Save" too\n' >"$ui/.note-2"
  run_bin -0 team-ui T7 --capture --note-file "$ui/.note-1"
  run_bin -0 team-ui T7 --note-file "$ui/.note-2" --capture
  [[ ! -e $ui/note.md ]]
  [[ $output != *.note-* ]] || { echo "$output" >&2; return 1; }
  assert_contains "$output" "$ui/capture-2/note.md"
  local note
  note=$(<"$ui/capture-1/note.md")
  [[ $note =~ ^"# Daniel's note"$'\n\n'"Daniel's words this capture goes with, as the coordinator copied them, at "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"."$'\n\n'"\`\`\`"$'\n'"preview import is blocked. check the page state"$'\n'"\`\`\`"$ ]] ||
    { echo "$note" >&2; return 1; }
  # The fence is longer than any run of backticks in the words, so they read as written.
  assert_equal "$(tail -n 3 "$ui/capture-2/note.md")" '````
the `Import` button ```stays``` grey, and Daniel'"'"'s "Save" too
````'
}

@test "--attach copies each file under its own name, numbering a name already taken" {
  run_bin -0 team-ui T7 --attach "$inbox/1563-screenshot.png" --attach "$inbox/notes.txt"
  run_bin -0 team-ui T7 --attach "$inbox/1563-screenshot.png"
  assert_equal "$(cd "$ui" && find . -type f -printf '%P %s\n' | sort)" "1563-screenshot-2.png 4
1563-screenshot.png 4
notes.txt 5"
  assert_equal "$(tail -n 4 <<<"$output")" "tasks/T7/ui/ holds:
$ui/1563-screenshot-2.png
$ui/1563-screenshot.png
$ui/notes.txt"
  [[ ! -e $STUB_CALLS/ui-capture.log ]]
}

@test "attachments stay at the top of ui/, beside the captures and a flat capture an older team-ui left" {
  mkdir -p "$ui"
  printf '# The selected element\n' >"$ui/ui-pick.md"
  printf 'png' >"$ui/element.png"
  run_bin -0 team-ui T7 --attach "$inbox/1563-screenshot.png" --capture
  assert_equal "$(sed -n '/holds:$/,$p' <<<"$output")" "tasks/T7/ui/ holds:
$ui/1563-screenshot.png
$ui/element.png
$ui/ui-pick.md
$ui/capture-1/element.png
$ui/capture-1/page-snapshot.txt
$ui/capture-1/page.png
$ui/capture-1/ui-page.md
$ui/capture-1/ui-pick.md"
}

@test "a capture that fails removes its directory, keeps the attachments and earlier captures, and says why in one line" {
  run_bin -0 team-ui T7 --capture
  echo "the Agent Chrome has no localhost page open" >"$STUB_FIXTURES/capture-fails"
  printf 'check the page\n' >"$BATS_TEST_TMPDIR/note"
  run_bin -1 --separate-stderr team-ui T7 --attach "$inbox/1563-screenshot.png" --capture --note-file "$BATS_TEST_TMPDIR/note"
  assert_equal "$(tail -n 1 "$STUB_CALLS/ui-capture.log")" "$ui/capture-2"
  assert_equal "$stderr" "team-ui: the capture failed: ui-capture: the Agent Chrome has no localhost page open"
  [[ ! -e $ui/capture-2 ]]
  assert_equal "$output" "tasks/T7/ui/ holds:
$ui/1563-screenshot.png
$ui/capture-1/element.png
$ui/capture-1/page-snapshot.txt
$ui/capture-1/page.png
$ui/capture-1/ui-page.md
$ui/capture-1/ui-pick.md"
  # The next capture takes the number the failed one gave back.
  rm "$STUB_FIXTURES/capture-fails"
  run_bin -0 team-ui T7 --capture
  assert_equal "$(tail -n 1 "$STUB_CALLS/ui-capture.log")" "$ui/capture-2"
}

@test "a ui/ it cannot make a capture directory in is refused at once, naming the directory" {
  mkdir -p "$ui"
  chmod 555 "$ui"
  run -1 --separate-stderr timeout 10 "$CODE_CHECKOUT/bin/team-ui" T7 --capture
  chmod 755 "$ui"
  assert_equal "$stderr" "team-ui: cannot make a capture directory in $ui"
  [[ ! -e $STUB_CALLS/ui-capture.log ]]
  [[ -z $(ls -A "$ui") ]]
}

@test "the brief that follows names each capture with a note, with its kind, and counts the others" {
  run_bin -0 team-ui T7 --capture
  echo page >"$STUB_FIXTURES/capture-kind"
  printf 'check the page state\n' >"$BATS_TEST_TMPDIR/note"
  run_bin -0 team-ui T7 --capture --note-file "$BATS_TEST_TMPDIR/note"
  jq -cn '{ts: "2026-10-25T10:01:00Z", task: "T7", event: "thread", discord_thread: "1563000000000000007"}' >>"$TEAM_HOME/ledger.jsonl"
  register_conventioner
  run_bin -0 team-brief T7 builder-fix --set 'read=- `AGENTS.md`.' --set commits=fix --set goal=g
  local brief=$TEAM_HOME/tasks/T7/brief.md
  grep -qF "kept for this task: \`$ui/\`, each capture in a directory of its own." "$brief"
  grep -qxF '  - `capture-2/`: a page capture, no element selected; `note.md` holds the words Daniel posted with it.' "$brief"
  grep -qxF '  - 1 with no note, `capture-1/`.' "$brief"
  grep -qF 'never in the Agent Chrome' "$brief"
}

@test "refuses a task that is not open, a file it cannot read, and a malformed command line" {
  run_bin -1 --separate-stderr team-ui T8 --capture
  assert_equal "$stderr" "team-ui: T8 is not open: the ledger has no opened event for it"
  jq -cn '{ts: "2026-10-25T11:00:00Z", task: "T7", event: "closed"}' >>"$TEAM_HOME/ledger.jsonl"
  run_bin -1 --separate-stderr team-ui T7 --capture
  assert_equal "$stderr" "team-ui: T7 is closed"
  open_task T9
  run_bin -1 --separate-stderr team-ui T9 --attach "$inbox/missing.png"
  assert_equal "$stderr" "team-ui: cannot read $inbox/missing.png"
  [[ ! -e $TEAM_HOME/tasks/T9/ui ]]
  run_bin -2 team-ui T9
  run_bin -2 team-ui T9 --attach
  run_bin -2 team-ui 9 --capture
  run_bin -2 team-ui T9 --capture --bogus
  local note=$BATS_TEST_TMPDIR/note
  printf 'check the page\n' >"$note"
  run_bin -2 --separate-stderr team-ui T9 --note-file "$note"
  assert_equal "$stderr" "team-ui: --note-file goes with --capture"
  run_bin -2 --separate-stderr team-ui T9 --attach "$inbox/notes.txt" --note-file "$note"
  assert_equal "$stderr" "team-ui: --note-file goes with --capture"
  run_bin -2 --separate-stderr team-ui T9 --capture --note-file
  assert_equal "$stderr" "team-ui: --note-file needs the file Daniel's words were written to"
  run_bin -2 --separate-stderr team-ui T9 --capture --note-file ''
  assert_equal "$stderr" "team-ui: --note-file needs the file Daniel's words were written to"
  run_bin -2 --separate-stderr team-ui T9 --capture --note-file "$note" --note-file "$note"
  assert_equal "$stderr" "team-ui: one --note-file per capture"
  run_bin -2 --separate-stderr team-ui T9 --capture --note 'check the page'
  assert_equal "$stderr" "team-ui: unexpected argument '--note'"
  # A note it cannot read, or one with no words, is refused before anything is copied or captured.
  run_bin -1 --separate-stderr team-ui T9 --attach "$inbox/notes.txt" --capture --note-file "$BATS_TEST_TMPDIR/missing"
  assert_equal "$stderr" "team-ui: cannot read $BATS_TEST_TMPDIR/missing"
  printf '\n \n' >"$note"
  run_bin -1 --separate-stderr team-ui T9 --attach "$inbox/notes.txt" --capture --note-file "$note"
  assert_equal "$stderr" "team-ui: $note holds no words"
  [[ ! -e $STUB_CALLS/ui-capture.log ]]
  [[ ! -e $TEAM_HOME/tasks/T9/ui ]]
}

# walk_events <task>: the task's walk events in the ledger, as "<state>" lines.
walk_events() {
  jq -r --arg task "$1" 'select(.task == $task and .event == "walk") | .state' "$TEAM_HOME/ledger.jsonl"
}

@test "--walk start and stop log the walk's state once each, status reads it, and a repeat changes nothing" {
  local ts='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'
  run_bin -0 --separate-stderr team-ui T7 --walk status
  assert_equal "$output" "walk off for T7"
  assert_equal "$(walk_events T7)" ""
  run_bin -0 --separate-stderr team-ui T7 --walk start
  assert_equal "$output" "walk on for T7"
  assert_equal "$stderr" ""
  assert_equal "$(walk_events T7)" "on"
  local since
  since=$(jq -r 'select(.event == "walk") | .ts' "$TEAM_HOME/ledger.jsonl")
  [[ $since =~ ^$ts$ ]]
  run_bin -0 team-ui T7 --walk start
  assert_equal "$output" "walk already on for T7 since $since"
  assert_equal "$(walk_events T7)" "on"
  run_bin -0 team-ui T7 --walk status
  assert_equal "$output" "walk on for T7 since $since"
  run_bin -0 team-ui T7 --walk stop
  assert_equal "$output" "walk off for T7"
  assert_equal "$(walk_events T7)" "on
off"
  run_bin -0 team-ui T7 --walk stop
  assert_equal "$output" "walk already off for T7"
  run_bin -0 team-ui T7 --walk status
  assert_equal "$output" "walk off for T7"
  assert_equal "$(walk_events T7)" "on
off"
  # Each line it logged meets the contract, written by team-ui.
  run_bin -0 team-log --check
  # A walk touches no capture.
  [[ ! -e $STUB_CALLS/ui-capture.log ]]
  [[ ! -e $ui ]]
}

@test "a walk is the task's own: another task's walk leaves it off" {
  open_task T9
  run_bin -0 team-ui T9 --walk start
  run_bin -0 team-ui T7 --walk status
  assert_equal "$output" "walk off for T7"
  run_bin -0 team-ui T7 --walk start
  assert_equal "$output" "walk on for T7"
}

@test "--walk refuses a task that is not open, and is a form of its own with one word" {
  local word
  for word in start stop status; do
    run_bin -1 --separate-stderr team-ui T8 --walk "$word"
    assert_equal "$stderr" "team-ui: T8 is not open: the ledger has no opened event for it"
  done
  open_task T9
  jq -cn '{ts: "2026-10-25T11:00:00Z", task: "T9", event: "closed"}' >>"$TEAM_HOME/ledger.jsonl"
  for word in start stop status; do
    run_bin -1 --separate-stderr team-ui T9 --walk "$word"
    assert_equal "$stderr" "team-ui: T9 is closed"
  done
  run_bin -2 --separate-stderr team-ui T7 --walk
  assert_equal "$stderr" "team-ui: --walk needs start, stop or status"
  run_bin -2 --separate-stderr team-ui T7 --walk begin
  assert_equal "$stderr" "team-ui: --walk needs start, stop or status, got 'begin'"
  run_bin -2 --separate-stderr team-ui T7 --walk --capture
  assert_equal "$stderr" "team-ui: --walk needs start, stop or status, got '--capture'"
  run_bin -2 --separate-stderr team-ui T7 --walk start --walk stop
  assert_equal "$stderr" "team-ui: one --walk at a time"
  run_bin -2 --separate-stderr team-ui T7 --walk start --capture
  assert_equal "$stderr" "team-ui: --walk goes alone, without --capture, --note-file or --attach"
  run_bin -2 --separate-stderr team-ui T7 --capture --walk start
  assert_equal "$stderr" "team-ui: --walk goes alone, without --capture, --note-file or --attach"
  run_bin -2 --separate-stderr team-ui T7 --walk start --note-file "$inbox/notes.txt"
  assert_equal "$stderr" "team-ui: --walk goes alone, without --capture, --note-file or --attach"
  run_bin -2 --separate-stderr team-ui T7 --walk stop --attach "$inbox/notes.txt"
  assert_equal "$stderr" "team-ui: --walk goes alone, without --capture, --note-file or --attach"
  run_bin -2 team-ui --walk start
  [[ ! -e $TEAM_HOME/ledger.jsonl ]] || assert_equal "$(walk_events T7)" ""
  [[ ! -e $STUB_CALLS/ui-capture.log ]]
  [[ ! -e $ui ]]
}

# The guard on the Agent Chrome: a worker's image can leave through team-post, so no worker session
# reaches that window through team-ui but the one the tests after this one name. A settings deny is
# the speed bump, this the refusal.
@test "with no interview walk on, no worker session captures, attaches or runs a walk, its own task's included; the coordinator's capture still runs" {
  local role
  for role in planner builder reviewer ops; do
    AGENT_TEAM_ROLE=$role AGENT_TEAM_TASK=T7 run_bin -1 team-ui T7 --capture
    if [[ $role == planner ]]; then
      assert_equal "$output" "team-ui: T7 has no interview walk on: a planner captures only during its own task's interview walk, which Daniel starts through the coordinator"
    else
      assert_equal "$output" "team-ui: a $role session takes no capture of the Agent Chrome: that is the coordinator's; send it your message"
    fi
    AGENT_TEAM_ROLE=$role AGENT_TEAM_TASK=T7 run_bin -1 team-ui T7 --attach "$inbox/1563-screenshot.png"
    assert_contains "$output" "a $role session runs no team-ui"
    local word
    for word in start stop status; do
      AGENT_TEAM_ROLE=$role AGENT_TEAM_TASK=T7 run_bin -1 team-ui T7 --walk "$word"
      assert_contains "$output" "a $role session runs no team-ui"
    done
  done
  [[ ! -e $STUB_CALLS/ui-capture.log ]]
  [[ ! -e $ui ]]
  assert_equal "$(walk_events T7)" ""

  AGENT_TEAM_ROLE=coordinator run_bin -0 team-ui T7 --capture
  assert_equal "$(cat "$STUB_CALLS/ui-capture.log")" "$ui/capture-1"
  AGENT_TEAM_ROLE=coordinator run_bin -0 team-ui T7 --walk start
  assert_equal "$output" "walk on for T7"
  # Daniel's own shell and the heartbeat set no role.
  run_bin -0 team-ui T7 --capture
  [[ -d $ui/capture-2 ]]
}

# Daniel's decision (Discord 1567568771311337525): an interview's planner, with its task's walk on in
# its own thread, takes a capture of the page Daniel is on, read-only; no other worker can.
@test "a planner captures during its own task's interview walk" {
  interview_thread T7
  run_bin -0 team-ui T7 --walk start --in interview
  AGENT_TEAM_ROLE=planner AGENT_TEAM_TASK=T7 run_bin -0 team-ui T7 --capture
  assert_equal "$(cat "$STUB_CALLS/ui-capture.log")" "$ui/capture-1"
  assert_contains "$output" "captured: element and page"
}

# The walk-note lines of the ledger, a count.
walk_note_count() {
  jq -s 'map(select(.event == "walk-note")) | length' "$TEAM_HOME/ledger.jsonl"
}

@test "a noted capture is a walk note in a walk of the task's own thread, even when the capture fails" {
  printf 'This is off.\n' >"$BATS_TEST_TMPDIR/note"
  # No walk on: nothing.
  run_bin -0 team-ui T7 --capture --note-file "$BATS_TEST_TMPDIR/note"
  assert_equal "$(walk_note_count)" 0
  run_bin -0 team-ui T7 --walk start
  # No note: the capture says nothing of Daniel.
  run_bin -0 team-ui T7 --capture
  assert_equal "$(walk_note_count)" 0
  run_bin -0 team-ui T7 --capture --note-file "$BATS_TEST_TMPDIR/note"
  assert_equal "$(walk_note_count)" 1
  echo 'no Agent Chrome' >"$STUB_FIXTURES/capture-fails"
  run_bin -1 team-ui T7 --capture --note-file "$BATS_TEST_TMPDIR/note"
  assert_equal "$(walk_note_count)" 2
}

@test "a walk note takes its message id from the coordinator's note file, and never Daniel's words" {
  run_bin -0 team-ui T7 --walk start
  printf 'This button is off.\n' >"$BATS_TEST_TMPDIR/.note-1564000000000000009"
  run_bin -0 team-ui T7 --capture --note-file "$BATS_TEST_TMPDIR/.note-1564000000000000009"
  assert_equal "$(jq -c 'select(.event == "walk-note") | [.task, .discord_message, (keys | length)]' "$TEAM_HOME/ledger.jsonl")" '["T7","1564000000000000009",4]'
  assert_equal "$(grep -c 'This button' "$TEAM_HOME/ledger.jsonl" || true)" 0
  # A note file of any other name has no id to give.
  printf 'And this.\n' >"$BATS_TEST_TMPDIR/note"
  run_bin -0 team-ui T7 --capture --note-file "$BATS_TEST_TMPDIR/note"
  assert_equal "$(jq -c 'select(.event == "walk-note") | .discord_message' "$TEAM_HOME/ledger.jsonl" | tail -n 1)" null
}

@test "a noted capture in an interview walk is no walk note: the wait logs that thread's messages" {
  interview_thread T7
  run_bin -0 team-ui T7 --walk start --in interview
  printf 'This is off.\n' >"$BATS_TEST_TMPDIR/note"
  run_bin -0 team-ui T7 --capture --note-file "$BATS_TEST_TMPDIR/note"
  assert_equal "$(walk_note_count)" 0
}

@test "a planner's noted capture is no walk note: the wait logged that message already" {
  register_conventioner
  interview_thread T7
  run_bin -0 team-ui T7 --walk start --in interview
  mkdir -p "$HOME/wt/T7/.scratch/task"
  # The note file's name holds an id, as the coordinator's does, and still logs nothing.
  local note=$HOME/wt/T7/.scratch/task/.note-1564000000000000009
  printf 'This is off.\n' >"$note"
  AGENT_TEAM_ROLE=planner AGENT_TEAM_TASK=T7 run_bin -0 team-ui T7 --capture --note-file "$note"
  assert_equal "$(cat "$STUB_CALLS/ui-capture.log")" "$ui/capture-1"
  assert_contains "$(<"$ui/capture-1/note.md")" "as the planner copied them"
  assert_equal "$(walk_note_count)" 0
}

@test "only that planner, only --capture, and only while that walk is on in its interview thread" {
  interview_thread T7
  open_task T9
  run_bin -0 team-ui T7 --walk start --in interview
  local role word
  # Another role of the same task.
  for role in builder reviewer ops; do
    AGENT_TEAM_ROLE=$role AGENT_TEAM_TASK=T7 run_bin -1 team-ui T7 --capture
    assert_equal "$output" "team-ui: a $role session takes no capture of the Agent Chrome: that is the coordinator's; send it your message"
  done
  # A planner of another task, for that walk's task or its own.
  AGENT_TEAM_ROLE=planner AGENT_TEAM_TASK=T9 run_bin -1 team-ui T7 --capture
  assert_equal "$output" "team-ui: a planner session of T9 takes no capture of the Agent Chrome for T7: a planner captures only during its own task's interview walk"
  AGENT_TEAM_ROLE=planner AGENT_TEAM_TASK=T9 run_bin -1 team-ui T9 --capture
  assert_equal "$output" "team-ui: T9 has no interview walk on: a planner captures only during its own task's interview walk, which Daniel starts through the coordinator"
  # Every other form stays refused to the walk's own planner, and nothing of them runs.
  AGENT_TEAM_ROLE=planner AGENT_TEAM_TASK=T7 run_bin -1 team-ui T7 --attach "$inbox/1563-screenshot.png"
  assert_contains "$output" "a planner session runs no team-ui"
  AGENT_TEAM_ROLE=planner AGENT_TEAM_TASK=T7 run_bin -1 team-ui T7 --capture --attach "$inbox/1563-screenshot.png"
  assert_contains "$output" "a planner session runs no team-ui"
  for word in start stop status; do
    AGENT_TEAM_ROLE=planner AGENT_TEAM_TASK=T7 run_bin -1 team-ui T7 --walk "$word"
    assert_contains "$output" "a planner session runs no team-ui"
  done
  [[ ! -e $STUB_CALLS/ui-capture.log ]]
  [[ ! -e $ui ]]
  assert_equal "$(walk_events T7)" "on"

  # Off again, it refuses; so does a walk in the task's own thread, which the coordinator follows.
  run_bin -0 team-ui T7 --walk stop
  AGENT_TEAM_ROLE=planner AGENT_TEAM_TASK=T7 run_bin -1 team-ui T7 --capture
  assert_contains "$output" "T7 has no interview walk on"
  run_bin -0 team-ui T7 --walk start
  AGENT_TEAM_ROLE=planner AGENT_TEAM_TASK=T7 run_bin -1 team-ui T7 --capture
  assert_contains "$output" "T7 has no interview walk on"
  run_bin -0 team-ui T7 --walk stop
  # A walk left on ends with its task.
  run_bin -0 team-ui T7 --walk start --in interview
  jq -cn '{ts: "2026-10-25T11:00:00Z", task: "T7", event: "closed"}' >>"$TEAM_HOME/ledger.jsonl"
  AGENT_TEAM_ROLE=planner AGENT_TEAM_TASK=T7 run_bin -1 team-ui T7 --capture
  assert_contains "$output" "T7 has no interview walk on"
  [[ ! -e $STUB_CALLS/ui-capture.log ]]
}

@test "--in interview logs the walk's thread, status and a repeat say it, and it goes only with start" {
  interview_thread T7
  run_bin -0 team-ui T7 --walk start --in interview
  assert_equal "$output" "walk on for T7 in its interview thread"
  assert_equal "$(jq -c 'select(.event == "walk") | del(.ts)' "$TEAM_HOME/ledger.jsonl")" '{"task":"T7","event":"walk","state":"on","thread":"interview"}'
  run_bin -0 team-log --check
  local since
  since=$(jq -r 'select(.event == "walk") | .ts' "$TEAM_HOME/ledger.jsonl")
  run_bin -0 team-ui T7 --walk status
  assert_equal "$output" "walk on for T7 since $since in its interview thread"
  run_bin -0 team-ui T7 --walk start --in interview
  assert_equal "$output" "walk already on for T7 since $since in its interview thread"
  assert_equal "$(walk_events T7)" "on"
  # A walk moves between threads only by a stop, so no caller reads "on" as the thread it asked for.
  run_bin -1 --separate-stderr team-ui T7 --walk start
  assert_equal "$stderr" "team-ui: T7's walk is on since $since in its interview thread: stop it before starting it in another thread"
  assert_equal "$(walk_events T7)" "on"
  run_bin -0 team-ui T7 --walk stop
  assert_equal "$output" "walk off for T7"
  assert_equal "$(jq -c 'select(.event == "walk" and .state == "off") | del(.ts)' "$TEAM_HOME/ledger.jsonl")" '{"task":"T7","event":"walk","state":"off"}'
  run_bin -0 team-ui T7 --walk start
  assert_equal "$output" "walk on for T7"
  since=$(jq -r 'select(.event == "walk" and .state == "on") | .ts' "$TEAM_HOME/ledger.jsonl" | tail -n 1)
  run_bin -1 --separate-stderr team-ui T7 --walk start --in interview
  assert_equal "$stderr" "team-ui: T7's walk is on since $since in its task thread: stop it before starting it in another thread"
  # The malformed forms.
  run_bin -2 --separate-stderr team-ui T7 --walk stop --in interview
  assert_equal "$stderr" "team-ui: --in goes only with --walk start"
  run_bin -2 --separate-stderr team-ui T7 --walk status --in interview
  assert_equal "$stderr" "team-ui: --in goes only with --walk start"
  run_bin -2 --separate-stderr team-ui T7 --capture --in interview
  assert_equal "$stderr" "team-ui: --in goes only with --walk start"
  run_bin -2 --separate-stderr team-ui T7 --walk start --in task
  assert_equal "$stderr" "team-ui: --in takes only interview, got 'task'"
  run_bin -2 --separate-stderr team-ui T7 --walk start --in
  assert_equal "$stderr" "team-ui: --in takes only interview"
  assert_equal "$(walk_events T7)" "on
off
on"
}

@test "--in interview needs the task's interview thread" {
  run_bin -1 --separate-stderr team-ui T7 --walk start --in interview
  assert_equal "$stderr" "team-ui: T7 has no interview thread in the ledger; team-thread T7 --interview opens one"
  assert_equal "$(walk_events T7)" ""
}

@test "a second interview walk is refused, naming the one that is on, and a walk in a task's thread is not one" {
  interview_thread T7
  open_task T9
  interview_thread T9
  open_task T11
  run_bin -0 team-ui T7 --walk start --in interview
  local since
  since=$(jq -r 'select(.event == "walk") | .ts' "$TEAM_HOME/ledger.jsonl")
  run_bin -1 --separate-stderr team-ui T9 --walk start --in interview
  assert_equal "$stderr" "team-ui: T7's interview walk is on since $since, and Daniel has one Agent Chrome window: team-ui T7 --walk stop ends it"
  assert_equal "$(walk_events T9)" ""
  # A walk the coordinator follows in a task's own thread neither counts nor waits.
  run_bin -0 team-ui T11 --walk start
  assert_equal "$output" "walk on for T11"
  run_bin -1 team-ui T9 --walk start --in interview
  assert_contains "$output" "T7's interview walk is on"
  # Stopped, or ended with its task, it holds nothing.
  run_bin -0 team-ui T7 --walk stop
  run_bin -0 team-ui T9 --walk start --in interview
  jq -cn '{ts: "2026-10-25T11:00:00Z", task: "T9", event: "closed"}' >>"$TEAM_HOME/ledger.jsonl"
  run_bin -0 team-ui T7 --walk start --in interview
}

@test "of several interview walks started at once, one is on" {
  local n
  for n in 21 22 23 24 25 26; do
    open_task "T$n"
    interview_thread "T$n"
  done
  for n in 21 22 23 24 25 26; do
    "$CODE_CHECKOUT/bin/team-ui" "T$n" --walk start --in interview >/dev/null 2>&1 &
  done
  wait
  assert_equal "$(jq -c 'select(.event == "walk")' "$TEAM_HOME/ledger.jsonl" | wc -l)" 1
}

@test "the coordinator's captures are unchanged while a planner's walk is on" {
  interview_thread T7
  open_task T9
  run_bin -0 team-ui T7 --walk start --in interview
  AGENT_TEAM_ROLE=coordinator run_bin -0 team-ui T7 --capture
  AGENT_TEAM_ROLE=coordinator run_bin -0 team-ui T9 --capture
  run_bin -0 team-ui T9 --capture
  assert_equal "$(cat "$STUB_CALLS/ui-capture.log")" "$ui/capture-1
$TEAM_HOME/tasks/T9/ui/capture-1
$TEAM_HOME/tasks/T9/ui/capture-2"
  # The coordinator's note stays where it writes them, in ui/, and says who copied it.
  printf 'check the page\n' >"$ui/.note-1"
  AGENT_TEAM_ROLE=coordinator run_bin -0 team-ui T7 --capture --note-file "$ui/.note-1"
  grep -qF 'as the coordinator copied them' "$ui/capture-2/note.md"
}

@test "a planner's note file must be in its task directory, since its hook refuses writes to ui/" {
  register_conventioner
  interview_thread T7
  run_bin -0 team-ui T7 --walk start --in interview
  local own=$HOME/wt/T7/.scratch/task
  mkdir -p "$own" "$ui"
  printf 'the header is off\n' >"$own/note-1.md"
  AGENT_TEAM_ROLE=planner AGENT_TEAM_TASK=T7 run_bin -0 team-ui T7 --capture --note-file "$own/note-1.md"
  assert_contains "$(cat "$ui/capture-1/note.md")" "the header is off"
  grep -qF 'as the planner copied them' "$ui/capture-1/note.md"

  # Anywhere else is refused before any capture: outside, a link out of it, ui/, and a .. out of it.
  printf 'secret\n' >"$HOME/wt/outside"
  ln -s "$HOME/wt/outside" "$own/link.md"
  printf 'words\n' >"$ui/.note-1"
  local note
  for note in "$HOME/wt/outside" "$own/link.md" "$ui/.note-1" "$own/../../../outside"; do
    AGENT_TEAM_ROLE=planner AGENT_TEAM_TASK=T7 run_bin -1 team-ui T7 --capture --note-file "$note"
    assert_equal "$output" "team-ui: cannot use $note: a worker session's note file must be in T7's task directory"
  done
  assert_equal "$(wc -l <"$STUB_CALLS/ui-capture.log")" 1
  [[ ! -e $ui/capture-2 ]]
}

@test "--help documents --walk, what a walk is for, and that the ledger records it" {
  run_bin -0 team-ui --help
  assert_contains "$output" "Usage: team-ui T<n> [--capture [--note-file <file>]] [--attach <file>]...
       team-ui T<n> --walk start [--in interview [--reseeded <message id>]] | --walk stop | --walk status"
  assert_contains "$output" "manual QC walk"
  assert_contains "$output" "walk event in the ledger"
  assert_contains "$output" "1567568771311337525"
}

# Daniel's message <id> in channel <channel> saying <text>, by <author> (757, the one in allowFrom,
# unless given); the stub answers a read of it, and a read of any other with a 404:
# discord_word <channel> <id> <text> [<author>]
discord_word() {
  export DISCORD_DIR=$BATS_TEST_TMPDIR/discord
  mkdir -p "$DISCORD_DIR"
  echo '{"allowFrom": ["757"]}' >"$HOME/.claude/channels/discord/access.json"
  jq -n --arg id "$2" --arg text "$3" --arg a "${4:-757}" \
    '{id: $id, content: $text, author: {id: $a, username: "daniel"}}' >"$DISCORD_DIR/$1-$2.json"
  stub_script curl <<'EOF'
cat >/dev/null
url=${*: -1}
if [[ $url =~ channels/([0-9]+)/messages/([0-9]+)$ && -f $DISCORD_DIR/${BASH_REMATCH[1]}-${BASH_REMATCH[2]}.json ]]; then
  cat "$DISCORD_DIR/${BASH_REMATCH[1]}-${BASH_REMATCH[2]}.json"
else
  echo "curl: (22) The requested URL returned error: 404" >&2
  exit 22
fi
EOF
}

# A Discord message id sent <seconds> ago (0 unless given): word_id [<seconds>]
word_id() {
  echo $(((($(date +%s) - ${1:-0} - 1420070400) * 1000) << 22))
}

THREAD=1563000000000000009

@test "--reseeded reads Daniel's word back from Discord, logs it on the walk, and the walk's lines say so" {
  interview_thread T7
  local id
  id=$(word_id 60)
  discord_word "$THREAD" "$id" "Just RESEEDED the primary with the fixture."
  run_bin -0 team-ui T7 --walk start --in interview --reseeded "$id"
  local said=", on Daniel's word $id that the primary stack was just reseeded"
  assert_equal "$output" "walk on for T7 in its interview thread$said"
  assert_equal "$(jq -c 'select(.event == "walk") | del(.ts)' "$TEAM_HOME/ledger.jsonl")" \
    "{\"task\":\"T7\",\"event\":\"walk\",\"state\":\"on\",\"thread\":\"interview\",\"reseeded\":\"$id\"}"
  run_bin -0 team-log --check
  # The read went to Discord with the token on stdin, never on the command line.
  assert_contains "$(stub_calls curl)" "channels/$THREAD/messages/$id"
  [[ $(stub_calls curl) != *"$FAKE_DISCORD_TOKEN"* ]]
  local since
  since=$(jq -r 'select(.event == "walk") | .ts' "$TEAM_HOME/ledger.jsonl")
  run_bin -0 team-ui T7 --walk status
  assert_equal "$output" "walk on for T7 since $since in its interview thread$said"
  # A repeat with the same word, or none, changes nothing; another word needs a stop first.
  run_bin -0 team-ui T7 --walk start --in interview --reseeded "$id"
  assert_equal "$output" "walk already on for T7 since $since in its interview thread$said"
  run_bin -0 team-ui T7 --walk start --in interview
  assert_equal "$output" "walk already on for T7 since $since in its interview thread$said"
  run_bin -1 --separate-stderr team-ui T7 --walk start --in interview --reseeded 1567568771311337525
  assert_equal "$stderr" "team-ui: T7's walk is on since $since in its interview thread$said: stop it before starting it on Daniel's word 1567568771311337525"
  assert_equal "$(walk_events T7)" "on"
  # A stop ends the word with the walk: the next on carries none.
  run_bin -0 team-ui T7 --walk stop
  run_bin -0 team-ui T7 --walk start --in interview
  assert_equal "$output" "walk on for T7 in its interview thread"
}

@test "a walk on with no word does not take one by a repeated start, which must not read as cleared" {
  interview_thread T7
  local id
  id=$(word_id)
  discord_word "$THREAD" "$id" "Reseeded."
  run_bin -0 team-ui T7 --walk start --in interview
  run_bin -1 --separate-stderr team-ui T7 --walk start --in interview --reseeded "$id"
  assert_contains "$stderr" "stop it before starting it on Daniel's word $id"
  assert_equal "$(jq -c 'select(.event == "walk" and .reseeded)' "$TEAM_HOME/ledger.jsonl")" ""
  assert_equal "$(stub_calls curl)" ""
}

@test "the word may be in the task's thread or #coordinator" {
  interview_thread T7
  jq -cn '{ts: "2026-10-25T10:02:00Z", task: "T7", event: "thread", discord_thread: "1563000000000000010"}' >>"$TEAM_HOME/ledger.jsonl"
  local id
  id=$(word_id)
  discord_word 1563000000000000010 "$id" "the primary is reseeded"
  run_bin -0 team-ui T7 --walk start --in interview --reseeded "$id"
  run_bin -0 team-ui T7 --walk stop
  id=$(word_id 1)
  export TEAM_COORDINATOR_CHANNEL=1562000000000000001
  discord_word "$TEAM_COORDINATOR_CHANNEL" "$id" "primary reseeded"
  run_bin -0 team-ui T7 --walk start --in interview --reseeded "$id"
  assert_contains "$output" "on Daniel's word $id"
}

@test "--reseeded refuses a word that is not Daniel's, not found, old or silent on seeding, and logs no walk" {
  interview_thread T7
  local id
  id=$(word_id 2)
  discord_word "$THREAD" "$id" "I just reseeded the primary." 999
  run_bin -1 --separate-stderr team-ui T7 --walk start --in interview --reseeded "$id"
  assert_equal "$stderr" "team-ui: Discord message $id is by daniel (999), who is not in allowFrom of ~/.claude/channels/discord/access.json"
  id=$(word_id 3)
  discord_word "$THREAD" "$id" "go with recs."
  run_bin -1 --separate-stderr team-ui T7 --walk start --in interview --reseeded "$id"
  assert_equal "$stderr" "team-ui: Discord message $id does not say the primary stack was reseeded: ask Daniel to say so in a new message"
  id=$(word_id 3700)
  discord_word "$THREAD" "$id" "I just reseeded the primary."
  run_bin -1 --separate-stderr team-ui T7 --walk start --in interview --reseeded "$id"
  assert_contains "$stderr" "team-ui: Discord message $id was sent at "
  assert_contains "$stderr" ", over an hour ago, so it does not say the primary stack was just reseeded: ask Daniel to say so in a new message"
  run_bin -1 --separate-stderr team-ui T7 --walk start --in interview --reseeded "$(word_id 4)"
  assert_contains "$stderr" "cannot be fetched from T7's thread $THREAD or #coordinator"
  rm "$HOME/.claude/channels/discord/access.json"
  run_bin -1 --separate-stderr team-ui T7 --walk start --in interview --reseeded "$id"
  assert_equal "$stderr" "team-ui: cannot read allowFrom from ~/.claude/channels/discord/access.json, so the word that the primary stack was reseeded cannot be checked"
  assert_equal "$(walk_events T7)" ""
}

@test "--reseeded needs a message id and --walk start --in interview, and an interview thread to read it from" {
  run_bin -1 --separate-stderr team-ui T7 --walk start --in interview --reseeded 1567568771311337525
  assert_equal "$stderr" "team-ui: T7 has no interview thread in the ledger; team-thread T7 --interview opens one"
  assert_equal "$(stub_calls curl)" ""
  interview_thread T7
  local form
  for form in "--walk start" "--walk stop" "--walk status" "--capture"; do
    # shellcheck disable=SC2086 # each form is its words
    run_bin -2 --separate-stderr team-ui T7 $form --reseeded 1567568771311337525
    assert_equal "$stderr" "team-ui: --reseeded goes only with --walk start --in interview"
  done
  run_bin -2 --separate-stderr team-ui T7 --walk start --in interview --reseeded
  assert_equal "$stderr" "team-ui: --reseeded needs the id of Daniel's message"
  run_bin -2 --separate-stderr team-ui T7 --walk start --in interview --reseeded soon
  assert_equal "$stderr" "team-ui: --reseeded needs the id of Daniel's message"
  assert_equal "$(walk_events T7)" ""
}
