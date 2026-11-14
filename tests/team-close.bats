#!/usr/bin/env bats
# team-close: ending a task only once every worktree has landed and no worker is busy, across a
# git-pool project (home) and a treehouse-pool project (conv, through the fake commands of
# helpers/treehouse). Tasks are opened with the real team-open; launches are hand-written.

load helpers/common
load helpers/treehouse
load helpers/docker
load helpers/inbox

setup() {
  sandbox
  home=$(make_repo home)
  conv=$(make_repo conv)
  ignore_scratch "$home"
  ignore_scratch "$conv"
  home_slots=("$HOME/slots/home/1" "$HOME/slots/home/2")
  conv_slots=("$HOME/.treehouse/conv-abc123/1/conv" "$HOME/.treehouse/conv-abc123/2/conv")
  local slot
  for slot in "${conv_slots[@]}"; do git -C "$conv" worktree add -q --detach "$slot" origin/main; done
  printf '%s\n' "${conv_slots[@]}" >"$BATS_TEST_TMPDIR/free"
  fake_pool_commands "$conv"
  cat >"$TEAM_HOME/projects.toml" <<'TOML'
[home]
repo = "owner/home"
path = "projects/home"
base = "main"
delivery = "direct-pr"
merge_method = "merge"
required_checks = []
task_dir = ".scratch/task"
docs = []
toolkits = []

[home.pool]
provider = "git"
slots = ["slots/home/1", "slots/home/2"]

[conv]
repo = "owner/conv"
path = "projects/conv"
base = "main"
delivery = "no-mistakes"
merge_method = "merge"
required_checks = []
task_dir = ".scratch/task"
docs = []
toolkits = []

[conv.pool]
provider = "treehouse"
lease = "scripts/th-lease.sh"
return = "scripts/th-return.sh"
slots = [".treehouse/conv-abc123/1/conv", ".treehouse/conv-abc123/2/conv"]
TOML
  team_origin=$(make_team_home)
  # team-thread's post answers with the thread's id; team-inbox's calls go to the fake Discord.
  stub_script curl <<'SH'
[[ ! -f $STUB_FIXTURES/inbox.sh ]] || source "$STUB_FIXTURES/inbox.sh"
echo '{"id":"1563000000000000001"}'
SH
  inbox_discord
  sessions
  # claude: agents --json answers the session list; stop and rm note what the archive and the
  # worktrees looked like at the time of the call, so the order of the steps can be checked.
  stub_script claude <<'SH'
case $1 in
  agents) cat "$BATS_TEST_TMPDIR/sessions.json" ;;
  stop | rm)
    echo "$1 $2 archive:$(find "$TEAM_HOME/tasks" -path '*/scratch*' -type f 2>/dev/null | wc -l) worktrees:$(git -C "$HOME/projects/home" worktree list | wc -l)" \
      >>"$BATS_TEST_TMPDIR/order"
    ;;
  *) exit 64 ;;
esac
SH
}

# Commit and push a .gitignore with .scratch/ and .env in the primary checkout <path>.
ignore_scratch() {
  printf '.scratch/\n.env\n' >"$1/.gitignore"
  git -C "$1" add .gitignore
  git -C "$1" commit -q -m "chore: ignore scratch"
  git -C "$1" push -q origin main
}

# session <short id> <name> <status> [<state>]: one background session as claude agents --json
# lists it.
session() {
  jq -cn --arg id "$1" --arg name "$2" --arg status "$3" --arg state "${4:-working}" \
    '{pid: 4242, cwd: "/w/1", kind: "background", startedAt: 1761098400000,
      sessionId: "\($id)-1111-4222-8333-444455556666", name: $name, status: $status, id: $id, state: $state}'
}

# sessions <session JSON>...: the live session list.
sessions() {
  jq -cs . <<<"$*" >"$BATS_TEST_TMPDIR/sessions.json"
}

# ledger_line [jq options...] <filter>: append the line jq builds, standing in for its writer.
ledger_line() {
  jq -cn "$@" >>"$TEAM_HOME/ledger.jsonl"
}

# launch <task> <role> <session> <worktree>
launch() {
  ledger_line --arg t "$1" --arg r "$2" --arg s "$3" --arg wt "$4" \
    '{ts: "2026-10-22T02:10:00Z", task: $t, event: "launch", role: $r, session: $s, worktree: $wt,
      toolkits: []}'
}

events() {
  jq -c --arg e "$1" 'select(.event == $e) | del(.ts)' "$TEAM_HOME/ledger.jsonl"
}

# The claude calls other than reading the session list.
claude_actions() {
  stub_calls claude | jq -c 'select(.[0] != "agents")'
}

# Commit a file in <worktree> and push its branch to origin.
work_and_push() {
  echo "$2" >"$1/$2"
  git -C "$1" add "$2"
  git -C "$1" commit -q -m "feat: $2"
  git -C "$1" push -q origin HEAD
}

@test "a landed git-pool task stops its sessions, archives, removes them, returns the slot and closes" {
  run_bin -0 team-open home feature feat work "Do the work"
  local slot=${home_slots[0]}
  launch T1 planner 1a2b3c4d "$slot"
  launch T1 builder 4f2a9c1e "$slot"
  sessions "$(session 4f2a9c1e T1-builder idle blocked)"
  mkdir -p "$slot/.scratch/task/notes"
  echo "spec" >"$slot/.scratch/task/spec.md"
  echo "note" >"$slot/.scratch/task/notes/01.md"
  echo "SECRET=1" >"$slot/.env"
  work_and_push "$slot" feature.txt
  mkdir -p "$TEAM_HOME/tasks/T1/scratch"
  echo "stale" >"$TEAM_HOME/tasks/T1/scratch/old.md"

  run_bin -0 --separate-stderr team-close T1
  assert_equal "$(jq -c . <<<"$output")" "$(jq -cn --arg wt "$slot" '{task: "T1", stopped: ["4f2a9c1e"],
    removed: ["1a2b3c4d", "4f2a9c1e"], archive: ["tasks/T1/scratch"], returned: [$wt], kept: []}')"

  # Stopped before the archive (only the stale file there), removed after it, both before the
  # slot was returned; the mirror dropped the stale file.
  assert_equal "$(cat "$BATS_TEST_TMPDIR/order")" "stop 4f2a9c1e archive:1 worktrees:2
rm 1a2b3c4d archive:2 worktrees:2
rm 4f2a9c1e archive:2 worktrees:2"
  assert_equal "$(cd "$TEAM_HOME/tasks/T1/scratch" && find . -type f | sort)" "./notes/01.md
./spec.md"
  [[ ! -e $slot ]]
  assert_equal "$(git -C "$home" worktree list | wc -l)" "1"
  git -C "$home" show-ref -q --verify refs/heads/feat/T1-work

  assert_equal "$(events worktree-returned)" "$(jq -cn --arg wt "$slot" \
    '{task: "T1", event: "worktree-returned", project: "home", worktree: $wt, branch: "feat/T1-work"}')"
  assert_equal "$(events closed)" "$(jq -cn --arg wt "$slot" \
    '{task: "T1", event: "closed", archive: ["tasks/T1/scratch"], returned: [$wt], kept: []}')"
  run_bin -0 team-log --check
  run_bin -0 team-state T1
  assert_contains "$output" "closed"
}

@test "the closed and worktree-returned lines are on origin when the close ends" {
  run_bin -0 team-open home feature feat work "Do the work"
  local slot=${home_slots[0]} tip
  work_and_push "$slot" feature.txt
  tip=$(git -C "$team_origin" rev-parse dev)
  run_bin -0 --separate-stderr team-close T1
  [[ $stderr != *"not on origin"* ]]
  assert_equal "$(git -C "$team_origin" rev-parse dev^)" "$tip"
  assert_equal "$(git -C "$team_origin" log -1 --format=%s dev)" "chore: ledger T1 worktree-returned closed"
  assert_equal "$(git -C "$team_origin" diff-tree -r --no-commit-id --name-only dev)" "ledger.jsonl"
  assert_equal "$(git -C "$team_origin" show dev:ledger.jsonl | jq -r .event | tail -n 2)" "worktree-returned
closed"
}

@test "a close takes the task out of waiting.md, and a list team-inbox cannot write is a line on stderr" {
  run_bin -0 team-open home feature feat work "Do the work"
  ledger_line '{ts: "2026-10-22T02:11:00Z", task: "T1", event: "asked", id: "go", text: "Go on?"}'
  run_bin -0 team-inbox
  assert_equal "$(waiting_items_shown | head -n 1)" "- **1** T1 go: Go on? <#1563000000000000001> - unblocks 1 (1 task)"
  run_bin -0 --separate-stderr team-close T1
  [[ $stderr != *"waiting.md"* ]]
  assert_equal "$(waiting_items_shown)" "Nothing waits on you."

  run_bin -0 team-open home feature feat more "Do more"
  waiting_unwritable
  run_bin -0 --separate-stderr team-close T2
  assert_equal "$(tail -n 1 <<<"$stderr")" "team-close: waiting.md is not updated: cannot write $TEAM_HOME/waiting.md: it is a directory"
  assert_equal "$(events closed | jq -r .task)" "T1
T2"
}

# A UI capture (team-ui) stays on the machine that took it and goes with its task, before the
# archive, so no archive or checkpoint carries it.
@test "the task's UI captures in tasks/T<n>/ui/ are removed before the archive" {
  run_bin -0 team-open home feature feat work "Do the work"
  local slot=${home_slots[0]}
  mkdir -p "$slot/.scratch/task" "$TEAM_HOME/tasks/T1/ui" "$TEAM_HOME/tasks/T2/ui"
  echo "spec" >"$slot/.scratch/task/spec.md"
  echo "png" >"$TEAM_HOME/tasks/T1/ui/page.png"
  echo "png" >"$TEAM_HOME/tasks/T2/ui/page.png"
  work_and_push "$slot" feature.txt
  run_bin -0 --separate-stderr team-close T1
  [[ ! -e $TEAM_HOME/tasks/T1/ui ]]
  assert_contains "$stderr" "team-close: removed tasks/T1/ui/, the task's UI captures"
  assert_equal "$(cd "$TEAM_HOME/tasks/T1" && find . -type f | sort)" "./plan.md
./scratch/spec.md"
  # Another task's captures are its own.
  [[ -f $TEAM_HOME/tasks/T2/ui/page.png ]]
}

# The system prompts team-worker generated for the task's sessions, each with a copy of a
# project's instructions, stay on this machine and go with the task.
@test "the task's generated system prompts in the machine's state directory are removed, another task's kept" {
  run_bin -0 team-open home feature feat work "Do the work"
  local slot=${home_slots[0]} prompts=$HOME/.local/state/agent-team/prompts
  mkdir -p "$slot/.scratch/task" "$prompts/T1" "$prompts/T2"
  echo "spec" >"$slot/.scratch/task/spec.md"
  echo "You build." >"$prompts/T1/builder.home.md"
  echo "You plan." >"$prompts/T2/planner.home.md"
  work_and_push "$slot" feature.txt
  run_bin -0 --separate-stderr team-close T1
  [[ ! -e $prompts/T1 ]]
  assert_contains "$stderr" "team-close: removed ~/.local/state/agent-team/prompts/T1/, the system prompts team-worker generated for the task's sessions"
  [[ -f $prompts/T2/planner.home.md ]]
}

