#!/usr/bin/env bats
# team-drill: a drill run recorded in the team home's drills.jsonl, and each registered drill's
# last run and whether it is due. The script runs from a code checkout of the test's own
# (code_checkout), so commits can be made under it; home-pc is named, and the claude stub answers
# 2.1.321.

load helpers/common

RECORD=''

setup() {
  sandbox
  code_checkout
  mkdir -p "$HOME/.config/agent-team"
  echo home-pc >"$HOME/.config/agent-team/machine"
  stub_reply claude '2.1.321 (Claude Code)'
  RECORD=$TEAM_HOME/drills.jsonl
}

# The code checkout's HEAD.
head_commit() {
  git -C "$CODE_CHECKOUT" rev-parse HEAD
}

# Commit a change to <path> in the code checkout; prints the commit: commit_path <path>
commit_path() {
  mkdir -p "$(dirname "$CODE_CHECKOUT/$1")"
  echo "$RANDOM" >>"$CODE_CHECKOUT/$1"
  git -C "$CODE_CHECKOUT" add -- "$1"
  git -C "$CODE_CHECKOUT" commit -q -m "feat: change $1"
  head_commit
}

# Append a record of <drill> that ended <days> days ago: record_line <drill> <days> [<verdict>
# [<commit> [<dirty>]]], the commit the code checkout's HEAD by default.
record_line() {
  jq -cn --arg drill "$1" --arg at "$(date -u -d "@$(($(date +%s) - $2 * 86400))" +%FT%TZ)" \
    --arg verdict "${3:-pass}" --arg commit "${4:-$(head_commit)}" --argjson dirty "${5:-false}" \
    '{at: $at, drill: $drill, machine: "home-pc", commit: $commit, dirty: $dirty, claude: "2.1.321",
      verdict: $verdict, detail: ""}' >>"$RECORD"
}

# The status view's entry of <drill>, as compact JSON: drill_json <drill>
drill_json() {
  run_bin -0 team-drill status --json
  jq -c --arg drill "$1" '.drills[] | select(.drill == $drill) | {due, age_days, changed_by}' <<<"$output"
}

# The text row of <drill> in team-drill status, its runs of spaces squeezed: row_of <drill>
row_of() {
  run_bin -0 team-drill status
  grep -E "^$1 " <<<"$output" | tr -s ' '
}

