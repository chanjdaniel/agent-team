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
  # Each kind the table lists is a contract kind, so a kind the contract drops cannot linger here.
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
  on "done" '{role: "builder", session: "b1", report: "05"}'
  on "done" '{role: "reviewer", session: "r1", report: "review-ready https://x"}'
  assert_equal "$(fold_read phase)" building
  on "done" '{role: "builder", session: "b1", report: "review-ready https://github.com/owner/proj/pull/5"}'
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
  on "done" '{role: "builder", session: "b2", report: "05"}'
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
  # An old line's cause is legacy_cause's, and typed false.
  assert_equal "$(fold_read 'lifecycle | [.parks[] | [.id, .kind, .cause, .typed, .on, .since, .i, .passed]]')" \
    '[["waiting-1","waiting","daniel",false,"Daniel","2026-10-31T00:00:00Z",1,false],["paused-1","paused","stow",false,null,"2026-11-01T00:04:00Z",4,false]]'
  assert_equal "$(fold_read 'lifecycle | .asks | map(.id)')" '["door-data","merge"]'
  assert_equal "$(fold_read 'lifecycle.stow')" '{"state":"stowed","cause":"handoff","roles":["builder"],"since":"2026-11-01T00:05:00Z","i":5}'
  on answered '{id: "door-data", text: "the old data"}'
  on merge-approved '{url: "https://github.com/owner/proj/pull/5", head: "1111111", discord_message: "1"}'
  assert_equal "$(fold_read 'lifecycle | .asks')" '[]'
  # The merge-approved also ended the old wait on Daniel (ticket 03's rule); a resumed naming only a
  # merge-base round's brief ends no park; a launch ends the pause and the stow, and the next
  # park's id counts on.
  assert_equal "$(fold_read 'lifecycle | .parks | map(.id)')" '["paused-1"]'
  on resumed '{brief: "brief-merge-base"}'
  assert_equal "$(fold_read 'lifecycle | .parks | map(.id)')" '["paused-1"]'
  builder_launch b2
  on waiting '{on: "T31", reason: "its PR"}'
  assert_equal "$(fold_read 'lifecycle | [(.parks | map(.id)), .stow, .counts]')" '[["waiting-2"],null,{"waiting":2,"paused":1}]'
}

@test "T278's A4: a room refusal and a resumed after it agree in parked and refused_launches, which both clear" {
  opened feature
  on plan-approved '{by: "Daniel"}'
  on launch '{role: "planner", session: "p1", worktree: "/w/1", toolkits: []}'
  on paused '{reason: "no room for session:builder at full (90%)"}'
  # The refusal is a standing park of cause room, its role read once from its reason.
  assert_equal "$(fold_read 'lifecycle.parks | map([.id, .cause, .role])')" '[["paused-1","room","builder"]]'
  assert_equal "$(fold_read '[parked, refused_launches]')" \
    '[true,{"at":"2026-11-01T00:03:00Z","roles":["builder"],"hold":null}]'
  on resumed
  assert_equal "$(fold_read '[parked, refused_launches]')" '[false,null]'
  # A room refusal whose words name no role parks the task, and refused_launches, which relaunches
  # roles, has none to name.
  on paused '{reason: "no room at full (90%): 17.9 GiB of 17.2"}'
  assert_equal "$(fold_read '[parked, refused_launches, (lifecycle.parks | map([.cause, .role]))]')" '[true,null,[["room",null]]]'
}

@test "T278's A5 and D6: a PAUSED stowed with detail hands the stowed builder on, and launch_states calls it handed-on" {
  local reason
  for reason in "stowed" "stowed, handoff written" "stowed ad6520fc for shutdown; next: re-run the gate"; do
    events=()
    opened feature
    builder_launch b1
    on paused "{reason: \"$reason\"}"
    builder_launch b2
    assert_equal "$(fold_read 'handed_on_launches("builder"; "/home/x") | map([.session, .stowed, .handed_on])')" \
      '[["b1",true,true],["b2",false,false]]'
    assert_equal "$(fold_read 'handed_on_launches(""; "/home/x") | launch_states([{id: "b1", status: "idle"}]) | map([.session, .state])')" \
      '[["b1","handed-on"]]'
  done
  # A paused that is no stow (its cause worker) is a wait the builder comes back from.
  events=()
  opened feature
  builder_launch b1
  on paused '{reason: "holding gate runs for the sudo fix"}'
  builder_launch b2
  assert_equal "$(fold_read 'handed_on_launches(""; "/home/x") | launch_states([{id: "b1", status: "idle"}]) | map([.session, .state])')" \
    '[["b1","idle with no event of its own since its launch"]]'
}

