#!/usr/bin/env bats
# team-queue: the ranked index of queued work, tasks/queued/index.md, written from each file's
# front matter and the ledger (bin/lib/queue.jq) and committed alone; --check naming each
# malformed file, each item the heartbeat should have moved, each item two open tasks' plans cite,
# and a stale index; each after: condition met and unmet; and set, writing many files' front matter
# from one table in one commit, or refusing the whole table, naming each row, and writing nothing.

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
  item node-pin.md "summary: pin Node 24" "project: proj" "priority: 2" "size: S"
  item bootstrap-drill.md "summary: drill the bootstrap" "project: proj" "priority: 3" "size: M"
  printf '# Current items\n' >"$TEAM_HOME/tasks/current.md"
  make_team_home >/dev/null
}

# Write tasks/queued/<name> with the front matter lines given, then its title, "# <name less .md>":
# item <name> [<key>: <value>]...
item() {
  local name=$1
  shift
  { echo ---; printf '%s\n' "$@"; echo ---; echo "# ${name%.md}"; } >"$queued/$name"
}

# Write a ready item of project proj: ready <name> <priority> <size> <summary> [<key>: <value>]...
ready() {
  item "$1" "summary: $4" "project: proj" "priority: $2" "size: $3" "${@:5}"
}

# Append a merged of <task> to the ledger, with phases_left <json> when given, at <ts> (default
# 2026-01-01T00:00:00Z): merged <task> [<phases_left> [<ts>]]
merged() {
  jq -cn --arg task "$1" --arg left "${2:-}" --arg ts "${3:-2026-01-01T00:00:00Z}" \
    '{ts: $ts, task: $task, event: "merged", url: "https://github.com/owner/proj/pull/1"}
      + (if $left == "" then {} else {phases_left: ($left | fromjson)} end)' >>"$TEAM_HOME/ledger.jsonl"
}

# Append a closed of <task> to the ledger at <ts> (default 2026-01-01T00:00:00Z): closed <task> [<ts>]
closed() {
  jq -cn --arg task "$1" --arg ts "${2:-2026-01-01T00:00:00Z}" '{ts: $ts, task: $task, event: "closed"}' \
    >>"$TEAM_HOME/ledger.jsonl"
}

# The index from its first section on.
sections() {
  sed -n '5,$p' "$queued/index.md"
}

# The subject of the team home's last commit, and the paths it changed, on one line each.
last_commit() {
  git -C "$TEAM_HOME" log -1 --format=%s
  git -C "$TEAM_HOME" show --name-only --format= HEAD
}

