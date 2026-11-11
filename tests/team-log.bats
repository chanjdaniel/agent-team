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

# A code checkout of tools, at owner/tools, for run_bin to run team-log from, so the team's own
# project is mirror by its repo and tools by its path: own_by_repo_and_path <merge_with_plan>
own_by_repo_and_path() {
  export CODE_CHECKOUT
  CODE_CHECKOUT=$(make_repo tools dev)
  copy_bin "$CODE_CHECKOUT/bin"
  git -C "$CODE_CHECKOUT" remote set-url origin git@github.com:Owner/Tools.git
  plan_registry "$(plan_project mirror "$1" owner/tools && echo && plan_project tools false owner/elsewhere)"
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

# #coordinator's channel in the sandbox, the library's default.
COORDINATOR=1562486564871995482

# A thread of the task, as team-thread logs it: thread <task> <id>
thread() {
  jq -cn --arg task "$1" --arg id "$2" '{ts: (now | todate), task: $task, event: "thread", discord_thread: $id}' \
    >>"$TEAM_HOME/ledger.jsonl"
}

# The standing words and withdrawals logged, one "<event> <project>" per line.
standing_events() {
  jq -r 'select(.event | startswith("merge-standing")) | "\(.event) \(.project)"' "$TEAM_HOME/ledger.jsonl"
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
gate-lane-cleared team-clean-messages branch head tag
caught-up team-catch-up url from head base
done team-log role session
ticket-done team-log ticket commits
question team-log,team-ask role
asked team-log,team-ask id text
answered team-log,team-answer id answer
ran team-run-approved id exit
plan-approved team-log by
paused team-log,team-worker reason
blocked team-log reason
denied team-log,denial-log role what why
held team-log reason
waiting team-log,team-ask on reason
resumed team-log,team-answer
pr team-log url head
review team-log verdict head
gate-run team-log run head outcome
merge-approved team-log url discord_message
merge-preapproved team-log project ask discord_message scope
merge-preapproval-withdrawn team-log project discord_message
merge-standing team-log project discord_message discord_channel
merge-standing-withdrawn team-log project discord_message discord_channel
branch-renamed team-log project branch
failed team-log reason
retro-schedule team-log every_hours discord_message
retro-change team-log retro proposals
stowing team-stow machine cause roles
stowed team-stow machine worktrees roles
stow-failed team-stow machine reason
worktree-moved team-open project branch from worktree machine
injection team-log role source text
rehome-failed team-resume project branch machine reason
rehomed team-open project branch worktree machine
walk team-ui state
image-posted team-post thread discord_thread discord_message file
image-retracted team-post thread discord_thread discord_message
TABLE
  )
  actual=$(jq -r '.kinds | to_entries[] | [.key, ([.value.writer] | flatten | join(",")), (.value.required | keys_unsorted[])] | join(" ")' "$CONTRACT")
  assert_equal "$actual" "$expected"
  assert_equal "$(jq -c '.kinds.launch.optional' "$CONTRACT")" '{"project":"string","branch":"string","machine":"string","model":"string","request":"string","discord_message":"id","brief":"string","template":"string","admission":"string","past_ask":"array"}'
  assert_equal "$(jq -c '.kinds.review.required.verdict' "$CONTRACT")" '["pass","findings"]'
  assert_equal "$(jq -c '.kinds.answered.optional' "$CONTRACT")" '{"discord_message":"id","item":"number"}'
  assert_equal "$(jq -c '.kinds.asked.optional' "$CONTRACT")" '{"discord_message":"id","script":"string","sha256":"string"}'
  assert_equal "$(jq -c '.kinds.ran.required' "$CONTRACT")" '{"id":"string","exit":"number"}'
  assert_equal "$(jq -c '.kinds.done.optional' "$CONTRACT")" '{"report":"string","report_chars":"number","relay":"id"}'
  assert_equal "$(jq -c '.kinds.question | [.optional, .one_of]' "$CONTRACT")" '[{"text":"string","chars":"number","discord_message":"id"},[["text","chars"]]]'
  assert_equal "$(jq -c '[.kinds[] | (.required, .optional // {}) | to_entries[] | select(.key | startswith("discord_")) | .value] | unique' "$CONTRACT")" '["id"]'
  assert_equal "$(jq -c '[.kinds.waiting, .kinds.blocked, .kinds.paused, .kinds.held | .optional.since]' "$CONTRACT")" '["string","string","string","string"]'
  # Each park kind's cause, its choices bin/lib/lifecycle.json's causes of the kind, and the fields
  # beside it: Daniel's message on a held, the ask on a waiting, the worker on a blocked and a paused.
  assert_equal "$(jq -c '[.kinds.held, .kinds.waiting, .kinds.blocked, .kinds.paused | .optional | del(.since)]' "$CONTRACT")" \
    '[{"cause":["daniel-hold"],"discord_message":"id","head":"string"},{"cause":["ask","daniel","outside"],"ask":"string"},{"cause":["task","worker","denial"],"role":"string","session":"string"},{"cause":["worker","room","stow","coordinator-hold","offline","limit","machine","shutdown"],"role":"string","session":"string","brief":"string"}]'
  assert_equal "$(jq -c '[.kinds.closed.required[]]' "$CONTRACT")" '["array","array","array"]'
  assert_equal "$(jq -c '.kinds["merge-preapproved"].required' "$CONTRACT")" '{"project":"string","ask":"string","discord_message":"id","scope":"array"}'
  assert_equal "$(jq -c '[.kinds["merge-standing", "merge-standing-withdrawn"].required]' "$CONTRACT")" \
    '[{"project":"string","discord_message":"id","discord_channel":"id"},{"project":"string","discord_message":"id","discord_channel":"id"}]'
  assert_equal "$(jq -c '.kinds.review.optional' "$CONTRACT")" '{"agent_review":"string","sent_back":"numbers","findings":"object","before":"numbers","guarded":"array","widening":"numbers","memory":"string"}'
  assert_equal "$(jq -c '.kinds.merged.optional.approval' "$CONTRACT")" '["head","plan","standing"]'
  assert_equal "$(jq -c '.kinds.walk.required.state' "$CONTRACT")" '["on","off"]'
  [[ $STRICT_FROM =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "--help prints the header and the contract as a table" {
  run_bin -0 team-log --help
  assert_equal "${lines[0]}" "$(sed -n '2s/^# //p' "$REPO_ROOT/bin/team-log")"
  assert_contains "$output" "Ledger contract, strict from $STRICT_FROM"
  # The forms a list and an object take, the whole numbers' type and the one-time conversion.
  assert_contains "$output" "Usage: team-log T<n> <event> [key=value]...
       team-log T<n> --from-message '<message>' [--from <session>] [--sent-back <list>] [--relay <id>] [--print]
       team-log --check [<file>]
       team-log --check-lifecycle [<file>]
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
  grep -Eq '^  review +team-log +verdict \(pass\|findings\), head; optional agent_review, sent_back \(list of whole numbers\), findings \(object\), before \(list of whole numbers\), guarded \(list\), widening \(list of whole numbers\), memory  \(verdict: findings whenever sent_back names a finding, whatever the reviewer.s word, .*sent_back: the numbers of the findings sent back .*findings: the count of each kind.*before: the numbers of the plain notes .*guarded: the guarded areas.*widening: the numbers of the new findings that sit in what the last fix added for an earlier finding, so reverting that fix would end them, as a rereview marks them; empty for none; memory: the file in the task directory of the memories.*\)$' <<<"$output"
  grep -Eq '^  merge-preapproved +team-log +project, ask, discord_message \(id\), scope \(list\); pushed at once  \(Daniel.s plan-time word .*\)$' <<<"$output"
  grep -Eq '^  merge-preapproval-withdrawn +team-log +project, discord_message \(id\); pushed at once  \(.*withdr.*\)$' <<<"$output"
  grep -Eq '^  merge-standing +team-log +project, discord_message \(id\), discord_channel \(id\); pushed at once  \(Daniel.s standing word .*never the team.s own \(own_project\), which team-log refuses, or of every other project when project is all.*across the whole ledger.*the latest merge-standing or merge-standing-withdrawn whose project is .* or all decides.*stands when that is a merge-standing.*\)$' <<<"$output"
  grep -Eq '^  merge-standing-withdrawn +team-log +project, discord_message \(id\), discord_channel \(id\); pushed at once  \(Daniel withdrew .*standing word.*every project but the team.s own when project is all.*across the whole ledger.*\)$' <<<"$output"
  grep -Eq '^  merged +team-merge +pr \(number\), merge, head, by; optional .*approval \(head\|plan\|standing\), phases_left \(list of whole numbers\); pushed at once  \(approval: .*\)$' <<<"$output"
  grep -Eq '^  gate-run +team-log +run, head, outcome \(pushed\|red\|aborted\|stopped-green\); optional cause \(review\|notes\|gate-finding\|load\|tooling\|base-merge\|other\), minutes \(object\), approved \(list\)  \(.*approved the ids of the parks the builder approved itself.*\)$' <<<"$output"
  grep -Eq '^  closed +team-close +archive \(list\), returned \(list\), kept \(list\); pushed at once  \(.*legacy.*\)$' <<<"$output"
  grep -Eq '^  walk +team-ui +state \(on\|off\)  \(a manual QC walk of the task.*team-ui --walk.*\)$' <<<"$output"
  grep -Eq '^  merge-approved +team-log +url, discord_message \(id\); optional head; pushed at once  \(.*team-log requires head of every new line.*\)$' <<<"$output"
  grep -Eq '^  launch +team-worker +role, session, worktree, toolkits \(list\); optional project, branch, machine, model, request, discord_message \(id\), brief, template, admission, past_ask \(list\)  \(request is the link to Daniel.s Discord message, on an ops launch, and discord_message its id, a message no other ops launch ran on \(team-worker refuses one that did\), which only an ops launch carries; model is the --model the session launched on, .*; admission is the id of the capacity admission the launch was made on \(team-capacity admit.s first line\), absent on T0, ops and a launch from before 2026-11-11; past_ask is the ids of the open asks the launch went past \(team-worker --past-ask\), which then park nothing, absent when it names none\)$' <<<"$output"
  grep -Eq '^  answered +team-log, team-answer +id, answer; optional discord_message \(id\), item \(number\); pushed at once  \(Daniel.s answer to the asked of its id; .*never logged twice for one ask; item: .*team-answer --item alone\)$' <<<"$output"
  grep -Eq '^  asked +team-log, team-ask +id, text; optional discord_message \(id\), script, sha256  \(a decision put to Daniel; .*script and sha256: .*together.*team-run-approved.*\)$' <<<"$output"
  grep -Eq '^  ran +team-run-approved +id, exit \(number\); pushed at once  \(.*\)$' <<<"$output"
  grep -Eq '^  waiting +team-log, team-ask +on, reason; optional cause \(ask\|daniel\|outside\), ask, since  \(.*cause: why, .*daniel when on is Daniel.*\)$' <<<"$output"
  grep -Eq '^  resumed +team-log, team-answer +-; optional id, all \(boolean\), discord_message \(id\), brief +\(ends standing parks, by bin/lib/lifecycle.json.s causes: id, .*all true, .*brief alone, .*ends none; .*\)$' <<<"$output"
  grep -Eq '^  blocked +team-log +reason; optional cause \(task\|worker\|denial\), role, session, since  \(.*since: when the park began, when it is logged after the fact\)$' <<<"$output"
  grep -Eq '^  held +team-log +reason; optional cause \(daniel-hold\), discord_message \(id\), head, since  \(Daniel.s hold on the task; .*\)$' <<<"$output"
  grep -Eq '^  paused +team-log, team-worker +reason; optional cause \(worker\|room\|stow\|coordinator-hold\|offline\|limit\|machine\|shutdown\), role, session, brief, since  \(.*\)$' <<<"$output"
  grep -Eq '^  denied +team-log, denial-log +role, what, why; optional session  \(a denial the worker went past .*parks nothing and clears nothing.*a denial that stops the work is a blocked; denial-log, every worker.s PermissionDenied hook, .*never the tool.s input\)$' <<<"$output"
  grep -Eq '^  retro-schedule +team-log +every_hours \(number\), discord_message \(id\); pushed at once  \(.*every_hours 0 stops.*\)$' <<<"$output"
  grep -Eq '^  retro-change +team-log +retro, proposals  \(the task it is logged on builds those proposals of retro T<m>, or, logged on T<m> itself, records were changed in place for them; .*team-retro digest.*\)$' <<<"$output"
  grep -Eq '^  injection +team-log +role, source, text  \(.*never the personal details.*\)$' <<<"$output"
  grep -Eq '^  stowed +team-stow +machine, worktrees \(list\), roles \(list\); optional sessions \(list\), cause \(level\|handoff\)  \(one per task team-stow stows, every open task at a handoff .*unfinished_roles.*\)$' <<<"$output"
  grep -Eq '^  stowing +team-stow +machine, cause \(level\|handoff\), roles \(list\)  \(a stow of the task under way on machine, logged by team-stow --begin .*stands until the task.s stowed or stow-failed, or a launch.*\)$' <<<"$output"
  grep -Eq '^  stow-failed +team-stow +machine, reason  \(a stow of the task under way .*the run stopped: <its last error line>.*read as stowed with the stowing.s roles.*\)$' <<<"$output"
  grep -Eq '^  rehome-failed +team-resume +project, branch, machine, reason  \(.*stands until a later opened, worktree-added, worktree-moved, rehomed or worktree-returned.*\)$' <<<"$output"
  assert_equal "$(stub_calls curl)$(stub_calls gh)" ""
}

@test "an event is appended as one line with ts now, task and event" {
  opened_task T14
  local before after
  before=$(date -u +%FT%TZ)
  run_bin -0 team-log T14 pr url=https://github.com/chanjdaniel/agent-team/pull/5 head=a1b2c3d
  after=$(date -u +%FT%TZ)
  assert_equal "$output" ""
  assert_equal "$(logged_after 2 | wc -l)" "1"
  assert_equal "$(logged_after 2)" \
    '{"task":"T14","event":"pr","url":"https://github.com/chanjdaniel/agent-team/pull/5","head":"a1b2c3d"}'
  local ts
  ts=$(tail -n 1 "$TEAM_HOME/ledger.jsonl" | jq -r .ts)
  [[ $ts =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
  [[ ! $ts < $before && ! $ts > $after ]]

  run_bin -0 team-log T14 resumed all=true
  assert_equal "$(logged_after 2 | wc -l)" "2"
  assert_equal "$(tail -n 1 "$TEAM_HOME/ledger.jsonl" | jq -c 'del(.ts)')" '{"task":"T14","event":"resumed","all":true}'
}

@test "values that parse as JSON are stored as JSON, others as strings" {
  opened_task T14
  run_bin -0 team-log T14 ticket-done ticket=03 'commits=["a1b2c3d", "e4f5a6b"]' count=3 ok=true \
    'extra={"a":1}' 'quoted="7"' 'note=two words, [not a list' nan=nan nothing=null
  assert_equal "$(logged_after 2)" \
    '{"task":"T14","event":"ticket-done","ticket":"03","commits":["a1b2c3d","e4f5a6b"],"count":3,"ok":true,"extra":{"a":1},"quoted":"7","note":"two words, [not a list","nan":"nan","nothing":"null"}'
}

@test "a review names the notes sent back before the merge as a list, which a non-list cannot be" {
  opened_task T14
  run_bin -0 team-log T14 review verdict=findings head=a1b2c3d 'sent_back=[2, 4]'
  run_bin -0 team-log T14 review verdict=pass head=e4f5a6b
  assert_equal "$(logged_after 2)" "$(
    cat <<'LINES'
{"task":"T14","event":"review","verdict":"findings","head":"a1b2c3d","sent_back":[2,4]}
{"task":"T14","event":"review","verdict":"pass","head":"e4f5a6b"}
LINES
  )"
  run_bin -1 team-log T14 review verdict=pass head=a1b2c3d 'sent_back={"2":1}'
  assert_contains "$output" "sent_back must be a list of whole numbers, got an object"
  run_bin -1 team-log T14 review verdict=pass head=a1b2c3d 'sent_back=note 2'
  assert_equal "$output" "team-log: sent_back: note 2 is not a whole number"
  assert_equal "$(logged_after 2 | wc -l)" "2"
}

@test "a list field takes a comma list, each item trimmed, none for the empty list, and refuses an empty item" {
  opened_task T14
  run_bin -0 team-log T14 ticket-done ticket=03 commits=a0017cce,9e0e3990
  run_bin -0 team-log T14 ticket-done ticket=04 'commits= a0017cce , 9e0e3990 '
  run_bin -0 team-log T14 ticket-done ticket=05 commits=1234567
  run_bin -0 team-log T14 review verdict=findings head=a1b2c3d sent_back=5,6 guarded=ci,settings before=none
  run_bin -0 team-log T14 review verdict=pass head=e4f5a6b sent_back=none guarded=none
  assert_equal "$(logged_after 2)" "$(
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
  assert_equal "$(logged_after 2 | wc -l)" "5"
}

@test "an object field takes key:value pairs, logged as the same object as its JSON form, and the finding kinds hold for both" {
  opened_task T14
  local kinds='blocking:0,correctness:1,security:0,real-data:0,note-change:2,note-before:1'
  run_bin -0 team-log T14 review verdict=pass head=a1b2c3d "findings=$kinds" before=4 guarded=none
  run_bin -0 team-log T14 review verdict=pass head=a1b2c3d \
    'findings={"blocking": 0, "correctness": 1, "security": 0, "real-data": 0, "note-change": 2, "note-before": 1}' 'before=[4]' 'guarded=[]'
  assert_equal "$(sed -n 3p "$TEAM_HOME/ledger.jsonl" | jq -c 'del(.ts)')" \
    '{"task":"T14","event":"review","verdict":"pass","head":"a1b2c3d","findings":{"blocking":0,"correctness":1,"security":0,"real-data":0,"note-change":2,"note-before":1},"before":[4],"guarded":[]}'
  assert_equal "$(sed -n 4p "$TEAM_HOME/ledger.jsonl" | jq -c 'del(.ts)')" "$(sed -n 3p "$TEAM_HOME/ledger.jsonl" | jq -c 'del(.ts)')"
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
  assert_equal "$(logged_after 2 | wc -l)" "3"
}

@test "sent_back is stored as whole numbers from a comma list or a JSON list, and anything else is refused naming it" {
  opened_task T14
  run_bin -0 team-log T14 review verdict=findings head=a1b2c3d 'sent_back=["5",6]'
  run_bin -0 team-log T14 review verdict=findings head=a1b2c3d sent_back=5,6
  run_bin -0 team-log T14 review verdict=findings head=a1b2c3d sent_back=07
  assert_equal "$(logged_after 2 | jq -c .sent_back)" '[5,6]
[5,6]
[7]'
  run_bin -0 team-log --check

  run_bin -1 team-log T14 review verdict=findings head=a1b2c3d sent_back=5a
  assert_equal "$output" "team-log: sent_back: 5a is not a whole number"
  run_bin -1 team-log T14 review verdict=findings head=a1b2c3d sent_back=5,5a,-1
  assert_equal "$output" "team-log: sent_back: 5a is not a whole number; sent_back: -1 is not a whole number"
  run_bin -1 team-log T14 review verdict=findings head=a1b2c3d 'sent_back=["5a", 1.5, true, null]'
  assert_equal "$output" "team-log: sent_back: 5a is not a whole number; sent_back: 1.5 is not a whole number; sent_back: true is not a whole number; sent_back: null is not a whole number"
  assert_equal "$(logged_after 2 | wc -l)" "3"
}

@test "a gate run is logged with its run, head and outcome, the cause of a re-run and its minutes per step" {
  opened_task T14
  run_bin -0 team-log T14 gate-run run=01M5Q9GR head=a1b2c3d outcome=pushed \
    'minutes={"review": 3.0, "test": 49.9, "document": 0.6, "push": 0.4, "ci": 9.0}'
  run_bin -0 team-log T14 gate-run run=01M5QDHG head=e4f5a6b outcome=stopped-green cause=notes
  run_bin -0 team-log T14 gate-run run=01M5REA0 head=e4f5a6b outcome=red cause=load
  assert_equal "$(logged_after 2)" "$(
    cat <<'LINES'
{"task":"T14","event":"gate-run","run":"01M5Q9GR","head":"a1b2c3d","outcome":"pushed","minutes":{"review":3.0,"test":49.9,"document":0.6,"push":0.4,"ci":9.0}}
{"task":"T14","event":"gate-run","run":"01M5QDHG","head":"e4f5a6b","outcome":"stopped-green","cause":"notes"}
{"task":"T14","event":"gate-run","run":"01M5REA0","head":"e4f5a6b","outcome":"red","cause":"load"}
LINES
  )"
  run_bin -0 team-log --check
}

@test "a gate run that re-gates a base merge is logged all the same, with one line saying the brief asks for no such run" {
  opened_task T14
  local said="team-log: T14 gate run 01M5Q9GR re-gates a base merge, which the gated delivery brief asks no gate run for: a merge of the base is re-reviewed and checked by CI"
  run_bin -0 --separate-stderr team-log T14 gate-run run=01M5Q9GR head=a1b2c3d outcome=pushed cause=base-merge
  assert_equal "$output" ""
  assert_equal "$stderr" "$said"
  run_bin -0 --separate-stderr team-log T14 gate-run run=01M5QDHG head=a1b2c3d outcome=red cause=base-merge
  assert_equal "$stderr" "${said//01M5Q9GR/01M5QDHG}"
  # A run the base's move aborted says nothing more, nor does any other cause.
  run_bin -0 --separate-stderr team-log T14 gate-run run=01M5REA0 head=e4f5a6b outcome=aborted cause=base-merge
  assert_equal "$output$stderr" ""
  run_bin -0 --separate-stderr team-log T14 gate-run run=01M5REA1 head=e4f5a6b outcome=pushed cause=review
  assert_equal "$output$stderr" ""
  assert_equal "$(logged_after 2 | jq -r '"\(.run) \(.outcome) \(.cause)"')" "$(
    printf '%s\n' "01M5Q9GR pushed base-merge" "01M5QDHG red base-merge" "01M5REA0 aborted base-merge" "01M5REA1 pushed review"
  )"
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
  opened_task T14
  run_bin -0 team-log T14 ticket-done ticket=12 'commits=["1234567"]'
  run_bin -0 team-log T14 pr url=https://github.com/chanjdaniel/agent-team/pull/5 head=1234567 note=true
  run_bin -0 team-log T14 merge-approved url=https://github.com/chanjdaniel/agent-team/pull/5 discord_message=1563000000000000123456789 head=1234567
  assert_equal "$(logged_after 2)" "$(
    cat <<'LINES'
{"task":"T14","event":"ticket-done","ticket":"12","commits":["1234567"]}
{"task":"T14","event":"pr","url":"https://github.com/chanjdaniel/agent-team/pull/5","head":"1234567","note":"true"}
{"task":"T14","event":"merge-approved","url":"https://github.com/chanjdaniel/agent-team/pull/5","discord_message":"1563000000000000123456789","head":"1234567"}
LINES
  )"
}

@test "a Discord id is stored as a string, declared or not, and so is any whole number of 16 digits or more" {
  opened_task T14
  run_bin -0 team-log T14 asked id=q1 text=Which? discord_message=1564584780744491089
  run_bin -0 team-log T14 resumed all=true discord_channel=1562486564871995482 ref=1565336870932582522 count=42 big=999999999999999
  assert_equal "$(logged_after 2)" "$(
    cat <<'LINES'
{"task":"T14","event":"asked","id":"q1","text":"Which?","discord_message":"1564584780744491089"}
{"task":"T14","event":"resumed","all":true,"discord_channel":"1562486564871995482","ref":"1565336870932582522","count":42,"big":999999999999999}
LINES
  )"
  # A declared id is a string of digits: anything else is refused.
  run_bin -1 team-log T14 asked id=q2 text=Which? discord_message=m1563
  assert_contains "$output" "discord_message must be a Discord id, a string of digits, got a string that is not one"
  assert_equal "$(logged_after 2 | wc -l)" "2"
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
}