# What team-thread wait saves from an interview goes the same way.
@test "an image team-thread wait saved goes with the task's captures, and into no archive" {
  run_bin -0 team-open home feature feat work "Do the work"
  local slot=${home_slots[0]} saved
  mkdir -p "$slot/.scratch/task"
  echo "spec" >"$slot/.scratch/task/spec.md"
  work_and_push "$slot" feature.txt
  echo '{"ts":"2026-10-01T10:00:02Z","task":"T1","event":"interview-thread","discord_thread":"5555"}' >>"$TEAM_HOME/ledger.jsonl"
  echo '{"allowFrom": ["757"], "groups": {}}' >"$HOME/.claude/channels/discord/access.json"
  export SKETCH=$BATS_TEST_TMPDIR/sketch.png
  printf '\x89PNG\r\n\x1a\nsketch' >"$SKETCH"
  stub_script curl <<'EOF'
url=${*: -1}
if [[ $url == https://cdn.discordapp.com/* ]]; then
  for ((i = 1; i < $#; i++)); do [[ ${!i} != -o ]] || { j=$((i + 1)); cp "$SKETCH" "${!j}"; }; done
elif [[ $url == *'/channels/5555/messages?'* ]]; then
  for ((i = 1; i < $#; i++)); do [[ ${!i} != -D ]] || { j=$((i + 1)); printf 'HTTP/2 200\r\n\r\n' >"${!j}"; }; done
  echo '[{"id":"1564000000000000001","content":"this","timestamp":"2026-10-29T11:00:00.000000+00:00","author":{"id":"757"},"attachments":[{"filename":"sketch.png","url":"https://cdn.discordapp.com/attachments/5555/1/sketch.png"}]}]'
else
  echo '{}'
fi
EOF
  run_bin -0 team-thread wait T1
  saved=$(jq -r '.attachments[0].saved' <<<"$output")
  assert_equal "$saved" "$TEAM_HOME/tasks/T1/ui/sketch.png"
  cmp "$SKETCH" "$saved"
  run_bin -0 --separate-stderr team-close T1
  [[ ! -e $TEAM_HOME/tasks/T1/ui ]]
  assert_contains "$stderr" "team-close: removed tasks/T1/ui/, the task's UI captures"
  assert_equal "$(find "$TEAM_HOME/tasks/T1" -name '*.png' | wc -l)" "0"
}

# Screenshots a project keeps outside the task directory go with the worktree that took them, and
# treehouse leaves what git ignores in a slot it takes back.
@test "a returned treehouse slot loses its .scratch/shots/, and another task's slot keeps its own" {
  run_bin -0 team-open conv feature feat move "Move it"
  run_bin -0 team-open conv feature feat other "Other work"
  local slot=${conv_slots[0]} other=${conv_slots[1]}
  mkdir -p "$slot/.scratch/shots/builder/after" "$other/.scratch/shots"
  echo png >"$slot/.scratch/shots/builder/after/page.png"
  echo png >"$other/.scratch/shots/page.png"
  echo keep >"$slot/.scratch/notes.md"
  work_and_push "$slot" move.txt
  run_bin -0 --separate-stderr team-close T1
  [[ ! -e $slot/.scratch/shots ]]
  assert_contains "$stderr" "team-close: removed .scratch/shots/ of $slot"
  # Only that folder: what else the project keeps in .scratch/ is not the team's to remove.
  [[ -f $slot/.scratch/notes.md ]]
  [[ -f $other/.scratch/shots/page.png ]]
  # And none of it reached the archive.
  assert_equal "$(find "$TEAM_HOME/tasks/T1" -name '*.png' | wc -l)" "0"
}

@test "a returned git worktree takes its .scratch/shots/ with it" {
  run_bin -0 team-open home feature feat work "Do the work"
  local slot=${home_slots[0]}
  mkdir -p "$slot/.scratch/shots"
  echo png >"$slot/.scratch/shots/page.png"
  work_and_push "$slot" feature.txt
  run_bin -0 --separate-stderr team-close T1
  [[ ! -e $slot ]]
  assert_contains "$stderr" "team-close: removed .scratch/shots/ of $slot"
}

@test "a kept worktree keeps its .scratch/shots/, and the worktree returned beside it does not" {
  run_bin -0 team-open home feature feat work "Do the work"
  run_bin -0 team-open --task T1 --add conv feat move
  local kept=${home_slots[0]} returned=${conv_slots[0]}
  mkdir -p "$kept/.scratch/shots" "$returned/.scratch/shots"
  echo png >"$kept/.scratch/shots/page.png"
  echo png >"$returned/.scratch/shots/page.png"
  echo unpushed >"$kept/unpushed.txt"
  work_and_push "$returned" move.txt
  run_bin -0 --separate-stderr team-close T1 --keep-worktree
  [[ -f $kept/.scratch/shots/page.png ]]
  [[ $stderr != *"of $kept"* ]]
  [[ ! -e $returned/.scratch/shots ]]
  assert_equal "$(events closed | jq -c .kept)" "$(jq -cn --arg k "$kept" '[$k]')"
}

# A link in the slot may point anywhere, another slot's folders included: only the link is the
# slot's own, so a close never removes through it.
@test "a slot whose .scratch is a link leaves the folders it points at, and says so" {
  run_bin -0 team-open conv feature feat move "Move it"
  run_bin -0 team-open conv feature feat other "Other work"
  local slot=${conv_slots[0]} other=${conv_slots[1]}
  mkdir -p "$other/.scratch/shots"
  echo png >"$other/.scratch/shots/page.png"
  echo plan >"$other/.scratch/task/spec.md"
  rm -r "$slot/.scratch"
  ln -s "$other/.scratch" "$slot/.scratch"
  echo .scratch >>"$(git -C "$slot" rev-parse --git-path info/exclude)"
  work_and_push "$slot" move.txt
  run_bin -0 --separate-stderr team-close T1
  [[ -f $other/.scratch/shots/page.png ]]
  [[ -f $other/.scratch/task/spec.md ]]
  assert_contains "$stderr" "team-close: left .scratch/shots/ of $slot: .scratch is a link, to what may be another worktree's"
  assert_contains "$stderr" "team-close: left .scratch/task of $slot: .scratch is a link, to what may be another worktree's"
  [[ $stderr != *"removed .scratch/shots/"* ]]
  assert_equal "$(events closed | jq -c .returned)" "$(jq -cn --arg s "$slot" '[$s]')"
}

@test "a slot whose .scratch/shots is itself a link loses the link and keeps what it points at" {
  run_bin -0 team-open conv feature feat move "Move it"
  local slot=${conv_slots[0]} target=$BATS_TEST_TMPDIR/elsewhere
  mkdir -p "$target"
  echo png >"$target/page.png"
  ln -s "$target" "$slot/.scratch/shots"
  work_and_push "$slot" move.txt
  run_bin -0 --separate-stderr team-close T1
  [[ ! -e $slot/.scratch/shots && ! -L $slot/.scratch/shots ]]
  [[ -f $target/page.png ]]
  assert_contains "$stderr" "team-close: removed .scratch/shots/ of $slot"
}

# Each step a stopped close already took is one its rerun finds done.
@test "a close stopped by a failed return removes the rest on its rerun" {
  run_bin -0 team-open conv feature feat move "Move it"
  local slot=${conv_slots[0]} return_script=$conv/scripts/th-return.sh
  mkdir -p "$slot/.scratch/shots"
  echo png >"$slot/.scratch/shots/page.png"
  work_and_push "$slot" move.txt
  mv "$return_script" "$return_script.real"
  cat >"$return_script" <<'SH'
#!/usr/bin/env bash
echo "the pool is busy" >&2
exit 3
SH
  chmod +x "$return_script"
  run_bin -1 --separate-stderr team-close T1
  assert_contains "$stderr" "T1 is half closed"
  [[ ! -e $slot/.scratch/shots ]]
  assert_equal "$(events worktree-returned)$(events closed)" ""
  # A folder made since goes on the rerun, which then finishes.
  mkdir -p "$slot/.scratch/shots"
  echo png >"$slot/.scratch/shots/late.png"
  mv "$return_script.real" "$return_script"
  run_bin -0 --separate-stderr team-close T1
  [[ ! -e $slot/.scratch/shots ]]
  assert_equal "$(events closed | jq -c .returned)" "$(jq -cn --arg s "$slot" '[$s]')"
}

# The work has landed by now, so a folder that will not go must not stop the slot's return, and
# the doctor's captures line names it from then on.
@test "a .scratch/shots/ that cannot be removed is reported, and the close still finishes" {
  run_bin -0 team-open conv feature feat move "Move it"
  local slot=${conv_slots[0]}
  mkdir -p "$slot/.scratch/shots/locked"
  echo png >"$slot/.scratch/shots/locked/page.png"
  work_and_push "$slot" move.txt
  chmod a-w "$slot/.scratch/shots/locked"
  run_bin -0 --separate-stderr team-close T1
  chmod u+w "$slot/.scratch/shots/locked"
  assert_contains "$stderr" "team-close: cannot remove .scratch/shots/ of $slot ("
  assert_contains "$stderr" "); team-doctor's captures line names it until it is gone"
  [[ $stderr != *"removed .scratch/shots/"* ]]
  assert_equal "$(events closed | jq -c .returned)" "$(jq -cn --arg s "$slot" '[$s]')"
}

@test "the archive leaves out a UI capture, nested repositories, files over 1 MiB and names that may hold a secret, each named" {
  run_bin -0 team-open home feature feat work "Do the work"
  local slot=${home_slots[0]}
  local dir=$slot/.scratch/task
  echo "notes" >"$dir/notes.md"
  git init -q "$dir/clone"
  echo "tool" >"$dir/clone/tool.txt"
  head -c 2M /dev/zero >"$dir/big.bin"
  echo "SECRET=1" >"$dir/.env.local"
  # A frontend capture made in the task directory stays on this machine, whatever it holds.
  mkdir -p "$dir/ui/deep"
  echo "pick" >"$dir/ui/ui-pick.md"
  head -c 2M /dev/zero >"$dir/ui/deep/page.png"
  work_and_push "$slot" feature.txt

  run_bin -0 --separate-stderr team-close T1
  assert_equal "$stderr" "team-close: left out of tasks/T1/scratch: ui (UI capture)
team-close: left out of tasks/T1/scratch: clone (nested repository)
team-close: left out of tasks/T1/scratch: big.bin (over 1 MiB)
team-close: left out of tasks/T1/scratch: .env.local (may hold a secret)"
  assert_equal "$(jq -c .archive <<<"$output")" '["tasks/T1/scratch"]'
  assert_equal "$(cd "$TEAM_HOME/tasks/T1/scratch" && find . -mindepth 1 | sort)" "./notes.md"
}

@test "the archive leaves out bare repositories, dependency trees, directories of over 200 files and links, each named" {
  run_bin -0 team-open home feature feat work "Do the work"
  local slot=${home_slots[0]}
  local dir=$slot/.scratch/task
  echo "notes" >"$dir/notes.md"
  git init -q --bare "$dir/scan.git"
  mkdir -p "$dir/node_modules/a" "$dir/trial/front-end" "$dir/py/__pycache__" "$dir/kept"
  touch "$dir/node_modules/a/1.js" "$dir/node_modules/a/2.js" "$dir/node_modules/3.js" "$dir/py/__pycache__/m.pyc"
  touch "$dir/trial/front-end/"{1..201}.ts "$dir/kept/"{1..200}.txt
  echo "trial notes" >"$dir/trial/notes.md"
  ln -s ../../front-end/node_modules "$dir/deps"
  work_and_push "$slot" feature.txt

  run_bin -0 --separate-stderr team-close T1
  assert_equal "$stderr" "team-close: left out of tasks/T1/scratch: scan.git (nested repository)
team-close: left out of tasks/T1/scratch: node_modules (dependencies)
team-close: left out of tasks/T1/scratch: py/__pycache__ (dependencies)
team-close: left out of tasks/T1/scratch: trial/front-end (over 200 files)
team-close: left out of tasks/T1/scratch: deps (link)"
  # The innermost crowded directory is left out, so trial/ keeps what else it holds.
  assert_equal "$(cd "$TEAM_HOME/tasks/T1/scratch" && find . -mindepth 1 -not -path './kept/*' | sort)" "./kept
./notes.md
./py
./trial
./trial/notes.md"
  assert_equal "$(find "$TEAM_HOME/tasks/T1/scratch/kept" -type f | wc -l)" "200"
}

@test "the archive leaves out videos, Playwright output and build output, each named, and keeps a research task's probes" {
  run_bin -0 team-open home feature feat work "Do the work"
  local slot=${home_slots[0]}
  local dir=$slot/.scratch/task
  mkdir -p "$dir/work/probes" "$dir/work/tmp/pytest-of-u" "$dir/sweep-out/login" "$dir/test-results/login" \
    "$dir/baseline/dist/assets"
  # The probes the report's tickets cite, beside the files a test's TMPDIR left in work/tmp/.
  echo "def test_half_state(): pass" >"$dir/work/probes/acct_test_import_halfstate.py"
  echo "# Report" >"$dir/report.md"
  touch "$dir/work/tmp/pytest-of-u/"{1..201}
  printf '\x1a\x45\xdf\xa3webm' >"$dir/sweep-out/login/video.webm"
  echo "zip" >"$dir/test-results/login/trace.zip"
  echo "var a=1" >"$dir/baseline/dist/assets/index-Bgg7i7NB.js"
  echo "font" >"$dir/baseline/dist/assets/Inter.ttf"
  work_and_push "$slot" feature.txt

  run_bin -0 --separate-stderr team-close T1
  assert_equal "$stderr" "team-close: left out of tasks/T1/scratch: work/tmp/pytest-of-u (over 200 files)
team-close: left out of tasks/T1/scratch: sweep-out/login/video.webm (video)
team-close: left out of tasks/T1/scratch: test-results (Playwright output)
team-close: left out of tasks/T1/scratch: baseline/dist (build output)"
  assert_equal "$(cd "$TEAM_HOME/tasks/T1/scratch" && find . -type f | sort)" "./report.md
./work/probes/acct_test_import_halfstate.py"
}

@test "the archive leaves out every image anywhere in the task directory, named, and keeps the text beside it" {
  run_bin -0 team-open home feature feat work "Do the work"
  local slot=${home_slots[0]}
  local dir=$slot/.scratch/task
  mkdir -p "$dir/ui-check/builder-abc1234"
  echo "findings" >"$dir/ui-check/builder-abc1234/findings.md"
  echo "png" >"$dir/ui-check/builder-abc1234/result-1920x1080.png"
  # A large screenshot is an image first, and the extension is matched in any case.
  head -c 2M /dev/zero >"$dir/ui-check/builder-abc1234/result-1920x1080-2.PNG"
  echo "jpeg" >"$dir/photo.Jpeg"
  work_and_push "$slot" feature.txt

  run_bin -0 --separate-stderr team-close T1
  assert_equal "$stderr" "team-close: left out of tasks/T1/scratch: photo.Jpeg (image)
team-close: left out of tasks/T1/scratch: ui-check/builder-abc1234/result-1920x1080-2.PNG (image)
team-close: left out of tasks/T1/scratch: ui-check/builder-abc1234/result-1920x1080.png (image)"
  assert_equal "$(cd "$TEAM_HOME/tasks/T1/scratch" && find . -mindepth 1 | sort)" "./ui-check
./ui-check/builder-abc1234
./ui-check/builder-abc1234/findings.md"
}

@test "the archive leaves out a ui-check run's Lighthouse reports and keeps the run's text" {
  run_bin -0 team-open home feature feat work "Do the work"
  local slot=${home_slots[0]}
  local run=$slot/.scratch/task/ui-check/builder-abc1234
  mkdir -p "$run/lighthouse/result" "$run/lighthouse/menu-open"
  echo "findings" >"$run/findings.md"
  echo "{}" >"$run/lighthouse/result/report.json"
  echo "<html>" >"$run/lighthouse/result/report.html"
  echo "{}" >"$run/lighthouse/menu-open/report.json"
  # Only a run's own lighthouse/ is a report directory.
  mkdir -p "$slot/.scratch/task/notes/lighthouse"
  echo "notes" >"$slot/.scratch/task/notes/lighthouse/scores.md"
  work_and_push "$slot" feature.txt

  run_bin -0 --separate-stderr team-close T1
  assert_equal "$stderr" "team-close: left out of tasks/T1/scratch: ui-check/builder-abc1234/lighthouse (Lighthouse reports)"
  assert_equal "$(cd "$TEAM_HOME/tasks/T1/scratch" && find . -mindepth 1 | sort)" "./notes
./notes/lighthouse
./notes/lighthouse/scores.md
./ui-check
./ui-check/builder-abc1234
./ui-check/builder-abc1234/findings.md"
}

# rehome_ledger <home>: the ledger as another machine with home <home> wrote it, its recorded
# worktree paths under that home instead of this HOME.
rehome_ledger() {
  jq -c --arg home "$HOME" --arg other "$1" \
    'if (.worktree // "" | startswith("\($home)/")) then .worktree |= $other + .[($home | length):] else . end' \
    "$TEAM_HOME/ledger.jsonl" >"$BATS_TEST_TMPDIR/ledger"
  cp "$BATS_TEST_TMPDIR/ledger" "$TEAM_HOME/ledger.jsonl"
}

@test "a task whose worktree was recorded under another home closes this machine's slot" {
  run_bin -0 team-open home feature feat work "Do the work"
  local slot=${home_slots[0]}
  # The task was opened on another machine, whose home is /home/someone.
  rehome_ledger /home/someone
  assert_equal "$(events opened | jq -r .worktree)" "/home/someone/slots/home/1"
  launch T1 builder 4f2a9c1e /Users/someone/slots/home/1
  sessions "$(session 4f2a9c1e T1-builder idle)"
  echo "spec" >"$slot/.scratch/task/spec.md"
  work_and_push "$slot" feature.txt

  run_bin -0 --separate-stderr team-close T1
  assert_equal "$(jq -c .returned <<<"$output")" "$(jq -cn --arg wt "$slot" '[$wt]')"
  assert_equal "$(cat "$TEAM_HOME/tasks/T1/scratch/spec.md")" "spec"
  [[ ! -e $slot ]]
  assert_equal "$(events worktree-returned | jq -r .worktree)" "$slot"
  assert_equal "$(events opened | jq -r .worktree)" "/home/someone/slots/home/1"
  run_bin -0 team-log --check
}

@test "a task whose worktree moved on another machine's resume closes the slot it moved to" {
  run_bin -0 team-open home feature feat work "Do the work"
  rehome_ledger /home/someone
  local slot=${home_slots[1]}
  # This machine's resume found the recorded slot taken and moved the task to the next one.
  git -C "$home" worktree move "${home_slots[0]}" "$slot"
  ledger_line --arg wt "$slot" '{ts: "2026-10-22T02:00:00Z", task: "T1", event: "worktree-moved", project: "home",
    branch: "feat/T1-work", from: "/home/someone/slots/home/1", worktree: $wt, machine: "laptop"}'
  echo "spec" >"$slot/.scratch/task/spec.md"
  work_and_push "$slot" feature.txt

  run_bin -0 --separate-stderr team-close T1
  assert_equal "$(jq -c .returned <<<"$output")" "$(jq -cn --arg wt "$slot" '[$wt]')"
  assert_equal "$(cat "$TEAM_HOME/tasks/T1/scratch/spec.md")" "spec"
  [[ ! -e $slot ]]
  assert_equal "$(events worktree-returned | jq -r .worktree)" "$slot"
  run_bin -0 team-log --check
  stub_reply claude "[]"
  run_bin -0 team-state T1 --json
  assert_equal "$(jq -c .worktrees <<<"$output")" "$(jq -cn --arg wt "$slot" \
    '[{project: "home", branch: "feat/T1-work", worktree: $wt, ticket: null, returned: true}]')"
}

# open_home_task: T1 open in the first home slot with a builder launched and live, its task
# directory holding a spec; remembers the ledger so assert_unchanged can compare.
open_home_task() {
  run_bin -0 team-open home feature feat work "Do the work"
  wt=${home_slots[0]}
  launch T1 builder 4f2a9c1e "$wt"
  sessions "$(session 4f2a9c1e T1-builder idle blocked)"
  echo "spec" >"$wt/.scratch/task/spec.md"
  remember_before
}

# The home project's registered worktrees.
home_worktrees() {
  git -C "$home" worktree list --porcelain | grep '^worktree '
}

# Remember the ledger and the home worktrees for assert_unchanged.
remember_before() {
  cp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/ledger.before"
  home_worktrees >"$BATS_TEST_TMPDIR/worktrees.before"
}

# Nothing changed: no session stopped or removed, nothing archived, no ledger line, the slot kept.
assert_unchanged() {
  assert_equal "$(claude_actions)" ""
  [[ ! -e $TEAM_HOME/tasks/T1/scratch ]]
  cmp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/ledger.before"
  [[ -f $wt/.scratch/task/spec.md ]]
  assert_equal "$(home_worktrees)" "$(cat "$BATS_TEST_TMPDIR/worktrees.before")"
}

@test "unpushed commits refuse the close and change nothing" {
  open_home_task
  work_and_push "$wt" pushed.txt
  echo one >"$wt/a.txt"
  git -C "$wt" add a.txt
  git -C "$wt" commit -q -m "feat: a"
  echo two >"$wt/b.txt"
  git -C "$wt" add b.txt
  git -C "$wt" commit -q -m "feat: b"
  stub_reply gh '[]'

  run_bin -1 team-close T1
  assert_contains "$output" "team-close: T1 cannot close, so nothing changed:"
  assert_contains "$output" "$wt (home, feat/T1-work) has not landed: head $(git -C "$wt" rev-parse --short=7 HEAD) is on no branch of origin (2 commits not pushed) and is not the head of a merged PR"
  assert_contains "$output" "--keep-worktree"
  assert_equal "$(stub_calls gh)" '["pr","list","--repo","owner/home","--head","feat/T1-work","--state","merged","--json","number,headRefOid"]'
  assert_unchanged
}

@test "a head held only by a snapshot or salvage branch on origin has not landed" {
  open_home_task
  work_and_push "$wt" pushed.txt
  echo one >"$wt/a.txt"
  git -C "$wt" add a.txt
  git -C "$wt" commit -q -m "feat: a"
  # A project whose origin is the team home's (agent-team until the split) fetches the team's
  # snapshots and salvages with its branches; none of them is where the work landed.
  git -C "$wt" push -q origin HEAD:refs/heads/wip/agent-team/T1 HEAD:refs/heads/wip/T1 \
    HEAD:refs/heads/salvage/agent-team/T1-laptop
  stub_reply gh '[]'

  run_bin -1 team-close T1
  assert_contains "$output" "$wt (home, feat/T1-work) has not landed: head $(git -C "$wt" rev-parse --short=7 HEAD) is on no branch of origin (1 commit not pushed) and is not the head of a merged PR"
  assert_equal "$(git -C "$wt" for-each-ref --contains HEAD --format='%(refname)' refs/remotes/origin | paste -sd ,)" \
    "refs/remotes/origin/salvage/agent-team/T1-laptop,refs/remotes/origin/wip/T1,refs/remotes/origin/wip/agent-team/T1"
  assert_unchanged
}

@test "an uncommitted change refuses the close and changes nothing" {
  open_home_task
  echo changed >>"$wt/README.md"

  run_bin -1 team-close T1
  assert_contains "$output" "$wt (home, feat/T1-work) has not landed: changes to tracked files: README.md"
  assert_equal "$(stub_calls gh)" ""
  assert_unchanged
}

@test "an untracked file refuses the close, while ignored files are fine" {
  open_home_task
  mkdir -p "$wt/src"
  echo new >"$wt/src/new.txt"
  echo "SECRET=1" >"$wt/.env"

  run_bin -1 team-close T1
  assert_contains "$output" "$wt (home, feat/T1-work) has not landed: untracked files: src/new.txt"
  [[ $output != *".env"* ]]
  [[ $output != *".scratch"* ]]
  assert_unchanged
}

@test "a research worktree with no commits of its own has landed at origin's base" {
  run_bin -0 team-open home research research look-around "Look around"
  local slot=${home_slots[0]}
  echo "report" >"$slot/.scratch/task/report.md"
  advance_origin home "moved on"

  run_bin -0 team-close T1
  assert_equal "$(cat "$TEAM_HOME/tasks/T1/scratch/report.md")" "report"
  [[ ! -e $slot ]]
  assert_equal "$(stub_calls gh)" ""
  assert_equal "$(events closed | jq -c '[.returned, .kept]')" "$(jq -cn --arg wt "$slot" '[[$wt], []]')"
}

# Push a commit to <project>'s origin main from a second clone.
advance_origin() {
  local other=$BATS_TEST_TMPDIR/other-$1
  [[ -d $other ]] || git clone -q "$BATS_TEST_TMPDIR/origin/$1.git" "$other" 2>/dev/null
  git -C "$other" pull -q
  git -C "$other" commit -q --allow-empty -m "feat: $2"
  git -C "$other" push -q origin main
}

# Squash-merge <worktree>'s pushed branch <branch> into origin main and delete the branch on
# origin, so the worktree's head is on no branch of origin.
squash_merge() {
  local other=$BATS_TEST_TMPDIR/other-home
  [[ -d $other ]] || git clone -q "$BATS_TEST_TMPDIR/origin/home.git" "$other" 2>/dev/null
  git -C "$other" fetch -q origin
  git -C "$other" merge -q --squash "origin/$2" >/dev/null
  git -C "$other" commit -q -m "feat: the work (#7)"
  git -C "$other" push -q origin main ":$2"
}

@test "the landed check fetches origin first, so a head pushed from elsewhere counts" {
  open_home_task
  echo one >"$wt/a.txt"
  git -C "$wt" add a.txt
  git -C "$wt" commit -q -m "feat: a"
  # Pushed, but this checkout's remote-tracking ref is gone, as on a machine that never fetched it.
  git -C "$wt" push -q origin HEAD
  git -C "$wt" update-ref -d refs/remotes/origin/feat/T1-work
  [[ -z $(git -C "$wt" branch -r --contains HEAD) ]]

  run_bin -0 team-close T1
  [[ ! -e $wt ]]
  assert_equal "$(stub_calls gh)" ""
}

@test "a branch deleted on origin without a merge has not landed, though this checkout still has its ref" {
  open_home_task
  work_and_push "$wt" feature.txt
  git -C "$BATS_TEST_TMPDIR/origin/home.git" branch -q -D feat/T1-work
  git -C "$wt" rev-parse -q --verify refs/remotes/origin/feat/T1-work
  stub_reply gh '[]'

  run_bin -1 team-close T1
  assert_contains "$output" "is on no branch of origin (1 commit not pushed) and is not the head of a merged PR"
  assert_unchanged
}

@test "a squash-merged head on no branch of origin has landed as a merged PR's head" {
  open_home_task
  work_and_push "$wt" feature.txt
  squash_merge "$wt" feat/T1-work
  [[ -z $(git -C "$BATS_TEST_TMPDIR/origin/home.git" branch --contains "$(git -C "$wt" rev-parse HEAD)") ]]
  stub_reply gh "$(jq -cn --arg head "$(git -C "$wt" rev-parse HEAD)" '[{number: 7, headRefOid: $head}]')"

  run_bin -0 team-close T1
  [[ ! -e $wt ]]
  assert_equal "$(events closed | jq -c .returned)" "$(jq -cn --arg wt "$wt" '[$wt]')"
}

@test "a squash-merged branch whose merged PR had another head has not landed" {
  open_home_task
  work_and_push "$wt" feature.txt
  squash_merge "$wt" feat/T1-work
  stub_reply gh '[{"number": 7, "headRefOid": "0123456789abcdef0123456789abcdef01234567"}]'

  run_bin -1 team-close T1
  assert_contains "$output" "is on no branch of origin (1 commit not pushed) and is not the head of a merged PR"
  assert_unchanged
}

@test "GitHub down while a head is on no branch of origin refuses the close" {
  open_home_task
  work_and_push "$wt" feature.txt
  squash_merge "$wt" feat/T1-work
  stub_script gh <<'SH'
echo "error connecting to api.github.com" >&2
exit 1
SH

  run_bin -1 team-close T1
  assert_contains "$output" "GitHub cannot tell whether a PR merged it (gh pr list: error connecting to api.github.com)"
  assert_unchanged
}

@test "--keep-worktree closes with an unlanded worktree kept and archived" {
  open_home_task
  echo changed >>"$wt/README.md"

  run_bin -0 --separate-stderr team-close T1 --keep-worktree
  assert_equal "$(jq -c '[.returned, .kept]' <<<"$output")" "$(jq -cn --arg wt "$wt" '[[], [$wt]]')"
  assert_equal "$(cat "$TEAM_HOME/tasks/T1/scratch/spec.md")" "spec"
  assert_equal "$(git -C "$wt" diff --name-only)" "README.md"
  [[ -f $wt/.scratch/task/spec.md ]]
  assert_equal "$(events worktree-returned)" ""
  assert_equal "$(events closed)" "$(jq -cn --arg wt "$wt" \
    '{task: "T1", event: "closed", archive: ["tasks/T1/scratch"], returned: [], kept: [$wt]}')"
  assert_equal "$(claude_actions)" '["stop","4f2a9c1e"]
["rm","4f2a9c1e"]'
}

# The stack teardown, on the stub docker (helpers/docker): home_stack gives home a stack block
# naming the fixture wrapper (tests/fixtures/stack/), committed on origin's main so the slot
# team-open makes has it, and installs the stub docker. The slot's stack is stackfix-1.
home_stack() {
  mkdir -p "$home/scripts"
  cp "$REPO_ROOT/tests/fixtures/stack/compose.sh" "$home/scripts/compose.sh"
  cp "$REPO_ROOT/tests/fixtures/stack/docker-compose.yml" "$home/docker-compose.yml"
  git -C "$home" add scripts docker-compose.yml
  git -C "$home" commit -q -m "feat: add the stack"
  git -C "$home" push -q origin main
  cat >>"$TEAM_HOME/projects.toml" <<'TOML'

[home.stack]
compose = "scripts/compose.sh"
seed = "scripts/seed.sh"
log_services = ["web"]
TOML
  docker_stub "${home_slots[0]}"
}

# Whether Docker holds any object of the Compose project <project>.
stack_exists() {
  jq -e --arg p "$1" 'any(.[]; .Config.Labels["com.docker.compose.project"] == $p or .Labels["com.docker.compose.project"] == $p)' \
    <(jq -s 'add' "$DOCKER_STATE/containers.json" "$DOCKER_STATE/volumes.json" "$DOCKER_STATE/networks.json") >/dev/null
}

# Whether Docker holds no object of the Compose project <project> (a function, so that bats
# counts its status, as it does not a bare !).
stack_gone() {
  ! stack_exists "$1"
}

@test "a returned worktree's stack and its instances are taken down before the archive, which leaves their logs out" {
  home_stack
  open_home_task
  run_bin -0 team-stack up --worktree "$wt" --no-seed
  run_bin -0 team-stack up --worktree "$wt" --instance a --no-seed
  stack_exists stackfix-1
  stack_exists stackfix-1-a
  work_and_push "$wt" feature.txt

  run_bin -0 --separate-stderr team-close T1
  assert_contains "$stderr" "team-stack: stackfix-1-a is removed, its logs in $wt/.scratch/task/stack-logs
team-stack: stackfix-1 is removed, its logs in $wt/.scratch/task/stack-logs"
  assert_contains "$(docker_calls)" "compose -p stackfix-1 down -v --remove-orphans"
  assert_contains "$(docker_calls)" "compose -p stackfix-1-a down -v --remove-orphans"
  stack_gone stackfix-1
  stack_gone stackfix-1-a
  assert_contains "$stderr" "team-close: left out of tasks/T1/scratch: stack-logs (stack logs)"
  [[ ! -e $TEAM_HOME/tasks/T1/scratch/stack-logs ]]
  assert_equal "$(jq -c .returned <<<"$output")" "$(jq -cn --arg wt "$wt" '[$wt]')"
}

@test "a project without a stack block closes with no Docker call at all" {
  docker_stub "${home_slots[0]}"
  open_home_task
  work_and_push "$wt" feature.txt
  # team-open's reading of the machine's load read Docker; the close reads nothing more.
  local calls
  calls=$(stub_calls docker | wc -l)
  run_bin -0 team-close T1
  assert_equal "$(stub_calls docker | wc -l)" "$calls"
}

@test "a worktree kept with --keep-worktree keeps its stack" {
  home_stack
  open_home_task
  run_bin -0 team-stack up --worktree "$wt" --no-seed
  local calls
  calls=$(stub_calls docker | wc -l)
  echo changed >>"$wt/README.md"

  run_bin -0 team-close T1 --keep-worktree
  assert_equal "$(stub_calls docker | wc -l)" "$calls"
  stack_exists stackfix-1
}

@test "a failed stack teardown stops the close half closed, and a second close after the fix completes" {
  home_stack
  open_home_task
  run_bin -0 team-stack up --worktree "$wt" --no-seed
  work_and_push "$wt" feature.txt
  docker_fail 'compose down' 'Error response from daemon: a stand-in failure'

  run_bin -1 --separate-stderr team-close T1
  assert_contains "$stderr" "team-stack: docker compose down of stackfix-1 failed: Error response from daemon: a stand-in failure"
  assert_contains "$stderr" "team-close: cannot take down the stack of $wt (home)"
  assert_contains "$stderr" "T1 is half closed; fix the cause above and run team-close T1 again"
  [[ ! -e $TEAM_HOME/tasks/T1/scratch ]]
  [[ -d $wt ]]
  assert_equal "$(events worktree-returned)$(events closed)" ""
  stack_exists stackfix-1

  rm "$DOCKER_STATE/fail-compose-down"
  run_bin -0 team-close T1
  stack_gone stackfix-1
  [[ ! -e $TEAM_HOME/tasks/T1/scratch/stack-logs ]]
  [[ ! -e $wt ]]
  assert_equal "$(events closed | jq -c .returned)" "$(jq -cn --arg wt "$wt" '[$wt]')"
}

@test "a busy session refuses the close; --stop-busy stops it, and other tasks' sessions are never touched" {
  open_home_task
  work_and_push "$wt" feature.txt
  run_bin -0 team-open home feature feat other "Other work"
  launch T2 builder 9e8d7c6b "${home_slots[1]}"
  sessions "$(session 4f2a9c1e T1-builder busy)" "$(session 9e8d7c6b T2-builder busy)"
  remember_before

  run_bin -1 team-close T1
  assert_contains "$output" "  T1-builder 4f2a9c1e is busy"
  assert_contains "$output" "--stop-busy"
  [[ $output != *9e8d7c6b* ]]
  assert_unchanged

  run_bin -0 team-close T1 --stop-busy
  assert_equal "$(claude_actions)" '["stop","4f2a9c1e"]
["rm","4f2a9c1e"]'
  [[ -d ${home_slots[1]} ]]
}

@test "a commit made while sessions were stopped is caught by a second landed check" {
  open_home_task
  work_and_push "$wt" feature.txt
  sessions "$(session 4f2a9c1e T1-builder busy)"
  remember_before
  # The worker commits as it is stopped.
  export LATE_IN=$wt
  stub_script claude <<'SH'
case $1 in
  agents) cat "$BATS_TEST_TMPDIR/sessions.json" ;;
  stop)
    echo late >"$LATE_IN/late.txt"
    git -C "$LATE_IN" add late.txt
    git -C "$LATE_IN" commit -q -m "feat: late"
    ;;
  rm) ;;
  *) exit 64 ;;
esac
SH
  stub_reply gh '[]'

  run_bin -1 --separate-stderr team-close T1 --stop-busy
  assert_contains "$stderr" "team-close: $wt (home, feat/T1-work) has not landed since its sessions were stopped: head"
  assert_contains "$stderr" "(1 commit not pushed)"
  assert_contains "$stderr" "team-close: T1 is half closed"
  assert_equal "$(claude_actions)" '["stop","4f2a9c1e"]'
  [[ ! -e $TEAM_HOME/tasks/T1/scratch ]]
  cmp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/ledger.before"
  assert_equal "$(home_worktrees)" "$(cat "$BATS_TEST_TMPDIR/worktrees.before")"

  # With --keep-worktree, the worktree that stopped landing is kept instead.
  git -C "$wt" reset -q --hard HEAD~1
  : >"$STUB_CALLS/claude.log"
  run_bin -0 --separate-stderr team-close T1 --stop-busy --keep-worktree
  assert_equal "$(jq -c '[.stopped, .returned, .kept]' <<<"$output")" "$(jq -cn --arg wt "$wt" '[["4f2a9c1e"], [], [$wt]]')"
  [[ -f $wt/late.txt ]]
  assert_equal "$(events worktree-returned)" ""
}

# ops_session <status>: T1's ops session, launched in $wt and listed with <status>, with the
# transcript and the answer file team-ops-end deletes; sets ops_transcript and ops_answer.
ops_session() {
  local uuid=6f93fe38-1111-4222-8333-444455556666
  launch T1 ops 6f93fe38 "$wt"
  ops_transcript=$HOME/.claude/projects/-slots-home-1/$uuid.jsonl
  ops_answer=$wt/.scratch/answer.md
  mkdir -p "$(dirname "$ops_transcript")"
  echo '{"query": "results"}' >"$ops_transcript"
  echo "42 documents" >"$ops_answer"
  sessions "$(jq -c --arg wt "$wt" '.cwd = $wt' <<<"$(session 6f93fe38 T1-ops "$1" "done")")" \
    "$(session 4f2a9c1e T1-builder idle blocked)"
  remember_before
}

@test "an ops session is ended through team-ops-end before the other sessions stop, and the close goes on" {
  open_home_task
  work_and_push "$wt" feature.txt
  ops_session idle

  run_bin -0 --separate-stderr team-close T1
  assert_equal "$(jq -c '[.stopped, .removed]' <<<"$output")" '[["4f2a9c1e"],["6f93fe38","4f2a9c1e"]]'
  assert_contains "$stderr" "deleted $ops_transcript"
  assert_contains "$stderr" "deleted $ops_answer"
  assert_contains "$stderr" "ended T1-ops (6f93fe38)"
  [[ ! -e $ops_transcript ]]
  # team-ops-end's own stop and rm come first; the close stops and removes no ops session itself.
  assert_equal "$(claude_actions)" '["stop","6f93fe38"]
["rm","6f93fe38"]
["stop","4f2a9c1e"]
["rm","4f2a9c1e"]'
  assert_equal "$(events closed)" "$(jq -cn --arg wt "$wt" \
    '{task: "T1", event: "closed", archive: ["tasks/T1/scratch"], returned: [$wt], kept: []}')"
}

@test "a failed team-ops-end stops the close half closed with its reason, and a second close after the fix completes" {
  open_home_task
  work_and_push "$wt" feature.txt
  ops_session idle
  touch "$BATS_TEST_TMPDIR/rm-fails"
  stub_script claude <<'SH'
case $1 in
  agents) cat "$BATS_TEST_TMPDIR/sessions.json" ;;
  stop) ;;
  rm) [[ ! -e $BATS_TEST_TMPDIR/rm-fails ]] ;;
  *) exit 64 ;;
