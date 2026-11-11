#!/usr/bin/env bats
# shellcheck disable=SC2153 # CODE_START and the other globals are helpers/doctor.bash's
# team-doctor: one PASS, WARN or FAIL line per thing this machine needs, on the machine
# tests/helpers/doctor.bash builds: every tool a version stub, the OS a stubbed uname.
# This file: the drills line, which reads team-drill status --json; on the doctor's machine every
# drill passed today on the code checkout's first commit, CODE_START.

load helpers/common
load helpers/doctor

FIX="team-drill status lists them, and sops/drills.md has each one's runbook"

setup() {
  sandbox
  doctor_machine
  only_checks 182-drills.sh
  tools_at arch
}

# The registry's drill count.
drill_count() {
  jq '.drills | length' "$REPO_ROOT/bin/lib/drills.json"
}

# Commit a change to <path> in the code checkout, with git's plumbing as doctor_machine makes
# CODE_START; prints the commit: code_commit <path>
code_commit() {
  mkdir -p "$(dirname "$CODE_CHECKOUT/$1")"
  echo "$RANDOM" >>"$CODE_CHECKOUT/$1"
  git -C "$CODE_CHECKOUT" add -- "$1"
  local commit
  commit=$(git -C "$CODE_CHECKOUT" commit-tree -p HEAD -m "feat: change $1" "$(git -C "$CODE_CHECKOUT" write-tree)")
  git -C "$CODE_CHECKOUT" update-ref HEAD "$commit"
  echo "$commit"
}

# Append a run of <drill> that ended <days> days ago, which is its last: drill_line <drill> <days>
# [<verdict> [<commit> [<dirty>]]], the commit CODE_START by default.
drill_line() {
  jq -cn --arg drill "$1" --arg at "$(date -u -d "@$(($(date +%s) - $2 * 86400))" +%FT%TZ)" \
    --arg verdict "${3:-pass}" --arg commit "${4:-$CODE_START}" --argjson dirty "${5:-false}" \
    '{at: $at, drill: $drill, machine: "home-pc", commit: $commit, dirty: $dirty, claude: "2.1.321",
      verdict: $verdict, detail: ""}' >>"$TEAM_HOME/drills.jsonl"
}

# Drop every run of <drill> from the record, so it never ran: never_ran <drill>
never_ran() {
  local kept
  kept=$(grep -vF "\"drill\":\"$1\"" "$TEAM_HOME/drills.jsonl")
  printf '%s\n' "$kept" >"$TEAM_HOME/drills.jsonl"
}

@test "the drills line passes when every drill passed within 30 days on the code it proves" {
  run_bin -0 team-doctor
  assert_equal "$output" "PASS drills: $(drill_count) drills, each passed within 30 days on the code it proves"
  # A commit that touches only paths no drill proves leaves each proven.
  code_commit docs/notes.md >/dev/null
  drill_line compaction 30
  run_bin -0 team-doctor
  assert_equal "$output" "PASS drills: $(drill_count) drills, each passed within 30 days on the code it proves"
}

@test "the drills line warns, never fails, naming each due drill's first reason in the registry's order" {
  local today changed
  today=$(date -u +%F)
  # Failed today, on uncommitted changes too: only the failure is named.
  drill_line handoff 0 fail "$CODE_START" true
  never_ran steal
  drill_line load-check-planner 0 pass 0123456789abcdef0123456789abcdef01234567
  drill_line load-check-ops-prod-write 0 pass "$CODE_START" true
  # 30 days is within the age; 31 is over it.
  drill_line load-check-ops-vercel-read 31
  drill_line bootstrap-arch 30
  changed=$(code_commit tests/compaction-drill)
  run_bin -0 team-doctor
  assert_equal "$output" "WARN drills: 6 of $(drill_count) drills are due: handoff failed on $today; steal never ran; load-check-planner ran on a commit this checkout lacks (0123456); load-check-ops-prod-write ran on uncommitted changes; load-check-ops-vercel-read last ran 31 days ago; compaction ran before ${changed:0:7} changed the code it proves; fix: $FIX"

  # A run over a day ahead of the clock is due, never fresh.
  drill_line bootstrap-arch -40
  run_bin -0 team-doctor
  assert_equal "$output" "WARN drills: 7 of $(drill_count) drills are due: handoff failed on $today; steal never ran; load-check-planner ran on a commit this checkout lacks (0123456); load-check-ops-prod-write ran on uncommitted changes; load-check-ops-vercel-read last ran 31 days ago; compaction ran before ${changed:0:7} changed the code it proves; bootstrap-arch ran at $(date -u -d '40 days' +%F), over a day ahead of this machine's clock; fix: $FIX"

  # One due drill is one that is due.
  drill_line handoff 0
  drill_line steal 0
  drill_line load-check-planner 0
  drill_line load-check-ops-prod-write 0
  drill_line load-check-ops-vercel-read 0
  drill_line compaction 0 pass "$changed"
  drill_line bootstrap-arch 0
  drill_line bootstrap-macos 0 fail
  run_bin -0 team-doctor
  assert_equal "$output" "WARN drills: 1 of $(drill_count) drills is due: bootstrap-macos failed on $today; fix: $FIX"
}

@test "lines of drills.jsonl that are no drill record make the drills line warn, counted after any due drill" {
  echo 'not json' >>"$TEAM_HOME/drills.jsonl"
  run_bin -0 team-doctor
  assert_equal "$output" "WARN drills: $(drill_count) drills, each passed within 30 days on the code it proves; 1 line of drills.jsonl is no drill record; fix: $FIX"
  # A drill the registry lacks is no drill record either, and skipped.
  drill_line handof 0
  never_ran steal
  run_bin -0 team-doctor
  assert_equal "$output" "WARN drills: 1 of $(drill_count) drills is due: steal never ran; 2 lines of drills.jsonl are no drill record; fix: $FIX"
}

@test "the drills line warns with team-drill's first error when team-drill status does not answer" {
  # The sandbox's bin/lib is a directory of its own, its files links: replace one, never edit it.
  rm "$CODE_CHECKOUT/bin/lib/drills.json"
  echo '{"drills": "none"}' >"$CODE_CHECKOUT/bin/lib/drills.json"
  run_bin -0 team-doctor
  assert_equal "$output" "WARN drills: \`team-drill status\` did not answer: cannot read the drill registry $CODE_CHECKOUT/bin/lib/drills.json; fix: fix what it names, then run team-doctor again"
}

@test "the drills line's part of team-doctor --help comes between the records and the team home's trust" {
  run_bin -0 team-doctor --help
  local part
  part=$(sed -n '/^  drills  /,/^  trust team home$/p' <<<"$output")
  assert_equal "$(head -n 1 <<<"$part")" "  drills        \`team-drill status --json\`: passes when every drill of bin/lib/drills.json passed"
  assert_equal "$(tail -n 1 <<<"$part")" "  trust team home"
  # Its lines are indented as the other checks' are, and the records line's come before them.
  assert_equal "$(sed '1d;$d' <<<"$part" | grep -cv '^                ')" 0
  grep -B 1 '^  drills  ' <<<"$output" | head -n 1 | grep -q '^                '
  [[ $(grep -n '^  records  ' <<<"$output" | cut -d: -f1) -lt $(grep -n '^  drills  ' <<<"$output" | cut -d: -f1) ]]
}