@test "every kind team-log writes is appended with its required fields and a note" {
  # merge-preapproved names a project of the task that opts in, and an ask it logged before;
  # branch-renamed a new branch of it that names the task; merge-standing #coordinator's channel,
  # and merge-standing-withdrawn, after it, the word it logged; retro-change a retro Daniel answered;
  # a kind with one_of sets the first field of each (a question its text); a paused its cause, a
  # held Daniel's message and a resumed all=true, which team-log requires of each.
  plan_registry
  opened T14 proj
  a_retro T150 answered
  local kind args count=0
  while IFS= read -r kind; do
    # A head is a sha, since merge-approved's must be one a pr event logged, which team-log adds.
    mapfile -t args < <(jq -r --arg k "$kind" --arg soon "$(soon)" --arg coordinator "$COORDINATOR" '(.kinds[$k].required | to_entries[]
      | "\(.key)=\(if .key == "head" then "a1b2c3d4" elif .key == "project" then "proj" elif .key == "ask" then "x y"
          elif .key == "scope" then "[\"src/\"]" elif .key == "branch" then "feat/T14-x-fresh"
          elif .key == "retro" then "T150"
          elif .key == "discord_channel" then $coordinator
          else .value | if type == "array" then .[0] elif . == "array" then "[]" elif . == "number" then "7" elif . == "id" then $soon else "x y" end end)"),
      (select($k == "merge-approved") | "head=a1b2c3d4"),
      (select($k == "paused") | "cause=limit"), (select($k == "held") | "discord_message=\($soon)"),
      (select($k == "resumed") | "all=true"),
      (.kinds[$k].one_of // [] | .[] | "\(.[0])=x y")' "$CONTRACT")
    run_bin -0 team-log T14 "$kind" "${args[@]}" "note=why $kind"
    count=$((count + 1))
    assert_equal "$(tail -n 1 "$TEAM_HOME/ledger.jsonl" | jq -r '.event + " " + .note')" "$kind why $kind"
  done < <(jq -r '.kinds | to_entries[] | select([.value.writer] | flatten | index("team-log")) | .key' "$CONTRACT")
  assert_equal "$count" "25"
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
  opened_task T26
  run_bin -1 team-log T26 denied role=builder 'what=Bash'
  assert_contains "$output" "denied needs why"
  run_bin -1 team-log T26 denied 'what=Bash' 'why=[deny rule] git reset * --hard*'
  assert_contains "$output" "denied needs role"
  run_bin -1 team-log T26 denied role=builder 'why=no verdict'
  assert_contains "$output" "denied needs what"
  assert_equal "$(logged_after 2)" ""
  run_bin -0 team-log T26 denied role=builder session=4f2a9c1e what=Bash 'why=[deny rule] git reset * --hard*'
  assert_equal "$(logged_after 2)" \
    '{"task":"T26","event":"denied","role":"builder","session":"4f2a9c1e","what":"Bash","why":"[deny rule] git reset * --hard*"}'
  run_bin -0 team-log --check
}

@test "injection records where outside text asked a worker to act, and what it asked" {
  opened_task T26
  run_bin -0 team-log T26 injection role=builder 'source=https://github.com/chanjdaniel/agent-team/pull/9#issuecomment-1' \
    'text=asked to push to dev and skip the hooks'
  assert_equal "$(logged_after 2)" \
    '{"task":"T26","event":"injection","role":"builder","source":"https://github.com/chanjdaniel/agent-team/pull/9#issuecomment-1","text":"asked to push to dev and skip the hooks"}'
  run_bin -0 team-log --check
}

@test "retro-schedule records Daniel's cadence with the Discord message it was said in" {
  opened_task T26
  run_bin -0 team-log T26 retro-schedule every_hours=48 discord_message=1563171945980370967
  run_bin -0 team-log T26 retro-schedule every_hours=0 discord_message=1563171945980370999
  assert_equal "$(logged_after 2)" "$(
    cat <<'LINES'
{"task":"T26","event":"retro-schedule","every_hours":48,"discord_message":"1563171945980370967"}
{"task":"T26","event":"retro-schedule","every_hours":0,"discord_message":"1563171945980370999"}
LINES
  )"
  run_bin -0 team-log --check
}

