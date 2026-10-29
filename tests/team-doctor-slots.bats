#!/usr/bin/env bats
# team-doctor: one PASS, WARN or FAIL line per thing this machine needs, on the machine
# tests/helpers/doctor.bash builds: every tool a version stub, the OS a stubbed uname.
# This file: the slots line, the machine's task slots as team-slots says them.

load helpers/common
load helpers/doctor

setup() {
  sandbox
  doctor_machine
  tools_at arch
  READINGS=$HOME/.local/state/agent-team/slots/readings.jsonl
}

# Register agent-team with its primary checkout at the code checkout (through a link under HOME,
# where the registry's paths are), so it is the reserved project, with a git pool of <n> slots.
reserve_agent_team() {
  ln -s "$CODE_CHECKOUT" "$HOME/projects/agent-team"
  printf '%s\n' '[agent-team]' 'repo = "owner/agent-team"' 'path = "projects/agent-team"' 'base = "dev"' 'delivery = "direct-pr"' \
    'merge_method = "merge"' 'required_checks = []' 'task_dir = ".scratch/task"' 'docs = []' 'toolkits = []' \
    '[agent-team.pool]' 'provider = "git"' "slots = [$(slot_list agent-team "$1")]" >>"$TEAM_HOME/projects.toml"
}

# The registry's slots of <project>'s pool, <n> of them, as its slots line lists them.
slot_list() {
  local n list=''
  for ((n = 1; n <= $2; n++)); do
    if [[ $1 == conventioner ]]; then list+="\".treehouse/Conventioner-d4c77a/$n/Conventioner\", "; else list+="\"projects/$1-slots/$n\", "; fi
  done
  echo "${list%, }"
}

# Give <project>'s pool <n> slots in the registry.
pool_of() {
  local file=$TEAM_HOME/projects.toml
  awk -v section="[$1.pool]" -v slots="slots = [$(slot_list "$1" "$2")]" '
    $0 == section { inside = 1 } /^\[/ && $0 != section { inside = 0 }
    inside && /^slots = / { $0 = slots } { print }' "$file" >"$file.new"
  mv "$file.new" "$file"
}

# Tasks T<from> to T<to> of <project> each hold a slot, opened in the ledger.
holding() {
  local n
  for ((n = $2; n <= $3; n++)); do
    jq -cn --arg task "T$n" --arg p "$1" --arg wt "$HOME/elsewhere/$1/$n" \
      '{ts: "2026-10-29T10:00:00Z", task: $task, event: "opened", project: $p, path: "feature", type: "feat",
        title: "Held", branch: "feat/\($task)-held", base: "main", base_sha: "abc1234", worktree: $wt}' \
      >>"$TEAM_HOME/ledger.jsonl"
  done
}

# The newest reading's time, as HH:MM in local time, as the slots line says it.
newest() {
  tail -n 1 "$READINGS" | jq -r '.at | fromdateiso8601 | strflocaltime("%H:%M")'
}

@test "the slots line passes with the cap, the effective cap, the slots held and kept and the latest reading, noting each pool smaller than the cap lets it take" {
  # The code checkout is no clone with an origin, so its project lines fail: only the slots line counts.
  reserve_agent_team 10
  holding agent-team 1 1
  holding conventioner 2 4
  holding site 5 7
  : >"$READINGS"
  slots_reading 5 9 1
  slots_reading 0 9.8 1.1
  run_bin team-doctor
  assert_equal "$(line_of slots)" "PASS slots: cap 10 (slots.json), effective 10, 7 held, 1 kept for agent-team; other programs use 9.8 GiB of 30.6 GiB and 1.1 of 12 cores ($(newest)); pools smaller than the cap lets them take: conventioner 2 of 9, site 1 of 9"
  run_bin --separate-stderr team-doctor --json
  assert_equal "$(jq -c '.[] | select(.check == "slots") | [.verdict, .fix, (.reason | startswith("cap 10 (slots.json), effective 10, 7 held"))]' <<<"$output")" \
    '["PASS","",true]'

  # Another project's pool is held to the cap less the reserved slot, agent-team's to the cap.
  pool_of conventioner 9
  pool_of site 9
  pool_of agent-team 9
  run_bin team-doctor
  assert_equal "$(line_of slots)" "PASS slots: cap 10 (slots.json), effective 10, 7 held, 1 kept for agent-team; other programs use 9.8 GiB of 30.6 GiB and 1.1 of 12 cores ($(newest)); pools smaller than the cap lets them take: agent-team 9 of 10"
  pool_of agent-team 10
  echo '{"cap": 10, "reserved": 0, "dynamic": false}' >"$HOME/.config/agent-team/slots.json"
  run_bin team-doctor
  assert_equal "$(line_of slots)" "PASS slots: cap 10 (slots.json), effective 10 (dynamic sizing is off), 7 held, none kept for agent-team; other programs use 9.8 GiB of 30.6 GiB and 1.1 of 12 cores ($(newest)); pools smaller than the cap lets them take: conventioner 9 of 10, site 9 of 10"
  # The doctor took no reading.
  assert_equal "$(wc -l <"$READINGS")" 2
}

