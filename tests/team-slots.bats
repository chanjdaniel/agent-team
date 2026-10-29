#!/usr/bin/env bats
# team-slots: the machine's task slots, the one kept for the reserved project and who holds them.

load helpers/common
load helpers/docker

setup() {
  sandbox
  # The code checkout is agent-team's primary checkout, as on Daniel's machines, so agent-team is
  # the reserved project.
  code_checkout "$(make_repo agent-team dev)"
  proj=$(make_repo proj)
  make_repo other >/dev/null
  SETTINGS=$HOME/.config/agent-team/slots.json
  mkdir -p "$HOME/.config/agent-team"
  echo home-pc >"$HOME/.config/agent-team/machine"
  registry agent-team proj other
  NOW=$(date +%s)
  READINGS=$HOME/.local/state/agent-team/slots/readings.jsonl
  SNAPSHOT=$HOME/.local/state/agent-team/slots/procs.tsv
}

teardown() {
  # Let a slot lock holder a test left go, so bats does not wait on it.
  touch "$BATS_TEST_TMPDIR/release"
  wait 2>/dev/null || true
}

# The registry of the projects <name>..., each a git pool of three slots under ~/slots/<name>,
# its primary checkout at ~/projects/<name>.
registry() {
  local name
  : >"$TEAM_HOME/projects.toml"
  for name; do
    cat >>"$TEAM_HOME/projects.toml" <<TOML
[$name]
repo = "owner/$name"
path = "projects/$name"
base = "main"
delivery = "direct-pr"
merge_method = "merge"
required_checks = []
task_dir = ".scratch/task"
docs = []
toolkits = []

[$name.pool]
provider = "git"
slots = ["slots/$name/1", "slots/$name/2", "slots/$name/3"]

TOML
  done
}

# Append the ledger event <event> of the task <task> with the fields <json>.
event() {
  jq -cn --arg task "$1" --arg event "$2" --argjson fields "$3" \
    '{ts: "2026-10-29T10:00:00Z", task: $task, event: $event} + $fields' >>"$TEAM_HOME/ledger.jsonl"
}

# Log the task <task> opened in <project> in its slot <n> (a path only: the ledger holds it).
opened() {
  event "$1" opened "$(jq -cn --arg p "$2" --arg wt "$HOME/slots/$2/$3" --arg b "feat/$1-work" \
    '{project: $p, path: "feature", type: "feat", title: "Work", branch: $b, base: "main", base_sha: "abc1234",
      worktree: $wt}')"
}

# Log the task <task> given a worktree in <project>'s slot <n>.
added() {
  event "$1" worktree-added "$(jq -cn --arg p "$2" --arg wt "$HOME/slots/$2/$3" --arg b "feat/$1-work" \
    '{project: $p, branch: $b, base: "main", base_sha: "abc1234", worktree: $wt}')"
}

# Log the task <task>'s worktree in <project>'s slot <n> returned.
returned() {
  event "$1" worktree-returned "$(jq -cn --arg p "$2" --arg wt "$HOME/slots/$2/$3" '{project: $p, worktree: $wt}')"
}

# Log the task <task> closed.
closed() {
  event "$1" closed '{"archive": [], "returned": [], "kept": []}'
}

# Make <project>'s slot <n> a worktree of its primary checkout on the branch <branch>.
worktree_on() {
  git -C "$HOME/projects/$1" worktree add -q -b "$3" "$HOME/slots/$1/$2" 2>/dev/null
}

# The held slots of team-slots --json, one compact {task, project, worktree, half_open} per line.
held() {
  run_bin -0 team-slots --json
  jq -c '.held[]' <<<"$output"
}

# reading <minutes> <others GiB> [<others cores>]: append a reading taken <minutes> before the test
# began on a machine shaped like home-pc (30.6 GiB, 12 cores), other programs using <others GiB>
# and <others cores> busy (no CPU read without it).
reading() {
  local file=$HOME/.local/state/agent-team/slots/readings.jsonl
  mkdir -p "${file%/*}"
  jq -cn --arg at "$(date -u -d "@$((NOW - $1 * 60))" +%FT%TZ)" --argjson others "$2" --arg cores "${3:-}" '
    (30.6 * 1073741824 | floor) as $total | ($others * 1073741824 | floor) as $others
    | {at: $at, os: "linux", docker: true,
       memory: {total: $total, available: ($total - $others - 1073741824), team: 1073741824, others: $others},
       cpu: (if $cores == "" then null else {cpus: 12, seconds: 300, team: 0.5, others: ($cores | tonumber)} end)}' >>"$file"
}

# The local time, as HH:MM, <minutes> before the test began.
hm() {
  date -d "@$((NOW - $1 * 60))" +%H:%M
}

# The effective cap of team-slots --json, as "<cap> <lowered_by>".
effective() {
  run_bin -0 team-slots --json
  jq -r '"\(.effective.cap) \(.effective.lowered_by)"' <<<"$output"
}

@test "with no slots.json, every setting is its default and the cap says so" {
  run_bin -0 team-slots --json
  assert_equal "$(jq -c '.settings | del(.from)' <<<"$output")" \
    '{"cap":6,"reserved":1,"dynamic":true,"task_gib":1.25,"reserve_gib":6,"task_cores":0.5,"reserve_cores":2,"window_minutes":15,"wait_minutes":15}'
  assert_equal "$(jq -r .settings.from.cap <<<"$output")" default
  run_bin -0 team-slots
  assert_equal "${lines[1]}" "the cap is 6 (the default: ~/.config/agent-team/slots.json sets no cap), effective 6: $(sampled_reason)"
}

@test "every key of slots.json is read over its default" {
  echo '{"cap": 10, "reserved": 2, "dynamic": false, "task_gib": 2, "reserve_gib": 4.5, "task_cores": 1,
    "reserve_cores": 0, "window_minutes": 30, "wait_minutes": 0}' >"$SETTINGS"
  run_bin -0 team-slots --json
  assert_equal "$(jq -c '.settings | del(.from)' <<<"$output")" \
    '{"cap":10,"reserved":2,"dynamic":false,"task_gib":2,"reserve_gib":4.5,"task_cores":1,"reserve_cores":0,"window_minutes":30,"wait_minutes":0}'
  assert_equal "$(jq -c .settings.from <<<"$output")" \
    '{"cap":"slots.json","reserved":"slots.json","dynamic":"slots.json","task_gib":"slots.json","reserve_gib":"slots.json","task_cores":"slots.json","reserve_cores":"slots.json","window_minutes":"slots.json","wait_minutes":"slots.json"}'
  run_bin -0 team-slots
  assert_equal "${lines[1]}" "the cap is 10 (cap in ~/.config/agent-team/slots.json), effective 10: dynamic sizing is off (dynamic in slots.json)"
}