@test "a merge-approved ends an old wait on Daniel, and no other park" {
  opened feature
  on waiting '{on: "Daniel", reason: "the merge of PR 5"}'
  on waiting '{on: "daniel", reason: "ask merge"}'
  on waiting '{reason: "a word on the plan"}'
  on waiting '{on: "restart", reason: "machine shutdown; resume from the handoff"}'
  on blocked '{reason: "Daniel to apply the settings change"}'
  on paused '{reason: "machine load"}'
  on held '{reason: "on hold by Daniel"}'
  on merge-approved '{url: "https://github.com/owner/proj/pull/5", head: "1111111", discord_message: "1"}'
  assert_equal "$(fold_read 'lifecycle.parks | map(.id)')" '["waiting-4","blocked-1","paused-1","held-1"]'
  assert_equal "$(fold_read 'waiting')" '{"on":"restart","reason":"machine shutdown; resume from the handoff","since":"2026-11-01T00:04:00Z"}'
  # A wait whose line carries its own cause is not an old one, whatever it says.
  on waiting '{on: "Daniel", cause: "daniel", reason: "an interview"}'
  on merge-approved '{url: "https://github.com/owner/proj/pull/5", head: "1111111", discord_message: "2"}'
  assert_equal "$(fold_read 'lifecycle.parks | map([.id, .typed])')" \
    '[["waiting-4",false],["blocked-1",false],["paused-1",false],["held-1",false],["waiting-5",true]]'
}

@test "legacy_cause gives every park line of an old ledger a cause, first match winning" {
  run jq -L "$REPO_ROOT/bin/lib" -sc 'include "ledger";
    map(select(.event | IN("held", "blocked", "waiting", "paused")) | legacy_cause)
    | [length, (group_by(.) | map([.[0], length]))]' "$REPO_ROOT/tests/fixtures/ledger-2026-10-23.jsonl"
  assert_equal "$status" 0
  assert_equal "$output" '[30,[["daniel",8],["denial",9],["shutdown",6],["stow",3],["worker",4]]]'
  # One line of each rule, in the order the rules are tried.
  run jq -L "$REPO_ROOT/bin/lib" -nrc 'include "ledger";
    {event: "paused", reason: "Stowed ad6520fc for shutdown"},
    {event: "paused", reason: "team-worker: no room for session:reviewer at minor (30%)"},
    {event: "waiting", on: "the weekly limit", reason: "until Monday"},
    {event: "paused", reason: "the usage limit, stowed after it"},
    {event: "waiting", on: "restart", reason: "machine shutdown 2026-10-22"},
    {event: "held", reason: "OS update"},
    {event: "held", reason: "on hold by Daniel"},
    {event: "waiting", on: "Daniel", reason: "ask door-data"},
    {event: "waiting", on: "daniel", reason: "walkthrough section B"},
    {event: "waiting", reason: "a word on the plan"},
    {event: "waiting", on: "GitHub Support", reason: "ticket 4412"},
    {event: "blocked", on: "T31", reason: "its PR"},
    {event: "blocked", reason: "auto mode denied git rm"},
    {event: "blocked", reason: "the fixture server is down"},
    {event: "paused", reason: "docker daemons need a restart"},
    {event: "paused", reason: "holding gate runs for the sudo fix"},
    {event: "paused", cause: "limit", reason: "stowed"}
    | park_cause'
  assert_equal "$status" 0
  assert_equal "$(tr '\n' ' ' <<<"$output")" \
    "stow room limit limit shutdown shutdown daniel-hold ask daniel daniel outside task denial worker machine worker limit "
}

# problems <kind> [<jq object of more fields>]: the problems transition_problems finds for a T1
# event of <kind> a minute after the last event, over the events so far, one per line.
problems() {
  fold_read '(last.ts // "2026-11-01T00:00:00Z" | fromdate + 60 | todate) as $ts
    | transition_problems({ts: $ts, task: "T1", event: "'"$1"'"} + ('"${2:-{\}}"'))'
}