esac
SH

  run_bin -1 --separate-stderr team-close T1
  assert_contains "$stderr" "team-ops-end: claude rm 6f93fe38 failed; its transcript is kept"
  assert_contains "$stderr" "team-close: cannot end T1-ops with team-ops-end; its reason is above"
  assert_contains "$stderr" "team-close: T1 is half closed"
  [[ -f $ops_transcript ]]
  # The builder was never stopped, nothing was archived, and the slot is still held.
  assert_equal "$(claude_actions)" '["stop","6f93fe38"]
["rm","6f93fe38"]'
  [[ ! -e $TEAM_HOME/tasks/T1/scratch ]]
  cmp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/ledger.before"
  assert_equal "$(home_worktrees)" "$(cat "$BATS_TEST_TMPDIR/worktrees.before")"

  rm "$BATS_TEST_TMPDIR/rm-fails"
  run_bin -0 --separate-stderr team-close T1
  assert_equal "$(jq -c .removed <<<"$output")" '["6f93fe38","4f2a9c1e"]'
  [[ ! -e $ops_transcript ]]
  assert_equal "$(events closed | jq -r .event)" closed
}

@test "a busy ops session refuses the close; --stop-busy ends it through team-ops-end" {
  open_home_task
  work_and_push "$wt" feature.txt
  ops_session busy

  run_bin -1 team-close T1
  assert_contains "$output" "  T1-ops 6f93fe38 is busy"
  assert_equal "$(grep -c 'is busy' <<<"$output")" 1
  assert_contains "$output" "--stop-busy"
  assert_unchanged
  [[ -f $ops_transcript ]]

  run_bin -0 --separate-stderr team-close T1 --stop-busy
  assert_contains "$stderr" "ended T1-ops (6f93fe38)"
  [[ ! -e $ops_transcript && ! -e $ops_answer ]]
  assert_equal "$(claude_actions | grep -c 6f93fe38)" 2
  assert_equal "$(jq -c '[.stopped, .removed]' <<<"$output")" '[["4f2a9c1e"],["6f93fe38","4f2a9c1e"]]'
}

