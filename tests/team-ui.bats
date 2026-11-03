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

@test "--note keeps Daniel's words and the time beside the capture they go with" {
  echo page >"$STUB_FIXTURES/capture-kind"
  run_bin -0 team-ui T7 --capture --note 'preview import is blocked. check the page state'
  run_bin -0 team-ui T7 --note 'the `Import` button ```stays``` grey' --capture
  [[ ! -e $ui/note.md ]]
  assert_contains "$output" "$ui/capture-2/note.md"
  local note
  note=$(<"$ui/capture-1/note.md")
  [[ $note =~ ^"# Daniel's note"$'\n\n'"Daniel's words this capture goes with, as the coordinator copied them, at "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"."$'\n\n'"\`\`\`"$'\n'"preview import is blocked. check the page state"$'\n'"\`\`\`"$ ]] ||
    { echo "$note" >&2; return 1; }
  # The fence is longer than any run of backticks in the words, so they read as written.
  assert_equal "$(tail -n 3 "$ui/capture-2/note.md")" '````
the `Import` button ```stays``` grey
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
  run_bin -1 --separate-stderr team-ui T7 --attach "$inbox/1563-screenshot.png" --capture --note 'check the page'
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

@test "the brief that follows names each capture with its kind and its note" {
  run_bin -0 team-ui T7 --capture
  echo page >"$STUB_FIXTURES/capture-kind"
  run_bin -0 team-ui T7 --capture --note 'check the page state'
  jq -cn '{ts: "2026-10-25T10:01:00Z", task: "T7", event: "thread", discord_thread: "1563000000000000007"}' >>"$TEAM_HOME/ledger.jsonl"
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
  run_bin -0 team-brief T7 builder-fix --set 'read=- `AGENTS.md`.' --set commits=fix --set goal=g
  local brief=$TEAM_HOME/tasks/T7/brief.md
  grep -qF "captured at intake: \`$ui/\`, each capture in a directory of its own, listed below." "$brief"
  grep -qxF '  - `capture-1/`: an element and page capture.' "$brief"
  grep -qxF '  - `capture-2/`: a page capture, no element selected; `note.md` holds the words Daniel posted with it.' "$brief"
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
  run_bin -2 --separate-stderr team-ui T9 --note 'check the page'
  assert_equal "$stderr" "team-ui: --note goes with --capture"
  run_bin -2 --separate-stderr team-ui T9 --attach "$inbox/notes.txt" --note 'check the page'
  assert_equal "$stderr" "team-ui: --note goes with --capture"
  run_bin -2 --separate-stderr team-ui T9 --capture --note
  assert_equal "$stderr" "team-ui: --note needs the words Daniel posted"
  run_bin -2 --separate-stderr team-ui T9 --capture --note ''
  assert_equal "$stderr" "team-ui: --note needs the words Daniel posted"
  run_bin -2 --separate-stderr team-ui T9 --capture --note a --note b
  assert_equal "$stderr" "team-ui: one --note per capture"
  [[ ! -e $STUB_CALLS/ui-capture.log ]]
  [[ ! -e $TEAM_HOME/tasks/T9/ui ]]
}
