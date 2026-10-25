#!/usr/bin/env bats
# team-ui: what Daniel pointed at for a UI fix, kept in tasks/T<n>/ui/ (the frontend toolkit's
# capture of the element selected in the Agent Chrome, and the screenshots Daniel attached), and
# named by team-brief in the briefs that follow. ui-capture is a stub in the test's own code
# checkout; its real behaviour is tests/toolkits/frontend.test.mjs's.

load helpers/common

setup() {
  sandbox
  code_checkout
  capture=$CODE_CHECKOUT/toolkits/frontend/scripts/ui-capture
  # The stub capture: writes what the real one writes, or fails with the line in
  # $STUB_FIXTURES/capture-fails, and logs its arguments.
  cat >"$capture" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$STUB_CALLS/ui-capture.log"
if [[ -f $STUB_FIXTURES/capture-fails ]]; then
  echo "ui-capture: $(cat "$STUB_FIXTURES/capture-fails")" >&2
  exit 1
fi
mkdir -p "$1"
printf '# The selected element\n\n- button src/components/PhaseRail.vue:529:13\n' >"$1/ui-pick.md"
printf 'png' >"$1/element.png"
printf 'png' >"$1/page.png"
echo "ui-capture: button \"More...\" at button src/components/PhaseRail.vue:529:13 -> $1/ui-pick.md"
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

@test "--capture runs ui-capture into tasks/T<n>/ui/ and lists what it holds" {
  run_bin -0 --separate-stderr team-ui T7 --capture
  assert_equal "$(cat "$STUB_CALLS/ui-capture.log")" "$ui"
  assert_equal "$output" "ui-capture: button \"More...\" at button src/components/PhaseRail.vue:529:13 -> $ui/ui-pick.md
tasks/T7/ui/ holds:
$ui/element.png
$ui/page.png
$ui/ui-pick.md"
  assert_equal "$stderr" ""
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

@test "a capture that fails keeps the attachments, and says why in one line" {
  echo "no localhost page of the Agent Chrome has DevTools open; right-click the element and Inspect" >"$STUB_FIXTURES/capture-fails"
  run_bin -1 --separate-stderr team-ui T7 --attach "$inbox/1563-screenshot.png" --capture
  assert_equal "$stderr" "team-ui: the capture failed: ui-capture: no localhost page of the Agent Chrome has DevTools open; right-click the element and Inspect"
  assert_equal "$output" "tasks/T7/ui/ holds:
$ui/1563-screenshot.png"
}

@test "the brief that follows names the capture" {
  run_bin -0 team-ui T7 --capture
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
  grep -qF "captured at intake: \`$ui/\` (\`element.png\`, \`page.png\`, \`ui-pick.md\`)" "$TEAM_HOME/tasks/T7/brief.md"
  grep -qF 'never in the Agent Chrome' "$TEAM_HOME/tasks/T7/brief.md"
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
  [[ ! -e $STUB_CALLS/ui-capture.log ]]
}