@test "an ops session listed with no launch of its own is ended too, and a launched one no longer listed is left alone" {
  open_home_task
  work_and_push "$wt" feature.txt
  # A launch of an ops session that team-ops-end already ended: it is not removed again.
  launch T1 ops 0a0b0c0d "$wt"
  # As Claude Code lists them, a background session that has finished only with --all; a busy one
  # listed there alone still refuses the close.
  stub_script claude <<'SH'
case $1 in
  agents) if [[ ${3:-} == --all ]]; then cat "$BATS_TEST_TMPDIR/sessions.json"; else jq -c 'map(select(.state != "done"))' "$BATS_TEST_TMPDIR/sessions.json"; fi ;;
  stop | rm) ;;
  *) exit 64 ;;
esac
SH
  sessions "$(session 7e7e7e7e T1-ops busy "done")" "$(session 4f2a9c1e T1-builder idle blocked)"
  run_bin -1 team-close T1
  assert_contains "$output" "  T1-ops 7e7e7e7e is busy"
  sessions "$(session 7e7e7e7e T1-ops idle "done")" "$(session 4f2a9c1e T1-builder idle blocked)"

  run_bin -0 --separate-stderr team-close T1
  assert_contains "$stderr" "ended T1-ops (7e7e7e7e)"
  assert_equal "$(jq -c .removed <<<"$output")" '["7e7e7e7e","4f2a9c1e"]'
  [[ $(claude_actions) != *0a0b0c0d* ]]
}

