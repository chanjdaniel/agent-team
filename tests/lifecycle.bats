#!/usr/bin/env bats
# The task lifecycle: bin/lib/lifecycle.json's table and the fold in bin/lib/ledger.jq that reads
# a task's events into its status, phase, PRs, parks, asks and stow, over synthetic events.

load helpers/common

setup() {
  sandbox
  events=()
}

# on <kind> [<jq object of more fields>]: add an event of T1 to the events, a minute after the one
# before it, from 2026-11-01T00:00:00Z.
on() {
  events+=("$(jq -cn --arg e "$1" --argjson n "${#events[@]}" \
    '{ts: ("2026-11-01T00:00:00Z" | fromdate + $n * 60 | todate), task: "T1", event: $e} + ('"${2:-{\}}"')')")
}

# fold_read <filter>: the filter's output over the events so far, with ledger.jq's definitions and
# the contract as $contract, compact, strings raw.
fold_read() {
  printf '%s\n' "${events[@]}" | jq -L "$REPO_ROOT/bin/lib" -scr --slurpfile contract "$REPO_ROOT/bin/lib/ledger-contract.json" \
    "include \"ledger\"; \$contract[0] as \$contract | $1"
}

# opened <path>: T1 opened on <path>.
opened() {
  on opened "{project: \"proj\", path: \"$1\", type: \"feat\", title: \"The tooling\", branch: \"feat/T1-tooling\",
    base: \"dev\", base_sha: \"0123456\", worktree: \"/w/1\"}"
}

builder_launch() {
  on launch "{role: \"builder\", session: \"${1:-b1}\", worktree: \"/w/1\", toolkits: []}"
}

@test "the table names only contract kinds, implemented effects, and known statuses and phases" {
  run fold_read 'lifecycle_table as $t
    | [($t.kinds | keys[] | select(in($contract.kinds) | not) | "kind \(.) is no contract kind"),
       ($t.kinds | to_entries[] | select(.value.effect != null and (.value.effect | IN(lifecycle_effects[]) | not))
         | "kind \(.key) has effect \(.value.effect), which the fold does not implement"),
       (($t.kinds[] , $t.default) | .status // [] | .[] | select(IN(lifecycle_statuses[]) | not) | "status \(.) is unknown"),
       (($t.kinds[], $t.default) | .phases // [] | .[] | select(IN($t.phases[]) | not) | "phase \(.) is unknown"),
       ($t.start[] | select(IN($t.phases[]) | not) | "start phase \(.) is unknown"),
       ($t.refusing_writers[] | select(IN($contract.kinds[] | .writer | if type == "array" then .[] else . end) | not)
         | "refusing writer \(.) writes no kind")]'
  assert_equal "$status" 0
  assert_equal "$output" "[]"
  # The table is a contract kind's entry or none, so a kind the contract drops cannot linger here.
  assert_equal "$(fold_read 'lifecycle_table | .lifecycle_from, .causes')" "$(printf 'null\n{}')"
}

@test "a feature task plans, builds on its plan, is in review on its PR and awaits merge once every open PR's head passed" {
  assert_equal "$(fold_read 'task_status + " " + phase')" "unknown planning"
  on thread '{discord_thread: "1563"}'
  assert_equal "$(fold_read 'task_status + " " + phase')" "legacy planning"
  opened feature
  assert_equal "$(fold_read 'task_status + " " + phase')" "open planning"
  on plan-approved '{by: "Daniel"}'
  assert_equal "$(fold_read phase)" building
  assert_equal "$(fold_read 'lifecycle.since')" "2026-11-01T00:02:00Z"
  on pr '{url: "https://github.com/owner/proj/pull/5", head: "1111111"}'
  assert_equal "$(fold_read phase)" in-review
  on pr '{url: "https://github.com/owner/conv/pull/3", head: "2222222"}'
  on review '{verdict: "pass", head: "1111111"}'
  assert_equal "$(fold_read phase)" in-review
  on review '{verdict: "pass", head: "2222222aaaa"}'
  assert_equal "$(fold_read phase)" awaiting-merge
  assert_equal "$(fold_read 'lifecycle.prs | map([.number, .verdict, .merged])')" '[[5,"pass",false],[3,"pass",false]]'
  # A rewrite moves the PR's head, and the pass on the old head no longer counts.
  on history-rewritten '{project: "proj", branch: "feat/T1-tooling", old_head: "1111111", head: "3333333"}'
  assert_equal "$(fold_read phase)" in-review
  assert_equal "$(fold_read 'lifecycle.prs | map([.head, .verdict])')" '[["3333333",null],["2222222","pass"]]'
  on review '{verdict: "pass", head: "3333333"}'
  assert_equal "$(fold_read phase)" awaiting-merge
  # A new pr in a repo replaces its PR, at a head no review has passed.
  on pr '{url: "https://github.com/owner/proj/pull/6", head: "4444444"}'
  assert_equal "$(fold_read phase)" in-review
  assert_equal "$(fold_read 'task_prs')" \
    '[{"url":"https://github.com/owner/conv/pull/3","head":"2222222","number":3},{"url":"https://github.com/owner/proj/pull/6","head":"4444444","number":6}]'
  on closed '{archive: [], returned: [], kept: []}'
  assert_equal "$(fold_read 'task_status + " " + phase')" "closed closed"
}

@test "a pass on a fix's head counts for the pr logged at that head after it, as for a rewrite to it" {
  opened feature
  on pr '{url: "https://github.com/owner/proj/pull/5", head: "1111111"}'
  on review '{verdict: "findings", head: "1111111"}'
  # The fix was reviewed at its head before the delivering builder logged the PR there.
  on review '{verdict: "pass", head: "2222222"}'
  assert_equal "$(fold_read phase)" in-review
  on pr '{url: "https://github.com/owner/proj/pull/5", head: "2222222"}'
  assert_equal "$(fold_read phase)" awaiting-merge
  on history-rewritten '{project: "proj", branch: "feat/T1-tooling", old_head: "2222222", head: "1111111"}'
  assert_equal "$(fold_read 'phase + " " + (lifecycle.prs[0].verdict)')" "in-review findings"
}

@test "a rewrite with no PR logged moves no phase, while a review puts a building task in review" {
  opened small
  on history-rewritten '{project: "proj", branch: "feat/T1-tooling", old_head: "1111111", head: "2222222"}'
  assert_equal "$(fold_read phase)" building
  on review '{verdict: "findings", head: "2222222"}'
  assert_equal "$(fold_read phase)" in-review
}

@test "a small or bug task builds from its open, a research or retro task plans, and a path the table lacks plans" {
  local path want
  for path in small:building bug:building research:planning retro:planning feature:planning other:planning; do
    events=()
    opened "${path%%:*}"
    want=${path#*:}
    assert_equal "$path $(fold_read 'phase + " " + lifecycle.path + " " + lifecycle.since')" \
      "$path $want ${path%%:*} 2026-11-01T00:00:00Z"
  done
}

@test "a builder's report of review-ready or merged puts the task in review, and no other done does" {
  opened small
  on done '{role: "builder", session: "b1", report: "05"}'
  on done '{role: "reviewer", session: "r1", report: "review-ready https://x"}'
  assert_equal "$(fold_read phase)" building
  on done '{role: "builder", session: "b1", report: "review-ready https://github.com/owner/proj/pull/5"}'
  assert_equal "$(fold_read phase)" in-review
}

@test "a merged naming phases left is a merged part, and one naming none, or [], is merged" {
  local left want
  for left in '[2]:merged-part' '[]:merged' 'null:merged'; do
    events=()
    opened feature
    on plan-approved '{by: "Daniel"}'
    on pr '{url: "https://github.com/owner/proj/pull/5", head: "1111111"}'
    on review '{verdict: "pass", head: "1111111"}'
    on merged "{pr: 5, merge: \"fedcba9\", head: \"1111111\", by: \"Daniel\", url: \"https://github.com/owner/proj/pull/5\"}
      + if ${left%%:*} == null then {} else {phases_left: ${left%%:*}} end"
    want=${left#*:}
    assert_equal "$left $(fold_read phase)" "$left $want"
  done
  # The contract takes phases_left as a list of whole numbers, and only that.
  assert_equal "$(fold_read '[.[-1] | append_problems($contract; "team-merge")]')" '[]'
  on merged '{pr: 5, merge: "fedcba9", head: "1111111", by: "Daniel", phases_left: ["2"]}'
  assert_contains "$(fold_read '[.[-1] | append_problems($contract; "team-merge")] | join("; ")')" "phases_left must be"
}

@test "after a merge, a builder launch or a ticket-done builds again and a pr is in review" {
  local after want
  for after in launch:building ticket-done:building pr:in-review review:merged-part other-launch:merged-part; do
    events=()
    opened feature
    on plan-approved '{by: "Daniel"}'
    on pr '{url: "https://github.com/owner/proj/pull/5", head: "1111111"}'
    on merged '{pr: 5, merge: "fedcba9", head: "1111111", by: "Daniel", phases_left: [2]}'
    case ${after%%:*} in
      launch) builder_launch b2 ;;
      other-launch) on launch '{role: "reviewer", session: "r2", worktree: "/w/1", toolkits: []}' ;;
      ticket-done) on ticket-done '{ticket: "05", commits: ["bbbbbbb"]}' ;;
      pr) on pr '{url: "https://github.com/owner/proj/pull/6", head: "2222222"}' ;;
      review) on review '{verdict: "pass", head: "1111111"}' ;;
    esac
    # A reviewer's launch or a review of the merged head moves nothing: the part stays merged.
    want=${after#*:}
    assert_equal "$after $(fold_read phase)" "$after $want"
  done
}

@test "T278's A1: a part merged, then a builder's ticket, reads building and the sweep does not say to close it" {
  opened feature
  on thread '{discord_thread: "1"}'
  on plan-approved '{by: "coordinator"}'
  on pr '{url: "https://github.com/o/r/pull/1", head: "aaaaaaa1"}'
  on review '{verdict: "pass", head: "aaaaaaa1"}'
  on merged '{pr: 1, merge: "fedcba9", url: "https://github.com/o/r/pull/1", head: "aaaaaaa1", by: "Daniel"}'
  assert_equal "$(fold_read phase)" merged
  builder_launch b2
  on ticket-done '{ticket: "05", commits: ["bbbbbbb2"]}'
  on done '{role: "builder", session: "b2", report: "05"}'
  assert_equal "$(fold_read phase)" building
  run fold_read '[task_findings([{id: "b2", status: "idle", name: "T1-builder"}]; {sessions: {}})][0].text'
  assert_equal "$output" "T1 no-worker: every live worker is idle with a ledger event since its launch (latest T1-builder b2); next: send it its next step or launch the next worker with team-worker, or log why the task waits with team-log"
}

@test "a held or a blocked shows over the work phase while it stands, wherever it was logged, and closed over every one" {
  opened feature
  on held '{reason: "OS update"}'
  on merged '{pr: 5, merge: "fedcba9", head: "a1b2c3d", by: "1563"}'
  assert_equal "$(fold_read phase)" held
  on blocked '{reason: "a denied push"}'
  assert_equal "$(fold_read phase)" held
  # A launch ends the block, never the hold; a resumed ends both.
  builder_launch b2
  assert_equal "$(fold_read 'phase + " " + (lifecycle.parks | map(.id) | join(","))')" "held held-1"
  on resumed
  assert_equal "$(fold_read phase)" building
  on blocked '{reason: "the second half waits on T31"}'
  assert_equal "$(fold_read 'phase + " " + (lifecycle.parks | map(.id) | join(","))')" "blocked blocked-2"
  on closed '{archive: [], returned: [], kept: []}'
  assert_equal "$(fold_read phase)" closed
}

@test "the fold keeps each standing park with its id, the asks no event settles, and the stow until a launch" {
  opened feature
  on waiting '{on: "Daniel", reason: "an interview", since: "2026-10-31T00:00:00Z"}'
  on asked '{id: "door-data", text: "Which door data?"}'
  on asked '{id: "merge", text: "merge https://github.com/owner/proj/pull/5 at 1111111?"}'
  on paused '{reason: "stowed, handoff written"}'
  on stowed '{machine: "m1", worktrees: [], roles: ["builder"], cause: "handoff"}'
  assert_equal "$(fold_read 'lifecycle | [.parks[] | [.id, .kind, .on, .since, .i, .passed]]')" \
    '[["waiting-1","waiting","Daniel","2026-10-31T00:00:00Z",1,false],["paused-1","paused",null,"2026-11-01T00:04:00Z",4,false]]'
  assert_equal "$(fold_read 'lifecycle | .asks | map(.id)')" '["door-data","merge"]'
  assert_equal "$(fold_read 'lifecycle.stow')" '{"state":"stowed","cause":"handoff","roles":["builder"],"since":"2026-11-01T00:05:00Z","i":5}'
  on answered '{id: "door-data", text: "the old data"}'
  on merge-approved '{url: "https://github.com/owner/proj/pull/5", head: "1111111", discord_message: "1"}'
  assert_equal "$(fold_read 'lifecycle | .asks')" '[]'
  # A resumed naming only a merge-base round's brief ends no park; a launch ends the wait and the
  # pause and the stow, and the next park's id counts on.
  on resumed '{brief: "brief-merge-base"}'
  assert_equal "$(fold_read 'lifecycle | .parks | map(.id)')" '["waiting-1","paused-1"]'
  builder_launch b2
  on waiting '{on: "T31", reason: "its PR"}'
  assert_equal "$(fold_read 'lifecycle | [(.parks | map(.id)), .stow, .counts]')" '[["waiting-2"],null,{"waiting":2,"paused":1}]'
}
