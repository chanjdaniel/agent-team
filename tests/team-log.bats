#!/usr/bin/env bats
# team-log: recording a hand-written event against the ledger contract, and checking a ledger.

load helpers/common

setup() {
  sandbox
  CONTRACT=$REPO_ROOT/bin/lib/ledger-contract.json
  STRICT_FROM=$(jq -r .strict_from "$CONTRACT")
}

# The ledger's lines without their ts, one per line.
ledger_without_ts() {
  jq -c 'del(.ts)' "$TEAM_HOME/ledger.jsonl"
}

# A Discord message id sent a minute from now: soon
soon() {
  echo $(((($(date -u +%s) + 60 - 1420070400) * 1000) << 22))
}

assert_ledger_empty() {
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" ""
}

# One project of the registry, at ~/projects/<name>, as TOML: plan_project <name> <merge_with_plan> [<repo>]
plan_project() {
  cat <<TOML
[$1]
repo = "${3:-owner/$1}"
path = "projects/$1"
base = "dev"
delivery = "direct-pr"
merge_method = "merge"
required_checks = []
merge_with_plan = $2
task_dir = ".scratch/task"
docs = []
toolkits = []
pool = { provider = "git", slots = ["slots/$1/1"] }
TOML
}

# A registry of proj, which opts in to a plan-time merge approval, conv, which does not, and the
# projects given as more TOML: plan_registry [<TOML>]
plan_registry() {
  {
    plan_project proj true
    echo
    plan_project conv false
    [[ -z ${1:-} ]] || printf '\n%s\n' "$1"
  } >"$TEAM_HOME/projects.toml"
}

# A project of the task, as team-open logs it: opened <task> <project> [worktree-added]
opened() {
  jq -cn --arg task "$1" --arg project "$2" --arg event "${3:-opened}" \
    '{ts: (now | todate), task: $task, event: $event, project: $project, branch: "feat/\($task)-x", base: "dev",
      base_sha: "0123456", worktree: "/w/\($project)"}
     + if $event == "opened" then {path: "feature", type: "feat", title: "X"} else {} end' >>"$TEAM_HOME/ledger.jsonl"
}

# The ledger's events, one per line.
ledger_events() {
  jq -r .event "$TEAM_HOME/ledger.jsonl"
}

# --from-message: a worker's message, whole.

HEAD_A=a1b2c3d4e5f60718293a4b5c6d7e8f9012345678
HEAD_B=0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c
URL=https://github.com/owner/proj/pull/12

# T7 in proj (registry proj and conv), on feat/T7-x.
open_t7() {
  plan_registry
  opened T7 proj
}

# A launch of the task, as team-worker logs it: launched <task> <role> <session> [<brief>]
launched() {
  jq -cn --arg task "$1" --arg role "$2" --arg session "$3" --arg brief "${4:-}" \
    '{ts: (now | todate), task: $task, event: "launch", role: $role, session: $session, worktree: "/w/proj",
      toolkits: [], project: "proj", branch: "feat/\($task)-x", machine: "m"}
     + if $brief == "" then {} else {brief: $brief} end' >>"$TEAM_HOME/ledger.jsonl"
}

# A brief's record, as team-brief writes it beside the brief: brief_record <task> <name> <values JSON>
brief_record() {
  mkdir -p "$TEAM_HOME/tasks/$1"
  jq -cn --argjson values "$3" '{template: "reviewer", project: "proj", values: $values}' >"$TEAM_HOME/tasks/$1/$2.json"
}