@test "a two-project task archives both task directories and returns both slots through their pools" {
  run_bin -0 team-open home feature feat work "Do the work"
  run_bin -0 team-open --task T1 --add conv feat move
  local home_wt=${home_slots[0]} conv_wt=${conv_slots[0]}
  launch T1 builder 4f2a9c1e "$home_wt"
  launch T1 builder 5a6b7c8d "$conv_wt"
  echo "home spec" >"$home_wt/.scratch/task/spec.md"
  echo "conv notes" >"$conv_wt/.scratch/task/notes.md"
  echo "SECRET=1" >"$conv_wt/.env"
  work_and_push "$home_wt" feature.txt
  work_and_push "$conv_wt" move.txt

  run_bin -0 --separate-stderr team-close T1
  assert_equal "$(cat "$TEAM_HOME/tasks/T1/scratch/spec.md")" "home spec"
  assert_equal "$(cat "$TEAM_HOME/tasks/T1/scratch-conv/notes.md")" "conv notes"
  [[ ! -e $home_wt ]]
  # The treehouse slot stays on disk, detached, its task directory emptied, back in the pool.
  [[ -d $conv_wt/.scratch/task && -z $(ls -A "$conv_wt/.scratch/task") ]]
  run -1 git -C "$conv_wt" symbolic-ref -q HEAD
  assert_equal "$(stub_calls th-return.sh)" "$(jq -cn --arg cwd "$conv" --arg wt "$conv_wt" '{cwd: $cwd, args: [$wt]}')"
  assert_equal "$(cat "$BATS_TEST_TMPDIR/free")" "${conv_slots[1]}
$conv_wt"

  assert_equal "$(events worktree-returned)" "$(jq -cn --arg h "$home_wt" --arg c "$conv_wt" \
    '{task: "T1", event: "worktree-returned", project: "home", worktree: $h, branch: "feat/T1-work"},
     {task: "T1", event: "worktree-returned", project: "conv", worktree: $c, branch: "feat/T1-move"}' | jq -c .)"
  assert_equal "$(events closed)" "$(jq -cn --arg h "$home_wt" --arg c "$conv_wt" \
    '{task: "T1", event: "closed", archive: ["tasks/T1/scratch", "tasks/T1/scratch-conv"], returned: [$h, $c], kept: []}')"
  run_bin -0 team-log --check
}

