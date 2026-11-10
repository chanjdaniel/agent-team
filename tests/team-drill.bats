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
    jq -c '.verdict = "fail" | .run = 4242' <<<"$valid"
    echo '[]'
  } >>"$RECORD"
  run_bin -0 team-drill status --json
  assert_equal "$(jq .malformed <<<"$output")" 10
  assert_equal "$(drill_json compaction)" '{"due":[],"age_days":1,"changed_by":null}'
  run_bin -0 team-drill status
  assert_equal "$(tail -1 <<<"$output")" "10 lines of drills.jsonl are no drill record; they are skipped"
  # The lines stay as they are.
  assert_equal "$(wc -l <"$RECORD")" 12
  # A run that is a string is a record's: an imported run's line.
  jq -c '.verdict = "fail" | .run = "https://github.com/owner/agent-team/actions/runs/4242"' <<<"$valid" >>"$RECORD"
  assert_equal "$(drill_json compaction)" '{"due":["failed"],"age_days":1,"changed_by":null}'
}

# The Bootstrap workflow's runs as gh shows them: gh run view <id> --json answers from
# $STUB_FIXTURES/run-<id>.json and gh run view <id> --log --job <job id> from
# $STUB_FIXTURES/log-<job id>, each call's directory a line of $STUB_FIXTURES/gh.pwd; any other
# call, or a run or log with no fixture, fails.
gh_runs() {
  stub_script gh <<'STUB'
printf '%s\n' "$PWD" >>"$STUB_FIXTURES/gh.pwd"
if [[ $1 == run && $2 == view && $4 == --json && $# == 5 ]]; then print_file "$STUB_FIXTURES/run-$3.json"; exit 0; fi
if [[ $1 == run && $2 == view && $4 == --log && $5 == --job && $# == 6 ]]; then print_file "$STUB_FIXTURES/log-$6"; exit 0; fi
echo "unplanned gh call: $*" >&2
exit 1
STUB
}

RUN_SHA=4fa41cbdca1c00e9c4a87381d191429410a02307

# run_json <id> <status> <workflow> [<job>=<conclusion>]...: run <id> of <workflow>, which ran on
# RUN_SHA and was last updated at 10:40; each job's id is 9<index><id>, and a completed run's job
# completed at 10:3<index>.
run_json() {
  local id=$1 state=$2 workflow=$3 jobs='[]' spec i=0
  shift 3
  for spec; do
    jobs=$(jq -c --arg name "${spec%%=*}" --arg conclusion "${spec#*=}" --argjson id "9$i$id" \
      --arg state "$state" --arg at "2026-11-10T10:3${i}:00Z" \
      '. + [{name: $name, databaseId: $id, status: $state, conclusion: $conclusion,
        startedAt: "2026-11-10T10:00:00Z", completedAt: (if $state == "completed" then $at else "0001-01-01T00:00:00Z" end),
        url: "https://github.com/owner/agent-team/actions/runs/\($id)/job/\($id)"}]' <<<"$jobs")
    i=$((i + 1))
  done
  jq -n --argjson id "$id" --arg state "$state" --arg workflow "$workflow" --arg sha "$RUN_SHA" --argjson jobs "$jobs" \
    '{status: $state, conclusion: (if $state == "completed" then "success" else "" end), headSha: $sha,
      url: "https://github.com/owner/agent-team/actions/runs/\($id)", workflowName: $workflow,
      updatedAt: "2026-11-10T10:40:00Z", jobs: $jobs}' >"$STUB_FIXTURES/run-$id.json"
}

# job_log <job id> <job> <text>...: the job's log as gh prints it, one line per <text>, each after
# the job's and step's names and a timestamp, the first with the byte order mark GitHub starts a
# step's log with.
job_log() {
  local id=$1 job=$2 text bom=$'\xef\xbb\xbf'
  shift 2
  for text; do
    printf '%s\t%s\t%s2026-11-10T10:29:59.1234567Z %s\n' "$job" "Run tests/bootstrap-drill $job" "$bom" "$text"
    bom=''
  done >"$STUB_FIXTURES/log-$id"
}

# The line tests/bootstrap-drill ends with: drill_record <machine> <verdict> [<commit> [<claude>]],
# the commit the code checkout's HEAD by default.
drill_record() {
  echo "drill-record: machine=$1 verdict=$2 commit=${3:-$(head_commit)} claude=${4:-2.1.321}"
}

# The record's lines of <drill>, whole: lines_of <drill>
lines_of() {
  jq -c --arg drill "$1" 'select(.drill == $drill)' "$RECORD"
}

@test "import records each Bootstrap job's run from its record line, the job's end and the run's URL" {
  gh_runs
  run_json 4242 completed Bootstrap bootstrap-macos=success bootstrap-arch=success
  # The last record line counts: an earlier one is a run's echo, or a round before.
  job_log 904242 bootstrap-macos "== round 1: team-bootstrap, as the agent runs it" \
    "$(drill_record ci-macos fail)" "== it ended with: projects: Daniel: run gh auth login" "$(drill_record ci-macos pass)"
  job_log 914242 bootstrap-arch "$(drill_record ci-arch pass "$(head_commit)" 2.1.322)" "Cleaning up orphan processes"
  local head
  head=$(head_commit)
  run_bin -0 --separate-stderr team-drill import 4242
  assert_equal "$output" "team-drill: recorded bootstrap-arch pass on ci-arch at ${head:0:7}
team-drill: recorded bootstrap-macos pass on ci-macos at ${head:0:7}"
  assert_equal "$stderr" ""
  assert_equal "$(lines_of bootstrap-arch)" \
    "{\"at\":\"2026-11-10T10:31:00Z\",\"drill\":\"bootstrap-arch\",\"machine\":\"ci-arch\",\"commit\":\"$head\",\"dirty\":false,\"claude\":\"2.1.322\",\"verdict\":\"pass\",\"detail\":\"\",\"run\":\"https://github.com/owner/agent-team/actions/runs/4242\"}"
  assert_equal "$(lines_of bootstrap-macos)" \
    "{\"at\":\"2026-11-10T10:30:00Z\",\"drill\":\"bootstrap-macos\",\"machine\":\"ci-macos\",\"commit\":\"$head\",\"dirty\":false,\"claude\":\"2.1.321\",\"verdict\":\"pass\",\"detail\":\"\",\"run\":\"https://github.com/owner/agent-team/actions/runs/4242\"}"
  assert_equal "$(stub_calls gh)" '["run","view","4242","--json","status,conclusion,headSha,url,workflowName,updatedAt,jobs"]
["run","view","4242","--log","--job","914242"]
["run","view","4242","--log","--job","904242"]'
  # gh runs in the code checkout, which names the repository.
  assert_equal "$(sort -u "$STUB_FIXTURES/gh.pwd")" "$CODE_CHECKOUT"
  # The status reads them as any other record.
  assert_equal "$(drill_json bootstrap-arch | jq -c .due)" '[]'
  assert_equal "$(row_of bootstrap-macos | sed 's/.* ci-macos //')" "${head:0:7} 2.1.321 pass ok"
}

@test "import records a fail when the job failed or its record line says fail" {
  gh_runs
  run_json 4243 completed Bootstrap bootstrap-arch=failure bootstrap-macos=success
  job_log 904243 bootstrap-arch "$(drill_record ci-arch pass)"
  job_log 914243 bootstrap-macos "$(drill_record ci-macos fail "$RUN_SHA" 2.1.321)"
  run_bin -0 team-drill import 4243
  assert_contains "$output" "team-drill: recorded bootstrap-arch fail on ci-arch at $(head_commit | cut -c1-7)"
  assert_contains "$output" "team-drill: recorded bootstrap-macos fail on ci-macos at ${RUN_SHA:0:7}"
  assert_equal "$(lines_of bootstrap-arch | jq -c '{machine, claude, verdict, detail}')" \
    '{"machine":"ci-arch","claude":"2.1.321","verdict":"fail","detail":"the job ended failure; its record line says verdict=pass"}'
  assert_equal "$(lines_of bootstrap-macos | jq -c '{commit, verdict, detail}')" \
    "{\"commit\":\"$RUN_SHA\",\"verdict\":\"fail\",\"detail\":\"the job ended success; its record line says verdict=fail\"}"
  # The commit the run built, which this checkout lacks, is the status's reason after the failure.
  assert_equal "$(drill_json bootstrap-macos | jq -c .due)" '["failed","unknown-commit"]'
}

@test "import records a fail with the run's commit for a job with no record line, or one that does not parse" {
  gh_runs
  run_json 4244 completed Bootstrap bootstrap-arch=failure bootstrap-macos=success
  job_log 904244 bootstrap-arch "tools: the Claude Code install failed (exit 1)"
  # The drill writes commit=unknown when it cannot read its checkout's HEAD, which is no commit.
  job_log 914244 bootstrap-macos "$(drill_record ci-macos pass unknown)"
  run_bin -0 team-drill import 4244
  assert_equal "$output" "team-drill: recorded bootstrap-arch fail on ci-arch at ${RUN_SHA:0:7}
team-drill: recorded bootstrap-macos fail on ci-macos at ${RUN_SHA:0:7}"
  assert_equal "$(lines_of bootstrap-arch | jq -c 'del(.run)')" \
    "{\"at\":\"2026-11-10T10:30:00Z\",\"drill\":\"bootstrap-arch\",\"machine\":\"ci-arch\",\"commit\":\"$RUN_SHA\",\"dirty\":false,\"claude\":null,\"verdict\":\"fail\",\"detail\":\"the job ended failure with no record line\"}"
  assert_equal "$(lines_of bootstrap-macos | jq -c '{machine, commit, claude, detail}')" \
    "{\"machine\":\"ci-macos\",\"commit\":\"$RUN_SHA\",\"claude\":null,\"detail\":\"the job ended success with no record line\"}"
  # Each other malformed line is no record line either.
  local bad i=5
  for bad in "drill-record: machine=CI_ARCH verdict=pass commit=$(head_commit) claude=2.1.321" \
    "drill-record: machine=ci-arch verdict=maybe commit=$(head_commit) claude=2.1.321" \
    "drill-record: machine=ci-arch verdict=pass commit=$(head_commit) claude=2.1.321-beta" \
    "drill-record: machine=ci-arch verdict=pass commit=$(head_commit)" \
    "drill-record: machine=ci-arch verdict=pass commit=$(head_commit) claude=2.1.321 extra=1" \
    "drill-record: machine=ci-arch machine=ci-arch commit=$(head_commit) claude=2.1.321"; do
    run_json "424$i" completed Bootstrap bootstrap-arch=success bootstrap-macos=success
    job_log "90424$i" bootstrap-arch "$bad"
    job_log "91424$i" bootstrap-macos "$(drill_record ci-macos pass)"
    run_bin -0 team-drill import "424$i"
    assert_equal "$(tail -1 <(lines_of bootstrap-arch) | jq -c '{commit, verdict, detail}')" \
      "{\"commit\":\"$RUN_SHA\",\"verdict\":\"fail\",\"detail\":\"the job ended success with no record line\"}"
    i=$((i + 1))
  done
}

@test "import records a record line's claude=none, which the drill writes when it finds no Claude Code, as null" {
  gh_runs
  run_json 4249 completed Bootstrap bootstrap-arch=failure bootstrap-macos=success
  job_log 904249 bootstrap-arch "$(drill_record ci-arch fail "$(head_commit)" none)"
  job_log 914249 bootstrap-macos "$(drill_record ci-macos pass "$(head_commit)" none)"
  run_bin -0 team-drill import 4249
  assert_equal "$(lines_of bootstrap-arch | jq -c '{commit, claude, verdict, detail}')" \
    "{\"commit\":\"$(head_commit)\",\"claude\":null,\"verdict\":\"fail\",\"detail\":\"the job ended failure; its record line says verdict=fail\"}"
  assert_equal "$(lines_of bootstrap-macos | jq -c '{claude, verdict}')" '{"claude":null,"verdict":"pass"}'
  assert_equal "$(row_of bootstrap-macos | sed 's/.* ci-macos [0-9a-f]* //')" "none pass ok"
}

@test "import records a fail for a drill whose job the run lacks, at the run's last update" {
  gh_runs
  run_json 4250 completed Bootstrap bootstrap-macos=success
  job_log 904250 bootstrap-macos "$(drill_record ci-macos pass)"
  run_bin -0 team-drill import 4250
  assert_equal "$(lines_of bootstrap-arch | jq -c 'del(.run)')" \
    "{\"at\":\"2026-11-10T10:40:00Z\",\"drill\":\"bootstrap-arch\",\"machine\":\"ci-arch\",\"commit\":\"$RUN_SHA\",\"dirty\":false,\"claude\":null,\"verdict\":\"fail\",\"detail\":\"the run has no job bootstrap-arch\"}"
  assert_equal "$(lines_of bootstrap-macos | jq -r .verdict)" pass
}

@test "import of a run still going exits 75, and of another workflow's run is refused, each writing nothing" {
  gh_runs
  run_json 4251 in_progress Bootstrap bootstrap-macos= bootstrap-arch=
  run_bin -75 --separate-stderr team-drill import 4251
  assert_equal "$stderr" "team-drill: run 4251 is in_progress, not completed; import it again once it completes"
  run_json 4252 completed CI test=success
  run_bin -1 team-drill import 4252
  assert_equal "$output" "team-drill: run 4252 is a run of CI, not of the Bootstrap workflow"
  [[ ! -e $RECORD ]]
  # No job's log was read.
  assert_equal "$(stub_calls gh | jq -r '.[3]' | sort -u)" --json
}

@test "a second import of the same run adds nothing and says so" {
  gh_runs
  run_json 4253 completed Bootstrap bootstrap-macos=success bootstrap-arch=success
  job_log 904253 bootstrap-macos "$(drill_record ci-macos pass)"
  job_log 914253 bootstrap-arch "$(drill_record ci-arch pass)"
  run_bin -0 team-drill import 4253
  local before
  before=$(cat "$RECORD")
  : >"$STUB_CALLS/gh.log"
  run_bin -0 team-drill import 4253
  assert_equal "$output" "team-drill: bootstrap-arch of run https://github.com/owner/agent-team/actions/runs/4253 is recorded already, so it is skipped
team-drill: bootstrap-macos of run https://github.com/owner/agent-team/actions/runs/4253 is recorded already, so it is skipped"
  assert_equal "$(cat "$RECORD")" "$before"
  # A recorded job's log is not read again.
  assert_equal "$(stub_calls gh | jq -r '.[3]')" --json
}

@test "import refuses on a fenced machine, writes nothing when gh fails, and its malformed command lines are exit 2" {
  gh_runs
  run_bin -2 team-drill import
  assert_equal "$output" "team-drill: import needs one run id; usage: team-drill record <drill> --verdict pass|fail [--detail <text>] | import <run id> | status [--json]"
  run_bin -2 team-drill import 4254 4255
  assert_contains "$output" "team-drill: import needs one run id"
  run_bin -2 team-drill import https://github.com/owner/agent-team/actions/runs/4254
  assert_equal "$output" "team-drill: a run id is a number, not 'https://github.com/owner/agent-team/actions/runs/4254'"
  assert_equal "$(stub_calls gh)" ""
  # A run gh cannot read, and a job log it cannot read.
  run_bin -1 team-drill import 4254
  assert_equal "$output" "team-drill: gh run view 4254 failed: cat: $STUB_FIXTURES/run-4254.json: No such file or directory"
  run_json 4254 completed Bootstrap bootstrap-macos=success bootstrap-arch=success
  job_log 904254 bootstrap-macos "$(drill_record ci-macos pass)"
  run_bin -1 team-drill import 4254
  assert_equal "$output" "team-drill: gh could not read the log of run 4254's job bootstrap-arch: cat: $STUB_FIXTURES/log-914254: No such file or directory"
  [[ ! -e $RECORD ]]
  mkdir -p "$HOME/.local/state/agent-team"
  echo '{"since": "2026-10-22T14:00:00Z", "holder": "laptop", "epoch": 2}' >"$HOME/.local/state/agent-team/fenced"
  : >"$STUB_CALLS/gh.log"
  run_bin -1 team-drill import 4254
  assert_equal "$output" "team-drill: home-pc is fenced since 2026-10-22T14:00:00Z (holder seen laptop, epoch 2): a fenced machine records no drill"
  assert_equal "$(stub_calls gh)" ""
  [[ ! -e $RECORD ]]
}