# GitHub's PR, read by gh pr view <n> --repo <repo> --json headRefOid,headRefName: on_github <url> <head> <branch>
on_github() {
  [[ $1 =~ ^https://github\.com/([^/]+)/([^/]+)/pull/([0-9]+)$ ]]
  jq -cn --arg head "$2" --arg branch "$3" '{headRefOid: $head, headRefName: $branch}' \
    >"$STUB_FIXTURES/github-${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]}"
  stub_script gh <<'SH'
[[ $1 == pr && $2 == view && $4 == --repo && $6 == --json ]] || { echo "unexpected gh $*" >&2; exit 1; }
answer=$STUB_FIXTURES/github-${5/\//-}-$3
[[ -f $answer ]] || { echo "GraphQL: Could not resolve to a PullRequest with the number of $3." >&2; exit 1; }
cat "$answer"
SH
}

# The ledger's lines after its first <n>, without their ts: logged_after <n>
logged_after() {
  tail -n +"$(($1 + 1))" "$TEAM_HOME/ledger.jsonl" | jq -c 'del(.ts)'
}

# Logs the message and checks the events it added, one compact JSON object per line without ts:
# logs_events <expected> <team-log arguments after the task>...
logs_events() {
  local expected=$1 before
  shift
  before=$(wc -l <"$TEAM_HOME/ledger.jsonl")
  run_bin -0 team-log T7 "$@"
  assert_equal "$(logged_after "$before")" "$expected"
}

# Refuses the message with the given output, logging nothing: refuses_message <output> <team-log arguments after the task>...
refuses_message() {
  local expected=$1 before
  shift
  before=$(cat "$TEAM_HOME/ledger.jsonl")
  run_bin -1 team-log T7 "$@"
  assert_equal "$output" "$expected"
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" "$before"
}

@test "the contract lists every kind of the spec's table with its writer and required fields" {
  local expected actual
  expected=$(
    cat <<'TABLE'
opened team-open project path type title branch base base_sha worktree
worktree-added team-open project branch base base_sha worktree
thread team-thread discord_thread
interview-thread team-thread discord_thread
launch team-worker role session worktree toolkits
worktree-returned team-close project worktree
closed team-close archive returned kept
merged team-merge pr merge head by
history-rewritten team-clean-messages branch old_head head
done team-log role session
ticket-done team-log ticket commits
question team-log,team-ask role text
asked team-log,team-ask id text
answered team-log,team-answer id answer
plan-approved team-log by
paused team-log reason
blocked team-log reason
denied team-log role what why
held team-log reason
waiting team-log,team-ask on reason
resumed team-log,team-answer
pr team-log url head
review team-log verdict head
gate-run team-log run head outcome
merge-approved team-log url discord_message
merge-preapproved team-log project ask discord_message scope
merge-preapproval-withdrawn team-log project discord_message
branch-renamed team-log project branch
failed team-log reason
retro-schedule team-log every_hours discord_message
stowed team-stow machine worktrees roles
worktree-moved team-open project branch from worktree machine
injection team-log role source text
rehome-failed team-resume project branch machine reason
rehomed team-open project branch worktree machine
TABLE
  )
  actual=$(jq -r '.kinds | to_entries[] | [.key, ([.value.writer] | flatten | join(",")), (.value.required | keys_unsorted[])] | join(" ")' "$CONTRACT")
  assert_equal "$actual" "$expected"
  assert_equal "$(jq -c '.kinds.launch.optional' "$CONTRACT")" '{"project":"string","branch":"string","machine":"string","model":"string","request":"string","brief":"string"}'
  assert_equal "$(jq -c '.kinds.review.required.verdict' "$CONTRACT")" '["pass","findings"]'
  assert_equal "$(jq -c '.kinds.answered.optional' "$CONTRACT")" '{"discord_message":"id"}'
  assert_equal "$(jq -c '[.kinds[] | (.required, .optional // {}) | to_entries[] | select(.key | startswith("discord_")) | .value] | unique' "$CONTRACT")" '["id"]'
  assert_equal "$(jq -c '[.kinds.waiting, .kinds.blocked, .kinds.paused, .kinds.held | .optional.since]' "$CONTRACT")" '["string","string","string","string"]'
  assert_equal "$(jq -c '[.kinds.closed.required[]]' "$CONTRACT")" '["array","array","array"]'
  assert_equal "$(jq -c '.kinds["merge-preapproved"].required' "$CONTRACT")" '{"project":"string","ask":"string","discord_message":"id","scope":"array"}'
  assert_equal "$(jq -c '.kinds.review.optional' "$CONTRACT")" '{"agent_review":"string","sent_back":"numbers","findings":"object","before":"numbers","guarded":"array"}'
  assert_equal "$(jq -c '.kinds.merged.optional.approval' "$CONTRACT")" '["head","plan"]'
  [[ $STRICT_FROM =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "--help prints the header and the contract as a table" {
  run_bin -0 team-log --help
  assert_equal "${lines[0]}" "$(sed -n '2s/^# //p' "$REPO_ROOT/bin/team-log")"
  assert_contains "$output" "Ledger contract, strict from $STRICT_FROM"
  # The forms a list and an object take, the whole numbers' type and the one-time conversion.
  assert_contains "$output" "Usage: team-log T<n> <event> [key=value]...
       team-log T<n> --from-message '<message>' [--from <session>] [--sent-back <list>] [--print]
       team-log --check [<file>]
       team-log --fix-sent-back [<file>]"
  grep -Eq 'a comma list as a worker.s message writes it \(commits=a0017cce,9e0e3990' <<<"$output"
  grep -Eq 'none is the empty list' <<<"$output"
  grep -Eq 'key:value pairs .*findings=blocking:0,correctness:1' <<<"$output"
  grep -Eq 'numbers \(a list of whole numbers\)' <<<"$output"
  grep -Eq '^--fix-sent-back .*under the ledger.s lock' <<<"$output"
  local kind
  for kind in $(jq -r '.kinds | keys_unsorted[]' "$CONTRACT"); do
    grep -Eq "^  $kind +[a-z-]+(, [a-z-]+)* " <<<"$output" || {
      echo "no row for $kind" >&2
      return 1
    }
  done
  grep -Eq '^  opened +team-open +project, path, type, title, branch, base, base_sha, worktree; optional story  \(story is the backlog story .*team-merge marks done\)$' <<<"$output"
  grep -Eq '^  review +team-log +verdict \(pass\|findings\), head; optional agent_review, sent_back \(list of whole numbers\), findings \(object\), before \(list of whole numbers\), guarded \(list\)  \(verdict: findings whenever sent_back names a finding, whatever the reviewer.s word, .*sent_back: the numbers of the findings sent back .*findings: the count of each kind.*before: the numbers of the plain notes .*guarded: the guarded areas.*\)$' <<<"$output"
  grep -Eq '^  merge-preapproved +team-log +project, ask, discord_message \(id\), scope \(list\)  \(Daniel.s plan-time word .*\)$' <<<"$output"
  grep -Eq '^  merge-preapproval-withdrawn +team-log +project, discord_message \(id\)  \(.*withdr.*\)$' <<<"$output"
  grep -Eq '^  merged +team-merge +pr \(number\), merge, head, by; optional .*approval \(head\|plan\)  \(approval: .*\)$' <<<"$output"
  grep -Eq '^  gate-run +team-log +run, head, outcome \(pushed\|red\|aborted\|stopped-green\); optional cause \(review\|notes\|gate-finding\|load\|tooling\|base-merge\|other\), minutes \(object\)  \(.*\)$' <<<"$output"
  grep -Eq '^  closed +team-close +archive \(list\), returned \(list\), kept \(list\)  \(.*legacy.*\)$' <<<"$output"
  grep -Eq '^  merge-approved +team-log +url, discord_message \(id\); optional head  \(.*team-log requires head of every new line.*\)$' <<<"$output"
  grep -Eq '^  launch +team-worker +role, session, worktree, toolkits \(list\); optional project, branch, machine, model, request, brief  \(request is the link to Daniel.s Discord message, on an ops launch; model is the --model the session launched on, .*\)$' <<<"$output"
  grep -Eq '^  answered +team-log, team-answer +id, answer; optional discord_message \(id\)  \(Daniel.s answer to the asked of its id; .*never logged twice for one ask\)$' <<<"$output"
  grep -Eq '^  waiting +team-log, team-ask +on, reason; optional since  \(.*\)$' <<<"$output"
  grep -Eq '^  resumed +team-log, team-answer +- +\(clears held, blocked, paused and waiting\)$' <<<"$output"
  grep -Eq '^  blocked +team-log +reason; optional since  \(.*since: when the park began, when it is logged after the fact\)$' <<<"$output"
  grep -Eq '^  denied +team-log +role, what, why; optional session  \(a denial the worker went past .*parks nothing and clears nothing.*a denial that stops the work is a blocked\)$' <<<"$output"
  grep -Eq '^  retro-schedule +team-log +every_hours \(number\), discord_message \(id\)  \(.*every_hours 0 stops.*\)$' <<<"$output"
  grep -Eq '^  injection +team-log +role, source, text  \(.*never the personal details.*\)$' <<<"$output"
  grep -Eq '^  stowed +team-stow +machine, worktrees \(list\), roles \(list\); optional sessions \(list\), cause \(level\|handoff\)  \(one per task team-stow stows, every open task at a handoff .*unfinished_roles.*\)$' <<<"$output"
  grep -Eq '^  rehome-failed +team-resume +project, branch, machine, reason  \(.*stands until a later opened, worktree-added, worktree-moved, rehomed or worktree-returned.*\)$' <<<"$output"
  assert_equal "$(stub_calls curl)$(stub_calls gh)" ""
}

@test "an event is appended as one line with ts now, task and event" {
  local before after
  before=$(date -u +%FT%TZ)
  run_bin -0 team-log T14 pr url=https://github.com/chanjdaniel/agent-team/pull/5 head=a1b2c3d
  after=$(date -u +%FT%TZ)
  assert_equal "$output" ""
  assert_equal "$(wc -l <"$TEAM_HOME/ledger.jsonl")" "1"
  assert_equal "$(ledger_without_ts)" \
    '{"task":"T14","event":"pr","url":"https://github.com/chanjdaniel/agent-team/pull/5","head":"a1b2c3d"}'
  local ts
  ts=$(jq -r .ts "$TEAM_HOME/ledger.jsonl")
  [[ $ts =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
  [[ ! $ts < $before && ! $ts > $after ]]

  run_bin -0 team-log T14 resumed
  assert_equal "$(wc -l <"$TEAM_HOME/ledger.jsonl")" "2"
  assert_equal "$(tail -n 1 "$TEAM_HOME/ledger.jsonl" | jq -c 'del(.ts)')" '{"task":"T14","event":"resumed"}'
}

@test "values that parse as JSON are stored as JSON, others as strings" {
  run_bin -0 team-log T14 ticket-done ticket=03 'commits=["a1b2c3d", "e4f5a6b"]' count=3 ok=true \
    'extra={"a":1}' 'quoted="7"' 'note=two words, [not a list' nan=nan nothing=null
  assert_equal "$(ledger_without_ts)" \
    '{"task":"T14","event":"ticket-done","ticket":"03","commits":["a1b2c3d","e4f5a6b"],"count":3,"ok":true,"extra":{"a":1},"quoted":"7","note":"two words, [not a list","nan":"nan","nothing":"null"}'
}

@test "a review names the notes sent back before the merge as a list, which a non-list cannot be" {
  run_bin -0 team-log T14 review verdict=findings head=a1b2c3d 'sent_back=[2, 4]'
  run_bin -0 team-log T14 review verdict=pass head=e4f5a6b
  assert_equal "$(ledger_without_ts)" "$(
    cat <<'LINES'
{"task":"T14","event":"review","verdict":"findings","head":"a1b2c3d","sent_back":[2,4]}
{"task":"T14","event":"review","verdict":"pass","head":"e4f5a6b"}
LINES
  )"
  run_bin -1 team-log T14 review verdict=pass head=a1b2c3d 'sent_back={"2":1}'
  assert_contains "$output" "sent_back must be a list of whole numbers, got an object"
  run_bin -1 team-log T14 review verdict=pass head=a1b2c3d 'sent_back=note 2'
  assert_equal "$output" "team-log: sent_back: note 2 is not a whole number"
  assert_equal "$(wc -l <"$TEAM_HOME/ledger.jsonl")" "2"
}

@test "a list field takes a comma list, each item trimmed, none for the empty list, and refuses an empty item" {
  run_bin -0 team-log T14 ticket-done ticket=03 commits=a0017cce,9e0e3990
  run_bin -0 team-log T14 ticket-done ticket=04 'commits= a0017cce , 9e0e3990 '
  run_bin -0 team-log T14 ticket-done ticket=05 commits=1234567
  run_bin -0 team-log T14 review verdict=findings head=a1b2c3d sent_back=5,6 guarded=ci,settings before=none
  run_bin -0 team-log T14 review verdict=pass head=e4f5a6b sent_back=none guarded=none
  assert_equal "$(ledger_without_ts)" "$(
    cat <<'LINES'
{"task":"T14","event":"ticket-done","ticket":"03","commits":["a0017cce","9e0e3990"]}
{"task":"T14","event":"ticket-done","ticket":"04","commits":["a0017cce","9e0e3990"]}
{"task":"T14","event":"ticket-done","ticket":"05","commits":["1234567"]}
{"task":"T14","event":"review","verdict":"findings","head":"a1b2c3d","sent_back":[5,6],"guarded":["ci","settings"],"before":[]}
{"task":"T14","event":"review","verdict":"pass","head":"e4f5a6b","sent_back":[],"guarded":[]}
LINES
  )"
  run_bin -0 team-log --check

  local value
  for value in 5,,6 ,5 '5,' '5, ,6'; do
    run_bin -1 team-log T14 review verdict=findings head=a1b2c3d "sent_back=$value"
    assert_equal "$output" "team-log: sent_back has an empty item in '$value'"
  done
  run_bin -1 team-log T14 ticket-done ticket=06 commits=a0017cce,,9e0e3990
  assert_equal "$output" "team-log: commits has an empty item in 'a0017cce,,9e0e3990'"
  run_bin -1 team-log T14 ticket-done ticket=06 'commits=[a0017cce]'
  assert_equal "$output" "team-log: commits starts as JSON, but is not JSON: [a0017cce]"
  assert_equal "$(wc -l <"$TEAM_HOME/ledger.jsonl")" "5"
}

@test "an object field takes key:value pairs, logged as the same object as its JSON form, and the finding kinds hold for both" {
  local kinds='blocking:0,correctness:1,security:0,real-data:0,note-change:2,note-before:1'
  run_bin -0 team-log T14 review verdict=pass head=a1b2c3d "findings=$kinds" before=4 guarded=none
  run_bin -0 team-log T14 review verdict=pass head=a1b2c3d \
    'findings={"blocking": 0, "correctness": 1, "security": 0, "real-data": 0, "note-change": 2, "note-before": 1}' 'before=[4]' 'guarded=[]'
  assert_equal "$(sed -n 1p "$TEAM_HOME/ledger.jsonl" | jq -c 'del(.ts)')" \
    '{"task":"T14","event":"review","verdict":"pass","head":"a1b2c3d","findings":{"blocking":0,"correctness":1,"security":0,"real-data":0,"note-change":2,"note-before":1},"before":[4],"guarded":[]}'
  assert_equal "$(sed -n 2p "$TEAM_HOME/ledger.jsonl" | jq -c 'del(.ts)')" "$(sed -n 1p "$TEAM_HOME/ledger.jsonl" | jq -c 'del(.ts)')"
  # Each pair trimmed, a value a number when it reads as one.
  run_bin -0 team-log T14 gate-run run=01M5Q9GR head=a1b2c3d outcome=pushed 'minutes=review:3.0, test : 49.9,ci:9'
  assert_equal "$(tail -n 1 "$TEAM_HOME/ledger.jsonl" | jq -c .minutes)" '{"review":3.0,"test":49.9,"ci":9}'
  run_bin -0 team-log --check

  # The finding kinds refuse the pairs as they refuse the JSON.
  local pairs json
  run_bin -1 team-log T14 review verdict=pass head=a1b2c3d 'findings=blocking:0,correctness:-1,security:x,note-before:0,note:2'
  pairs=$output
  run_bin -1 team-log T14 review verdict=pass head=a1b2c3d 'findings={"blocking":0,"correctness":-1,"security":"x","note-before":0,"note":2}'
  json=$output
  assert_equal "$pairs" "$json"
  assert_equal "$pairs" "team-log: findings holds the count of each finding kind, exactly blocking, correctness, security, real-data, note-change and note-before, each a whole number:
  correctness: -1 is not a whole number
  security: \"x\" is not a whole number
  real-data: missing
  note-change: missing
  note: not a finding kind"
  # A malformed pair is refused, naming it.
  run_bin -1 team-log T14 review verdict=pass head=a1b2c3d findings=3
  assert_equal "$output" "team-log: findings: 3 is not a key:value pair"
  run_bin -1 team-log T14 review verdict=pass head=a1b2c3d 'findings=blocking:0,:1,correctness:'
  assert_equal "$output" "team-log: findings: :1 is not a key:value pair; findings: correctness: is not a key:value pair"
  run_bin -1 team-log T14 review verdict=pass head=a1b2c3d findings=blocking:0,,correctness:1
  assert_equal "$output" "team-log: findings has an empty item in 'blocking:0,,correctness:1'"
  run_bin -1 team-log T14 review verdict=pass head=a1b2c3d findings=blocking:0,blocking:1
  assert_equal "$output" "team-log: findings: blocking is given twice"
  run_bin -1 team-log T14 gate-run run=01M5Q9GR head=a1b2c3d outcome=pushed 'minutes={review: 3}'
  assert_equal "$output" "team-log: minutes starts as JSON, but is not JSON: {review: 3}"
  assert_equal "$(wc -l <"$TEAM_HOME/ledger.jsonl")" "3"
}

@test "sent_back is stored as whole numbers from a comma list or a JSON list, and anything else is refused naming it" {
  run_bin -0 team-log T14 review verdict=findings head=a1b2c3d 'sent_back=["5",6]'
  run_bin -0 team-log T14 review verdict=findings head=a1b2c3d sent_back=5,6
  run_bin -0 team-log T14 review verdict=findings head=a1b2c3d sent_back=07
  assert_equal "$(jq -c .sent_back "$TEAM_HOME/ledger.jsonl")" '[5,6]
[5,6]
[7]'
  run_bin -0 team-log --check

  run_bin -1 team-log T14 review verdict=findings head=a1b2c3d sent_back=5a
  assert_equal "$output" "team-log: sent_back: 5a is not a whole number"
  run_bin -1 team-log T14 review verdict=findings head=a1b2c3d sent_back=5,5a,-1
  assert_equal "$output" "team-log: sent_back: 5a is not a whole number; sent_back: -1 is not a whole number"
  run_bin -1 team-log T14 review verdict=findings head=a1b2c3d 'sent_back=["5a", 1.5, true, null]'
  assert_equal "$output" "team-log: sent_back: 5a is not a whole number; sent_back: 1.5 is not a whole number; sent_back: true is not a whole number; sent_back: null is not a whole number"
  assert_equal "$(wc -l <"$TEAM_HOME/ledger.jsonl")" "3"
}

@test "a gate run is logged with its run, head and outcome, the cause of a re-run and its minutes per step" {
  run_bin -0 team-log T14 gate-run run=01M5Q9GR head=a1b2c3d outcome=pushed \
    'minutes={"review": 3.0, "test": 49.9, "document": 0.6, "push": 0.4, "ci": 9.0}'
  run_bin -0 team-log T14 gate-run run=01M5QDHG head=e4f5a6b outcome=stopped-green cause=notes
  run_bin -0 team-log T14 gate-run run=01M5REA0 head=e4f5a6b outcome=red cause=load
  assert_equal "$(ledger_without_ts)" "$(
    cat <<'LINES'
{"task":"T14","event":"gate-run","run":"01M5Q9GR","head":"a1b2c3d","outcome":"pushed","minutes":{"review":3.0,"test":49.9,"document":0.6,"push":0.4,"ci":9.0}}
{"task":"T14","event":"gate-run","run":"01M5QDHG","head":"e4f5a6b","outcome":"stopped-green","cause":"notes"}
{"task":"T14","event":"gate-run","run":"01M5REA0","head":"e4f5a6b","outcome":"red","cause":"load"}
LINES
  )"
  run_bin -0 team-log --check
}

@test "a gate run with an unknown outcome or cause, or minutes that are not an object, is refused" {
  run_bin -1 team-log T14 gate-run run=01M5Q9GR head=a1b2c3d outcome=green
  assert_contains "$output" "outcome must be one of pushed, red, aborted, stopped-green"
  run_bin -1 team-log T14 gate-run run=01M5Q9GR head=a1b2c3d outcome=red cause=flaky
  assert_contains "$output" "cause must be one of review, notes, gate-finding, load, tooling, base-merge, other"
  run_bin -1 team-log T14 gate-run run=01M5Q9GR head=a1b2c3d outcome=red 'minutes=[44]'
  assert_contains "$output" "minutes must be an object, got a list"
  run_bin -1 team-log T14 gate-run head=a1b2c3d outcome=red
  assert_contains "$output" "gate-run needs run"
  assert_ledger_empty
}

@test "a field the contract types as a string stays a string even when it looks like JSON" {
  run_bin -0 team-log T14 ticket-done ticket=12 'commits=["1234567"]'
  run_bin -0 team-log T14 pr url=https://github.com/chanjdaniel/agent-team/pull/5 head=1234567 note=true
  run_bin -0 team-log T14 merge-approved url=https://github.com/chanjdaniel/agent-team/pull/5 discord_message=1563000000000000123456789 head=1234567
  assert_equal "$(ledger_without_ts)" "$(
    cat <<'LINES'
{"task":"T14","event":"ticket-done","ticket":"12","commits":["1234567"]}
{"task":"T14","event":"pr","url":"https://github.com/chanjdaniel/agent-team/pull/5","head":"1234567","note":"true"}
{"task":"T14","event":"merge-approved","url":"https://github.com/chanjdaniel/agent-team/pull/5","discord_message":"1563000000000000123456789","head":"1234567"}
LINES
  )"
}

@test "a Discord id is stored as a string, declared or not, and so is any whole number of 16 digits or more" {
  run_bin -0 team-log T14 asked id=q1 text=Which? discord_message=1564584780744491089
  run_bin -0 team-log T14 resumed discord_channel=1562486564871995482 ref=1565336870932582522 count=42 big=999999999999999
  assert_equal "$(ledger_without_ts)" "$(
    cat <<'LINES'
{"task":"T14","event":"asked","id":"q1","text":"Which?","discord_message":"1564584780744491089"}
{"task":"T14","event":"resumed","discord_channel":"1562486564871995482","ref":"1565336870932582522","count":42,"big":999999999999999}
LINES
  )"
  # A declared id is a string of digits: anything else is refused.
  run_bin -1 team-log T14 answered id=q1 answer=Five discord_message=m1563
  assert_contains "$output" "discord_message must be a Discord id, a string of digits, got a string that is not one"
  assert_equal "$(wc -l <"$TEAM_HOME/ledger.jsonl")" "2"
}

@test "--check accepts a Discord id written as a whole number, as dev's team-log wrote two, and nothing else in its place" {
  cat >"$TEAM_HOME/ledger.jsonl" <<LEDGER
{"ts":"$STRICT_FROM","task":"T14","event":"asked","id":"q1","text":"Which?","discord_message":1564584780744491089}
{"ts":"$STRICT_FROM","task":"T14","event":"answered","id":"q1","answer":"Five","discord_message":1565336870932582522}
{"ts":"$STRICT_FROM","task":"T14","event":"answered","id":"q1","answer":"Five","discord_message":"1565336870932582523"}
{"ts":"$STRICT_FROM","task":"T14","event":"thread","discord_thread":1563}
{"ts":"$STRICT_FROM","task":"T14","event":"answered","id":"q1","answer":"Five","discord_message":1.5}
{"ts":"$STRICT_FROM","task":"T14","event":"answered","id":"q1","answer":"Five","discord_message":-1563}
{"ts":"$STRICT_FROM","task":"T14","event":"answered","id":"q1","answer":"Five","discord_message":"m1563"}
LEDGER
  run_bin -1 team-log --check
  assert_equal "$output" "$TEAM_HOME/ledger.jsonl:5: discord_message must be a Discord id, a string of digits, got a number that is not one
$TEAM_HOME/ledger.jsonl:6: discord_message must be a Discord id, a string of digits, got a number that is not one
$TEAM_HOME/ledger.jsonl:7: discord_message must be a Discord id, a string of digits, got a string that is not one
$TEAM_HOME/ledger.jsonl: 3 of 7 lines break the ledger contract"
  # The number's digits are the id: an answer read from that message again is a repeat.
  run_bin -1 team-log T14 answered id=q1 answer=Five discord_message=1565336870932582522
  assert_contains "$output" "already logged answered id=q1 from Discord message 1565336870932582522"
}

@test "every kind team-log writes is appended with its required fields and a note" {
  # merge-preapproved names a project of the task that opts in, and an ask it logged before;
  # branch-renamed a new branch of it that names the task.
  plan_registry
  opened T14 proj
  local kind args count=0
  while IFS= read -r kind; do
    # A head is a sha, since merge-approved's must be one a pr event logged, which team-log adds.
    mapfile -t args < <(jq -r --arg k "$kind" --arg soon "$(soon)" '(.kinds[$k].required | to_entries[]
      | "\(.key)=\(if .key == "head" then "a1b2c3d4" elif .key == "project" then "proj" elif .key == "ask" then "x y"
          elif .key == "scope" then "[\"src/\"]" elif .key == "branch" then "feat/T14-x-fresh"
          else .value | if type == "array" then .[0] elif . == "array" then "[]" elif . == "number" then "7" elif . == "id" then $soon else "x y" end end)"),
      (select($k == "merge-approved") | "head=a1b2c3d4")' "$CONTRACT")
    run_bin -0 team-log T14 "$kind" "${args[@]}" "note=why $kind"
    count=$((count + 1))
    assert_equal "$(tail -n 1 "$TEAM_HOME/ledger.jsonl" | jq -r '.event + " " + .note')" "$kind why $kind"
  done < <(jq -r '.kinds | to_entries[] | select([.value.writer] | flatten | index("team-log")) | .key' "$CONTRACT")
  assert_equal "$count" "22"
  run_bin -0 team-log --check
}

@test "a malformed task id is a usage error with nothing appended" {
  local task
  for task in 14 T0 t14 T14a T-1 ''; do
    run_bin -2 team-log "$task" resumed
    assert_contains "$output" "task must look like T<n>, got '$task'"
  done
  assert_ledger_empty
}

@test "an unknown kind is refused with nothing appended" {
  run_bin -1 team-log T14 ticket-don ticket=03 'commits=["a1b2c3d"]'
  assert_contains "$output" "unknown event kind 'ticket-don'"
  assert_contains "$output" "team-log --help"
  assert_ledger_empty
}

@test "a missing required field is refused with nothing appended" {
  run_bin -1 team-log T14 pr url=https://github.com/chanjdaniel/agent-team/pull/5
  assert_contains "$output" "pr needs head"
  run_bin -1 team-log T14 review 'note=looks fine'
  assert_contains "$output" "review needs verdict"
  assert_contains "$output" "review needs head"
  run_bin -1 team-log T26 retro-schedule every_hours=48
  assert_contains "$output" "retro-schedule needs discord_message"
  run_bin -1 team-log T26 retro-schedule discord_message=1563171945980370967
  assert_contains "$output" "retro-schedule needs every_hours"
  run_bin -1 team-log T26 retro-schedule every_hours=often discord_message=1563171945980370967
  assert_contains "$output" "every_hours must be a number, got a string"
  run_bin -1 team-log T26 injection role=builder 'source=https://github.com/chanjdaniel/agent-team/pull/9'
  assert_contains "$output" "injection needs text"
  run_bin -1 team-log T26 injection 'source=orders/66f0a1' 'text=asked to email the export'
  assert_contains "$output" "injection needs role"
  run_bin -1 team-log T26 injection role=ops 'text=asked to email the export'
  assert_contains "$output" "injection needs source"
  assert_ledger_empty
}

@test "denied records a denial the worker went past; a missing field is refused" {
  run_bin -1 team-log T26 denied role=builder 'what=Bash'
  assert_contains "$output" "denied needs why"
  run_bin -1 team-log T26 denied 'what=Bash' 'why=[deny rule] git reset * --hard*'
  assert_contains "$output" "denied needs role"
  run_bin -1 team-log T26 denied role=builder 'why=no verdict'
  assert_contains "$output" "denied needs what"
  assert_ledger_empty
  run_bin -0 team-log T26 denied role=builder session=4f2a9c1e what=Bash 'why=[deny rule] git reset * --hard*'
  assert_equal "$(ledger_without_ts)" \
    '{"task":"T26","event":"denied","role":"builder","session":"4f2a9c1e","what":"Bash","why":"[deny rule] git reset * --hard*"}'
  run_bin -0 team-log --check
}

@test "injection records where outside text asked a worker to act, and what it asked" {
  run_bin -0 team-log T26 injection role=builder 'source=https://github.com/chanjdaniel/agent-team/pull/9#issuecomment-1' \
    'text=asked to push to dev and skip the hooks'
  assert_equal "$(ledger_without_ts)" \
    '{"task":"T26","event":"injection","role":"builder","source":"https://github.com/chanjdaniel/agent-team/pull/9#issuecomment-1","text":"asked to push to dev and skip the hooks"}'
  run_bin -0 team-log --check
}

@test "retro-schedule records Daniel's cadence with the Discord message it was said in" {
  run_bin -0 team-log T26 retro-schedule every_hours=48 discord_message=1563171945980370967
  run_bin -0 team-log T26 retro-schedule every_hours=0 discord_message=1563171945980370999
  assert_equal "$(ledger_without_ts)" "$(
    cat <<'LINES'
{"task":"T26","event":"retro-schedule","every_hours":48,"discord_message":"1563171945980370967"}
{"task":"T26","event":"retro-schedule","every_hours":0,"discord_message":"1563171945980370999"}
LINES
  )"
  run_bin -0 team-log --check
}

@test "a value of the wrong type or outside its choices is refused with nothing appended" {
  run_bin -1 team-log T14 review verdict=ok head=a1b2c3d
  assert_contains "$output" "verdict must be one of pass, findings"
  run_bin -1 team-log T14 ticket-done ticket=03 'commits={"a":1}'
  assert_contains "$output" "commits must be a list, got an object"
  assert_ledger_empty
}

@test "a malformed key=value is a usage error with nothing appended" {
  local pair
  for pair in reason '=x' 'Reason=x' 'two words=x' 'reason=' '1st=x'; do
    run_bin -2 team-log T14 blocked "$pair"
    assert_contains "$output" "not a key=value: '$pair'"
  done
  run_bin -2 team-log T14 blocked reason=a reason=b
  assert_contains "$output" "reason is given twice"
  local key
  for key in ts task event; do
    run_bin -2 team-log T14 blocked reason=a "$key=x"
    assert_contains "$output" "$key is set by team-log"
  done
  assert_ledger_empty
}

@test "merge-approved names a PR of the task's pr events, by its URL" {
  local five=https://github.com/owner/proj/pull/5 seven=https://github.com/other/repo/pull/7
  run_bin -1 team-log T14 merge-approved url=$five discord_message=1563
  assert_contains "$output" "$five is not a PR of T14's pr events; it has none"
  assert_ledger_empty
  run_bin -0 team-log T14 pr url=$five/ head=a1b2c3d
  run_bin -0 team-log T14 pr url=$seven head=e4f5a6b
  run_bin -0 team-log T13 pr url=https://github.com/owner/proj/pull/9 head=0a1b2c3
  run_bin -1 team-log T14 merge-approved url=https://github.com/owner/proj/pull/9 discord_message=1563
  assert_contains "$output" "https://github.com/owner/proj/pull/9 is not a PR of T14's pr events:"
  assert_contains "$output" "  $five/"
  assert_contains "$output" "  $seven"
  run_bin -1 team-log T14 merge-approved pr=5 discord_message=1563
  assert_contains "$output" "merge-approved needs url"
  assert_equal "$(wc -l <"$TEAM_HOME/ledger.jsonl")" "3"
  run_bin -0 team-log T14 merge-approved url=$five discord_message="$(soon)" head=a1b2c3d4e5f60718293a4b5c6d7e8f9012345678
  run_bin -0 team-log T14 merge-approved url=$seven/ discord_message="$(soon)" head=e4f5a6b
  assert_equal "$(tail -n 2 "$TEAM_HOME/ledger.jsonl" | jq -r .url)" "$five"$'\n'"$seven/"
}

@test "merge-approved names the head Daniel was asked on, one a pr event of its PR or a review since logged" {
  local five=https://github.com/owner/proj/pull/5
  run_bin -0 team-log T14 pr url=$five head=a1b2c3d
  run_bin -0 team-log T14 pr url=$five head=0123456789abcdef0123456789abcdef01234567
  run_bin -0 team-log T14 pr url=https://github.com/owner/proj/pull/6 head=e4f5a6b
  run_bin -1 team-log T14 merge-approved url=$five discord_message=1563
  assert_contains "$output" "merge-approved needs head, the full sha of the PR's head Daniel was asked on"
  run_bin -1 team-log T14 merge-approved url=$five discord_message=1563 head=e4f5a6b7
  assert_equal "$output" "team-log: head e4f5a6b7 is not a head the pr events of $five, or the reviews since, logged:
  a1b2c3d
  0123456789abcdef0123456789abcdef01234567"
  run_bin -1 team-log T14 merge-approved url=$five discord_message=1563 head=a1b2c3
  assert_equal "$(wc -l <"$TEAM_HOME/ledger.jsonl")" "3"
  run_bin -0 team-log T14 merge-approved url=$five discord_message="$(soon)" head=A1B2C3D4E5F60718293A4B5C6D7E8F9012345678
  run_bin -0 team-log T14 merge-approved url=$five/ discord_message="$(soon)" head=0123456789abcdef0123456789abcdef01234567
  run_bin -0 team-log --check
}

@test "merge-approved may name a fix head a review logged after the PR's first pr event, with no pr event of its own" {
  local five=https://github.com/owner/proj/pull/5 fix=b2c3d4e5f60718293a4b5c6d7e8f901234567890
  # A review before the PR's first pr event logs no head of it.
  run_bin -0 team-log T14 review verdict=pass head=c3d4e5f
  run_bin -0 team-log T14 pr url=$five head=a1b2c3d
  run_bin -0 team-log T14 review verdict=findings head=a1b2c3d
  run_bin -0 team-log T14 review verdict=pass head=$fix
  run_bin -0 team-log T14 merge-approved url=$five discord_message="$(soon)" head=$fix
  run_bin -1 team-log T14 merge-approved url=$five discord_message="$(soon)" head=c3d4e5f
  assert_contains "$output" "team-log: head c3d4e5f is not a head the pr events of $five, or the reviews since, logged:
  a1b2c3d
  $fix"
}

@test "merge-approved's message must be sent no earlier than the first event that logged its head" {
  local five=https://github.com/owner/proj/pull/5 fix=b2c3d4e5f60718293a4b5c6d7e8f901234567890
  # 1562661774950400000 is 2026-10-22T03:00:00Z; the review of the fix is logged now, later.
  run_bin -0 team-log T14 pr url=$five head=a1b2c3d
  run_bin -0 team-log T14 review verdict=pass head=$fix
  local reviewed
  reviewed=$(tail -n 1 "$TEAM_HOME/ledger.jsonl" | jq -r .ts)
  run_bin -1 team-log T14 merge-approved url=$five discord_message=1562661774950400000 head=$fix
  assert_equal "$output" "team-log: Discord message 1562661774950400000 was sent at 2026-10-22T03:00:00Z, before the review event that first logged head $fix at $reviewed, so it is not Daniel's word on that head"
  assert_equal "$(wc -l <"$TEAM_HOME/ledger.jsonl")" "2"
}

@test "merge-preapproved records Daniel's plan-time word on a project of the task, with the ask it answers and the scope" {
  plan_registry
  opened T14 conv
  opened T14 proj worktree-added
  run_bin -0 team-log T14 asked id=plan 'text=Approve the plan, and its merge?'
  local message
  message=$(soon)
  run_bin -0 team-log T14 merge-preapproved project=proj ask=plan discord_message="$message" \
    'scope=["src/", "README.md", ".github/x/y.yml", "a/b-c_d.e"]'
  assert_equal "$output" ""
  assert_equal "$(tail -n 1 "$TEAM_HOME/ledger.jsonl" | jq -c 'del(.ts)')" \
    "{\"task\":\"T14\",\"event\":\"merge-preapproved\",\"project\":\"proj\",\"ask\":\"plan\",\"discord_message\":\"$message\",\"scope\":[\"src/\",\"README.md\",\".github/x/y.yml\",\"a/b-c_d.e\"]}"
  run_bin -0 team-log --check
}

@test "merge-preapproved is refused for a project that is not the task's, does not opt in now, or is the team's own" {
  plan_registry
  run_bin -0 team-log T14 asked id=plan 'text=Approve?'
  run_bin -1 team-log T14 merge-preapproved project=proj ask=plan discord_message="$(soon)" 'scope=["src/"]'
  assert_equal "$output" "team-log: proj is not a project of T14's opened or worktree-added events; it has none"
  opened T14 proj
  opened T14 conv worktree-added
  opened T15 other
  run_bin -1 team-log T14 merge-preapproved project=other ask=plan discord_message="$(soon)" 'scope=["src/"]'
  assert_equal "$output" "team-log: other is not a project of T14's opened or worktree-added events: proj, conv"
  run_bin -1 team-log T14 merge-preapproved project=conv ask=plan discord_message="$(soon)" 'scope=["src/"]'
  assert_equal "$output" "team-log: conv does not opt in to a plan-time merge approval: its merge_with_plan in projects.toml is false"
  assert_equal "$(ledger_events | grep -c merge-preapproved)" 0

  # agent-team by name, even when the registry says true (which team-project --check refuses).
  plan_registry "$(plan_project agent-team true)"
  opened T14 agent-team worktree-added
  run_bin -1 team-log T14 merge-preapproved project=agent-team ask=plan discord_message="$(soon)" 'scope=["src/"]'
  assert_equal "$output" "team-log: agent-team is the team's own project, whose PRs merge only on Daniel's word per head, never on a plan-time word"

  # By repo, which --check does not read, the key set to true; and by path, at the code checkout.
  export CODE_CHECKOUT
  CODE_CHECKOUT=$(make_repo tools dev)
  copy_bin "$CODE_CHECKOUT/bin"
  git -C "$CODE_CHECKOUT" remote set-url origin git@github.com:Owner/Tools.git
  plan_registry "$(plan_project mirror true owner/tools && echo && plan_project tools false owner/elsewhere)"
  opened T14 mirror worktree-added
  opened T14 tools worktree-added
  run_bin -1 team-log T14 merge-preapproved project=mirror ask=plan discord_message="$(soon)" 'scope=["src/"]'
  assert_equal "$output" "team-log: mirror is the team's own project, whose PRs merge only on Daniel's word per head, never on a plan-time word"
  run_bin -1 team-log T14 merge-preapproved project=tools ask=plan discord_message="$(soon)" 'scope=["src/"]'
  assert_equal "$output" "team-log: tools is the team's own project, whose PRs merge only on Daniel's word per head, never on a plan-time word"
  assert_equal "$(ledger_events | grep -c merge-preapproved)" 0
}

@test "merge-preapproved names an ask the task logged, and a Discord message sent no earlier than it" {
  plan_registry
  opened T14 proj
  run_bin -0 team-log T15 asked id=plan 'text=Approve?'
  run_bin -1 team-log T14 merge-preapproved project=proj ask=plan discord_message="$(soon)" 'scope=["src/"]'
  assert_equal "$output" "team-log: T14 logged no asked with id plan, so merge-preapproved answers no ask of it"
  run_bin -0 team-log T14 asked id=plan 'text=Approve?'
  local asked
  asked=$(tail -n 1 "$TEAM_HOME/ledger.jsonl" | jq -r .ts)
  # 1562661774950400000 is 2026-10-22T03:00:00Z, before the ask logged now.
  run_bin -1 team-log T14 merge-preapproved project=proj ask=plan discord_message=1562661774950400000 'scope=["src/"]'
  assert_equal "$output" "team-log: Discord message 1562661774950400000 was sent at 2026-10-22T03:00:00Z, before the asked plan at $asked, so it is not Daniel's answer to that ask"
  local message
  for message in 0 01563 15630000000000001234567; do
    run_bin -1 team-log T14 merge-preapproved project=proj ask=plan discord_message=$message 'scope=["src/"]'
    assert_equal "$output" "team-log: discord_message $message is not a Discord id"
  done
  run_bin -1 team-log T14 merge-preapproved project=proj ask=plan discord_message=m1563 'scope=["src/"]'
  assert_contains "$output" "discord_message must be a Discord id"
  run_bin -1 team-log T14 merge-preapproved project=proj ask=plan 'scope=["src/"]'
  assert_contains "$output" "merge-preapproved needs discord_message"
  assert_equal "$(ledger_events | grep -c merge-preapproved)" 0
  run_bin -0 team-log T14 merge-preapproved project=proj ask=plan discord_message="$(soon)" 'scope=["src/"]'
}

@test "merge-preapproved's scope is a list of clean repository paths, each a file or a directory ending in /" {
  plan_registry
  opened T14 proj
  run_bin -0 team-log T14 asked id=plan 'text=Approve?'
  run_bin -1 team-log T14 merge-preapproved project=proj ask=plan discord_message="$(soon)" 'scope=[]'
  assert_equal "$output" "team-log: scope is empty: it lists every path the plan may change, each a file or a directory ending in /"
  run_bin -1 team-log T14 merge-preapproved project=proj ask=plan discord_message="$(soon)" scope=none
  assert_equal "$output" "team-log: scope is empty: it lists every path the plan may change, each a file or a directory ending in /"
  run_bin -1 team-log T14 merge-preapproved project=proj ask=plan discord_message="$(soon)" 'scope={"src/":1}'
  assert_contains "$output" "scope must be a list, got an object"
  # A comma list is checked as its JSON form is.
  run_bin -1 team-log T14 merge-preapproved project=proj ask=plan discord_message="$(soon)" scope=src/,/etc/x
  assert_equal "$output" "team-log: scope holds entries that are not clean repository paths:
  \"/etc/x\": a leading /"
  run_bin -1 team-log T14 merge-preapproved project=proj ask=plan discord_message="$(soon)" \
    'scope=["src/", "/etc/x", "/", "./a", "a/./b", "a/..", "..", "a//b", "src/*.py", "a?", "b[1]", "a b", "a\tb", "", 7]'
  assert_equal "$output" "team-log: scope holds entries that are not clean repository paths:
  \"/etc/x\": a leading /
  \"/\": a leading /
  \"./a\": a . or .. segment
  \"a/./b\": a . or .. segment
  \"a/..\": a . or .. segment
  \"..\": a . or .. segment
  \"a//b\": an empty segment
  \"src/*.py\": a glob character
  \"a?\": a glob character
  \"b[1]\": a glob character
  \"a b\": whitespace
  \"a\\tb\": whitespace
  \"\": an empty segment
  7: not a string"
  assert_equal "$(ledger_events | grep -c merge-preapproved)" 0
  run_bin -0 team-log T14 merge-preapproved project=proj ask=plan discord_message="$(soon)" scope=src/,docs/README.md
  assert_equal "$(tail -n 1 "$TEAM_HOME/ledger.jsonl" | jq -c .scope)" '["src/","docs/README.md"]'
}

@test "merge-preapproval-withdrawn needs a standing merge-preapproved of its project, and a new one may follow it" {
  plan_registry "$(plan_project web true)"
  opened T14 proj
  opened T14 web worktree-added
  run_bin -0 team-log T14 asked id=plan 'text=Approve?'
  run_bin -1 team-log T14 merge-preapproval-withdrawn project=proj discord_message="$(soon)"
  assert_equal "$output" "team-log: T14 has no standing merge-preapproved of proj to withdraw"
  # Another task's approval is its own.
  opened T15 proj
  run_bin -0 team-log T15 asked id=plan 'text=Approve?'
  run_bin -0 team-log T15 merge-preapproved project=proj ask=plan discord_message="$(soon)" 'scope=["src/"]'
  run_bin -1 team-log T14 merge-preapproval-withdrawn project=proj discord_message="$(soon)"
  run_bin -0 team-log T14 merge-preapproved project=proj ask=plan discord_message="$(soon)" 'scope=["src/"]'
  run_bin -1 team-log T14 merge-preapproval-withdrawn project=web discord_message="$(soon)"
  assert_equal "$output" "team-log: T14 has no standing merge-preapproved of web to withdraw"
  run_bin -1 team-log T14 merge-preapproval-withdrawn project=proj
  assert_contains "$output" "merge-preapproval-withdrawn needs discord_message"
  run_bin -0 team-log T14 merge-preapproval-withdrawn project=proj discord_message="$(soon)"
  run_bin -1 team-log T14 merge-preapproval-withdrawn project=proj discord_message="$(soon)"
  assert_equal "$output" "team-log: T14 has no standing merge-preapproved of proj to withdraw"
  # A later approval, on a new ask, grants it again, and may be withdrawn in turn.
  run_bin -0 team-log T14 asked id=plan-2 'text=Approve again?'
  run_bin -0 team-log T14 merge-preapproved project=proj ask=plan-2 discord_message="$(soon)" 'scope=["src/", "docs/"]'
  run_bin -0 team-log T14 merge-preapproval-withdrawn project=proj discord_message="$(soon)"
  assert_equal "$(jq -r 'select(.task == "T14" and (.event | startswith("merge-pre"))) | "\(.event) \(.project)"' "$TEAM_HOME/ledger.jsonl")" "$(
    cat <<'LINES'
merge-preapproved proj
merge-preapproval-withdrawn proj
merge-preapproved proj
merge-preapproval-withdrawn proj
LINES
  )"
  run_bin -0 team-log --check
}

@test "branch-renamed records the task's new branch for one of its projects, which names the task and is not its branch now" {
  opened T14 proj
  opened T14 lib worktree-added
  run_bin -1 team-log T14 branch-renamed project=other branch=feat/T14-x-fresh
  assert_equal "$output" "team-log: other is not a project of T14's opened or worktree-added events: proj, lib"
  run_bin -1 team-log T14 branch-renamed project=proj branch=feat/T14-x
  assert_equal "$output" "team-log: feat/T14-x is already T14's branch for proj"
  run_bin -1 team-log T14 branch-renamed project=proj branch=feat/T15-x
  assert_equal "$output" "team-log: feat/T15-x does not name T14, as a branch of its worktree must"
  run_bin -1 team-log T14 branch-renamed project=proj branch=feat/T140-x
  assert_equal "$output" "team-log: feat/T140-x does not name T14, as a branch of its worktree must"
  run_bin -1 team-log T14 branch-renamed project=proj 'branch=feat/T14..x'
  assert_equal "$output" "team-log: feat/T14..x is not a branch name git takes (git check-ref-format --branch)"
  assert_equal "$(ledger_events | grep -c branch-renamed)" 0

  run_bin -0 team-log T14 branch-renamed project=proj branch=feat/T14-x-fresh
  assert_equal "$(tail -n 1 "$TEAM_HOME/ledger.jsonl" | jq -c 'del(.ts)')" \
    '{"task":"T14","event":"branch-renamed","project":"proj","branch":"feat/T14-x-fresh"}'
  # The latest one is the task's branch now: renaming it to itself is refused, back again is not.
  run_bin -1 team-log T14 branch-renamed project=proj branch=feat/T14-x-fresh
  assert_equal "$output" "team-log: feat/T14-x-fresh is already T14's branch for proj"
  run_bin -0 team-log T14 branch-renamed project=proj branch=feat/T14-x
  run_bin -0 team-log --check
}

@test "a review logs the count of each finding kind and the guarded areas, in their shapes, or neither" {
  run_bin -0 team-log T14 review verdict=pass head=a1b2c3d \
    'findings={"blocking": 0, "correctness": 1, "security": 0, "real-data": 0, "note-change": 2, "note-before": 1}' \
    'before=[4]' 'guarded=["ci", "secrets"]'
  run_bin -0 team-log T14 review verdict=pass head=e4f5a6b \
    'findings={"note-before": 0, "note-change": 0, "real-data": 0, "security": 0, "correctness": 0, "blocking": 0}' 'guarded=[]'
  run_bin -0 team-log T14 review verdict=findings head=e4f5a6b
  assert_equal "$(ledger_without_ts)" "$(
    cat <<'LINES'
{"task":"T14","event":"review","verdict":"pass","head":"a1b2c3d","findings":{"blocking":0,"correctness":1,"security":0,"real-data":0,"note-change":2,"note-before":1},"before":[4],"guarded":["ci","secrets"]}
{"task":"T14","event":"review","verdict":"pass","head":"e4f5a6b","findings":{"note-before":0,"note-change":0,"real-data":0,"security":0,"correctness":0,"blocking":0},"guarded":[]}
{"task":"T14","event":"review","verdict":"findings","head":"e4f5a6b"}
LINES
  )"
  run_bin -0 team-log --check

  run_bin -1 team-log T14 review verdict=pass head=a1b2c3d 'findings=[3]'
  assert_contains "$output" "findings must be an object, got a list"
  run_bin -1 team-log T14 review verdict=pass head=a1b2c3d \
    'findings={"blocking": 0, "correctness": -1, "security": 1.5, "note-change": "2", "note-before": 0, "note": 1}'
  assert_equal "$output" "team-log: findings holds the count of each finding kind, exactly blocking, correctness, security, real-data, note-change and note-before, each a whole number:
  correctness: -1 is not a whole number
  security: 1.5 is not a whole number
  note-change: \"2\" is not a whole number
  real-data: missing
  note: not a finding kind"
  run_bin -1 team-log T14 review verdict=pass head=a1b2c3d 'guarded={"ci":1}'
  assert_contains "$output" "guarded must be a list, got an object"
  run_bin -1 team-log T14 review verdict=pass head=a1b2c3d 'guarded=["ci", "docs", 1]'
  assert_equal "$output" "team-log: guarded lists the guarded areas the change touches, each one of ci, dependencies, migrations, settings, permissions and secrets:
  \"docs\": not a guarded area
  1: not a guarded area"
  assert_equal "$(wc -l <"$TEAM_HOME/ledger.jsonl")" "3"
}