@test "the task's wip/<project>/T<n> snapshots are deleted on the team home's origin and in each primary checkout once its worktrees are returned" {
  run_bin -0 team-open home feature feat work "Do the work"
  run_bin -0 team-open --task T1 --add conv feat move
  run_bin -0 team-open home feature feat other "Other work"
  local home_wt=${home_slots[0]} conv_wt=${conv_slots[0]}
  work_and_push "$home_wt" feature.txt
  work_and_push "$conv_wt" move.txt
  # team-checkpoint's snapshots: T1's of home alone (conv has none, which is fine), and T2's,
  # which stays; and a same-named branch on home's own origin, which is not the team's to delete.
  git -C "$home_wt" push -q "$team_origin" HEAD:refs/heads/wip/home/T1
  git -C "${home_slots[1]}" push -q "$team_origin" HEAD:refs/heads/wip/home/T2
  git -C "$home_wt" push -q origin HEAD:refs/heads/wip/home/T1
  # The order: home's wip/home/T1 is still there when the last slot goes back.
  echo 'git -C "$BATS_TEST_TMPDIR/origin/agent-team.git" for-each-ref --format="%(refname)" refs/heads/wip/home/T1 >>"$BATS_TEST_TMPDIR/wip-at-return"' \
    >>"$conv/scripts/th-return.sh"

  # team-open --resume's copies of the snapshots in the primary checkouts: T1's go, T2's stays.
  git -C "$home" update-ref refs/remotes/team-home/wip/home/T1 "$(git -C "$home_wt" rev-parse HEAD)"
  git -C "$home" update-ref refs/remotes/team-home/wip/home/T2 "$(git -C "${home_slots[1]}" rev-parse HEAD)"
  git -C "$conv" update-ref refs/remotes/team-home/wip/conv/T1 "$(git -C "$conv_wt" rev-parse HEAD)"

  run_bin -0 --separate-stderr team-close T1
  [[ $stderr != *"cannot delete"* ]]
  assert_equal "$(git -C "$team_origin" for-each-ref --format='%(refname)' refs/heads/wip/)" "refs/heads/wip/home/T2"
  assert_equal "$(git -C "$home" for-each-ref --format='%(refname)' refs/remotes/team-home/)" "refs/remotes/team-home/wip/home/T2"
  assert_equal "$(git -C "$conv" for-each-ref --format='%(refname)' refs/remotes/team-home/)" ""
  assert_equal "$(git -C "$BATS_TEST_TMPDIR/origin/home.git" for-each-ref --format='%(refname)' refs/heads/wip/)" "refs/heads/wip/home/T1"
  assert_equal "$(cat "$BATS_TEST_TMPDIR/wip-at-return")" "refs/heads/wip/home/T1"
}

@test "a wip/<project>/T<n> that cannot be deleted is reported, and the close still finishes" {
  run_bin -0 team-open home feature feat work "Do the work"
  local slot=${home_slots[0]}
  work_and_push "$slot" feature.txt
  git -C "$slot" push -q "$team_origin" HEAD:refs/heads/wip/home/T1
  # The team home's origin refuses every ref update from here on.
  printf '#!/bin/sh\nexit 1\n' >"$team_origin/hooks/pre-receive"
  chmod +x "$team_origin/hooks/pre-receive"

  run_bin -0 --separate-stderr team-close T1
  assert_contains "$stderr" "team-close: cannot delete wip/home/T1 on the team home's origin"
  assert_contains "$stderr" "delete it by hand: git -C $TEAM_HOME push origin --delete wip/home/T1"
  assert_equal "$(events closed | jq -r .event)" "closed"
}

@test "a treehouse return that leaves the slot on its branch stops the close half way" {
  run_bin -0 team-open conv feature feat move "Move it"
  local slot=${conv_slots[0]}
  work_and_push "$slot" move.txt
  # treehouse 2: a dirty slot is left leased, and the return exits 0.
  cat >"$conv/scripts/th-return.sh" <<'SH'
#!/usr/bin/env bash
echo "Worktree has uncommitted changes. Clean and return? [Y/n] Aborted."
SH

  run_bin -1 team-close T1
  assert_contains "$output" "did not return $slot: it is still on a branch"
  assert_contains "$output" "T1 is half closed; fix the cause above and run team-close T1 again"
  assert_equal "$(events worktree-returned)$(events closed)" ""

  # treehouse 3 (the pin): the same slot is left leased, and the return exits 3, as th-return.sh
  # passes treehouse's status on under set -e.
  cat >"$conv/scripts/th-return.sh" <<'SH'
#!/usr/bin/env bash
echo "Worktree has uncommitted changes. Clean and return? [Y/n] 🌳 worktree not returned: it has uncommitted changes and the confirmation could not be answered (stdin reached EOF)" >&2
exit 3
SH
  run_bin -1 team-close T1
  assert_contains "$output" "worktree not returned: it has uncommitted changes"
  assert_contains "$output" "scripts/th-return.sh failed for $slot"
  assert_contains "$output" "T1 is half closed; fix the cause above and run team-close T1 again"
  assert_equal "$(events worktree-returned)$(events closed)" ""
  git -C "$slot" symbolic-ref -q HEAD
}

@test "a missing or empty task directory is reported and nothing is archived from it" {
  run_bin -0 team-open home feature feat work "Do the work"
  run_bin -0 team-open --task T1 --add conv feat move
  rmdir "${home_slots[0]}/.scratch/task"

  run_bin -0 --separate-stderr team-close T1
  # The return command's own output follows on stderr.
  assert_equal "$(head -n 2 <<<"$stderr")" "team-close: ${home_slots[0]}/.scratch/task is missing, so nothing was archived from home
team-close: ${conv_slots[0]}/.scratch/task is empty, so nothing was archived from conv"
  [[ ! -e $TEAM_HOME/tasks/T1/scratch && ! -e $TEAM_HOME/tasks/T1/scratch-conv ]]
  assert_equal "$(events closed | jq -c '[.archive, (.returned | length)]')" '[[],2]'
}

@test "a mirror that fails stops the close half closed with rsync's reason, and a second close after the fix completes" {
  [[ $(id -u) != 0 ]] || skip "root reads a file whatever its mode"
  run_bin -0 team-open home feature feat work "Do the work"
  local slot=${home_slots[0]}
  local dir=$slot/.scratch/task
  echo "spec" >"$dir/spec.md"
  echo "unreadable" >"$dir/locked.md"
  chmod 000 "$dir/locked.md"
  work_and_push "$slot" feature.txt

  run_bin -1 --separate-stderr team-close T1
  assert_equal "$output" ""
  [[ $(head -n 1 <<<"$stderr") =~ ^"team-close: cannot mirror $dir into tasks/T1/scratch: rsync".*"locked.md".*"Permission denied" ]]
  assert_equal "$(tail -n 1 <<<"$stderr")" "team-close: T1 is half closed; fix the cause above and run team-close T1 again"
  assert_equal "$(events worktree-returned)$(events closed)" ""
  [[ -d $slot ]]

  chmod 644 "$dir/locked.md"
  run_bin -0 --separate-stderr team-close T1
  assert_equal "$(jq -c .archive <<<"$output")" '["tasks/T1/scratch"]'
  assert_equal "$(cat "$TEAM_HOME/tasks/T1/scratch/locked.md")" "unreadable"
}

@test "a closed, unknown or malformed task is refused" {
  run_bin -0 team-open home research research look "Look"
  run_bin -0 team-close T1
  run_bin -1 team-close T1
  assert_equal "$output" "team-close: T1 is already closed"
  run_bin -1 team-close T9
  assert_equal "$output" "team-close: unknown task T9: the ledger has no events for it"
  run_bin -2 team-close 9
  run_bin -2 team-close T1 --force
  run_bin -2 team-close
  run_bin -2 team-close T1 --worktree
}

@test "--worktree is refused for a task opened by team-open" {
  open_home_task
  run_bin -2 team-close T1 --worktree "$wt"
  assert_contains "$output" "--worktree is for a legacy task"
  assert_unchanged
}

@test "a legacy task stops and removes its sessions and closes with a legacy note, touching no worktree" {
  cp "$BATS_TEST_DIRNAME/fixtures/ledger-T7-T10.jsonl" "$TEAM_HOME/ledger.jsonl"
  sessions "$(session 418e77bd T7-planner idle)" "$(session 77ddfee3 T8-planner idle)"
  local before
  before=$(home_worktrees)

  run_bin -0 --separate-stderr team-close T7
  assert_equal "$(jq -c . <<<"$output")" \
    '{"task":"T7","stopped":["418e77bd"],"removed":["418e77bd"],"archive":[],"returned":[],"kept":[]}'
  assert_equal "$stderr" ""
  assert_equal "$(claude_actions)" '["stop","418e77bd"]
["rm","418e77bd"]'
  assert_equal "$(events closed)" '{"task":"T7","event":"closed","archive":[],"returned":[],"kept":[],"note":"legacy"}'
  assert_equal "$(home_worktrees)" "$before"
  assert_equal "$(stub_calls gh)" ""

  run_bin -0 team-close T10
  assert_equal "$(claude_actions | tail -n 1)" '["rm","954b98a2"]'
}

# Hand-written rather than fixtures/ledger-T5.jsonl: the slot a legacy close checks must be one of
# the sandbox's, and the real launches name paths on Daniel's machine.
# legacy_task <worktree> <branch>: T5 as the ledger had it, launched in <worktree> and in an
# agent-team slot, with <worktree> (a home slot) on <branch>, pushed, its task directory holding a
# handoff.
legacy_task() {
  git -C "$home" worktree add -q --no-track -b "$2" "$1" origin/main
  mkdir -p "$1/.scratch/task"
  echo "handoff" >"$1/.scratch/task/handoff.md"
  work_and_push "$1" work.txt
  launch T5 planner bcc8f165 "$1"
  launch T5 builder 99cb9d02 /home/danielc/agent-team/.claude/worktrees/1
  remember_before
}

@test "a legacy task with --worktree returns that slot after the same checks" {
  local slot=${home_slots[1]}
  legacy_task "$slot" feat/T5-sign-in-limits

  run_bin -0 team-close T5 --worktree "$slot/"
  assert_equal "$(cat "$TEAM_HOME/tasks/T5/scratch/handoff.md")" "handoff"
  [[ ! -e $slot ]]
  assert_equal "$(events worktree-returned)" "$(jq -cn --arg wt "$slot" \
    '{task: "T5", event: "worktree-returned", project: "home", worktree: $wt, branch: "feat/T5-sign-in-limits"}')"
  assert_equal "$(events closed)" "$(jq -cn --arg wt "$slot" \
    '{task: "T5", event: "closed", archive: ["tasks/T5/scratch"], returned: [$wt], kept: [], note: "legacy"}')"
  assert_equal "$(claude_actions)" '["rm","bcc8f165"]
["rm","99cb9d02"]'
}

@test "a legacy task's --worktree matches a launch recorded under another home" {
  local slot=${home_slots[1]}
  legacy_task "$slot" feat/T5-sign-in-limits
  rehome_ledger /Users/someone

  run_bin -0 team-close T5 --worktree "$slot"
  [[ ! -e $slot ]]
  assert_equal "$(events worktree-returned | jq -r .worktree)" "$slot"
}