# A retro task T<m> as team-open opens it, Daniel's answer to its proposals when given: a_retro <task> [answered]
a_retro() {
  jq -cn --arg task "$1" '{ts: (now | todate), task: $task, event: "opened", project: "agent-team", path: "retro",
    type: "research", title: "Retro", branch: "research/\($task)-retro", base: "dev", base_sha: "0123456", worktree: "/w/retro"}' \
    >>"$TEAM_HOME/ledger.jsonl"
  [[ ${2:-} != answered ]] ||
    jq -cn --arg task "$1" '{ts: (now | todate), task: $task, event: "answered", id: "retro", answer: "1 and 3 yes, 2 no"}' \
      >>"$TEAM_HOME/ledger.jsonl"
}

@test "retro-change links a task to the approved proposals of a retro it builds, or of its own retro for records" {
  a_retro T150 answered
  opened T165 agent-team
  local before
  before=$(cat "$TEAM_HOME/ledger.jsonl")
  run_bin -0 team-log T165 retro-change retro=T150 'proposals=1, 3'
  run_bin -0 team-log T150 retro-change retro=T150 'proposals=2 and the SOP review'
  assert_equal "$(tail -n 2 "$TEAM_HOME/ledger.jsonl" | jq -c 'del(.ts)')" "$(
    cat <<'LINES'
{"task":"T165","event":"retro-change","retro":"T150","proposals":"1, 3"}
{"task":"T150","event":"retro-change","retro":"T150","proposals":"2 and the SOP review"}
LINES
  )"
  assert_equal "$(head -n 3 "$TEAM_HOME/ledger.jsonl")" "$before"
  # A number alone is still the proposals' string, as the contract types it.
  run_bin -0 team-log T165 retro-change retro=T150 proposals=4
  assert_equal "$(tail -n 1 "$TEAM_HOME/ledger.jsonl" | jq -c '.proposals')" '"4"'
  run_bin -0 team-log --check
}

@test "retro-change is refused for a task that is no retro, and for a retro Daniel has not answered" {
  opened T165 agent-team
  run_bin -1 team-log T165 retro-change retro=T165 proposals=1
  assert_contains "$output" "T165 is not a retro task: it has no opened event with the path retro, so retro-change links no retro's proposals"
  run_bin -1 team-log T165 retro-change retro=T9 proposals=1
  assert_contains "$output" "T9 is not a retro task: it has no opened event with the path retro"
  run_bin -1 team-log T165 retro-change retro=retro proposals=1
  assert_contains "$output" "retro is not a retro task"
  a_retro T150
  jq -cn '{ts: (now | todate), task: "T150", event: "answered", id: "plan", answer: "yes"}' >>"$TEAM_HOME/ledger.jsonl"
  jq -cn '{ts: (now | todate), task: "T151", event: "answered", id: "retro", answer: "yes"}' >>"$TEAM_HOME/ledger.jsonl"
  local before
  before=$(cat "$TEAM_HOME/ledger.jsonl")
  run_bin -1 team-log T165 retro-change retro=T150 proposals=1
  assert_contains "$output" "T150 has no answered with id retro: Daniel has not answered its proposals, so none is approved to build"
  run_bin -1 team-log T150 retro-change retro=T150 proposals=1
  assert_contains "$output" "T150 has no answered with id retro"
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" "$before"
  jq -cn '{ts: (now | todate), task: "T150", event: "answered", id: "retro", answer: "1 yes"}' >>"$TEAM_HOME/ledger.jsonl"
  before=$(cat "$TEAM_HOME/ledger.jsonl")
  run_bin -1 team-log T165 retro-change retro=T150
  assert_contains "$output" "retro-change needs proposals"
  run_bin -1 team-log T165 retro-change proposals=1
  assert_contains "$output" "retro-change needs retro"
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" "$before"
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
  opened_task T14
  opened_task T13
  local five=https://github.com/owner/proj/pull/5 seven=https://github.com/other/repo/pull/7
  run_bin -1 team-log T14 merge-approved url=$five discord_message=1563
  assert_contains "$output" "$five is not a PR of T14's pr events; it has none"
  assert_equal "$(logged_after 4)" ""
  run_bin -0 team-log T14 pr url=$five/ head=a1b2c3d
  run_bin -0 team-log T14 pr url=$seven head=e4f5a6b
  run_bin -0 team-log T13 pr url=https://github.com/owner/proj/pull/9 head=0a1b2c3
  run_bin -1 team-log T14 merge-approved url=https://github.com/owner/proj/pull/9 discord_message=1563
  assert_contains "$output" "https://github.com/owner/proj/pull/9 is not a PR of T14's pr events:"
  assert_contains "$output" "  $five/"
  assert_contains "$output" "  $seven"
  run_bin -1 team-log T14 merge-approved pr=5 discord_message=1563
  assert_contains "$output" "merge-approved needs url"
  assert_equal "$(logged_after 4 | wc -l)" "3"
  run_bin -0 team-log T14 merge-approved url=$five discord_message="$(soon)" head=a1b2c3d4e5f60718293a4b5c6d7e8f9012345678
  run_bin -0 team-log T14 merge-approved url=$seven/ discord_message="$(soon)" head=e4f5a6b
  assert_equal "$(tail -n 2 "$TEAM_HOME/ledger.jsonl" | jq -r .url)" "$five"$'\n'"$seven/"
}

@test "merge-approved names the head Daniel was asked on, one a pr event of its PR or a review since logged" {
  opened_task T14
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
  assert_equal "$(logged_after 2 | wc -l)" "3"
  run_bin -0 team-log T14 merge-approved url=$five discord_message="$(soon)" head=A1B2C3D4E5F60718293A4B5C6D7E8F9012345678
  run_bin -0 team-log T14 merge-approved url=$five/ discord_message="$(soon)" head=0123456789abcdef0123456789abcdef01234567
  run_bin -0 team-log --check
}

@test "merge-approved may name a fix head a review logged after the PR's first pr event, with no pr event of its own" {
  opened_task T14
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
  opened_task T14
  local five=https://github.com/owner/proj/pull/5 fix=b2c3d4e5f60718293a4b5c6d7e8f901234567890
  # 1562661774950400000 is 2026-10-22T03:00:00Z; the review of the fix is logged now, later.
  run_bin -0 team-log T14 pr url=$five head=a1b2c3d
  run_bin -0 team-log T14 review verdict=pass head=$fix
  local reviewed
  reviewed=$(tail -n 1 "$TEAM_HOME/ledger.jsonl" | jq -r .ts)
  run_bin -1 team-log T14 merge-approved url=$five discord_message=1562661774950400000 head=$fix
  assert_equal "$output" "team-log: Discord message 1562661774950400000 was sent at 2026-10-22T03:00:00Z, before the review event that first logged head $fix at $reviewed, so it is not Daniel's word on that head"
  assert_equal "$(logged_after 2 | wc -l)" "2"
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
  run_bin -1 team-log T14 merge-preapproved project=proj ask=plan discord_message="$(soon)" 'scope=["src/"]'
  assert_equal "$output" "team-log: proj is not a project of T14's opened or worktree-added events; it has none"
  opened_task T14
  run_bin -0 team-log T14 asked id=plan 'text=Approve?'
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
  own_by_repo_and_path true
  opened T14 mirror worktree-added
  opened T14 tools worktree-added
  run_bin -1 team-log T14 merge-preapproved project=mirror ask=plan discord_message="$(soon)" 'scope=["src/"]'
  assert_equal "$output" "team-log: mirror is the team's own project, whose PRs merge only on Daniel's word per head, never on a plan-time word"
  run_bin -1 team-log T14 merge-preapproved project=tools ask=plan discord_message="$(soon)" 'scope=["src/"]'
  assert_equal "$output" "team-log: tools is the team's own project, whose PRs merge only on Daniel's word per head, never on a plan-time word"
  assert_equal "$(ledger_events | grep -c merge-preapproved)" 0
}