@test "a review names its plain notes on code the PR did not change, and never sends one back" {
  local counts='"blocking": 1, "correctness": 0, "security": 0, "real-data": 0'
  # The before notes are named, the change notes and the blocking finding go back.
  run_bin -0 team-log T14 review verdict=findings head=a1b2c3d \
    "findings={$counts, \"note-change\": 2, \"note-before\": 2}" 'before=[3, 5]' 'sent_back=[1, 2, 4]' 'guarded=[]'
  # A review with no before note names none, and may omit the list.
  run_bin -0 team-log T14 review verdict=pass head=e4f5a6b \
    "findings={$counts, \"note-change\": 1, \"note-before\": 0}" 'sent_back=[1, 2]'
  run_bin -0 team-log T14 review verdict=pass head=e4f5a6b \
    "findings={$counts, \"note-change\": 0, \"note-before\": 0}" 'before=[]'
  # A review that logs no counts may still name its before notes.
  run_bin -0 team-log T14 review verdict=pass head=e4f5a6b 'before=[2]' 'sent_back=[1]'
  run_bin -0 team-log --check

  # A before note sent back is refused, naming each.
  run_bin -1 team-log T14 review verdict=findings head=a1b2c3d \
    "findings={$counts, \"note-change\": 0, \"note-before\": 2}" 'before=[3, 5]' 'sent_back=[1, 3, 5]'
  assert_equal "$output" "team-log: sent_back names notes 3 and 5, which before lists as plain notes on code the PR did not change: such a note is queued as a follow-up, never sent back"
  run_bin -1 team-log T14 review verdict=findings head=a1b2c3d 'before=[2]' 'sent_back=[2]'
  assert_equal "$output" "team-log: sent_back names note 2, which before lists as a plain note on code the PR did not change: such a note is queued as a follow-up, never sent back"
  # The counts and the list agree.
  run_bin -1 team-log T14 review verdict=findings head=a1b2c3d \
    "findings={$counts, \"note-change\": 0, \"note-before\": 2}" 'sent_back=[1]'
  assert_equal "$output" "team-log: findings counts 2 plain notes on code the PR did not change: before lists their numbers"
  run_bin -1 team-log T14 review verdict=findings head=a1b2c3d \
    "findings={$counts, \"note-change\": 0, \"note-before\": 2}" 'before=[3]'
  assert_equal "$output" "team-log: before lists 1 note, but findings counts 2 plain notes on code the PR did not change"
  # The list's shape.
  run_bin -1 team-log T14 review verdict=findings head=a1b2c3d 'before={"3":1}'
  assert_contains "$output" "before must be a list of whole numbers, got an object"
  run_bin -1 team-log T14 review verdict=findings head=a1b2c3d 'before=[0, "3", 4, 4, 3]'
  assert_equal "$output" "team-log: before lists the numbers of the plain notes on code the PR did not change, each a whole number above 0, once:
  0: not a finding number
  3: listed twice
  4: listed twice"
  run_bin -1 team-log T14 review verdict=findings head=a1b2c3d 'before=2.5,3'
  assert_equal "$output" "team-log: before: 2.5 is not a whole number"
  assert_equal "$(wc -l <"$TEAM_HOME/ledger.jsonl")" "4"
}

