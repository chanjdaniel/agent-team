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
stowed team-handoff machine worktrees roles
worktree-moved team-open project branch from worktree machine
injection team-log role source text
rehome-failed team-resume project branch machine reason
rehomed team-open project branch worktree machine
TABLE
  )
  actual=$(jq -r '.kinds | to_entries[] | [.key, ([.value.writer] | flatten | join(",")), (.value.required | keys_unsorted[])] | join(" ")' "$CONTRACT")
  assert_equal "$actual" "$expected"
  assert_equal "$(jq -c '.kinds.launch.optional' "$CONTRACT")" '{"project":"string","branch":"string","machine":"string","model":"string","request":"string"}'
  assert_equal "$(jq -c '.kinds.review.required.verdict' "$CONTRACT")" '["pass","findings"]'
  assert_equal "$(jq -c '.kinds.answered.optional' "$CONTRACT")" '{"discord_message":"id"}'
  assert_equal "$(jq -c '[.kinds[] | (.required, .optional // {}) | to_entries[] | select(.key | startswith("discord_")) | .value] | unique' "$CONTRACT")" '["id"]'
  assert_equal "$(jq -c '[.kinds.waiting, .kinds.blocked, .kinds.paused, .kinds.held | .optional.since]' "$CONTRACT")" '["string","string","string","string"]'
  assert_equal "$(jq -c '[.kinds.closed.required[]]' "$CONTRACT")" '["array","array","array"]'
  assert_equal "$(jq -c '.kinds["merge-preapproved"].required' "$CONTRACT")" '{"project":"string","ask":"string","discord_message":"id","scope":"array"}'
  assert_equal "$(jq -c '.kinds.review.optional' "$CONTRACT")" '{"agent_review":"string","sent_back":"array","findings":"object","before":"array","guarded":"array"}'
  assert_equal "$(jq -c '.kinds.merged.optional.approval' "$CONTRACT")" '["head","plan"]'
  [[ $STRICT_FROM =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "--help prints the header and the contract as a table" {
  run_bin -0 team-log --help
  assert_equal "${lines[0]}" "$(sed -n '2s/^# //p' "$REPO_ROOT/bin/team-log")"
  assert_contains "$output" "Ledger contract, strict from $STRICT_FROM"
  local kind
  for kind in $(jq -r '.kinds | keys_unsorted[]' "$CONTRACT"); do
    grep -Eq "^  $kind +[a-z-]+(, [a-z-]+)* " <<<"$output" || {
      echo "no row for $kind" >&2
      return 1
    }
  done
  grep -Eq '^  opened +team-open +project, path, type, title, branch, base, base_sha, worktree$' <<<"$output"
  grep -Eq '^  review +team-log +verdict \(pass\|findings\), head; optional agent_review, sent_back \(list\), findings \(object\), before \(list\), guarded \(list\)  \(sent_back: the numbers of the findings sent back .*findings: the count of each kind.*before: the numbers of the plain notes .*guarded: the guarded areas.*\)$' <<<"$output"
  grep -Eq '^  merge-preapproved +team-log +project, ask, discord_message \(id\), scope \(list\)  \(Daniel.s plan-time word .*\)$' <<<"$output"
  grep -Eq '^  merge-preapproval-withdrawn +team-log +project, discord_message \(id\)  \(.*withdr.*\)$' <<<"$output"
  grep -Eq '^  merged +team-merge +pr \(number\), merge, head, by; optional .*approval \(head\|plan\)  \(approval: .*\)$' <<<"$output"
  grep -Eq '^  gate-run +team-log +run, head, outcome \(pushed\|red\|aborted\|stopped-green\); optional cause \(review\|notes\|gate-finding\|load\|tooling\|base-merge\|other\), minutes \(object\)  \(.*\)$' <<<"$output"
  grep -Eq '^  closed +team-close +archive \(list\), returned \(list\), kept \(list\)  \(.*legacy.*\)$' <<<"$output"
  grep -Eq '^  merge-approved +team-log +url, discord_message \(id\); optional head  \(.*team-log requires head of every new line.*\)$' <<<"$output"
  grep -Eq '^  launch +team-worker +role, session, worktree, toolkits \(list\); optional project, branch, machine, model, request  \(request is the link to Daniel.s Discord message, on an ops launch; model is the --model the session launched on, .*\)$' <<<"$output"
  grep -Eq '^  answered +team-log, team-answer +id, answer; optional discord_message \(id\)  \(Daniel.s answer to the asked of its id; .*never logged twice for one ask\)$' <<<"$output"
  grep -Eq '^  waiting +team-log, team-ask +on, reason; optional since  \(.*\)$' <<<"$output"
  grep -Eq '^  resumed +team-log, team-answer +- +\(clears held, blocked, paused and waiting\)$' <<<"$output"
  grep -Eq '^  blocked +team-log +reason; optional since  \(.*since: when the park began, when it is logged after the fact\)$' <<<"$output"
  grep -Eq '^  retro-schedule +team-log +every_hours \(number\), discord_message \(id\)  \(.*every_hours 0 stops.*\)$' <<<"$output"
  grep -Eq '^  injection +team-log +role, source, text  \(.*never the personal details.*\)$' <<<"$output"
  grep -Eq '^  stowed +team-handoff +machine, worktrees \(list\), roles \(list\); optional sessions \(list\)  \(one per open task at a handoff: .*unfinished_roles.*\)$' <<<"$output"
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
  run_bin -0 team-log T14 review verdict=pass head=a1b2c3d 'sent_back=[2, 4]'
  run_bin -0 team-log T14 review verdict=pass head=e4f5a6b
  assert_equal "$(ledger_without_ts)" "$(
    cat <<'LINES'
{"task":"T14","event":"review","verdict":"pass","head":"a1b2c3d","sent_back":[2,4]}
{"task":"T14","event":"review","verdict":"pass","head":"e4f5a6b"}
LINES
  )"
  local value
  for value in 2 'note 2' '{"2":1}'; do
    run_bin -1 team-log T14 review verdict=pass head=a1b2c3d "sent_back=$value"
    assert_contains "$output" "sent_back must be a list, got"
  done
  assert_equal "$(wc -l <"$TEAM_HOME/ledger.jsonl")" "2"
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
  run_bin -1 team-log T14 gate-run run=01M5Q9GR head=a1b2c3d outcome=red minutes=44
  assert_contains "$output" "minutes must be an object, got a number"
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
  assert_equal "$count" "21"
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
  run_bin -1 team-log T14 ticket-done ticket=03 commits=a1b2c3d
  assert_contains "$output" "commits must be a list, got a string"
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
  run_bin -1 team-log T14 merge-preapproved project=proj ask=plan discord_message="$(soon)" scope=src/
  assert_contains "$output" "scope must be a list, got a string"
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

  run_bin -1 team-log T14 review verdict=pass head=a1b2c3d findings=3
  assert_contains "$output" "findings must be an object, got a number"
  run_bin -1 team-log T14 review verdict=pass head=a1b2c3d \
    'findings={"blocking": 0, "correctness": -1, "security": 1.5, "note-change": "2", "note-before": 0, "note": 1}'
  assert_equal "$output" "team-log: findings holds the count of each finding kind, exactly blocking, correctness, security, real-data, note-change and note-before, each a whole number:
  correctness: -1 is not a whole number
  security: 1.5 is not a whole number
  note-change: \"2\" is not a whole number
  real-data: missing
  note: not a finding kind"
  run_bin -1 team-log T14 review verdict=pass head=a1b2c3d guarded=ci
  assert_contains "$output" "guarded must be a list, got a string"
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
  run_bin -1 team-log T14 review verdict=findings head=a1b2c3d before=3
  assert_contains "$output" "before must be a list, got a number"
  run_bin -1 team-log T14 review verdict=findings head=a1b2c3d 'before=[0, 2.5, "3", 4, 4]'
  assert_equal "$output" "team-log: before lists the numbers of the plain notes on code the PR did not change, each a whole number above 0, once:
  0: not a finding number
  2.5: not a finding number
  \"3\": not a finding number
  4: listed twice"
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
