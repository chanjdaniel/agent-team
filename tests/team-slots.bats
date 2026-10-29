#!/usr/bin/env bats
# team-slots: the machine's task slots, the one kept for the reserved project and who holds them.

load helpers/common

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

@test "with no slots.json, every setting is its default and the cap says so" {
  run_bin -0 team-slots --json
  assert_equal "$(jq -c '.settings | del(.from)' <<<"$output")" \
    '{"cap":6,"reserved":1,"dynamic":true,"task_gib":1.25,"reserve_gib":6,"task_cores":0.5,"reserve_cores":2,"window_minutes":15,"wait_minutes":15}'
  assert_equal "$(jq -r .settings.from.cap <<<"$output")" default
  run_bin -0 team-slots
  assert_equal "${lines[1]}" "the cap is 6 (the default: ~/.config/agent-team/slots.json sets no cap), effective 6: no reading of the machine's load yet"
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
  assert_equal "${lines[1]}" "the cap is 10 (cap in ~/.config/agent-team/slots.json), effective 10: no reading of the machine's load yet"
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
the cap is 10 (cap in ~/.config/agent-team/slots.json), effective 10: no reading of the machine's load yet
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
  assert_equal "$(jq -c 'del(.settings, .held)' <<<"$output")" '{"schema":"team-slots/1","machine":"home-pc","reserved_project":"agent-team","effective":{"cap":4,"lowered_by":null,"reason":"no reading of the machine'"'"'s load yet","readings":[]},"counts":{"held":2,"reserved_held":0,"others_held":2},"room":{"reserved":2,"others":1},"stale":true}'
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

@test "without a machine name it says this machine, and it needs neither Docker nor the session list" {
  rm "$HOME/.config/agent-team/machine"
  stub_command docker
  run_bin -0 --separate-stderr team-slots
  assert_equal "${lines[0]}" "this machine: 0 of 6 task slots held, 1 kept for agent-team (agent-team holds 0); effective 6"
  assert_equal "$stderr" ""
  run_bin -0 team-slots --json
  assert_equal "$(jq -c .machine <<<"$output")" null
  assert_equal "$(stub_calls docker)$(stub_calls claude)" ""
}

@test "a malformed command line is refused" {
  run_bin -2 team-slots sample
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
team-slots: the cap is 10 (cap in ~/.config/agent-team/slots.json), effective 10: no reading of the machine's load yet
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