@test "an answered naming the Discord message an earlier answered of the same ask logged is refused" {
  run_bin -0 team-log T14 answered id=sign-in answer=five discord_message=1564000000000000001
  run_bin -1 team-log T14 answered id=sign-in answer=five discord_message=1564000000000000001
  assert_equal "$output" "team-log: T14 already logged answered id=sign-in from Discord message 1564000000000000001"
  # Another message for the same ask is an addition, the same message may answer another ask,
  # another task is its own, and an answer with no message is never a repeat.
  run_bin -0 team-log T14 answered id=sign-in answer=and-six discord_message=1564000000000000002
  run_bin -0 team-log T14 answered id=reset answer=five discord_message=1564000000000000001
  run_bin -0 team-log T15 answered id=sign-in answer=five discord_message=1564000000000000001
  run_bin -0 team-log T14 answered id=sign-in answer=five
  run_bin -0 team-log T14 answered id=sign-in answer=five
  assert_equal "$(jq -r '[.task, .id, .discord_message // "-"] | join(" ")' "$TEAM_HOME/ledger.jsonl")" "$(
    cat <<'LINES'
T14 sign-in 1564000000000000001
T14 sign-in 1564000000000000002
T14 reset 1564000000000000001
T15 sign-in 1564000000000000001
T14 sign-in -
T14 sign-in -
LINES
  )"
}