@test "a slots.json that is not JSON, or not one object, is refused" {
  echo '{"cap": ' >"$SETTINGS"
  run_bin -1 team-slots
  assert_contains "$output" "team-slots: $SETTINGS is not JSON:"
  echo '{"cap": 10} {"cap": 9}' >"$SETTINGS"
  run_bin -1 team-slots --json
  assert_equal "$output" "team-slots: $SETTINGS is not one JSON object"
  echo '[10]' >"$SETTINGS"
  run_bin -1 team-slots
  assert_equal "$output" "team-slots: $SETTINGS is not one JSON object"
}

@test "a key of the wrong kind and an unknown key are refused, naming each" {
  echo '{"cap": 0, "reserved": -1, "dynamic": "yes", "task_gib": 0, "reserve_gib": -2, "task_cores": "1",
    "reserve_cores": null, "window_minutes": 1.5, "wait_minutes": "15", "slots": 10}' >"$SETTINGS"
  run_bin -1 team-slots
  assert_equal "$output" "team-slots: $SETTINGS: cap must be a whole number of 1 or more, not 0; reserved must be a whole number of 0 or more, not -1; dynamic must be true or false, not \"yes\"; task_gib must be a number above 0, not 0; reserve_gib must be a number of 0 or more, not -2; task_cores must be a number above 0, not \"1\"; reserve_cores must be a number of 0 or more, not null; window_minutes must be a whole number of 1 or more, not 1.5; wait_minutes must be a number of 0 or more, not \"15\"; slots is not a setting (they are: cap, reserved, dynamic, task_gib, reserve_gib, task_cores, reserve_cores, window_minutes, wait_minutes)"
}

@test "reserved must be below the cap, its default's included" {
  echo '{"cap": 3, "reserved": 3}' >"$SETTINGS"
  run_bin -1 team-slots
  assert_equal "$output" "team-slots: $SETTINGS: reserved must be less than cap (3), not 3"
  echo '{"reserved": 6}' >"$SETTINGS"
  run_bin -1 team-slots
  assert_equal "$output" "team-slots: $SETTINGS: reserved must be less than cap (6), not 6"
  echo '{"cap": 1, "reserved": 0}' >"$SETTINGS"
  run_bin -0 team-slots
}

@test "an opened worktree and an added one each hold a slot, a task in two projects two" {
  opened T1 proj 1
  opened T2 agent-team 1
  added T2 other 1
  assert_equal "$(held)" "$(printf '%s\n' \
    "{\"task\":\"T1\",\"project\":\"proj\",\"worktree\":\"$HOME/slots/proj/1\",\"half_open\":false}" \
    "{\"task\":\"T2\",\"project\":\"agent-team\",\"worktree\":\"$HOME/slots/agent-team/1\",\"half_open\":false}" \
    "{\"task\":\"T2\",\"project\":\"other\",\"worktree\":\"$HOME/slots/other/1\",\"half_open\":false}")"
  run_bin -0 team-slots --json
  assert_equal "$(jq -c .counts <<<"$output")" '{"held":3,"reserved_held":1,"others_held":2}'
}

@test "a returned worktree, a closed task's and a closed task's kept one hold none" {
  opened T1 proj 1
  added T1 other 1
  returned T1 other 1
  opened T2 proj 2
  worktree_on proj 2 feat/T2-work
  closed T2
  assert_equal "$(held | jq -r .task)" "T1"
  run_bin -0 team-slots --json
  assert_equal "$(jq -c .counts <<<"$output")" '{"held":1,"reserved_held":0,"others_held":1}'
}

@test "a slot on a task's branch the ledger has no open worktree for is half open, and holds one" {
  # T3 never got its opened event; T4 is open in proj but half open in other; T5's branch is no
  # task's name, and the primary checkout itself is no slot.
  worktree_on proj 1 feat/T3-half
  opened T4 proj 2
  worktree_on proj 2 feat/T4-work
  worktree_on other 1 fix/T4-other
  worktree_on other 2 feat/not-a-task
  git -C "$proj" checkout -q -b feat/T6-primary
  assert_equal "$(held)" "$(printf '%s\n' \
    "{\"task\":\"T3\",\"project\":\"proj\",\"worktree\":\"$HOME/slots/proj/1\",\"half_open\":true}" \
    "{\"task\":\"T4\",\"project\":\"other\",\"worktree\":\"$HOME/slots/other/1\",\"half_open\":true}" \
    "{\"task\":\"T4\",\"project\":\"proj\",\"worktree\":\"$HOME/slots/proj/2\",\"half_open\":false}")"
}

@test "a worktree recorded under another machine's home holds its slot here" {
  event T1 opened "$(jq -cn '{project: "proj", path: "feature", type: "feat", title: "Work", branch: "feat/T1-work",
    base: "main", base_sha: "abc1234", worktree: "/Users/someone/slots/proj/1"}')"
  assert_equal "$(held | jq -r .worktree)" "$HOME/slots/proj/1"
}

@test "the text says the cap, the reserved slot and each holder" {
  echo '{"cap": 10}' >"$SETTINGS"
  opened T1 proj 1
  opened T2 proj 2
  opened T3 agent-team 1
  worktree_on other 1 feat/T4-half
  run_bin -0 team-slots status
  assert_equal "$output" "home-pc: 4 of 10 task slots held, 1 kept for agent-team (agent-team holds 1); effective 10
the cap is 10 (cap in ~/.config/agent-team/slots.json), effective 10: $(sampled_reason)
  T1 proj in ~/slots/proj/1
  T2 proj in ~/slots/proj/2
  T3 agent-team in ~/slots/agent-team/1
  T4 other in ~/slots/other/1 (half open)"
}

@test "the JSON is team-slots/1, with the effective cap, the counts and the room each side has" {
  echo '{"cap": 4}' >"$SETTINGS"
  opened T1 proj 1
  opened T2 other 1
  run_bin -0 team-slots --json
  assert_equal "$(jq -c 'del(.settings, .held, .effective.reason, .effective.readings)' <<<"$output")" '{"schema":"team-slots/1","machine":"home-pc","reserved_project":"agent-team","effective":{"cap":4,"lowered_by":null},"counts":{"held":2,"reserved_held":0,"others_held":2},"room":{"reserved":2,"others":1},"stale":false}'
  assert_equal "$(jq -r .effective.reason <<<"$output")" "$(sampled_reason)"
  assert_equal "$(jq -c '.effective.readings' <<<"$output")" "[$(cat "$READINGS")]"
}

