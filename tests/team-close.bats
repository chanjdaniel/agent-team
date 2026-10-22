#!/usr/bin/env bats
# team-close: ending a task only once every worktree has landed and no worker is busy, across a
# git-pool project (home) and a treehouse-pool project (conv, through the fake commands of
# helpers/treehouse). Tasks are opened with the real team-open; launches are hand-written.

load helpers/common
load helpers/treehouse

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
  stub_reply curl '{"id":"1563000000000000001"}'
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

@test "a treehouse return that leaves the slot on its branch stops the close half way" {
  run_bin -0 team-open conv feature feat move "Move it"
  local slot=${conv_slots[0]}
  work_and_push "$slot" move.txt
  cat >"$conv/scripts/th-return.sh" <<'SH'
#!/usr/bin/env bash
echo "Worktree has uncommitted changes. Clean and return? [Y/n] Aborted."
SH

  run_bin -1 team-close T1
  assert_contains "$output" "did not return $slot: it is still on a branch"
  assert_contains "$output" "T1 is half closed; fix the cause above and run team-close T1 again"
  assert_equal "$(events worktree-returned)$(events closed)" ""
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