@test "a kind another script writes is refused with nothing appended" {
  run_bin -1 team-log T14 opened project=agent-team path=feature type=feat title=x branch=b base=dev base_sha=abc1234 worktree=/w
  assert_contains "$output" "opened events are written by team-open, not team-log"
  run_bin -1 team-log T14 launch role=builder session=abc worktree=/w 'toolkits=[]'
  assert_contains "$output" "launch events are written by team-worker, not team-log"
  run_bin -1 team-log T14 merged pr=5 merge=abc1234 head=def5678 by=coordinator
  assert_contains "$output" "merged events are written by team-merge, not team-log"
  run_bin -1 team-log T14 closed 'archive=[]' 'returned=[]' 'kept=[]'
  assert_contains "$output" "closed events are written by team-close, not team-log"
  run_bin -1 team-log T14 thread discord_thread=1563
  assert_contains "$output" "thread events are written by team-thread, not team-log"
  assert_ledger_empty
}

@test "a park logged after the fact takes since, when it began, on each of the four park kinds" {
  local task
  for task in T14 T15 T16 T17; do
    echo '{"ts":"2026-10-25T14:51:44Z","task":"'$task'","event":"launch","role":"builder","session":"s","worktree":"/w","toolkits":[]}'
  done >"$TEAM_HOME/ledger.jsonl"
  # Another task's later event does not bound it.
  echo '{"ts":"2026-10-25T16:00:00Z","task":"T18","event":"resumed"}' >>"$TEAM_HOME/ledger.jsonl"
  run_bin -0 team-log T14 blocked 'reason=usage limit: the weekly limit' since=2026-10-25T14:58:00Z
  run_bin -0 team-log T15 waiting on=Daniel reason=x since=2026-10-25T14:58:00Z
  run_bin -0 team-log T16 paused reason=x since=2026-10-25T14:51:44Z
  run_bin -0 team-log T17 held reason=x since=2026-10-25T14:58:00Z
  assert_equal "$(tail -n 4 "$TEAM_HOME/ledger.jsonl" | jq -r '[.event, .since] | join(" ")')" "$(
    printf '%s\n' 'blocked 2026-10-25T14:58:00Z' 'waiting 2026-10-25T14:58:00Z' 'paused 2026-10-25T14:51:44Z' 'held 2026-10-25T14:58:00Z'
  )"
  run_bin -0 team-log --check
}

@test "since is refused when it is not a UTC time, later than now, or earlier than the task's latest event" {
  printf '%s\n' '{"ts":"2026-10-25T14:51:44Z","task":"T14","event":"launch","role":"builder","session":"s","worktree":"/w","toolkits":[]}' \
    '{"ts":"2026-10-25T15:30:00Z","task":"T15","event":"resumed"}' >"$TEAM_HOME/ledger.jsonl"
  local before
  before=$(cat "$TEAM_HOME/ledger.jsonl")
  local bad
  for bad in yesterday 2026-10-25 2026-10-25T14:58:00 '2026-10-25 14:58:00Z' 2026-10-25T25:00:00Z; do
    run_bin -1 team-log T14 blocked reason=x "since=$bad"
    assert_contains "$output" "since must be a UTC time like 2026-10-22T01:00:00Z, got '$bad'"
  done
  run_bin -1 team-log T14 blocked reason=x since=2999-01-01T00:00:00Z
  assert_contains "$output" "since 2999-01-01T00:00:00Z is later than now ("
  run_bin -1 team-log T14 blocked reason=x since=2026-10-25T14:00:00Z
  assert_contains "$output" "since 2026-10-25T14:00:00Z is earlier than T14's latest event, at 2026-10-25T14:51:44Z"
  run_bin -1 team-log T14 resumed since=2026-10-25T15:00:00Z
  assert_contains "$output" "since is taken only by a park (waiting, blocked, paused, held), not resumed"
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" "$before"
}

@test "too few arguments is a usage error" {
  run_bin -2 team-log
  assert_contains "$output" "usage: team-log T<n> <event> [key=value]..."
  run_bin -2 team-log T14
  run_bin -2 team-log --check a b
  assert_ledger_empty
}

@test "--check passes a ledger whose legacy lines are loose and whose later lines meet the contract" {
  [[ 2026-10-01T00:00:00Z < $STRICT_FROM ]]
  cat >"$TEAM_HOME/ledger.jsonl" <<LEDGER
{"ts":"2026-10-01T00:00:00Z","task":"T1","event":"closed"}
{"ts":"2026-10-01T00:00:01Z","task":"T5","event":"ticket-partial","ticket":"09"}
{"ts":"2026-10-01T00:00:02Z","task":"T4","event":"review","verdict":"pass","agent_review":"success","head":"e1e8cdb6"}
{"ts":"2026-10-01T00:00:03Z","task":"T7","event":"closed","note":"a legacy close by hand: no lists"}
{"ts":"2026-10-01T00:00:04Z","task":"T16","event":"plan-ready","note":"a kind that is not in the contract"}
{"ts":"$STRICT_FROM","task":"T14","event":"closed","archive":["tasks/T14/scratch"],"returned":[],"kept":[]}
{"ts":"$STRICT_FROM","task":"T14","event":"launch","role":"builder","session":"c79f0205","worktree":"/w","toolkits":[]}
{"ts":"$STRICT_FROM","task":"T14","event":"resumed","note":"anything extra is allowed","by":"coordinator"}
LEDGER
  run_bin -0 team-log --check
  assert_equal "$output" "$TEAM_HOME/ledger.jsonl: 8 lines meet the ledger contract"
}

# T171 review note 2: the ledger's reviews before the scope split count plain notes as note.
@test "--check passes a review logged before the scope split, its findings counting note" {
  echo "{\"ts\":\"$STRICT_FROM\",\"task\":\"T14\",\"event\":\"review\",\"verdict\":\"pass\",\"head\":\"a1b2c3d\",\"findings\":{\"blocking\":0,\"correctness\":0,\"security\":0,\"real-data\":0,\"note\":3},\"guarded\":[]}" \
    >>"$TEAM_HOME/ledger.jsonl"
  run_bin -0 team-log --check
  assert_equal "$output" "$TEAM_HOME/ledger.jsonl: 1 line meets the ledger contract"
  # A new review after it counts the split.
  run_bin -0 team-log T14 review verdict=pass head=e4f5a6b \
    'findings={"blocking": 0, "correctness": 0, "security": 0, "real-data": 0, "note-change": 0, "note-before": 0}' 'guarded=[]'
  run_bin -0 team-log --check
  assert_equal "$output" "$TEAM_HOME/ledger.jsonl: 2 lines meet the ledger contract"
}

