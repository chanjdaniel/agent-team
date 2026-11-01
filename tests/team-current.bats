#!/usr/bin/env bats
# team-current: the coordinator's current items in the team home's tasks/current.md, added, listed
# and removed by a short id, checked against the manual's rules, each change committed alone.

load helpers/common

setup() {
  sandbox
  mkdir -p "$TEAM_HOME/tasks/queued" "$TEAM_HOME/tasks/T4"
  printf 'ledger.jsonl.lock\n' >"$TEAM_HOME/.gitignore"
  echo "# Node pin" >"$TEAM_HOME/tasks/queued/node-pin.md"
  echo "# Plan" >"$TEAM_HOME/tasks/T4/plan.md"
  printf '# Current items\n' >"$TEAM_HOME/tasks/current.md"
  team_origin=$(make_team_home)
  current=$TEAM_HOME/tasks/current.md
  # The team home under HOME, as ~/team, for a where in the ~/ form.
  ln -s "$TEAM_HOME" "$HOME/team"
  # A where as the coordinator types it, starting with a literal ~/.
  tilde='~'
}

# The id of an item line: the first 6 hex digits of the sha256 of the line without its "- ".
id_of() {
  printf '%s' "${1#- }" | sha256sum | cut -c1-6
}

# The subject of the team home's last commit, and the paths it changed, on one line each.
last_commit() {
  git -C "$TEAM_HOME" log -1 --format=%s
  git -C "$TEAM_HOME" show --name-only --format= HEAD
}