@test "index ranks the ready items, then lists the waiting, opened and unranked ones, taken items under their taker, and commits the index alone" {
  rm "$queued/node-pin.md" "$queued/bootstrap-drill.md"
  opened_task T5
  opened_task T7
  ready a-three.md 3 S "the third"
  ready b-one.md 1 M "the first" "takes: c-taken.md"
  ready c-taken.md 2 S "carried with the first"
  ready d-two.md 2 L "the second" "guarded: ci, deploy"
  ready e-wait.md 1 S "a later one" "after: T7 merged" "waits: Daniel's word on baselines" "alone: yes"
  ready f-opened.md 2 S "in the building" "opened: T5"
  ready g-bad.md 5 S "a bad one"
  run_bin -0 --separate-stderr team-queue index
  assert_equal "$output" "wrote tasks/queued/index.md: 7 files"
  assert_equal "$(cat "$queued/index.md")" "# Queued work

Written by \`team-queue index\` from each file's front matter and the ledger; edit the files, never this index.

## Ready, ranked

1. b-one.md (proj, priority 1, M): the first
   - takes c-taken.md: carried with the first
2. d-two.md (proj, priority 2, L, guarded: ci, deploy): the second
3. a-three.md (proj, priority 3, S): the third

## Waiting

- e-wait.md (proj, priority 1, S, alone): a later one; waits for Daniel's word on baselines, T7 merged

## Opened

- f-opened.md (proj, T5): in the building

## Unranked

- g-bad.md: priority \"5\" is not 1, 2, 3 or 4"
  assert_equal "$(last_commit)" "chore: queued index
tasks/queued/index.md"
  [[ -z $(git -C "$TEAM_HOME" status --porcelain -- tasks/queued/index.md) ]]
  # A run that changes nothing commits nothing.
  local head
  head=$(git -C "$TEAM_HOME" rev-parse HEAD)
  run_bin -0 team-queue index
  assert_equal "$(git -C "$TEAM_HOME" rev-parse HEAD)" "$head"
  [[ -z $(find "$queued" -name 'index.md.*') ]]
}

@test "items of one priority rank by how many items wait on them, then by size, then by name, and the waiting ones in the same order" {
  rm "$queued/node-pin.md" "$queued/bootstrap-drill.md"
  opened_task T9
  ready x-small.md 2 S "x"
  ready y-medium.md 2 M "y"
  ready w-small.md 2 S "w"
  ready z-large.md 2 L "z"
  ready v-later.md 3 S "v" "after: z-large.md"
  ready u-later.md 3 S "u" "after: z-large.md, T9 merged"
  ready t-later.md 3 M "t" "after: T9 merged"
  ready s-first.md 1 L "s"
  run_bin -0 team-queue index
  assert_equal "$(sections)" "## Ready, ranked

1. s-first.md (proj, priority 1, L): s
2. z-large.md (proj, priority 2, L): z
3. w-small.md (proj, priority 2, S): w
4. x-small.md (proj, priority 2, S): x
5. y-medium.md (proj, priority 2, M): y

## Waiting

- u-later.md (proj, priority 3, S): u; waits for z-large.md, T9 merged
- v-later.md (proj, priority 3, S): v; waits for z-large.md
- t-later.md (proj, priority 3, M): t; waits for T9 merged"
}

@test "each after: condition is met and unmet: a whole merge, a phase's merge, a close, a date and an item that left the queue" {
  rm "$queued/node-pin.md" "$queued/bootstrap-drill.md"
  local t
  for t in T1 T2 T3 T4; do opened_task "$t"; done
  merged T1 '[]'
  merged T2 '[2, 3]'
  closed T4
  mkdir -p "$TEAM_HOME/tasks/T1/queued"
  printf '# gone\n' >"$TEAM_HOME/tasks/T1/queued/gone.md"
  ready a-merged.md 2 S "a" "after: T1 merged"
  ready b-unmerged.md 2 S "b" "after: T3 merged"
  ready c-part-merged.md 2 S "c" "after: T2 merged"
  ready d-phase-met.md 2 S "d" "after: T2 phase 1 merged"
  ready e-phase-unmet.md 2 S "e" "after: T2 phase 2 merged"
  ready f-phase-whole.md 2 S "f" "after: T1 phase 4 merged"
  ready g-closed.md 2 S "g" "after: T4 closed"
  ready h-open.md 2 S "h" "after: T3 closed"
  ready i-today.md 2 S "i" "after: 2026-11-13"
  ready j-tomorrow.md 2 S "j" "after: 2026-11-14"
  ready k-left.md 2 S "k" "after: gone.md"
  ready l-still.md 2 S "l" "after: a-merged.md"
  ready m-all.md 2 S "m" "after: T1 merged, T4 closed, 2026-11-12, gone.md"
  TEAM_QUEUE_TODAY=2026-11-13 run_bin -0 team-queue index
  assert_equal "$(sections)" "## Ready, ranked

1. a-merged.md (proj, priority 2, S): a
2. d-phase-met.md (proj, priority 2, S): d
3. f-phase-whole.md (proj, priority 2, S): f
4. g-closed.md (proj, priority 2, S): g
5. i-today.md (proj, priority 2, S): i
6. k-left.md (proj, priority 2, S): k
7. m-all.md (proj, priority 2, S): m

## Waiting

- b-unmerged.md (proj, priority 2, S): b; waits for T3 merged
- c-part-merged.md (proj, priority 2, S): c; waits for T2 merged
- e-phase-unmet.md (proj, priority 2, S): e; waits for T2 phase 2 merged
- h-open.md (proj, priority 2, S): h; waits for T3 closed
- j-tomorrow.md (proj, priority 2, S): j; waits for 2026-11-14
- l-still.md (proj, priority 2, S): l; waits for a-merged.md"
  # The day after, the date is met; a TEAM_QUEUE_TODAY that is no date is a usage error.
  TEAM_QUEUE_TODAY=2026-11-14 run_bin -0 team-queue index
  [[ $(sections) == *"j-tomorrow.md (proj, priority 2, S): j"$'\n'* ]]
  TEAM_QUEUE_TODAY=soon run_bin -2 --separate-stderr team-queue index
  assert_equal "$stderr" "team-queue: TEAM_QUEUE_TODAY \"soon\" is not a YYYY-MM-DD date"
}

@test "a task merged whole is one the ledger's lifecycle leaves merged, so a merge logged with no phases_left that a builder launch or a merged part follows is none" {
  rm "$queued/node-pin.md" "$queued/bootstrap-drill.md"
  local t
  for t in T1 T2 T3; do opened_task "$t"; done
  merged T1
  # T2's merge was logged before team-merge logged phases_left, and its builder went on building.
  merged T2
  jq -cn '{ts: "2026-01-01T00:00:00Z", task: "T2", event: "launch", role: "builder", session: "b2"}' >>"$TEAM_HOME/ledger.jsonl"
  # T3's first merge too, then a merge that names phase 3 still to build.
  merged T3
  merged T3 '[3]'
  ready a-done.md 2 S "a" "opened: T1"
  ready b-going.md 2 S "b" "opened: T2"
  ready c-part.md 2 S "c" "opened: T3"
  ready d-whole.md 2 S "d" "after: T1 merged"
  ready e-going.md 2 S "e" "after: T2 merged"
  ready f-part.md 2 S "f" "after: T3 merged"
  ready g-phase-met.md 2 S "g" "after: T3 phase 2 merged"
  ready h-phase-left.md 2 S "h" "after: T3 phase 3 merged"
  ready i-phase-unknown.md 2 S "i" "after: T2 phase 2 merged"
  ready j-phase-whole.md 2 S "j" "after: T1 phase 2 merged"
  run_bin -0 team-queue index
  assert_equal "$(sections)" "## Ready, ranked

1. d-whole.md (proj, priority 2, S): d
2. g-phase-met.md (proj, priority 2, S): g
3. j-phase-whole.md (proj, priority 2, S): j

## Waiting

- e-going.md (proj, priority 2, S): e; waits for T2 merged
- f-part.md (proj, priority 2, S): f; waits for T3 merged
- h-phase-left.md (proj, priority 2, S): h; waits for T3 phase 3 merged
- i-phase-unknown.md (proj, priority 2, S): i; waits for T2 phase 2 merged

## Opened

- b-going.md (proj, T2): b
- c-part.md (proj, T3): c

## Unranked

- a-done.md: T1 merged at 2026-01-01T00:00:00Z but it is still queued; the heartbeat's queue step moves it (team-queue tidy)"
}

@test "--check names each malformed file, keeping T303's problems and refusing task:, and a stale index, writing nothing" {
  run_bin -0 team-queue index
  run_bin -0 team-queue index --check
  assert_equal "$output" ""
  opened_task T5
  printf -- '---\nsummary: one\nsummary: two\nowner: kim\njust text\ntask: T5\nproject: proj\npriority: 2\nsize: S\n---\n# keys\n' \
    >"$queued/a-keys.md"
  printf -- '---\nsummary: open\n' >"$queued/b-open.md"
  item c-missing.md "summary: the bare minimum"
  item d-values.md "summary: d" "project: nope" "priority: 5" "size: XL" "alone: no" "waits:"
  ready e-after.md 2 S "e" "after: soon, T99 merged, T5 phase 0 merged, 2026-02-30, nowhere.md"
  ready f-links.md 2 S "f" "from: T98, sometime" "opened: T97"
  ready g-takes.md 2 S "g" "takes: nowhere.md, g-takes.md, h-taker.md, i-built.md"
  ready h-taker.md 2 S "h" "takes: node-pin.md"
  ready i-built.md 2 S "i" "opened: T5"
  item j-empty.md "summary:" "project: proj" "priority: 2" "size: S"
  printf -- '---\nproject: proj\npriority: 2\nsize: S\n---\nno title\n' >"$queued/k-untitled.md"
  ready l-takes-bad.md 2 S "l" "takes: T5" "opened: soon"
  run_bin -1 team-queue index --check
  assert_equal "$output" "tasks/queued/a-keys.md: summary given twice
tasks/queued/a-keys.md: front matter line \"just text\" is no <key>: <value>
tasks/queued/a-keys.md: front matter key \"owner\" is none team-queue reads (team-queue --help)
tasks/queued/a-keys.md: task: is from: since T305 (the tasks it came from)
tasks/queued/b-open.md: front matter has no closing ---
tasks/queued/b-open.md: it has no project
tasks/queued/b-open.md: it has no priority (1, 2, 3 or 4)
tasks/queued/b-open.md: it has no size (S, M or L)
tasks/queued/c-missing.md: it has no project
tasks/queued/c-missing.md: it has no priority (1, 2, 3 or 4)
tasks/queued/c-missing.md: it has no size (S, M or L)
tasks/queued/d-values.md: project \"nope\" is not in projects.toml
tasks/queued/d-values.md: priority \"5\" is not 1, 2, 3 or 4
tasks/queued/d-values.md: size \"XL\" is not S, M or L
tasks/queued/d-values.md: its waits is empty
tasks/queued/d-values.md: alone \"no\" is not yes
tasks/queued/e-after.md: after \"soon\" is not T<n> merged, T<n> phase <k> merged, T<n> closed, a YYYY-MM-DD date or a queued file
tasks/queued/e-after.md: after names T99, which the ledger does not hold
tasks/queued/e-after.md: after \"T5 phase 0 merged\" is not T<n> merged, T<n> phase <k> merged, T<n> closed, a YYYY-MM-DD date or a queued file
tasks/queued/e-after.md: after \"2026-02-30\" is not T<n> merged, T<n> phase <k> merged, T<n> closed, a YYYY-MM-DD date or a queued file
tasks/queued/e-after.md: after names nowhere.md, which is neither queued nor in a task's queued/
tasks/queued/f-links.md: from names T98, which the ledger does not hold
tasks/queued/f-links.md: from \"sometime\" is not T<n>
tasks/queued/f-links.md: opened names T97, which the ledger does not hold
tasks/queued/g-takes.md: takes nowhere.md, which is not queued
tasks/queued/g-takes.md: takes itself
tasks/queued/g-takes.md: takes h-taker.md, which takes others
tasks/queued/g-takes.md: takes i-built.md, which T5 opened
tasks/queued/j-empty.md: its summary is empty
tasks/queued/k-untitled.md: it has no summary and no title
tasks/queued/l-takes-bad.md: opened \"soon\" is not T<n>
tasks/queued/l-takes-bad.md: takes \"T5\" is not a queued file
tasks/queued/index.md: not as team-queue index writes it"
  [[ -z $(find "$queued" -name 'index.md.*') ]]
  [[ -z $(git -C "$TEAM_HOME" status --porcelain -- tasks/queued/index.md) ]]
}

@test "--check names an item whose task merged whole or closed over 15 minutes ago, never one in its grace or a merged part" {
  local t now
  for t in T5 T6 T7 T8; do opened_task "$t"; done
  now=$(date -u +%FT%TZ)
  merged T5
  closed T6 2026-01-02T03:04:05Z
  merged T7 '[2]'
  merged T8 '' "$now"
  ready a-merged.md 2 S "a" "opened: T5"
  ready b-closed.md 2 S "b" "opened: T6"
  ready c-part.md 2 S "c" "opened: T7"
  ready d-grace.md 2 S "d" "opened: T8"
  run_bin -0 team-queue index
  run_bin -1 team-queue index --check
  assert_equal "$output" "tasks/queued/a-merged.md: T5 merged at 2026-01-01T00:00:00Z but it is still queued; the heartbeat's queue step moves it (team-queue tidy)
tasks/queued/b-closed.md: T6 closed at 2026-01-02T03:04:05Z but it is still queued; the heartbeat's queue step moves it (team-queue tidy)"
  assert_equal "$(sections)" "## Ready, ranked

1. node-pin.md (proj, priority 2, S): pin Node 24
2. bootstrap-drill.md (proj, priority 3, M): drill the bootstrap

## Opened

- c-part.md (proj, T7): c
- d-grace.md (proj, T8): d

## Unranked

- a-merged.md: T5 merged at 2026-01-01T00:00:00Z but it is still queued; the heartbeat's queue step moves it (team-queue tidy)
- b-closed.md: T6 closed at 2026-01-02T03:04:05Z but it is still queued; the heartbeat's queue step moves it (team-queue tidy)"
}

@test "--check names an item two open tasks' plans cite, but not one only one of them may take" {
  local t
  for t in T5 T6 T7; do opened_task "$t"; done
  closed T7
  jq -cn '{ts: "2026-01-01T00:00:00Z", task: "T8", event: "opened", project: "other", path: "small", type: "fix",
    title: "X", branch: "fix/T8-x", base: "main", base_sha: "0000000000000000000000000000000000000000", worktree: "/w/T8"}' \
    >>"$TEAM_HOME/ledger.jsonl"
  ready a-shared.md 2 S "a"
  ready b-from.md 2 S "b" "from: T6"
  ready c-taken.md 2 S "c"
  ready d-taker.md 2 S "d" "takes: c-taken.md"
  ready e-closed.md 2 S "e"
  ready f-other.md 2 S "f"
  plan_md T5 "# T5 plan

Builds \`~/agent-team-records/tasks/queued/a-shared.md\`, tasks/queued/b-from.md, tasks/queued/c-taken.md,
tasks/queued/e-closed.md and tasks/queued/f-other.md."
  plan_md T6 "# T6 plan

Builds tasks/queued/a-shared.md and tasks/queued/b-from.md and tasks/queued/c-taken.md."
  plan_md T7 "Cites tasks/queued/e-closed.md."
  plan_md T8 "Cites tasks/queued/f-other.md and tasks/queued/a-shared.md."
  run_bin -0 team-queue index
  run_bin -1 team-queue index --check
  assert_equal "$output" "tasks/queued/a-shared.md: cited by T5's and T6's plans: link it to one with team-queue take and give the other --part"
}

@test "--check names an unreadable registry once and checks no project, and the index is still written" {
  rm "$TEAM_HOME/projects.toml"
  item node-pin.md "summary: pin Node 24" "project: nope" "priority: 2" "size: S"
  run_bin -0 team-queue index
  assert_equal "$(sections)" "## Ready, ranked

1. node-pin.md (nope, priority 2, S): pin Node 24
2. bootstrap-drill.md (proj, priority 3, M): drill the bootstrap"
  run_bin -1 team-queue index --check
  assert_equal "$output" "tasks/queued/: projects not checked: no registry at $TEAM_HOME/projects.toml"
}

@test "--check of a stale index prints its one line and nothing more when cmp stops at the first difference with SIGPIPE ignored, as on macOS" {
  local n
  for n in $(seq -w 1 30); do ready "item-$n.md" 2 S "item $n"; done
  echo stale >"$queued/index.md"
  # macOS's cmp exits at the first byte that differs, where GNU's reads a whole buffer first; this
  # one stops after the first line, so whatever is written to it after that finds no reader.
  stub_command cmp
  stub_script cmp <<<'IFS= read -r _ || true; exit 1'
  # Ignored on entry, SIGPIPE stays ignored in every process the script starts, as on CI's macOS
  # runners, so a write to a reader that stopped early fails with an error on stderr instead of
  # ending the writer quietly.
  run --separate-stderr bash -c 'trap "" PIPE; exec "$0" index --check' "$REPO_ROOT/bin/team-queue"
  assert_equal "$status" 1
  assert_equal "$output" "tasks/queued/index.md: not as team-queue index writes it"
  assert_equal "$stderr" ""
}

@test "a carriage return in a file's front matter is escaped, so --check of a stale index names it and exits 1, and index writes it" {
  run_bin -0 team-queue index
  printf -- '---\nsummary: item\r\nproject: proj\npriority: 2\nsize: S\n---\n# item\r\n' >"$queued/zz-crlf.md"
  run_bin -1 --separate-stderr team-queue index --check
  assert_equal "$output" "tasks/queued/index.md: not as team-queue index writes it"
  run_bin -0 team-queue index
  run_bin -0 team-queue index --check
  [[ $(cat "$queued/index.md") == *"zz-crlf.md (proj, priority 2, S): item"$'\r'* ]]
}

@test "set writes each row's keys in team-queue's order, an empty cell removing one, keeps the other keys and the body, drops task:, and commits the rows' files with the index" {
  opened_task T5
  printf -- '---\ntask: T5\nguarded: ci\nsummary: old words\n---\n# legacy\n\nThe body stays.\n---\n' >"$queued/legacy.md"
  printf '# no front matter\n\nBody only.\n' >"$queued/bare.md"
  item node-pin.md "summary: pin Node 24" "waits: the release" "project: proj" "priority: 2" "size: S"
  git -C "$TEAM_HOME" add -A
  git -C "$TEAM_HOME" commit -q -m "chore: queue three"
  item untouched.md "summary: not in the table" "project: proj"
  local table=$BATS_TEST_TMPDIR/table.tsv
  printf '%s\n' $'file\tsummary\tproject\tpriority\tsize\tfrom\twaits' \
    $'legacy.md\tthe legacy item\tproj\t2\tM\tT5\t' \
    $'bare.md\ta bare item \tother\t4\tS\t\tDaniel\'s word' \
    '' \
    $'node-pin.md\tpin Node 24\tproj\t1\tS\t\t' >"$table"
  run_bin -1 --separate-stderr team-queue set "$table"
  assert_equal "$output" "set 3 files
wrote tasks/queued/index.md: 5 files
tasks/queued/untouched.md: it has no priority (1, 2, 3 or 4)
tasks/queued/untouched.md: it has no size (S, M or L)"
  assert_equal "$stderr" ""
  assert_equal "$(cat "$queued/legacy.md")" "---
summary: the legacy item
project: proj
priority: 2
size: M
from: T5
guarded: ci
---
# legacy

The body stays.
---"
  assert_equal "$(cat "$queued/bare.md")" "---
summary: a bare item
project: other
priority: 4
size: S
waits: Daniel's word
---
# no front matter

Body only."
  assert_equal "$(cat "$queued/node-pin.md")" "---
summary: pin Node 24
project: proj
priority: 1
size: S
---
# node-pin"
  assert_equal "$(last_commit | LC_ALL=C sort)" "chore: queued set
tasks/queued/bare.md
tasks/queued/index.md
tasks/queued/legacy.md
tasks/queued/node-pin.md"
  # A file the table does not name is left out of the commit.
  assert_equal "$(git -C "$TEAM_HOME" status --porcelain -- tasks/queued)" "?? tasks/queued/untouched.md"
  [[ -z $(find "$queued" -name '*.md.*') ]]
  # A table of one row, written with CRLF line ends, sets one file, and with nothing left to name it exits 0.
  printf 'file\tpriority\tsize\r\nuntouched.md\t3\tS\r\n' >"$table"
  run_bin -0 --separate-stderr team-queue set "$table"
  assert_equal "$output" "set 1 file
wrote tasks/queued/index.md: 5 files"
  assert_equal "$(cat "$queued/untouched.md")" "---
summary: not in the table
project: proj
priority: 3
size: S
---
# untouched"
  run_bin -0 team-queue index --check
}

@test "set refuses a table whose header is not file and front matter keys, writing nothing" {
  local table=$BATS_TEST_TMPDIR/table.tsv head
  head=$(git -C "$TEAM_HOME" rev-parse HEAD)
  printf '%s\n' $'name\tpriority\towner\tsize\tsize\tfile' $'node-pin.md\t1\tkim\tS\tS\tx' >"$table"
  run_bin -1 --separate-stderr team-queue set "$table"
  assert_equal "$output" "$table:1: the header's first column is \"name\", not file
$table:1: column \"owner\" is no front matter key (team-queue --help)
$table:1: column \"size\" is given twice
$table:1: column \"file\" is no front matter key (team-queue --help)"
  assert_equal "$stderr" "team-queue: the table is refused whole, so nothing is written"
  : >"$table"
  run_bin -1 team-queue set "$table"
  assert_equal "$output" "$table:1: the table has no header line
team-queue: the table is refused whole, so nothing is written"
  assert_equal "$(git -C "$TEAM_HOME" rev-parse HEAD)" "$head"
  [[ ! -e $queued/index.md ]]
}

@test "set refuses the whole table, naming each row, on a file not queued, a row's cells, a malformed file and a value --check refuses, writing nothing" {
  printf -- '---\nsummary: broken\nproject: proj\n# broken\n' >"$queued/broken.md"
  printf -- '---\nsummary: twice\nsummary: again\nproject: proj\npriority: 2\nsize: S\n---\n# twice\n' >"$queued/twice.md"
  ready fine.md 2 S "fine"
  item unnamed.md "summary: not in the table"
  git -C "$TEAM_HOME" add -A
  git -C "$TEAM_HOME" commit -q -m "chore: queue four"
  local table=$BATS_TEST_TMPDIR/table.tsv head before
  head=$(git -C "$TEAM_HOME" rev-parse HEAD)
  before=$(cat "$queued"/*.md | cksum)
  printf '%s\n' $'file\tproject\tpriority\tsize\tafter\ttakes' \
    $'gone.md\tproj\t2\tS\t\t' \
    $'index.md\tproj\t2\tS\t\t' \
    $'node-pin.md\tnope\t5\tXL\tsoon\tnowhere.md' \
    $'bootstrap-drill.md\t\t3\tM\t\t' \
    $'fine.md\tproj\t2' \
    $'broken.md\tproj\t2\tS\t\t' \
    $'twice.md\tproj\t2\tS\t\t' \
    $'node-pin.md\tproj\t2\tS\t\t' \
    $'unnamed.md\tproj\t2\tS\t\tunnamed.md' >"$table"
  run_bin -1 --separate-stderr team-queue set "$table"
  assert_equal "$output" "$table:2: gone.md is not queued
$table:3: index.md is not queued
$table:4: tasks/queued/node-pin.md: project \"nope\" is not in projects.toml
$table:4: tasks/queued/node-pin.md: priority \"5\" is not 1, 2, 3 or 4
$table:4: tasks/queued/node-pin.md: size \"XL\" is not S, M or L
$table:4: tasks/queued/node-pin.md: after \"soon\" is not T<n> merged, T<n> phase <k> merged, T<n> closed, a YYYY-MM-DD date or a queued file
$table:4: tasks/queued/node-pin.md: takes nowhere.md, which is not queued
$table:5: tasks/queued/bootstrap-drill.md: it has no project
$table:6: it has 3 cells and the header 6
$table:7: tasks/queued/broken.md: front matter line \"# broken\" is no <key>: <value>, which set cannot rewrite: fix the file by hand first
$table:7: tasks/queued/broken.md: front matter has no closing ---, which set cannot rewrite: fix the file by hand first
$table:8: tasks/queued/twice.md: summary given twice, which set cannot rewrite: fix the file by hand first
$table:9: node-pin.md is on line 4 too
$table:10: tasks/queued/unnamed.md: takes itself"
  assert_equal "$stderr" "team-queue: the table is refused whole, so nothing is written"
  assert_equal "$(cat "$queued"/*.md | cksum)" "$before"
  assert_equal "$(git -C "$TEAM_HOME" rev-parse HEAD)" "$head"
  [[ -z $(git -C "$TEAM_HOME" status --porcelain) ]]
  [[ -z $(find "$queued" -name '*.md.*') ]]
}

@test "set takes one table that exists" {
  run_bin -2 team-queue set
  run_bin -2 team-queue set a.tsv b.tsv
  run_bin -1 --separate-stderr team-queue set "$BATS_TEST_TMPDIR/none.tsv"
  assert_equal "$stderr" "team-queue: no table at $BATS_TEST_TMPDIR/none.tsv"
}

@test "a worker session is refused, and a malformed command line is a usage error" {
  AGENT_TEAM_ROLE=builder run_bin -1 --separate-stderr team-queue index
  assert_equal "$stderr" "team-queue: a builder session edits no records: that is the coordinator's; send it your message"
  [[ ! -e $queued/index.md ]]
  run_bin -2 team-queue
  run_bin -2 team-queue index --all
  run_bin -2 team-queue migrate
  AGENT_TEAM_ROLE=builder run_bin -1 team-queue set "$BATS_TEST_TMPDIR/none.tsv"
  run_bin -2 team-queue list
}