@test "--check accepts a failed re-home and the re-home that clears it, and refuses one with no reason" {
  cat >"$TEAM_HOME/ledger.jsonl" <<LEDGER
{"ts":"$STRICT_FROM","task":"T14","event":"rehome-failed","project":"home","branch":"feat/T14-x","machine":"laptop","reason":"feat/T14-x here has commits that origin's lacks"}
{"ts":"$STRICT_FROM","task":"T14","event":"rehomed","project":"home","branch":"feat/T14-x","worktree":"/w","machine":"laptop"}
LEDGER
  run_bin -0 team-log --check
  assert_equal "$output" "$TEAM_HOME/ledger.jsonl: 2 lines meet the ledger contract"
  echo "{\"ts\":\"$STRICT_FROM\",\"task\":\"T14\",\"event\":\"rehome-failed\",\"project\":\"home\",\"branch\":\"b\",\"machine\":\"laptop\"}" >>"$TEAM_HOME/ledger.jsonl"
  run_bin -1 team-log --check
  assert_contains "$output" "ledger.jsonl:3: rehome-failed needs reason"
  # Only team-resume writes it.
  run_bin -1 team-log T14 rehome-failed project=home branch=b machine=laptop reason=r
  assert_contains "$output" "team-resume"
}

@test "--check lists every bad line by number and exits 1" {
  cat >"$TEAM_HOME/ledger.jsonl" <<LEDGER
{"ts":"2026-10-01T00:00:00Z","task":"T1","event":"closed"}
not json
{"task":"T1","event":"closed"}
{"ts":"2026-10-01 00:00:00","task":"T1","event":"closed"}
{"ts":"2026-10-01T00:00:00Z","task":"7","event":"closed"}

{"ts":"2026-10-01T00:00:00Z","task":"T1"}
["ts","task","event"]
{"ts":"$STRICT_FROM","task":"T14","event":"closed"}
{"ts":"$STRICT_FROM","task":"T14","event":"ticket-partial","ticket":"09"}
{"ts":"$STRICT_FROM","task":"T14","event":"review","verdict":"fine","head":"a1b2c3d","note":7}
{"ts":"$STRICT_FROM","task":"T14","event":"pr","url":"","head":"a1b2c3d"}
{"ts":"$STRICT_FROM","task":"T14","event":"thread","discord_thread":"1563"}
LEDGER
  run_bin -1 team-log --check
  assert_equal "$output" "$(
    cat <<EXPECTED
$TEAM_HOME/ledger.jsonl:2: not JSON
$TEAM_HOME/ledger.jsonl:3: missing ts
$TEAM_HOME/ledger.jsonl:4: ts must be a UTC time like 2026-10-22T01:00:00Z
$TEAM_HOME/ledger.jsonl:5: task must look like T<n>
$TEAM_HOME/ledger.jsonl:6: not JSON
$TEAM_HOME/ledger.jsonl:7: missing event
$TEAM_HOME/ledger.jsonl:8: not a JSON object
$TEAM_HOME/ledger.jsonl:9: closed needs archive; closed needs returned; closed needs kept
$TEAM_HOME/ledger.jsonl:10: unknown event kind 'ticket-partial'
$TEAM_HOME/ledger.jsonl:11: verdict must be one of pass, findings; note must be a string, got a number
$TEAM_HOME/ledger.jsonl:12: pr needs url
$TEAM_HOME/ledger.jsonl: 11 of 13 lines break the ledger contract
EXPECTED
  )"
}

@test "--check reads the file it is given, and a missing ledger is refused" {
  printf '%s\n' '{"ts":"2026-10-01T00:00:00Z","task":"T1","event":"closed"}' >"$BATS_TEST_TMPDIR/other.jsonl"
  echo 'not json' >"$TEAM_HOME/ledger.jsonl"
  run_bin -0 team-log --check "$BATS_TEST_TMPDIR/other.jsonl"
  assert_equal "$output" "$BATS_TEST_TMPDIR/other.jsonl: 1 line meets the ledger contract"
  run_bin -1 team-log --check "$BATS_TEST_TMPDIR/missing.jsonl"
  assert_contains "$output" "no ledger at $BATS_TEST_TMPDIR/missing.jsonl"
  rm "$TEAM_HOME/ledger.jsonl"
  run_bin -1 team-log --check
  assert_contains "$output" "no ledger at $TEAM_HOME/ledger.jsonl"
}

