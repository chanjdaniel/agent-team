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
  # Each launch prints the next session id, c0000001, c0000002...; the session list has none of
  # them, so team-worker stops nothing. Once $STUB_FIXTURES/fail-once exists, the next launch
  # fails and removes it.
  stub_script claude <<'EOF'
if [[ $* == "agents --json" ]]; then echo '[]'; exit 0; fi
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

# What a refusal must leave as it was: the ledger, the task's files and the claude calls.
state() {
  cat "$TEAM_HOME/ledger.jsonl"
  (cd "$TEAM_HOME/tasks" && find . -type f | sort)
  stub_calls claude
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
    '{"template":"builder-deliver","values":{"goal":"Coordinator toil goes to the scripts."}}'
  grep -qF 'Coordinator toil goes to the scripts.' "$TEAM_HOME/tasks/T7/brief-deliver.md"
  assert_equal "$(jq -r 'select(.event == "launch") | .brief' "$TEAM_HOME/ledger.jsonl" | tail -n 1)" brief-deliver
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

@test "a brief a launch already read is refused, not rendered again" {
  # Every other ticket done and the deliverer launched once; then 01 is built again.
  for n in 02 03 04; do event ticket-done "$(jq -cn --arg n "$n" '{ticket: $n, commits: ["0123456"]}')"; done
  echo "# delivered" >"$TEAM_HOME/tasks/T7/brief-deliver.md"
  launched d0000001 brief-deliver
  launched b0000009 brief-build-01
  refused "brief-deliver was launched already (T7-builder d0000001 at 2026-11-01T10:00:00Z), so it is not launched again" \
    T7 -- "T7 DONE 01 $sha again"
  assert_equal "$(cat "$TEAM_HOME/tasks/T7/brief-deliver.md")" "# delivered"
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
  event answered '{id: "scope", text: "This one.", discord_message: "1566347677472661545"}'
  grep -v plan-approved "$TEAM_HOME/ledger.jsonl" >"$BATS_TEST_TMPDIR/l" && cp "$BATS_TEST_TMPDIR/l" "$TEAM_HOME/ledger.jsonl"
  refused "T7 has no plan-approved, so no ticket hand-off" T7 -- "T7 DONE 01 $sha done"
  event plan-approved '{by: "coordinator"}'
  event closed '{archive: [], returned: [], kept: []}'
  refused "T7 is closed" T7 -- "T7 DONE 01 $sha done"
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
no hand-off for PAUSED"
  run_bin -0 team-next T7 -- "T7 QUESTION Which file holds the goal?"
  assert_equal "$output" "logged question role=builder text=Which file holds the goal?
no hand-off for QUESTION"
  # The same message again holds nothing new since the launch.
  run_bin -0 team-next T7 -- "T7 QUESTION Which file holds the goal?"
  assert_equal "$output" "already logged question role=builder text=Which file holds the goal?
no hand-off for QUESTION"
  run_bin -0 team-next T7 -- "T7 DONE review-ready $sha"
  assert_equal "$output" "logged done role=builder session=b0000001 report=review-ready $sha
no hand-off for DONE review-ready"
  assert_equal "$(logged_from $((count + 1)) | jq -r .event | tr '\n' ' ')" "paused question done "
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
  assert_contains "$output" "Usage: team-next T<n> [--from <session>] [--sent-back <list>] [--next <NN>] -- '<the worker's message>'"
  local manual=$REPO_ROOT/roles/coordinator.md
  grep -E '^4\. \*\*Build\.\*\*' -A 1 "$manual" | grep -qF '`team-next T<n> -- '"'"'<the message>'"'"'`'
  grep -qF -- '`--next NN`' "$manual"
  (($(wc -l <"$manual") <= 120))
}