@test "a legacy task's --worktree spelled otherwise than its launch is that slot (report F6)" {
  local slot=${home_slots[1]}
  legacy_task "$slot" feat/T5-sign-in-limits
  run_bin -0 team-close T5 --worktree "$(other_spelling "$(dirname "$slot")")/${slot##*/}"
  [[ ! -e $slot ]]
  assert_equal "$(events worktree-returned | wc -l)" 1
}

@test "a legacy task's --worktree with an uncommitted change is refused like any other" {
  local slot=${home_slots[1]}
  legacy_task "$slot" feat/T5-sign-in-limits
  echo changed >>"$slot/README.md"

  run_bin -1 team-close T5 --worktree "$slot"
  assert_contains "$output" "$slot (home, feat/T5-sign-in-limits) has not landed: changes to tracked files: README.md"
  assert_equal "$(claude_actions)" ""
  cmp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/ledger.before"
}

@test "a legacy task's --worktree must be a trusted slot, launched by the task, on a branch naming it" {
  local slot=${home_slots[1]}
  legacy_task "$slot" feat/T50-other-task
  run_bin -1 team-close T5 --worktree "$slot"
  assert_equal "$output" "team-close: $slot is on feat/T50-other-task, which does not name T5"

  git -C "$slot" switch -q -c fix/T5-again
  run_bin -1 team-close T5 --worktree "$HOME/projects/home"
  assert_equal "$output" "team-close: $HOME/projects/home is not a trusted slot of any project in projects.toml"

  git -C "$home" worktree add -q --no-track -b feat/T5-elsewhere "${home_slots[0]}" origin/main
  run_bin -1 team-close T5 --worktree "${home_slots[0]}"
  assert_equal "$output" "team-close: ${home_slots[0]} appears in none of T5's launch events"

  git -C "$slot" switch -q --detach
  run_bin -1 team-close T5 --worktree "$slot"
  assert_equal "$output" "team-close: $slot is not on a branch, so it cannot be T5's"

  assert_equal "$(claude_actions)" ""
  cmp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/ledger.before"
  [[ ! -e $TEAM_HOME/tasks/T5 ]]
}

@test "refused in a worker session, whatever its role, before any read; --help and the coordinator are not" {
  worker_refused team-close "closes no task" T1
  worker_refused team-close "closes no task" T1 --keep-worktree --stop-busy
  AGENT_TEAM_ROLE=ops run_bin -0 team-close --help
  assert_equal "${lines[0]}" "$(sed -n '2s/^# //p' "$REPO_ROOT/bin/team-close")"
  AGENT_TEAM_ROLE=coordinator run_bin -2 team-close
  assert_contains "$output" "usage: team-close T<n>"
}

# Ticket worktrees (team-open --ticket), returned one at a time with --ticket and with the rest at
# the close.

# open_ticket <NN> [<task worktree>]: give T1's task worktree (default $wt, open_home_task's) a
# ticket NN and open its ticket worktree with the real team-open --ticket; sets twt (the ticket
# worktree) and tbranch (its branch).
open_ticket() {
  local task_wt=${2:-$wt}
  mkdir -p "$task_wt/.scratch/task/tickets"
  printf '# %s: t\n\nBlocked by: None\n' "$1" >"$task_wt/.scratch/task/tickets/$1-t.md"
  run_bin -0 team-open --task T1 --ticket "$1"
  twt=$(events worktree-added | jq -r --arg t "$1" 'select(.ticket == $t) | .worktree' | tail -n 1)
  tbranch=$(events worktree-added | jq -r --arg t "$1" 'select(.ticket == $t) | .branch' | tail -n 1)
}

# Commit a file in the worktree <wt>, pushing nothing: commit_in <wt> <file>
commit_in() {
  echo "$2" >"$1/$2"
  git -C "$1" add "$2"
  git -C "$1" commit -q -m "feat: $2"
}

# Fast-forward the task branch in its worktree (default $wt) to the ticket branch's head, as an
# integration does: integrate [<task worktree>]
integrate() {
  git -C "${1:-$wt}" merge -q --ff-only "$tbranch"
}

@test "--ticket stops the ticket's idle builder, archives, removes it, returns the slot and deletes its integrated branch" {
  open_home_task
  open_ticket 03
  assert_equal "$twt" "${home_slots[1]}"
  launch T1 builder 7c7c7c7c "$twt"
  sessions "$(session 4f2a9c1e T1-builder idle blocked)" "$(session 7c7c7c7c T1-builder-03 idle blocked)"
  mkdir -p "$twt/.scratch/task/build-notes"
  echo "note three" >"$twt/.scratch/task/build-notes/03.md"
  commit_in "$twt" three.txt
  integrate
  local head
  head=$(git -C "$twt" rev-parse HEAD)

  run_bin -0 --separate-stderr team-close T1 --ticket 03
  assert_equal "$(jq -c . <<<"$output")" "$(jq -cn --arg wt "$twt" '{task: "T1", ticket: "03", stopped: ["7c7c7c7c"],
    removed: ["7c7c7c7c"], archive: "tasks/T1/scratch--03", returned: $wt, branch: "feat/T1-work--03", branch_deleted: true}')"
  # Stopped before the archive, removed after it, both before the slot was returned; the task's
  # own builder is never touched.
  assert_equal "$(cat "$BATS_TEST_TMPDIR/order")" "stop 7c7c7c7c archive:0 worktrees:3
rm 7c7c7c7c archive:3 worktrees:3"
  assert_equal "$(cd "$TEAM_HOME/tasks/T1/scratch--03" && find . -type f | sort)" "./build-notes/03.md
./spec.md
./tickets/03-t.md"
  [[ ! -e $twt ]]
  [[ -f $wt/.scratch/task/spec.md ]]
  assert_equal "$(git -C "$home" worktree list | wc -l)" "2"
  assert_contains "$stderr" "team-close: deleted feat/T1-work--03 at ${head:0:8}, which feat/T1-work holds"
  run -1 git -C "$home" show-ref -q --verify refs/heads/feat/T1-work--03
  git -C "$home" show-ref -q --verify refs/heads/feat/T1-work

  assert_equal "$(events worktree-returned)" "$(jq -cn --arg wt "$twt" \
    '{task: "T1", event: "worktree-returned", project: "home", worktree: $wt, branch: "feat/T1-work--03", ticket: "03"}')"
  assert_equal "$(events closed)" ""
  run_bin -0 team-log --check
  run_bin -0 --separate-stderr team-state T1 --json
  assert_equal "$(jq -c '[.worktrees[] | select(.returned | not) | .worktree]' <<<"$output")" "$(jq -cn --arg wt "$wt" '[$wt]')"
}

@test "--ticket keeps a ticket branch the task branch does not hold, and says so" {
  open_home_task
  open_ticket 03
  commit_in "$twt" three.txt
  local head
  head=$(git -C "$twt" rev-parse HEAD)

  run_bin -0 --separate-stderr team-close T1 --ticket 03
  assert_equal "$(jq -c '[.stopped, .removed, .branch_deleted]' <<<"$output")" '[[],[],false]'
  assert_contains "$stderr" "team-close: kept feat/T1-work--03 at ${head:0:8}: the task branch does not hold it"
  assert_equal "$(git -C "$home" rev-parse refs/heads/feat/T1-work--03)" "$head"
  [[ ! -e $twt ]]
  assert_equal "$(events worktree-returned | jq -r .ticket)" "03"
}

@test "--ticket waits for a busy builder, and returns the worktree once it is idle" {
  open_home_task
  open_ticket 03
  launch T1 builder 7c7c7c7c "$twt"
  sessions "$(session 7c7c7c7c T1-builder-03 busy)"
  stub_script claude <<'SH'
case $1 in
  agents)
    cat "$BATS_TEST_TMPDIR/sessions.json"
    jq -cn '[{id: "7c7c7c7c", sessionId: "7c7c7c7c-1111-4222-8333-444455556666", name: "T1-builder-03", status: "idle"}]' \
      >"$BATS_TEST_TMPDIR/sessions.json"
    ;;
  stop | rm) ;;
  *) exit 64 ;;
esac
SH

  TEAM_CLOSE_IDLE_SECONDS=10 run_bin -0 --separate-stderr team-close T1 --ticket 03
  assert_equal "$(jq -c .stopped <<<"$output")" '["7c7c7c7c"]'
  assert_equal "$(stub_calls claude | jq -c 'select(.[0] == "agents")' | wc -l)" "2"
  [[ ! -e $twt ]]
}

@test "--ticket on a builder still busy after the wait is exit 75, returning nothing" {
  open_home_task
  open_ticket 03
  launch T1 builder 7c7c7c7c "$twt"
  sessions "$(session 7c7c7c7c T1-builder-03 busy)"
  remember_before

  TEAM_CLOSE_IDLE_SECONDS=0 run_bin -75 --separate-stderr team-close T1 --ticket 03
  assert_equal "$stderr" "team-close: T1-builder-03 7c7c7c7c is still busy; run this again once it is idle"
  assert_equal "$output" ""
  assert_equal "$(claude_actions)" ""
  [[ ! -e $TEAM_HOME/tasks/T1/scratch--03 ]]
  cmp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/ledger.before"
  [[ -d $twt ]]

  TEAM_CLOSE_IDLE_SECONDS=soon run_bin -2 team-close T1 --ticket 03
  assert_equal "$output" "team-close: TEAM_CLOSE_IDLE_SECONDS must be a whole number of seconds, got 'soon'"
}

@test "--ticket stops only the sessions launched in that worktree since it was given to the ticket" {
  open_home_task
  open_ticket 03
  launch T1 builder 7c7c7c7c "$twt"
  sessions "$(session 7c7c7c7c T1-builder-03 idle blocked)"
  run_bin -0 team-close T1 --ticket 03
  # The slot goes to ticket 04 next; ticket 03's builder, already removed, is not touched again.
  open_ticket 04
  assert_equal "$twt" "${home_slots[1]}"
  launch T1 builder 8d8d8d8d "$twt"
  sessions "$(session 8d8d8d8d T1-builder-04 idle blocked)" "$(session 4f2a9c1e T1-builder idle blocked)"
  rm -f "$BATS_TEST_TMPDIR/order"

  run_bin -0 --separate-stderr team-close T1 --ticket 04
  assert_equal "$(jq -c '[.stopped, .removed, .archive]' <<<"$output")" '[["8d8d8d8d"],["8d8d8d8d"],"tasks/T1/scratch--04"]'
  assert_equal "$(cut -d' ' -f1,2 "$BATS_TEST_TMPDIR/order")" "stop 8d8d8d8d
rm 8d8d8d8d"
}

@test "--ticket returns a treehouse slot through the project's return command" {
  run_bin -0 --separate-stderr team-open conv feature feat move "Move it"
  open_ticket 02 "${conv_slots[0]}"
  assert_equal "$twt" "${conv_slots[1]}"
  integrate "${conv_slots[0]}"

  run_bin -0 --separate-stderr team-close T1 --ticket 02
  assert_equal "$(jq -c '[.archive, .returned, .branch_deleted]' <<<"$output")" "$(jq -cn --arg wt "$twt" '["tasks/T1/scratch--02", $wt, true]')"
  run -1 git -C "$twt" symbolic-ref -q HEAD
  [[ -d $twt/.scratch/task && -z $(ls -A "$twt/.scratch/task") ]]
  assert_equal "$(stub_calls th-return.sh)" "$(jq -cn --arg cwd "$conv" --arg wt "$twt" '{cwd: $cwd, args: [$wt]}')"
  assert_equal "$(cat "$BATS_TEST_TMPDIR/free")" "$twt"
  run -1 git -C "$conv" show-ref -q --verify refs/heads/feat/T1-move--02
  assert_equal "$(events worktree-returned)" "$(jq -cn --arg wt "$twt" \
    '{task: "T1", event: "worktree-returned", project: "conv", worktree: $wt, branch: "feat/T1-move--02", ticket: "02"}')"
}

