#!/usr/bin/env bats
# team-queue: the ranked index of queued work, tasks/queued/index.md, written from each file's
# front matter and the ledger (bin/lib/queue.jq) and committed alone; --check naming each
# malformed file, each item the heartbeat should have moved, each item two open tasks' plans cite,
# and a stale index; each after: condition met and unmet; and migrate, moving tasks/current.md's
# queued lines into their files' front matter once, idempotent, keeping a line it cannot match to
# a file.

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

@test "migrate moves each queued line into its file's front matter, joining two for one file, and a second run changes nothing" {
  local tilde='~'
  ln -s "$TEAM_HOME" "$HOME/team"
  cat >>"$TEAM_HOME/tasks/current.md" <<EOF
- next T4 once it merges, open the Node pin task | tasks/queued/node-pin.md
- queued - pin Node, after the release | tasks/queued/node-pin.md
- queued T258 rerun the drill on macOS | $tilde/team/tasks/queued/bootstrap-drill.md
- queued T260 and on Arch | tasks/queued/bootstrap-drill.md
EOF
  run_bin -0 --separate-stderr team-queue migrate
  assert_equal "$output" "migrated 3 lines into 2 files
wrote tasks/queued/index.md: 2 files"
  assert_equal "$(cat "$TEAM_HOME/tasks/current.md")" "# Current items
- next T4 once it merges, open the Node pin task | tasks/queued/node-pin.md"
  assert_equal "$(cat "$queued/node-pin.md")" "---
summary: pin Node, after the release
task: -
---
# node-pin"
  # The file's old front matter is replaced, its body kept.
  assert_equal "$(cat "$queued/bootstrap-drill.md")" "---
summary: rerun the drill on macOS; and on Arch
task: T258, T260
---
# bootstrap-drill"
  assert_equal "$(last_commit | sort)" "chore: queued migrate
tasks/current.md
tasks/queued/bootstrap-drill.md
tasks/queued/index.md
tasks/queued/node-pin.md"
  local head
  head=$(git -C "$TEAM_HOME" rev-parse HEAD)
  run_bin -0 team-queue migrate
  assert_equal "$output" "migrated 0 lines into 0 files
wrote tasks/queued/index.md: 2 files"
  assert_equal "$(git -C "$TEAM_HOME" rev-parse HEAD)" "$head"
}

@test "migrate keeps a line whose where names no file in tasks/queued/, naming it, after migrating the rest" {
  mkdir -p "$TEAM_HOME/tasks/T4"
  echo "# Plan" >"$TEAM_HOME/tasks/T4/plan.md"
  cat >>"$TEAM_HOME/tasks/current.md" <<'EOF'
- queued - pin Node | tasks/queued/node-pin.md
- queued - an old one | ledger 2026-10-29T00:00:00Z
- queued T4 the plan's | tasks/T4/plan.md
- queued - gone | tasks/queued/gone.md
EOF
  run_bin -1 --separate-stderr team-queue migrate
  assert_equal "$output" "migrated 1 line into 1 file
wrote tasks/queued/index.md: 2 files
tasks/current.md:3: ledger 2026-10-29T00:00:00Z is no file in tasks/queued/
tasks/current.md:4: tasks/T4/plan.md is no file in tasks/queued/
tasks/current.md:5: tasks/queued/gone.md is no file in tasks/queued/"
  assert_equal "$(cat "$TEAM_HOME/tasks/current.md")" "# Current items
- queued - an old one | ledger 2026-10-29T00:00:00Z
- queued T4 the plan's | tasks/T4/plan.md
- queued - gone | tasks/queued/gone.md"
  assert_equal "$(sed -n 2p "$queued/node-pin.md")" "summary: pin Node"
}

@test "a worker session is refused, and a malformed command line is a usage error" {
  AGENT_TEAM_ROLE=builder run_bin -1 --separate-stderr team-queue index
  assert_equal "$stderr" "team-queue: a builder session edits no records: that is the coordinator's; send it your message"
  [[ ! -e $queued/index.md ]]
  run_bin -2 team-queue
  run_bin -2 team-queue index --all
  run_bin -2 team-queue migrate now
  run_bin -2 team-queue list
}
