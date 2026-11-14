#!/usr/bin/env bats
# team-queue take and tidy: linking queued items to the task that builds them, opened: T<n> or with
# --part T<n> in from:, in one commit with the index, or refusing every file and writing nothing;
# and tidy, the heartbeat's, linking an item an open task's plan cites and moving an item whose
# task merged whole or closed, with the files it takes, into tasks/T<n>/queued/, in one commit.

load helpers/common

setup() {
  sandbox
  queued=$TEAM_HOME/tasks/queued
  mkdir -p "$queued"
  printf 'ledger.jsonl.lock\n' >"$TEAM_HOME/.gitignore"
  cat >"$TEAM_HOME/projects.toml" <<'TOML'
[proj]
repo = "owner/proj"
path = "projects/proj"
base = "main"
delivery = "direct-pr"
merge_method = "merge"
required_checks = []
task_dir = ".scratch/task"
docs = []
toolkits = []

[proj.pool]
provider = "git"
slots = ["slots/proj/1"]

[other]
repo = "owner/other"
path = "projects/other"
base = "main"
delivery = "direct-pr"
merge_method = "merge"
required_checks = []
task_dir = ".scratch/task"
docs = []
toolkits = []

[other.pool]
provider = "git"
slots = ["slots/other/1"]
TOML
  opened_task T2
  opened_task T5
  ready node-pin.md 2 S "pin Node 24" "from: T2"
  ready bootstrap-drill.md 3 M "drill the bootstrap"
  printf '# Current items\n' >"$TEAM_HOME/tasks/current.md"
  make_team_home >/dev/null
}

# Write tasks/queued/<name> with the front matter lines given, then its title, "# <name less .md>",
# and a body line: item <name> [<key>: <value>]...
item() {
  local name=$1
  shift
  { echo ---; printf '%s\n' "$@"; echo ---; echo "# ${name%.md}"; echo; echo "The body."; } >"$queued/$name"
}

# Write a ready item of project proj: ready <name> <priority> <size> <summary> [<key>: <value>]...
ready() {
  item "$1" "summary: $4" "project: proj" "priority: $2" "size: $3" "${@:5}"
}

# Append one event of <task> to the ledger: event <task> <event> [<jq object>]
event() {
  jq -cn --arg task "$1" --arg event "$2" '{ts: "2026-01-01T00:00:00Z", task: $task, event: $event} + '"${3:-{\}}" \
    >>"$TEAM_HOME/ledger.jsonl"
}

# The subject of the team home's last commit, and the paths it changed, on one line each, a move
# as the path it left and the one it took.
last_commit() {
  git -C "${TEAM_HOME:?}" log -1 --format=%s
  git -C "${TEAM_HOME:?}" show --name-only --no-renames --format= HEAD
}

