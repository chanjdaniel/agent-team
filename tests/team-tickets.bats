#!/usr/bin/env bats
# shellcheck disable=SC2154 # wt, task_dir and tickets are helpers/tickets.bash's
# team-tickets: a task's tickets read from each open worktree's task directory, with their strict
# Blocked by:, Waits for:, Phase: and Touches: lines and spec.md's Parallel: line, each said done,
# running, ready, waiting or blocked from the ledger; --check refuses a malformed set, a Touches:
# path outside scope.txt and two tickets that may build at once and share a path. The fixture
# tickets are T172's as planned (tests/fixtures/tickets-T172/), with no builder's ticks or notes,
# and a small set with Touches: lines, its scope.txt and spec.md (tests/fixtures/tickets-touches/);
# each test's ledger says which are done.

load helpers/common
load helpers/tickets

setup() {
  sandbox
  tickets_sandbox
  cp "$REPO_ROOT"/tests/fixtures/tickets-T172/*.md "$tickets/"
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

@test "--json prints the same as a list of objects, each done ticket with its build minutes" {
  build_launch 01 0a0a0a0a 2026-11-01T09:00:00Z
  ticket_done --at 2026-11-01T09:42:10Z 01
  ticket_done 02 03 04 05 06 07 08 09
  build_launch 10 a1b2c3d4
  run_bin -0 --separate-stderr team-tickets T172 --json
  assert_equal "$(jq length <<<"$output")" 19
  assert_equal "$(jq -c '.[9]' <<<"$output")" "$(jq -cn --arg f "$tickets/10-team-tickets.md" \
    '{ticket: "10", slug: "team-tickets", state: "running", project: "proj", file: $f, phase: 1, blocked_by: ["04"],
      waits_for: null, on: [], session: "a1b2c3d4", touches: null, minutes: null}')"
  assert_equal "$(jq -c '.[11] | [.state, .blocked_by, .on, .waits_for, .session, .minutes]' <<<"$output")" \
    '["blocked",["03","05","07","10"],["10"],"T171 merged (both edit `roles/coordinator.md`).",null,null]'
  # Done after a launch: its minutes, last; done by hand with no launch: null.
  assert_equal "$(jq -c '.[0] | [.state, .on, .session, .minutes]' <<<"$output")" '["done",[],null,42]'
  assert_equal "$(jq -c '.[0] | keys_unsorted | last' <<<"$output")" '"minutes"'
  assert_equal "$(jq -c '.[1] | [.state, .minutes]' <<<"$output")" '["done",null]'
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
  assert_equal "$output" "T172: 19 tickets, every Blocked by:, Waits for:, Phase:, Touches: and Parallel: line well-formed"
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

@test "a Phase: line, plain or bold, sets the ticket's phase, 1 without one; Phase in prose is none" {
  fresh_tickets
  ticket 01-one "Blocked by: None"
  ticket 02-two "**Blocked by:** 01" "**Phase:** 2"
  ticket 03-three "Blocked by: 02" "Phase: 2  " "Phase 2 is the merge ask." "- [ ] phase: three works"
  run_bin -0 --separate-stderr team-tickets T172 --json
  assert_equal "$(jq -c 'map([.ticket, .phase])' <<<"$output")" '[["01",1],["02",2],["03",2]]'
  run_bin -0 --separate-stderr team-tickets T172 --check
  assert_equal "$output" "T172: 3 tickets, every Blocked by:, Waits for:, Phase:, Touches: and Parallel: line well-formed"
}

@test "--check refuses a malformed or second Phase: line, and a blocker in a later phase than its ticket" {
  fresh_tickets
  ticket 01-one "Blocked by: 02"
  ticket 02-two "Blocked by: None" "Phase: 2"
  ticket 03-three "Blocked by: None" "Phase: two"
  ticket 04-four "Blocked by: None" "Phase: 1" "**Phase:** 2"
  ticket 05-five "Blocked by: None" "Phase: 0"
  run_bin -1 --separate-stderr team-tickets T172 --check
  assert_equal "$stderr" "team-tickets: $tickets/01-one.md:3: blocker 02 is in phase 2, after this ticket's phase 1
team-tickets: $tickets/03-three.md:4: a malformed Phase: line; write 'Phase: 2', a whole number from 1, the label optionally bold, nothing else on the line
team-tickets: $tickets/04-four.md:5: a second Phase: line (the first is line 4)
team-tickets: $tickets/05-five.md:4: a malformed Phase: line; write 'Phase: 2', a whole number from 1, the label optionally bold, nothing else on the line"
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

# touches_set: the task directory holds the Touches: fixture set, its tickets, scope.txt and spec.md.
touches_set() {
  fresh_tickets
  cp "$REPO_ROOT"/tests/fixtures/tickets-touches/tickets/*.md "$tickets/"
  cp "$REPO_ROOT"/tests/fixtures/tickets-touches/scope.txt "$REPO_ROOT"/tests/fixtures/tickets-touches/spec.md "$task_dir/"
}

@test "--check passes a set with Touches: lines and a Parallel: line; --json gives each ticket's touches" {
  touches_set
  run_bin -0 --separate-stderr team-tickets T172 --check
  assert_equal "$output" "T172: 7 tickets, every Blocked by:, Waits for:, Phase:, Touches: and Parallel: line well-formed"
  run_bin -0 --separate-stderr team-tickets T172 --json
  assert_equal "$(jq -c 'map([.ticket, .touches])' <<<"$output")" \
    '[["01",["bin/team-a","tests/team-a.bats"]],["02",["bin/lib/one.jq","tests/team-b.bats"]],["03",["bin/lib/","docs/manual.md"]],["04",["bin/team-a","docs/manual.md"]],["05",["docs/manual.md"]],["06",["bin/team-a"]],["07",null]]'
  # The text listing does not change.
  run_bin -0 --separate-stderr team-tickets T172
  assert_equal "$output" "01 ready   team-a
02 ready   lib-one
03 blocked lib-and-manual: on 01, 02
04 ready   team-a-again
05 blocked manual: on 04
06 blocked team-a-last: on 05
07 ready   unbounded"
}

@test "--check refuses a malformed or second Touches: line; one in prose, a list item or a fence is none" {
  fresh_tickets
  printf '%s\n' bin/team-a tests/team-a.bats docs/manual.md >"$task_dir/scope.txt"
  local form="a malformed Touches: line; write 'Touches: bin/team-next, tests/team-next.bats', repository paths as scope.txt has them (a directory ending in /) joined by ', ', with no leading /, no . or .., no glob and no space, the label optionally bold"
  ticket 01-lead "Blocked by: None" "Touches: /bin/team-a"
  ticket 02-dots "Blocked by: None" "Touches: bin/../team-a"
  ticket 03-dot "Blocked by: None" "Touches: ./bin/team-a"
  ticket 04-glob "Blocked by: None" "Touches: bin/*.sh"
  ticket 05-question "Blocked by: None" "Touches: bin/team-?"
  ticket 06-bracket "Blocked by: None" "Touches: bin/team-[ab]"
  ticket 07-comma "Blocked by: None" "Touches: bin/team-a,tests/team-a.bats"
  ticket 08-space "Blocked by: None" "Touches: bin/team-a tests/team-a.bats"
  ticket 09-empty "Blocked by: None" "**Touches:**"
  ticket 10-listed "Blocked by: None" "- Touches: bin/team-a"
  ticket 11-lower "Blocked by: None" "touches: bin/team-a"
  ticket 12-double "Blocked by: None" "Touches: bin//team-a"
  ticket 13-trailing "Blocked by: None" "Touches: bin/team-a, "
  ticket 14-second "Blocked by: None" "Touches: bin/team-a" "**Touches:** tests/team-a.bats"
  ticket 15-prose "Blocked by: None" "It reads the \`Touches:\` line." "- [ ] touches: every path" \
    '```' "Touches: /nowhere" '```' "Touches: docs/manual.md"
  ticket 16-backtick "Blocked by: None" "Touches: \`bin/team-a\`, \`docs/manual.md\`"
  run_bin -1 --separate-stderr team-tickets T172 --check
  local n
  for n in 01-lead 02-dots 03-dot 04-glob 05-question 06-bracket 07-comma 08-space 09-empty 10-listed 11-lower 12-double 13-trailing 16-backtick; do
    assert_contains "$stderr" "team-tickets: $tickets/$n.md:4: $form"
  done
  assert_contains "$stderr" "team-tickets: $tickets/14-second.md:5: a second Touches: line (the first is line 4)"
  [[ $stderr != *"15-prose"* ]]
  [[ $stderr != *'`bin/team-a`'* ]]
  # A directory ending in / is a well-formed path.
  fresh_tickets
  printf '%s\n' bin/lib/ tests/team-a.bats >"$task_dir/scope.txt"
  ticket 01-dir "Blocked by: None" "**Touches:** bin/lib/, tests/team-a.bats  "
  run_bin -0 --separate-stderr team-tickets T172 --check
  run_bin -0 --separate-stderr team-tickets T172 --json
  assert_equal "$(jq -c '.[0].touches' <<<"$output")" '["bin/lib/","tests/team-a.bats"]'
}

@test "--check refuses a Touches: path in no line of scope.txt, and a Touches: line with no scope.txt" {
  touches_set
  ticket 08-outside "Phase: 2" "Blocked by: 07" "Touches: bin/team-b, bin/lib/two.jq, bin/lib, tests/"
  run_bin -1 --separate-stderr team-tickets T172 --check
  assert_equal "$stderr" "team-tickets: $tickets/08-outside.md:5: bin/team-b is in no line of scope.txt
team-tickets: $tickets/08-outside.md:5: bin/lib is in no line of scope.txt
team-tickets: $tickets/08-outside.md:5: tests/ is in no line of scope.txt"
  rm "$task_dir/scope.txt"
  rm "$tickets/08-outside.md"
  run_bin -1 --separate-stderr team-tickets T172 --check
  assert_contains "$stderr" "team-tickets: $tickets/01-team-a.md:5: a Touches: line splits the task directory's scope.txt, and there is none"
  assert_contains "$stderr" "team-tickets: $tickets/06-team-a-last.md:7: a Touches: line splits the task directory's scope.txt, and there is none"
  [[ $stderr != *"07-unbounded"* ]]
  # With no Touches: line in any ticket, no scope.txt is needed.
  fresh_tickets
  rm "$task_dir/spec.md"
  ticket 01-plain "Blocked by: None"
  run_bin -0 --separate-stderr team-tickets T172 --check
}

@test "when every ticket has a Touches: line, a scope.txt line none covers is named" {
  touches_set
  printf '%s\n' "" "templates/" "docs/manual.md" >>"$task_dir/scope.txt"
  # 07 has no Touches: line, so the scope is not held to the tickets.
  run_bin -0 --separate-stderr team-tickets T172 --check
  ticket 07-unbounded "Phase: 2" "Blocked by: 06" "Touches: tests/team-b.bats"
  run_bin -1 --separate-stderr team-tickets T172 --check
  assert_equal "$stderr" "team-tickets: $task_dir/scope.txt:7: templates/ is in no ticket's Touches: line"
  # A Touches: path under a directory line covers it.
  ticket 07-unbounded "Phase: 2" "Blocked by: 06" "Touches: templates/briefs/build.md"
  run_bin -0 --separate-stderr team-tickets T172 --check
}

@test "--check refuses two tickets that may build at once and share a path, once at the higher one's Touches: line" {
  touches_set
  # 08 may build at once with 01, 02 and 03, none of which it blocks or is blocked by: it shares a
  # file with 01, a directory holding 02's file (which both touch) and the very directory with 03.
  ticket 08-shares "Blocked by: None" "Touches: tests/team-a.bats, bin/lib/"
  run_bin -1 --separate-stderr team-tickets T172 --check
  assert_equal "$stderr" "team-tickets: $tickets/08-shares.md:4: tickets 01 and 08 may build at once (phase 1, neither blocks the other) and both touch tests/team-a.bats; block one on the other, or split the path
team-tickets: $tickets/08-shares.md:4: tickets 02 and 08 may build at once (phase 1, neither blocks the other) and both touch bin/lib/one.jq; block one on the other, or split the path
team-tickets: $tickets/08-shares.md:4: tickets 03 and 08 may build at once (phase 1, neither blocks the other) and both touch bin/lib/; block one on the other, or split the path"
  # Blocked through a chain, 08 builds after both: nothing is named.
  ticket 08-shares "Blocked by: 03" "Touches: tests/team-a.bats, bin/lib/"
  run_bin -0 --separate-stderr team-tickets T172 --check
  # In phase 2, 08 shares bin/team-a with 04 and 06; 06 is ordered after 04, but neither orders 08.
  ticket 08-shares "Phase: 2" "Blocked by: None" "Touches: bin/team-a"
  run_bin -1 --separate-stderr team-tickets T172 --check
  assert_equal "$stderr" "team-tickets: $tickets/08-shares.md:5: tickets 04 and 08 may build at once (phase 2, neither blocks the other) and both touch bin/team-a; block one on the other, or split the path
team-tickets: $tickets/08-shares.md:5: tickets 06 and 08 may build at once (phase 2, neither blocks the other) and both touch bin/team-a; block one on the other, or split the path"
  # 07 has no Touches: line: it is never named, beside any ticket.
  [[ $stderr != *"tickets 07"* ]]
  [[ $stderr != *"and 07 "* ]]
}

@test "--check refuses a malformed or second Parallel: line in spec.md, and more caps than the tickets' phases" {
  touches_set
  local form="a malformed Parallel: line; write 'Parallel: 2' or 'Parallel: 2, 1', a cap from 1 to 3 per phase, the label optionally bold, nothing else on the line"
  local value
  for value in "Parallel: 0" "Parallel: 4" "Parallel: 2,1" "Parallel: two" "Parallel: 2, 1 for now" "- Parallel: 2" "parallel: 2" "**Parallel:**"; do
    printf '%s\n' "# spec" "" "$value" >"$task_dir/spec.md"
    run_bin -1 --separate-stderr team-tickets T172 --check
    assert_equal "$stderr" "team-tickets: $task_dir/spec.md:3: $form"
  done
  printf '%s\n' "# spec" "" "**Parallel:** 3" "Parallel: 1, 2" >"$task_dir/spec.md"
  run_bin -1 --separate-stderr team-tickets T172 --check
  assert_equal "$stderr" "team-tickets: $task_dir/spec.md:4: a second Parallel: line (the first is line 3)"
  printf '%s\n' "# spec" "" "Parallel: 2, 1, 3" >"$task_dir/spec.md"
  run_bin -1 --separate-stderr team-tickets T172 --check
  assert_equal "$stderr" "team-tickets: $task_dir/spec.md:3: Parallel: names 3 caps, but the tickets have 2 phases"
  # Fewer caps than phases are fine (the last holds for later ones), and so is no Parallel: line.
  printf '%s\n' "# spec" "" "**Parallel:** 3  " "The Parallel: line is the planner's." >"$task_dir/spec.md"
  run_bin -0 --separate-stderr team-tickets T172 --check
  rm "$task_dir/spec.md"
  run_bin -0 --separate-stderr team-tickets T172 --check
  # A Parallel: line in a ticket is no spec's line.
  ticket 08-parallel "Phase: 2" "Blocked by: 07" "Parallel: 9"
  run_bin -0 --separate-stderr team-tickets T172 --check
}

@test "each task directory's tickets are held to its own scope.txt, and tickets of two projects never share a path" {
  fresh_tickets
  printf '%s\n' bin/team-a >"$task_dir/scope.txt"
  ticket 01-first "Blocked by: None" "Touches: bin/team-a"
  local wt2=$BATS_TEST_TMPDIR/wt2
  mkdir -p "$wt2/.work/task/tickets"
  printf '%s\n' bin/team-a bin/team-b >"$wt2/.work/task/scope.txt"
  printf '# 02: second\n\nBlocked by: None\n\nTouches: bin/team-a, bin/team-b\n' >"$wt2/.work/task/tickets/02-second.md"
  event T172 worktree-added "$(jq -cn --arg wt "$wt2" \
    '{project: "other", branch: "feat/T172-other", base: "main", base_sha: "644a76b", worktree: $wt}')"
  run_bin -0 --separate-stderr team-tickets T172 --check
  # 01's directory has no bin/team-b, and the other's scope line is named at its own scope.txt.
  ticket 01-first "Blocked by: None" "Touches: bin/team-b"
  printf '%s\n' bin/team-c >>"$wt2/.work/task/scope.txt"
  run_bin -1 --separate-stderr team-tickets T172 --check
  assert_equal "$stderr" "team-tickets: $tickets/01-first.md:4: bin/team-b is in no line of scope.txt
team-tickets: $task_dir/scope.txt:1: bin/team-a is in no ticket's Touches: line
team-tickets: $wt2/.work/task/scope.txt:3: bin/team-c is in no ticket's Touches: line"
}

@test "a task with no tickets lists none; an unknown task is refused" {
  rm -r "${tickets:?}"
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
  assert_contains "$output" "Usage: team-tickets T<n> [--check | --json"
  assert_contains "$output" "Blocked by: None"
  assert_contains "$output" "Waits for:"
}

@test "the planner's role and briefs give the line formats, the Phase:, Touches: and Parallel: lines and the check, and the manual names team-tickets" {
  local file
  for file in roles/planner.md templates/briefs/planner-feature.md templates/briefs/planner-interview.md; do
    assert_contains "$(cat "$REPO_ROOT/$file")" '`Blocked by: None` or `Blocked by: 01, 03`'
    assert_contains "$(cat "$REPO_ROOT/$file")" '`Waits for: <an outside condition>`'
    assert_contains "$(cat "$REPO_ROOT/$file")" 'optionally bold'
    assert_contains "$(cat "$REPO_ROOT/$file")" 'team-tickets'
    assert_contains "$(cat "$REPO_ROOT/$file")" '`Phase: <n>` line'
    assert_contains "$(cat "$REPO_ROOT/$file")" '`Touches: bin/team-next, tests/team-next.bats`'
    assert_contains "$(cat "$REPO_ROOT/$file")" 'keep tickets that may build at once disjoint'
    assert_contains "$(cat "$REPO_ROOT/$file")" '`Parallel:` line in `spec.md`, a cap from 1 to 3 per phase'
  done
  assert_contains "$(cat "$REPO_ROOT/templates/briefs/planner-feature.md")" '`{{team_bin}}/team-tickets {{task}} --check`'
  assert_contains "$(cat "$REPO_ROOT/templates/briefs/planner-interview.md")" '`{{team_bin}}/team-tickets {{task}} --check`'
  # The planner may run that check for its own task, and only that.
  assert_contains "$(jq -r '.permissions.allow[]' "$REPO_ROOT/settings/planner.json")" \
    'Bash(@TEAM_CODE@/bin/team-tickets @TASK@ --check)'
  assert_contains "$(cat "$REPO_ROOT/roles/coordinator.md")" '`team-tickets T<n> --check`'
  assert_contains "$(cat "$REPO_ROOT/roles/coordinator.md")" '`team-tickets T<n>` shows'
}
