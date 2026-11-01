#!/usr/bin/env bats
# team-next: a worker's message taken to the task's next step. Its checks refuse with nothing
# changed; it logs the message's events through team-log once, and a builder's DONE <NN> launches
# the next ready ticket's builder, or the deliverer once every ticket is done, through team-brief
# and team-worker. T7 runs in proj, its worktree a real git worktree; claude is a stub whose
# launches print a fresh session id each.

load helpers/common

setup() {
  sandbox
  hold_lease home-pc >/dev/null
  primary=$(make_repo proj)
  wt=$HOME/slots/proj/1
  git -C "$primary" worktree add -q -b feat/T7-toil "$wt"
  cat >"$TEAM_HOME/projects.toml" <<'TOML'
[proj]
repo = "owner/proj"
path = "projects/proj"
base = "main"
delivery = "direct-pr"
merge_method = "merge"
required_checks = []
task_dir = ".scratch/task"
docs = []
toolkits = ["browser"]
pool = { provider = "git", slots = ["slots/proj/1", "slots/proj/2"] }
TOML
  mkdir -p "$TEAM_HOME/tasks/T7" "$wt/.scratch/task/tickets"
  printf '%s\n' "# T7 plan" "" "## Goal" "" "Coordinator toil goes to the scripts." "" "## Why" "" "Turns." \
    >"$TEAM_HOME/tasks/T7/plan.md"
  event opened "$(jq -cn --arg wt "$wt" '{project: "proj", path: "feature", type: "feat", title: "toil",
    branch: "feat/T7-toil", base: "main", base_sha: "0123456", worktree: $wt}')"
  event thread '{discord_thread: "1563000000000000012"}'
  event plan-approved '{by: "coordinator"}'
  ticket 01-first "Blocked by: None"
  ticket 02-second "Blocked by: 01"
  ticket 03-third "**Blocked by:** 01" "**Waits for:** T171 merged"
  ticket 04-fourth "Blocked by: 02"
  launched b0000001 brief-build-01 '["browser"]'
  sha=$(commit one.txt "feat: ticket 01")
  # Each launch prints the next session id, c0000001, c0000002...; the session list is
  # $STUB_FIXTURES/agents, else empty, so team-worker stops nothing. Once $STUB_FIXTURES/fail-once exists, the next launch
  # fails and removes it.
  stub_script claude <<'EOF'
if [[ $* == "agents --json" ]]; then cat "$STUB_FIXTURES/agents" 2>/dev/null || echo '[]'; exit 0; fi
if [[ $1 == stop ]]; then exit 0; fi
if [[ -e $STUB_FIXTURES/fail-once ]]; then
  rm "$STUB_FIXTURES/fail-once"
  echo "claude: could not start the session" >&2
  exit 1
fi
n=$(($(cat "$STUB_FIXTURES/count" 2>/dev/null || echo 0) + 1))
echo "$n" >"$STUB_FIXTURES/count"
echo "Started background session c000000$n (${*: -2:1}). Attach with: claude attach c000000$n"
EOF
}

# event <kind> '<jq object of the other fields>': append one T7 ledger line.
event() {
  jq -cn --arg event "$1" "{ts: \"2026-11-01T10:00:00Z\", task: \"T7\", event: \$event} + $2" >>"$TEAM_HOME/ledger.jsonl"
}

# launched <session> <brief> [<toolkits as JSON>] [<role>]: a launch in the worktree.
launched() {
  event launch "$(jq -cn --arg s "$1" --arg b "$2" --argjson k "${3:-[]}" --arg r "${4:-builder}" --arg wt "$wt" \
    '{role: $r, session: $s, worktree: $wt, toolkits: $k, project: "proj", branch: "feat/T7-toil", machine: "home-pc"}
     + (if $b == "" then {} else {brief: $b} end)')"
}

# ticket <NN-slug> <lines>...: a ticket file of those lines under a title.
ticket() {
  printf '%s\n' "# ${1%%-*}: ${1#*-}" "" "${@:2}" "" "- [ ] it works" >"$wt/.scratch/task/tickets/$1.md"
}

# commit <file> <subject>: a commit in the worktree; prints its full sha.
commit() {
  echo "$2" >"$wt/$1"
  git -C "$wt" add "$1"
  git -C "$wt" commit -q -m "$2"
  git -C "$wt" rev-parse HEAD
}

# The ledger's T7 lines from the n-th on, without ts.
logged_from() {
  tail -n +"$1" "$TEAM_HOME/ledger.jsonl" | jq -c 'del(.ts)'
}

# What a refusal must leave as it was: the ledger, the task's files and the claude calls but its
# reads of the session list.
state() {
  cat "$TEAM_HOME/ledger.jsonl"
  (cd "$TEAM_HOME/tasks" && find . -type f | sort)
  stub_calls claude | jq -c 'select(. != ["agents", "--json"])'
}

# refused <expected text> <team-next arguments>...: exit 1 naming it, with nothing changed.
refused() {
  local before
  before=$(state)
  run_bin -1 team-next "${@:2}"
  assert_contains "$output" "$1"
  assert_equal "$(state)" "$before"
}

# The claude calls that started a session.
bg_calls() {
  stub_calls claude | jq -c 'select(.[0] == "--bg")'
}

