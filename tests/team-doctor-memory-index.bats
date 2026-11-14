#!/usr/bin/env bats
# team-doctor: one PASS, WARN or FAIL line per thing this machine needs, on the machine
# tests/helpers/doctor.bash builds: every tool a version stub, the OS a stubbed uname.
# This file: the memory index line, which reads each memory/*/MEMORY.md of the team home against
# Claude Code's load cap of 200 lines or 25,000 characters.

load helpers/common
load helpers/doctor

FIX_ONE="condense each line of memory/conventioner/MEMORY.md to its hook, one line per memory, so every memory loads"

setup() {
  sandbox
  doctor_machine
  only_checks 125-memory-index.sh
  tools_at arch
}

# Write memory/<project>/MEMORY.md with <lines> lines of <width> characters each (9 at least),
# every one marked SECRET-, as an index's pointers are a memory's text:
# index_of <project> <lines> <width>
index_of() {
  mkdir -p "$TEAM_HOME/memory/$1"
  awk -v n="$2" -v w="$3" 'BEGIN {
    line = "- SECRET-"; while (length(line) < w) line = line "x"
    for (i = 1; i <= n; i++) print line
  }' >"$TEAM_HOME/memory/$1/MEMORY.md"
}

@test "an index past 200 lines warns, naming it, its lines and characters, and the line the cut falls at" {
  index_of conventioner 201 10
  index_of coordinator 20 50
  run_bin -0 team-doctor
  assert_equal "$output" "WARN memory index: conventioner's MEMORY.md is 201 lines and 2,210 characters, past Claude Code's load cap of 200 lines or 25,000 characters, so its sessions load lines 1 to 200 and the cut falls at line 201; fix: $FIX_ONE"
  [[ $output != *SECRET-* ]]
}

@test "an index past 25,000 characters in fewer than 200 lines warns, the cut falling at the last whole line" {
  # 100 lines of 249 characters and their newlines end at 24,999, then line 101 is one character:
  # 25,001 once the last newline is trimmed, as Claude Code trims the index. The cut falls at the
  # last newline within 25,000, after line 100.
  index_of conventioner 100 249
  printf 'y\n' >>"$TEAM_HOME/memory/conventioner/MEMORY.md"
  run_bin -0 team-doctor
  assert_equal "$output" "WARN memory index: conventioner's MEMORY.md is 101 lines and 25,001 characters, past Claude Code's load cap of 200 lines or 25,000 characters, so its sessions load lines 1 to 100 and the cut falls at line 101; fix: $FIX_ONE"
  # One character more on each line ends line 100 at 25,099, which moves the cut to it.
  index_of conventioner 100 250
  printf 'y\n' >>"$TEAM_HOME/memory/conventioner/MEMORY.md"
  run_bin -0 team-doctor
  assert_contains "$output" "is 101 lines and 25,101 characters, past Claude Code's load cap of 200 lines or 25,000 characters, so its sessions load lines 1 to 99 and the cut falls at line 100;"
  [[ $output != *SECRET-* ]]
}

@test "a first line past 25,000 characters loads only part of line 1" {
  index_of conventioner 1 25001
  run_bin -0 team-doctor
  assert_contains "$output" "WARN memory index: conventioner's MEMORY.md is 1 line and 25,001 characters, past Claude Code's load cap of 200 lines or 25,000 characters, so its sessions load part of line 1 and the cut falls inside it;"
}

@test "a character outside the Basic Multilingual Plane counts twice, as Claude Code counts it" {
  # 24,999 characters, then an emoji Claude Code's JavaScript counts as two: 25,001.
  index_of conventioner 1 24999
  printf '\xf0\x9f\x98\x80\n' >>"$TEAM_HOME/memory/conventioner/MEMORY.md"
  run_bin -0 team-doctor
  assert_contains "$output" "conventioner's MEMORY.md is 2 lines and 25,002 characters"
  assert_contains "$output" "so its sessions load line 1 and the cut falls at line 2;"
}

@test "each index past the cap is named, and the fix names each" {
  index_of conventioner 201 10
  index_of agent-team 210 10
  index_of coordinator 20 50
  run_bin -0 --separate-stderr team-doctor --json
  assert_equal "$(jq -r '.[0].reason' <<<"$output")" "agent-team's MEMORY.md is 210 lines and 2,309 characters, past Claude Code's load cap of 200 lines or 25,000 characters, so its sessions load lines 1 to 200 and the cut falls at line 201; conventioner's MEMORY.md is 201 lines and 2,210 characters, past it too, so its sessions load lines 1 to 200 and the cut falls at line 201"
  assert_equal "$(jq -r '.[0].fix' <<<"$output")" \
    "condense each line of memory/agent-team/MEMORY.md and memory/conventioner/MEMORY.md to its hook, one line per memory, so every memory loads"
}

@test "with every index within the cap it passes, naming the fullest" {
  # 200 lines is within it (200 of 124 characters and their newlines, the last trimmed, is 24,999),
  # and so is one line of 25,000 characters; the first as full, by name, is the fullest.
  index_of conventioner 200 124
  index_of coordinator 1 25000
  index_of agent-team 20 50
  run_bin -0 team-doctor
  assert_equal "$output" "PASS memory index: 3 memory indexes, each within Claude Code's load cap of 200 lines and 25,000 characters; the fullest, conventioner's, is 200 lines and 24,999 characters"
  rm -r "${TEAM_HOME:?}/memory/conventioner" "${TEAM_HOME:?}/memory/coordinator"
  run_bin -0 team-doctor
  assert_equal "$output" "PASS memory index: 1 memory index, within Claude Code's load cap of 200 lines and 25,000 characters; agent-team's is 20 lines and 1,019 characters"
}

@test "with no memory directory, or none holding an index, it passes and says there is none" {
  rm -rf "${TEAM_HOME:?}/memory"
  run_bin -0 team-doctor
  assert_equal "$output" "PASS memory index: the team home has no memory/*/MEMORY.md, so no index to load"
  mkdir -p "$TEAM_HOME/memory/conventioner"
  run_bin -0 team-doctor
  assert_equal "$output" "PASS memory index: the team home has no memory/*/MEMORY.md, so no index to load"
}

@test "an index it cannot read warns, naming it" {
  index_of conventioner 20 50
  index_of coordinator 20 50
  chmod 000 "$TEAM_HOME/memory/conventioner/MEMORY.md"
  if [[ -r $TEAM_HOME/memory/conventioner/MEMORY.md ]]; then
    skip "this user reads a file of mode 000"
  fi
  run_bin -0 team-doctor
  chmod 600 "$TEAM_HOME/memory/conventioner/MEMORY.md"
  assert_equal "$output" "WARN memory index: memory/conventioner/MEMORY.md cannot be read; fix: make memory/conventioner/MEMORY.md readable, then run team-doctor again"
}

@test "with no team home it warns, pointing at the team home line" {
  rm "$HOME/.config/agent-team/home"
  unset TEAM_HOME
  run -0 "$CODE_CHECKOUT/bin/team-doctor"
  assert_equal "$output" \
    "WARN memory index: no team home to read the memory indexes from (the team home line); fix: the team home line's fix, then run team-doctor again"
}