@test "--ticket takes down the ticket worktree's stack before the archive" {
  home_stack
  docker_stub "${home_slots[1]}"
  open_home_task
  open_ticket 03
  run_bin -0 team-stack up --worktree "$twt" --no-seed
  stack_exists stackfix-2

  run_bin -0 --separate-stderr team-close T1 --ticket 03
  assert_contains "$stderr" "team-stack: stackfix-2 is removed, its logs in $twt/.scratch/task/stack-logs"
  stack_gone stackfix-2
  [[ ! -e $TEAM_HOME/tasks/T1/scratch--03/stack-logs ]]
}

@test "--ticket refuses a ticket worktree with uncommitted work, naming it, and changes nothing" {
  open_home_task
  open_ticket 03
  launch T1 builder 7c7c7c7c "$twt"
  sessions "$(session 7c7c7c7c T1-builder-03 idle blocked)"
  echo changed >>"$twt/README.md"
  echo new >"$twt/new.txt"
  echo ignored >"$twt/.env"
  remember_before

  run_bin -1 team-close T1 --ticket 03
  assert_equal "$output" "team-close: T1's ticket 03 worktree $twt has changes to tracked files: README.md; untracked files: new.txt, so nothing was returned"
  assert_equal "$(claude_actions)" ""
  [[ ! -e $TEAM_HOME/tasks/T1/scratch--03 ]]
  cmp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/ledger.before"
  assert_equal "$(home_worktrees)" "$(cat "$BATS_TEST_TMPDIR/worktrees.before")"
}

@test "--ticket refuses a task with no open worktree of the ticket, a closed or legacy task, and a malformed command line" {
  open_home_task
  run_bin -1 team-close T1 --ticket 03
  assert_equal "$output" "team-close: T1 has no open worktree of ticket 03"
  open_ticket 03
  run_bin -0 team-close T1 --ticket 03
  run_bin -1 team-close T1 --ticket 03
  assert_equal "$output" "team-close: T1 has no open worktree of ticket 03"

  ledger_line '{ts: "2026-10-22T01:00:00Z", task: "T5", event: "launch", role: "builder", session: "5e5e5e5e", toolkits: []}'
  run_bin -1 team-close T5 --ticket 03
  assert_equal "$output" "team-close: T5 is not open: the ledger has no opened event for it"
  run_bin -1 team-close T9 --ticket 03
  assert_equal "$output" "team-close: unknown task T9: the ledger has no events for it"

  local bad
  for bad in "--ticket" "--ticket 3" "--ticket 003" "--ticket ab" "--ticket 03 --keep-worktree" \
    "--ticket 03 --stop-busy" "--ticket 03 --worktree x"; do
    # shellcheck disable=SC2086
    run_bin -2 team-close T1 $bad
    assert_contains "$output" "usage: team-close T<n>"
  done

  run_bin -0 team-close T1
  run_bin -1 team-close T1 --ticket 03
  assert_equal "$output" "team-close: T1 is already closed"
}

@test "the close returns an integrated ticket worktree with the task's and deletes its branch" {
  open_home_task
  open_ticket 03
  launch T1 builder 7c7c7c7c "$twt"
  commit_in "$twt" three.txt
  integrate
  git -C "$wt" push -q origin HEAD
  local head
  head=$(git -C "$twt" rev-parse HEAD)

  run_bin -0 --separate-stderr team-close T1
  assert_equal "$(jq -c '[.archive, .returned, .kept]' <<<"$output")" "$(jq -cn --arg wt "$wt" --arg twt "$twt" \
    '[["tasks/T1/scratch", "tasks/T1/scratch--03"], [$wt, $twt], []]')"
  [[ ! -e $wt && ! -e $twt ]]
  assert_contains "$stderr" "team-close: deleted feat/T1-work--03 at ${head:0:8}, which feat/T1-work holds"
  run -1 git -C "$home" show-ref -q --verify refs/heads/feat/T1-work--03
  assert_equal "$(events worktree-returned)" "$(jq -cn --arg wt "$wt" --arg twt "$twt" \
    '{task: "T1", event: "worktree-returned", project: "home", worktree: $wt, branch: "feat/T1-work"},
     {task: "T1", event: "worktree-returned", project: "home", worktree: $twt, branch: "feat/T1-work--03", ticket: "03"}' | jq -c .)"
  [[ -f $TEAM_HOME/tasks/T1/scratch--03/tickets/03-t.md ]]
  run_bin -0 team-log --check
}

@test "the close counts a ticket head a squash-merged PR of the task branch holds as landed" {
  open_home_task
  open_ticket 03
  commit_in "$twt" three.txt
  integrate
  commit_in "$wt" after.txt
  git -C "$wt" push -q origin HEAD
  squash_merge "$wt" feat/T1-work
  stub_reply gh "$(jq -cn --arg head "$(git -C "$wt" rev-parse HEAD)" '[{number: 7, headRefOid: $head}]')"

  run_bin -0 --separate-stderr team-close T1
  assert_equal "$(jq -c .returned <<<"$output")" "$(jq -cn --arg wt "$wt" --arg twt "$twt" '[$wt, $twt]')"
  # Each landed check (before and after the stop) asks for the task branch's merged PRs alone.
  assert_equal "$(stub_calls gh | jq -r '.[5]' | sort -u)" "feat/T1-work"
}

@test "the close refuses an unintegrated ticket worktree, and --keep-worktree keeps it with its branch" {
  open_home_task
  open_ticket 03
  commit_in "$twt" three.txt
  work_and_push "$wt" feature.txt
  stub_reply gh '[]'
  remember_before

  run_bin -1 team-close T1
  assert_contains "$output" "  $twt (home, feat/T1-work--03) has not landed: head $(git -C "$twt" rev-parse --short=7 HEAD) is on no branch of origin (1 commit not pushed) and no merged PR of feat/T1-work holds it"
  assert_unchanged

  run_bin -0 --separate-stderr team-close T1 --keep-worktree
  assert_equal "$(jq -c '[.returned, .kept]' <<<"$output")" "$(jq -cn --arg wt "$wt" --arg twt "$twt" '[[$wt], [$twt]]')"
  [[ -d $twt ]]
  git -C "$home" show-ref -q --verify refs/heads/feat/T1-work--03
  [[ $stderr != *"feat/T1-work--03 at"* ]]
  assert_equal "$(events worktree-returned | jq -r .worktree)" "$wt"
}

@test "--ticket catches a file its builder wrote as it was stopped, and is half returned" {
  open_home_task
  open_ticket 03
  launch T1 builder 7c7c7c7c "$twt"
  sessions "$(session 7c7c7c7c T1-builder-03 idle blocked)"
  export TICKET_LATE_IN=$twt
  stub_script claude <<'SH'
case $1 in
  agents) cat "$BATS_TEST_TMPDIR/sessions.json" ;;
  stop) echo late >"$TICKET_LATE_IN/late.txt" ;;
  rm) ;;
  *) exit 64 ;;
esac
SH

  run_bin -1 --separate-stderr team-close T1 --ticket 03
  assert_equal "$stderr" "team-close: T1's ticket 03 worktree $twt has untracked files: late.txt since its sessions were stopped, so it was not returned
team-close: T1's ticket 03 worktree $twt is half returned; fix the cause above and run team-close T1 --ticket 03 again"
  [[ -d $twt && ! -e $TEAM_HOME/tasks/T1/scratch--03 ]]
  assert_equal "$(events worktree-returned)" ""
}

@test "--ticket deletes its ticket's wip ref on the team home's origin and in the primary checkout, and no other" {
  open_home_task
  open_ticket 03
  commit_in "$twt" three.txt
  integrate
  local ref
  # team-checkpoint's snapshots of the task worktree and two ticket worktrees, and team-open
  # --resume's copies of them in the primary checkout.
  for ref in wip/home/T1 wip/home/T1--02 wip/home/T1--03; do
    git -C "$wt" push -q "$team_origin" "HEAD:refs/heads/$ref"
    git -C "$home" update-ref "refs/remotes/team-home/$ref" "$(git -C "$wt" rev-parse HEAD)"
  done

  run_bin -0 --separate-stderr team-close T1 --ticket 03
  [[ $stderr != *"cannot delete"* ]]
  assert_equal "$(git -C "$team_origin" for-each-ref --format='%(refname)' refs/heads/wip/)" "refs/heads/wip/home/T1
refs/heads/wip/home/T1--02"
  assert_equal "$(git -C "$home" for-each-ref --format='%(refname)' refs/remotes/team-home/)" "refs/remotes/team-home/wip/home/T1
refs/remotes/team-home/wip/home/T1--02"
}

@test "--ticket with the team home's origin unreachable says so in one line and still returns the worktree" {
  open_home_task
  open_ticket 03
  commit_in "$twt" three.txt
  integrate
  git -C "$wt" push -q "$team_origin" HEAD:refs/heads/wip/home/T1--03
  mv "$team_origin" "$team_origin.away"

  run_bin -0 --separate-stderr team-close T1 --ticket 03
  mv "$team_origin.away" "$team_origin"
  assert_equal "$(grep -c 'wip/home/T1--03' <<<"$stderr")" 1
  assert_contains "$stderr" "team-close: cannot delete wip/home/T1--03 on the team home's origin ("
  assert_contains "$stderr" "delete it by hand: git -C $TEAM_HOME push origin --delete wip/home/T1--03"
  [[ ! -e $twt ]]
  assert_equal "$(jq -r .returned <<<"$output")" "$twt"
  assert_equal "$(events worktree-returned | jq -r .ticket)" "03"
}

@test "the close deletes every wip/<project>/T<n>--NN origin lists beside wip/<project>/T<n>, and no other task's" {
  open_home_task
  open_ticket 03
  commit_in "$twt" three.txt
  integrate
  git -C "$wt" push -q origin HEAD
  run_bin -0 team-close T1 --ticket 03
  local ref
  # Ticket 03's ref left behind (its return could not reach origin), ticket 05's whose worktree was
  # returned on another machine, and T10's and T1's of another project, which stay.
  for ref in wip/home/T1 wip/home/T1--03 wip/home/T1--05 wip/home/T10 wip/home/T10--03 wip/conv/T1--03; do
    git -C "$wt" push -q "$team_origin" "HEAD:refs/heads/$ref"
  done
  git -C "$home" update-ref refs/remotes/team-home/wip/home/T1--05 "$(git -C "$wt" rev-parse HEAD)"
  git -C "$home" update-ref refs/remotes/team-home/wip/home/T10--03 "$(git -C "$wt" rev-parse HEAD)"

  run_bin -0 --separate-stderr team-close T1
  [[ $stderr != *"cannot delete"* ]]
  assert_equal "$(git -C "$team_origin" for-each-ref --format='%(refname)' refs/heads/wip/)" "refs/heads/wip/conv/T1--03
refs/heads/wip/home/T10
refs/heads/wip/home/T10--03"
  assert_equal "$(git -C "$home" for-each-ref --format='%(refname)' refs/remotes/team-home/)" "refs/remotes/team-home/wip/home/T10--03"
}