@test "add prints the item's id and appends its line; list prints each item with its id" {
  run_bin -0 --separate-stderr team-current add owe - the T4 summary, my move --where https://discord.com/channels/1/2/3
  local first="- owe - the T4 summary, my move | https://discord.com/channels/1/2/3"
  assert_equal "${lines[0]}" "$(id_of "$first")"
  [[ ${lines[0]} =~ ^[0-9a-f]{6}$ ]]
  run_bin -0 team-current add next T4 "once it merges, open the Node pin task" --where tasks/queued/node-pin.md
  local second="- next T4 once it merges, open the Node pin task | tasks/queued/node-pin.md"
  assert_equal "$(cat "$current")" "# Current items
$first
$second"
  run_bin -0 team-current list
  assert_equal "$output" "$(id_of "$first") ${first#- }
$(id_of "$second") ${second#- }"
}

@test "done with the id or a unique 4-digit prefix removes exactly that line" {
  local a="- ask - which domain for the docs site, Daniel's move | 1563000000000000045"
  local b="- watch T4 the CI wait on PR 7, re-arm with team-ci-wait | ledger 2026-11-01T07:08:11Z"
  local c="- queued - the Node pin | ~/team/tasks/queued/node-pin.md"
  printf '%s\n' "# Current items" "" "$a" "$b" "$c" >"$current"
  git -C "$TEAM_HOME" commit -q -am "chore: items"
  run_bin -0 team-current "done" "$(id_of "$b")"
  assert_contains "$output" "removed $(id_of "$b") ${b#- }"
  assert_equal "$(cat "$current")" "$(printf '%s\n' "# Current items" "" "$a" "$c")"
  local prefix
  prefix=$(id_of "$a")
  run_bin -0 team-current "done" "${prefix:0:4}"
  assert_equal "$(cat "$current")" "$(printf '%s\n' "# Current items" "" "$c")"
}

@test "add refuses each line the manual does not allow, file unchanged and nothing committed" {
  local before head long
  printf '%s\n' "# Current items" "- next T4 open the Node pin task | tasks/queued/node-pin.md" >"$current"
  git -C "$TEAM_HOME" commit -q -am "chore: items"
  before=$(cat "$current") head=$(git -C "$TEAM_HOME" rev-parse HEAD)
  long=$(printf 'x%.0s' {1..280})
  mkdir -p "$BATS_TEST_TMPDIR/job"
  echo out >"$BATS_TEST_TMPDIR/job/out.md"
  check_refusal() {
    local reason=$1
    shift
    run_bin -1 --separate-stderr team-current add "$@"
    assert_contains "$stderr" "$reason"
    assert_equal "$(cat "$current")" "$before"
    assert_equal "$(git -C "$TEAM_HOME" rev-parse HEAD)" "$head"
    assert_equal "$(git -C "$TEAM_HOME" status --porcelain)" ""
  }
  check_refusal "kind 'todo' is not ask, owe, next, queued or watch" todo - a thing --where tasks/queued/node-pin.md
  check_refusal "task 'T4a' is not T<n> or -" next T4a a thing --where tasks/queued/node-pin.md
  check_refusal "task '-:' is not T<n> or -" next -: a thing --where tasks/queued/node-pin.md
  check_refusal "the text holds ' | '" next - "a | b" --where tasks/queued/node-pin.md
  check_refusal "the text holds a newline" next - "a
b" --where tasks/queued/node-pin.md
  check_refusal "the line is 316 characters, over 300" next - "$long" --where tasks/queued/node-pin.md
  check_refusal "the where '/tmp/notes.md' is a temp path" next - a thing --where /tmp/notes.md
  check_refusal "the where '/var/tmp/x' is a temp path" next - a thing --where /var/tmp/x
  check_refusal "the where '/var/folders/ab/T/x' is a temp path" next - a thing --where /var/folders/ab/T/x
  check_refusal "the where '/private/var/folders/ab/T/x' is a temp path" next - a thing --where /private/var/folders/ab/T/x
  check_refusal "the where '$tilde/.claude/jobs/0a0b0c0d/tmp/x.md' is a temp path" next - a thing --where "$tilde/.claude/jobs/0a0b0c0d/tmp/x.md"
  check_refusal "the where '$BATS_TEST_TMPDIR/job/out.md' is a temp path" next - a thing --where "$BATS_TEST_TMPDIR/job/out.md"
  # /etc/hosts is a file outside the team home and every temp directory, unless TMPDIR names /etc.
  check_refusal "the where '/etc/hosts' is not a file in the team home" next - a thing --where /etc/hosts
  check_refusal "the where 'tasks/queued/gone.md' is not a file in the team home" next - a thing --where tasks/queued/gone.md
  check_refusal "the where 'tasks/queued' is not a file in the team home" next - a thing --where tasks/queued
  local up=tasks/../../../../../../../../../../../../../../../etc/hosts
  check_refusal "the where '$up' is not a file in the team home" next - a thing --where "$up"
  check_refusal "the where 'ledger' is not a file in the team home" next - a thing --where ledger
  check_refusal "the where 'ledger yesterday' is not a file in the team home" next - a thing --where "ledger yesterday"
  check_refusal "the where holds ' | '" next - a thing --where "tasks/queued/node-pin.md | x"
  check_refusal "the line is already in tasks/current.md" next T4 open the Node pin task --where tasks/queued/node-pin.md
}

@test "add takes each where the manual allows: a URL, a Discord id, a ledger time and a team-home path in each form" {
  local where
  for where in https://github.com/owner/proj/pull/7 "https://discord.com/channels/1/2/3" 1563000000000000045 \
    "Discord 1563000000000000045" "ledger 2026-11-01T07:08:11Z" tasks/queued/node-pin.md \
    "$TEAM_HOME/tasks/queued/node-pin.md" "$tilde/team/tasks/queued/node-pin.md"; do
    run_bin -0 team-current add next - "pin Node for $where" --where "$where"
  done
  assert_equal "$(grep -c '^- ' "$current")" 8
  # 300 characters, counted as characters, not bytes.
  local text='' i
  for ((i = 0; i < 264; i++)); do text+=$'\xc3\xa9'; done
  run_bin -0 team-current add next - "$text" --where tasks/queued/node-pin.md
  run_bin -1 team-current add next - "${text}x" --where tasks/queued/node-pin.md
  run_bin -0 team-current check
}

@test "done refuses an id that matches no item or two, file unchanged" {
  local item="- next T4 open the Node pin task | tasks/queued/node-pin.md"
  printf '%s\n' "# Current items" "$item" "$item" "- owe - a reply | 1563000000000000045" >"$current"
  git -C "$TEAM_HOME" commit -q -am "chore: items"
  local before
  before=$(cat "$current")
  run_bin -1 --separate-stderr team-current "done" "$(id_of "$item")"
  assert_contains "$stderr" "$(id_of "$item") matches 2 items:"
  assert_equal "$(cat "$current")" "$before"
  run_bin -1 --separate-stderr team-current "done" 000000
  assert_contains "$stderr" "000000 matches no item"
  assert_equal "$(cat "$current")" "$before"
  run_bin -2 team-current "done" abc
  run_bin -2 team-current "done" 12345g
  assert_equal "$(git -C "$TEAM_HOME" status --porcelain)" ""
}

@test "check names each bad line with its reason and exits 1, never writing; a clean file passes" {
  cat >"$current" <<'EOF'
# Current items

- next T4 open the Node pin task | tasks/queued/node-pin.md
- queued -: branch cleanup | tasks/queued/node-pin.md
- next T4 a progress line | ledger
- todo - something | tasks/queued/node-pin.md
- ask - two wheres | tasks/queued/node-pin.md | ledger 2026-11-01T07:08:11Z
- owe - no where at all
- watch - the scratch | /tmp/watch.log
- next T4 open the Node pin task | tasks/queued/node-pin.md
Not an item: a note under the list.
EOF
  git -C "$TEAM_HOME" commit -q -am "chore: items"
  run_bin -1 team-current check
  assert_equal "$output" "tasks/current.md:4: task '-:' is not T<n> or -
tasks/current.md:5: the where 'ledger' is not a file in the team home
tasks/current.md:6: kind 'todo' is not ask, owe, next, queued or watch
tasks/current.md:7: the line holds ' | ' more than once
tasks/current.md:8: the line has no ' | <where>'
tasks/current.md:9: the where '/tmp/watch.log' is a temp path
tasks/current.md:10: the line is already in tasks/current.md, at line 3
tasks/current.md:11: not an item line (- <kind> <task or -> <text> | <where>)"
  assert_equal "$(git -C "$TEAM_HOME" status --porcelain)" ""
  printf '%s\n' "# Current items" "" "- next T4 open the Node pin task | tasks/queued/node-pin.md" >"$current"
  run_bin -0 team-current check
  assert_equal "$output" ""
  printf '%s\n' "# Current items" "- next - the hosts | /etc/hosts" >"$current"
  run_bin -1 team-current check
  assert_equal "$output" "tasks/current.md:2: the where '/etc/hosts' is not a file in the team home"
  # A path under TMPDIR is a temp path, wherever TMPDIR is.
  TMPDIR=/etc run_bin -1 team-current check
  assert_equal "$output" "tasks/current.md:2: the where '/etc/hosts' is a temp path"
  rm "$current"
  run_bin -0 team-current check
  run_bin -0 team-current list
  assert_equal "$output" ""
}

@test "add and done commit tasks/current.md alone and push it, another changed record left uncommitted" {
  echo "# Plan, changed" >"$TEAM_HOME/tasks/T4/plan.md"
  echo "a staged note" >"$TEAM_HOME/README.md"
  git -C "$TEAM_HOME" add README.md
  run_bin -0 team-current add next T4 open the Node pin task --where tasks/queued/node-pin.md
  local id=${lines[0]}
  assert_contains "$output" "team home: committed"
  assert_equal "$(last_commit)" "chore: current next T4
tasks/current.md"
  assert_equal "$(git -C "$team_origin" log -1 --format=%s dev)" "chore: current next T4"
  run_bin -0 team-current "done" "${id:0:4}"
  assert_equal "$(last_commit)" "chore: current done $id
tasks/current.md"
  assert_equal "$(git -C "$team_origin" log -1 --format=%s dev)" "chore: current done $id"
  assert_equal "$(git -C "$TEAM_HOME" status --porcelain)" "A  README.md
 M tasks/T4/plan.md"
}

@test "a commit the team home's hooks refuse undoes the change and fails" {
  local before head
  before=$(cat "$current") head=$(git -C "$TEAM_HOME" rev-parse HEAD)
  printf '#!/bin/sh\necho "pre-commit: refused" >&2\nexit 1\n' >"$TEAM_HOME/.git/hooks/pre-commit"
  chmod +x "$TEAM_HOME/.git/hooks/pre-commit"
  run_bin -1 --separate-stderr team-current add next T4 open the Node pin task --where tasks/queued/node-pin.md
  assert_contains "$stderr" "pre-commit: refused"
  assert_contains "$stderr" "not committed, so the change is undone"
  assert_equal "$(cat "$current")" "$before"
  assert_equal "$(git -C "$TEAM_HOME" rev-parse HEAD)" "$head"
  assert_equal "$(git -C "$TEAM_HOME" status --porcelain)" ""
}

@test "a push that fails keeps the commit for the next checkpoint and succeeds" {
  git -C "$TEAM_HOME" remote set-url origin "$BATS_TEST_TMPDIR/no-such-origin.git"
  run_bin -0 --separate-stderr team-current add next T4 open the Node pin task --where tasks/queued/node-pin.md
  assert_contains "$stderr" "cannot push dev"
  assert_equal "$(last_commit)" "chore: current next T4
tasks/current.md"
}

@test "add creates the file with its title when there is none" {
  rm "$current"
  run_bin -0 team-current add owe - the T4 summary --where 1563000000000000045
  assert_equal "$(cat "$current")" "# Current items
- owe - the T4 summary | 1563000000000000045"
}

@test "team-snapshot reads the items team-current writes, as before" {
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
TOML
  stub_reply claude '[]'
  stub_reply gh '[]'
  run_bin -0 team-current add owe - the T4 summary --where 1563000000000000045
  run_bin -0 team-current add next T4 open the Node pin task --where tasks/queued/node-pin.md
  run_bin -0 team-snapshot
  assert_contains "$output" "Current items (2):
  - owe - the T4 summary | 1563000000000000045
  - next T4 open the Node pin task | tasks/queued/node-pin.md"
  run_bin -0 team-snapshot --json
  assert_equal "$(jq -c .items <<<"$output")" '["owe - the T4 summary | 1563000000000000045","next T4 open the Node pin task | tasks/queued/node-pin.md"]'
}

@test "it refuses a malformed command line" {
  run_bin -2 team-current
  run_bin -2 team-current frob
  run_bin -2 team-current add next T4 no where
  run_bin -2 team-current add next T4 --where tasks/queued/node-pin.md
  run_bin -2 team-current add next --where tasks/queued/node-pin.md
  run_bin -2 team-current add next T4 a thing --where
  run_bin -2 team-current "done"
  run_bin -2 team-current "done" 123456 7890
  run_bin -2 team-current list extra
  run_bin -2 team-current check extra
}
