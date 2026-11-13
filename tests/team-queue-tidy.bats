#!/usr/bin/env bats
# team-queue take: linking queued items to the task that builds them, opened: T<n> or with --part
# T<n> in from:, in one commit with the index, or refusing every file and writing nothing.

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

# The subject of the team home's last commit, and the paths it changed, on one line each.
last_commit() {
  git -C "$TEAM_HOME" log -1 --format=%s
  git -C "$TEAM_HOME" show --name-only --format= HEAD
}

# Commit what the test wrote, and note the head and the queued files' sum, for nothing_written.
committed() {
  git -C "$TEAM_HOME" add -A
  git -C "$TEAM_HOME" commit -q --allow-empty -m "chore: the test's queue"
  head=$(git -C "$TEAM_HOME" rev-parse HEAD)
  before=$(cat "$queued"/*.md | cksum)
}

# Nothing changed since committed: the head, the files, a clean status and no temporary file.
nothing_written() {
  assert_equal "$(git -C "$TEAM_HOME" rev-parse HEAD)" "$head"
  assert_equal "$(cat "$queued"/*.md | cksum)" "$before"
  [[ -z $(git -C "$TEAM_HOME" status --porcelain) ]]
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
  [[ -z $(git -C "$TEAM_HOME" status --porcelain) ]]
  # Taking it again, a file named twice, changes nothing and says the same.
  local head
  head=$(git -C "$TEAM_HOME" rev-parse HEAD)
  run_bin -0 --separate-stderr team-queue take T5 node-pin.md node-pin.md
  assert_equal "$output" "took node-pin.md for T5"
  assert_equal "$(git -C "$TEAM_HOME" rev-parse HEAD)" "$head"
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
  assert_equal "$(git -C "$TEAM_HOME" log -1 --format=%s)" "chore: queued take T5"
  local head
  head=$(git -C "$TEAM_HOME" rev-parse HEAD)
  run_bin -0 team-queue take T5 --part node-pin.md
  assert_equal "$(grep '^from:' "$queued/node-pin.md")" "from: T2, T5"
  assert_equal "$(git -C "$TEAM_HOME" rev-parse HEAD)" "$head"
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
  [[ -z $(git -C "$TEAM_HOME" status --porcelain) ]]
}