@test "the table test: every contract kind, in every status and phase, is refused exactly where lifecycle.json does not take it" {
  # Generated from lifecycle.json, so a new row is tested by being written: each case a state of
  # that status and phase, and a T1 event of the kind, whose retro is T1 for closed-own-retro and
  # T2 otherwise; taken when the kind's status (or default's) names the status, a closed task's
  # own retro taken where it names closed too, and its phases (or default's) are null or name it.
  run fold_read 'lifecycle_table as $t
    | [$contract.kinds | keys[] as $kind | lifecycle_statuses[] as $status | $t.phases[] as $phase
       | ($t.kinds[$kind] // {}) as $row
       | ($row.status // $t.default.status) as $statuses
       | ($row.phases // $t.default.phases) as $phases
       | ((($statuses | index([$status])) or ($status == "closed-own-retro" and ($statuses | index(["closed"]))))
          and ($phases == null or ($phases | index([$phase])))) as $taken
       | (lifecycle_start | .status = (if $status == "closed-own-retro" then "closed" else $status end)
          | .phase = $phase | .since = "2026-11-01T00:00:00Z" | .opened_at = "2026-11-01T00:00:00Z") as $state
       | {ts: "2026-11-01T00:01:00Z", task: "T1", event: $kind, retro: (if $status == "closed-own-retro" then "T1" else "T2" end)} as $e
       | [$state | lifecycle_problems($e)] as $problems
       | {kind: $kind, status: $status, phase: $phase, taken: $taken, problems: $problems}] as $cases
    | [$cases[] | select(.taken == (.problems != [])) | "\(.kind) \(.status) \(.phase): taken \(.taken), problems \(.problems)"],
      ([$cases[] | select(.taken)] | length > 0), ([$cases[] | select(.taken | not)] | length > 0),
      (($cases | length) == ($contract.kinds | length) * (lifecycle_statuses | length) * ($t.phases | length))'
  assert_equal "$status" 0
  assert_equal "$output" "$(printf '[]\ntrue\ntrue\ntrue')"
}

@test "a closed task takes no event but a team-wide word and a closed retro's own retro-change" {
  opened retro
  on closed '{archive: [], returned: [], kept: []}'
  assert_equal "$(problems retro-change '{retro: "T1", proposals: "1, 2"}')" ""
  assert_equal "$(problems retro-change '{retro: "T5", proposals: "1"}')" "T1 is closed, and a closed task takes no retro-change"
  assert_equal "$(problems merge-standing '{project: "proj", discord_message: "1", discord_channel: "2"}')" ""
  assert_equal "$(problems asked '{id: "a1", text: "which?"}')" "T1 is closed, and a closed task takes no asked"
  # A closed task of another path takes no retro-change, even one naming it.
  events=()
  opened small
  on closed '{archive: [], returned: [], kept: []}'
  assert_equal "$(problems retro-change '{retro: "T7", proposals: "3"}')" "T1 is closed, and a closed task takes no retro-change"
}

@test "a new task takes a thread and then its opened, and an opened task no second opened" {
  assert_equal "$(problems thread '{discord_thread: "1563"}')" ""
  on thread '{discord_thread: "1563"}'
  assert_equal "$(problems opened '{path: "feature"}')" ""
  opened feature
  assert_equal "$(problems opened '{path: "feature"}')" "T1 is opened already, at 2026-11-01T00:01:00Z"
  assert_equal "$(problems thread '{discord_thread: "1564"}')" ""
}

@test "an event of a task not opened is refused, naming what its status takes, and review as T99's first event is refused" {
  run fold_read 'transition_problems({ts: "2026-11-01T00:00:00Z", task: "T99", event: "review", verdict: "pass", head: "a1b2c3d"})'
  assert_equal "$output" "T99 is not opened (no opened event), and it takes only thread and opened before its opened, not review"
  # A legacy task (events, no opened) takes its closed too, as team-close of a half-opened task.
  on launch '{role: "builder", session: "b1"}'
  assert_equal "$(problems review '{verdict: "pass", head: "a1b2c3d"}')" \
    "T1 is not opened (no opened event), and it takes only thread, opened and closed before its opened, not review"
  assert_equal "$(problems closed)" ""
  # A kind the table does not list takes default: an open task only.
  assert_equal "$(problems image-posted)" \
    "T1 is not opened (no opened event), and it takes only thread, opened and closed before its opened, not image-posted"
}

@test "a kind the table takes only in some phases is refused in the others, naming them" {
  opened feature
  on pr '{url: "https://github.com/owner/proj/pull/5", head: "a1b2c3d"}'
  assert_equal "$(problems plan-approved)" \
    "T1 is in-review since 2026-11-01T00:01:00Z, and plan-approved is taken only while it is planning, building, merged-part or merged"
  on review '{verdict: "pass", head: "a1b2c3d"}'
  assert_equal "$(problems plan-approved)" \
    "T1 is awaiting-merge since 2026-11-01T00:02:00Z, and plan-approved is taken only while it is planning, building, merged-part or merged"
  on merged '{url: "https://github.com/owner/proj/pull/5", head: "a1b2c3d", phases_left: [2]}'
  assert_equal "$(problems plan-approved)" ""
  # A held shows over the work phase, but the table reads the work phase.
  on held '{reason: "on hold by Daniel"}'
  assert_equal "$(problems plan-approved)" ""
}

@test "check_lifecycle replays raw lines in one pass, each task's event against the state before it" {
  run jq -L "$REPO_ROOT/bin/lib" -nRc --slurpfile contract "$REPO_ROOT/bin/lib/ledger-contract.json" \
    'include "ledger"; $contract[0] as $contract | check_lifecycle' <<'LEDGER'
{"ts":"2026-11-01T00:00:00Z","task":"T2","event":"thread","discord_thread":"1"}
{"ts":"2026-11-01T00:01:00Z","task":"T2","event":"opened","path":"small"}
not JSON

{"ts":"2026-11-01T00:02:00Z","task":"T3","event":"asked","id":"a1","text":"which?"}
{"ts":"2026-11-01T00:03:00Z","event":"asked"}
{"ts":"2026-11-01T00:04:00Z","task":"T2","event":"closed"}
{"ts":"2026-11-01T00:05:00Z","task":"T2","event":"answered","id":"a1","by":"Daniel"}
LEDGER
  assert_equal "$status" 0
  assert_equal "$output" '{"total":8,"from":null,"bad":[{"line":5,"task":"T3","event":"asked","ts":"2026-11-01T00:02:00Z","problems":["T3 is not opened (no opened event), and it takes only thread and opened before its opened, not asked"]},{"line":8,"task":"T2","event":"answered","ts":"2026-11-01T00:05:00Z","problems":["T2 is closed, and a closed task takes no answered"]}]}'
}