@test "the room: others stop one short of the cap while agent-team holds none, and agent-team's slot counts toward it" {
  echo '{"cap": 10}' >"$SETTINGS"
  for n in 1 2 3; do opened "T$n" proj "$n"; done
  for n in 4 5 6; do opened "T$n" other "$((n - 3))"; done
  for n in 7 8 9; do worktree_on proj "$((n - 3))" "feat/T$n-half"; done
  run_bin -0 team-slots --json
  assert_equal "$(jq -c '[.counts, .room]' <<<"$output")" '[{"held":9,"reserved_held":0,"others_held":9},{"reserved":1,"others":0}]'
  run_bin -0 team-slots
  assert_equal "${lines[0]}" "home-pc: 9 of 10 task slots held, 1 kept for agent-team (agent-team holds 0); effective 10"

  # With agent-team holding 3 and the others 6, the others may take one more, then nobody.
  echo '{"cap": 10}' >"$SETTINGS"
  : >"$TEAM_HOME/ledger.jsonl"
  for n in 1 2 3; do git -C "$proj" worktree remove --force "$HOME/slots/proj/$((n + 3))"; done
  for n in 1 2 3; do opened "T$((n + 10))" agent-team "$n"; done
  for n in 1 2 3; do opened "T$((n + 20))" proj "$n"; done
  for n in 1 2 3; do opened "T$((n + 30))" other "$n"; done
  run_bin -0 team-slots --json
  assert_equal "$(jq -c '[.counts, .room]' <<<"$output")" '[{"held":9,"reserved_held":3,"others_held":6},{"reserved":1,"others":1}]'
}

@test "reserved 0 keeps none" {
  echo '{"cap": 2, "reserved": 0}' >"$SETTINGS"
  opened T1 proj 1
  run_bin -0 team-slots --json
  assert_equal "$(jq -c .room <<<"$output")" '{"reserved":1,"others":1}'
  run_bin -0 team-slots
  assert_equal "${lines[0]}" "home-pc: 1 of 2 task slots held, none kept for agent-team (reserved 0); effective 2"
}

@test "with no registered project whose primary checkout is the code checkout, reserved is ignored and said so" {
  registry proj other
  echo '{"cap": 2}' >"$SETTINGS"
  opened T1 proj 1
  run_bin -0 team-slots --json
  assert_equal "$(jq -c '[.reserved_project, .counts, .room]' <<<"$output")" \
    '[null,{"held":1,"reserved_held":0,"others_held":1},{"reserved":null,"others":1}]'
  run_bin -0 team-slots
  assert_equal "${lines[0]}" "home-pc: 1 of 2 task slots held, none kept, since no registered project's primary checkout is the code checkout ~/projects/agent-team (reserved 1 ignored); effective 2"
}

@test "run from a linked worktree of the code checkout, the reserved project is still its primary checkout's" {
  worktree_on agent-team 1 feat/T9-work
  code_checkout "$HOME/slots/agent-team/1"
  run_bin -0 team-slots --json
  assert_equal "$(jq -r .reserved_project <<<"$output")" agent-team
}

@test "without a machine name it says this machine, and with a reading of the last 10 minutes it reads neither Docker nor the session list" {
  rm "$HOME/.config/agent-team/machine"
  stub_command docker
  reading 9 8
  run_bin -0 --separate-stderr team-slots
  assert_equal "${lines[0]}" "this machine: 0 of 6 task slots held, 1 kept for agent-team (agent-team holds 0); effective 6"
  assert_equal "$stderr" ""
  run_bin -0 team-slots --json
  assert_equal "$(jq -c .machine <<<"$output")" null
  assert_equal "$(stub_calls docker)$(stub_calls claude)" ""
}

@test "a malformed command line is refused" {
  run_bin -2 team-slots sample --json
  assert_contains "$output" "usage: team-slots [status] [--json]"
  run_bin -2 team-slots status sample
  assert_contains "$output" "usage: team-slots [status] [--json]"
  run_bin -2 team-slots status --all
  assert_contains "$output" "usage: team-slots [status] [--json]"
}

@test "check: with cap 10 and 9 held by other projects, they are refused naming the reserved slot and each holder, and agent-team is not" {
  echo '{"cap": 10}' >"$SETTINGS"
  for n in 1 2 3; do opened "T$n" proj "$n"; done
  for n in 4 5 6; do opened "T$n" other "$((n - 3))"; done
  for n in 7 8 9; do opened "T$n" proj "$n"; done
  run_bin -75 --separate-stderr team-slots check proj
  assert_equal "$output" ""
  assert_equal "$stderr" "team-slots: no task slot for proj on home-pc: 9 of 10 held, and the last one is kept for agent-team (reserved 1)
team-slots: the cap is 10 (cap in ~/.config/agent-team/slots.json), effective 10: $(sampled_reason)
team-slots: the slots:
  T1 proj in ~/slots/proj/1
  T2 proj in ~/slots/proj/2
  T3 proj in ~/slots/proj/3
  T4 other in ~/slots/other/1
  T5 other in ~/slots/other/2
  T6 other in ~/slots/other/3
  T7 proj in ~/slots/proj/7
  T8 proj in ~/slots/proj/8
  T9 proj in ~/slots/proj/9"
  run_bin -75 team-slots check other
  run_bin -0 --separate-stderr team-slots check agent-team
  assert_equal "$output$stderr" ""
}

@test "check: agent-team's held slots count toward the reservation, and a full cap refuses every project for the cap" {
  echo '{"cap": 10, "reserved": 2}' >"$SETTINGS"
  for n in 1 2 3; do opened "T$n" agent-team "$n"; done
  for n in 4 5 6; do opened "T$n" proj "$((n - 3))"; done
  for n in 7 8 9; do opened "T$n" other "$((n - 6))"; done
  run_bin -0 team-slots check proj
  opened T10 proj 4
  run_bin -75 --separate-stderr team-slots check proj
  assert_equal "${stderr%%$'\n'*}" "team-slots: no task slot for proj on home-pc: 10 of 10 held"
  run_bin -75 --separate-stderr team-slots check agent-team
  assert_equal "${stderr%%$'\n'*}" "team-slots: no task slot for agent-team on home-pc: 10 of 10 held"

  # With 2 kept and agent-team holding 1, the last one is kept and agent-team's held one named.
  : >"$TEAM_HOME/ledger.jsonl"
  opened T1 agent-team 1
  for n in 2 3 4 5 6 7 8 9; do opened "T$n" proj "$n"; done
  run_bin -75 --separate-stderr team-slots check other
  assert_equal "${stderr%%$'\n'*}" "team-slots: no task slot for other on home-pc: 9 of 10 held, and the last one is kept for agent-team (reserved 2, agent-team holds 1)"

  # With 2 kept and none held by agent-team, the last 2 are.
  echo '{"cap": 10, "reserved": 2}' >"$SETTINGS"
  : >"$TEAM_HOME/ledger.jsonl"
  for n in 1 2 3 4 5 6 7 8; do opened "T$n" proj "$n"; done
  run_bin -75 --separate-stderr team-slots check other
  assert_equal "${stderr%%$'\n'*}" "team-slots: no task slot for other on home-pc: 8 of 10 held, and the last 2 are kept for agent-team (reserved 2)"
}