# Commit what the test wrote, and note the head and the queued files' sum, for nothing_written.
committed() {
  git -C "${TEAM_HOME:?}" add -A
  git -C "${TEAM_HOME:?}" commit -q --allow-empty -m "chore: the test's queue"
  head=$(git -C "${TEAM_HOME:?}" rev-parse HEAD)
  before=$(cat "$queued"/*.md | cksum)
}

# Nothing changed since committed: the head, the files, a clean status and no temporary file.
nothing_written() {
  assert_equal "$(git -C "${TEAM_HOME:?}" rev-parse HEAD)" "$head"
  assert_equal "$(cat "$queued"/*.md | cksum)" "$before"
  [[ -z $(git -C "${TEAM_HOME:?}" status --porcelain) ]]
  [[ -z $(find "$queued" -name '*.md.*') ]]
}

@test "take writes opened: T<n> into each file, in team-queue's key order with the body kept, and commits them with the index" {
  run_bin -0 --separate-stderr team-queue take T5 node-pin.md bootstrap-drill.md
  assert_equal "$output" "took node-pin.md for T5
took bootstrap-drill.md for T5"
  assert_equal "$(cat "$queued/node-pin.md")" "---
summary: pin Node 24
project: proj
priority: 2
size: S
from: T2
opened: T5
---
# node-pin

The body."
  assert_equal "$(sed -n 6p "$queued/bootstrap-drill.md")" "opened: T5"
  assert_equal "$(last_commit)" "chore: queued take T5
tasks/queued/bootstrap-drill.md
tasks/queued/index.md
tasks/queued/node-pin.md"
  assert_equal "$(sed -n '/^## Opened/,$p' "$queued/index.md")" "## Opened

- bootstrap-drill.md (proj, T5): drill the bootstrap
- node-pin.md (proj, T5): pin Node 24"
  [[ -z $(git -C "${TEAM_HOME:?}" status --porcelain) ]]
  # Taking it again, a file named twice, changes nothing and says the same.
  local tip
  tip=$(git -C "${TEAM_HOME:?}" rev-parse HEAD)
  run_bin -0 --separate-stderr team-queue take T5 node-pin.md node-pin.md
  assert_equal "$output" "took node-pin.md for T5"
  assert_equal "$(git -C "${TEAM_HOME:?}" rev-parse HEAD)" "$tip"
}

@test "take --part adds T<n> to from: once, leaving opened and the taker alone, and an item another task opened or another item takes may be part-built" {
  opened_task T6
  ready bundle.md 2 M "the bundle" "takes: bootstrap-drill.md"
  ready opened.md 2 S "opened by T6" "opened: T6"
  run_bin -0 --separate-stderr team-queue take T5 node-pin.md bootstrap-drill.md opened.md --part
  assert_equal "$output" "T5 builds part of node-pin.md
T5 builds part of bootstrap-drill.md
T5 builds part of opened.md"
  assert_equal "$(grep -E '^(from|opened):' "$queued/node-pin.md")" "from: T2, T5"
  assert_equal "$(grep -E '^(from|opened):' "$queued/bootstrap-drill.md")" "from: T5"
  assert_equal "$(grep -E '^(from|opened):' "$queued/opened.md")" "from: T5
opened: T6"
  assert_equal "$(git -C "${TEAM_HOME:?}" log -1 --format=%s)" "chore: queued take T5"
  local tip
  tip=$(git -C "${TEAM_HOME:?}" rev-parse HEAD)
  run_bin -0 team-queue take T5 --part node-pin.md
  assert_equal "$(grep '^from:' "$queued/node-pin.md")" "from: T2, T5"
  assert_equal "$(git -C "${TEAM_HOME:?}" rev-parse HEAD)" "$tip"
}

@test "take refuses a file not queued, writing nothing" {
  committed
  run_bin -1 --separate-stderr team-queue take T5 node-pin.md gone.md index.md ../ledger.jsonl
  assert_equal "$output" "gone.md is not queued
index.md is not queued
../ledger.jsonl is not queued"
  assert_equal "$stderr" "team-queue: nothing is taken"
  nothing_written
}

@test "take refuses a task with no opened in the ledger, writing nothing" {
  event T9 thread '{discord_thread: "1"}'
  committed
  run_bin -1 --separate-stderr team-queue take T9 node-pin.md
  assert_equal "$output" "T9 has no opened in the ledger"
  run_bin -1 --separate-stderr team-queue take T10 node-pin.md
  assert_equal "$output" "T10 has no opened in the ledger"
  nothing_written
}

@test "take refuses a closed task, writing nothing" {
  event T5 closed
  committed
  run_bin -1 --separate-stderr team-queue take T5 node-pin.md --part
  assert_equal "$output" "T5 closed at 2026-01-01T00:00:00Z"
  nothing_written
}

@test "take refuses an item another task opened, writing nothing" {
  opened_task T6
  ready opened.md 2 S "opened by T6" "opened: T6"
  committed
  run_bin -1 --separate-stderr team-queue take T5 node-pin.md opened.md
  assert_equal "$output" "tasks/queued/opened.md: T6 opened it; give --part when T5 builds part of it"
  nothing_written
}

@test "take refuses an item another item takes, but with --part, writing nothing" {
  ready bundle.md 2 M "the bundle" "takes: bootstrap-drill.md"
  ready second.md 2 M "a second bundle" "takes: bootstrap-drill.md"
  committed
  run_bin -1 --separate-stderr team-queue take T5 bootstrap-drill.md
  assert_equal "$output" "tasks/queued/bootstrap-drill.md: bundle.md, second.md take it; give --part when T5 builds part of it"
  nothing_written
}

@test "take refuses an item whose project is none of the task's, its opened's and worktree-added's, writing nothing" {
  item elsewhere.md "summary: in the other project" "project: other" "priority: 2" "size: S"
  item nowhere.md "summary: no project" "priority: 2" "size: S"
  committed
  run_bin -1 --separate-stderr team-queue take T5 elsewhere.md nowhere.md --part
  assert_equal "$output" "tasks/queued/elsewhere.md: its project other is none of T5's (proj)
tasks/queued/nowhere.md: it has no project, so it is none of T5's"
  nothing_written
  # A worktree added in the other project makes it one of the task's.
  event T5 worktree-added '{project: "other", branch: "feat/T5-x", base: "main", base_sha: "0000000000000000000000000000000000000000", worktree: "/w/o"}'
  run_bin -0 team-queue take T5 elsewhere.md
  assert_equal "$(grep '^opened:' "$queued/elsewhere.md")" "opened: T5"
}

@test "take refuses a file whose front matter it cannot rewrite without losing a line, writing nothing" {
  printf -- '---\nsummary: broken\nproject: proj\n# broken\n' >"$queued/broken.md"
  committed
  run_bin -1 --separate-stderr team-queue take T5 broken.md
  assert_equal "$output" "tasks/queued/broken.md: front matter line \"# broken\" is no <key>: <value>, which take cannot rewrite: fix the file by hand first
tasks/queued/broken.md: front matter has no closing ---, which take cannot rewrite: fix the file by hand first"
  nothing_written
}

@test "take names a task and at least one file, and refuses a worker session" {
  run_bin -2 team-queue take
  run_bin -2 team-queue take T5
  run_bin -2 team-queue take T5 --part
  run_bin -2 team-queue take 5 node-pin.md
  run_bin -2 team-queue take T5 node-pin.md --part --part
  run_bin -2 team-queue take T5 --all node-pin.md
  AGENT_TEAM_ROLE=builder run_bin -1 --separate-stderr team-queue take T5 node-pin.md
  assert_equal "$stderr" "team-queue: a builder session edits no records: that is the coordinator's; send it your message"
  [[ -z $(git -C "${TEAM_HOME:?}" status --porcelain) ]]
}

# Append a merged of <task> to the ledger, with phases_left <json> when given: merged <task> [<phases_left>]
merged() {
  event "$1" merged "{url: \"https://github.com/owner/proj/pull/1\"}$([[ -z ${2:-} ]] || echo " + {phases_left: $2}")"
}

# The queued files and those in every task's queued/, one path a line under the team home.
where() {
  (cd "$TEAM_HOME" && find tasks -path '*/queued/*.md' ! -name index.md | LC_ALL=C sort)
}

@test "tidy moves an item into its task's queued/ once the task merged whole, in one commit with the index, and after a research task's closed too" {
  opened_task T6 research
  ready closing.md 2 S "researched" "opened: T6"
  ready node-pin.md 2 S "pin Node 24" "opened: T5"
  # A merged with a phase left builds on: the item stays, and tidy says and commits nothing.
  merged T5 '[2]'
  run_bin -0 team-queue index
  committed
  run_bin -0 --separate-stderr team-queue tidy
  assert_equal "$output" ""
  assert_equal "$stderr" ""
  nothing_written
  merged T5 '[]'
  committed
  run_bin -0 --separate-stderr team-queue tidy
  assert_equal "$output" "moved node-pin.md to tasks/T5/queued/: T5 merged
wrote tasks/queued/index.md: 2 files"
  assert_equal "$(where)" "tasks/T5/queued/node-pin.md
tasks/queued/bootstrap-drill.md
tasks/queued/closing.md"
  assert_equal "$(head -n 2 "$TEAM_HOME/tasks/T5/queued/node-pin.md")" "---
summary: pin Node 24"
  assert_equal "$(last_commit)" "chore: queued tidy
tasks/T5/queued/node-pin.md
tasks/queued/index.md
tasks/queued/node-pin.md"
  [[ -z $(git -C "${TEAM_HOME:?}" status --porcelain) ]]
  # A closed ends it too.
  event T6 closed
  committed
  run_bin -0 team-queue tidy
  assert_equal "$output" "moved closing.md to tasks/T6/queued/: T6 closed
wrote tasks/queued/index.md: 1 file"
  assert_equal "$(where)" "tasks/T5/queued/node-pin.md
tasks/T6/queued/closing.md
tasks/queued/bootstrap-drill.md"
  assert_equal "$(git -C "${TEAM_HOME:?}" log -1 --format=%s)" "chore: queued tidy"
  # Once tidy, a second run changes nothing.
  committed
  run_bin -0 team-queue tidy
  assert_equal "$output" ""
  nothing_written
}

@test "tidy leaves queued an item whose feature, bug or small task closed with no whole merge, which --check names, and moves a research or retro task's" {
  local t
  for t in T5 T6 T7; do opened_task "$t"; done
  opened_task T8 bug
  opened_task T9 retro
  opened_task T10 small
  ready a-abandoned.md 2 S "a" "opened: T5" "takes: e-taken.md"
  ready b-part.md 2 S "b" "opened: T6"
  ready c-whole.md 2 S "c" "opened: T7"
  ready d-bug.md 2 S "d" "opened: T8"
  ready e-taken.md 3 S "e"
  ready f-retro.md 2 S "f" "opened: T9"
  ready g-small.md 2 S "g" "opened: T10"
  # T5 closed with no merge, T6 with a part merged, T8 and T10 with no merge; T7 merged whole and
  # closed, T9 is a retro, which finishes by closing.
  merged T6 '[2]'
  merged T7 '[]'
  for t in T5 T6 T7 T8 T9 T10; do event "$t" closed; done
  committed
  run_bin -0 team-queue tidy
  assert_equal "$output" "moved c-whole.md to tasks/T7/queued/: T7 merged
moved f-retro.md to tasks/T9/queued/: T9 closed
wrote tasks/queued/index.md: 7 files"
  assert_equal "$(where)" "tasks/T7/queued/c-whole.md
tasks/T9/queued/f-retro.md
tasks/queued/a-abandoned.md
tasks/queued/b-part.md
tasks/queued/bootstrap-drill.md
tasks/queued/d-bug.md
tasks/queued/e-taken.md
tasks/queued/g-small.md
tasks/queued/node-pin.md"
  run_bin -1 team-queue index --check
  assert_equal "$output" "tasks/queued/a-abandoned.md: opened names T5, which closed at 2026-01-01T00:00:00Z with no whole merge: remove opened: to queue it again, or delete the file
tasks/queued/b-part.md: opened names T6, which closed at 2026-01-01T00:00:00Z with no whole merge: remove opened: to queue it again, or delete the file
tasks/queued/d-bug.md: opened names T8, which closed at 2026-01-01T00:00:00Z with no whole merge: remove opened: to queue it again, or delete the file
tasks/queued/g-small.md: opened names T10, which closed at 2026-01-01T00:00:00Z with no whole merge: remove opened: to queue it again, or delete the file"
  # A second tidy leaves them.
  committed
  run_bin -0 team-queue tidy
  assert_equal "$output" ""
  nothing_written
}

@test "tidy moves an item whose task merged with no phases_left, then launched a builder, then closed: a closed task's merge is whole unless it names phases left" {
  opened_task T1 small
  ready a-small.md 2 S "a" "opened: T1"
  merged T1
  event T1 launch '{role: "builder", session: "b1"}'
  event T1 closed
  committed
  run_bin -0 team-queue tidy
  assert_equal "$output" "moved a-small.md to tasks/T1/queued/: T1 merged
wrote tasks/queued/index.md: 2 files"
  run_bin -0 team-queue index --check
  assert_equal "$output" ""
}

@test "tidy moves a taken file with its taker unless another queued item still takes it or a task opened it" {
  opened_task T6
  opened_task T7
  ready a.md 3 S "taken by bundle"
  ready b.md 3 S "taken by both"
  ready c.md 3 S "opened by T7" "opened: T7"
  ready bundle.md 2 M "the bundle" "opened: T5" "takes: a.md, b.md, c.md"
  ready second.md 2 M "the second" "opened: T6" "takes: b.md"
  run_bin -0 team-queue index
  committed
  merged T5
  run_bin -0 team-queue tidy
  assert_equal "$output" "moved bundle.md to tasks/T5/queued/: T5 merged
moved a.md to tasks/T5/queued/: bundle.md takes it
wrote tasks/queued/index.md: 5 files"
  assert_equal "$(where)" "tasks/T5/queued/a.md
tasks/T5/queued/bundle.md
tasks/queued/b.md
tasks/queued/bootstrap-drill.md
tasks/queued/c.md
tasks/queued/node-pin.md
tasks/queued/second.md"
  # b.md leaves with its last taker.
  merged T6
  run_bin -0 team-queue tidy
  assert_equal "$output" "moved second.md to tasks/T6/queued/: T6 merged
moved b.md to tasks/T6/queued/: second.md takes it
wrote tasks/queued/index.md: 3 files"
  assert_equal "$(where)" "tasks/T5/queued/a.md
tasks/T5/queued/bundle.md
tasks/T6/queued/b.md
tasks/T6/queued/second.md
tasks/queued/bootstrap-drill.md
tasks/queued/c.md
tasks/queued/node-pin.md"
  assert_equal "$(last_commit)" "chore: queued tidy
tasks/T6/queued/b.md
tasks/T6/queued/second.md
tasks/queued/b.md
tasks/queued/index.md
tasks/queued/second.md"
}

@test "two takers that leave in one tidy take a file they share with the first of them" {
  opened_task T6
  ready b.md 3 S "taken by both"
  ready bundle.md 2 M "the bundle" "opened: T6" "takes: b.md"
  ready second.md 2 M "the second" "opened: T5" "takes: b.md"
  merged T5
  merged T6
  run_bin -0 team-queue tidy
  assert_equal "$output" "moved bundle.md to tasks/T6/queued/: T6 merged
moved b.md to tasks/T6/queued/: bundle.md takes it
moved second.md to tasks/T5/queued/: T5 merged
wrote tasks/queued/index.md: 2 files"
}

@test "tidy links an item an open task's plan cites to that task, and moves it in the same run when the task merged whole" {
  plan_md T5 "# T5 plan

Builds \`~/agent-team-records/tasks/queued/node-pin.md\` and tasks/queued/bootstrap-drill.md."
  run_bin -0 team-queue index
  committed
  run_bin -0 --separate-stderr team-queue tidy
  assert_equal "$output" "linked bootstrap-drill.md to T5: its plan cites it
linked node-pin.md to T5: its plan cites it
wrote tasks/queued/index.md: 2 files"
  assert_equal "$(cat "$queued/node-pin.md")" "---
summary: pin Node 24
project: proj
priority: 2
size: S
from: T2
opened: T5
---
# node-pin

The body."
  assert_equal "$(last_commit)" "chore: queued tidy
tasks/queued/bootstrap-drill.md
tasks/queued/index.md
tasks/queued/node-pin.md"
  # A task that merged whole and is not closed yet is still open: its cited item is linked and moved.
  opened_task T6
  plan_md T6 "Cites tasks/queued/late.md."
  ready late.md 2 S "linked late"
  merged T6
  run_bin -0 team-queue tidy
  # The index never listed late.md, so it is as it was.
  assert_equal "$output" "linked late.md to T6: its plan cites it
moved late.md to tasks/T6/queued/: T6 merged"
  assert_equal "$(grep '^opened:' "$TEAM_HOME/tasks/T6/queued/late.md")" "opened: T6"
}

@test "tidy links no cited item that waits: one whose after: names a file the task builds, one after the task's merge, one with waits:" {
  ready flakes.md 2 M "the flakes" "opened: T5"
  ready split.md 1 L "the hot-file split, after the flakes" "after: flakes.md"
  ready after-merge.md 3 S "what is left once T5 lands" "after: T5 merged"
  ready ideas.md 4 M "ideas, each on its own incident" "waits: each idea's own incident"
  plan_md T5 "It lands before the split (tasks/queued/split.md); the rest of tasks/queued/after-merge.md waits;
it builds two of tasks/queued/ideas.md."
  run_bin -0 team-queue index
  committed
  run_bin -0 team-queue tidy
  assert_equal "$output" ""
  nothing_written
  run -1 grep -l '^opened:' "$queued/split.md" "$queued/after-merge.md" "$queued/ideas.md"
}

@test "tidy links no cited item another item takes" {
  ready bundle.md 2 M "the bundle" "takes: node-pin.md"
  plan_md T5 "Cites tasks/queued/node-pin.md."
  run_bin -0 team-queue index
  committed
  run_bin -0 team-queue tidy
  assert_equal "$output" ""
  nothing_written
}

@test "tidy links no cited item whose from: names the citing task" {
  ready notes.md 3 S "T5's notes" "from: T2, T5"
  plan_md T5 "Cites tasks/queued/notes.md."
  run_bin -0 team-queue index
  committed
  run_bin -0 team-queue tidy
  assert_equal "$output" ""
  nothing_written
}

@test "tidy links no cited item whose project is none of the citing task's" {
  item elsewhere.md "summary: in the other project" "project: other" "priority: 2" "size: S"
  plan_md T5 "Cites tasks/queued/elsewhere.md."
  run_bin -0 team-queue index
  committed
  run_bin -0 team-queue tidy
  assert_equal "$output" ""
  nothing_written
}

@test "tidy links no item two open tasks' plans cite, which --check names, nor one only a closed task's plan cites" {
  plan_md T2 "Cites tasks/queued/node-pin.md and tasks/queued/bootstrap-drill.md."
  plan_md T5 "Cites tasks/queued/bootstrap-drill.md."
  opened_task T6
  event T6 closed
  plan_md T6 "Cites tasks/queued/node-pin.md."
  run_bin -0 team-queue index
  committed
  run_bin -0 team-queue tidy
  # node-pin.md's from: names T2 and T6 is closed, so neither may take it.
  assert_equal "$output" ""
  nothing_written
  run_bin -1 team-queue index --check
  assert_equal "$output" "tasks/queued/bootstrap-drill.md: cited by T2's and T5's plans: link it to one with team-queue take and give the other --part"
}

@test "tidy rewrites a stale index alone, and does nothing with no tasks/queued/" {
  committed
  run_bin -0 team-queue tidy
  assert_equal "$output" "wrote tasks/queued/index.md: 2 files"
  assert_equal "$(last_commit)" "chore: queued tidy
tasks/queued/index.md"
  run_bin -0 team-queue index --check
  git -C "${TEAM_HOME:?}" rm -rq tasks/queued
  git -C "${TEAM_HOME:?}" commit -qm "chore: no queue"
  local tip
  tip=$(git -C "${TEAM_HOME:?}" rev-parse HEAD)
  run_bin -0 --separate-stderr team-queue tidy
  assert_equal "$output" ""
  assert_equal "$stderr" ""
  [[ ! -e $queued ]]
  assert_equal "$(git -C "${TEAM_HOME:?}" rev-parse HEAD)" "$tip"
}

@test "tidy leaves an item queued whose task's queued/ holds its name already, says so and exits 1, moving the rest" {
  opened_task T6 research
  ready node-pin.md 2 S "pin Node 24" "opened: T5"
  ready closing.md 2 S "researched" "opened: T6"
  mkdir -p "$TEAM_HOME/tasks/T5/queued"
  echo "an earlier copy" >"$TEAM_HOME/tasks/T5/queued/node-pin.md"
  merged T5
  event T6 closed
  run_bin -0 team-queue index
  committed
  run_bin -1 --separate-stderr team-queue tidy
  assert_equal "$output" "moved closing.md to tasks/T6/queued/: T6 closed
wrote tasks/queued/index.md: 2 files"
  assert_equal "$stderr" "team-queue: left node-pin.md queued: tasks/T5/queued/node-pin.md is there already"
  assert_equal "$(cat "$TEAM_HOME/tasks/T5/queued/node-pin.md")" "an earlier copy"
  [[ -e $queued/node-pin.md ]]
  [[ -z $(git -C "${TEAM_HOME:?}" status --porcelain) ]]
}

@test "a tidy the team home's hooks refuse leaves its change written for the checkpoint, and exits 1" {
  ready node-pin.md 2 S "pin Node 24" "opened: T5"
  run_bin -0 team-queue index
  committed
  merged T5
  printf '#!/bin/sh\necho "refused by the test hook" >&2\nexit 1\n' >"$TEAM_HOME/.git/hooks/pre-commit"
  chmod +x "$TEAM_HOME/.git/hooks/pre-commit"
  run_bin -1 --separate-stderr team-queue tidy
  assert_equal "$output" "moved node-pin.md to tasks/T5/queued/: T5 merged
wrote tasks/queued/index.md: 1 file"
  assert_equal "$stderr" "team-queue: team home: cannot commit the records: refused by the test hook
team-queue: the change is written but not committed; the next checkpoint commits it"
  assert_equal "$(git -C "${TEAM_HOME:?}" rev-parse HEAD)" "$head"
  assert_equal "$(where)" "tasks/T5/queued/node-pin.md
tasks/queued/bootstrap-drill.md"
}

@test "tidy takes no argument, and refuses a worker session" {
  run_bin -2 team-queue tidy --all
  AGENT_TEAM_ROLE=builder run_bin -1 --separate-stderr team-queue tidy
  assert_equal "$stderr" "team-queue: a builder session edits no records: that is the coordinator's; send it your message"
}