@test "a builder's DONE logs the ticket and the done, renders the next ready ticket's brief and launches its builder" {
  local count
  count=$(wc -l <"$TEAM_HOME/ledger.jsonl")
  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE 01 ${sha:0:8} team-log takes comma lists"
  assert_equal "$output" "logged ticket-done ticket=01 commits=[\"${sha:0:8}\"] note=team-log takes comma lists
logged done role=builder session=b0000001
brief $TEAM_HOME/tasks/T7/brief-build-02.md
launched T7-builder c0000001"
  assert_equal "$(logged_from $((count + 1)) | jq -c 'select(.event != "launch")')" \
    "{\"task\":\"T7\",\"event\":\"ticket-done\",\"ticket\":\"01\",\"commits\":[\"${sha:0:8}\"],\"note\":\"team-log takes comma lists\"}
{\"task\":\"T7\",\"event\":\"done\",\"role\":\"builder\",\"session\":\"b0000001\"}"
  # The launch: the next ready ticket (02; 03 waits for T171), in the worktree, with the latest
  # builder launch's toolkits, its brief logged.
  assert_equal "$(logged_from $((count + 1)) | jq -c 'select(.event == "launch") | {role, session, worktree, toolkits, brief}')" \
    "$(jq -cn --arg wt "$wt" '{role: "builder", session: "c0000001", worktree: $wt, toolkits: ["browser"], brief: "brief-build-02"}')"
  grep -qF 'Your ticket: number 02 in `.scratch/task/tickets/`.' "$TEAM_HOME/tasks/T7/brief-build-02.md"
  assert_equal "$(jq -c . "$TEAM_HOME/tasks/T7/brief-build-02.json")" '{"template":"builder-ticket","project":"proj","values":{"ticket":"02"}}'
  assert_equal "$(bg_calls | jq -r 'last')" "Read your brief at $(tail -n 2 <<<"$output" | head -n 1 | sed 's/^brief //')"
  assert_equal "$(bg_calls | jq -r 'index("--plugin-dir") as $i | .[$i + 1]')" "$REPO_ROOT/toolkits/browser"
  assert_equal "$(bg_calls | wc -l)" 1
}

@test "the brief path in the prompt is the one team-brief printed, and team-worker reads it" {
  run_bin -0 team-next T7 -- "T7 DONE 01 $sha done"
  local brief
  brief=$(grep '^brief ' <<<"$output" | sed 's/^brief //')
  assert_equal "$(bg_calls | jq -r 'last')" "Read your brief at $brief"
  [[ -f ${brief/#\~/$HOME} ]]
}

@test "a ticket with a Waits for: line is launched only when --next names it" {
  run_bin -0 team-next T7 --next 03 -- "T7 DONE 01 $sha done"
  assert_contains "$output" "launched T7-builder c0000001"
  [[ -f $TEAM_HOME/tasks/T7/brief-build-03.md ]]
  [[ ! -e $TEAM_HOME/tasks/T7/brief-build-02.md ]]
  assert_equal "$(jq -r 'select(.event == "launch") | .brief' "$TEAM_HOME/ledger.jsonl" | tail -n 1)" brief-build-03
}

@test "with only a waiting ticket left, it is refused, naming what each waits on, until --next names it" {
  event ticket-done '{ticket: "02", commits: ["0123456"]}'
  event ticket-done '{ticket: "04", commits: ["0123456"]}'
  refused "tickets remain once 01 is done, but none is ready: 03 waiting: T171 merged; --next <NN> launches a waiting one" \
    T7 -- "T7 DONE 01 $sha done"
  run_bin -0 team-next T7 --next 03 -- "T7 DONE 01 $sha done"
  assert_contains "$output" "launched T7-builder c0000001"
}

@test "tickets blocked or running are named when none is ready" {
  ticket 02-second "Blocked by: 01" "Waits for: PR 9"
  ticket 04-fourth "Blocked by: 03"
  ticket 05-fifth "Blocked by: None"
  launched b0000005 brief-build-05
  launched b0000001 brief-build-01
  refused "tickets remain once 01 is done, but none is ready: 02 waiting: PR 9; 03 waiting: T171 merged; 04 blocked on 03; 05 running in session b0000005" \
    T7 -- "T7 DONE 01 $sha done"
}

@test "with every ticket done it renders builder-deliver with the plan's goal and launches the deliverer" {
  for n in 02 03 04; do event ticket-done "$(jq -cn --arg n "$n" '{ticket: $n, commits: ["0123456"]}')"; done
  run_bin -0 team-next T7 -- "T7 DONE 01 $sha the last one"
  assert_contains "$output" "brief-deliver.md"
  assert_contains "$output" "launched T7-builder c0000001"
  assert_equal "$(jq -c '{template, values}' "$TEAM_HOME/tasks/T7/brief-deliver.json")" \
    '{"template":"builder-deliver","values":{"goal":"Coordinator toil goes to the scripts.","tickets":"every ticket"}}'
  grep -qF 'Coordinator toil goes to the scripts.' "$TEAM_HOME/tasks/T7/brief-deliver.md"
  assert_equal "$(jq -r 'select(.event == "launch") | .brief' "$TEAM_HOME/ledger.jsonl" | tail -n 1)" brief-deliver
}

@test "a phase's last ticket done launches that phase's deliverer, deliver-p<n>, before any ticket of the next phase" {
  local brief=$TEAM_HOME/tasks/T7/brief-deliver-p1.md
  ticket 02-second "Blocked by: 01" "Phase: 2"
  ticket 03-third "Blocked by: None" "**Phase:** 2"
  ticket 04-fourth "Blocked by: 02" "Phase: 2"
  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE 01 $sha the last of phase 1"
  assert_equal "$(tail -n 2 <<<"$output")" "brief $brief
launched T7-builder c0000001"
  assert_equal "$(record deliver-p1 | jq -cS .)" \
    '{"template":"builder-deliver","values":{"goal":"Coordinator toil goes to the scripts.","tickets":"every ticket of phase 1 (01)"}}'
  grep -qF 'you are the builder who delivers: every ticket of phase 1 (01) is done and pushed on `feat/T7-toil`.' "$brief"
  grep -qF 'the boxes of every ticket of phase 1 (01) are ticked' "$brief"
  [[ ! -e $TEAM_HOME/tasks/T7/brief-build-03.md ]]
  assert_equal "$(bg_calls | wc -l)" 1
}

@test "while a phase has tickets not done, the next ticket is that phase's, and --next refuses a later phase's" {
  ticket 02-second "Blocked by: 01"
  ticket 03-third "Blocked by: None" "Phase: 2"
  ticket 04-fourth "Blocked by: 03" "Phase: 2"
  refused "--next 03 is in phase 2, but phase 1 has tickets not done: 02 ready" T7 --next 03 -- "T7 DONE 01 $sha done"
  run_bin -0 team-next T7 -- "T7 DONE 01 $sha done"
  assert_contains "$output" "brief $TEAM_HOME/tasks/T7/brief-build-02.md"
  # None of phase 1's left ready: refused naming phase 1's alone.
  ticket 05-fifth "Blocked by: None"
  launched b0000005 brief-build-05
  refused "tickets of phase 1 remain once 01 is done, but none is ready: 02 running in session c0000001; 05 running in session b0000005" \
    T7 --from b0000001 -- "T7 DONE 01 ${sha:0:9} again"
}

@test "a later phase's deliverer is deliver-p<n>, and --next is refused while a phase's deliverer is due" {
  ticket 02-second "Blocked by: 01" "Phase: 2"
  ticket 03-third "Blocked by: None" "Phase: 3"
  ticket 04-fourth "Blocked by: 03" "Phase: 3"
  refused "phase 1's tickets are all done once 01 is, so its deliverer comes next, not --next 03" \
    T7 --next 03 -- "T7 DONE 01 $sha done"
  event ticket-done '{ticket: "01", commits: ["0123456"]}'
  launched b0000002 brief-build-02 '["browser"]'
  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE 02 $sha phase 2 done"
  assert_contains "$output" "brief $TEAM_HOME/tasks/T7/brief-deliver-p2.md"
  assert_equal "$(record deliver-p2 | jq -r .values.tickets)" "every ticket of phase 2 (02)"
}

@test "a launch that failed finishes on the rerun without logging again; a rerun after the launch is refused" {
  local count
  # 04 waits on 01 alone, so after the hand-off to 02 a rerun would still find a ready ticket.
  ticket 04-fourth "Blocked by: 01"
  count=$(wc -l <"$TEAM_HOME/ledger.jsonl")
  touch "$STUB_FIXTURES/fail-once"
  run_bin -1 team-next T7 -- "T7 DONE 01 $sha done"
  assert_contains "$output" "team-next: the launch failed; run the same command again to finish it, which logs nothing twice"
  assert_equal "$(logged_from $((count + 1)) | jq -r .event | tr '\n' ' ')" "ticket-done done "
  [[ -f $TEAM_HOME/tasks/T7/brief-build-02.md ]]

  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE 01 $sha done"
  assert_contains "$output" "already logged ticket-done ticket=01"
  assert_contains "$output" "already logged done role=builder session=b0000001"
  assert_contains "$output" "launched T7-builder c0000001"
  assert_equal "$(logged_from $((count + 1)) | jq -r .event | tr '\n' ' ')" "ticket-done done launch "

  refused "ticket 01 is already handed off: T7-builder c0000001 was launched at" T7 -- "T7 DONE 01 $sha done"
}

@test "a deliverer's brief a launch already read is kept, and the next deliverer takes the next free name" {
  # Every other ticket done and the deliverer launched once; then 01 is built again.
  for n in 02 03 04; do event ticket-done "$(jq -cn --arg n "$n" '{ticket: $n, commits: ["0123456"]}')"; done
  echo "# delivered" >"$TEAM_HOME/tasks/T7/brief-deliver.md"
  launched d0000001 brief-deliver
  launched b0000009 brief-build-01
  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE 01 $sha again"
  assert_contains "$output" "brief $TEAM_HOME/tasks/T7/brief-deliver-2.md"
  assert_equal "$(jq -r 'select(.event == "launch") | .brief' "$TEAM_HOME/ledger.jsonl" | tail -n 1)" brief-deliver-2
  assert_equal "$(cat "$TEAM_HOME/tasks/T7/brief-deliver.md")" "# delivered"
  # A one-phase task's deliverer says every ticket.
  grep -qF 'you are the builder who delivers: every ticket is done and pushed' "$TEAM_HOME/tasks/T7/brief-deliver-2.md"
}

@test "a running ticket is not ready for --next" {
  launched b0000002 brief-build-02
  launched b0000001 brief-build-01
  refused "--next 02 is not ready once 01 is done: 02 running in session b0000002" T7 --next 02 -- "T7 DONE 01 $sha done"
}

@test "refused with nothing changed: a closed task, a held task, an unanswered ask, no plan-approved" {
  event held '{reason: "Daniel paused it"}'
  refused "T7 is held since 2026-11-01T10:00:00Z: Daniel paused it" T7 -- "T7 DONE 01 $sha done"
  event resumed '{}'
  event asked '{id: "scope", text: "Which scope?"}'
  refused "T7 has an unanswered ask, scope, since 2026-11-01T10:00:00Z" T7 -- "T7 DONE 01 $sha done"
  event answered '{id: "scope", text: "This one.", discord_message: "1563000000000000045"}'
  grep -v plan-approved "$TEAM_HOME/ledger.jsonl" >"$BATS_TEST_TMPDIR/l" && cp "$BATS_TEST_TMPDIR/l" "$TEAM_HOME/ledger.jsonl"
  refused "T7 has no plan-approved, so no ticket hand-off" T7 -- "T7 DONE 01 $sha done"
  event plan-approved '{by: "coordinator"}'
  event closed '{archive: [], returned: [], kept: []}'
  refused "T7 is closed" T7 -- "T7 DONE 01 $sha done"
}

# The manual: a message team-next refuses for an open ask is logged with team-log --from-message,
# and team-next runs on it once the ask is settled, logging nothing twice.
@test "a DONE logged by team-log --from-message while an ask was open is handed off once it is answered, logged once" {
  event asked '{id: "scope", text: "Which scope?"}'
  refused "T7 has an unanswered ask, scope" T7 -- "T7 DONE 01 $sha done"
  run_bin -0 team-log T7 --from-message "T7 DONE 01 $sha done"
  event answered '{id: "scope", text: "This one.", discord_message: "1563000000000000045"}'
  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE 01 $sha done"
  assert_equal "$output" "already logged ticket-done ticket=01 commits=[\"$sha\"] note=done
already logged done role=builder session=b0000001
brief $TEAM_HOME/tasks/T7/brief-build-02.md
launched T7-builder c0000001"
  assert_equal "$(jq -c 'select(.event == "ticket-done" or .event == "done")' "$TEAM_HOME/ledger.jsonl" | wc -l)" 2
}

@test "refused with nothing changed: an unknown ticket, a sha the worktree's HEAD lacks, an unknown --next" {
  refused "T7 has no ticket 09: its tickets are 01, 02, 03, 04" T7 -- "T7 DONE 09 $sha done"
  refused "abcdef0 is not a commit the HEAD of $wt holds, so ticket 01 is not handed off" T7 -- "T7 DONE 01 $sha abcdef0 done"
  # A commit on another branch, which HEAD does not hold.
  git -C "$wt" checkout -q -b side
  local side
  side=$(commit two.txt "feat: elsewhere")
  git -C "$wt" checkout -q feat/T7-toil
  refused "$side is not a commit the HEAD of $wt holds" T7 -- "T7 DONE 01 $side done"
  refused "--next 08 is none of T7's tickets: they are 01, 02, 03, 04" T7 --next 08 -- "T7 DONE 01 $sha done"
  refused "--next 04 is not ready once 01 is done: 04 blocked on 02" T7 --next 04 -- "T7 DONE 01 $sha done"
}

@test "a message team-log cannot read is refused with its reason, nothing changed" {
  refused "team-log: the message is for T8, not T7" T7 -- "T8 DONE 01 $sha done"
  refused "team-log: DONE 01 takes one or more shas" T7 -- "T7 DONE 01 nosha done"
}

@test "any other message is logged and reported as having no hand-off" {
  local count
  count=$(wc -l <"$TEAM_HOME/ledger.jsonl")
  run_bin -0 team-next T7 -- "T7 PAUSED stowed"
  assert_equal "$output" "logged paused reason=stowed
no hand-off for PAUSED stowed: no review's sent-back findings wait for a round"
  run_bin -0 team-next T7 -- "T7 QUESTION Which file holds the goal?"
  assert_equal "$output" "logged question role=builder text=Which file holds the goal?
no hand-off for QUESTION"
  # The same message again holds nothing new since the launch.
  run_bin -0 team-next T7 -- "T7 QUESTION Which file holds the goal?"
  assert_equal "$output" "already logged question role=builder text=Which file holds the goal?
no hand-off for QUESTION"
  run_bin -0 team-next T7 -- "T7 DONE gate run=r1 head=0123456 outcome=pushed"
  assert_equal "$output" "logged gate-run run=r1 head=0123456 outcome=pushed
no hand-off for DONE gate"
  assert_equal "$(logged_from $((count + 1)) | jq -r .event | tr '\n' ' ')" "paused question gate-run "
  assert_equal "$(bg_calls)" ""
}

@test "--next with another message, and a malformed command line, are usage errors" {
  run_bin -2 team-next T7 --next 02 -- "T7 PAUSED stowed"
  assert_contains "$output" "--next is taken only with a builder's DONE <NN> message, not PAUSED"
  run_bin -2 team-next T7 -- ""
  assert_contains "$output" "missing the worker's message"
  run_bin -2 team-next T7 "T7 PAUSED stowed"
  assert_contains "$output" "missing '--' before the worker's message"
  run_bin -2 team-next 7 -- "T7 PAUSED stowed"
  assert_contains "$output" "usage: team-next T<n>"
  run_bin -2 team-next T7 --next 2 -- "T7 DONE 01 $sha done"
  assert_contains "$output" "--next takes a two-digit ticket number, got '2'"
  run_bin -2 team-next T7 --from x --from y -- "T7 PAUSED stowed"
  assert_contains "$output" "--from is given twice"
}

@test "--help prints the header, and the manual's step 4 names team-next within its 120 lines" {
  run_bin -0 team-next --help
  assert_contains "$output" "Usage: team-next T<n> [--from <session>] [--sent-back <list>] [--next <NN>] [--checks <file>]"
  assert_contains "$output" "[--since <file>] [--template rereview|verify] -- '<the worker's message>'"
  local manual=$REPO_ROOT/roles/coordinator.md
  grep -E '^4\. \*\*Build\.\*\*' -A 1 "$manual" | grep -qF '`team-next T<n> -- '"'"'<the message>'"'"'`'
  grep -qF -- '`--next NN`' "$manual"
  (($(wc -l <"$manual") <= 120))
}

# T172 ticket 13: a builder's PR, DONE review-ready or DONE merged launches a fresh reviewer.

url=https://github.com/owner/proj/pull/9

# on_github <PR number> <head> [<head branch>]: the gh stub answers gh pr view <number> --repo
# owner/proj with that head and head branch (the task's by default); any other PR is not found.
on_github() {
  jq -cn --arg head "$2" --arg branch "${3:-feat/T7-toil}" '{headRefOid: $head, headRefName: $branch}' \
    >"$STUB_FIXTURES/github-$1"
  stub_script gh <<'SH'
[[ $1 == pr && $2 == view && $4 == --repo && $5 == owner/proj ]] || { echo "unexpected gh $*" >&2; exit 1; }
answer=$STUB_FIXTURES/github-$3
[[ -f $answer ]] || { echo "GraphQL: Could not resolve to a PullRequest with the number of $3." >&2; exit 1; }
cat "$answer"
SH
}

# review_logged <verdict> <head> <sent_back as JSON> [<findings counts as JSON>]: a review of
# <head>, every count not given 0.
review_logged() {
  local counts=${4:-'{}'}
  event review "$(jq -cn --arg v "$1" --arg h "$2" --argjson s "$3" --argjson f "$counts" '{verdict: $v, head: $h, sent_back: $s,
    findings: ({blocking: 0, correctness: 0, security: 0, "real-data": 0, "note-change": 0, "note-before": 0} + $f),
    before: [], guarded: []}')"
}

# reviewed_once <head> <sent_back as JSON> [<findings counts as JSON>]: the PR logged at <head>,
# its first reviewer launched with the browser toolkit, its review of findings and its done.
reviewed_once() {
  event pr "$(jq -cn --arg url "$url" --arg h "$1" '{url: $url, head: $h}')"
  launched r0000001 brief-review '["browser"]' reviewer
  review_logged findings "$1" "$2" "${3:-}"
  event 'done' '{role: "reviewer", session: "r0000001"}'
}

# The brief record's template and values, compact.
record() {
  jq -c '{template, values}' "$TEAM_HOME/tasks/T7/brief-$1.json"
}

checks() {
  echo "1. team-next launches the reviewer." >"$BATS_TEST_TMPDIR/checks"
  echo "$BATS_TEST_TMPDIR/checks"
}

@test "a first PR with --checks logs the pr with GitHub's head, renders the reviewer brief naming it and launches a reviewer with the builder's toolkits" {
  local count
  on_github 9 "$sha"
  refused "T7 has no review yet, so its first reviewer needs --checks <file>, the review's checks" T7 -- "T7 PR $url"
  count=$(wc -l <"$TEAM_HOME/ledger.jsonl")
  run_bin -0 --separate-stderr team-next T7 --checks "$(checks)" -- "T7 PR $url"
  assert_equal "$output" "logged pr url=$url head=$sha
brief $TEAM_HOME/tasks/T7/brief-review.md
launched T7-reviewer c0000001"
  assert_equal "$(logged_from $((count + 1)) | jq -c 'select(.event != "launch")')" \
    "$(jq -cn --arg url "$url" --arg h "$sha" '{task: "T7", event: "pr", url: $url, head: $h}')"
  assert_equal "$(logged_from $((count + 1)) | jq -c 'select(.event == "launch") | {role, session, worktree, toolkits, brief}')" \
    "$(jq -cn --arg wt "$wt" '{role: "reviewer", session: "c0000001", worktree: $wt, toolkits: ["browser"], brief: "brief-review"}')"
  assert_equal "$(record review | jq -cS .)" \
    "$(jq -cnS --arg url "$url" --arg h "$sha" '{template: "reviewer", values: {checks: "1. team-next launches the reviewer.", head: $h, pr: $url}}')"
  grep -qF "review \`origin/main...$sha\`" "$TEAM_HOME/tasks/T7/brief-review.md"
  grep -qxF "1. team-next launches the reviewer." "$TEAM_HOME/tasks/T7/brief-review.md"
  assert_equal "$(bg_calls | jq -r 'last')" "Read your brief at $TEAM_HOME/tasks/T7/brief-review.md"
  assert_equal "$(bg_calls | wc -l)" 1
}

@test "a PR after a review renders rereview-2 with the derived since and the coordinator's words, and the next one rereview-3" {
  local fix fix2
  reviewed_once "$sha" '[1]' '{"blocking": 1}'
  fix=$(commit two.txt "fix: finding 1")
  on_github 9 "$fix"
  echo "Read the new test first." >"$BATS_TEST_TMPDIR/since"
  run_bin -0 --separate-stderr team-next T7 --since "$BATS_TEST_TMPDIR/since" -- "T7 PR $url"
  assert_equal "$output" "logged pr url=$url head=$fix
brief $TEAM_HOME/tasks/T7/brief-rereview-2.md
launched T7-reviewer c0000001"
  assert_equal "$(record rereview-2 | jq -c '{template, reviewed: .values.reviewed, head: .values.head, pr: .values.pr}')" \
    "$(jq -cn --arg url "$url" --arg r "$sha" --arg h "$fix" '{template: "rereview", reviewed: $r, head: $h, pr: $url}')"
  local brief=$TEAM_HOME/tasks/T7/brief-rereview-2.md
  grep -qF "The last review, of \`${sha:0:8}\`, had findings, and sent back 1." "$brief"
  grep -qF -- "- \`${fix:0:8}\` fix: finding 1" "$brief"
  grep -qF "The coordinator adds: Read the new test first." "$brief"
  # The reviewer takes the toolkits of the task's latest reviewer launch.
  assert_equal "$(jq -c 'select(.event == "launch") | {role, toolkits, brief}' "$TEAM_HOME/ledger.jsonl" | tail -n 1)" \
    '{"role":"reviewer","toolkits":["browser"],"brief":"brief-rereview-2"}'

  review_logged findings "$fix" '[2]' '{"blocking": 1}'
  fix2=$(commit three.txt "fix: finding 2")
  on_github 9 "$fix2"
  run_bin -0 --separate-stderr team-next T7 -- "T7 PR $url"
  assert_equal "$output" "logged pr url=$url head=$fix2
brief $TEAM_HOME/tasks/T7/brief-rereview-3.md
launched T7-reviewer c0000002"
  grep -qF -- "- \`${fix2:0:8}\` fix: finding 2" "$TEAM_HOME/tasks/T7/brief-rereview-3.md"
  if grep -qF "fix: finding 1" "$TEAM_HOME/tasks/T7/brief-rereview-3.md"; then return 1; fi
  assert_equal "$(record rereview-3 | jq -r .values.reviewed)" "$fix"
}

@test "a round whose findings were all plain notes, or that only edited the PR body, is re-reviewed with verify unless --template says" {
  local fix
  reviewed_once "$sha" '[3, 4]' '{"note-change": 2}'
  fix=$(commit two.txt "fix: notes 3 and 4")
  on_github 9 "$fix"
  echo "words" >"$BATS_TEST_TMPDIR/since"
  refused "--since is for a rereview; verify derives no since" T7 --since "$BATS_TEST_TMPDIR/since" -- "T7 PR $url"
  run_bin -0 --separate-stderr team-next T7 -- "T7 PR $url"
  assert_contains "$output" "brief $TEAM_HOME/tasks/T7/brief-rereview-2.md"
  assert_equal "$(record rereview-2 | jq -c '{template, findings: .values.findings}')" '{"template":"verify","findings":"3 and 4"}'

  # A blocking finding whose round only edited the PR body: the same head again.
  review_logged findings "$fix" '[5]' '{"blocking": 1}'
  run_bin -0 --separate-stderr team-next T7 -- "T7 PR $url"
  assert_equal "$output" "logged pr url=$url head=$fix
brief $TEAM_HOME/tasks/T7/brief-rereview-3.md
launched T7-reviewer c0000002"
  assert_equal "$(record rereview-3 | jq -r .template)" verify

  # --template chooses instead.
  review_logged findings "$fix" '[6]' '{"blocking": 1}'
  run_bin -0 --separate-stderr team-next T7 --template rereview -- "T7 PR $url"
  assert_equal "$(record rereview-4 | jq -r .template)" rereview
}

@test "a DONE merged renders the next rereview, its since naming the merge's conflicts, and refuses a sha that is not the worktree's HEAD" {
  local merge
  event pr "$(jq -cn --arg url "$url" --arg h "$sha" '{url: $url, head: $h}')"
  launched r0000001 brief-review '[]' reviewer
  review_logged pass "$sha" '[]'
  event 'done' '{role: "reviewer", session: "r0000001"}'
  # The base moves one.txt too; the builder merges it, resolving the conflict.
  echo "base" >"$primary/one.txt"
  git -C "$primary" add one.txt
  git -C "$primary" commit -q -m "feat: one on main"
  git -C "$primary" push -q origin main
  git -C "$wt" fetch -q origin
  git -C "$wt" merge -q origin/main >/dev/null 2>&1 || true
  echo "resolved" >"$wt/one.txt"
  git -C "$wt" add one.txt
  git -C "$wt" commit -q --no-edit
  merge=$(git -C "$wt" rev-parse HEAD)
  on_github 9 "$merge"

  refused "$sha is not the HEAD of $wt (${merge:0:8}), so it is not reviewed" T7 -- "T7 DONE merged main $sha conflicts: one.txt"
  refused "a DONE merged is re-reviewed with rereview, whose since names the merge; verify reads only a round's fix" \
    T7 --template verify -- "T7 DONE merged main $merge conflicts: one.txt"
  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE merged main $merge conflicts: one.txt"
  assert_equal "$output" "logged done role=builder session=b0000001 report=merged main $merge conflicts: one.txt
brief $TEAM_HOME/tasks/T7/brief-rereview-2.md
launched T7-reviewer c0000001"
  assert_equal "$(record rereview-2 | jq -c '{template, reviewed: .values.reviewed, head: .values.head}')" \
    "$(jq -cn --arg r "$sha" --arg h "$merge" '{template: "rereview", reviewed: $r, head: $h}')"
  grep -qF -- "- \`${merge:0:8}\` Merge remote-tracking branch 'origin/main' into feat/T7-toil: a merge of \`origin/main\`, conflicts in \`one.txt\`" \
    "$TEAM_HOME/tasks/T7/brief-rereview-2.md"
}

@test "a gated project's DONE review-ready of the worktree's HEAD logs no pr and launches the review of that head; any other sha is refused" {
  local head
  sed -i 's/^delivery = "direct-pr"/delivery = "no-mistakes"/' "$TEAM_HOME/projects.toml"
  head=$(commit two.txt "feat: ticket 02")
  refused "$sha is not the HEAD of $wt (${head:0:8}), so it is not reviewed" T7 --checks "$(checks)" -- "T7 DONE review-ready $sha"
  refused "abcdef1 is not the HEAD of $wt (${head:0:8}), so it is not reviewed" T7 --checks "$(checks)" -- "T7 DONE review-ready abcdef1"
  run_bin -0 --separate-stderr team-next T7 --checks "$(checks)" -- "T7 DONE review-ready ${head:0:10}"
  assert_equal "$output" "logged done role=builder session=b0000001 report=review-ready ${head:0:10}
brief $TEAM_HOME/tasks/T7/brief-review.md
launched T7-reviewer c0000001"
  assert_equal "$(jq -r 'select(.event == "pr")' "$TEAM_HOME/ledger.jsonl")" ""
  assert_equal "$(record review | jq -c '{template, head: .values.head, pr: .values.pr}')" \
    "$(jq -cn --arg h "$head" '{template: "reviewer", head: $h, pr: null}')"
  grep -qF "There is no PR yet" "$TEAM_HOME/tasks/T7/brief-review.md"
  grep -qF "review \`origin/main...$head\`" "$TEAM_HOME/tasks/T7/brief-review.md"
}

@test "a DONE review-ready with a run of whitespace before its sha reads the sha as team-log does" {
  local head
  sed -i 's/^delivery = "direct-pr"/delivery = "no-mistakes"/' "$TEAM_HOME/projects.toml"
  head=$(commit two.txt "feat: ticket 02")
  run_bin -0 --separate-stderr team-next T7 --checks "$(checks)" -- "T7 DONE review-ready  "$'\t'"${head:0:10}"
  assert_contains "$output" "launched T7-reviewer c0000001"
  assert_equal "$(record review | jq -r .values.head)" "$head"
}

@test "a PR whose head branch is not the task's logs branch-renamed too" {
  on_github 9 "$sha" feat/T7-toil-r2
  run_bin -0 --separate-stderr team-next T7 --checks "$(checks)" -- "T7 PR $url"
  assert_equal "$output" "logged pr url=$url head=$sha
logged branch-renamed project=proj branch=feat/T7-toil-r2
brief $TEAM_HOME/tasks/T7/brief-review.md
launched T7-reviewer c0000001"
}

@test "a review launch that failed finishes on the rerun without logging again; a rerun after the launch is refused" {
  local count
  on_github 9 "$sha" feat/T7-toil-r2
  count=$(wc -l <"$TEAM_HOME/ledger.jsonl")
  touch "$STUB_FIXTURES/fail-once"
  run_bin -1 team-next T7 --checks "$(checks)" -- "T7 PR $url"
  assert_contains "$output" "team-next: the launch failed; run the same command again to finish it, which logs nothing twice"
  assert_equal "$(logged_from $((count + 1)) | jq -r .event | tr '\n' ' ')" "pr branch-renamed "
  [[ -f $TEAM_HOME/tasks/T7/brief-review.md ]]

  run_bin -0 --separate-stderr team-next T7 --checks "$(checks)" -- "T7 PR $url"
  assert_equal "$output" "already logged pr url=$url head=$sha
brief $TEAM_HOME/tasks/T7/brief-review.md
launched T7-reviewer c0000001"
  assert_equal "$(logged_from $((count + 1)) | jq -r .event | tr '\n' ' ')" "pr branch-renamed launch "

  refused "PR is already handed off: T7-reviewer c0000001 was launched at" T7 --checks "$(checks)" -- "T7 PR $url"
  assert_equal "$(jq -c 'select(.event == "launch" and .role == "reviewer")' "$TEAM_HOME/ledger.jsonl" | wc -l)" 1
}

@test "a review launch's options are refused where they do not fit, nothing changed" {
  run_bin -2 team-next T7 --checks "$(checks)" -- "T7 PAUSED stowed"
  assert_contains "$output" "--checks is taken only with a builder's PR, DONE review-ready or DONE merged message, not PAUSED"
  run_bin -2 team-next T7 --template rereview -- "T7 DONE 01 $sha done"
  assert_contains "$output" "--template is taken only with a builder's PR, DONE review-ready or DONE merged message, not DONE <NN>"
  run_bin -2 team-next T7 --template review -- "T7 PR $url"
  assert_contains "$output" "--template takes rereview or verify, got 'review'"
  on_github 9 "$sha"
  refused "T7 has no review yet, so its first reviewer takes the reviewer brief, not --template verify" \
    T7 --checks "$(checks)" --template verify -- "T7 PR $url"
  refused "T7 has no review yet, so there is no since for --since" T7 --checks "$(checks)" --since "$(checks)" -- "T7 PR $url"
  reviewed_once "$sha" '[1]' '{"blocking": 1}'
  refused "T7 has a review already, so --checks is for its first reviewer only; a rereview takes --since" \
    T7 --checks "$(checks)" -- "T7 PR $url"
  # A PR in no repo of the task's.
  refused "team-log: https://github.com/owner/other/pull/9 is in no repo of T7's projects" T7 -- "T7 PR https://github.com/owner/other/pull/9"
}

@test "--help names the review launch's options, and the manual's step 5 and PR row name team-next" {
  run_bin -0 team-next --help
  assert_contains "$output" "--checks     with a review launch, the first review's checks file"
  assert_contains "$output" "rereview-<k>, the lowest k from 2 whose brief no launch read"
  local manual=$REPO_ROOT/roles/coordinator.md
  grep -E '^5\. \*\*Review\.\*\*' "$manual" | grep -qF '`team-next T<n> --checks <file> -- '"'"'<the message>'"'"'`'
  grep -qF '`team-next` (no `--checks`) launches the fresh reviewer that re-checks from the reviewed head' "$manual"
  grep -qF 'your own words added with `--since <file>`' "$manual"
  grep -E '^\| `PR <url>` \| `team-next` \| It starts the review \(step 5\)' "$manual"
  (($(wc -l <"$manual") <= 120))
}

# T172 ticket 14: a reviewer's verdict, and the fix round's stow.

counts="findings=blocking:0,correctness:0,security:0,real-data:0,note-change:0,note-before:0"

# pr_on_github <head> [<behind_by>] [<checks as JSON>]: the gh stub answers team-state's reads
# of PR 9 (open, against main, at <head>), its checks (agent-review passed by default), its
# required checks (none) and the compare of main with <head> (0 behind by default).
pr_on_github() {
  export GH_HEAD=$1 GH_BEHIND=${2:-0}
  export GH_CHECKS=${3:-'[{"name": "agent-review", "bucket": "pass", "state": "SUCCESS"}]'}
  stub_script gh <<'SH'
case "$*" in
  "pr view 9 --repo owner/proj --json number,state,baseRefName,headRefOid")
    jq -cn --arg h "$GH_HEAD" '{number: 9, state: "OPEN", baseRefName: "main", headRefOid: $h}' ;;
  "pr checks 9 --repo owner/proj --required"*) echo '[]' ;;
  "pr checks 9 --repo owner/proj"*) echo "$GH_CHECKS" ;;
  "api repos/owner/proj/compare/main...$GH_HEAD --jq .behind_by") echo "$GH_BEHIND" ;;
  *) echo "unplanned gh call: $*" >&2; exit 1 ;;