@test "record writes one line with every field, filling the machine, the commit and Claude Code's version itself" {
  local head
  head=$(head_commit)
  run_bin -0 --separate-stderr team-drill record compaction --verdict pass
  assert_equal "$output" "team-drill: recorded compaction pass on home-pc at ${head:0:7}"
  assert_equal "$stderr" ""
  assert_equal "$(wc -l <"$RECORD")" 1
  assert_equal "$(jq -c 'del(.at)' "$RECORD")" \
    "{\"drill\":\"compaction\",\"machine\":\"home-pc\",\"commit\":\"$head\",\"dirty\":false,\"claude\":\"2.1.321\",\"verdict\":\"pass\",\"detail\":\"\"}"
  # The time the run ended, in UTC, within the last minute.
  local at
  at=$(jq -r .at "$RECORD")
  [[ $at =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
  (($(date +%s) - $(date -d "$at" +%s) < 60))
  assert_equal "$(stub_calls claude)" '["--version"]'
}

@test "record takes a detail, marks a checkout with changes to tracked files dirty, and records no Claude Code that does not answer" {
  # An untracked file is no change to the code the drill ran.
  echo "new" >"$CODE_CHECKOUT/untracked.txt"
  stub_reply claude '' 127
  run_bin -0 team-drill record handoff --verdict fail --detail "the fence did not hold"
  assert_equal "$(jq -c '{dirty, claude, verdict, detail}' "$RECORD")" \
    '{"dirty":false,"claude":null,"verdict":"fail","detail":"the fence did not hold"}'
  echo "edited" >>"$CODE_CHECKOUT/README.md"
  stub_reply claude '2.1.321 (Claude Code)'
  run_bin -0 team-drill record handoff --verdict pass --detail ""
  assert_equal "$(tail -1 "$RECORD" | jq -c '{dirty, claude, detail}')" '{"dirty":true,"claude":"2.1.321","detail":""}'
  # Two runs, two lines, appended.
  assert_equal "$(wc -l <"$RECORD")" 2
}

@test "record refuses a drill the registry lacks, naming the known ones, and a drill its workflow's import records" {
  run_bin -1 team-drill record handof --verdict pass
  assert_equal "$output" "team-drill: no drill 'handof'; the drills are handoff, steal, load-check-planner, load-check-ops-prod-write, load-check-ops-vercel-read, compaction, bootstrap-arch, bootstrap-macos"
  run_bin -1 team-drill record bootstrap-arch --verdict pass
  assert_equal "$output" "team-drill: bootstrap-arch runs as the Bootstrap workflow's job bootstrap-arch, whose run team-drill import <run id> records"
  [[ ! -e $RECORD ]]
}

@test "record refuses on a fenced machine and on one that lost the lease, writing nothing" {
  mkdir -p "$HOME/.local/state/agent-team"
  echo '{"since": "2026-10-22T14:00:00Z", "holder": "laptop", "epoch": 2}' >"$HOME/.local/state/agent-team/fenced"
  run_bin -1 team-drill record compaction --verdict pass
  assert_equal "$output" "team-drill: home-pc is fenced since 2026-10-22T14:00:00Z (holder seen laptop, epoch 2): a fenced machine records no drill"
  rm "$HOME/.local/state/agent-team/fenced"
  hold_lease home-pc >/dev/null
  make_machine laptop
  steal_lease laptop home-pc
  run_bin -1 team-drill record compaction --verdict pass
  assert_equal "$output" "team-drill: home-pc no longer holds the lease: origin names laptop (held, epoch 2): a machine that lost the lease records no drill"
  [[ ! -e $RECORD ]]
}

@test "record refuses a code checkout whose HEAD it cannot read, and a machine with no team name" {
  mv "$CODE_CHECKOUT/.git" "$CODE_CHECKOUT/.git-gone"
  run_bin -1 team-drill record compaction --verdict pass
  assert_equal "$output" "team-drill: cannot read the HEAD of the code checkout $CODE_CHECKOUT, so the drill's commit is unknown"
  mv "$CODE_CHECKOUT/.git-gone" "$CODE_CHECKOUT/.git"
  rm "$HOME/.config/agent-team/machine"
  run_bin -1 team-drill record compaction --verdict pass
  assert_contains "$output" "team-drill: this machine has no team name"
  [[ ! -e $RECORD ]]
}

@test "a missing or other verdict, a detail of two lines or over 300 characters, and other malformed command lines are exit 2" {
  local long
  printf -v long '%301s' ''
  run_bin -2 team-drill record compaction
  assert_equal "$output" "team-drill: record needs --verdict pass or --verdict fail"
  run_bin -2 team-drill record compaction --verdict maybe
  assert_equal "$output" "team-drill: --verdict takes pass or fail, not 'maybe'"
  run_bin -2 team-drill record compaction --verdict pass --detail $'one\ntwo'
  assert_equal "$output" "team-drill: --detail takes one line of at most 300 characters"
  run_bin -2 team-drill record compaction --verdict pass --detail "${long// /x}"
  assert_equal "$output" "team-drill: --detail takes one line of at most 300 characters"
  run_bin -2 team-drill record compaction --verdict pass --detail
  assert_equal "$output" "team-drill: --detail takes one line of at most 300 characters"
  run_bin -2 team-drill record --verdict pass
  assert_contains "$output" "team-drill: record needs a drill"
  run_bin -2 team-drill record compaction --verdict pass --machine laptop
  assert_contains "$output" "team-drill: unexpected argument '--machine'"
  run_bin -2 team-drill status --text
  assert_contains "$output" "team-drill: unexpected argument '--text'"
  run_bin -2 team-drill rerun
  assert_contains "$output" "team-drill: unknown subcommand 'rerun'"
  [[ ! -e $RECORD ]]
  # A detail of exactly 300 characters is one line.
  run_bin -0 team-drill record compaction --verdict pass --detail "${long:1}"
}

@test "status with no record shows every drill, in the registry's order, as never ran" {
  run_bin -0 team-drill status
  assert_equal "$output" "drill                       last run  age  machine  commit  claude  verdict  state
handoff                                                                      due: never ran
steal                                                                        due: never ran
load-check-planner                                                           due: never ran
load-check-ops-prod-write                                                    due: never ran
load-check-ops-vercel-read                                                   due: never ran
compaction                                                                   due: never ran
bootstrap-arch                                                               due: never ran
bootstrap-macos                                                              due: never ran"
  run_bin -0 team-drill status --json
  assert_equal "$(jq -c '{schema, max_age_days, malformed}' <<<"$output")" '{"schema":"team-drill/1","max_age_days":30,"malformed":0}'
  assert_equal "$(jq -c '.drills[0]' <<<"$output")" \
    '{"drill":"handoff","by":"daniel","what":"The team moves to a second machine and back, with one trivial task at work.","last":null,"age_days":null,"due":["never"],"changed_by":null}'
  assert_equal "$(jq -r '[.drills[] | "\(.drill):\(.by):\(.due | join(","))"] | join(" ")' <<<"$output")" \
    "handoff:daniel:never steal:daniel:never load-check-planner:coordinator:never load-check-ops-prod-write:daniel:never load-check-ops-vercel-read:daniel:never compaction:coordinator:never bootstrap-arch:coordinator:never bootstrap-macos:coordinator:never"
}

@test "status shows a drill that passed today as ok, with its run, and one that failed as due" {
  local head
  head=$(head_commit)
  run_bin -0 team-drill record compaction --verdict pass
  run_bin -0 team-drill record handoff --verdict fail
  assert_equal "$(row_of compaction)" "compaction $(date -u +%F) 0 days home-pc ${head:0:7} 2.1.321 pass ok"
  assert_equal "$(row_of handoff)" "handoff $(date -u +%F) 0 days home-pc ${head:0:7} 2.1.321 fail due: failed on $(date -u +%F)"
  assert_equal "$(drill_json compaction)" '{"due":[],"age_days":0,"changed_by":null}'
  assert_equal "$(drill_json handoff)" '{"due":["failed"],"age_days":0,"changed_by":null}'
  run_bin -0 team-drill status --json
  assert_equal "$(jq -c '.drills[] | select(.drill == "compaction") | .last | del(.at)' <<<"$output")" \
    "{\"drill\":\"compaction\",\"machine\":\"home-pc\",\"commit\":\"$head\",\"dirty\":false,\"claude\":\"2.1.321\",\"verdict\":\"pass\",\"detail\":\"\"}"
}

@test "status: a drill 31 days old is old, one 30 days old is not, and one run on uncommitted changes is dirty" {
  record_line steal 31
  record_line handoff 30
  record_line compaction 1 pass "$(head_commit)" true
  assert_equal "$(drill_json steal)" '{"due":["old"],"age_days":31,"changed_by":null}'
  assert_equal "$(row_of steal)" "steal $(date -u -d '31 days ago' +%F) 31 days home-pc $(head_commit | cut -c1-7) 2.1.321 pass due: last ran 31 days ago"
  assert_equal "$(drill_json handoff)" '{"due":[],"age_days":30,"changed_by":null}'
  assert_equal "$(drill_json compaction)" '{"due":["dirty"],"age_days":1,"changed_by":null}'
  assert_equal "$(row_of compaction | sed 's/.* pass //')" "due: ran on uncommitted changes"
}

@test "status: a drill that ran before a commit touching a path it proves is changed, and one before a commit touching only other paths is not due" {
  record_line compaction 0
  record_line handoff 0
  local changed
  changed=$(commit_path tests/fixtures/compaction-drill/stubs/claude)
  commit_path README.md >/dev/null
  assert_equal "$(drill_json compaction)" "{\"due\":[\"changed\"],\"age_days\":0,\"changed_by\":\"$changed\"}"
  assert_equal "$(row_of compaction | sed 's/.* pass //')" "due: ran before ${changed:0:7} changed the code it proves"
  assert_equal "$(drill_json handoff)" '{"due":[],"age_days":0,"changed_by":null}'
  # The last commit to touch a proved path is the one named.
  changed=$(commit_path tests/compaction-drill)
  assert_equal "$(drill_json compaction)" "{\"due\":[\"changed\"],\"age_days\":0,\"changed_by\":\"$changed\"}"
}

@test "status: a drill run on a commit the checkout lacks is unknown-commit, and every reason that holds is listed in order" {
  record_line compaction 0 pass 0123456789abcdef0123456789abcdef01234567
  assert_equal "$(drill_json compaction)" '{"due":["unknown-commit"],"age_days":0,"changed_by":null}'
  assert_equal "$(row_of compaction | sed 's/.* pass //')" "due: ran on a commit this checkout lacks (0123456)"
  record_line load-check-ops-prod-write 40 fail "$(head_commit)" true
  commit_path servers/package-lock.json >/dev/null
  run_bin -0 team-drill status --json
  assert_equal "$(jq -c '.drills[] | select(.drill == "load-check-ops-prod-write") | .due' <<<"$output")" '["failed","dirty","changed","old"]'
  assert_equal "$(row_of load-check-ops-prod-write | sed 's/.* fail //')" "due: failed on $(date -u -d '40 days ago' +%F)"
}

@test "status: a line that is no drill record is skipped and counted, and a drill's last run is its last valid line" {
  record_line compaction 2 fail
  record_line compaction 1 pass
  local valid
  valid=$(tail -1 "$RECORD")
  {
    echo 'not json'
    echo '{"at":"2026-11-10T10:00:00Z","drill":"compaction"}'
    jq -c '.drill = "compactoin"' <<<"$valid"
    jq -c '.commit = "abc"' <<<"$valid"
    jq -c '.verdict = "skipped"' <<<"$valid"
    jq -c '.detail = "two\nlines"' <<<"$valid"
    jq -c '.at = "2026-11-10 10:00:00"' <<<"$valid"
    jq -c '.verdict = "fail" | .dirty = "no"' <<<"$valid"
    echo '[]'
  } >>"$RECORD"
  run_bin -0 team-drill status --json
  assert_equal "$(jq .malformed <<<"$output")" 9
  assert_equal "$(drill_json compaction)" '{"due":[],"age_days":1,"changed_by":null}'
  run_bin -0 team-drill status
  assert_equal "$(tail -1 <<<"$output")" "9 lines of drills.jsonl are no drill record; they are skipped"
  # The lines stay as they are.
  assert_equal "$(wc -l <"$RECORD")" 11
}
