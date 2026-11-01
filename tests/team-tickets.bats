#!/usr/bin/env bats
# team-tickets: a task's tickets read from each open worktree's task directory, with their strict
# Blocked by: and Waits for: lines, each said done, running, ready, waiting or blocked from the
# ledger; --check refuses a malformed set. The fixture tickets are T172's own
# (tests/fixtures/tickets-T172/), whose tickets 01 to 09 were done when they were copied in.

load helpers/common

setup() {
  sandbox
  cat >"$TEAM_HOME/projects.toml" <<'TOML'
[proj]
repo = "owner/proj"
path = "projects/proj"
base = "dev"
delivery = "direct-pr"
merge_method = "merge"
required_checks = []
task_dir = ".scratch/task"
docs = []
toolkits = []

[proj.pool]
provider = "git"
slots = ["projects/proj-slots/1"]

[other]
repo = "owner/other"
path = "projects/other"
base = "main"
delivery = "direct-pr"
merge_method = "merge"
required_checks = []
task_dir = ".work/task"
docs = []
toolkits = []

[other.pool]
provider = "git"
slots = ["projects/other-slots/1"]
TOML
  wt=$BATS_TEST_TMPDIR/wt
  tickets=$wt/.scratch/task/tickets
  mkdir -p "$tickets"
  cp "$REPO_ROOT"/tests/fixtures/tickets-T172/*.md "$tickets/"
  event T172 opened "$(jq -cn --arg wt "$wt" '{project: "proj", path: "feature", type: "feat", title: "toil",
    branch: "feat/T172-toil", base: "dev", base_sha: "aba9d074", worktree: $wt}')"
}

# event <task> <kind> '<jq object of the other fields>': append one ledger line.
event() {
  jq -cn --arg task "$1" --arg event "$2" "{ts: \"2026-11-01T10:00:00Z\", task: \$task, event: \$event} + $3" \
    >>"$TEAM_HOME/ledger.jsonl"
}

# ticket_done <NN>...: a ticket-done of each.
ticket_done() {
  local n
  for n in "$@"; do
    event T172 ticket-done "$(jq -cn --arg n "$n" '{ticket: $n, commits: ["1f2f4a1"]}')"
  done
}

# build_launch <NN> <session>: a builder's launch on brief-build-<NN>.
build_launch() {
  event T172 launch "$(jq -cn --arg b "brief-build-$1" --arg s "$2" --arg wt "$wt" \
    '{role: "builder", session: $s, worktree: $wt, toolkits: [], brief: $b}')"
}

# ticket <NN-slug> <lines>...: write a ticket file of those lines under a title.
ticket() {
  printf '%s\n' "# ${1%%-*}: ${1#*-}" "" "${@:2}" "" "- [ ] it works" >"$tickets/$1.md"
}

# A fresh ticket set of the given files only.
fresh_tickets() {
  rm -f "$tickets"/*.md
}

@test "lists each fixture ticket with its state, and what a blocked one waits on" {
  ticket_done 01 02 03 04 05 06 07 08 09
  build_launch 10 a1b2c3d4
  run_bin -0 --separate-stderr team-tickets T172
  assert_equal "$output" "01 done    team-log-comma-lists-and-numeric-sent-back
02 done    the-denied-kind
03 done    team-log-from-message
04 done    team-worker-checks-the-brief
05 done    rereview-facts-from-the-ledger
06 done    project-review-rules
07 done    builder-round-and-deliver-defaults
08 done    checkpoint-every-record
09 done    team-current
10 running team-tickets: session a1b2c3d4
11 blocked progress-in-team-state: on 10
12 blocked team-next-ticket-hand-off: on 10
13 blocked team-next-review-launch: on 12
14 blocked team-next-verdict-and-fix-round: on 11, 13
15 blocked the-manual-in-the-team-next-era: on 14
16 blocked deny-git-reset-with-options: on 15
17 blocked team-automode-block: on 16
18 blocked denial-log-hook: on 17
19 blocked team-run-approved: on 15"
}

@test "a ticket whose blockers are done is ready, or waiting with its Waits for: text" {
  ticket_done 01 02 03 04 05 06 07 08 09 10
  run_bin -0 team-tickets T172
  assert_contains "$output" "10 done    team-tickets"
  assert_contains "$output" "11 ready   progress-in-team-state"
  assert_contains "$output" '12 waiting team-next-ticket-hand-off: T171 merged (both edit `roles/coordinator.md`).'
  assert_contains "$output" "13 blocked team-next-review-launch: on 12"
}

@test "--json prints the same as a list of objects" {
  ticket_done 01 02 03 04 05 06 07 08 09
  build_launch 10 a1b2c3d4
  run_bin -0 --separate-stderr team-tickets T172 --json
  assert_equal "$(jq length <<<"$output")" 19
  assert_equal "$(jq -c '.[9]' <<<"$output")" "$(jq -cn --arg f "$tickets/10-team-tickets.md" \
    '{ticket: "10", slug: "team-tickets", state: "running", project: "proj", file: $f, blocked_by: ["04"],
      waits_for: null, on: [], session: "a1b2c3d4"}')"
  assert_equal "$(jq -c '.[11] | [.state, .blocked_by, .on, .waits_for, .session]' <<<"$output")" \
    '["blocked",["03","05","07","10"],["10"],"T171 merged (both edit `roles/coordinator.md`).",null]'
  assert_equal "$(jq -c '.[0] | [.state, .on, .session]' <<<"$output")" '["done",[],null]'
}

@test "running needs a builder launch on brief-build-NN with no ticket-done of NN since" {
  ticket_done 01 02 03 04 05 06 07 08 09
  # Not this ticket's build brief, or not a builder: none of these runs ticket 11.
  build_launch 10b 11111111
  event T172 launch "$(jq -cn --arg wt "$wt" '{role: "reviewer", session: "22222222", worktree: $wt, toolkits: [],
    brief: "brief-build-11"}')"
  event T172 launch "$(jq -cn --arg wt "$wt" '{role: "builder", session: "33333333", worktree: $wt, toolkits: []}')"
  # Another task's launch on the same brief name.
  event T9 launch "$(jq -cn --arg wt "$wt" '{role: "builder", session: "44444444", worktree: $wt, toolkits: [],
    brief: "brief-build-10"}')"
  run_bin -0 team-tickets T172
  assert_contains "$output" "10 ready   team-tickets"$'\n'
  assert_contains "$output" "11 blocked progress-in-team-state: on 10"
  # Launched, then done: done. Launched again after its ticket-done (a rerun): running, on the
  # latest launch's session.
  build_launch 10 55555555
  ticket_done 10
  run_bin -0 team-tickets T172
  assert_contains "$output" "10 done    team-tickets"
  build_launch 10 66666666
  run_bin -0 team-tickets T172
  assert_contains "$output" "10 running team-tickets: session 66666666"
  # A running ticket's blocker is not done for the tickets it blocks.
  assert_contains "$output" "11 blocked progress-in-team-state: on 10"
}

@test "--check passes the fixture set and says how many tickets it read" {
  run_bin -0 --separate-stderr team-tickets T172 --check
  assert_equal "$output" "T172: 19 tickets, every Blocked by: and Waits for: line well-formed"
}

@test "the bold and the plain labels both parse" {
  fresh_tickets
  ticket 01-first "Blocked by: None"
  ticket 02-second "**Blocked by:** 01" "**Waits for:** T9 merged"
  ticket 03-third "Blocked by: 01, 02" "Waits for: PR 7"
  ticket_done 01
  run_bin -0 team-tickets T172 --check
  run_bin -0 team-tickets T172
  assert_equal "$output" "01 done    first
02 waiting second: T9 merged
03 blocked third: on 02"
}

@test "--check refuses a missing line, naming the file" {
  fresh_tickets
  ticket 01-first "Blocked by: None"
  ticket 02-second "Waits for: T9 merged"
  run_bin -1 --separate-stderr team-tickets T172 --check
  assert_equal "$stderr" "team-tickets: $tickets/02-second.md: no Blocked by: line; write 'Blocked by: None' or 'Blocked by: 01, 03'"
  # The listing refuses the same set, with the same reasons.
  run_bin -1 --separate-stderr team-tickets T172
  assert_equal "$output" ""
  assert_contains "$stderr" "$tickets/02-second.md: no Blocked by: line"
}

@test "--check refuses two Blocked by: lines and two Waits for: lines, naming each second line" {
  fresh_tickets
  ticket 01-first "Blocked by: None" "**Blocked by:** None"
  ticket 02-second "Blocked by: 01" "Waits for: T9 merged" "Waits for: PR 7"
  run_bin -1 --separate-stderr team-tickets T172 --check
  assert_contains "$stderr" "$tickets/01-first.md:4: a second Blocked by: line (the first is line 3)"
  assert_contains "$stderr" "$tickets/02-second.md:5: a second Waits for: line (the first is line 4)"
}

@test "--check refuses a Blocked by: line with anything else on it" {
  fresh_tickets
  ticket 01-first "Blocked by: None. Do it next"
  ticket 02-second "Blocked by: 01,03"
  ticket 03-third "- **Blocked by:** 1"
  ticket 04-fourth "blocked by: none"
  ticket 05-fifth "**Waits for:**"
  run_bin -1 --separate-stderr team-tickets T172 --check
  local form="write 'Blocked by: None' or 'Blocked by: 01, 03', the label optionally bold, nothing else on the line"
  assert_contains "$stderr" "$tickets/01-first.md:3: a malformed Blocked by: line; $form"
  assert_contains "$stderr" "$tickets/02-second.md:3: a malformed Blocked by: line; $form"
  assert_contains "$stderr" "$tickets/03-third.md:3: a malformed Blocked by: line; $form"
  assert_contains "$stderr" "$tickets/04-fourth.md:3: a malformed Blocked by: line; $form"
  assert_contains "$stderr" "$tickets/05-fifth.md:3: a malformed Waits for: line; write 'Waits for: <an outside condition>', the label optionally bold"
  # 05 has no Blocked by: line either.
  assert_contains "$stderr" "$tickets/05-fifth.md: no Blocked by: line"
}

@test "a Blocked by: mentioned inside a sentence, a list item or a code block is not a ticket's line" {
  fresh_tickets
  ticket 01-first "Blocked by: None" "It parses the \`Blocked by:\` line." \
    "- [ ] two \`Blocked by:\` lines are refused" '```' "Blocked by: 07" '```'
  run_bin -0 team-tickets T172 --check
}

@test "--check refuses a blocker that is no ticket, and a ticket number twice" {
  fresh_tickets
  ticket 01-first "Blocked by: None"
  ticket 02-second "Blocked by: 01, 07"
  ticket 03-third "Blocked by: 01, 01"
  run_bin -1 --separate-stderr team-tickets T172 --check
  assert_equal "$stderr" "team-tickets: $tickets/02-second.md:3: blocker 07 is no ticket of T172
team-tickets: $tickets/03-third.md:3: blocker 01 is named twice"
}

@test "--check refuses a cycle, naming the Blocked by: line of its lowest ticket" {
  fresh_tickets
  ticket 01-first "Blocked by: None"
  ticket 02-second "Blocked by: 01, 04"
  ticket 03-third "Blocked by: 02"
  ticket 04-fourth "Blocked by: 03"
  ticket 05-fifth "Blocked by: 05"
  run_bin -1 --separate-stderr team-tickets T172 --check
  assert_equal "$stderr" "team-tickets: $tickets/02-second.md:3: a cycle of blockers: 02 -> 04 -> 03 -> 02
team-tickets: $tickets/05-fifth.md:3: a cycle of blockers: 05 -> 05"
}

@test "--check refuses a file in tickets/ not named NN-<slug>.md" {
  fresh_tickets
  ticket 01-first "Blocked by: None"
  printf '# notes\n' >"$tickets/notes.md"
  printf '# third\n\nBlocked by: None\n' >"$tickets/3-third.md"
  run_bin -1 --separate-stderr team-tickets T172 --check
  assert_contains "$stderr" "$tickets/3-third.md: not named NN-<slug>.md, NN the ticket's two-digit number"
  assert_contains "$stderr" "$tickets/notes.md: not named NN-<slug>.md"
}

@test "reads the tickets of every open worktree of the task, each project's task_dir, as one set" {
  fresh_tickets
  ticket 01-first "Blocked by: None"
  local wt2=$BATS_TEST_TMPDIR/wt2
  mkdir -p "$wt2/.work/task/tickets"
  printf '# 02: second\n\n**Blocked by:** 01\n' >"$wt2/.work/task/tickets/02-second.md"
  event T172 worktree-added "$(jq -cn --arg wt "$wt2" \
    '{project: "other", branch: "feat/T172-other", base: "main", base_sha: "644a76b", worktree: $wt}')"
  ticket_done 01
  run_bin -0 team-tickets T172
  assert_equal "$output" "01 done    first
02 ready   second"
  run_bin -0 team-tickets T172 --json
  assert_equal "$(jq -c 'map(.project)' <<<"$output")" '["proj","other"]'
  # A number in both is refused.
  printf '# 01: again\n\nBlocked by: None\n' >"$wt2/.work/task/tickets/01-again.md"
  run_bin -1 --separate-stderr team-tickets T172 --check
  assert_contains "$stderr" "$wt2/.work/task/tickets/01-again.md: ticket 01 is also $tickets/01-first.md"
  # A returned worktree is no longer read.
  rm "$wt2/.work/task/tickets/01-again.md"
  event T172 worktree-returned "$(jq -cn --arg wt "$wt2" '{project: "other", worktree: $wt}')"
  run_bin -0 team-tickets T172
  assert_equal "$output" "01 done    first"
}

@test "a task with no tickets lists none; an unknown task is refused" {
  rm -r "$tickets"
  run_bin -0 --separate-stderr team-tickets T172
  assert_equal "$output" ""
  assert_equal "$stderr" "team-tickets: T172 has no tickets in its open worktrees"
  run_bin -0 --separate-stderr team-tickets T172 --json
  assert_equal "$output" "[]"
  run_bin -0 --separate-stderr team-tickets T172 --check
  assert_equal "$output" ""
  assert_equal "$stderr" "team-tickets: T172 has no tickets in its open worktrees"
  run_bin -1 --separate-stderr team-tickets T404
  assert_contains "$stderr" "unknown task T404"
}

@test "a malformed command line is a usage error" {
  run_bin -2 team-tickets
  run_bin -2 team-tickets 172
  run_bin -2 team-tickets T172 --bogus
  run_bin -2 team-tickets T172 T173
  run_bin -2 team-tickets T172 --check --json
}

@test "it never writes: the ledger and the tickets are unchanged" {
  ticket_done 01
  local before
  before=$(cat "$TEAM_HOME/ledger.jsonl"; cat "$tickets"/*.md)
  run_bin -0 team-tickets T172
  run_bin -0 team-tickets T172 --check
  run_bin -0 team-tickets T172 --json
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl"; cat "$tickets"/*.md)" "$before"
}

@test "--help prints the header with both line formats" {
  run_bin -0 team-tickets --help
  assert_contains "$output" "Usage: team-tickets T<n> [--check] [--json]"
  assert_contains "$output" "Blocked by: None"
  assert_contains "$output" "Waits for:"
}

@test "the planner's role and briefs give both line formats and the check, and the manual names team-tickets" {
  local file
  for file in roles/planner.md templates/briefs/planner-feature.md templates/briefs/planner-interview.md; do
    assert_contains "$(cat "$REPO_ROOT/$file")" '`Blocked by: None` or `Blocked by: 01, 03`'
    assert_contains "$(cat "$REPO_ROOT/$file")" '`Waits for: <an outside condition>`'
    assert_contains "$(cat "$REPO_ROOT/$file")" 'optionally bold'
    assert_contains "$(cat "$REPO_ROOT/$file")" 'team-tickets'
  done
  assert_contains "$(cat "$REPO_ROOT/templates/briefs/planner-feature.md")" '`{{team_bin}}/team-tickets {{task}} --check`'
  assert_contains "$(cat "$REPO_ROOT/templates/briefs/planner-interview.md")" '`{{team_bin}}/team-tickets {{task}} --check`'
  # The planner may run that check for its own task, and only that.
  assert_contains "$(jq -r '.permissions.allow[]' "$REPO_ROOT/settings/planner.json")" \
    'Bash(@TEAM_CODE@/bin/team-tickets @TASK@ --check)'
  assert_contains "$(cat "$REPO_ROOT/roles/coordinator.md")" '`team-tickets T<n> --check`'
  assert_contains "$(cat "$REPO_ROOT/roles/coordinator.md")" '`team-tickets T<n>` shows'
}