@test "check: more held than the cap is said so, and with no reserved project none is kept" {
  echo '{"cap": 2, "reserved": 0}' >"$SETTINGS"
  for n in 1 2 3; do opened "T$n" proj "$n"; done
  run_bin -75 --separate-stderr team-slots check agent-team
  assert_equal "${stderr%%$'\n'*}" "team-slots: no task slot for agent-team on home-pc: 3 held, over the effective cap of 2"
  # With no reserved project, every project is another's, and no slot is kept.
  registry proj other
  echo '{"cap": 3}' >"$SETTINGS"
  run_bin -75 --separate-stderr team-slots check other
  assert_equal "${stderr%%$'\n'*}" "team-slots: no task slot for other on home-pc: 3 of 3 held"
  : >"$TEAM_HOME/ledger.jsonl"
  run_bin -0 team-slots check other
}

@test "check: a malformed slots.json is exit 1, an unregistered project and a malformed command line exit 2" {
  echo '{"cap": "ten"}' >"$SETTINGS"
  run_bin -1 team-slots check proj
  assert_equal "$output" "team-slots: $SETTINGS: cap must be a whole number of 1 or more, not \"ten\""
  rm "$SETTINGS"
  run_bin -2 team-slots check nope
  assert_equal "$output" "team-slots: unknown project 'nope'; known: agent-team, proj, other"
  run_bin -2 team-slots check
  run_bin -2 team-slots check --json
  run_bin -2 team-slots check proj --json
  run_bin -2 team-slots check proj --label someone
  run_bin -2 team-slots check proj --lock 3
  run_bin -2 team-slots check proj --lock three --label someone
  assert_contains "$output" "--lock takes a file descriptor"
  # A descriptor open on another file than the slot lock is refused.
  run_bin -2 team-slots check proj --lock 0 --label someone
  assert_contains "$output" "--lock takes a descriptor open on $HOME/.local/state/agent-team/slots.lock, and 0 is not"
}

@test "check --lock takes the slot lock on the caller's descriptor, keeps it past the check and writes the holder's line" {
  local lock=$HOME/.local/state/agent-team/slots.lock
  mkdir -p "${lock%/*}"
  exec {fd}<>"$lock"
  run_bin -0 team-slots check proj --lock "$fd" --label "team-open T1 proj (pid 42)"
  [[ $(cat "$lock") =~ ^team-open\ T1\ proj\ \(pid\ 42\)\ since\ [0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9:]{8}\ [+-][0-9]{4}$ ]]
  # Held by this descriptor still, so another run cannot take it.
  run flock -n -x "$lock" true
  assert_equal "$status" 1
  exec {fd}>&-
  run -0 flock -n -x "$lock" true
}

@test "check --lock waits up to wait_minutes, saying once for whom, then exits 75 naming the holder" {
  local lock=$HOME/.local/state/agent-team/slots.lock
  mkdir -p "${lock%/*}"
  echo "team-open T7 proj (pid 7) since 2026-10-29 10:00:00 +0000" >"$lock"
  (
    exec {holder}<>"$lock"
    flock -x "$holder"
    touch "$BATS_TEST_TMPDIR/held"
    until [[ -e $BATS_TEST_TMPDIR/release ]]; do sleep 0.1; done
  ) 3>&- &
  until [[ -e $BATS_TEST_TMPDIR/held ]]; do sleep 0.1; done
  echo '{"wait_minutes": 0}' >"$SETTINGS"
  exec {fd}<>"$lock"
  run_bin -75 --separate-stderr team-slots check proj --lock "$fd" --label "team-open T8 proj (pid 8)"
  assert_equal "$stderr" "team-slots: the machine's slot lock is held by team-open T7 proj (pid 7) since 2026-10-29 10:00:00 +0000"
  echo '{"wait_minutes": 0.02}' >"$SETTINGS"
  run_bin -75 --separate-stderr team-slots check proj --lock "$fd" --label "team-open T8 proj (pid 8)"
  assert_equal "$stderr" "team-slots: waiting up to 0.02 minutes for the machine's slot lock, held by team-open T7 proj (pid 7) since 2026-10-29 10:00:00 +0000
team-slots: the machine's slot lock is still held after 0.02 minutes, by team-open T7 proj (pid 7) since 2026-10-29 10:00:00 +0000"
  # Once the holder lets go, the waiting run takes it.
  echo '{"wait_minutes": 1}' >"$SETTINGS"
  (sleep 1 && touch "$BATS_TEST_TMPDIR/release") &
  run_bin -0 --separate-stderr team-slots check proj --lock "$fd" --label "team-open T8 proj (pid 8)"
  assert_equal "$(grep -c waiting <<<"$stderr")" 1
  assert_contains "$(cat "$lock")" "team-open T8 proj (pid 8) since "
  exec {fd}>&-
  wait
}

@test "--help documents check and its lock" {
  run_bin -0 team-slots --help
  assert_contains "$output" "team-slots check <project> [--lock <fd> --label <text>]"
  assert_contains "$output" "agent-team/slots.lock, so the lock outlasts the check"
}

@test "--help documents the effective cap and the readings file" {
  run_bin -0 team-slots --help
  assert_contains "$output" "/.local/state/agent-team/slots/readings.jsonl, kept to the last 24 hours"
  assert_contains "$output" "never below the slots kept for the reserved project"
}

@test "one reading of high load leaves the cap, two in a row lower it at once, and it rises once that pair has left the window" {
  echo '{"cap": 10}' >"$SETTINGS"
  local readings=$HOME/.local/state/agent-team/slots/readings.jsonl
  reading 14 11 1
  reading 9 18 1
  reading 4 11 1
  assert_equal "$(effective)" "10 null"
  run_bin -0 team-slots
  assert_equal "${lines[1]}" "the cap is 10 (cap in ~/.config/agent-team/slots.json), effective 10: other programs use 11.0 GiB of 30.6 GiB and 1.0 of 12 cores (the reading of $(hm 4))"

  # The first reading ever has no previous one, so it alone moves nothing either.
  rm "$readings"
  reading 2 18 1
  assert_equal "$(effective)" "10 null"

  rm "$readings"
  reading 14 11 1
  reading 9 18 1
  reading 4 18 1
  assert_equal "$(effective)" "5 memory"
  run_bin -0 team-slots
  assert_equal "${lines[0]}" "home-pc: 0 of 10 task slots held, 1 kept for agent-team (agent-team holds 0); effective 5"
  assert_equal "${lines[1]}" "the cap is 10 (cap in ~/.config/agent-team/slots.json), effective 5: lowered by memory: other programs use 18.0 GiB of 30.6 GiB, leaving room for 5 tasks of 1.25 GiB after 6 GiB kept (the readings of $(hm 9) and $(hm 4))"

  # A lower pair whose second reading is in the window still holds the cap down, its first one
  # before the window counting as the first's previous.
  rm "$readings"
  reading 16 18 1
  reading 11 18 1
  reading 6 11 1
  reading 1 11 1
  assert_equal "$(effective)" "5 memory"
  run_bin -0 team-slots
  assert_contains "${lines[1]}" "(the readings of $(hm 16) and $(hm 11))"

  # Once the pair is older than the window, it is back up.
  rm "$readings"
  reading 21 18 1
  reading 16 18 1
  reading 11 11 1
  reading 6 11 1
  reading 1 11 1
  assert_equal "$(effective)" "10 null"
}