@test "--check passes a sent_back or before holding whole numbers as strings, naming each such line from strict_from on and the conversion" {
  cat >"$TEAM_HOME/ledger.jsonl" <<LEDGER
{"ts":"2026-10-01T00:00:00Z","task":"T4","event":"review","verdict":"pass","head":"e1e8cdb6","sent_back":["1"]}
{"ts":"$STRICT_FROM","task":"T14","event":"review","verdict":"findings","head":"a1b2c3d","sent_back":[5,6]}
{"ts":"$STRICT_FROM","task":"T14","event":"review","verdict":"findings","head":"a1b2c3d","sent_back":["5","6"]}
{"ts":"$STRICT_FROM","task":"T14","event":"review","verdict":"findings","head":"a1b2c3d","sent_back":["7",8],"before":["3"]}
LEDGER
  run_bin -0 --separate-stderr team-log --check
  assert_equal "$output" "$TEAM_HOME/ledger.jsonl: 4 lines meet the ledger contract; 2 hold whole numbers as strings, which team-log --fix-sent-back stores as numbers"
  assert_equal "$stderr" "$TEAM_HOME/ledger.jsonl:3: sent_back holds whole numbers as strings (\"5\", \"6\"): team-log --fix-sent-back stores them as numbers
$TEAM_HOME/ledger.jsonl:4: sent_back holds whole numbers as strings (\"7\"): team-log --fix-sent-back stores them as numbers; before holds whole numbers as strings (\"3\"): team-log --fix-sent-back stores them as numbers"
  sed -i '4d' "$TEAM_HOME/ledger.jsonl"
  run_bin -0 --separate-stderr team-log --check
  assert_equal "$output" "$TEAM_HOME/ledger.jsonl: 3 lines meet the ledger contract; 1 holds whole numbers as strings, which team-log --fix-sent-back stores as numbers"
  sed -i '3d' "$TEAM_HOME/ledger.jsonl"
  run_bin -0 --separate-stderr team-log --check
  assert_equal "$output" "$TEAM_HOME/ledger.jsonl: 2 lines meet the ledger contract"
  assert_equal "$stderr" ""
}

@test "--check refuses a sent_back holding anything but whole numbers, the bad lines first and the old strings after" {
  cat >"$TEAM_HOME/ledger.jsonl" <<LEDGER
{"ts":"$STRICT_FROM","task":"T14","event":"review","verdict":"findings","head":"a1b2c3d","sent_back":["5"]}
{"ts":"$STRICT_FROM","task":"T14","event":"review","verdict":"findings","head":"a1b2c3d","sent_back":["x",1.5]}
{"ts":"$STRICT_FROM","task":"T14","event":"review","verdict":"findings","head":"a1b2c3d","sent_back":["6","y"]}
{"ts":"$STRICT_FROM","task":"T14","event":"review","verdict":"findings","head":"a1b2c3d","sent_back":"5"}
LEDGER
  run_bin -1 team-log --check
  assert_equal "$output" "$TEAM_HOME/ledger.jsonl:2: sent_back must be a list of whole numbers, got \"x\", 1.5
$TEAM_HOME/ledger.jsonl:3: sent_back must be a list of whole numbers, got \"6\", \"y\"
$TEAM_HOME/ledger.jsonl:4: sent_back must be a list of whole numbers, got a string
$TEAM_HOME/ledger.jsonl:1: sent_back holds whole numbers as strings (\"5\"): team-log --fix-sent-back stores them as numbers
$TEAM_HOME/ledger.jsonl: 3 of 4 lines break the ledger contract; 1 holds whole numbers as strings, which team-log --fix-sent-back stores as numbers"
}

@test "a new review's sent_back of strings that are no whole numbers is still refused, logging nothing" {
  run_bin -1 team-log T1 review verdict=findings head=a1b2c3d findings=blocking:1,correctness:0,security:0,real-data:0,note-change:0,note-before:0 guarded=none 'sent_back=["x"]'
  assert_contains "$output" 'sent_back: x is not a whole number'
  run_bin -1 team-log T1 review verdict=findings head=a1b2c3d findings=blocking:1,correctness:0,security:0,real-data:0,note-change:0,note-before:0 guarded=none sent_back=5,x
  assert_contains "$output" 'sent_back: x is not a whole number'
  assert_equal "$(wc -l <"$TEAM_HOME/ledger.jsonl")" 0
}


# A ledger with sent_back held as strings on some lines, legacy and strict, beside lines of other
# shapes the conversion leaves byte for byte: fix_ledger <file>
fix_ledger() {
  cat >"$1" <<LEDGER
{"ts":"2026-10-01T00:00:00Z","task":"T4","event":"review","verdict":"pass","head":"e1e8cdb6","sent_back":["1"]}
{"ts": "$STRICT_FROM", "task": "T14", "event": "review", "verdict": "pass", "head": "a1", "sent_back": [1, 2]}
{"ts":"$STRICT_FROM","task":"T14","event":"review","verdict":"findings","head":"a2","sent_back":["5","6"],"findings":{"blocking":1.0}}
not json
{"ts":"$STRICT_FROM","task":"T14","event":"resumed","sent_back":["9"],"note":"caf\u00e9 \u2192 ok"}
{"ts":"$STRICT_FROM","task":"T14","event":"review","verdict":"findings","head":"a3","sent_back":["7",8],"before":["3"],"note":"é"}

{"ts":"$STRICT_FROM","task":"T14","event":"done","role":"builder","session":"s1"}
LEDGER
}

@test "--fix-sent-back stores the whole numbers sent_back holds as strings as numbers, leaving every other line byte for byte" {
  fix_ledger "$TEAM_HOME/ledger.jsonl"
  cp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/before.jsonl"
  chmod 0644 "$TEAM_HOME/ledger.jsonl"
  run_bin -0 team-log --fix-sent-back
  assert_equal "$output" "$TEAM_HOME/ledger.jsonl: 3 lines changed, the whole numbers their sent_back or before held as strings now numbers"
  assert_equal "$(wc -l <"$TEAM_HOME/ledger.jsonl")" "8"
  assert_equal "$(sed -n 1p "$TEAM_HOME/ledger.jsonl")" '{"ts":"2026-10-01T00:00:00Z","task":"T4","event":"review","verdict":"pass","head":"e1e8cdb6","sent_back":[1]}'
  assert_equal "$(sed -n 3p "$TEAM_HOME/ledger.jsonl")" "{\"ts\":\"$STRICT_FROM\",\"task\":\"T14\",\"event\":\"review\",\"verdict\":\"findings\",\"head\":\"a2\",\"sent_back\":[5,6],\"findings\":{\"blocking\":1.0}}"
  assert_equal "$(sed -n 6p "$TEAM_HOME/ledger.jsonl")" "{\"ts\":\"$STRICT_FROM\",\"task\":\"T14\",\"event\":\"review\",\"verdict\":\"findings\",\"head\":\"a3\",\"sent_back\":[7,8],\"before\":[3],\"note\":\"é\"}"
  local n
  for n in 2 4 5 7 8; do
    cmp <(sed -n "${n}p" "$TEAM_HOME/ledger.jsonl") <(sed -n "${n}p" "$BATS_TEST_TMPDIR/before.jsonl")
  done
  assert_equal "$(stat -c %a "$TEAM_HOME/ledger.jsonl")" "644"
  assert_equal "$(find "$TEAM_HOME" -maxdepth 1 -name 'ledger.jsonl.*' ! -name ledger.jsonl.lock)" ""

  # Once is enough: a second run changes nothing.
  cp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/fixed.jsonl"
  run_bin -0 team-log --fix-sent-back
  assert_equal "$output" "$TEAM_HOME/ledger.jsonl: no line's sent_back or before holds a whole number as a string; nothing changed"
  cmp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/fixed.jsonl"

  # It reads the file it is given.
  fix_ledger "$BATS_TEST_TMPDIR/other.jsonl"
  run_bin -0 team-log --fix-sent-back "$BATS_TEST_TMPDIR/other.jsonl"
  assert_equal "$output" "$BATS_TEST_TMPDIR/other.jsonl: 3 lines changed, the whole numbers their sent_back or before held as strings now numbers"
  run_bin -1 team-log --fix-sent-back "$BATS_TEST_TMPDIR/missing.jsonl"
  assert_contains "$output" "no ledger at $BATS_TEST_TMPDIR/missing.jsonl"
  run_bin -2 team-log --fix-sent-back a b
}

@test "--fix-sent-back refuses a string that is no whole number, naming each, and changes nothing" {
  fix_ledger "$TEAM_HOME/ledger.jsonl"
  cat >>"$TEAM_HOME/ledger.jsonl" <<LEDGER
{"ts":"$STRICT_FROM","task":"T14","event":"review","verdict":"findings","head":"a4","sent_back":["5","5a"]}
{"ts":"$STRICT_FROM","task":"T14","event":"review","verdict":"findings","head":"a5","sent_back":["-1",""]}
LEDGER
  cp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/before.jsonl"
  run_bin -1 team-log --fix-sent-back
  assert_equal "$output" "$TEAM_HOME/ledger.jsonl:9: sent_back holds \"5a\", which is no whole number
$TEAM_HOME/ledger.jsonl:10: sent_back holds \"-1\", \"\", which are no whole numbers
team-log: $TEAM_HOME/ledger.jsonl: 2 lines hold strings that are no whole numbers in a list of whole numbers, so nothing changed"
  cmp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/before.jsonl"
}

@test "--fix-sent-back waits for the ledger's lock, as an append does" {
  fix_ledger "$TEAM_HOME/ledger.jsonl"
  cp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/before.jsonl"
  local held
  exec {held}>>"$TEAM_HOME/ledger.jsonl.lock"
  flock -x "$held"
  guard_sandbox
  run timeout 1 "$REPO_ROOT/bin/team-log" --fix-sent-back
  exec {held}>&-
  assert_equal "$status" "124"
  cmp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/before.jsonl"
  run_bin -0 team-log --fix-sent-back
  assert_contains "$output" "3 lines changed"
}

@test "--from-message logs a QUESTION as the sender's question" {
  open_t7
  launched T7 builder b0000001
  # roles/builder.md: `QUESTION <text> | options: ...`
  logs_events '{"task":"T7","event":"question","role":"builder","text":"Which store keeps the counters? | options: Mongo TTL / memory"}' \
    --from-message 'T7 QUESTION Which store keeps the counters? | options: Mongo TTL / memory'
}

@test "--from-message logs a BLOCKED and a NEED toolkit as blocked" {
  open_t7
  launched T7 builder b0000001
  # roles/builder.md: `BLOCKED <what> <why>`
  logs_events '{"task":"T7","event":"blocked","reason":"Bash(git push) denied: the push target is a base branch"}' \
    --from-message 'T7 BLOCKED Bash(git push) denied: the push target is a base branch'
  # roles/builder.md: `NEED toolkit <name>`
  logs_events '{"task":"T7","event":"blocked","reason":"needs toolkit browser"}' \
    --from-message 'T7 NEED toolkit browser'
  refuses_message "team-log: NEED takes 'NEED toolkit <name>', got 'NEED a browser'" \
    --from-message 'T7 NEED a browser'
}

@test "--from-message logs a PAUSED stowed as paused reason=stowed" {
  open_t7
  launched T7 builder b0000001
  # roles/builder.md: reply `T<n> PAUSED stowed`
  logs_events '{"task":"T7","event":"paused","reason":"stowed"}' --from-message 'T7 PAUSED stowed'
}

@test "--from-message logs a PAUSED with its why" {
  open_t7
  launched T7 builder b0000001
  # roles/builder.md: `T<n> PAUSED offline <what failed>`
  logs_events '{"task":"T7","event":"paused","reason":"offline git push could not reach github.com"}' \
    --from-message 'T7 PAUSED offline git push could not reach github.com'
}

@test "--from-message logs a PR with its head from GitHub, and a branch-renamed when the gate moved the branch" {
  open_t7
  launched T7 builder b0000001
  on_github "$URL" "$HEAD_A" feat/T7-x
  # templates/briefs/delivery/direct-pr.md: `{{task}} PR <full url>`
  logs_events "{\"task\":\"T7\",\"event\":\"pr\",\"url\":\"$URL\",\"head\":\"$HEAD_A\"}" --from-message "T7 PR $URL"
  # templates/briefs/delivery/no-mistakes.md: followed by `merged {{base}} conflicts: <each file that conflicted, or none>`
  on_github "$URL" "$HEAD_B" feat/T7-x-r2
  logs_events "{\"task\":\"T7\",\"event\":\"pr\",\"url\":\"$URL\",\"head\":\"$HEAD_B\"}
{\"task\":\"T7\",\"event\":\"branch-renamed\",\"project\":\"proj\",\"branch\":\"feat/T7-x-r2\"}" \
    --from-message "T7 PR $URL merged dev conflicts: bin/team-log, tests/team-log.bats"
  # The branch is the task's now, so the next PR message renames nothing.
  logs_events "{\"task\":\"T7\",\"event\":\"pr\",\"url\":\"$URL\",\"head\":\"$HEAD_B\"}" \
    --from-message "T7 PR $URL merged dev conflicts: none"
}

@test "--from-message refuses a PR it cannot read on GitHub, in no repo of the task, or followed by anything else" {
  open_t7
  launched T7 builder b0000001
  on_github "$URL" "$HEAD_A" feat/T7-x
  refuses_message "team-log: cannot read https://github.com/owner/proj/pull/13 on GitHub (GraphQL: Could not resolve to a PullRequest with the number of 13.); log it by hand: team-log T7 pr url=https://github.com/owner/proj/pull/13 head=<full sha>" \
    --from-message 'T7 PR https://github.com/owner/proj/pull/13'
  refuses_message "team-log: https://github.com/owner/conv/pull/12 is in no repo of T7's projects: proj (owner/proj)" \
    --from-message 'T7 PR https://github.com/owner/conv/pull/12'
  refuses_message "team-log: PR takes 'PR <full url>', optionally followed by 'merged <base> conflicts: <files or none>', got 'PR $URL and more'" \
    --from-message "T7 PR $URL and more"
  refuses_message "team-log: PR takes 'PR <full url>', optionally followed by 'merged <base> conflicts: <files or none>', got 'PR owner/proj#12'" \
    --from-message 'T7 PR owner/proj#12'
}

@test "--from-message logs a ticket's DONE as ticket-done and the builder's done" {
  open_t7
  launched T7 builder b0000001 brief-build-03
  # templates/briefs/builder-ticket.md: `{{task}} DONE {{ticket}} <sha> <one line>`
  logs_events '{"task":"T7","event":"ticket-done","ticket":"03","commits":["a1b2c3d4"],"note":"team-log reads a worker'"'"'s message whole"}
{"task":"T7","event":"done","role":"builder","session":"b0000001"}' \
    --from-message "T7 DONE 03 a1b2c3d4 team-log reads a worker's message whole"
  # More than one sha, and a full one.
  logs_events "{\"task\":\"T7\",\"event\":\"ticket-done\",\"ticket\":\"04\",\"commits\":[\"0a1b2c3\",\"$HEAD_A\"],\"note\":\"two commits\"}
{\"task\":\"T7\",\"event\":\"done\",\"role\":\"builder\",\"session\":\"b0000001\"}" \
    --from-message "T7 DONE 04 0a1b2c3 $HEAD_A two commits"
  # A malformed sha is refused, naming it.
  refuses_message "team-log: DONE 05 takes one or more shas of 7 to 40 hex digits after the ticket, then a line, got 'a1b2c3'" \
    --from-message 'T7 DONE 05 a1b2c3 too short'
}

@test "--from-message logs a DONE review-ready as the builder's done with its report" {
  open_t7
  launched T7 builder b0000002 brief-deliver
  # templates/briefs/delivery/no-mistakes.md: `{{task}} DONE review-ready <the full sha of HEAD>`
  logs_events "{\"task\":\"T7\",\"event\":\"done\",\"role\":\"builder\",\"session\":\"b0000002\",\"report\":\"review-ready $HEAD_A\"}" \
    --from-message "T7 DONE review-ready $HEAD_A"
  refuses_message "team-log: DONE review-ready takes 'DONE review-ready <sha>', got 'DONE review-ready HEAD'" \
    --from-message 'T7 DONE review-ready HEAD'
}

@test "--from-message logs a DONE merged as the builder's done with its report" {
  open_t7
  launched T7 builder b0000003 brief-merge-base
  # templates/briefs/builder-merge-base.md: `{{task}} DONE merged {{base}} <the full sha of the head> conflicts: <each file that conflicted, or none>`
  logs_events "{\"task\":\"T7\",\"event\":\"done\",\"role\":\"builder\",\"session\":\"b0000003\",\"report\":\"merged dev $HEAD_A conflicts: bin/team-log, CLAUDE.md\"}" \
    --from-message "T7 DONE merged dev $HEAD_A conflicts: bin/team-log, CLAUDE.md"
  refuses_message "team-log: DONE merged takes 'DONE merged <base> <sha> conflicts: <files or none>', got 'DONE merged dev $HEAD_A'" \
    --from-message "T7 DONE merged dev $HEAD_A"
}

@test "--from-message logs a DONE pass as the review of the head its reviewer's brief named, and the reviewer's done" {
  open_t7
  launched T7 builder b0000001
  launched T7 reviewer c0000001 brief-review
  brief_record T7 brief-review "{\"pr\": \"$URL\", \"head\": \"$HEAD_A\"}"
  # templates/briefs/review/direct-pr.md: `{{task}} DONE pass {{pr}} findings=... before=... guarded=...`
  logs_events "{\"task\":\"T7\",\"event\":\"review\",\"verdict\":\"pass\",\"head\":\"$HEAD_A\",\"findings\":{\"blocking\":0,\"correctness\":0,\"security\":0,\"real-data\":0,\"note-change\":1,\"note-before\":1},\"before\":[2],\"guarded\":[]}
{\"task\":\"T7\",\"event\":\"done\",\"role\":\"reviewer\",\"session\":\"c0000001\"}" \
    --from-message "T7 DONE pass $URL findings=blocking:0,correctness:0,security:0,real-data:0,note-change:1,note-before:1 before=2 guarded=none"
}

@test "--from-message logs a DONE findings as a review with what --sent-back gives, and the reviewer's done" {
  open_t7
  launched T7 builder b0000001
  launched T7 reviewer c0000001 brief-rereview-2
  brief_record T7 brief-rereview-2 "{\"pr\": \"$URL\", \"head\": \"$HEAD_B\", \"reviewed\": \"$HEAD_A\"}"
  # templates/briefs/rereview.md: `{{task}} DONE findings {{task_dir}}/review.md findings=... before=... guarded=...`
  logs_events "{\"task\":\"T7\",\"event\":\"review\",\"verdict\":\"findings\",\"head\":\"$HEAD_B\",\"findings\":{\"blocking\":1,\"correctness\":1,\"security\":0,\"real-data\":0,\"note-change\":1,\"note-before\":0},\"before\":[],\"guarded\":[\"ci\",\"settings\"],\"sent_back\":[1,2,3]}
{\"task\":\"T7\",\"event\":\"done\",\"role\":\"reviewer\",\"session\":\"c0000001\"}" \
    --from-message "T7 DONE findings .scratch/task/review.md findings=blocking:1,correctness:1,security:0,real-data:0,note-change:1,note-before:0 before=none guarded=ci,settings" \
    --sent-back 1,2,3
  # The review's own checks hold: a before note is never sent back.
  refuses_message "team-log: sent_back names note 2, which before lists as a plain note on code the PR did not change: such a note is queued as a follow-up, never sent back" \
    --from-message "T7 DONE findings .scratch/task/review.md findings=blocking:1,correctness:0,security:0,real-data:0,note-change:0,note-before:1 before=2 guarded=none" \
    --sent-back 1,2
}

@test "a pass that sends findings back is logged as findings, by hand and from a message, and one that sends none stays a pass" {
  open_t7
  launched T7 builder b0000001
  launched T7 reviewer c0000001 brief-review
  brief_record T7 brief-review "{\"pr\": \"$URL\", \"head\": \"$HEAD_A\"}"
  local counts='blocking:0,correctness:1,security:0,real-data:0,note-change:1,note-before:0'
  # From a message, with --sent-back: not ready to merge, so findings, whatever the verdict word.
  logs_events "{\"task\":\"T7\",\"event\":\"review\",\"verdict\":\"findings\",\"head\":\"$HEAD_A\",\"findings\":{\"blocking\":0,\"correctness\":1,\"security\":0,\"real-data\":0,\"note-change\":1,\"note-before\":0},\"guarded\":[],\"sent_back\":[1,2]}
{\"task\":\"T7\",\"event\":\"done\",\"role\":\"reviewer\",\"session\":\"c0000001\"}" \
    --from-message "T7 DONE pass $URL findings=$counts guarded=none" --sent-back 1,2
  # By hand, in either list form.
  run_bin -0 team-log T7 review verdict=pass head=a1b2c3d sent_back=3
  run_bin -0 team-log T7 review verdict=pass head=a1b2c3d 'sent_back=[4]'
  # A pass that sends nothing back stays a pass.
  run_bin -0 team-log T7 review verdict=pass head=a1b2c3d sent_back=none
  run_bin -0 team-log T7 review verdict=pass head=a1b2c3d
  assert_equal "$(jq -c 'select(.event == "review") | [.verdict, .sent_back]' "$TEAM_HOME/ledger.jsonl")" \
    '["findings",[1,2]]
["findings",[3]]
["findings",[4]]
["pass",[]]
["pass",null]'
}

@test "--from-message logs a DONE gate as the gate-run its pairs give" {
  open_t7
  launched T7 builder b0000002 brief-deliver
  # templates/briefs/delivery/no-mistakes.md: `{{task}} DONE gate run=<its id> head=<sha> outcome=<...> minutes=<one JSON object>`, with `cause=<...>`
  logs_events "{\"task\":\"T7\",\"event\":\"gate-run\",\"run\":\"01KR2B3C4D\",\"head\":\"$HEAD_A\",\"outcome\":\"pushed\",\"minutes\":{\"review\":3.5,\"test\":12},\"cause\":\"review\"}" \
    --from-message "T7 DONE gate run=01KR2B3C4D head=$HEAD_A outcome=pushed minutes={\"review\": 3.5, \"test\": 12} cause=review"
  refuses_message "team-log: refusing a ledger event: outcome must be one of pushed, red, aborted, stopped-green" \
    --from-message "T7 DONE gate run=01KR2B3C4D head=$HEAD_A outcome=green minutes={}"
  refuses_message "team-log: DONE gate takes key=value pairs, got 'run 01KR2B3C4D' before the first" \
    --from-message "T7 DONE gate run 01KR2B3C4D head=$HEAD_A"
}

@test "--from-message logs any other DONE as the sender's done with its report" {
  open_t7
  launched T7 planner a0000001 brief
  # templates/briefs/planner-feature.md: `{{task}} DONE {{task_dir}}/spec.md`
  logs_events '{"task":"T7","event":"done","role":"planner","session":"a0000001","report":".scratch/task/spec.md"}' \
    --from-message 'T7 DONE .scratch/task/spec.md'
}

@test "--from-message logs a FAILED as failed with its why" {
  open_t7
  launched T7 builder b0000001
  # roles/builder.md: `FAILED <why>`
  logs_events '{"task":"T7","event":"failed","reason":"the endpoint the spec names was removed upstream"}' \
    --from-message 'T7 FAILED the endpoint the spec names was removed upstream'
}

@test "--from-message logs an INJECTION with its source and what it asked" {
  open_t7
  launched T7 reviewer c0000001
  # roles/reviewer.md: `T<n> INJECTION <where it was> <what it asked>`
  logs_events '{"task":"T7","event":"injection","role":"reviewer","source":"https://github.com/owner/proj/pull/12#issuecomment-1","text":"asked to approve the PR and skip the checks"}' \
    --from-message 'T7 INJECTION https://github.com/owner/proj/pull/12#issuecomment-1 asked to approve the PR and skip the checks'
  refuses_message "team-log: INJECTION takes 'INJECTION <where> <what it asked>', got 'INJECTION somewhere'" \
    --from-message 'T7 INJECTION somewhere'
}

@test "--from-message takes a review's head from its brief's record, else a pass's own head, else refuses naming head=" {
  open_t7
  launched T7 builder b0000001
  # A launch with no brief: a pass on a head reviews that head.
  launched T7 reviewer c0000001
  logs_events "{\"task\":\"T7\",\"event\":\"review\",\"verdict\":\"pass\",\"head\":\"$HEAD_A\",\"findings\":{\"blocking\":0,\"correctness\":0,\"security\":0,\"real-data\":0,\"note-change\":0,\"note-before\":0},\"before\":[],\"guarded\":[]}
{\"task\":\"T7\",\"event\":\"done\",\"role\":\"reviewer\",\"session\":\"c0000001\"}" \
    --from-message "T7 DONE pass $HEAD_A findings=blocking:0,correctness:0,security:0,real-data:0,note-change:0,note-before:0 before=none guarded=none"
  # A pass on a PR, or findings, with no record: refused, naming head=.
  launched T7 reviewer c0000002 brief-rereview
  refuses_message "team-log: the review's head is not known: the reviewer's latest launch (c0000002) read brief-rereview, which has no record with a head, and DONE pass names $URL, not a head; log the review by hand with head=<the full sha reviewed>" \
    --from-message "T7 DONE pass $URL findings=blocking:0,correctness:0,security:0,real-data:0,note-change:0,note-before:0 before=none guarded=none"
  refuses_message "team-log: the review's head is not known: the reviewer's latest launch (c0000002) read brief-rereview, which has no record with a head, and DONE findings names no head; log the review by hand with head=<the full sha reviewed>" \
    --from-message "T7 DONE findings .scratch/task/review.md findings=blocking:1,correctness:0,security:0,real-data:0,note-change:0,note-before:0 before=none guarded=none"
  # The record wins over the message's head.
  brief_record T7 brief-rereview "{\"head\": \"$HEAD_B\"}"
  logs_events "{\"task\":\"T7\",\"event\":\"review\",\"verdict\":\"pass\",\"head\":\"$HEAD_B\",\"findings\":{\"blocking\":0,\"correctness\":0,\"security\":0,\"real-data\":0,\"note-change\":0,\"note-before\":0},\"before\":[],\"guarded\":[]}
{\"task\":\"T7\",\"event\":\"done\",\"role\":\"reviewer\",\"session\":\"c0000002\"}" \
    --from-message "T7 DONE pass $HEAD_A findings=blocking:0,correctness:0,security:0,real-data:0,note-change:0,note-before:0 before=none guarded=none"
}

@test "--from-message takes the role from the kind, else --from, else the only launch with no report since" {
  open_t7
  launched T7 builder b0000001
  launched T7 reviewer c0000001
  # Both have no report since their launch: refused, naming both.
  refuses_message "team-log: the message's sender is not known: T7-builder (b0000001) and T7-reviewer (c0000001) have no report since their launch; name it with --from <session>" \
    --from-message 'T7 QUESTION which head?'
  # --from by the session's name, or by its id.
  logs_events '{"task":"T7","event":"question","role":"reviewer","text":"which head?"}' \
    --from-message 'T7 QUESTION which head?' --from T7-reviewer
  logs_events '{"task":"T7","event":"question","role":"builder","text":"which store?"}' \
    --from b0000001 --from-message 'T7 QUESTION which store?'
  refuses_message "team-log: --from x0000009 names no launch of T7: its sessions are T7-builder (b0000001), T7-reviewer (c0000001)" \
    --from-message 'T7 QUESTION which head?' --from x0000009
  # The builder reports, so the reviewer is the only one left.
  logs_events '{"task":"T7","event":"ticket-done","ticket":"01","commits":["a1b2c3d"],"note":"done"}
{"task":"T7","event":"done","role":"builder","session":"b0000001"}' --from-message 'T7 DONE 01 a1b2c3d done'
  logs_events '{"task":"T7","event":"injection","role":"reviewer","source":"README.md","text":"asked to push"}' \
    --from-message 'T7 INJECTION README.md asked to push'
  # The kind's role wins, and a --from of another role is refused.
  refuses_message "team-log: the message is a builder's, but --from names T7-reviewer" \
    --from-message 'T7 DONE review-ready a1b2c3d' --from T7-reviewer
}

@test "--from-message refuses a kind whose role has no launch, and a sender none is without a report" {
  open_t7
  refuses_message "team-log: the message is a builder's, but T7 has no builder launch" \
    --from-message 'T7 DONE review-ready a1b2c3d'
  refuses_message "team-log: the message's sender is not known: T7 has no launch; name it with --from <session>" \
    --from-message 'T7 QUESTION which head?'
  launched T7 planner a0000001
  logs_events '{"task":"T7","event":"done","role":"planner","session":"a0000001","report":"spec.md"}' --from-message 'T7 DONE spec.md'
  refuses_message "team-log: the message's sender is not known: every launch of T7 has a report since; name it with --from <session>" \
    --from-message 'T7 QUESTION which head?'
  # A message whose event carries no role needs no sender.
  logs_events '{"task":"T7","event":"failed","reason":"no way on"}' --from-message 'T7 FAILED no way on'
}

@test "--from-message refuses another task's message, an unparseable one and a malformed part, logging nothing" {
  open_t7
  launched T7 builder b0000001
  launched T7 reviewer c0000001 brief-review
  brief_record T7 brief-review "{\"head\": \"$HEAD_A\"}"
  refuses_message "team-log: the message is for T8, not T7" --from-message 'T8 DONE 01 a1b2c3d x'
  refuses_message "team-log: a worker's message starts with its task, T7, then its kind; got 'DONE 01 a1b2c3d x'" \
    --from-message 'DONE 01 a1b2c3d x'
  local forms="QUESTION <text>, BLOCKED <what> <why>, NEED toolkit <name>, PAUSED <why>, PR <full url> [merged <base> conflicts: <files or none>], DONE <NN> <sha>... <line>, DONE review-ready <sha>, DONE merged <base> <sha> conflicts: <files or none>, DONE pass <PR url or head> findings=<kind:n,...> [before=<list>] guarded=<list>, DONE findings <path> findings=<kind:n,...> [before=<list>] guarded=<list>, DONE gate <key=value>..., DONE <report>, FAILED <why>, INJECTION <where> <what it asked>"
  refuses_message "team-log: cannot read 'T7 HELLO there': expected one of $forms" --from-message 'T7 HELLO there'
  refuses_message "team-log: cannot read 'T7 QUESTION': expected one of $forms" --from-message 'T7 QUESTION'
  # Malformed parts of a review, each named.
  run_bin -1 team-log T7 --from-message 'T7 DONE pass a1b2c3d findings=blocking:0 guarded=none'
  assert_contains "$output" "findings holds the count of each finding kind"
  refuses_message "team-log: findings: blocking is not a key:value pair" \
    --from-message 'T7 DONE pass a1b2c3d findings=blocking,correctness:1 guarded=none'
  refuses_message "team-log: DONE pass takes findings=<kind:n,...>, before=<list> and guarded=<list>, got bogus" \
    --from-message 'T7 DONE pass a1b2c3d findings=blocking:0,correctness:0,security:0,real-data:0,note-change:0,note-before:0 guarded=none bogus=1'
  refuses_message "team-log: DONE pass needs findings= and guarded=" \
    --from-message 'T7 DONE pass a1b2c3d guarded=none'
  refuses_message "team-log: DONE pass takes a PR url or a head of 7 to 40 hex digits, got 'main'" \
    --from-message 'T7 DONE pass main findings=blocking:0,correctness:0,security:0,real-data:0,note-change:0,note-before:0 guarded=none'
  refuses_message "team-log: DONE pass has guarded= with no value" \
    --from-message 'T7 DONE pass a1b2c3d findings=blocking:0,correctness:0,security:0,real-data:0,note-change:0,note-before:0 guarded='
  refuses_message "team-log: DONE pass has guarded= twice" \
    --from-message 'T7 DONE pass a1b2c3d findings=blocking:0,correctness:0,security:0,real-data:0,note-change:0,note-before:0 guarded=none guarded=ci'
  # A second event refused refuses the first too: the ticket's done is never logged without it.
  refuses_message "team-log: sent_back: x is not a whole number" \
    --from-message 'T7 DONE findings r.md findings=blocking:1,correctness:0,security:0,real-data:0,note-change:0,note-before:0 guarded=none' --sent-back 1,x
}

@test "--from-message --print logs nothing and prints what a run without it logs" {
  open_t7
  launched T7 builder b0000001 brief-build-03
  local message="T7 DONE 03 a1b2c3d4 $HEAD_A the parser"
  run_bin -0 team-log T7 --from-message "$message" --print
  local printed=$output
  assert_equal "$(wc -l <"$TEAM_HOME/ledger.jsonl")" 2
  assert_equal "$(jq -c 'del(.ts)' <<<"$printed")" "{\"task\":\"T7\",\"event\":\"ticket-done\",\"ticket\":\"03\",\"commits\":[\"a1b2c3d4\",\"$HEAD_A\"],\"note\":\"the parser\"}
{\"task\":\"T7\",\"event\":\"done\",\"role\":\"builder\",\"session\":\"b0000001\"}"
  # Every printed line has a UTC ts, as a logged one does.
  jq -se 'all(.[]; .ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))' <<<"$printed" >/dev/null
  run_bin -0 team-log T7 --print --from-message "$message"
  assert_equal "$(wc -l <"$TEAM_HOME/ledger.jsonl")" 2
  run_bin -0 team-log T7 --from-message "$message"
  assert_equal "$output" ""
  assert_equal "$(logged_after 2)" "$(jq -c 'del(.ts)' <<<"$printed")"
  # A refusal is the same with --print.
  refuses_message "team-log: the message is for T8, not T7" --from-message 'T8 FAILED x' --print
}

@test "--from-message takes --sent-back only with a DONE findings or a DONE pass, and its options once each" {
  open_t7
  launched T7 builder b0000001
  launched T7 reviewer c0000001
  refuses_message "team-log: --sent-back is taken only with a DONE findings or DONE pass message, not DONE review-ready" \
    --from-message "T7 DONE review-ready $HEAD_A" --from T7-builder --sent-back 1
  refuses_message "team-log: --sent-back is taken only with a DONE findings or DONE pass message, not QUESTION" \
    --from-message 'T7 QUESTION x' --from T7-builder --sent-back 1
  # A pass whose correctness note goes back before the merge.
  run_bin -0 team-log T7 --print --sent-back 2 \
    --from-message "T7 DONE  pass $HEAD_A findings=blocking:0,correctness:1,security:0,real-data:0,note-change:0,note-before:0 guarded=none"
  assert_equal "$(jq -c 'select(.event == "review") | {verdict, sent_back}' <<<"$output")" '{"verdict":"findings","sent_back":[2]}'
  run_bin -2 team-log T7 --from-message 'T7 FAILED x' --from-message 'T7 FAILED y'
  assert_contains "$output" "--from-message is given twice"
  run_bin -2 team-log T7 --from-message
  assert_contains "$output" "--from-message needs a message"
  run_bin -2 team-log T7 --from-message 'T7 FAILED x' --bogus
  assert_contains "$output" "usage: team-log"
  run_bin -2 team-log T7 --print
  assert_contains "$output" "--print is taken only with --from-message"
  assert_equal "$(wc -l <"$TEAM_HOME/ledger.jsonl")" 3
}