@test "merge-preapproved names an ask the task logged, and a Discord message sent no earlier than it" {
  opened_task T15
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

@test "merge-preapproval-withdrawn needs a merge-preapproved of its project not withdrawn, and a new one may follow it" {
  plan_registry "$(plan_project web true)"
  opened T14 proj
  opened T14 web worktree-added
  run_bin -0 team-log T14 asked id=plan 'text=Approve?'
  run_bin -1 team-log T14 merge-preapproval-withdrawn project=proj discord_message="$(soon)"
  assert_equal "$output" "team-log: T14 has no merge-preapproved of proj left to withdraw"
  # Another task's approval is its own.
  opened T15 proj
  run_bin -0 team-log T15 asked id=plan 'text=Approve?'
  run_bin -0 team-log T15 merge-preapproved project=proj ask=plan discord_message="$(soon)" 'scope=["src/"]'
  run_bin -1 team-log T14 merge-preapproval-withdrawn project=proj discord_message="$(soon)"
  run_bin -0 team-log T14 merge-preapproved project=proj ask=plan discord_message="$(soon)" 'scope=["src/"]'
  run_bin -1 team-log T14 merge-preapproval-withdrawn project=web discord_message="$(soon)"
  assert_equal "$output" "team-log: T14 has no merge-preapproved of web left to withdraw"
  run_bin -1 team-log T14 merge-preapproval-withdrawn project=proj
  assert_contains "$output" "merge-preapproval-withdrawn needs discord_message"
  run_bin -0 team-log T14 merge-preapproval-withdrawn project=proj discord_message="$(soon)"
  run_bin -1 team-log T14 merge-preapproval-withdrawn project=proj discord_message="$(soon)"
  assert_equal "$output" "team-log: T14 has no merge-preapproved of proj left to withdraw"
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

@test "merge-standing records Daniel's standing word on a project or every project, said in #coordinator or the task's thread" {
  plan_registry
  opened_task T14
  thread T14 1563000000000000001
  local message
  message=$(soon)
  run_bin -0 team-log T14 merge-standing project=proj discord_message="$message" discord_channel=$COORDINATOR
  assert_equal "$output" ""
  assert_equal "$(tail -n 1 "$TEAM_HOME/ledger.jsonl" | jq -c 'del(.ts)')" \
    "{\"task\":\"T14\",\"event\":\"merge-standing\",\"project\":\"proj\",\"discord_message\":\"$message\",\"discord_channel\":\"$COORDINATOR\"}"
  # Every project, and a project none of the task's events name, which the word needs not.
  run_bin -0 team-log T14 merge-standing project=all discord_message="$(soon)" discord_channel=$COORDINATOR
  run_bin -0 team-log T14 merge-standing project=conv discord_message="$(soon)" discord_channel=1563000000000000001
  assert_equal "$(tail -n 1 "$TEAM_HOME/ledger.jsonl" | jq -r .discord_channel)" 1563000000000000001
  assert_equal "$(standing_events)" "merge-standing proj
merge-standing all
merge-standing conv"
  run_bin -0 team-log --check
}

@test "merge-standing and its withdrawal are refused for an unknown project, a message no Discord id, or a channel neither #coordinator nor the task's thread" {
  plan_registry
  local kind message channel
  for kind in merge-standing merge-standing-withdrawn; do
    run_bin -1 team-log T14 $kind project=web discord_message="$(soon)" discord_channel=$COORDINATOR
    assert_equal "$output" "team-log: web is neither all, for every project, nor a project projects.toml names: proj, conv"
    for message in 0 01566 15660000000000001234567; do
      run_bin -1 team-log T14 $kind project=proj discord_message=$message discord_channel=$COORDINATOR
      assert_equal "$output" "team-log: discord_message $message is not a Discord id"
    done
    run_bin -1 team-log T14 $kind project=proj discord_message="$(soon)" discord_channel=1563000000000000009
    assert_equal "$output" "team-log: discord_channel 1563000000000000009 is neither #coordinator's channel, $COORDINATOR, nor T14's thread: it has none"
  done
  # The task's latest thread, never an earlier one or another task's.
  opened_task T14
  thread T14 1563000000000000001
  thread T14 1563000000000000002
  thread T15 1563000000000000003
  for kind in merge-standing merge-standing-withdrawn; do
    for channel in 1563000000000000001 1563000000000000003; do
      run_bin -1 team-log T14 $kind project=all discord_message="$(soon)" discord_channel=$channel
      assert_equal "$output" "team-log: discord_channel $channel is neither #coordinator's channel, $COORDINATOR, nor T14's thread, 1563000000000000002"
    done
  done
  run_bin -1 team-log T14 merge-standing project=proj discord_message="$(soon)"
  assert_contains "$output" "merge-standing needs discord_channel"
  # A project named all makes all name it, never every project.
  plan_registry "$(plan_project all false)"
  run_bin -1 team-log T14 merge-standing project=all discord_message="$(soon)" discord_channel=$COORDINATOR
  assert_equal "$output" "team-log: projects.toml names a project all, so project=all cannot say every project"
  assert_equal "$(standing_events)" ""
  run_bin -0 team-log T14 merge-standing project=proj discord_message="$(soon)" discord_channel=1563000000000000002
}

@test "merge-standing and its withdrawal are refused for the team's own project, by name, by repo and by path, and all is logged beside it" {
  opened_task T14
  local kind said=(discord_message="$(soon)" discord_channel="$COORDINATOR")
  plan_registry "$(plan_project agent-team false)"
  for kind in merge-standing merge-standing-withdrawn; do
    run_bin -1 team-log T14 $kind project=agent-team "${said[@]}"
    assert_equal "$output" "team-log: agent-team is the team's own project, whose PRs merge only on Daniel's word per head, never on a standing word"
  done

  # By repo, the origin of the code checkout team-log runs from; and by path, at that checkout.
  own_by_repo_and_path false
  for kind in merge-standing merge-standing-withdrawn; do
    run_bin -1 team-log T14 $kind project=mirror "${said[@]}"
    assert_equal "$output" "team-log: mirror is the team's own project, whose PRs merge only on Daniel's word per head, never on a standing word"
    run_bin -1 team-log T14 $kind project=tools "${said[@]}"
    assert_equal "$output" "team-log: tools is the team's own project, whose PRs merge only on Daniel's word per head, never on a standing word"
  done
  assert_equal "$(standing_events)" ""

  # Every project, and a project not the team's own, are logged as before.
  run_bin -0 team-log T14 merge-standing project=all "${said[@]}"
  run_bin -0 team-log T14 merge-standing project=proj "${said[@]}"
  run_bin -0 team-log T14 merge-standing-withdrawn project=proj "${said[@]}"
  run_bin -0 team-log T14 merge-standing-withdrawn project=all "${said[@]}"
  assert_equal "$(standing_events)" "merge-standing all
merge-standing proj
merge-standing-withdrawn proj
merge-standing-withdrawn all"
}

@test "merge-standing-withdrawn needs a standing word for its project, or for any project when it withdraws all" {
  opened_task T14
  opened_task T15
  plan_registry "$(plan_project web false)"
  local said=(discord_message="$(soon)" discord_channel="$COORDINATOR")
  run_bin -1 team-log T14 merge-standing-withdrawn project=proj "${said[@]}"
  assert_equal "$output" "team-log: no standing word of Daniel's stands for proj, so merge-standing-withdrawn withdraws nothing"
  run_bin -1 team-log T14 merge-standing-withdrawn project=all "${said[@]}"
  assert_equal "$output" "team-log: no standing word of Daniel's stands for any project, so merge-standing-withdrawn withdraws nothing"
  # A word on one project stands for it alone, whichever task logged it.
  run_bin -0 team-log T15 merge-standing project=proj "${said[@]}"
  run_bin -1 team-log T14 merge-standing-withdrawn project=conv "${said[@]}"
  assert_equal "$output" "team-log: no standing word of Daniel's stands for conv, so merge-standing-withdrawn withdraws nothing"
  run_bin -0 team-log T14 merge-standing-withdrawn project=proj "${said[@]}"
  run_bin -1 team-log T14 merge-standing-withdrawn project=proj "${said[@]}"
  # A word on every project, withdrawn for one, stands for the others.
  run_bin -0 team-log T14 merge-standing project=all "${said[@]}"
  run_bin -0 team-log T14 merge-standing-withdrawn project=conv "${said[@]}"
  run_bin -1 team-log T14 merge-standing-withdrawn project=conv "${said[@]}"
  assert_equal "$output" "team-log: no standing word of Daniel's stands for conv, so merge-standing-withdrawn withdraws nothing"
  run_bin -0 team-log T14 merge-standing-withdrawn project=web "${said[@]}"
  # A word given after a withdrawal stands again.
  run_bin -0 team-log T14 merge-standing project=conv "${said[@]}"
  run_bin -0 team-log T14 merge-standing-withdrawn project=conv "${said[@]}"
  # A withdrawal of all ends every word, and none is left to withdraw.
  run_bin -0 team-log T14 merge-standing project=web "${said[@]}"
  run_bin -0 team-log T14 merge-standing-withdrawn project=all "${said[@]}"
  local project
  for project in all proj conv web; do
    run_bin -1 team-log T14 merge-standing-withdrawn project=$project "${said[@]}"
  done
  assert_equal "$output" "team-log: no standing word of Daniel's stands for web, so merge-standing-withdrawn withdraws nothing"
  # A word on a project no longer registered still stands, and a withdrawal of all ends it.
  run_bin -0 team-log T14 merge-standing project=web "${said[@]}"
  plan_registry
  run_bin -0 team-log T14 merge-standing-withdrawn project=all "${said[@]}"
  assert_equal "$(standing_events)" "$(
    cat <<'LINES'
merge-standing proj
merge-standing-withdrawn proj
merge-standing all
merge-standing-withdrawn conv
merge-standing-withdrawn web
merge-standing conv
merge-standing-withdrawn conv
merge-standing web
merge-standing-withdrawn all
merge-standing web
merge-standing-withdrawn all
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
  opened_task T14
  run_bin -0 team-log T14 review verdict=pass head=a1b2c3d \
    'findings={"blocking": 0, "correctness": 1, "security": 0, "real-data": 0, "note-change": 2, "note-before": 1}' \
    'before=[4]' 'guarded=["ci", "secrets"]'
  run_bin -0 team-log T14 review verdict=pass head=e4f5a6b \
    'findings={"note-before": 0, "note-change": 0, "real-data": 0, "security": 0, "correctness": 0, "blocking": 0}' 'guarded=[]'
  run_bin -0 team-log T14 review verdict=findings head=e4f5a6b
  assert_equal "$(logged_after 2)" "$(
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
  assert_equal "$output" "team-log: guarded lists the guarded areas the change touches, each one of ci, dependencies, migrations, settings, permissions, secrets and guardrails:
  \"docs\": not a guarded area
  1: not a guarded area"
  assert_equal "$(logged_after 2 | wc -l)" "3"
}

@test "a review names its plain notes on code the PR did not change, and never sends one back" {
  opened_task T14
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
  assert_equal "$(logged_after 2 | wc -l)" "4"
}

@test "a review names its widening findings as distinct numbers above 0, never a before note" {
  opened_task T14
  local counts='"blocking": 1, "correctness": 0, "security": 0, "real-data": 0'
  # A comma list, none and no list at all.
  run_bin -0 team-log T14 review verdict=findings head=a1b2c3d sent_back=3,5 widening=3,5
  run_bin -0 team-log T14 review verdict=findings head=e4f5a6b sent_back=1 widening=none
  run_bin -0 team-log T14 review verdict=findings head=e4f5a6b sent_back=1
  # A widening finding not sent back is logged as given.
  run_bin -0 team-log T14 review verdict=findings head=e4f5a6b sent_back=1 widening=1,6
  assert_equal "$(logged_after 2 | jq -c 'select(.event == "review") | .widening')" '[3,5]
[]
null
[1,6]'
  run_bin -0 team-log --check

  # The list's shape.
  run_bin -1 team-log T14 review verdict=findings head=a1b2c3d widening=0
  assert_equal "$output" "team-log: widening lists the numbers of the findings in what the last fix added, each a whole number above 0, once:
  0: not a finding number"
  run_bin -1 team-log T14 review verdict=findings head=a1b2c3d widening=3,3
  assert_equal "$output" "team-log: widening lists the numbers of the findings in what the last fix added, each a whole number above 0, once:
  3: listed twice"
  run_bin -1 team-log T14 review verdict=findings head=a1b2c3d widening=x
  assert_equal "$output" "team-log: widening: x is not a whole number"
  # A before note is on code the PR did not change, so it is in no fix's code.
  run_bin -1 team-log T14 review verdict=findings head=a1b2c3d \
    "findings={$counts, \"note-change\": 0, \"note-before\": 1}" before=2 sent_back=1 widening=1,2
  assert_equal "$output" "team-log: widening names note 2, which before lists as on code the PR did not change"
  run_bin -1 team-log T14 review verdict=findings head=a1b2c3d before=3,5 sent_back=1 widening=3,5
  assert_equal "$output" "team-log: widening names notes 3 and 5, which before lists as on code the PR did not change"
  assert_equal "$(logged_after 2 | wc -l)" "4"
}

@test "an answered naming a Discord message is refused, naming team-answer, in both forms; one with no message is logged" {
  open_t7
  # team-answer reads the message from Discord and checks it is Daniel's, so a logged message id
  # is always a checked one: team-log never writes one, whatever its value.
  local message
  for message in 1564000000000000001 m1563; do
    run_bin -1 team-log T7 answered id=sign-in answer=five discord_message=$message
    assert_equal "$output" "team-log: an answered that names a Discord message is logged only by team-answer, which reads it and checks it is Daniel's: team-answer T7 sign-in <the message's id>"
  done
  # No worker's message is an answered, so --from-message logs none either.
  run_bin -1 team-log T7 --from-message 'T7 answered id=sign-in answer=five discord_message=1564000000000000001'
  assert_contains "$output" "cannot read 'T7 answered id=sign-in answer=five discord_message=1564000000000000001'"
  assert_equal "$(ledger_events)" "opened"
  # A decision Daniel gave at the terminal has no message, and is logged as often as it is given.
  run_bin -0 team-log T7 answered id=sign-in answer=five
  run_bin -0 team-log T7 answered id=sign-in answer=five
  assert_equal "$(jq -c 'select(.event == "answered") | del(.ts)' "$TEAM_HOME/ledger.jsonl")" '{"task":"T7","event":"answered","id":"sign-in","answer":"five"}
{"task":"T7","event":"answered","id":"sign-in","answer":"five"}'
}

@test "an answered naming an item of the waiting list is refused, naming team-answer --item" {
  open_t7
  # team-answer --item checks Daniel's message names the number, so team-log never writes one.
  run_bin -1 team-log T7 answered id=sign-in answer=five item=3
  assert_equal "$output" "team-log: an answered that names an item of the waiting list is logged only by team-answer --item, which reads Daniel's message and checks it names that number: team-answer --item 3 <the message's id>"
  run_bin -1 team-log T7 answered id=sign-in answer=five item=3 discord_message=1564000000000000001
  assert_contains "$output" "team-answer --item 3 <the message's id>"
  assert_equal "$(ledger_events)" "opened"
  # --check takes the field as a number, and refuses it as anything else.
  echo '{"ts":"2026-11-01T10:00:09Z","task":"T7","event":"answered","id":"sign-in","answer":"3 yes","discord_message":"1564000000000000001","item":3}' \
    >>"$TEAM_HOME/ledger.jsonl"
  run_bin -0 team-log --check
  echo '{"ts":"2026-11-01T10:00:10Z","task":"T7","event":"answered","id":"sign-in","answer":"3 yes","discord_message":"1564000000000000001","item":"3"}' \
    >>"$TEAM_HOME/ledger.jsonl"
  run_bin -1 team-log --check
  assert_contains "$output" "item must be a number, got a string"
}

@test "an asked names no script or sha256: team-ask --script is their one writer" {
  opened_task T14
  local hash
  hash=$(printf '%064d' 0 | tr 0 a)
  run_bin -1 team-log T14 asked id=fix text=run-it script=/w/14/fix.sh sha256="$hash"
  assert_equal "$output" "team-log: an asked logs no script or sha256: team-ask T14 fix --file <question> --script <path> asks Daniel about a script, naming its path and hash in the question"
  run_bin -1 team-log T14 asked id=fix text=run-it script=/w/14/fix.sh
  assert_equal "$output" "team-log: an asked logs no script or sha256: team-ask T14 fix --file <question> --script <path> asks Daniel about a script, naming its path and hash in the question"
  run_bin -1 team-log T14 asked id=fix text=run-it sha256="$hash"
  assert_equal "$output" "team-log: an asked logs no script or sha256: team-ask T14 fix --file <question> --script <path> asks Daniel about a script, naming its path and hash in the question"
  assert_equal "$(logged_after 2)" ""
  run_bin -0 team-log T14 asked id=plain text=no-script
  assert_equal "$(logged_after 2)" '{"task":"T14","event":"asked","id":"plain","text":"no-script"}'
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
    opened_task $task
    echo '{"ts":"2026-10-25T14:51:44Z","task":"'$task'","event":"launch","role":"builder","session":"s","worktree":"/w","toolkits":[]}' \
      >>"$TEAM_HOME/ledger.jsonl"
  done
  # Another task's later event does not bound it.
  echo '{"ts":"2026-10-25T16:00:00Z","task":"T18","event":"resumed"}' >>"$TEAM_HOME/ledger.jsonl"
  run_bin -0 team-log T14 blocked 'reason=usage limit: the weekly limit' since=2026-10-25T14:58:00Z
  run_bin -0 team-log T15 waiting on=Daniel reason=x since=2026-10-25T14:58:00Z
  run_bin -0 team-log T16 paused cause=machine reason=x since=2026-10-25T14:51:44Z
  run_bin -0 team-log T17 held discord_message=1564000000000000020 reason=x since=2026-10-25T14:58:00Z
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
  run_bin -1 team-log T14 resumed all=true since=2026-10-25T15:00:00Z
  assert_contains "$output" "since is taken only by a park (waiting, blocked, paused, held), not resumed"
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" "$before"
}

@test "too few arguments is a usage error" {
  run_bin -2 team-log
  assert_contains "$output" "usage: team-log T<n> <event> [key=value]..."
  run_bin -2 team-log T14
  run_bin -2 team-log --check a b
  run_bin -2 team-log --check-lifecycle a b
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

@test "--check-lifecycle names a closed task's event, and exits 1 only for one from lifecycle_from on" {
  cat >"$TEAM_HOME/ledger.jsonl" <<'LEDGER'
{"ts":"2026-11-01T00:00:00Z","task":"T1","event":"thread","discord_thread":"1563"}
{"ts":"2026-11-01T00:01:00Z","task":"T1","event":"opened","project":"proj","path":"small"}
{"ts":"2026-11-01T00:02:00Z","task":"T1","event":"closed","archive":[],"returned":[],"kept":[]}
{"ts":"2026-11-01T00:03:00Z","task":"T1","event":"held","reason":"on hold by Daniel"}
LEDGER
  local file=$TEAM_HOME/ledger.jsonl
  local named="$file:4: T1 held: T1 is closed, and a closed task takes no held"
  with_lifecycle_from null
  run_bin -0 --separate-stderr team-log --check-lifecycle
  assert_equal "$output" "$named
$file: 1 of 4 lines break the lifecycle table, 0 of them from its lifecycle_from on"
  assert_equal "$stderr" ""
  # From a time before the event, it would be refused: exit 1, on stderr.
  with_lifecycle_from 2026-01-01T00:00:00Z
  run_bin -1 --separate-stderr team-log --check-lifecycle
  assert_equal "$output" ""
  assert_equal "$stderr" "$named
$file: 1 of 4 lines break the lifecycle table, 1 of them from its lifecycle_from on"
  # From a time after it, it is named and passes.
  with_lifecycle_from 2026-11-01T00:03:01Z
  run_bin -0 team-log --check-lifecycle "$file"
  assert_contains "$output" "0 of them from its lifecycle_from on"
  # A ledger the table takes whole.
  head -3 "$file" >"$BATS_TEST_TMPDIR/clean.jsonl"
  run_bin -0 team-log --check-lifecycle "$BATS_TEST_TMPDIR/clean.jsonl"
  assert_equal "$output" "$BATS_TEST_TMPDIR/clean.jsonl: 3 lines meet the lifecycle table"
  run_bin -1 team-log --check-lifecycle "$BATS_TEST_TMPDIR/none.jsonl"
  assert_equal "$output" "team-log: no ledger at $BATS_TEST_TMPDIR/none.jsonl"
}

@test "--check-lifecycle runs over every fixture ledger and passes it while lifecycle_from is null" {
  with_lifecycle_from null
  local file count=0
  while IFS= read -r file; do
    run_bin -0 team-log --check-lifecycle "$file"
    assert_contains "${lines[-1]}" "$file: "
    count=$((count + 1))
  done < <(find "$REPO_ROOT/tests/fixtures" -name 'ledger*.jsonl' | sort)
  ((count >= 10))
  # The early ledger, from before team-open: its tasks are legacy, opened by no event, and its 15
  # parks of opened tasks carry no cause, which the table holds new lines to (252 before typed parks).
  file=$REPO_ROOT/tests/fixtures/ledger-2026-10-23.jsonl
  run_bin -0 team-log --check-lifecycle "$file"
  assert_equal "${lines[0]}" "$file:1: T1 launch: T1 is not opened (no opened event), and it takes only thread and opened before its opened, not launch"
  assert_equal "$(grep -c ': a [a-z]* needs a cause, one of ' <<<"$output")" 15
  assert_equal "${lines[-1]}" "$file: 267 of 436 lines break the lifecycle table, 0 of them from its lifecycle_from on"
}

# T171 review note 2: the ledger's reviews before the scope split count plain notes as note.
@test "--check passes a review logged before the scope split, its findings counting note" {
  opened_task T14
  echo "{\"ts\":\"$STRICT_FROM\",\"task\":\"T14\",\"event\":\"review\",\"verdict\":\"pass\",\"head\":\"a1b2c3d\",\"findings\":{\"blocking\":0,\"correctness\":0,\"security\":0,\"real-data\":0,\"note\":3},\"guarded\":[]}" \
    >>"$TEAM_HOME/ledger.jsonl"
  run_bin -0 team-log --check
  assert_equal "$output" "$TEAM_HOME/ledger.jsonl: 3 lines meet the ledger contract"
  # A new review after it counts the split.
  run_bin -0 team-log T14 review verdict=pass head=e4f5a6b \
    'findings={"blocking": 0, "correctness": 0, "security": 0, "real-data": 0, "note-change": 0, "note-before": 0}' 'guarded=[]'
  run_bin -0 team-log --check
  assert_equal "$output" "$TEAM_HOME/ledger.jsonl: 4 lines meet the ledger contract"
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

# An ops session's answer, whose name and order number are production data: OPS_ANSWER, 64 characters, é one of them.
OPS_ANSWER='3 accounts match; the newest is Jean Dupré, order 1187, on 11-02'

# Asserts that no line of the ledger holds the ops answer's text, or any of its distinctive parts.
assert_no_answer_logged() {
  local part
  for part in Dupré 1187 'accounts match' 'what store'; do
    if grep -qF "$part" "$TEAM_HOME/ledger.jsonl"; then
      echo "the ledger holds '$part':" >&2
      cat "$TEAM_HOME/ledger.jsonl" >&2
      return 1
    fi
  done
}

@test "--from-message logs an ops session's DONE as its length in characters, never its text, whatever its first word" {
  open_t7
  launched T7 ops d0000001
  assert_equal "${#OPS_ANSWER}" 64
  logs_events '{"task":"T7","event":"done","role":"ops","session":"d0000001","report_chars":64}' \
    --from-message "T7 DONE $OPS_ANSWER"
  # --print prints what it would log, and no more of the text.
  run_bin -0 team-log T7 --from-message "T7 DONE $OPS_ANSWER" --from T7-ops --print
  assert_equal "$(jq -c 'del(.ts)' <<<"$output")" '{"task":"T7","event":"done","role":"ops","session":"d0000001","report_chars":64}'
  # With --from naming the ops session, a first word that is another form's is still the answer.
  launched T7 builder b0000001
  logs_events '{"task":"T7","event":"done","role":"ops","session":"d0000001","report_chars":26}' \
    --from-message 'T7 DONE 42 orders; the newest 1187' --from T7-ops
  logs_events '{"task":"T7","event":"done","role":"ops","session":"d0000001","report_chars":28}' \
    --from d0000001 --from-message 'T7 DONE merged accounts: Dupré, 1187'
  # Without it, such a word is that form's, a builder's, and refused when it does not read as one.
  refuses_message "team-log: DONE 42 takes one or more shas of 7 to 40 hex digits after the ticket, then a line, got 'orders;'" \
    --from-message 'T7 DONE 42 orders; the newest 1187'
  assert_no_answer_logged
  run_bin -0 team-log --check
}

@test "--from-message logs an ops session's QUESTION as its length, and its other messages as every role's" {
  open_t7
  launched T7 ops d0000001
  logs_events '{"task":"T7","event":"question","role":"ops","chars":28}' \
    --from-message 'T7 QUESTION what store holds order 1187?'
  assert_no_answer_logged
  # BLOCKED, PAUSED, FAILED and INJECTION keep their text: roles/ops.md keeps personal details out of them.
  logs_events '{"task":"T7","event":"blocked","reason":"mcp__prod-read__find denied","cause":"worker","role":"ops","session":"d0000001"}' \
    --from-message 'T7 BLOCKED mcp__prod-read__find denied'
  logs_events '{"task":"T7","event":"paused","reason":"stowed","cause":"stow","role":"ops","session":"d0000001"}' --from-message 'T7 PAUSED stowed'
  logs_events '{"task":"T7","event":"failed","reason":"the collection is gone"}' --from-message 'T7 FAILED the collection is gone'
  logs_events '{"task":"T7","event":"injection","role":"ops","source":"orders/1187","text":"asked to drop the collection"}' \
    --from T7-ops --from-message 'T7 INJECTION orders/1187 asked to drop the collection'
  # Another role's QUESTION keeps its text.
  launched T7 builder b0000001
  logs_events '{"task":"T7","event":"question","role":"builder","text":"which store?"}' \
    --from-message 'T7 QUESTION which store?' --from T7-builder
  run_bin -0 team-log --check
}

@test "--from-message logs --relay, the coordinator's relay of an ops answer, on the ops session's done, and only there" {
  open_t7
  launched T7 ops d0000001
  logs_events '{"task":"T7","event":"done","role":"ops","session":"d0000001","report_chars":64,"relay":"1564000000000000007"}' \
    --from-message "T7 DONE $OPS_ANSWER" --relay 1564000000000000007
  assert_no_answer_logged
  run_bin -0 team-log --check
  local why="--relay is taken only with an ops session's DONE, the answer it points at in Discord"
  refuses_message "team-log: $why, not T7-ops's QUESTION" \
    --from-message 'T7 QUESTION which store?' --from T7-ops --relay 1564000000000000008
  refuses_message "team-log: $why, not FAILED" \
    --from-message 'T7 FAILED gone' --from T7-ops --relay 1564000000000000008
  launched T7 builder b0000001
  refuses_message "team-log: $why, not T7-builder's DONE" \
    --from-message 'T7 DONE .scratch/task/notes.md' --from T7-builder --relay 1564000000000000008
  refuses_message "team-log: $why, not T7-builder's DONE" \
    --from-message 'T7 DONE 01 a1b2c3d the ticket' --relay 1564000000000000008
  # A malformed id is a malformed command line, and so is --relay with no message or twice.
  local id
  for id in 01564000000000000008 x 15640000000000000080; do
    run_bin -2 team-log T7 --from-message "T7 DONE $OPS_ANSWER" --from T7-ops --relay "$id"
    assert_contains "$output" "--relay takes the Discord id of the relay's message, got '$id'"
  done
  run_bin -2 team-log T7 --from-message "T7 DONE $OPS_ANSWER" --from T7-ops --relay
  assert_contains "$output" "--relay needs a Discord message id"
  run_bin -2 team-log T7 --from-message "T7 DONE $OPS_ANSWER" --relay 1 --relay 2
  assert_contains "$output" "--relay is given twice"
  run_bin -2 team-log T7 --relay 1564000000000000008
  assert_contains "$output" "--relay is taken only with --from-message"
  assert_equal "$(wc -l <"$TEAM_HOME/ledger.jsonl")" 4
}

@test "--from-message logs a BLOCKED and a NEED toolkit as blocked cause=worker, with the sender's role and session" {
  open_t7
  launched T7 builder b0000001
  # roles/builder.md: `BLOCKED <what> <why>`
  logs_events '{"task":"T7","event":"blocked","reason":"Bash(git push) denied: the push target is a base branch","cause":"worker","role":"builder","session":"b0000001"}' \
    --from-message 'T7 BLOCKED Bash(git push) denied: the push target is a base branch'
  # roles/builder.md: `NEED toolkit <name>`
  logs_events '{"task":"T7","event":"blocked","reason":"needs toolkit browser","cause":"worker","role":"builder","session":"b0000001"}' \
    --from-message 'T7 NEED toolkit browser'
  refuses_message "team-log: NEED takes 'NEED toolkit <name>', got 'NEED a browser'" \
    --from-message 'T7 NEED a browser'
}

@test "--from-message logs a PAUSED with its why as the reason and its first word's cause, with the sender's role and session" {
  open_t7
  launched T7 builder b0000001
  local sender='"role":"builder","session":"b0000001"'
  # roles/builder.md: reply `T<n> PAUSED stowed`, a handoff after it.
  logs_events '{"task":"T7","event":"paused","reason":"stowed","cause":"stow",'"$sender"'}' --from-message 'T7 PAUSED stowed'
  logs_events '{"task":"T7","event":"paused","reason":"stowed, handoff written","cause":"stow",'"$sender"'}' \
    --from-message 'T7 PAUSED stowed, handoff written'
  # roles/builder.md: `T<n> PAUSED held`, the answer to `T<n> HOLD`.
  logs_events '{"task":"T7","event":"paused","reason":"held","cause":"coordinator-hold",'"$sender"'}' --from-message 'T7 PAUSED held'
  # roles/builder.md: `T<n> PAUSED offline <what failed>`
  logs_events '{"task":"T7","event":"paused","reason":"offline git push could not reach github.com","cause":"offline",'"$sender"'}' \
    --from-message 'T7 PAUSED offline git push could not reach github.com'
  logs_events '{"task":"T7","event":"paused","reason":"offline GitHub","cause":"offline",'"$sender"'}' --from-message 'T7 PAUSED offline GitHub'
  # Any other first word is the worker's own pause.
  logs_events '{"task":"T7","event":"paused","reason":"waiting for the gate","cause":"worker",'"$sender"'}' \
    --from-message 'T7 PAUSED waiting for the gate'
  logs_events '{"task":"T7","event":"paused","reason":"stowedness","cause":"worker",'"$sender"'}' --from-message 'T7 PAUSED stowedness'
  run_bin -0 team-log --check
}

@test "--from-message logs a park with no role or session when its sender is not known, and refuses a --from naming no launch" {
  open_t7
  launched T7 builder b0000001
  launched T7 reviewer r0000001
  logs_events '{"task":"T7","event":"paused","reason":"stowed","cause":"stow"}' --from-message 'T7 PAUSED stowed'
  logs_events '{"task":"T7","event":"blocked","reason":"the fixture is gone","cause":"worker"}' --from-message 'T7 BLOCKED the fixture is gone'
  logs_events '{"task":"T7","event":"paused","reason":"held","cause":"coordinator-hold","role":"reviewer","session":"r0000001"}' \
    --from-message 'T7 PAUSED held' --from T7-reviewer
  refuses_message "team-log: --from T7-planner names no launch of T7: its sessions are T7-builder (b0000001), T7-reviewer (r0000001)" \
    --from-message 'T7 PAUSED held' --from T7-planner
}

@test "a park logged by hand takes the cause its kind and on tell, keeps a cause given, and needs one for a paused and Daniel's message for a held" {
  opened_task T14
  run_bin -0 team-log T14 waiting on=Daniel reason="an interview"
  run_bin -0 team-log T14 waiting on=daniel reason="a login"
  run_bin -0 team-log T14 waiting on=GitHub reason="a support ticket"
  run_bin -0 team-log T14 blocked on=T31 reason="its PR first"
  run_bin -0 team-log T14 blocked reason="the fixture server is down"
  run_bin -0 team-log T14 blocked cause=denial reason="Bash(git push) denied"
  run_bin -0 team-log T14 waiting on=Daniel cause=outside reason="kept as given"
  run_bin -0 team-log T14 paused cause=limit reason="the weekly limit"
  run_bin -0 team-log T14 held discord_message=1564000000000000020 reason="Daniel holds it for the release"
  assert_equal "$(logged_after 2 | jq -r '[.event, .on // "-", .cause] | join(" ")')" "$(printf '%s\n' \
    "waiting Daniel daniel" "waiting daniel daniel" "waiting GitHub outside" "blocked T31 task" "blocked - worker" \
    "blocked - denial" "waiting Daniel outside" "paused - limit" "held - daniel-hold")"
  run_bin -0 team-log --check
  local before
  before=$(cat "$TEAM_HOME/ledger.jsonl")
  run_bin -1 team-log T14 paused reason="the machine is busy"
  assert_equal "$output" "team-log: a paused needs cause=, one of limit, machine, shutdown, worker"
  run_bin -1 team-log T14 held reason="Daniel holds it"
  assert_equal "$output" "team-log: a held is Daniel's hold, and needs discord_message, the id of Daniel's message saying so"
  # A cause the kind does not take is the contract's refusal.
  run_bin -1 team-log T14 held discord_message=1564000000000000020 cause=limit reason="x"
  assert_contains "$output" "cause must be one of daniel-hold"
  run_bin -1 team-log T14 blocked cause=stow reason="x"
  assert_contains "$output" "cause must be one of task, worker, denial"
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" "$before"
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

@test "--from-message logs the memory file a reviewer's DONE names on its review, which --check passes" {
  open_t7
  launched T7 builder b0000001
  launched T7 reviewer c0000001 brief-review
  brief_record T7 brief-review "{\"pr\": \"$URL\", \"head\": \"$HEAD_A\"}"
  # roles/reviewer.md: ` memory=.scratch/task/memory.md` after guarded= when it added a memory.
  logs_events "{\"task\":\"T7\",\"event\":\"review\",\"verdict\":\"pass\",\"head\":\"$HEAD_A\",\"findings\":{\"blocking\":0,\"correctness\":0,\"security\":0,\"real-data\":0,\"note-change\":0,\"note-before\":0},\"guarded\":[],\"memory\":\".scratch/task/memory.md\"}
{\"task\":\"T7\",\"event\":\"done\",\"role\":\"reviewer\",\"session\":\"c0000001\"}" \
    --from-message "T7 DONE pass $URL findings=blocking:0,correctness:0,security:0,real-data:0,note-change:0,note-before:0 guarded=none memory=.scratch/task/memory.md"
  run_bin -0 team-log --check
  # A findings review takes it too.
  launched T7 reviewer c0000002 brief-rereview
  brief_record T7 brief-rereview "{\"pr\": \"$URL\", \"head\": \"$HEAD_B\", \"reviewed\": \"$HEAD_A\"}"
  logs_events "{\"task\":\"T7\",\"event\":\"review\",\"verdict\":\"findings\",\"head\":\"$HEAD_B\",\"findings\":{\"blocking\":1,\"correctness\":0,\"security\":0,\"real-data\":0,\"note-change\":0,\"note-before\":0},\"before\":[],\"guarded\":[],\"memory\":\".scratch/task/memory.md\"}
{\"task\":\"T7\",\"event\":\"done\",\"role\":\"reviewer\",\"session\":\"c0000002\"}" \
    --from-message "T7 DONE findings .scratch/task/review.md findings=blocking:1,correctness:0,security:0,real-data:0,note-change:0,note-before:0 before=none guarded=none memory=.scratch/task/memory.md"
  run_bin -0 team-log --check
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

@test "--from-message logs a rereview's widening= on its review, none as an empty list, and no field when the message has none" {
  open_t7
  launched T7 builder b0000001
  launched T7 reviewer c0000001 brief-rereview
  brief_record T7 brief-rereview "{\"pr\": \"$URL\", \"head\": \"$HEAD_B\", \"reviewed\": \"$HEAD_A\"}"
  local counts='blocking:1,correctness:0,security:0,real-data:0,note-change:1,note-before:0'
  local logged='"findings":{"blocking":1,"correctness":0,"security":0,"real-data":0,"note-change":1,"note-before":0},"before":[],"guarded":[]'
  # templates/briefs/rereview.md: `... guarded=<areas, ...> widening=<the widening findings' numbers, ...>`
  logs_events "{\"task\":\"T7\",\"event\":\"review\",\"verdict\":\"findings\",\"head\":\"$HEAD_B\",$logged,\"widening\":[3,5],\"sent_back\":[3,5]}
{\"task\":\"T7\",\"event\":\"done\",\"role\":\"reviewer\",\"session\":\"c0000001\"}" \
    --from-message "T7 DONE findings .scratch/task/review.md findings=$counts before=none guarded=none widening=3,5" --sent-back 3,5
  launched T7 reviewer c0000002 brief-rereview
  logs_events "{\"task\":\"T7\",\"event\":\"review\",\"verdict\":\"pass\",\"head\":\"$HEAD_B\",$logged,\"widening\":[]}
{\"task\":\"T7\",\"event\":\"done\",\"role\":\"reviewer\",\"session\":\"c0000002\"}" \
    --from-message "T7 DONE pass $URL findings=$counts before=none guarded=none widening=none"
  launched T7 reviewer c0000003 brief-rereview
  logs_events "{\"task\":\"T7\",\"event\":\"review\",\"verdict\":\"findings\",\"head\":\"$HEAD_B\",$logged,\"sent_back\":[1]}
{\"task\":\"T7\",\"event\":\"done\",\"role\":\"reviewer\",\"session\":\"c0000003\"}" \
    --from-message "T7 DONE findings .scratch/task/review.md findings=$counts before=none guarded=none" --sent-back 1
  run_bin -0 team-log --check
  # The review's own checks hold on a message too.
  launched T7 reviewer c0000004 brief-rereview
  refuses_message "team-log: widening: x is not a whole number" \
    --from-message "T7 DONE findings .scratch/task/review.md findings=$counts before=none guarded=none widening=x" --sent-back 1
  refuses_message "team-log: widening names note 2, which before lists as on code the PR did not change" \
    --from-message "T7 DONE findings .scratch/task/review.md findings=blocking:1,correctness:0,security:0,real-data:0,note-change:0,note-before:1 before=2 guarded=none widening=2" --sent-back 1
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
  # and `approved=<ids>`; a line with no approved, as every one before it, still parses.
  logs_events "{\"task\":\"T7\",\"event\":\"gate-run\",\"run\":\"01KR2B3C4D\",\"head\":\"$HEAD_A\",\"outcome\":\"pushed\",\"minutes\":{\"review\":3.5,\"test\":12},\"cause\":\"review\"}" \
    --from-message "T7 DONE gate run=01KR2B3C4D head=$HEAD_A outcome=pushed minutes={\"review\": 3.5, \"test\": 12} cause=review"
  # A run that re-gates a base merge is logged, with the line saying the brief asks for none.
  run_bin -0 --separate-stderr team-log T7 --from-message "T7 DONE gate run=01KR2B3C4E head=$HEAD_A outcome=pushed cause=base-merge"
  assert_equal "$stderr" "team-log: T7 gate run 01KR2B3C4E re-gates a base merge, which the gated delivery brief asks no gate run for: a merge of the base is re-reviewed and checked by CI"
  assert_equal "$(tail -n 1 "$TEAM_HOME/ledger.jsonl" | jq -r '"\(.run) \(.cause)"')" "01KR2B3C4E base-merge"
  # --print logs nothing, so it says nothing of it either: team-next prints, then logs.
  run_bin -0 --separate-stderr team-log T7 --print --from-message "T7 DONE gate run=01KR2B3C4F head=$HEAD_A outcome=pushed cause=base-merge"
  assert_equal "$stderr" ""
  # The parks the builder approved itself, by the ids its brief names, are a list.
  logs_events "{\"task\":\"T7\",\"event\":\"gate-run\",\"run\":\"01KR2B3C5E\",\"head\":\"$HEAD_A\",\"outcome\":\"pushed\",\"minutes\":{\"review\":2},\"approved\":[\"review-coverage\",\"lint-before\"]}" \
    --from-message "T7 DONE gate run=01KR2B3C5E head=$HEAD_A outcome=pushed minutes={\"review\": 2} approved=review-coverage, lint-before"
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
  local forms="QUESTION <text>, BLOCKED <what> <why>, NEED toolkit <name>, PAUSED <why>, PR <full url> [merged <base> conflicts: <files or none>], DONE <NN> <sha>... <line>, DONE review-ready <sha>, DONE merged <base> <sha> conflicts: <files or none>, DONE pass <PR url or head> findings=<kind:n,...> [before=<list>] guarded=<list> [widening=<list>] [memory=<path>], DONE findings <path> findings=<kind:n,...> [before=<list>] guarded=<list> [widening=<list>] [memory=<path>], DONE gate <key=value>..., DONE <report>, FAILED <why>, INJECTION <where> <what it asked>"
  refuses_message "team-log: cannot read 'T7 HELLO there': expected one of $forms" --from-message 'T7 HELLO there'
  refuses_message "team-log: cannot read 'T7 QUESTION': expected one of $forms" --from-message 'T7 QUESTION'
  # Malformed parts of a review, each named.
  run_bin -1 team-log T7 --from-message 'T7 DONE pass a1b2c3d findings=blocking:0 guarded=none'
  assert_contains "$output" "findings holds the count of each finding kind"
  refuses_message "team-log: findings: blocking is not a key:value pair" \
    --from-message 'T7 DONE pass a1b2c3d findings=blocking,correctness:1 guarded=none'
  refuses_message "team-log: DONE pass takes findings=<kind:n,...>, before=<list>, guarded=<list>, widening=<list> and memory=<path>, got bogus" \
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

@test "refused in a worker session, whatever its role and form, --print, --check and --check-lifecycle included; --help and the coordinator are not" {
  worker_refused team-log "runs no team-log" T7 review verdict=pass
  worker_refused team-log "runs no team-log" T7 --from-message 'T7 DONE 01 abc1234 the ticket' --print
  worker_refused team-log "runs no team-log" --check
  worker_refused team-log "runs no team-log" --check-lifecycle
  worker_refused team-log "runs no team-log" --fix-sent-back
  AGENT_TEAM_ROLE=builder run_bin -0 team-log --help
  assert_equal "${lines[0]}" "$(sed -n '2s/^# //p' "$REPO_ROOT/bin/team-log")"
  opened_task T14
  AGENT_TEAM_ROLE=coordinator run_bin -0 team-log T14 resumed all=true
  assert_equal "$(logged_after 2)" '{"task":"T14","event":"resumed","all":true}'
}

@test "an event holding an address at a public provider is refused, naming its field and never the value, since the records hook would refuse every later ledger commit" {
  open_t7
  provider=gmail.com
  before=$(cat "$TEAM_HOME/ledger.jsonl")
  run_bin -1 team-log T7 waiting on=Daniel "reason=mail someone.else@$provider about the key"
  assert_contains "$output" "team-log: refusing a ledger event: reason holds 1 email address at a public provider"
  [[ $output != *someone.else* ]]
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" "$before"
  # Two string fields are both named (a list's item, tests/ledger.bats).
  run_bin -1 team-log T7 paused cause=machine "reason=from a@$provider" "note=and b@$provider, c@$provider"
  assert_contains "$output" "refusing a ledger event: reason holds 1 email address at a public provider; note holds 2 email addresses at a public provider"
  [[ $output != *"@$provider"* ]]
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" "$before"
  # What the hook takes is taken: a fixture address, a service, and the team home's own user.email.
  run_bin -0 team-log T7 waiting on=Daniel "reason=mail team@example.com, noreply@$provider"
  git init -q "$TEAM_HOME"
  git -C "$TEAM_HOME" config user.email "daniel@$provider"
  run_bin -0 team-log T7 waiting on=Daniel "reason=mail daniel@$provider"
  assert_equal "$(wc -l <"$TEAM_HOME/ledger.jsonl")" "$(($(wc -l <<<"$before") + 2))"
  # The line is judged as written, as the hook reads it: a control character right before the
  # owner's address is written as an escape, whose last letters run into the address's name.
  run_bin -1 team-log T7 waiting on=Daniel "reason=mail "$'\x01'"daniel@$provider"
  assert_contains "$output" "team-log: refusing a ledger event: reason holds 1 email address at a public provider"
  assert_equal "$(wc -l <"$TEAM_HOME/ledger.jsonl")" "$(($(wc -l <<<"$before") + 2))"
}

# The ledger's immediate push: the team home a clone of a bare origin, home-pc holding the lease,
# and the ledger's lock file ignored, as the team home's .gitignore has it.
push_home() {
  printf 'ledger.jsonl.lock\n' >"$TEAM_HOME/.gitignore"
  team_origin=$(hold_lease home-pc)
}

# The subject of the commit at the tip of the team home's dev on its origin.
origin_subject() {
  git -C "$team_origin" log -1 --format=%s dev
}

@test "every push kind team-log writes is committed alone and on origin at once, with no checkpoint; no other kind commits" {
  push_home
  plan_registry
  opened T14 proj
  a_retro T150 answered
  local kind args tip pushed=()
  while IFS= read -r kind; do
    mapfile -t args < <(jq -r --arg k "$kind" --arg soon "$(soon)" --arg coordinator "$COORDINATOR" '(.kinds[$k].required | to_entries[]
      | "\(.key)=\(if .key == "head" then "a1b2c3d4" elif .key == "project" then "proj" elif .key == "ask" then "x y"
          elif .key == "scope" then "[\"src/\"]" elif .key == "branch" then "feat/T14-x-fresh"
          elif .key == "retro" then "T150"
          elif .key == "discord_channel" then $coordinator
          else .value | if type == "array" then .[0] elif . == "array" then "[]" elif . == "number" then "7" elif . == "id" then $soon else "x y" end end)"),
      (select($k == "merge-approved") | "head=a1b2c3d4"),
      (select($k == "paused") | "cause=limit"), (select($k == "held") | "discord_message=\($soon)"),
      (select($k == "resumed") | "all=true"),
      (.kinds[$k].one_of // [] | .[] | "\(.[0])=x y")' "$CONTRACT")
    tip=$(git -C "$team_origin" rev-parse dev)
    run_bin -0 --separate-stderr team-log T14 "$kind" "${args[@]}"
    assert_equal "$output" ""
    assert_equal "$stderr" ""
    if jq -e --arg k "$kind" '.kinds[$k].push == true' "$CONTRACT" >/dev/null; then
      pushed+=("$kind")
      assert_equal "$(origin_subject)" "chore: ledger T14 $kind"
      assert_equal "$(git -C "$team_origin" rev-parse dev^)" "$tip"
      assert_equal "$(git -C "$team_origin" diff-tree -r --no-commit-id --name-only dev)" "ledger.jsonl"
      assert_equal "$(git -C "$team_origin" show dev:ledger.jsonl)" "$(cat "$TEAM_HOME/ledger.jsonl")"
      assert_equal "$(git -C "$TEAM_HOME" rev-parse HEAD)" "$(git -C "$team_origin" rev-parse dev)"
    else
      assert_equal "$(git -C "$team_origin" rev-parse dev)" "$tip"
    fi
  done < <(jq -r '.kinds | to_entries[] | select([.value.writer] | flatten | index("team-log")) | .key' "$CONTRACT")
  # The answered among them is one given at the terminal, with no discord_message.
  assert_equal "${pushed[*]}" "answered plan-approved merge-approved merge-preapproved merge-preapproval-withdrawn merge-standing merge-standing-withdrawn retro-schedule"
  [[ ! -e $HOME/.local/state/agent-team/last-checkpoint ]]
}

@test "a worker's message --from-message logs, of no push kind, makes no commit and no push" {
  push_home
  open_t7
  launched T7 builder b0000001
  local tip head
  tip=$(git -C "$team_origin" rev-parse dev) head=$(git -C "$TEAM_HOME" rev-parse HEAD)
  run_bin -0 --separate-stderr team-log T7 --from-message 'T7 DONE 01 a1b2c3d done'
  assert_equal "$stderr" ""
  assert_equal "$(tail -n 1 "$TEAM_HOME/ledger.jsonl" | jq -r .event)" "done"
  assert_equal "$(git -C "$team_origin" rev-parse dev)" "$tip"
  assert_equal "$(git -C "$TEAM_HOME" rev-parse HEAD)" "$head"
}

@test "a push that fails leaves the exit and stdout as they were, says why in one line, and the next checkpoint pushes the commit" {
  push_home
  opened_task T14
  git -C "$TEAM_HOME" remote set-url origin "$BATS_TEST_TMPDIR/gone.git"
  local tip
  tip=$(git -C "$team_origin" rev-parse dev)
  run_bin -0 --separate-stderr team-log T14 plan-approved by=Daniel
  assert_equal "$output" ""
  assert_equal "$stderr" "team-log: the ledger is not on origin yet (cannot push dev: '$BATS_TEST_TMPDIR/gone.git' does not appear to be a git repository); the next checkpoint pushes it"
  assert_equal "$(git -C "$TEAM_HOME" log -1 --format=%s)" "chore: ledger T14 plan-approved"
  assert_equal "$(git -C "$team_origin" rev-parse dev)" "$tip"

  git -C "$TEAM_HOME" remote set-url origin "$team_origin"
  run_bin -0 team-checkpoint --force
  assert_equal "$(git -C "$team_origin" log --format=%s "$tip..dev" | grep -c '^chore: ledger T14 plan-approved$')" 1
  assert_equal "$(git -C "$team_origin" show dev:ledger.jsonl | tail -n 1 | jq -r .event)" "plan-approved"
}

@test "a ledger the records hook refuses is the same one line with the hook's reason, and the exit stands" {
  push_home
  git -C "$TEAM_HOME" config core.hooksPath "$REPO_ROOT/bin/hooks/records-git"
  # A line written before the ledger's check, holding an address at a public provider.
  local provider=gmail.com head tip
  opened_task T14
  jq -cn --arg a "someone@$provider" '{ts: "2026-10-22T02:00:00Z", task: "T14", event: "paused", reason: "mail \($a)"}' \
    >>"$TEAM_HOME/ledger.jsonl"
  head=$(git -C "$TEAM_HOME" rev-parse HEAD) tip=$(git -C "$team_origin" rev-parse dev)
  run_bin -0 --separate-stderr team-log T14 plan-approved by=Daniel
  assert_equal "$output" ""
  assert_equal "$(wc -l <<<"$stderr")" 1
  # The hook's first line, which names the ledger, without the list of refusals it ends with.
  assert_equal "$stderr" "team-log: the ledger is not on origin yet (cannot commit the records: data-check: refused: ledger.jsonl adds an email address at a public provider or an image, which the records never take: other people's addresses and screenshots stay out of git; take each out, then commit again); the next checkpoint pushes it"
  assert_equal "$(git -C "$TEAM_HOME" rev-parse HEAD)" "$head"
  assert_equal "$(git -C "$team_origin" rev-parse dev)" "$tip"
  assert_equal "$(tail -n 1 "$TEAM_HOME/ledger.jsonl" | jq -r .event)" "plan-approved"
}

@test "a fenced machine, and one that lost the lease, commits and pushes no ledger, saying why" {
  push_home
  opened_task T14
  local head tip
  head=$(git -C "$TEAM_HOME" rev-parse HEAD) tip=$(git -C "$team_origin" rev-parse dev)
  echo '{"since": "2026-10-22T14:00:00Z", "holder": "laptop", "epoch": 2}' >"$HOME/.local/state/agent-team/fenced"
  run_bin -0 --separate-stderr team-log T14 plan-approved by=Daniel
  assert_equal "$output" ""
  assert_equal "$stderr" "team-log: the ledger is not on origin yet (home-pc is fenced since 2026-10-22T14:00:00Z (holder seen laptop, epoch 2): a fenced machine commits and pushes no ledger)"
  assert_equal "$(git -C "$TEAM_HOME" rev-parse HEAD)" "$head"
  assert_equal "$(git -C "$team_origin" rev-parse dev)" "$tip"

  rm "$HOME/.local/state/agent-team/fenced"
  make_machine laptop
  steal_lease laptop home-pc
  rm -f "$HOME/.local/state/agent-team/probe.json"
  run_bin -0 --separate-stderr team-log T14 plan-approved by=Daniel
  assert_equal "$output" ""
  [[ $stderr == "team-log: the ledger is not on origin yet (home-pc no longer holds the lease: origin names laptop ("*"): a machine that lost the lease commits and pushes no ledger)" ]]
  assert_equal "$(git -C "$TEAM_HOME" rev-parse HEAD)" "$head"
  assert_equal "$(git -C "$team_origin" rev-parse dev)" "$tip"
  assert_equal "$(logged_after 2 | jq -r .event)" "plan-approved
plan-approved"
}

@test "while the team holds offline, the push is skipped at once with no network call, saying the next checkpoint pushes it" {
  push_home
  opened_task T14
  local head tip
  head=$(git -C "$TEAM_HOME" rev-parse HEAD) tip=$(git -C "$team_origin" rev-parse dev)
  echo '{"since": "2026-10-22T14:00:00Z"}' >"$HOME/.local/state/agent-team/offline"
  rm -f "$HOME/.local/state/agent-team/probe.json"
  # An origin that would hang every call: the skip makes none.
  git -C "$TEAM_HOME" remote set-url origin "http://127.0.0.1:9/agent-team.git"
  run_bin -0 --separate-stderr team-log T14 plan-approved by=Daniel
  assert_equal "$output" ""
  assert_equal "$stderr" "team-log: the ledger is not on origin yet (GitHub is unreachable since $(date -d 2026-10-22T14:00:00Z +%H:%M), and the team is holding); the next checkpoint pushes it"
  assert_equal "$(git -C "$TEAM_HOME" rev-parse HEAD)" "$head"
  assert_equal "$(git -C "$team_origin" rev-parse dev)" "$tip"
  [[ ! -e $HOME/.local/state/agent-team/probe.json ]]

  # A fenced machine says it is fenced, offline or not.
  echo '{"since": "2026-10-22T14:00:00Z", "holder": "laptop", "epoch": 2}' >"$HOME/.local/state/agent-team/fenced"
  run_bin -0 --separate-stderr team-log T14 plan-approved by=Daniel
  [[ $stderr == "team-log: the ledger is not on origin yet (home-pc is fenced since "* ]]
}

@test "a team home with no origin, or that is no git checkout, prints nothing and fails nothing" {
  opened_task T14
  run_bin -0 --separate-stderr team-log T14 plan-approved by=Daniel
  assert_equal "$output" ""
  assert_equal "$stderr" ""
  git -C "$TEAM_HOME" init -q -b dev
  run_bin -0 --separate-stderr team-log T14 retro-schedule every_hours=48 discord_message="$(soon)"
  assert_equal "$output" ""
  assert_equal "$stderr" ""
  assert_equal "$(git -C "$TEAM_HOME" rev-list --all | wc -l)" 0
  assert_equal "$(logged_after 2 | jq -r .event)" "plan-approved
retro-schedule"
}

# T278's A-closed-task: team-log appended to a closed task and to one the ledger never opened.
@test "a closed task's held, asked and plan-approved, and a review of a task with no event, are warned and logged, and refused from lifecycle_from on" {
  printf '%s\n' \
    '{"ts":"2026-11-01T00:00:00Z","task":"T1","event":"opened","project":"p","path":"feature","branch":"feat/T1-x","worktree":"/w","title":"x"}' \
    '{"ts":"2026-11-01T09:00:00Z","task":"T1","event":"closed","archive":[],"returned":[],"kept":[]}' \
    >"$TEAM_HOME/ledger.jsonl"
  local note="(logged anyway; bin/lib/lifecycle.json refuses it from its lifecycle_from, not set yet)"
  local closed="T1 is closed, and a closed task takes no"
  local unopened="T99 is not opened (no opened event), and it takes only thread and opened before its opened, not review"
  with_lifecycle_from null
  run_bin -0 --separate-stderr team-log T1 held discord_message=1564000000000000020 reason="after close"
  assert_equal "$stderr" "team-log: lifecycle: $closed held $note"
  run_bin -0 --separate-stderr team-log T1 asked id=late text="asked after close"
  assert_equal "$stderr" "team-log: lifecycle: $closed asked $note"
  run_bin -0 --separate-stderr team-log T1 plan-approved by=coordinator
  assert_equal "$stderr" "team-log: lifecycle: $closed plan-approved $note"
  run_bin -0 --separate-stderr team-log T99 review verdict=pass head=abcdef1234567
  assert_equal "$stderr" "team-log: lifecycle: $unopened $note"
  assert_equal "$(jq -r '"\(.task) \(.event)"' "$TEAM_HOME/ledger.jsonl" | tail -n +3 | paste -sd ,)" \
    "T1 held,T1 asked,T1 plan-approved,T99 review"
  # From a time before the events, each is refused and nothing is logged.
  head -2 "$TEAM_HOME/ledger.jsonl" >"$BATS_TEST_TMPDIR/before.jsonl"
  cp "$BATS_TEST_TMPDIR/before.jsonl" "$TEAM_HOME/ledger.jsonl"
  with_lifecycle_from 2026-01-01T00:00:00Z
  run_bin -1 team-log T1 held discord_message=1564000000000000020 reason="after close"
  assert_equal "$output" "team-log: refusing a ledger event: lifecycle: $closed held"
  run_bin -1 team-log T1 asked id=late text="asked after close"
  assert_equal "$output" "team-log: refusing a ledger event: lifecycle: $closed asked"
  run_bin -1 team-log T1 plan-approved by=coordinator
  assert_equal "$output" "team-log: refusing a ledger event: lifecycle: $closed plan-approved"
  run_bin -1 team-log T99 review verdict=pass head=abcdef1234567
  assert_equal "$output" "team-log: refusing a ledger event: lifecycle: $unopened"
  cmp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/before.jsonl"
}

# T14's phase and standing parks' ids, by the fold over the ledger.
T14_state() {
  jq -L "$REPO_ROOT/bin/lib" -sc 'include "ledger"; map(select(.task == "T14")) | [phase, (lifecycle.parks | map(.id))]' \
    "$TEAM_HOME/ledger.jsonl"
}

@test "a resumed names what it ends, and one the fold would not end, or a second held, is warned and then refused" {
  opened_task T14
  local before
  before=$(cat "$TEAM_HOME/ledger.jsonl")
  run_bin -1 team-log T14 resumed
  assert_equal "$output" "team-log: resumed needs id=<a standing park>, all=true or brief=<brief>; team-state T14 lists the standing parks"
  run_bin -1 team-log T14 resumed all=false
  assert_equal "$output" "team-log: resumed needs id=<a standing park>, all=true or brief=<brief>; team-state T14 lists the standing parks"
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" "$before"
  run_bin -0 team-log T14 resumed all=true
  run_bin -0 team-log T14 resumed brief=brief-merge-base
  assert_equal "$(logged_after 2)" '{"task":"T14","event":"resumed","all":true}
{"task":"T14","event":"resumed","brief":"brief-merge-base"}'
  # Daniel's hold, a typed wait on an ask, then each resumed or held the fold would not take.
  printf '%s\n' \
    '{"ts":"2026-01-01T00:01:00Z","task":"T14","event":"held","cause":"daniel-hold","discord_message":"1564000000000000020","reason":"hold"}' \
    '{"ts":"2026-01-01T00:02:00Z","task":"T14","event":"asked","id":"door","text":"Which door?"}' \
    '{"ts":"2026-01-01T00:03:00Z","task":"T14","event":"waiting","on":"Daniel","cause":"ask","ask":"door","reason":"ask door"}' \
    >>"$TEAM_HOME/ledger.jsonl"
  cp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/before.jsonl"
  local note="(logged anyway; bin/lib/lifecycle.json refuses it from its lifecycle_from, not set yet)"
  local hold="held-1 is Daniel's hold, which only a resumed with discord_message, Daniel's word, lifts"
  local again="T14 is on Daniel's hold already: held-1 since 2026-01-01T00:01:00Z"
  local none="T14 has no standing park blocked-1; its standing parks: held-1, waiting-1"
  local ask="waiting-1 is the wait on ask door, which ends when the ask is answered (team-answer), not with a resumed"
  with_lifecycle_from null
  run_bin -0 --separate-stderr team-log T14 resumed id=held-1
  assert_equal "$stderr" "team-log: lifecycle: $hold $note"
  run_bin -0 --separate-stderr team-log T14 held discord_message=1567157155797139609 reason=again
  assert_equal "$stderr" "team-log: lifecycle: $again $note"
  run_bin -0 --separate-stderr team-log T14 resumed id=blocked-1
  assert_equal "$stderr" "team-log: lifecycle: $none, held-2 $note"
  run_bin -0 --separate-stderr team-log T14 resumed id=waiting-1
  assert_equal "$stderr" "team-log: lifecycle: $ask $note"
  # Each was logged, and the fold ended none of them: the hold and the wait stand.
  assert_equal "$(T14_state)" '["held",["held-1","waiting-1","held-2"]]'
  # From a time before them, each is refused and nothing is logged; Daniel's word lifts the hold.
  cp "$BATS_TEST_TMPDIR/before.jsonl" "$TEAM_HOME/ledger.jsonl"
  with_lifecycle_from 2026-01-01T00:00:00Z
  run_bin -1 team-log T14 resumed id=held-1
  assert_equal "$output" "team-log: refusing a ledger event: lifecycle: $hold"
  run_bin -1 team-log T14 held discord_message=1567157155797139609 reason=again
  assert_equal "$output" "team-log: refusing a ledger event: lifecycle: $again"
  run_bin -1 team-log T14 resumed id=blocked-1
  assert_equal "$output" "team-log: refusing a ledger event: lifecycle: $none"
  run_bin -1 team-log T14 resumed id=waiting-1
  assert_equal "$output" "team-log: refusing a ledger event: lifecycle: $ask"
  cmp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/before.jsonl"
  run_bin -0 --separate-stderr team-log T14 resumed id=held-1 discord_message=1567157155797139610
  assert_equal "$stderr" ""
  assert_equal "$(T14_state)" '["planning",["waiting-1"]]'
}