@test "the fit is the lower of memory's and the CPU's, and a reading with no CPU read is memory's alone" {
  echo '{"cap": 10}' >"$SETTINGS"
  local readings=$HOME/.local/state/agent-team/slots/readings.jsonl
  reading 6 11 9
  reading 1 11 9
  assert_equal "$(effective)" "2 cpu"
  run_bin -0 team-slots
  assert_equal "${lines[1]}" "the cap is 10 (cap in ~/.config/agent-team/slots.json), effective 2: lowered by CPU: other programs use 9.0 of 12 cores, leaving room for 2 tasks of 0.5 cores after 2 cores kept (the readings of $(hm 6) and $(hm 1))"

  rm "$readings"
  reading 6 20 1
  reading 1 20 1
  assert_equal "$(effective)" "3 memory"

  rm "$readings"
  reading 6 11
  reading 1 11
  assert_equal "$(effective)" "10 null"
  run_bin -0 team-slots
  assert_equal "${lines[1]}" "the cap is 10 (cap in ~/.config/agent-team/slots.json), effective 10: other programs use 11.0 GiB of 30.6 GiB (the reading of $(hm 1))"

  rm "$readings"
  reading 6 20
  reading 1 20
  assert_equal "$(effective)" "3 memory"

  # The settings set each side's need and what is kept.
  echo '{"cap": 10, "task_gib": 2, "reserve_gib": 4, "task_cores": 1, "reserve_cores": 0}' >"$SETTINGS"
  rm "$readings"
  reading 6 20 10
  reading 1 20 10
  assert_equal "$(effective)" "2 cpu"
  run_bin -0 team-slots
  assert_contains "${lines[1]}" "lowered by CPU: other programs use 10.0 of 12 cores, leaving room for 2 tasks of 1 core after 0 cores kept"
  # A tie with memory's names memory.
  rm "$readings"
  reading 6 20 9
  reading 1 20 9
  assert_equal "$(effective)" "3 memory"
}

@test "on the default settings, home-pc's readings give its cap of 10, and 18 GiB used by others give 5" {
  echo '{"cap": 10}' >"$SETTINGS"
  reading 6 11 1
  reading 1 11 1
  assert_equal "$(effective)" "10 null"
  reading 0 18 1
  assert_equal "$(effective)" "10 null"
  rm "$HOME/.local/state/agent-team/slots/readings.jsonl"
  reading 6 18 1
  reading 1 18 1
  assert_equal "$(effective)" "5 memory"
}

@test "the effective cap never drops below reserved, so agent-team still opens on a loaded machine while others are refused" {
  echo '{"cap": 10}' >"$SETTINGS"
  reading 6 28 1
  reading 1 28 1
  assert_equal "$(effective)" "1 memory"
  run_bin -0 team-slots
  assert_equal "${lines[1]}" "the cap is 10 (cap in ~/.config/agent-team/slots.json), effective 1: lowered by memory: other programs use 28.0 GiB of 30.6 GiB, leaving room for 0 tasks of 1.25 GiB after 6 GiB kept (the readings of $(hm 6) and $(hm 1)), and never below the 1 kept for agent-team"
  run_bin -75 --separate-stderr team-slots check proj
  assert_equal "${stderr%%$'\n'*}" "team-slots: no task slot for proj on home-pc: 0 of 1 held, and the last one is kept for agent-team (reserved 1)"
  run_bin -0 team-slots check agent-team

  # With no reserved project, nothing holds it up.
  registry proj other
  assert_equal "$(effective)" "0 memory"
  run_bin -75 --separate-stderr team-slots check other
  assert_equal "$stderr" "team-slots: no task slot for other on home-pc: 0 of 0 held
team-slots: the cap is 10 (cap in ~/.config/agent-team/slots.json), effective 0: lowered by memory: other programs use 28.0 GiB of 30.6 GiB, leaving room for 0 tasks of 1.25 GiB after 6 GiB kept (the readings of $(hm 6) and $(hm 1))
team-slots: the slots: none held"
}

@test "dynamic false, or no reading in the window, gives the cap with its reason" {
  echo '{"cap": 10, "dynamic": false}' >"$SETTINGS"
  reading 6 18 1
  reading 1 18 1
  run_bin -0 team-slots --json
  assert_equal "$(jq -c '[.effective.cap, .effective.lowered_by, .effective.reason, (.effective.readings | length), .stale]' <<<"$output")" \
    '[10,null,"dynamic sizing is off (dynamic in slots.json)",2,false]'

  # Stored readings only, as when status cannot take one of its own.
  echo '{"cap": 10}' >"$SETTINGS"
  rm "$HOME/.local/state/agent-team/slots/readings.jsonl"
  reading 25 18 1
  reading 20 18 1
  local meminfo
  meminfo=$(cat "$TEAM_MEMINFO")
  : >"$TEAM_MEMINFO"
  run_bin -0 --separate-stderr team-slots --json
  assert_equal "$(jq -c '[.effective.cap, .effective.lowered_by, .effective.reason, .effective.readings, .stale]' <<<"$output")" \
    '[10,null,"no reading of the machine'"'"'s load in the last 15 minutes",[],true]'
  rm "$HOME/.local/state/agent-team/slots/readings.jsonl"
  run_bin -0 --separate-stderr team-slots --json
  assert_equal "$(jq -c '[.effective.cap, .effective.reason, .stale]' <<<"$output")" \
    '[10,"no reading of the machine'"'"'s load yet",true]'

  # window_minutes sets how far back they count, the reading status takes now among them.
  printf '%s\n' "$meminfo" >"$TEAM_MEMINFO"
  reading 25 18 1
  reading 20 18 1
  echo '{"cap": 10, "window_minutes": 30}' >"$SETTINGS"
  assert_equal "$(effective)" "5 memory"
}