@test "the slots line warns on no slots.json or no cap in it, with the default cap and how to set one" {
  rm "$HOME/.config/agent-team/slots.json"
  run_bin -0 team-doctor
  assert_equal "$(line_of slots)" "WARN slots: ~/.config/agent-team/slots.json is missing, so the cap is the default 6; cap 6 (the default), effective 6, 0 held, none kept, since no registered project's primary checkout is the code checkout; other programs use 8.0 GiB of 30.6 GiB and 1.0 of 12 cores ($(newest)); pools smaller than the cap lets them take: conventioner 2 of 6, site 1 of 6; fix: echo '{\"cap\": <n>}' > ~/.config/agent-team/slots.json"
  echo '{}' >"$HOME/.config/agent-team/slots.json"
  run_bin -0 team-doctor
  assert_equal "$(line_of slots | sed 's/;.*fix:/; fix:/')" "WARN slots: ~/.config/agent-team/slots.json sets no cap, so the cap is the default 6; fix: echo '{\"cap\": <n>}' > ~/.config/agent-team/slots.json"
  # The fix keeps the file's other settings.
  echo '{"task_gib": 1.5}' >"$HOME/.config/agent-team/slots.json"
  run_bin -0 team-doctor
  assert_equal "$(line_of slots | sed 's/;.*fix:/; fix:/')" "WARN slots: ~/.config/agent-team/slots.json sets no cap, so the cap is the default 6; fix: add \"cap\": <n> to ~/.config/agent-team/slots.json"
}

@test "a slots.json team-slots refuses warns with its reason" {
  echo '{"cap": "ten", "slots": 3}' >"$HOME/.config/agent-team/slots.json"
  run_bin -0 team-doctor
  assert_equal "$(line_of slots)" "WARN slots: ~/.config/agent-team/slots.json: cap must be a whole number of 1 or more, not \"ten\"; slots is not a setting (they are: cap, reserved, dynamic, task_gib, reserve_gib, task_cores, reserve_cores, window_minutes, wait_minutes); fix: correct it as team-slots --help describes"
  echo '{"cap": 10' >"$HOME/.config/agent-team/slots.json"
  run_bin -0 team-doctor
  assert_contains "$(line_of slots)" "WARN slots: ~/.config/agent-team/slots.json is not JSON: "
  assert_contains "$(line_of slots)" "; fix: correct it as team-slots --help describes"
}

@test "more slots held than the effective cap warns, with no fix needed" {
  holding conventioner 1 11
  run_bin -0 team-doctor
  assert_equal "$(line_of slots)" "WARN slots: 11 held, over the effective cap of 10; cap 10 (slots.json), effective 10, 11 held, none kept, since no registered project's primary checkout is the code checkout; other programs use 8.0 GiB of 30.6 GiB and 1.0 of 12 cores ($(newest)); pools smaller than the cap lets them take: conventioner 2 of 10, site 1 of 10; fix: none needed; no task opens until some close"

  # Two readings in a row with other programs using 18 GiB lower it to 5.
  : >"$READINGS"
  slots_reading 5 18
  slots_reading 0 18
  rm "$TEAM_HOME/ledger.jsonl"
  holding conventioner 1 7
  run_bin -0 team-doctor
  assert_equal "$(line_of slots)" "WARN slots: 7 held, over the effective cap of 5; cap 10 (slots.json), effective 5 (lowered by memory), 7 held, none kept, since no registered project's primary checkout is the code checkout; other programs use 18.0 GiB of 30.6 GiB ($(newest)); pools smaller than the cap lets them take: conventioner 2 of 10, site 1 of 10; fix: none needed; no task opens until some close"
}

@test "stale readings warn only while this machine holds the lease, never on a machine whose heartbeat should not run" {
  : >"$READINGS"
  slots_reading 20 8 1
  local facts="cap 10 (slots.json), effective 10, 0 held, none kept, since no registered project's primary checkout is the code checkout; no reading of the machine's load in the last 15 minutes; pools smaller than the cap lets them take: conventioner 2 of 10, site 1 of 10"
  local stale="no reading of the machine's load in the last 15 minutes, though this machine holds the lease, whose heartbeat takes one every 5"
  run_bin -0 team-doctor
  assert_equal "$(line_of slots)" "WARN slots: $stale; $facts; fix: the slots step's lines in ~/.local/state/agent-team/heartbeat.log say why it takes none"
  "$REPO_ROOT/bin/team-timers" disable >/dev/null
  run_bin -1 team-doctor
  assert_equal "$(line_of slots)" "WARN slots: $stale; $facts; fix: team-timers enable"

  # Held by another machine: this one takes no readings, and the line passes.
  make_machine laptop
  run -0 "$REPO_ROOT/bin/team-lease" release
  on_machine laptop run -0 "$REPO_ROOT/bin/team-lease" take
  run_bin -0 team-doctor
  assert_equal "$(line_of lease | cut -d: -f1)" "WARN lease"
  assert_equal "$(line_of slots)" "PASS slots: $facts"

  # Nor while the lease line cannot say.
  git -C "$TEAM_HOME" remote set-url origin https://127.0.0.1:9/agent-team.git
  run_bin -1 team-doctor
  assert_equal "$(line_of slots)" "PASS slots: $facts"
}

@test "--help lists the slots check" {
  run_bin -0 team-doctor --help
  assert_contains "$output" "  slots         \`team-slots status --stored --json\`, which takes no reading"
}
