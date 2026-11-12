#!/usr/bin/env bats
# team-queue: the index of queued work, tasks/queued/index.md, written from each file's front
# matter (its title when it has none) and committed alone; --check naming a malformed file or a
# stale index; and migrate, moving tasks/current.md's queued lines into their files' front matter
# once, idempotent, keeping a line it cannot match to a file.

load helpers/common

setup() {
  sandbox
  queued=$TEAM_HOME/tasks/queued
  mkdir -p "$queued"
  printf 'ledger.jsonl.lock\n' >"$TEAM_HOME/.gitignore"
  printf '# Node pin\n\nPin Node 24.\n' >"$queued/node-pin.md"
  printf -- '---\nsummary: drill the bootstrap; waits on T258\ntask: T258\n---\n# Bootstrap drill\n\nThe body.\n' \
    >"$queued/bootstrap-drill.md"
  printf '# Current items\n' >"$TEAM_HOME/tasks/current.md"
  make_team_home >/dev/null
}

# The subject of the team home's last commit, and the paths it changed, on one line each.
last_commit() {
  git -C "$TEAM_HOME" log -1 --format=%s
  git -C "$TEAM_HOME" show --name-only --format= HEAD
}

@test "index lists each file by name, its front matter's summary and task, else its title, and commits the index alone" {
  run_bin -0 --separate-stderr team-queue index
  assert_equal "$output" "wrote tasks/queued/index.md: 2 files"
  assert_equal "$(cat "$queued/index.md")" "# Queued work

Written by \`team-queue index\` from each file's front matter (its title when it has none); edit the files, never this index.

- bootstrap-drill.md (T258): drill the bootstrap; waits on T258
- node-pin.md: Node pin"
  assert_equal "$(last_commit)" "chore: queued index
tasks/queued/index.md"
  [[ -z $(git -C "$TEAM_HOME" status --porcelain -- tasks/queued/index.md) ]]
  # A run that changes nothing commits nothing.
  local head
  head=$(git -C "$TEAM_HOME" rev-parse HEAD)
  run_bin -0 team-queue index
  assert_equal "$(git -C "$TEAM_HOME" rev-parse HEAD)" "$head"
}

@test "--check names each malformed file and a stale index, writing nothing" {
  run_bin -0 team-queue index
  run_bin -0 team-queue index --check
  assert_equal "$output" ""
  printf -- '---\nsummary: one\nsummary: two\nowner: kim\ntask: soon\n---\n' >"$queued/bad.md"
  printf -- '---\nsummary: open\n' >"$queued/open.md"
  run_bin -1 team-queue index --check
  assert_equal "$output" "tasks/queued/bad.md: summary given twice
tasks/queued/bad.md: front matter line \"owner: kim\" is no summary: or task:
tasks/queued/bad.md: task \"soon\" is not T<n> or -
tasks/queued/open.md: front matter has no closing ---
tasks/queued/index.md: not as team-queue index writes it"
  assert_equal "$(find "$queued" -name 'index.md.*')" ""
}

@test "--check of a stale index prints its one line and nothing more when cmp stops at the first difference with SIGPIPE ignored, as on macOS" {
  local n
  for n in $(seq -w 1 30); do printf -- '---\nsummary: item %s\n---\n' "$n" >"$queued/item-$n.md"; done
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

@test "--check of a stale index with a last file whose title ends in a carriage return names the stale index and exits 1" {
  run_bin -0 team-queue index
  printf '# item\r\n' >"$queued/zz-crlf.md"
  run_bin -1 --separate-stderr team-queue index --check
  assert_equal "$output" "tasks/queued/index.md: not as team-queue index writes it"
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
# Node pin

Pin Node 24."
  # The file's old front matter is replaced, its body kept.
  assert_equal "$(cat "$queued/bootstrap-drill.md")" "---
summary: rerun the drill on macOS; and on Arch
task: T258, T260
---
# Bootstrap drill

The body."
  assert_equal "$(sed -n '5,$p' "$queued/index.md")" "- bootstrap-drill.md (T258, T260): rerun the drill on macOS; and on Arch
- node-pin.md: pin Node, after the release"
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