@test "the JSON's effective cap carries the window's readings, and stale says the newest is over 15 minutes old" {
  echo '{"cap": 10}' >"$SETTINGS"
  reading 20 18 1
  reading 6 18 1
  reading 1 18
  run_bin -0 team-slots --json
  assert_equal "$(jq -c '[.effective.cap, .effective.lowered_by, (.effective.readings | map(.memory.others / 1073741824 | floor)), (.effective.readings | map(.cpu.others)), .stale]' <<<"$output")" \
    '[5,"memory",[18,18],[1,null],false]'
  assert_equal "$(jq -r '.effective.readings[0].at' <<<"$output")" "$(date -u -d "@$((NOW - 360))" +%FT%TZ)"
  assert_equal "$(jq -c .room <<<"$output")" '{"reserved":5,"others":4}'
}

@test "a broken line of the readings is skipped, saying so once on stderr" {
  echo '{"cap": 10}' >"$SETTINGS"
  local readings=$HOME/.local/state/agent-team/slots/readings.jsonl
  reading 6 18 1
  { echo '{"at": "2026-10-29T13:0'; echo '{"at": "yesterday", "memory": {}}'; echo; } >>"$readings"
  reading 1 18 1
  run_bin -0 --separate-stderr team-slots --json
  assert_equal "$(jq -c '[.effective.cap, (.effective.readings | length)]' <<<"$output")" '[5,2]'
  assert_equal "$stderr" "team-slots: skipped 2 broken lines of ~/.local/state/agent-team/slots/readings.jsonl"
  run_bin -0 --separate-stderr team-slots check proj
  assert_equal "$stderr" "team-slots: skipped 2 broken lines of ~/.local/state/agent-team/slots/readings.jsonl"
}

# proc <pid> <parent pid> <resident MiB> <CPU seconds> [<directory>]: a process of the simulated
# machine (TEAM_SLOTS_PROCS), its directory unreadable without one.
proc() {
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" $(($3 * 1024)) "$4" "${5:-}" >>"$TEAM_SLOTS_PROCS"
}

# The processes' CPU seconds at the previous reading, <seconds> ago: snapshot <seconds> <pid>:<CPU seconds>...
snapshot() {
  mkdir -p "${SNAPSHOT%/*}"
  local entry
  for entry in "${@:2}"; do printf '%s\t%s\n' "${entry%%:*}" "${entry#*:}"; done >"$SNAPSHOT"
  touch -d "@$((NOW - $1))" "$SNAPSHOT"
}

# The team and gate stacks' memory in bytes and CPU in cores, from team-stack ls --json on the
# stub docker: stacks_load <memory|cpu>
stacks_load() {
  "$CODE_CHECKOUT/bin/team-stack" ls --json | jq -r --arg part "$1" '[.projects[] | select(.class == "team" or .class == "gate")
    | if $part == "memory" then .memory_bytes // 0 else (.cpu_percent // 0) / 100 end] | add'
}

@test "sample: the team's memory is its processes', by directory and parentage, and the team and gate stacks'; the rest is others'" {
  docker_stub
  # A ledger worktree outside every pool's slots is a team path too.
  event T5 opened "$(jq -cn --arg wt "$HOME/elsewhere/wt" '{project: "proj", path: "feature", type: "feat", title: "Work",
    branch: "feat/T5-work", base: "main", base_sha: "abc1234", worktree: $wt}')"
  proc 100 1 1024 0 "$TEAM_HOME"
  proc 101 100 512 0 /tmp
  proc 102 101 256 0
  proc 103 1 128 0 "$HOME/slots/proj/1/src"
  proc 104 1 64 0 "$CODE_CHECKOUT"
  proc 105 1 32 0 "$HOME/.no-mistakes/worktrees/abc"
  proc 106 1 16 0 "$HOME/elsewhere/wt"
  # Not the team's: a project's primary checkout, an unreadable directory, a slot's namesake and
  # its child.
  proc 200 1 2048 0 "$HOME/projects/proj"
  proc 201 1 1024 0
  proc 202 1 512 0 "$HOME/slots/proj/10"
  proc 203 202 8 0 /tmp
  local stacks
  stacks=$(stacks_load memory)
  # The fixture's team stacks and gate stacks run, and its unowned ones are not counted.
  ((stacks > 0))
  run_bin -0 --separate-stderr team-slots sample
  assert_equal "$output$stderr" ""
  assert_equal "$(wc -l <"$READINGS")" 1
  assert_equal "$(jq -c --argjson stacks "$stacks" '[.os, .docker, .memory.total, .memory.available,
      .memory.team - 2032 * 1048576 - $stacks, .memory.others - 8 * 1073741824 + 2032 * 1048576 + $stacks, .cpu]' "$READINGS")" \
    '["linux",true,34359738368,25769803776,0,0,null]'
  [[ $(jq -r .at "$READINGS") =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "sample: Docker not answering is no Docker part, said in the reading, and others are never below 0" {
  docker_stub
  docker_down
  proc 100 1 $((9 * 1024)) 0 "$TEAM_HOME"
  run_bin -0 --separate-stderr team-slots sample
  assert_equal "$output$stderr" ""
  assert_equal "$(jq -c '[.docker, .memory.team, .memory.others]' "$READINGS")" "[false,$((9 * 1073741824)),0]"
  # Without the stub, the sandbox's Docker answers nobody either.
  rm "$READINGS" "$BATS_TEST_TMPDIR/stubs/docker"
  run_bin -0 team-slots sample
  assert_equal "$(jq -c .docker "$READINGS")" false
}

@test "sample: a Docker that hangs is no Docker part, after TEAM_SLOTS_DOCKER_SECONDS" {
  docker_stub
  docker_hang
  TEAM_SLOTS_DOCKER_SECONDS=1 run_bin -0 team-slots sample
  assert_equal "$(jq -c .docker "$READINGS")" false
  # The docker call it started is stopped with it.
  local pid
  [[ -s $DOCKER_STATE/hung ]]
  while read -r pid; do
    ! kill -0 "$pid" 2>/dev/null || { echo "docker call $pid still waits" && return 1; }
  done <"$DOCKER_STATE/hung"
}

@test "sample: the CPU is read against a snapshot 60 seconds to 15 minutes old, as cores busy, a new process counted whole, the stacks' CPU the team's" {
  docker_stub
  docker_state stats 'map(if .Name == "conventioner-2-mongodb-1" then .CPUPerc = "150.00%" else . end)'
  proc 100 1 10 1300 "$TEAM_HOME"
  proc 101 100 10 60 /tmp
  proc 300 1 10 6200 /x
  proc 301 1 10 50 /x
  proc 400 1 10 300 /x
  # With no snapshot, no CPU; the snapshot is then this reading's.
  run_bin -0 team-slots sample
  assert_equal "$(jq -c .cpu "$READINGS")" null
  assert_equal "$(cat "$SNAPSHOT")" "$(printf '%s\t%s\n' 100 1300 101 60 300 6200 301 50 400 300)"
  # Five minutes later: 100 used 300 s, 101 is new (60 s), 300 used 1200 s, 301's lower count is
  # a new process's (50 s), 400 is new (300 s).
  rm "$READINGS"
  snapshot 300 100:1000 300:5000 301:100
  local docker
  docker=$(stacks_load cpu)
  run_bin -0 team-slots sample
  assert_equal "$(jq -c --argjson docker "$docker" '.cpu as $cpu | [$cpu.cpus, ($cpu.seconds | . >= 300 and . <= 302),
      $cpu.team == ((360 / $cpu.seconds + $docker) * 100 | round / 100),
      $cpu.others == ((1550 / $cpu.seconds - $docker) * 100 | round / 100)]' "$READINGS")" '[12,true,true,true]'
  # A snapshot under a minute old, or over 15 minutes, gives no CPU.
  for age in 30 901; do
    rm "$READINGS"
    snapshot "$age" 100:1000
    run_bin -0 team-slots sample
    assert_equal "$(jq -c .cpu "$READINGS")" null
  done
}

@test "sample: the CPU's others are never below 0" {
  docker_stub
  docker_state stats 'map(if .Name == "conventioner-2-mongodb-1" then .CPUPerc = "600.00%" else . end)'
  proc 300 1 10 5300 /x
  snapshot 300 300:5000
  run_bin -0 team-slots sample
  assert_equal "$(jq -c .cpu.others "$READINGS")" 0
}

@test "sample: one a minute at most, and the readings kept to the last 24 hours" {
  reading 1500 5
  reading 2 5
  echo '{"at": "broken' >>"$READINGS"
  run_bin -0 team-slots sample
  assert_equal "$(wc -l <"$READINGS")" 2
  assert_equal "$(head -n 1 "$READINGS" | jq -r .at)" "$(date -u -d "@$((NOW - 120))" +%FT%TZ)"
  local newest
  newest=$(tail -n 1 "$READINGS")
  run_bin -0 team-slots sample
  assert_equal "$(wc -l <"$READINGS")" 2
  assert_equal "$(tail -n 1 "$READINGS")" "$newest"
}

@test "sample: a reading it cannot take is its reason and exit 1, with nothing written" {
  printf 'MemTotal:       33554432 kB\nMemFree:         1048576 kB\n' >"$TEAM_MEMINFO"
  run_bin -1 --separate-stderr team-slots sample
  assert_equal "$stderr" "team-slots: no MemTotal and MemAvailable in $TEAM_MEMINFO"
  [[ ! -e $READINGS && ! -e $SNAPSHOT ]]
  printf '%s\n' 'MemTotal:       33554432 kB' 'MemAvailable:   25165824 kB' >"$TEAM_MEMINFO"
  echo '{"cap": 0}' >"$SETTINGS"
  run_bin -1 --separate-stderr team-slots sample
  assert_equal "$stderr" "team-slots: $SETTINGS: cap must be a whole number of 1 or more, not 0"
  [[ ! -e $READINGS ]]
}

# The simulated machine as macOS gives it (uname Darwin): 32 GiB (sysctl hw.memsize) with 24 GiB
# available (vm_stat's free, inactive, speculative and purgeable pages of 16 KiB), and the
# processes mac_proc adds, from ps and lsof; TEAM_MEMINFO and TEAM_SLOTS_PROCS are unset, so the
# four commands are what sample reads.
on_macos() {
  as_macos
  unset TEAM_MEMINFO TEAM_SLOTS_PROCS
  stub_command sysctl vm_stat ps lsof
  stub_script sysctl <<<'[[ $* == "-n hw.memsize" ]] && echo 34359738368'
  stub_reply vm_stat "$(cat <<'OUT'
Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                              1000000.
Pages active:                             300000.
Pages inactive:                           400000.
Pages speculative:                        100000.
Pages throttled:                               0.
Pages wired down:                         200000.
Pages purgeable:                           72864.
"Translation faults":                  123456789.
OUT
)"
  : >"$BATS_TEST_TMPDIR/ps.out"
  : >"$BATS_TEST_TMPDIR/lsof.out"
  stub_script ps <<<"[[ \$* == '-A -o pid=,ppid=,rss=,time=' ]] && cat $(printf %q "$BATS_TEST_TMPDIR/ps.out")"
  stub_script lsof <<<"[[ \$* == '-a -d cwd -Fpn' ]] && cat $(printf %q "$BATS_TEST_TMPDIR/lsof.out")"
}