esac
SH
}

# reviewing <head> [<sent_back of an earlier review as JSON>]: the PR logged at <head> and a
# reviewer launched on brief-review, whose record names <head>; with a list, an earlier review
# and a round before it, so this reviewer is the re-review.
reviewing() {
  event pr "$(jq -cn --arg url "$url" --arg h "$1" '{url: $url, head: $h}')"
  if [[ -n ${2:-} ]]; then
    review_logged findings "$1" "$2" '{"blocking": 1}'
    launched b0000002 brief-round-1 '["browser"]'
  fi
  jq -cn --arg url "$url" --arg h "$1" '{template: "reviewer", project: "proj", values: {pr: $url, head: $h}}' \
    >"$TEAM_HOME/tasks/T7/brief-review.json"
  launched r0000002 brief-review '["browser"]' reviewer
}

# live <session> <context in tokens>...: the session list holds each session, idle, its
# transcript's latest reply having read that many tokens.
live() {
  local list='[]'
  mkdir -p "$HOME/.claude/projects/-wt"
  while (($#)); do
    list=$(jq -c --arg s "$1" '. + [{id: $s, sessionId: "\($s)-0000", kind: "background", status: "idle", state: "blocked"}]' <<<"$list")
    jq -cn --argjson n "$2" '{type: "assistant", message: {usage: {input_tokens: $n}}}' >"$HOME/.claude/projects/-wt/$1-0000.jsonl"
    shift 2
  done
  echo "$list" >"$STUB_FIXTURES/agents"
}

# The calls that could reach Discord, merge or post: curl's, and gh's beyond team-state's reads.
outside_calls() {
  stub_calls curl
  stub_calls gh | jq -c 'select((.[0] == "pr" and (.[1] == "view" or .[1] == "checks")) or (.[0] == "api" and (.[1] | test("/compare/"))) | not)'
}

@test "a pass whose PR head moved past the reviewed head is refused naming both, nothing logged" {
  local moved
  reviewing "$sha"
  moved=$(commit two.txt "feat: after the review")
  pr_on_github "$moved"
  refused "the PR's head $moved moved past the reviewed head $sha, so the pass is not taken; re-review the new head" \
    T7 -- "T7 DONE pass $url $counts before=none guarded=none"
}

@test "a pass logs the review at the reviewed head and prints the merge ask's facts, never posting or merging" {
  local count
  reviewing "$sha"
  pr_on_github "$sha"
  count=$(wc -l <"$TEAM_HOME/ledger.jsonl")
  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE pass $url $counts before=none guarded=ci"
  assert_equal "$output" "logged review verdict=pass head=$sha findings={\"blocking\":0,\"correctness\":0,\"security\":0,\"real-data\":0,\"note-change\":0,\"note-before\":0} before=[] guarded=[\"ci\"]
logged done role=reviewer session=r0000002
merge ask: $url at $sha, agent-review success, checks green; the review found guarded areas: ci"
  assert_equal "$(logged_from $((count + 1)) | jq -c '{event, verdict, head, guarded, role, session}')" \
    "$(jq -cn --arg h "$sha" '{event: "review", verdict: "pass", head: $h, guarded: ["ci"], role: null, session: null},
      {event: "done", verdict: null, head: null, guarded: null, role: "reviewer", session: "r0000002"}' | jq -c .)"
  assert_equal "$(outside_calls)" ""
  assert_equal "$(bg_calls)" ""
}

@test "a pass with before notes and pending checks names them, and a rerun logs nothing twice" {
  reviewing "$sha"
  pr_on_github "$sha" 0 '[{"name": "agent-review", "bucket": "pass", "state": "SUCCESS"}, {"name": "test", "bucket": "pending", "state": "PENDING"}]'
  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE pass $url ${counts%:0}:2 before=4,5 guarded=none"
  assert_equal "$(tail -n 1 <<<"$output")" \
    "merge ask: $url at $sha, agent-review success, checks pending: test; queue before notes 4 and 5 as follow-ups and say where each went"
  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE pass $url ${counts%:0}:2 before=4,5 guarded=none"
  assert_contains "$output" "already logged review verdict=pass head=$sha"
  assert_contains "$output" "already logged done role=reviewer session=r0000002"
  assert_equal "$(jq -c 'select(.event == "review")' "$TEAM_HOME/ledger.jsonl" | wc -l)" 1
}

@test "a pass on a PR behind its base prints the builder-merge-base step instead of the ask" {
  reviewing "$sha"
  pr_on_github "$sha" 3
  live b0000001 120000
  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE pass $url $counts before=none guarded=none"
  assert_contains "$output" "logged review verdict=pass head=$sha"
  assert_equal "$(tail -n 1 <<<"$output")" \
    "merge base: $url is 3 behind main, so it merges main first (step 6): render team-brief T7 builder-merge-base and send its path to T7-builder (b0000001, 120k)"
  # Past 250k, the holder stows and a fresh builder takes the brief.
  live b0000001 260000
  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE pass $url $counts before=none guarded=none"
  assert_equal "$(tail -n 1 <<<"$output")" \
    "merge base: $url is 3 behind main, so it merges main first (step 6): send T7 STOW to T7-builder (b0000001, 260k), then launch a fresh builder on team-brief T7 builder-merge-base"
  assert_equal "$(outside_calls)" ""
}

@test "a pass with a standing plan-time approval says merge pre-approved, unless the review found guarded areas" {
  sed -i 's/^merge_method = "merge"/&\nmerge_with_plan = true/' "$TEAM_HOME/projects.toml"
  event merge-preapproved '{project: "proj", ask: "plan", discord_message: "1563000000000000045", scope: ["one.txt"]}'
  reviewing "$sha"
  pr_on_github "$sha"
  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE pass $url $counts before=none guarded=none"
  assert_equal "$(tail -n 1 <<<"$output")" \
    "merge pre-approved: run team-merge T7 for $url at $sha, agent-review success, checks green"
  # A later review that found a guarded area brings the merge back to Daniel.
  launched r0000003 brief-review '["browser"]' reviewer
  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE pass $url $counts before=none guarded=ci,settings"
  assert_contains "$output" "logged review verdict=pass head=$sha"
  assert_equal "$(tail -n 1 <<<"$output")" \
    "merge ask: $url at $sha, agent-review success, checks green; the review found guarded areas: ci, settings, so the plan-time word does not hold"
  # A withdrawn approval no longer holds.
  event merge-preapproval-withdrawn '{project: "proj", discord_message: "1563000000000000046"}'
  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE pass $url $counts before=none guarded=none"
  assert_equal "$(tail -n 1 <<<"$output")" "merge ask: $url at $sha, agent-review success, checks green"
  assert_equal "$(outside_calls)" ""
}

@test "a pass counting findings that go back prints no merge line: refused until --sent-back sends them, then routed as findings are" {
  local back count
  sed -i 's/^merge_method = "merge"/&\nmerge_with_plan = true/' "$TEAM_HOME/projects.toml"
  event merge-preapproved '{project: "proj", ask: "plan", discord_message: "1563000000000000045", scope: ["one.txt"]}'
  reviewing "$sha"
  pr_on_github "$sha"
  live b0000001 120000
  echo "# review" >"$wt/.scratch/task/review.md"
  back=${counts/correctness:0/correctness:1}
  back=${back/note-change:0/note-change:2}
  local why="the pass counts 1 correctness and 2 note-change findings, which go back to the builder before the merge (step 5), so there is no merge yet: run it again with --sent-back <their numbers>, and the round goes as a DONE findings' does, through the holder or builder-round"
  refused "$why" T7 -- "T7 DONE pass $url $back before=none guarded=none"
  refused "$why" T7 --sent-back none -- "T7 DONE pass $url $back before=none guarded=none"
  refused "the pass counts 1 security finding, which goes back" T7 -- "T7 DONE pass $url ${counts/security:0/security:1} before=none guarded=none"
  count=$(wc -l <"$TEAM_HOME/ledger.jsonl")
  run_bin -0 --separate-stderr team-next T7 --sent-back 1,2,3 -- "T7 DONE pass $url $back before=none guarded=none"
  assert_equal "$(logged_from $((count + 1)) | jq -c 'select(.event == "review") | {verdict, sent_back}')" '{"verdict":"findings","sent_back":[1,2,3]}'
  assert_equal "$(tail -n 1 <<<"$output")" \
    "send to T7-builder (b0000001, 120k): T7 fix findings 1, 2 and 3 in .scratch/task/review.md on the same branch, then deliver again as your brief says"
  [[ $output != *merge* ]]
  # The holder's stow launches the round, as after findings.
  run_bin -0 --separate-stderr team-next T7 -- "T7 PAUSED stowed"
  assert_contains "$output" "brief $TEAM_HOME/tasks/T7/brief-round-1.md"
  assert_equal "$(record round-1 | jq -r .values.findings)" "1, 2 and 3"
  assert_equal "$(outside_calls)" ""
}

@test "a pass's fix message and its round's brief name the same findings file, a tie in mtime broken by name" {
  reviewing "$sha"
  pr_on_github "$sha"
  live b0000001 120000
  echo "# review" >"$wt/.scratch/task/review.md"
  echo "# rereview" >"$wt/.scratch/task/rereview-2.md"
  touch -d 2026-11-01T10:00:00Z "$wt/.scratch/task/review.md" "$wt/.scratch/task/rereview-2.md"
  run_bin -0 --separate-stderr team-next T7 --sent-back 1 -- "T7 DONE pass $url ${counts/correctness:0/correctness:1} before=none guarded=none"
  assert_equal "$(tail -n 1 <<<"$output")" \
    "send to T7-builder (b0000001, 120k): T7 fix findings 1 in .scratch/task/rereview-2.md on the same branch, then deliver again as your brief says"
  run_bin -0 --separate-stderr team-next T7 -- "T7 PAUSED stowed"
  assert_equal "$(record round-1 | jq -r .values.findings_file)" .scratch/task/rereview-2.md
}

@test "a security or real-data count on any review of the task, or a review with no counts, keeps the merge Daniel's" {
  sed -i 's/^merge_method = "merge"/&\nmerge_with_plan = true/' "$TEAM_HOME/projects.toml"
  event merge-preapproved '{project: "proj", ask: "plan", discord_message: "1563000000000000045", scope: ["one.txt"]}'
  review_logged findings 0123456 '[1]' '{"security": 1}'
  launched b0000002 brief-round-1 '["browser"]'
  reviewing "$sha"
  pr_on_github "$sha"
  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE pass $url $counts before=none guarded=none"
  assert_equal "$(tail -n 1 <<<"$output")" \
    "merge ask: $url at $sha, agent-review success, checks green; the review of 0123456 at 2026-11-01T10:00:00Z counted 1 security finding, so the plan-time word does not hold"
  # A review that logged no counts, and a real-data one, are named too.
  event review '{verdict: "findings", head: "89abcde", sent_back: [2], guarded: []}'
  review_logged findings fedcba9 '[1]' '{"real-data": 2}'
  launched r0000003 brief-review '["browser"]' reviewer
  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE pass $url $counts before=none guarded=ci"
  assert_equal "$(tail -n 1 <<<"$output")" \
    "merge ask: $url at $sha, agent-review success, checks green; the review found guarded areas: ci, so the plan-time word does not hold; the review of 0123456 at 2026-11-01T10:00:00Z counted 1 security finding, the review of 89abcde at 2026-11-01T10:00:00Z logged no counts and the review of fedcba9 at 2026-11-01T10:00:00Z counted 2 real-data findings, so the plan-time word does not hold"
  assert_equal "$(outside_calls)" ""
}

@test "a pass with no PR yet, a gated project's, tells the holding builder to go on" {
  sed -i 's/^delivery = "direct-pr"/delivery = "no-mistakes"/' "$TEAM_HOME/projects.toml"
  jq -cn --arg h "$sha" '{template: "reviewer", project: "proj", values: {head: $h}}' >"$TEAM_HOME/tasks/T7/brief-review.json"
  launched r0000002 brief-review '[]' reviewer
  live b0000001 90000
  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE pass $sha $counts before=none guarded=none"
  assert_equal "$(tail -n 1 <<<"$output")" \
    "send to T7-builder (b0000001, 90k): T7 the review of ${sha:0:8} passed: go on with your delivery"
  assert_equal "$(stub_calls gh)" ""
}

@test "a findings verdict needs --sent-back, logs it as numbers and routes the findings to the holder under 250k" {
  local count
  reviewing "$sha"
  pr_on_github "$sha"
  live b0000001 120000
  refused "a DONE findings needs --sent-back <list>, the numbers that go back to the builder (none for no fix round)" \
    T7 -- "T7 DONE findings .scratch/task/review.md $counts before=none guarded=none"
  count=$(wc -l <"$TEAM_HOME/ledger.jsonl")
  run_bin -0 --separate-stderr team-next T7 --sent-back 3,5 -- "T7 DONE findings .scratch/task/review.md ${counts/blocking:0/blocking:2} before=none guarded=none"
  assert_equal "$(logged_from $((count + 1)) | jq -c 'select(.event == "review") | {verdict, head, sent_back}')" \
    "$(jq -cn --arg h "$sha" '{verdict: "findings", head: $h, sent_back: [3, 5]}')"
  assert_equal "$(tail -n 1 <<<"$output")" \
    "send to T7-builder (b0000001, 120k): T7 fix findings 3 and 5 in .scratch/task/review.md on the same branch, then deliver again as your brief says"
  assert_equal "$(outside_calls)" ""
  assert_equal "$(bg_calls)" ""
}

@test "a findings verdict whose holder is at 250k or more, or gone, prints the STOW to send" {
  reviewing "$sha"
  pr_on_github "$sha"
  live b0000001 250000
  run_bin -0 --separate-stderr team-next T7 --sent-back 3 -- "T7 DONE findings .scratch/task/review.md ${counts/blocking:0/blocking:1} before=none guarded=none"
  assert_equal "$(tail -n 1 <<<"$output")" \
    "send to T7-builder (b0000001, 250k): T7 STOW; its PAUSED stowed goes to team-next, which launches the round"
  live
  run_bin -0 --separate-stderr team-next T7 --sent-back 3 -- "T7 DONE findings .scratch/task/review.md ${counts/blocking:0/blocking:1} before=none guarded=none"
  assert_contains "$output" "already logged review verdict=findings"
  assert_equal "$(tail -n 1 <<<"$output")" \
    "T7-builder b0000001 is gone: recover it (the recover-worker skill), then send it T7 STOW; its PAUSED stowed goes to team-next, which launches the round"
  # Nothing sent back: no round.
  run_bin -0 --separate-stderr team-next T7 --sent-back none -- "T7 DONE findings .scratch/task/review.md ${counts/note-before:0/note-before:1} before=2 guarded=none"
  assert_equal "$(tail -n 1 <<<"$output")" "no hand-off: the review sent nothing back, so there is no fix round"
}

@test "a PAUSED stowed after a findings review launches the round's builder with every fact derived, once" {
  local count
  reviewing "$sha"
  review_logged findings "$sha" '[3, 5]' '{"blocking": 2}'
  event 'done' '{role: "reviewer", session: "r0000002"}'
  echo "# review" >"$wt/.scratch/task/review.md"
  count=$(wc -l <"$TEAM_HOME/ledger.jsonl")
  run_bin -0 --separate-stderr team-next T7 -- "T7 PAUSED stowed"
  assert_equal "$output" "logged paused reason=stowed
brief $TEAM_HOME/tasks/T7/brief-round-1.md
launched T7-builder c0000001"
  assert_equal "$(record round-1 | jq -cS .)" "$(jq -cnS --arg url "$url" '{template: "builder-round",
    values: {findings: "3 and 5", findings_file: ".scratch/task/review.md", goal: "Coordinator toil goes to the scripts.", pr: $url}}')"
  assert_equal "$(logged_from $((count + 1)) | jq -c 'select(.event == "launch") | {role, worktree, toolkits, brief}')" \
    "$(jq -cn --arg wt "$wt" '{role: "builder", worktree: $wt, toolkits: ["browser"], brief: "brief-round-1"}')"
  # A second stow after that launch launches nothing.
  run_bin -0 --separate-stderr team-next T7 -- "T7 PAUSED stowed"
  assert_equal "$output" "logged paused reason=stowed
no hand-off for PAUSED stowed: no review's sent-back findings wait for a round"
  assert_equal "$(bg_calls | wc -l)" 1
}

@test "a PAUSED stowed whose round launch failed finishes on the rerun; one after a pass, or a re-review, launches nothing" {
  reviewing "$sha"
  review_logged findings "$sha" '[3]' '{"blocking": 1}'
  echo "# review" >"$wt/.scratch/task/review.md"
  touch "$STUB_FIXTURES/fail-once"
  run_bin -1 team-next T7 -- "T7 PAUSED stowed"
  run_bin -0 --separate-stderr team-next T7 -- "T7 PAUSED stowed"
  assert_equal "$output" "already logged paused reason=stowed
brief $TEAM_HOME/tasks/T7/brief-round-1.md
launched T7-builder c0000001"
  # The next round's stow after a re-review that had findings takes round-2.
  launched r0000003 brief-rereview-2 '[]' reviewer
  review_logged findings "$sha" '[4]' '{"blocking": 1}'
  run_bin -0 --separate-stderr team-next T7 -- "T7 PAUSED stowed"
  assert_contains "$output" "brief $TEAM_HOME/tasks/T7/brief-round-2.md"
  # A reviewer launched since the findings review means they were handed on.
  review_logged findings "$sha" '[6]' '{"blocking": 1}'
  launched r0000004 brief-rereview-3 '[]' reviewer
  run_bin -0 --separate-stderr team-next T7 -- "T7 PAUSED stowed"
  assert_contains "$output" "no hand-off for PAUSED stowed"
  # After a pass, nothing.
  review_logged pass "$sha" '[]'
  run_bin -0 --separate-stderr team-next T7 -- "T7 PAUSED stowed"
  assert_contains "$output" "no hand-off for PAUSED stowed"
  # The failed launch, round-1's and round-2's.
  assert_equal "$(bg_calls | wc -l)" 3
}

@test "a PAUSED stowed whose reason goes on after the word stowed is a stow; one that only starts with its letters is not" {
  reviewing "$sha"
  review_logged findings "$sha" '[3]' '{"blocking": 1}'
  echo "# review" >"$wt/.scratch/task/review.md"
  run_bin -0 --separate-stderr team-next T7 -- "T7 PAUSED stowedaway"
  assert_equal "$(tail -n 1 <<<"$output")" "no hand-off for PAUSED"
  run_bin -0 --separate-stderr team-next T7 -- "T7 PAUSED stowed, handoff.md written"
  assert_equal "$output" "logged paused reason=stowed, handoff.md written
brief $TEAM_HOME/tasks/T7/brief-round-1.md
launched T7-builder c0000001"
}

@test "team-next never runs team-post, team-merge or Discord, and the manual's steps 5 and 6 name the verdicts and the stow" {
  if grep -En 'sibling team-(post|merge|ask|answer|inbox|thread)|/team-(post|merge|ask|answer|inbox|thread)\b|discord_api|\bcurl\b' \
    "$REPO_ROOT/bin/team-next"; then return 1; fi
  local manual=$REPO_ROOT/roles/coordinator.md
  grep -qF '`team-next` logs a `DONE pass` and prints the merge ask' "$manual"
  grep -qF 'a `DONE findings` with `--sent-back <list>`' "$manual"
  grep -E '^\| `PAUSED stowed` \|.*`team-next`' "$manual"
  (($(wc -l <"$manual") <= 120))
}