# mac_proc <pid> <parent pid> <resident MiB> <CPU time as macOS's ps prints it> [<directory>]: a
# process of the simulated macOS, its directory missing from lsof's list without one.
mac_proc() {
  printf '%5s %5s %8s %10s\n' "$1" "$2" $(($3 * 1024)) "$4" >>"$BATS_TEST_TMPDIR/ps.out"
  [[ -z ${5:-} ]] || printf 'p%s\nfcwd\nn%s\n' "$1" "$5" >>"$BATS_TEST_TMPDIR/lsof.out"
}

@test "sample on macOS: the memory from sysctl and vm_stat, the processes from ps and lsof, attributed as on Linux" {
  docker_stub
  on_macos
  mac_proc 100 1 1024 12:34.56 "$TEAM_HOME"
  mac_proc 101 100 512 0:01.00 /tmp
  mac_proc 102 101 256 0:00.00
  mac_proc 103 1 128 1:00.00 "$HOME/slots/proj/1/src"
  # Not the team's: Docker Desktop's VM, a project's primary checkout and a process lsof cannot
  # read.
  mac_proc 300 1 4096 123:45.67 "$HOME/Library/Containers/com.docker.docker/Data"
  mac_proc 301 300 64 0:00.10 /
  mac_proc 200 1 2048 0:00.00 "$HOME/projects/proj"
  mac_proc 201 1 1024 0:00.00
  local stacks
  stacks=$(stacks_load memory)
  ((stacks > 0))
  run_bin -0 --separate-stderr team-slots sample
  assert_equal "$output$stderr" ""
  assert_equal "$(jq -c --argjson stacks "$stacks" '[.os, .docker, .memory.total, .memory.available,
      .memory.team - 1920 * 1048576 - $stacks, .memory.others - 8 * 1073741824 + 1920 * 1048576 + $stacks, .cpu]' "$READINGS")" \
    '["macos",true,34359738368,25769803776,0,0,null]'
  # ps's minutes and seconds are the snapshot's whole seconds.
  assert_equal "$(cat "$SNAPSHOT")" "$(printf '%s\t%s\n' 100 754 101 1 102 0 103 60 300 7425 301 0 200 0 201 0)"
  assert_equal "$(stub_calls lsof)" '["-a","-d","cwd","-Fpn"]'
  assert_equal "$(stub_calls ps)" '["-A","-o","pid=,ppid=,rss=,time="]'
  assert_equal "$(stub_calls sysctl)" '["-n","hw.memsize"]'
  # TEAM_MEMINFO stands for the memory on macOS too, as the sandbox's machine on a macOS host.
  rm "$READINGS"
  printf 'MemTotal:       %s kB\nMemAvailable:   %s kB\n' $((16 * 1024 * 1024)) $((8 * 1024 * 1024)) \
    >"$BATS_TEST_TMPDIR/meminfo"
  TEAM_MEMINFO=$BATS_TEST_TMPDIR/meminfo run_bin -0 team-slots sample
  assert_equal "$(jq -c '[.os, .memory.total, .memory.available]' "$READINGS")" '["macos",17179869184,8589934592]'
  assert_equal "$(stub_calls sysctl | wc -l)" 1
}

@test "sample on macOS: a command that fails or prints what cannot be read is exit 1 naming it, with nothing written" {
  on_macos
  mac_proc 100 1 1024 0:01.00 "$TEAM_HOME"
  # refused <stderr>: sample exits 1 saying so, and writes no reading or snapshot.
  refused() {
    run_bin -1 --separate-stderr team-slots sample
    assert_equal "$stderr" "team-slots: $1"
    [[ ! -e $READINGS && ! -e $SNAPSHOT ]]
  }
  local vm_stat
  vm_stat=$(cat "$STUB_FIXTURES/vm_stat.out")

  stub_script sysctl <<<"echo \"sysctl: unknown oid 'hw.memsize'\" >&2; exit 1"
  refused "sysctl -n hw.memsize failed: sysctl: unknown oid 'hw.memsize'"
  stub_script sysctl <<<'echo lots'
  refused "sysctl -n hw.memsize printed no memory size: lots"
  stub_script sysctl <<<'echo 34359738368'

  stub_reply vm_stat "vm_stat: not today" 1
  refused "vm_stat failed: no reason given"
  stub_reply vm_stat "$(grep -v speculative <<<"$vm_stat")"
  refused "vm_stat printed no page size and free, inactive, speculative and purgeable pages"
  stub_reply vm_stat "${vm_stat/page size of 16384 bytes/page size unknown}"
  refused "vm_stat printed no page size and free, inactive, speculative and purgeable pages"
  stub_reply vm_stat "${vm_stat/1000000./many.}"
  refused "vm_stat printed no page size and free, inactive, speculative and purgeable pages"
  stub_reply vm_stat "$vm_stat"

  stub_script lsof <<<'echo "lsof: no kernel today" >&2; exit 1'
  refused "lsof -a -d cwd -Fpn failed: lsof: no kernel today"
  stub_script lsof <<<'printf "p100\nfcwd\nn/x\nCOMMAND PID\n"'
  refused "lsof -a -d cwd -Fpn printed a line that is no process or directory: COMMAND PID"
  stub_script lsof <<<'printf "fcwd\nn/x\n"'
  refused "lsof -a -d cwd -Fpn printed a line that is no process or directory: fcwd"
  stub_script lsof <<<"cat $(printf %q "$BATS_TEST_TMPDIR/lsof.out")"

  stub_script ps <<<'echo "ps: no processes today" >&2; exit 1'
  refused "ps -A -o pid=,ppid=,rss=,time= failed: ps: no processes today"
  stub_script ps <<<'printf "  100     1  1048576    0:01.00\n  PID  PPID  RSS TIME\n"'
  refused "ps -A -o pid=,ppid=,rss=,time= printed a line that is no process: PID  PPID  RSS TIME"
  stub_script ps <<<"cat $(printf %q "$BATS_TEST_TMPDIR/ps.out")"

  run_bin -0 team-slots sample
  assert_equal "$(jq -r .os "$READINGS")" macos
}

@test "sample with no seam takes a real reading of this machine, Linux or macOS, of the reading's shape" {
  unset TEAM_MEMINFO TEAM_SLOTS_PROCS TEAM_SLOTS_CPUS
  local os=linux sleeper rss
  [[ $(uname -s) != Darwin ]] || os=macos
  # A process in the team home, whose memory is the team's.
  (cd "$TEAM_HOME" && exec sleep 60) &
  sleeper=$!
  rss=$(ps -o rss= -p "$sleeper" | tr -d ' ')
  run_bin -0 --separate-stderr team-slots sample
  kill "$sleeper"
  assert_equal "$output$stderr" ""
  assert_equal "$(jq -c --arg os "$os" --argjson rss "$rss" '[.os == $os, .docker, .memory.total > 0,
      .memory.available > 0 and .memory.available <= .memory.total, .memory.team >= $rss * 1024,
      .memory.others == ([.memory.total - .memory.available - .memory.team, 0] | max), .cpu]' "$READINGS")" \
    '[true,false,true,true,true,true,null]'
  grep -q "^$sleeper"$'\t' "$SNAPSHOT"
  # Against a snapshot two minutes old, the CPU of all the machine's cores.
  rm "$READINGS"
  touch -d "@$(($(date +%s) - 120))" "$SNAPSHOT"
  run_bin -0 team-slots sample
  assert_equal "$(jq -c --argjson cpus "$(nproc)" '.cpu | [.cpus == $cpus, .seconds >= 120 and .seconds <= 130,
      .team >= 0, .others >= 0]' "$READINGS")" '[true,true,true,true]'
}

@test "status and check take a reading first only when the newest is more than 10 minutes old" {
  run_bin -0 team-slots
  assert_equal "$(wc -l <"$READINGS")" 1
  # A reading taken by status counts at once: one alone never lowers the cap.
  run_bin -0 team-slots --json
  assert_equal "$(jq -c '[(.effective.readings | length), .stale]' <<<"$output")" '[1,false]'
  : >"$READINGS"
  reading 9 8
  run_bin -0 team-slots check proj
  assert_equal "$(wc -l <"$READINGS")" 1
  : >"$READINGS"
  reading 11 8
  run_bin -0 team-slots check proj
  assert_equal "$(wc -l <"$READINGS")" 2
}

@test "a reading status or check cannot take is said, and they go on with the stored ones" {
  printf 'MemTotal:       33554432 kB\n' >"$TEAM_MEMINFO"
  reading 11 8
  run_bin -0 --separate-stderr team-slots
  assert_equal "$stderr" "team-slots: took no reading of the machine's load: no MemTotal and MemAvailable in $TEAM_MEMINFO"
  run_bin -0 --separate-stderr team-slots check proj
  assert_equal "$stderr" "team-slots: took no reading of the machine's load: no MemTotal and MemAvailable in $TEAM_MEMINFO"
  assert_equal "$(wc -l <"$READINGS")" 1
}

@test "--help documents sample and its seams" {
  run_bin -0 team-slots --help
  assert_contains "$output" "team-slots sample"
  local seam
  for seam in TEAM_MEMINFO TEAM_SLOTS_PROCS TEAM_SLOTS_CPUS TEAM_SLOTS_DOCKER_SECONDS procs.tsv; do
    assert_contains "$output" "$seam"
  done
}
